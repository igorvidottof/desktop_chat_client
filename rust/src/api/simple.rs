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

/// Projeção pública da conta; a sessão e seus segredos permanecem no SDK em Rust.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AccountSummary {
    pub user_id: String,
    pub device_id: String,
    pub homeserver_address: String,
}

/// Falhas estáveis sem mensagens, respostas ou objetos de autenticação do SDK.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LoginError {
    InvalidServerAddress,
    InvalidInput,
    PasswordLoginUnsupported,
    InvalidCredentials,
    Network,
    Tls,
    RateLimited,
    AlreadyAuthenticated,
    LoginInProgress,
    UnusableHomeserver,
    Internal,
}

/// A senha atravessa a ponte somente nesta direção e não integra o estado da conta.
pub async fn login(
    homeserver_address: String,
    username: String,
    password: String,
) -> Result<AccountSummary, LoginError> {
    crate::auth::login(&homeserver_address, &username, password).await
}
