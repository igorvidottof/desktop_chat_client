use std::{
    collections::HashSet,
    sync::{LazyLock, Mutex},
};

use matrix_sdk::{config::RequestConfig, ruma::events::room::message::RoomMessageEventContent};

use crate::{
    api::simple::{ConversationError, MessageHistoryError, SendMessageError, SendMessageResult},
    auth, message_history,
};

// Conta valores escalares Unicode (chars), não bytes nem grafemas. Texto válido
// permanece literal, inclusive espaços, quebras de linha e conteúdo parecido com HTML.
const MAX_MESSAGE_CHARS: usize = 10_000;
static SENDING_ROOMS: LazyLock<Mutex<HashSet<String>>> = LazyLock::new(Mutex::default);

struct SendReservation(String);

impl SendReservation {
    fn acquire(id: String) -> Result<Self, SendMessageError> {
        let mut rooms = SENDING_ROOMS
            .lock()
            .map_err(|_| SendMessageError::Internal)?;
        if !rooms.insert(id.clone()) {
            return Err(SendMessageError::SendInProgress);
        }
        Ok(Self(id))
    }
}

impl Drop for SendReservation {
    fn drop(&mut self) {
        if let Ok(mut rooms) = SENDING_ROOMS.lock() {
            rooms.remove(&self.0);
        }
    }
}

pub(crate) async fn send(id: String, body: String) -> Result<SendMessageResult, SendMessageError> {
    // Cancelar Flutter não desfaz envio aceito pelo servidor. Esta tarefa finita
    // mantém a concessão e a reserva até concluir; nunca repete um envio incerto.
    tokio::spawn(send_reserved(id, body))
        .await
        .map_err(|_| SendMessageError::Internal)?
}

async fn send_reserved(id: String, body: String) -> Result<SendMessageResult, SendMessageError> {
    let _operation = auth::CLIENT_OPERATIONS.read().await;
    let client = auth::authenticated_client().map_err(map_auth_error)?;
    let result = async {
        let content = plain_content(body)?;
        // Compartilha a validação do histórico: o ID recebido continua não confiável.
        let room = message_history::resolve_room(&client, &id).map_err(map_history_error)?;
        let _reservation = SendReservation::acquire(room.room_id().to_string())?;
        // Room::send owns encryption initialization, key sharing and encryption.
        message_history::ensure_joined(room.state()).map_err(map_history_error)?;
        auth::ensure_current(&client).map_err(map_auth_error)?;
        send_room(&room, content).await
    }
    .await;
    // Logout revoga autoridade antes de aguardar a concessão. Até erros antigos
    // são descartados; um envio remoto aceito pode ter ocorrido apesar desta falha.
    auth::ensure_current(&client).map_err(map_auth_error)?;
    result
}

async fn send_room(
    room: &matrix_sdk::Room,
    content: RoomMessageEventContent,
) -> Result<SendMessageResult, SendMessageError> {
    let response = room
        .send(content)
        .with_request_config(RequestConfig::new().disable_retry())
        .await
        .map_err(map_sdk_error)?;
    // Only the server determines the ID. No authoritative timestamp is returned.
    Ok(SendMessageResult {
        event_id: response.response.event_id.to_string(),
    })
}

fn plain_content(body: String) -> Result<RoomMessageEventContent, SendMessageError> {
    if body.trim().is_empty() {
        return Err(SendMessageError::EmptyMessage);
    }
    if body.chars().take(MAX_MESSAGE_CHARS + 1).count() > MAX_MESSAGE_CHARS {
        return Err(SendMessageError::MessageTooLong);
    }
    Ok(RoomMessageEventContent::text_plain(body))
}

fn map_auth_error(error: ConversationError) -> SendMessageError {
    match error {
        ConversationError::NotAuthenticated => SendMessageError::NotAuthenticated,
        _ => SendMessageError::Internal,
    }
}

fn map_sdk_error(error: matrix_sdk::Error) -> SendMessageError {
    map_history_error(message_history::map_sdk_error(error))
}

fn map_history_error(error: MessageHistoryError) -> SendMessageError {
    match error {
        MessageHistoryError::NotAuthenticated => SendMessageError::NotAuthenticated,
        MessageHistoryError::InvalidConversationId => SendMessageError::InvalidConversationId,
        MessageHistoryError::ConversationNotFound => SendMessageError::ConversationNotFound,
        MessageHistoryError::ConversationNotJoined => SendMessageError::ConversationNotJoined,
        MessageHistoryError::EncryptionUnsupported => SendMessageError::EncryptionUnsupported,
        MessageHistoryError::Network => SendMessageError::Network,
        MessageHistoryError::Tls => SendMessageError::Tls,
        MessageHistoryError::RateLimited => SendMessageError::RateLimited,
        MessageHistoryError::History => SendMessageError::Send,
        MessageHistoryError::Internal => SendMessageError::Internal,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use matrix_sdk::ruma::{
        api::{
            client::uiaa::UiaaResponse,
            error::{
                ErrorBody, ErrorKind, FromHttpResponseError, LimitExceededErrorData,
                StandardErrorBody,
            },
        },
        events::{room::message::MessageType, MessageLikeEventContent},
    };

    // Minimal local HTTP fixture: exercise Room::send and Room::messages with
    // real SDK encryption/decryption, without credentials or a live homeserver.
    struct Homeserver {
        url: String,
        sent: std::sync::Arc<Mutex<Vec<(String, serde_json::Value)>>>,
        stopped: std::sync::Arc<std::sync::atomic::AtomicBool>,
        thread: Option<std::thread::JoinHandle<()>>,
    }

    impl Homeserver {
        fn new() -> Self {
            use std::io::{BufRead, Read, Write};
            let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
            let url = format!("http://{}", listener.local_addr().unwrap());
            listener.set_nonblocking(true).unwrap();
            let stopped = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
            let sent = std::sync::Arc::new(Mutex::new(Vec::<(String, serde_json::Value)>::new()));
            let stop = stopped.clone();
            let records = sent.clone();
            let thread = std::thread::spawn(move || {
                while !stop.load(std::sync::atomic::Ordering::SeqCst) {
                    let (mut stream, _) = match listener.accept() {
                        Ok(connection) => connection,
                        Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                            std::thread::sleep(std::time::Duration::from_millis(2));
                            continue;
                        }
                        Err(error) => panic!("local fixture accept: {error}"),
                    };
                    // macOS accepted sockets inherit the listener's nonblocking flag.
                    stream.set_nonblocking(false).unwrap();
                    stream
                        .set_read_timeout(Some(std::time::Duration::from_secs(5)))
                        .unwrap();
                    let mut reader = std::io::BufReader::new(stream.try_clone().unwrap());
                    let mut request = String::new();
                    reader.read_line(&mut request).unwrap();
                    let path = request.split_whitespace().nth(1).unwrap();
                    let mut length = 0;
                    loop {
                        let mut header = String::new();
                        reader.read_line(&mut header).unwrap();
                        if header == "\r\n" {
                            break;
                        }
                        if let Some(value) = header.to_lowercase().strip_prefix("content-length:") {
                            length = value.trim().parse::<usize>().unwrap();
                        }
                    }
                    let mut body = vec![0; length];
                    reader.read_exact(&mut body).unwrap();
                    let body: serde_json::Value = if body.is_empty() {
                        serde_json::json!({})
                    } else {
                        serde_json::from_slice(&body).unwrap()
                    };
                    let response = if path.contains("/send/") {
                        records.lock().unwrap().push((path.to_string(), body));
                        serde_json::json!({"event_id":"$accepted"})
                    } else if path.contains("/messages") {
                        let mut event = records.lock().unwrap().last().unwrap().1.clone();
                        event = serde_json::json!({"type": if event.get("ciphertext").is_some() { "m.room.encrypted" } else { "m.room.message" }, "content":event,
                            "event_id":"$accepted", "sender":"@me:example.org", "origin_server_ts":1234,
                            "room_id":"!room:example.org"});
                        serde_json::json!({"start":"start", "end":"end", "chunk":[event], "state":[]})
                    } else if path.contains("/keys/query") {
                        serde_json::json!({"device_keys":{}, "failures":{}})
                    } else if path.contains("/keys/claim") {
                        serde_json::json!({"one_time_keys":{}, "failures":{}})
                    } else if path.contains("/keys/upload") {
                        serde_json::json!({"one_time_key_counts":{}})
                    } else if path.contains("/versions") {
                        serde_json::json!({"versions":["v1.11"]})
                    } else {
                        serde_json::json!({})
                    };
                    let body = response.to_string();
                    write!(stream, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}", body.len(), body).unwrap();
                }
            });
            Self {
                url,
                sent,
                stopped,
                thread: Some(thread),
            }
        }
    }

    impl Drop for Homeserver {
        fn drop(&mut self) {
            self.stopped
                .store(true, std::sync::atomic::Ordering::SeqCst);
            self.thread.take().unwrap().join().unwrap();
        }
    }

    #[tokio::test]
    async fn sdk_send_encrypts_only_encrypted_rooms_and_history_decrypts_the_accepted_event() {
        use matrix_sdk::ruma::{room_id, user_id};
        for encrypted in [false, true] {
            let server = Homeserver::new();
            let client = matrix_sdk::Client::builder()
                .homeserver_url(&server.url)
                .build()
                .await
                .unwrap();
            let id = room_id!("!room:example.org");
            let mut info = matrix_sdk::RoomInfo::new(id, matrix_sdk::RoomState::Joined);
            info.mark_encryption_state_synced();
            info.mark_members_synced();
            if encrypted {
                info.set_encryption_event(Some(
                    serde_json::from_value(serde_json::json!({"algorithm":"m.megolm.v1.aes-sha2"}))
                        .unwrap(),
                ));
            }
            let mut changes = matrix_sdk::StateChanges::default();
            changes.add_room(info);
            client.state_store().save_changes(&changes).await.unwrap();
            client
                .restore_session(matrix_sdk::authentication::matrix::MatrixSession {
                    meta: matrix_sdk::SessionMeta {
                        user_id: user_id!("@me:example.org").to_owned(),
                        device_id: "LOCAL_TEST".into(),
                    },
                    tokens: matrix_sdk::SessionTokens {
                        access_token: "synthetic-local-token".into(),
                        refresh_token: None,
                    },
                })
                .await
                .unwrap();
            let room = client.get_room(id).unwrap();
            let result = tokio::time::timeout(
                std::time::Duration::from_secs(10),
                send_room(&room, plain_content("SDK text".into()).unwrap()),
            )
            .await
            .unwrap()
            .unwrap();
            assert_eq!(result.event_id, "$accepted");
            {
                let sent = server.sent.lock().unwrap();
                assert_eq!(sent.len(), 1);
                if encrypted {
                    assert!(sent[0].0.contains("m.room.encrypted"));
                    assert_eq!(sent[0].1["algorithm"], "m.megolm.v1.aes-sha2");
                    assert!(sent[0].1.get("body").is_none());
                    assert!(!sent[0].1.to_string().contains("SDK text"));
                } else {
                    assert!(sent[0].0.contains("m.room.message"));
                    assert_eq!(sent[0].1["body"], "SDK text");
                }
            }
            let history = room
                .messages(matrix_sdk::room::MessagesOptions::backward())
                .await
                .unwrap();
            assert_eq!(history.chunk.len(), 1);
            assert_eq!(
                matches!(
                    history.chunk[0].kind,
                    matrix_sdk::deserialized_responses::TimelineEventKind::Decrypted(_)
                ),
                encrypted
            );
            let message =
                message_history::map_message(history.chunk[0].raw(), user_id!("@me:example.org"))
                    .unwrap();
            assert_eq!(message.body, "SDK text");
            assert_eq!(message.id, result.event_id);
            assert_eq!(message.timestamp_ms, 1234);
            assert_eq!(message.sender_id, "@me:example.org");
            assert!(message.is_own);
        }
    }

    #[test]
    fn validates_unicode_bound_and_preserves_literal_content() {
        for body in ["", " \n\t", "\u{2003}"] {
            assert_eq!(
                plain_content(body.into()).unwrap_err(),
                SendMessageError::EmptyMessage
            );
        }
        for body in [
            "  hello  ",
            "first\nsecond",
            "<script>alert('test')</script>",
            &"🦀".repeat(MAX_MESSAGE_CHARS),
        ] {
            let content = plain_content(body.into()).unwrap();
            assert_eq!(content.event_type().to_string(), "m.room.message");
            match content.msgtype {
                MessageType::Text(text) => {
                    assert_eq!(text.body, body);
                    assert!(text.formatted.is_none());
                }
                _ => panic!("tipo inesperado"),
            }
        }
        for body in [
            "a".repeat(MAX_MESSAGE_CHARS + 1),
            "🦀".repeat(MAX_MESSAGE_CHARS + 1),
        ] {
            assert_eq!(
                plain_content(body).unwrap_err(),
                SendMessageError::MessageTooLong
            );
        }
    }

    #[test]
    fn per_room_reservation_releases_on_drop_without_blocking_other_rooms() {
        let first = SendReservation::acquire("!reservation-a:example.org".into()).unwrap();
        assert!(matches!(
            SendReservation::acquire(first.0.clone()),
            Err(SendMessageError::SendInProgress)
        ));
        let other = SendReservation::acquire("!reservation-b:example.org".into()).unwrap();
        drop(first);
        assert!(SendReservation::acquire("!reservation-a:example.org".into()).is_ok());
        drop(other);
    }

    #[tokio::test]
    async fn unauthenticated_send_does_not_touch_network() {
        assert_eq!(
            send("!unknown:example.org".into(), "test".into()).await,
            Err(SendMessageError::NotAuthenticated)
        );
    }

    #[test]
    fn safe_error_mapping_does_not_expose_remote_details() {
        for (kind, expected) in [
            (ErrorKind::MissingToken, SendMessageError::NotAuthenticated),
            (
                ErrorKind::LimitExceeded(LimitExceededErrorData::new()),
                SendMessageError::RateLimited,
            ),
            (ErrorKind::Forbidden, SendMessageError::Send),
            (ErrorKind::Unknown, SendMessageError::Send),
        ] {
            let body = ErrorBody::Standard(StandardErrorBody::new(kind, "detalhe privado".into()));
            let error = matrix_sdk::HttpError::Api(Box::new(FromHttpResponseError::Server(
                UiaaResponse::MatrixError(
                    body.into_error(matrix_sdk::reqwest::StatusCode::BAD_REQUEST),
                ),
            )));
            assert_eq!(
                map_sdk_error(matrix_sdk::Error::Http(Box::new(error))),
                expected
            );
        }
        assert_eq!(
            map_sdk_error(matrix_sdk::Error::NoOlmMachine),
            SendMessageError::Send
        );
        for (error, expected) in [
            (MessageHistoryError::Network, SendMessageError::Network),
            (MessageHistoryError::Tls, SendMessageError::Tls),
            (MessageHistoryError::Internal, SendMessageError::Internal),
        ] {
            assert_eq!(map_history_error(error), expected);
        }
    }
}
