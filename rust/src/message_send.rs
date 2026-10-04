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
        // Sem E2EE, o SDK envia plaintext: esta barreira independente é obrigatória.
        let encryption = room
            .latest_encryption_state()
            .await
            .map_err(map_sdk_error)?;
        message_history::ensure_unencrypted(encryption).map_err(map_history_error)?;
        message_history::ensure_joined(room.state()).map_err(map_history_error)?;
        auth::ensure_current(&client).map_err(map_auth_error)?;
        let response = room
            .send(content)
            .with_request_config(RequestConfig::new().disable_retry())
            .await
            .map_err(map_sdk_error)?;
        // Só o servidor determina o ID. A resposta não contém timestamp autoritativo;
        // Flutter recarrega /messages uma vez; sync posterior é conciliado pelo event ID.
        Ok(SendMessageResult {
            event_id: response.response.event_id.to_string(),
        })
    }
    .await;
    // Logout revoga autoridade antes de aguardar a concessão. Até erros antigos
    // são descartados; um envio remoto aceito pode ter ocorrido apesar desta falha.
    auth::ensure_current(&client).map_err(map_auth_error)?;
    result
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
        for (error, expected) in [
            (MessageHistoryError::Network, SendMessageError::Network),
            (MessageHistoryError::Tls, SendMessageError::Tls),
            (MessageHistoryError::Internal, SendMessageError::Internal),
        ] {
            assert_eq!(map_history_error(error), expected);
        }
    }
}
