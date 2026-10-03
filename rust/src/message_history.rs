use matrix_sdk::{
    room::MessagesOptions,
    ruma::{
        api::error::ErrorKind,
        events::{
            room::message::MessageType, AnySyncMessageLikeEvent, AnySyncTimelineEvent,
            SyncMessageLikeEvent,
        },
        serde::Raw,
        RoomId, UserId,
    },
    Client, HttpError, Room, RoomState,
};

use crate::{
    api::simple::{ConversationError, LoginError, MessageHistoryError, MessageSummary},
    auth,
};

const HISTORY_LIMIT: usize = 50;

pub(crate) async fn load(id: &str) -> Result<Vec<MessageSummary>, MessageHistoryError> {
    // A mesma concessão de leitura impede fechar/apagar o store enquanto há handles.
    let _operation = auth::CLIENT_OPERATIONS.read().await;
    let client = auth::authenticated_client().map_err(map_auth_error)?;
    let result = async {
        let room = resolve_room(&client, id)?;
        let own_id = client
            .user_id()
            .ok_or(MessageHistoryError::NotAuthenticated)?;
        // E2EE não está habilitado. Unknown deve ser resolvido pelo SDK, nunca virar vazio.
        let encryption = room
            .latest_encryption_state()
            .await
            .map_err(map_sdk_error)?;
        ensure_unencrypted(encryption)?;
        let history = room
            .messages(history_options())
            .await
            .map_err(map_sdk_error)?;
        let messages = map_history(
            history
                .chunk
                .iter()
                .take(HISTORY_LIMIT)
                .map(|event| event.raw()),
            own_id,
        )?;
        // A associação pode ter mudado enquanto a requisição aguardava a rede.
        ensure_joined(room.state())?;
        Ok(messages)
    }
    .await;
    // Inclusive erros antigos são descartados quando logout reserva a autoridade.
    auth::ensure_current(&client).map_err(map_auth_error)?;
    result
}

fn resolve_room(client: &Client, id: &str) -> Result<Room, MessageHistoryError> {
    // Flutter não é uma fronteira confiável: validar novamente antes de consultar o SDK.
    let id = RoomId::parse(id).map_err(|_| MessageHistoryError::InvalidConversationId)?;
    let room = client
        .get_room(&id)
        .ok_or(MessageHistoryError::ConversationNotFound)?;
    ensure_joined(room.state())?;
    Ok(room)
}

fn ensure_joined(state: RoomState) -> Result<(), MessageHistoryError> {
    if state == RoomState::Joined {
        Ok(())
    } else {
        Err(MessageHistoryError::ConversationNotJoined)
    }
}

fn ensure_unencrypted(state: matrix_sdk::EncryptionState) -> Result<(), MessageHistoryError> {
    if state.is_encrypted() {
        Err(MessageHistoryError::EncryptionUnsupported)
    } else if state.is_unknown() {
        Err(MessageHistoryError::History)
    } else {
        Ok(())
    }
}

fn history_options() -> MessagesOptions {
    // O limite pertence à aplicação; from/to ausentes iniciam no fim visível, sem paginação.
    let mut options = MessagesOptions::backward();
    options.limit = matrix_sdk::ruma::uint!(50);
    options
}

fn map_history<'a>(
    events: impl IntoIterator<Item = &'a Raw<AnySyncTimelineEvent>>,
    own_id: &UserId,
) -> Result<Vec<MessageSummary>, MessageHistoryError> {
    let mut messages = Vec::new();
    for raw in events {
        // Mesmo um evento cifrado malformado não pode produzir um falso histórico vazio.
        if raw.get_field::<String>("type").ok().flatten().as_deref() == Some("m.room.encrypted") {
            return Err(MessageHistoryError::EncryptionUnsupported);
        }
        // Eventos malformados, redigidos e tipos não suportados são descartados individualmente.
        if let Ok(AnySyncTimelineEvent::MessageLike(AnySyncMessageLikeEvent::RoomMessage(
            SyncMessageLikeEvent::Original(event),
        ))) = raw.deserialize()
        {
            let body = match event.content.msgtype {
                MessageType::Text(content) => content.body,
                MessageType::Notice(content) => content.body,
                MessageType::Emote(content) => content.body,
                _ => continue,
            };
            let timestamp_ms = i64::from(event.origin_server_ts.0);
            messages.push(MessageSummary {
                id: event.event_id.to_string(),
                sender_id: event.sender.to_string(),
                body,
                timestamp_ms,
                is_own: event.sender == own_id,
            });
        }
    }
    // /messages backward vem em ordem inversa da timeline; inverter preserva essa ordem,
    // inclusive quando relógios dos remetentes produzem timestamps iguais ou divergentes.
    messages.reverse();
    let mut seen = std::collections::HashSet::new();
    messages.retain(|message| seen.insert(message.id.clone()));
    Ok(messages)
}

fn map_auth_error(error: ConversationError) -> MessageHistoryError {
    match error {
        ConversationError::NotAuthenticated => MessageHistoryError::NotAuthenticated,
        _ => MessageHistoryError::Internal,
    }
}

fn map_sdk_error(error: matrix_sdk::Error) -> MessageHistoryError {
    match error {
        matrix_sdk::Error::AuthenticationRequired => MessageHistoryError::NotAuthenticated,
        matrix_sdk::Error::Http(error) => map_http_error(&error),
        _ => MessageHistoryError::History,
    }
}

fn map_http_error(error: &HttpError) -> MessageHistoryError {
    if let HttpError::Cached(error) = error {
        return map_http_error(error);
    }
    if matches!(
        error.client_api_error_kind(),
        Some(ErrorKind::MissingToken | ErrorKind::UnknownToken(_))
    ) {
        return MessageHistoryError::NotAuthenticated;
    }
    match auth::map_http_error_ref(error, false) {
        LoginError::Network => MessageHistoryError::Network,
        LoginError::Tls => MessageHistoryError::Tls,
        LoginError::RateLimited => MessageHistoryError::RateLimited,
        LoginError::UnusableHomeserver => MessageHistoryError::History,
        _ => MessageHistoryError::Internal,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use matrix_sdk::ruma::{
        api::{
            client::uiaa::UiaaResponse,
            error::{ErrorBody, FromHttpResponseError, LimitExceededErrorData, StandardErrorBody},
        },
        user_id,
    };
    use serde_json::json;

    fn event(
        id: &str,
        sender: &str,
        msgtype: &str,
        body: &str,
        timestamp: u64,
    ) -> Raw<AnySyncTimelineEvent> {
        Raw::from_json_string(
            json!({
                "type": "m.room.message", "event_id": id, "sender": sender,
                "origin_server_ts": timestamp, "content": {"msgtype": msgtype, "body": body}
            })
            .to_string(),
        )
        .unwrap()
    }

    #[test]
    fn bound_and_direction_belong_to_application() {
        let options = history_options();
        assert_eq!(
            usize::try_from(u64::from(options.limit)).unwrap(),
            HISTORY_LIMIT
        );
        assert_eq!(options.dir, matrix_sdk::ruma::api::Direction::Backward);
        assert!(options.from.is_none() && options.to.is_none());
    }

    #[test]
    fn maps_stable_identity_plain_body_ownership_and_timeline_order() {
        let own = user_id!("@me:example.org");
        let events = [
            event("$new", own.as_str(), "m.emote", "ação", 3000),
            event("$notice", "@other:example.org", "m.notice", "aviso", 2000),
            event(
                "$old",
                own.as_str(),
                "m.text",
                "<script>alert('x')</script>",
                1000,
            ),
        ];
        let mapped = map_history(&events, own).unwrap();
        assert_eq!(
            mapped.iter().map(|m| m.id.as_str()).collect::<Vec<_>>(),
            ["$old", "$notice", "$new"]
        );
        assert_eq!(mapped[0].sender_id, own.as_str());
        assert_eq!(mapped[0].timestamp_ms, 1000);
        assert_eq!(mapped[0].body, "<script>alert('x')</script>");
        assert!(mapped[0].is_own && mapped[2].is_own && !mapped[1].is_own);
    }

    #[test]
    fn skips_invalid_unsupported_and_redacted_events_and_deduplicates() {
        let own = user_id!("@me:example.org");
        let malformed = Raw::from_json_string("{}".into()).unwrap();
        let redacted = Raw::from_json_string(
            json!({
                "type":"m.room.message", "event_id":"$redacted", "sender":own,
                "origin_server_ts": 12, "content": {},
                "unsigned":{"redacted_because":{"type":"m.room.redaction"}}
            })
            .to_string(),
        )
        .unwrap();
        let missing_id = Raw::from_json_string(
            json!({
                "type":"m.room.message", "sender":own, "origin_server_ts":12,
                "content":{"msgtype":"m.text", "body":"sem id"}
            })
            .to_string(),
        )
        .unwrap();
        let events = [
            malformed,
            redacted,
            missing_id,
            event("$file", own.as_str(), "m.file", "arquivo", 3),
            event("$ok", own.as_str(), "m.text", "mensagem", 2),
            event("$ok", own.as_str(), "m.text", "mensagem", 2),
        ];
        let mapped = map_history(&events, own).unwrap();
        assert_eq!(mapped.len(), 1);
        assert_eq!(mapped[0].id, "$ok");
    }

    #[test]
    fn encrypted_even_malformed_events_never_become_empty_history() {
        assert_eq!(
            ensure_unencrypted(matrix_sdk::EncryptionState::Encrypted),
            Err(MessageHistoryError::EncryptionUnsupported)
        );
        assert_eq!(
            ensure_unencrypted(matrix_sdk::EncryptionState::Unknown),
            Err(MessageHistoryError::History)
        );
        assert_eq!(
            ensure_unencrypted(matrix_sdk::EncryptionState::NotEncrypted),
            Ok(())
        );
        let encrypted =
            Raw::from_json_string(r#"{"type":"m.room.encrypted","content":{}}"#.into()).unwrap();
        assert_eq!(
            map_history([&encrypted], user_id!("@me:example.org")),
            Err(MessageHistoryError::EncryptionUnsupported)
        );
        assert!(map_history([], user_id!("@me:example.org"))
            .unwrap()
            .is_empty());
    }

    #[tokio::test]
    async fn validates_identifier_and_unknown_room_without_network() {
        let client = Client::builder()
            .homeserver_url("https://example.invalid")
            .build()
            .await
            .unwrap();
        assert!(matches!(
            resolve_room(&client, "not a room"),
            Err(MessageHistoryError::InvalidConversationId)
        ));
        assert!(matches!(
            resolve_room(&client, "!unknown:example.org"),
            Err(MessageHistoryError::ConversationNotFound)
        ));
        let mut changes = matrix_sdk::StateChanges::default();
        for (id, state) in [
            ("!joined:example.org", RoomState::Joined),
            ("!left:example.org", RoomState::Left),
        ] {
            let id = RoomId::parse(id).unwrap();
            changes.add_room(matrix_sdk::RoomInfo::new(&id, state));
        }
        client.state_store().save_changes(&changes).await.unwrap();
        client
            .restore_session(matrix_sdk::authentication::matrix::MatrixSession {
                meta: matrix_sdk::SessionMeta {
                    user_id: user_id!("@me:example.org").to_owned(),
                    device_id: "SYNTHETIC_DEVICE".into(),
                },
                tokens: matrix_sdk::SessionTokens {
                    access_token: "synthetic-token-never-sent".into(),
                    refresh_token: None,
                },
            })
            .await
            .unwrap();
        assert!(resolve_room(&client, "!joined:example.org").is_ok());
        assert!(matches!(
            resolve_room(&client, "!left:example.org"),
            Err(MessageHistoryError::ConversationNotJoined)
        ));
        assert_eq!(ensure_joined(RoomState::Joined), Ok(()));
        for state in [
            RoomState::Left,
            RoomState::Invited,
            RoomState::Knocked,
            RoomState::Banned,
        ] {
            assert_eq!(
                ensure_joined(state),
                Err(MessageHistoryError::ConversationNotJoined)
            );
        }
        assert_eq!(
            load("!room:example.org").await,
            Err(MessageHistoryError::NotAuthenticated)
        );
    }

    #[test]
    fn errors_are_fixed_categories_including_cached_http_errors() {
        for (kind, expected) in [
            (
                ErrorKind::MissingToken,
                MessageHistoryError::NotAuthenticated,
            ),
            (
                ErrorKind::LimitExceeded(LimitExceededErrorData::new()),
                MessageHistoryError::RateLimited,
            ),
            (ErrorKind::Forbidden, MessageHistoryError::History),
            (ErrorKind::Unknown, MessageHistoryError::History),
        ] {
            let body = ErrorBody::Standard(StandardErrorBody::new(
                kind,
                "detalhe remoto privado".into(),
            ));
            let error = HttpError::Api(Box::new(FromHttpResponseError::Server(
                UiaaResponse::MatrixError(
                    body.into_error(matrix_sdk::reqwest::StatusCode::BAD_REQUEST),
                ),
            )));
            assert_eq!(map_http_error(&error), expected);
            assert_eq!(
                map_http_error(&HttpError::Cached(std::sync::Arc::new(error))),
                expected
            );
        }
        assert_eq!(
            map_sdk_error(matrix_sdk::Error::AuthenticationRequired),
            MessageHistoryError::NotAuthenticated
        );
        assert_eq!(
            map_auth_error(ConversationError::Internal),
            MessageHistoryError::Internal
        );
    }
}
