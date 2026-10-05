use crate::{
    api::simple::{ConversationError, ConversationSummary},
    auth, message_history,
};

pub(crate) async fn mark_read(id: &str) -> Result<(), ConversationError> {
    let _operation = auth::CLIENT_OPERATIONS.read().await;
    let client = auth::authenticated_client()?;
    let result = async {
        let room = message_history::resolve_room(&client, id).map_err(map_read_error)?;
        // O evento mais recente pode ser de estado ou criptografado; não filtrar por texto.
        let mut options = matrix_sdk::room::MessagesOptions::backward();
        options.limit = matrix_sdk::ruma::uint!(1);
        let history = room
            .messages(options)
            .await
            .map_err(|error| map_read_error(message_history::map_sdk_error(error)))?;
        auth::ensure_current(&client)?;
        message_history::ensure_joined(room.state()).map_err(map_read_error)?;
        if let Some(event) = history.chunk.first() {
            let event_id = event
                .raw()
                .get_field::<matrix_sdk::ruma::OwnedEventId>("event_id")
                .map_err(|_| ConversationError::Synchronization)?
                .ok_or(ConversationError::Synchronization)?;
            let receipts = matrix_sdk::room::Receipts::new()
                .fully_read_marker(event_id.clone())
                .private_read_receipt(event_id);
            room.send_multiple_receipts(receipts)
                .await
                .map_err(|error| map_read_error(message_history::map_sdk_error(error)))?;
        }
        Ok(())
    }
    .await;
    auth::ensure_current(&client)?;
    result
}

fn map_read_error(error: crate::api::simple::MessageHistoryError) -> ConversationError {
    use crate::api::simple::MessageHistoryError;
    match error {
        MessageHistoryError::NotAuthenticated => ConversationError::NotAuthenticated,
        MessageHistoryError::Network => ConversationError::Network,
        MessageHistoryError::Tls => ConversationError::Tls,
        MessageHistoryError::RateLimited => ConversationError::RateLimited,
        MessageHistoryError::Internal => ConversationError::Internal,
        _ => ConversationError::Synchronization,
    }
}

pub(crate) async fn list() -> Result<Vec<ConversationSummary>, ConversationError> {
    // snapshot libera o mutex antes da rede e mantém apenas o cliente já autenticado.
    let _operation = auth::CLIENT_OPERATIONS.read().await;
    let client = auth::authenticated_client()?;
    let result = snapshot(&client).await;
    // Descarta inclusive falhas antigas se o cliente ativo mudar durante a operação.
    auth::ensure_current(&client)?;
    result
}

async fn snapshot(
    client: &matrix_sdk::Client,
) -> Result<Vec<ConversationSummary>, ConversationError> {
    let mut summaries = Vec::new();
    for room in client
        .joined_rooms()
        .into_iter()
        .chain(client.invited_rooms())
    {
        if room.is_space() {
            continue;
        }
        let item = room_summary(&room).await;
        // O estado pode mudar enquanto o nome é lido do store.
        if matches!(
            room.state(),
            matrix_sdk::RoomState::Joined | matrix_sdk::RoomState::Invited
        ) {
            summaries.push(item);
        }
    }
    summaries.sort_by(|a, b| a.display_name.cmp(&b.display_name).then(a.id.cmp(&b.id)));
    summaries.dedup_by(|a, b| a.id == b.id);
    Ok(summaries)
}

async fn room_summary(room: &matrix_sdk::Room) -> ConversationSummary {
    let name = room.display_name().await.ok().map(|name| name.to_string());
    let mut item = summary(
        room.room_id().to_string(),
        name,
        room.num_unread_messages(),
        room.encryption_state().is_encrypted(),
    );
    item.is_invited = room.state() == matrix_sdk::RoomState::Invited;
    item
}

static ACCEPTING: std::sync::LazyLock<std::sync::Mutex<std::collections::HashSet<String>>> =
    std::sync::LazyLock::new(std::sync::Mutex::default);

struct AcceptReservation(String);
impl AcceptReservation {
    fn acquire(id: String) -> Result<Self, ConversationError> {
        if !ACCEPTING
            .lock()
            .map_err(|_| ConversationError::Internal)?
            .insert(id.clone())
        {
            return Err(ConversationError::Synchronization);
        }
        Ok(Self(id))
    }
}
impl Drop for AcceptReservation {
    fn drop(&mut self) {
        if let Ok(mut rooms) = ACCEPTING.lock() {
            rooms.remove(&self.0);
        }
    }
}

pub(crate) async fn accept(id: String) -> Result<ConversationSummary, ConversationError> {
    // A tarefa finita mantém concessão e reserva mesmo se Flutter cancelar o await.
    tokio::spawn(async move {
        let _operation = auth::CLIENT_OPERATIONS.read().await;
        let client = auth::authenticated_client()?;
        let _reservation = AcceptReservation::acquire(id.clone())?;
        auth::ensure_current(&client)?;
        let result = accept_with_client(&client, &id).await;
        auth::ensure_current(&client)?;
        if result.is_ok() {
            client.sync.invalidate_rooms();
        }
        result
    })
    .await
    .map_err(|_| ConversationError::Internal)?
}

async fn accept_with_client(
    client: &matrix_sdk::Client,
    id: &str,
) -> Result<ConversationSummary, ConversationError> {
    let id = matrix_sdk::ruma::RoomId::parse(id).map_err(|_| ConversationError::Synchronization)?;
    let room = client
        .get_room(&id)
        .ok_or(ConversationError::Synchronization)?;
    match room.state() {
        // Permite reconciliar uma aceitação já confirmada pelo sync após falha de transporte.
        matrix_sdk::RoomState::Joined => {}
        matrix_sdk::RoomState::Invited if !room.is_space() => {
            room.join()
                .await
                .map_err(|error| map_read_error(message_history::map_sdk_error(error)))?;
        }
        _ => return Err(ConversationError::Synchronization),
    }
    let item = room_summary(&room).await;
    if room.state() != matrix_sdk::RoomState::Joined {
        return Err(ConversationError::Synchronization);
    }
    Ok(item)
}

fn summary(
    id: String,
    name: Option<String>,
    unread_message_count: u64,
    is_encrypted: bool,
) -> ConversationSummary {
    let display_name = name
        .filter(|name| !name.trim().is_empty())
        .unwrap_or_else(|| "Sala sem nome".to_owned());
    ConversationSummary {
        id,
        display_name,
        unread_message_count: unread_message_count.try_into().unwrap_or(u32::MAX),
        is_encrypted,
        is_invited: false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    async fn fixture_client(url: &str) -> matrix_sdk::Client {
        use matrix_sdk::{
            ruma::{user_id, RoomId},
            RoomState,
        };
        let client = matrix_sdk::Client::builder()
            .homeserver_url(url)
            .server_versions([matrix_sdk::ruma::api::MatrixVersion::V1_1])
            .request_config(
                matrix_sdk::config::RequestConfig::new()
                    .disable_retry()
                    .timeout(std::time::Duration::from_secs(3)),
            )
            .build()
            .await
            .unwrap();
        let mut changes = matrix_sdk::StateChanges::default();
        for (id, state) in [
            ("!joined:example.org", RoomState::Joined),
            ("!invite:example.org", RoomState::Invited),
            ("!left:example.org", RoomState::Left),
        ] {
            let mut info = matrix_sdk::RoomInfo::new(&RoomId::parse(id).unwrap(), state);
            info.mark_encryption_state_synced();
            if state == RoomState::Invited {
                info.set_encryption_event(Some(
                    serde_json::from_value(serde_json::json!({"algorithm":"m.megolm.v1.aes-sha2"}))
                        .unwrap(),
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
                    access_token: "synthetic-test-token".into(),
                    refresh_token: None,
                },
            })
            .await
            .unwrap();
        client
    }

    // Servidor finito de teste; somente a linha da operação é devolvida, sem cabeçalhos.
    fn join_server(fail: bool) -> (String, std::thread::JoinHandle<String>) {
        use std::io::{Read, Write};
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        listener.set_nonblocking(true).unwrap();
        let task = std::thread::spawn(move || {
            let started = std::time::Instant::now();
            let mut socket = loop {
                match listener.accept() {
                    Ok((socket, _)) => break socket,
                    Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                        assert!(started.elapsed() < std::time::Duration::from_secs(10));
                        std::thread::sleep(std::time::Duration::from_millis(10));
                    }
                    Err(_) => panic!("servidor de teste indisponível"),
                }
            };
            socket
                .set_read_timeout(Some(std::time::Duration::from_secs(3)))
                .unwrap();
            let mut bytes = Vec::new();
            let mut byte = [0];
            while !bytes.ends_with(b"\r\n\r\n") {
                assert!(bytes.len() < 16_384);
                socket.read_exact(&mut byte).unwrap();
                bytes.push(byte[0]);
            }
            let request = String::from_utf8(bytes).unwrap();
            let line = request.lines().next().unwrap().to_owned();
            let length = request
                .lines()
                .find_map(|line| {
                    let (name, value) = line.split_once(':')?;
                    name.eq_ignore_ascii_case("content-length")
                        .then(|| value.trim().parse::<usize>().unwrap())
                })
                .unwrap_or(0);
            let mut body_bytes = vec![0; length];
            socket.read_exact(&mut body_bytes).unwrap();
            let (status, body) = if fail {
                (
                    "403 Forbidden",
                    r#"{"errcode":"M_FORBIDDEN","error":"private remote details"}"#,
                )
            } else {
                ("200 OK", r#"{"room_id":"!invite:example.org"}"#)
            };
            write!(socket, "HTTP/1.1 {status}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len()).unwrap();
            line
        });
        (url, task)
    }

    #[tokio::test]
    async fn sdk_snapshot_separates_invites_and_excludes_left_rooms() {
        let client = fixture_client("https://example.invalid").await;
        let rooms = snapshot(&client).await.unwrap();
        assert_eq!(rooms.len(), 2);
        let invite = rooms.iter().find(|r| r.is_invited).unwrap();
        assert_eq!(invite.id, "!invite:example.org");
        assert!(invite.is_encrypted);
        assert_eq!(
            rooms.iter().find(|r| !r.is_invited).unwrap().id,
            "!joined:example.org"
        );
    }

    #[tokio::test]
    async fn sdk_accept_posts_join_and_updates_membership_without_sync() {
        let (url, server) = join_server(false);
        let client = fixture_client(&url).await;
        let joined = accept_with_client(&client, "!invite:example.org")
            .await
            .unwrap();
        assert_eq!(
            server.join().unwrap(),
            "POST /_matrix/client/v3/rooms/!invite:example.org/join HTTP/1.1"
        );
        assert!(!joined.is_invited);
        assert!(joined.is_encrypted);
        assert!(client.invited_rooms().is_empty());
        assert_eq!(client.joined_rooms().len(), 2);
        assert!(snapshot(&client)
            .await
            .unwrap()
            .iter()
            .all(|r| !r.is_invited));
        // Uma repetição após confirmação não emite outra operação remota.
        assert_eq!(
            accept_with_client(&client, "!invite:example.org")
                .await
                .unwrap(),
            joined
        );
    }

    #[tokio::test]
    async fn sdk_join_failure_keeps_invitation_for_retry() {
        let (url, server) = join_server(true);
        let client = fixture_client(&url).await;
        assert_eq!(
            accept_with_client(&client, "!invite:example.org").await,
            Err(ConversationError::Synchronization)
        );
        assert_eq!(
            server.join().unwrap(),
            "POST /_matrix/client/v3/rooms/!invite:example.org/join HTTP/1.1"
        );
        assert_eq!(client.invited_rooms().len(), 1);
        assert!(snapshot(&client)
            .await
            .unwrap()
            .iter()
            .any(|r| r.is_invited));
    }

    #[tokio::test]
    async fn accept_validates_known_membership_and_authentication() {
        let client = fixture_client("https://example.invalid").await;
        for id in ["invalid", "!unknown:example.org", "!left:example.org"] {
            assert_eq!(
                accept_with_client(&client, id).await,
                Err(ConversationError::Synchronization)
            );
        }
        assert_eq!(
            accept("!invite:example.org".into()).await,
            Err(ConversationError::NotAuthenticated)
        );
    }

    #[test]
    fn accept_reservation_blocks_duplicates_and_releases_for_retry() {
        let reservation = AcceptReservation::acquire("test-invite".into()).unwrap();
        assert!(matches!(
            AcceptReservation::acquire("test-invite".into()),
            Err(ConversationError::Synchronization)
        ));
        let other = AcceptReservation::acquire("other-invite".into()).unwrap();
        drop(reservation);
        assert!(AcceptReservation::acquire("test-invite".into()).is_ok());
        drop(other);
    }

    #[tokio::test]
    async fn read_requires_authentication_without_network() {
        assert_eq!(
            mark_read("!room:example.org").await,
            Err(ConversationError::NotAuthenticated)
        );
    }

    #[test]
    fn read_errors_use_safe_conversation_categories() {
        use crate::api::simple::MessageHistoryError;
        for (error, expected) in [
            (MessageHistoryError::Network, ConversationError::Network),
            (MessageHistoryError::Tls, ConversationError::Tls),
            (
                MessageHistoryError::RateLimited,
                ConversationError::RateLimited,
            ),
            (
                MessageHistoryError::NotAuthenticated,
                ConversationError::NotAuthenticated,
            ),
            (
                MessageHistoryError::InvalidConversationId,
                ConversationError::Synchronization,
            ),
        ] {
            assert_eq!(map_read_error(error), expected);
        }
    }
    #[test]
    fn maps_metadata_without_parsing_identifier_or_remote_markup() {
        let room = summary(
            "opaque fixture / ?".into(),
            Some("<b>Nome remoto</b>".into()),
            7,
            true,
        );
        assert_eq!(room.id, "opaque fixture / ?");
        assert_eq!(room.display_name, "<b>Nome remoto</b>");
        assert_eq!(room.unread_message_count, 7);
        assert!(room.is_encrypted);
        assert!(!summary("opaque".into(), None, 0, false).is_encrypted);
        for name in [None, Some(String::new()), Some(" \n\t".into())] {
            assert_eq!(
                summary("opaque".into(), name, 0, false).display_name,
                "Sala sem nome"
            );
        }
        assert_eq!(
            summary("opaque".into(), None, u64::MAX, false).unread_message_count,
            u32::MAX
        );
    }

    #[test]
    fn unauthenticated_request_finishes_without_network() {
        let mut future = Box::pin(list());
        let mut context = std::task::Context::from_waker(std::task::Waker::noop());
        assert_eq!(
            std::future::Future::poll(future.as_mut(), &mut context),
            std::task::Poll::Ready(Err(ConversationError::NotAuthenticated))
        );
    }
}
