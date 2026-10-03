use matrix_sdk::{config::SyncSettings, ruma::api::error::ErrorKind, HttpError};

use crate::{
    api::simple::{ConversationError, ConversationSummary, LoginError},
    auth,
};

pub(crate) async fn list() -> Result<Vec<ConversationSummary>, ConversationError> {
    // snapshot libera o mutex antes da rede e mantém apenas o cliente já autenticado.
    let client = auth::authenticated_client()?;
    let result = async {
        // joined_rooms só conhece o estado recebido. Um sync único preenche esse
        // estado; não instalamos loop, stream, tarefas ou assinaturas de eventos.
        client
            .sync_once(SyncSettings::default())
            .await
            .map_err(map_sdk_error)?;
        let mut summaries = Vec::new();
        for room in client.joined_rooms() {
            // O SDK identifica espaços pelo estado de criação já recebido no sync.
            if room.is_space() {
                continue;
            }
            // Room e eventos permanecem em Rust. display_name consulta o armazenamento
            // do SDK; metadados incompletos não devem invalidar as demais salas.
            let name = room.display_name().await.ok().map(|name| name.to_string());
            summaries.push(summary(room.room_id().to_string(), name));
        }
        summaries.sort_by(|a, b| a.display_name.cmp(&b.display_name).then(a.id.cmp(&b.id)));
        Ok(summaries)
    }
    .await;
    // Descarta inclusive falhas antigas se o cliente ativo mudar durante a operação.
    auth::ensure_current(&client)?;
    result
}

fn summary(id: String, name: Option<String>) -> ConversationSummary {
    let display_name = name
        .filter(|name| !name.trim().is_empty())
        .unwrap_or_else(|| "Sala sem nome".to_owned());
    ConversationSummary { id, display_name }
}

fn map_sdk_error(error: matrix_sdk::Error) -> ConversationError {
    match error {
        matrix_sdk::Error::AuthenticationRequired => ConversationError::NotAuthenticated,
        matrix_sdk::Error::Http(error) => map_http_error(&error),
        _ => ConversationError::Internal,
    }
}

fn map_http_error(error: &HttpError) -> ConversationError {
    if let HttpError::Cached(error) = error {
        return map_http_error(error);
    }
    if let Some(ErrorKind::MissingToken | ErrorKind::UnknownToken(_)) =
        error.client_api_error_kind()
    {
        return ConversationError::NotAuthenticated;
    }
    // Reutiliza a classificação de transporte existente, sem tratar 403 como senha inválida.
    match auth::map_http_error_ref(error, false) {
        LoginError::Network => ConversationError::Network,
        LoginError::Tls => ConversationError::Tls,
        LoginError::RateLimited => ConversationError::RateLimited,
        LoginError::UnusableHomeserver => ConversationError::Synchronization,
        _ => ConversationError::Internal,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use matrix_sdk::ruma::api::{
        client::uiaa::UiaaResponse,
        error::{
            ErrorBody, FromHttpResponseError, LimitExceededErrorData, StandardErrorBody,
            UnknownTokenErrorData,
        },
    };

    #[test]
    fn maps_metadata_without_parsing_identifier_or_remote_markup() {
        let room = summary(
            "opaque fixture / ?".into(),
            Some("<b>Nome remoto</b>".into()),
        );
        assert_eq!(room.id, "opaque fixture / ?");
        assert_eq!(room.display_name, "<b>Nome remoto</b>");
        for name in [None, Some(String::new()), Some(" \n\t".into())] {
            assert_eq!(summary("opaque".into(), name).display_name, "Sala sem nome");
        }
    }

    fn api_error(kind: ErrorKind) -> HttpError {
        let body = ErrorBody::Standard(StandardErrorBody::new(
            kind,
            "untrusted server detail".into(),
        ));
        HttpError::Api(Box::new(FromHttpResponseError::Server(
            UiaaResponse::MatrixError(
                body.into_error(matrix_sdk::reqwest::StatusCode::BAD_REQUEST),
            ),
        )))
    }

    #[test]
    fn maps_safe_sync_categories_including_cached_errors() {
        for (kind, expected) in [
            (ErrorKind::MissingToken, ConversationError::NotAuthenticated),
            (
                ErrorKind::UnknownToken(UnknownTokenErrorData::new()),
                ConversationError::NotAuthenticated,
            ),
            (
                ErrorKind::LimitExceeded(LimitExceededErrorData::new()),
                ConversationError::RateLimited,
            ),
            (ErrorKind::Forbidden, ConversationError::Synchronization),
            (ErrorKind::Unknown, ConversationError::Synchronization),
        ] {
            let error = api_error(kind);
            assert_eq!(map_http_error(&error), expected);
            assert_eq!(
                map_http_error(&HttpError::Cached(std::sync::Arc::new(error))),
                expected
            );
        }
        assert_eq!(
            map_sdk_error(matrix_sdk::Error::AuthenticationRequired),
            ConversationError::NotAuthenticated
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
