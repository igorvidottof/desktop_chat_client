use crate::{
    api::simple::{ConversationError, ConversationSummary},
    auth,
};

pub(crate) async fn list() -> Result<Vec<ConversationSummary>, ConversationError> {
    // snapshot libera o mutex antes da rede e mantém apenas o cliente já autenticado.
    let _operation = auth::CLIENT_OPERATIONS.read().await;
    let client = auth::authenticated_client()?;
    let result = async {
        let mut summaries = Vec::new();
        for room in client.joined_rooms() {
            // O SDK identifica espaços pelo estado de criação já recebido no sync.
            if room.is_space() {
                continue;
            }
            // Room e eventos permanecem em Rust. display_name consulta o armazenamento
            // do SDK; metadados incompletos não devem invalidar as demais salas.
            let name = room.display_name().await.ok().map(|name| name.to_string());
            summaries.push(summary(
                room.room_id().to_string(),
                name,
                room.num_unread_messages(),
            ));
        }
        summaries.sort_by(|a, b| a.display_name.cmp(&b.display_name).then(a.id.cmp(&b.id)));
        Ok(summaries)
    }
    .await;
    // Descarta inclusive falhas antigas se o cliente ativo mudar durante a operação.
    auth::ensure_current(&client)?;
    result
}

fn summary(id: String, name: Option<String>, unread_message_count: u64) -> ConversationSummary {
    let display_name = name
        .filter(|name| !name.trim().is_empty())
        .unwrap_or_else(|| "Sala sem nome".to_owned());
    ConversationSummary {
        id,
        display_name,
        unread_message_count: unread_message_count.try_into().unwrap_or(u32::MAX),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn maps_metadata_without_parsing_identifier_or_remote_markup() {
        let room = summary(
            "opaque fixture / ?".into(),
            Some("<b>Nome remoto</b>".into()),
            7,
        );
        assert_eq!(room.id, "opaque fixture / ?");
        assert_eq!(room.display_name, "<b>Nome remoto</b>");
        assert_eq!(room.unread_message_count, 7);
        for name in [None, Some(String::new()), Some(" \n\t".into())] {
            assert_eq!(
                summary("opaque".into(), name, 0).display_name,
                "Sala sem nome"
            );
        }
        assert_eq!(
            summary("opaque".into(), None, u64::MAX).unread_message_count,
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
