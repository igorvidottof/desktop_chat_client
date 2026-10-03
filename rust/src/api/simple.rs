/// Informações da aplicação obtidas somente após uma resposta Matrix válida.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ServerInfo {
    pub server_address: String,
    pub supports_password_login: bool,
}

/// Categorias estáveis; detalhes do SDK e do servidor não atravessam a ponte.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProbeError {
    InvalidServerAddress,
    Network,
    Tls,
    UnusableHomeserver,
    Internal,
}

/// Consulta os métodos de acesso sem autenticar ou reter um cliente global.
pub async fn probe_server(address: String) -> Result<ServerInfo, ProbeError> {
    crate::matrix::probe(&address).await
}
