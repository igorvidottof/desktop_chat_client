use crate::{
    api::simple::{MatrixStreamError, MatrixSyncStatus, MatrixUpdate, MatrixUpdateKind},
    auth,
    frb_generated::StreamSink,
    message_history,
};
use futures_util::StreamExt;
use matrix_sdk::{
    config::SyncSettings,
    sync::{State, SyncResponse},
    Client, LoopCtrl,
};
use std::{
    collections::HashMap,
    sync::{
        atomic::{AtomicU64, Ordering},
        Arc, Mutex,
    },
    time::Duration,
};
use tokio::{
    sync::{broadcast, watch},
    task::JoinHandle,
};

const BUFFER: usize = 128;
const MAX_SUBSCRIBERS: usize = 8;
const DELIVERY_TIMEOUT: Duration = Duration::from_secs(30);
static SUBSCRIPTION_ID: AtomicU64 = AtomicU64::new(1);

struct Subscriber {
    receiver: Option<broadcast::Receiver<MatrixUpdate>>,
    ack: watch::Sender<u32>,
    closed: watch::Sender<bool>,
    created: std::time::Instant,
}

pub(crate) struct UpdateHub {
    sender: broadcast::Sender<MatrixUpdate>,
    stopped: watch::Sender<bool>,
    status: Mutex<MatrixSyncStatus>,
    subscribers: Mutex<HashMap<String, Subscriber>>,
}

impl UpdateHub {
    fn new() -> Arc<Self> {
        let (sender, _) = broadcast::channel(BUFFER);
        Arc::new(Self {
            sender,
            stopped: watch::channel(false).0,
            status: Mutex::new(MatrixSyncStatus::Connecting),
            subscribers: Mutex::new(HashMap::new()),
        })
    }

    fn update(&self, kind: MatrixUpdateKind) -> MatrixUpdate {
        MatrixUpdate {
            subscription_id: String::new(),
            sequence: 0,
            kind,
            conversation_id: None,
            message: None,
            status: *self.status.lock().expect("status mutex"),
        }
    }

    fn emit(&self, update: MatrixUpdate) {
        if !*self.stopped.borrow() {
            let _ = self.sender.send(update);
        }
    }

    fn status(&self, status: MatrixSyncStatus) {
        let mut current = self.status.lock().expect("status mutex");
        if *current == status {
            return;
        }
        *current = status;
        drop(current);
        self.emit(self.update(MatrixUpdateKind::Status));
    }

    fn register(&self) -> Result<String, MatrixStreamError> {
        let mut subscribers = self
            .subscribers
            .lock()
            .map_err(|_| MatrixStreamError::Internal)?;
        if *self.stopped.borrow() {
            return Err(MatrixStreamError::SubscriptionClosed);
        }
        // Registros abandonados antes de anexar o sink também têm prazo e limite.
        subscribers.retain(|_, s| s.receiver.is_none() || s.created.elapsed() < DELIVERY_TIMEOUT);
        if subscribers.len() >= MAX_SUBSCRIBERS {
            return Err(MatrixStreamError::SubscriberLimit);
        }
        let id = SUBSCRIPTION_ID.fetch_add(1, Ordering::Relaxed).to_string();
        subscribers.insert(
            id.clone(),
            Subscriber {
                receiver: Some(self.sender.subscribe()),
                ack: watch::channel(0).0,
                closed: watch::channel(false).0,
                created: std::time::Instant::now(),
            },
        );
        Ok(id)
    }

    fn close(&self, id: &str) {
        if let Ok(mut subscribers) = self.subscribers.lock() {
            if let Some(s) = subscribers.remove(id) {
                s.closed.send_replace(true);
            }
        }
    }

    fn stop(&self) {
        // Invalidar entrega precede aguardar a rede: nenhuma atualização antiga é publicada.
        self.stopped.send_replace(true);
        if let Ok(mut subscribers) = self.subscribers.lock() {
            for (_, s) in subscribers.drain() {
                s.closed.send_replace(true);
            }
        }
    }
}

// O proprietário pertence ao cliente autenticado. A tarefa guarda Client::clone,
// não Arc<AuthenticatedClient>: não há ciclo de propriedade nem lease infinito.
pub(crate) struct SyncOwner {
    pub(crate) hub: Arc<UpdateHub>,
    task: Mutex<Option<JoinHandle<()>>>,
}

impl SyncOwner {
    pub(crate) fn new() -> Self {
        Self {
            hub: UpdateHub::new(),
            task: Mutex::new(None),
        }
    }

    pub(crate) fn start(&self, client: &Client) {
        let hub = Arc::clone(&self.hub);
        let client = client.clone();
        self.start_task(async move {
            run(client, hub).await;
        });
    }

    fn start_task(&self, future: impl std::future::Future<Output = ()> + Send + 'static) {
        let mut task = self.task.lock().expect("sync owner mutex");
        // Hot restart chama start novamente; a trava garante exatamente um proprietário.
        if task.is_some() || *self.hub.stopped.borrow() {
            return;
        }
        *task = Some(tokio::spawn(future));
    }

    pub(crate) async fn stop(&self) -> Result<(), ()> {
        self.hub.stop();
        let task = self.task.lock().map_err(|_| ())?.take();
        // Cancelamento cooperativo na fronteira do callback preserva a transação do
        // store. Não abortar process_sync/spawn_blocking SQLite enquanto escreve.
        if let Some(task) = task {
            task.await.map_err(|_| ())?;
        }
        Ok(())
    }
}

async fn run(client: Client, hub: Arc<UpdateHub>) {
    // Subscribe before the first sync so keys received by that sync cannot be
    // missed. This listener shares the sync owner's lifetime; it never syncs.
    let Some(keys) = client.encryption().room_keys_received_stream().await else {
        run_sync(client, hub).await;
        return;
    };
    tokio::pin!(keys);
    let sync = run_sync(client.clone(), Arc::clone(&hub));
    tokio::pin!(sync);
    loop {
        tokio::select! {
            _ = &mut sync => return,
            update = keys.next() => {
                match update {
                    Some(Ok(keys)) => publish_key_refresh(&hub, keys.into_iter().map(|key| key.room_id)),
                    Some(Err(_)) => {
                        // A lagged key stream invalidates the bounded active history.
                        hub.emit(hub.update(MatrixUpdateKind::ResyncRequired));
                    }
                    None => { sync.await; return; }
                }
            }
        }
    }
}

fn publish_key_refresh(
    hub: &UpdateHub,
    rooms: impl IntoIterator<Item = matrix_sdk::ruma::OwnedRoomId>,
) {
    // Deduplicate this SDK batch only. No event/key cache survives the callback.
    let mut seen = std::collections::HashSet::new();
    for room in rooms {
        if seen.insert(room.clone()) {
            let mut event = hub.update(MatrixUpdateKind::ResyncRequired);
            event.conversation_id = Some(room.to_string());
            hub.emit(event);
        }
    }
}

async fn run_sync(client: Client, hub: Arc<UpdateHub>) {
    let stop = hub.stopped.subscribe();
    // O callback precisa ser Fn. Estado pequeno do backoff fica atrás de mutex,
    // sem manter a trava durante awaits; callbacks são sequenciais no SDK.
    let retry = Mutex::new((2u64, true));
    let _ = client
        .sync_with_result_callback(
            SyncSettings::default().ignore_timeout_on_first_sync(true),
            |result| {
                let hub = Arc::clone(&hub);
                let client = &client;
                let retry = &retry;
                let mut stop = stop.clone();
                async move {
                    if *stop.borrow() {
                        return Ok(LoopCtrl::Break);
                    }
                    match result {
                        Ok(response) => {
                            hub.status(MatrixSyncStatus::Connected);
                            let initial = {
                                let mut state = retry.lock().expect("retry mutex");
                                state.0 = 2;
                                let initial = state.1;
                                state.1 = false;
                                initial
                            };
                            publish_response(client, &hub, &response, initial);
                        }
                        Err(error) => {
                            let status = classify_error(&error);
                            hub.status(status);
                            if status == MatrixSyncStatus::AuthenticationRequired {
                                // Preservar sessão/cofre: a UI oferece logout; token revogado
                                // não causa retry agressivo nem remoção automática de credenciais.
                                let _ = stop.changed().await;
                                return Ok(LoopCtrl::Break);
                            }
                            let delay = {
                                let mut state = retry.lock().expect("retry mutex");
                                let seconds = state.0;
                                state.0 = (seconds * 2).min(30);
                                Duration::from_secs(seconds)
                            };
                            tokio::select! {
                                _ = stop.changed() => return Ok(LoopCtrl::Break),
                                _ = tokio::time::sleep(delay) => {}
                            }
                        }
                    }
                    Ok(if *stop.borrow() {
                        LoopCtrl::Break
                    } else {
                        LoopCtrl::Continue
                    })
                }
            },
        )
        .await;
    // Sem abort: ao retornar, o request e todo processamento do SDK já terminaram.
}

fn classify_error(error: &matrix_sdk::Error) -> MatrixSyncStatus {
    use matrix_sdk::ruma::api::error::ErrorKind;
    if matches!(error, matrix_sdk::Error::AuthenticationRequired)
        || matches!(error, matrix_sdk::Error::Http(e) if matches!(e.client_api_error_kind(), Some(ErrorKind::MissingToken | ErrorKind::UnknownToken(_))))
    {
        MatrixSyncStatus::AuthenticationRequired
    } else {
        MatrixSyncStatus::Reconnecting
    }
}

fn relevant_state(event_type: Option<String>) -> bool {
    matches!(
        event_type.as_deref(),
        Some("m.room.name" | "m.room.member" | "m.room.canonical_alias" | "m.room.create")
    )
}

fn publish_response(client: &Client, hub: &UpdateHub, response: &SyncResponse, initial: bool) {
    let mut rooms_changed = initial || !response.rooms.left.is_empty();
    for id in response.rooms.left.keys() {
        let mut event = hub.update(MatrixUpdateKind::ResyncRequired);
        event.conversation_id = Some(id.to_string());
        hub.emit(event);
    }
    for (id, update) in &response.rooms.joined {
        let (State::Before(state) | State::After(state)) = &update.state;
        rooms_changed |= state
            .iter()
            .any(|e| relevant_state(e.get_field("type").ok().flatten()));
        rooms_changed |= update
            .timeline
            .events
            .iter()
            .any(|e| relevant_state(e.raw().get_field("type").ok().flatten()));
        let Some(room) = client.get_room(id) else {
            continue;
        };
        if room.is_space() {
            continue;
        }
        let encryption_changed = state.iter().any(|e| {
            e.get_field::<String>("type").ok().flatten().as_deref() == Some("m.room.encryption")
        }) || update.timeline.events.iter().any(|e| {
            e.raw()
                .get_field::<String>("type")
                .ok()
                .flatten()
                .as_deref()
                == Some("m.room.encryption")
        });
        if encryption_changed {
            let mut event = hub.update(MatrixUpdateKind::ResyncRequired);
            event.conversation_id = Some(id.to_string());
            hub.emit(event);
        }
        if update.timeline.limited {
            let mut event = hub.update(MatrixUpdateKind::ResyncRequired);
            event.conversation_id = Some(id.to_string());
            hub.emit(event);
        }
        let Some(own) = client.user_id() else {
            continue;
        };
        for event in &update.timeline.events {
            if let Some(message) = message_history::map_message(event.raw(), own) {
                let mut event = hub.update(MatrixUpdateKind::Message);
                event.conversation_id = Some(id.to_string());
                event.message = Some(message);
                hub.emit(event);
            }
        }
    }
    // Uma invalidação por lote; mensagens/presença/ephemeral não recarregam a lista.
    if rooms_changed {
        hub.emit(hub.update(MatrixUpdateKind::ConversationsChanged));
    }
}

fn current_hub() -> Result<Arc<UpdateHub>, MatrixStreamError> {
    let client = auth::authenticated_client().map_err(|_| MatrixStreamError::NotAuthenticated)?;
    Ok(Arc::clone(&client.sync.hub))
}

pub(crate) async fn open() -> Result<String, MatrixStreamError> {
    current_hub()?.register()
}
pub(crate) fn close(id: &str) {
    if let Ok(hub) = current_hub() {
        hub.close(id);
    }
}
pub(crate) fn acknowledge(id: &str, sequence: u32) {
    if let Ok(hub) = current_hub() {
        if let Ok(subscribers) = hub.subscribers.lock() {
            if let Some(s) = subscribers.get(id) {
                s.ack.send_replace(sequence);
            }
        }
    }
}

pub(crate) async fn stream(
    id: String,
    sink: StreamSink<MatrixUpdate>,
) -> Result<(), MatrixStreamError> {
    let hub = current_hub()?;
    deliver(hub, id, |event| sink.add(event).is_ok(), DELIVERY_TIMEOUT).await
}

async fn deliver(
    hub: Arc<UpdateHub>,
    id: String,
    send: impl Fn(MatrixUpdate) -> bool,
    delivery_timeout: Duration,
) -> Result<(), MatrixStreamError> {
    // Depois deste bloco não existe handle do SDK na tarefa de entrega FRB.
    let (mut receiver, mut ack, mut closed) = {
        let mut subscribers = hub
            .subscribers
            .lock()
            .map_err(|_| MatrixStreamError::Internal)?;
        let s = subscribers
            .get_mut(&id)
            .ok_or(MatrixStreamError::SubscriptionClosed)?;
        (
            s.receiver
                .take()
                .ok_or(MatrixStreamError::SubscriptionClosed)?,
            s.ack.subscribe(),
            s.closed.subscribe(),
        )
    };
    let mut stopped = hub.stopped.subscribe();
    let mut sequence = 0u32;
    let mut next = Some(hub.update(MatrixUpdateKind::ResyncRequired));
    loop {
        if *stopped.borrow() || *closed.borrow() {
            break;
        }
        let mut event = if let Some(event) = next.take() {
            event
        } else {
            tokio::select! {
                _ = stopped.changed() => break,
                _ = closed.changed() => break,
                result = receiver.recv() => match result {
                    Ok(event) => event,
                    Err(broadcast::error::RecvError::Lagged(_)) => {
                        // Perda do consumidor lento vira invalidação explícita, sem histórico infinito.
                        receiver = hub.sender.subscribe();
                        hub.update(MatrixUpdateKind::ResyncRequired)
                    },
                    Err(broadcast::error::RecvError::Closed) => break,
                },
                // Lease nativo detecta Dart morto mesmo quando o homeserver está silencioso.
                _ = tokio::time::sleep(Duration::from_secs(15)) => hub.update(MatrixUpdateKind::Status),
            }
        };
        sequence = sequence.wrapping_add(1);
        event.subscription_id.clone_from(&id);
        event.sequence = sequence;
        if *stopped.borrow() || *closed.borrow() || !send(event) {
            break;
        }
        let consumed = async {
            while *ack.borrow_and_update() != sequence {
                if ack.changed().await.is_err() {
                    return false;
                }
            }
            true
        };
        tokio::select! {
            _ = stopped.changed() => break,
            _ = closed.changed() => break,
            result = tokio::time::timeout(delivery_timeout, consumed) => {
                if !matches!(result, Ok(true)) { break; }
            }
        }
    }
    hub.close(&id);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use matrix_sdk::ruma::{events::AnySyncTimelineEvent, serde::Raw, user_id};
    use serde_json::json;
    use std::sync::atomic::AtomicUsize;

    fn text(id: &str, msgtype: &str) -> Raw<AnySyncTimelineEvent> {
        Raw::from_json_string(
            json!({"type":"m.room.message", "event_id":id,
            "sender":"@me:example.org", "origin_server_ts":123,
            "content":{"msgtype":msgtype, "body":"literal <b>texto</b>"}})
            .to_string(),
        )
        .unwrap()
    }

    #[tokio::test]
    async fn duplicate_start_and_hot_restart_keep_one_owner_and_stop_joins_it() {
        let owner = SyncOwner::new();
        let count = Arc::new(AtomicUsize::new(0));
        for _ in 0..3 {
            let count = count.clone();
            let mut stop = owner.hub.stopped.subscribe();
            owner.start_task(async move {
                count.fetch_add(1, Ordering::SeqCst);
                if !*stop.borrow() {
                    let _ = stop.changed().await;
                }
            });
        }
        tokio::task::yield_now().await;
        assert_eq!(count.load(Ordering::SeqCst), 1);
        owner.stop().await.unwrap();
        owner.start_task(async {
            panic!("stopped owner restarted");
        });
        assert!(owner.task.lock().unwrap().is_none());
    }

    #[tokio::test]
    async fn unauthenticated_registration_never_starts_sync() {
        assert_eq!(open().await, Err(MatrixStreamError::NotAuthenticated));
    }

    #[tokio::test]
    async fn broadcast_is_bounded_multiple_receivers_and_account_generations_are_isolated() {
        let a = UpdateHub::new();
        let b = UpdateHub::new();
        let id1 = a.register().unwrap();
        let id2 = a.register().unwrap();
        let idb = b.register().unwrap();
        let mut receiver1 = a
            .subscribers
            .lock()
            .unwrap()
            .get_mut(&id1)
            .unwrap()
            .receiver
            .take()
            .unwrap();
        let mut receiver2 = a
            .subscribers
            .lock()
            .unwrap()
            .get_mut(&id2)
            .unwrap()
            .receiver
            .take()
            .unwrap();
        let mut receiverb = b
            .subscribers
            .lock()
            .unwrap()
            .get_mut(&idb)
            .unwrap()
            .receiver
            .take()
            .unwrap();
        a.emit(a.update(MatrixUpdateKind::ConversationsChanged));
        assert_eq!(
            receiver1.recv().await.unwrap().kind,
            MatrixUpdateKind::ConversationsChanged
        );
        assert_eq!(
            receiver2.recv().await.unwrap().kind,
            MatrixUpdateKind::ConversationsChanged
        );
        assert!(matches!(
            receiverb.try_recv(),
            Err(broadcast::error::TryRecvError::Empty)
        ));
        for _ in 0..BUFFER + 1 {
            a.emit(a.update(MatrixUpdateKind::Message));
        }
        assert!(matches!(
            receiver1.recv().await,
            Err(broadcast::error::RecvError::Lagged(_))
        ));
        a.stop();
        assert_eq!(a.register(), Err(MatrixStreamError::SubscriptionClosed));
        assert!(a.subscribers.lock().unwrap().is_empty());
        a.emit(a.update(MatrixUpdateKind::Message));
        assert!(matches!(
            receiverb.try_recv(),
            Err(broadcast::error::TryRecvError::Empty)
        ));
        b.emit(b.update(MatrixUpdateKind::Status));
        assert_eq!(
            receiverb.recv().await.unwrap().kind,
            MatrixUpdateKind::Status
        );
    }

    #[tokio::test]
    async fn subscribers_are_limited_removable_and_abandoned_registrations_expire() {
        let hub = UpdateHub::new();
        let ids: Vec<_> = (0..MAX_SUBSCRIBERS)
            .map(|_| hub.register().unwrap())
            .collect();
        assert_eq!(hub.register(), Err(MatrixStreamError::SubscriberLimit));
        hub.close(&ids[0]);
        let id = hub.register().unwrap();
        hub.subscribers
            .lock()
            .unwrap()
            .get_mut(&id)
            .unwrap()
            .created -= DELIVERY_TIMEOUT;
        assert!(hub.register().is_ok());
    }

    #[tokio::test]
    async fn delivery_has_one_in_flight_then_coalesces_lag_and_disposal_wakes_it() {
        let hub = UpdateHub::new();
        let id = hub.register().unwrap();
        let ack = hub.subscribers.lock().unwrap()[&id].ack.clone();
        let (sent, mut events) = tokio::sync::mpsc::channel(4);
        let task = tokio::spawn(deliver(
            hub.clone(),
            id.clone(),
            move |e| sent.try_send(e).is_ok(),
            Duration::from_secs(1),
        ));
        let first = events.recv().await.unwrap();
        assert_eq!(first.kind, MatrixUpdateKind::ResyncRequired);
        for _ in 0..BUFFER + 1 {
            hub.emit(hub.update(MatrixUpdateKind::Message));
        }
        assert!(events.try_recv().is_err());
        ack.send_replace(first.sequence);
        let lag = events.recv().await.unwrap();
        assert_eq!(lag.kind, MatrixUpdateKind::ResyncRequired);
        hub.close(&id);
        task.await.unwrap().unwrap();
        assert!(hub.subscribers.lock().unwrap().is_empty());
    }

    #[tokio::test]
    async fn dead_dart_or_failed_sink_releases_subscriber_without_stopping_sync() {
        for fail_sink in [false, true] {
            let hub = UpdateHub::new();
            let id = hub.register().unwrap();
            deliver(
                hub.clone(),
                id,
                move |_| !fail_sink,
                Duration::from_millis(5),
            )
            .await
            .unwrap();
            assert!(hub.subscribers.lock().unwrap().is_empty());
            assert!(!*hub.stopped.borrow());
        }
    }

    #[test]
    fn supported_mapping_is_shared_with_history_and_preserves_matrix_identity() {
        for msgtype in ["m.text", "m.notice", "m.emote"] {
            let raw = text("$stable", msgtype);
            let own = message_history::map_message(&raw, user_id!("@me:example.org")).unwrap();
            assert_eq!(own.id, "$stable");
            assert_eq!(own.sender_id, "@me:example.org");
            assert_eq!(own.body, "literal <b>texto</b>");
            assert_eq!(own.timestamp_ms, 123);
            assert!(own.is_own);
            assert!(
                !message_history::map_message(&raw, user_id!("@other:example.org"))
                    .unwrap()
                    .is_own
            );
        }
        assert!(message_history::map_message(
            &text("$file", "m.file"),
            user_id!("@me:example.org")
        )
        .is_none());
        for raw in [
            r#"{"type":"m.room.encrypted","content":{"ciphertext":"private"}}"#,
            r#"{"type":"m.room.message","content":{}}"#,
        ] {
            let raw = Raw::from_json_string(raw.into()).unwrap();
            assert!(message_history::map_message(&raw, user_id!("@me:example.org")).is_none());
        }
    }

    #[tokio::test]
    async fn processed_batch_maps_plain_and_encrypted_rooms() {
        use matrix_sdk::{
            ruma::room_id,
            sync::{JoinedRoomUpdate, Timeline},
        };
        let client = Client::builder()
            .homeserver_url("https://example.invalid")
            .build()
            .await
            .unwrap();
        let mut changes = matrix_sdk::StateChanges::default();
        for (id, encrypted) in [
            (room_id!("!plain:example.org"), false),
            (room_id!("!encrypted:example.org"), true),
        ] {
            let mut info = matrix_sdk::RoomInfo::new(id, matrix_sdk::RoomState::Joined);
            info.mark_encryption_state_synced();
            if encrypted {
                info.set_encryption_event(Some(
                    serde_json::from_value(json!({"algorithm":"m.megolm.v1.aes-sha2"})).unwrap(),
                ));
            }
            changes.add_room(info);
        }
        client.state_store().save_changes(&changes).await.unwrap();
        client
            .restore_session(matrix_sdk::authentication::matrix::MatrixSession {
                meta: matrix_sdk::SessionMeta {
                    user_id: user_id!("@me:example.org").to_owned(),
                    device_id: "SYNTHETIC".into(),
                },
                tokens: matrix_sdk::SessionTokens {
                    access_token: "synthetic-never-sent".into(),
                    refresh_token: None,
                },
            })
            .await
            .unwrap();
        let batch = |id| JoinedRoomUpdate {
            unread_notifications: Default::default(),
            timeline: Timeline {
                limited: false,
                prev_batch: None,
                events: vec![if id == "$encrypted" {
                    message_history::tests::decrypted_event(text(id, "m.text"))
                } else {
                    matrix_sdk::deserialized_responses::TimelineEvent::from_plaintext(text(
                        id, "m.text",
                    ))
                }],
            },
            state: Default::default(),
            account_data: vec![],
            ephemeral: vec![],
            ambiguity_changes: Default::default(),
            avatar_changes: None,
        };
        let hub = UpdateHub::new();
        let mut receiver = hub.sender.subscribe();
        let mut response = SyncResponse::default();
        response
            .rooms
            .joined
            .insert(room_id!("!plain:example.org").to_owned(), batch("$plain"));
        response.rooms.joined.insert(
            room_id!("!encrypted:example.org").to_owned(),
            batch("$encrypted"),
        );
        publish_response(&client, &hub, &response, false);
        let encrypted = receiver.recv().await.unwrap();
        assert_eq!(encrypted.kind, MatrixUpdateKind::Message);
        assert_eq!(
            encrypted.conversation_id.as_deref(),
            Some("!encrypted:example.org")
        );
        assert_eq!(encrypted.message.unwrap().id, "$encrypted");
        let event = receiver.recv().await.unwrap();
        assert_eq!(event.kind, MatrixUpdateKind::Message);
        assert_eq!(event.conversation_id.as_deref(), Some("!plain:example.org"));
        assert_eq!(event.message.unwrap().id, "$plain");
        assert!(receiver.try_recv().is_err());
        response
            .rooms
            .joined
            .get_mut(room_id!("!plain:example.org"))
            .unwrap()
            .timeline
            .limited = true;
        publish_response(&client, &hub, &response, true);
        assert_eq!(
            receiver.recv().await.unwrap().message.unwrap().id,
            "$encrypted"
        );
        assert_eq!(
            receiver.recv().await.unwrap().kind,
            MatrixUpdateKind::ResyncRequired
        );
        assert_eq!(
            receiver.recv().await.unwrap().kind,
            MatrixUpdateKind::Message
        );
        assert_eq!(
            receiver.recv().await.unwrap().kind,
            MatrixUpdateKind::ConversationsChanged
        );
        assert!(receiver.try_recv().is_err());
        // SDK UTD events travel through the same processed callback safely.
        let raw = Raw::from_json_string(json!({
            "type":"m.room.encrypted", "event_id":"$utd", "sender":"@me:example.org", "origin_server_ts":456,
            "content":{"ciphertext":"NEVER_FORWARD"}
        }).to_string()).unwrap();
        response.rooms.joined.clear();
        let mut update = batch("$encrypted");
        update.timeline.events = vec![matrix_sdk::deserialized_responses::TimelineEvent::from_utd(raw,
            matrix_sdk::deserialized_responses::UnableToDecryptInfo { session_id: None,
                reason: matrix_sdk::deserialized_responses::UnableToDecryptReason::MalformedEncryptedEvent })];
        response
            .rooms
            .joined
            .insert(room_id!("!encrypted:example.org").to_owned(), update);
        publish_response(&client, &hub, &response, false);
        let event = receiver.recv().await.unwrap();
        assert_eq!(event.kind, MatrixUpdateKind::Message);
        let message = event.message.unwrap();
        assert_eq!(message.id, "$utd");
        assert_eq!(
            message.body,
            "Não foi possível descriptografar esta mensagem."
        );
        assert_eq!(message.timestamp_ms, 456);
        assert!(receiver.try_recv().is_err());
    }

    #[tokio::test]
    async fn key_batches_request_one_bounded_refresh_per_room_without_retaining_events() {
        use matrix_sdk::ruma::room_id;
        let hub = UpdateHub::new();
        let mut receiver = hub.sender.subscribe();
        publish_key_refresh(
            &hub,
            [
                room_id!("!a:example.org").to_owned(),
                room_id!("!a:example.org").to_owned(),
                room_id!("!b:example.org").to_owned(),
            ],
        );
        for id in ["!a:example.org", "!b:example.org"] {
            let update = receiver.recv().await.unwrap();
            assert_eq!(update.kind, MatrixUpdateKind::ResyncRequired);
            assert_eq!(update.conversation_id.as_deref(), Some(id));
            assert!(update.message.is_none());
        }
        assert!(receiver.try_recv().is_err());
        hub.stop();
        publish_key_refresh(&hub, [room_id!("!a:example.org").to_owned()]);
        assert!(receiver.try_recv().is_err());
    }

    #[test]
    fn only_room_metadata_invalidates_list_and_error_status_has_no_remote_details() {
        for event in [
            "m.room.name",
            "m.room.member",
            "m.room.canonical_alias",
            "m.room.create",
        ] {
            assert!(relevant_state(Some(event.into())));
        }
        for event in [
            "m.room.message",
            "m.room.encrypted",
            "m.typing",
            "m.presence",
            "m.reaction",
        ] {
            assert!(!relevant_state(Some(event.into())));
        }
        assert_eq!(
            classify_error(&matrix_sdk::Error::AuthenticationRequired),
            MatrixSyncStatus::AuthenticationRequired
        );
        assert_eq!(
            classify_error(&matrix_sdk::Error::UnknownError(Box::new(
                std::io::Error::other("private server detail")
            ))),
            MatrixSyncStatus::Reconnecting
        );
    }
}
