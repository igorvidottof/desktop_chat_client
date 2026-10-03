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
    SecureStorage,
    Persistence,
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

/// Resumo de apresentação; o identificador é opaco para Flutter, sem tipos Matrix.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConversationSummary {
    pub id: String,
    pub display_name: String,
}

/// Categorias seguras, sem respostas do servidor nem segredos da sessão.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ConversationError {
    NotAuthenticated,
    Network,
    Tls,
    RateLimited,
    Synchronization,
    Internal,
}

/// Sincroniza uma única vez e retorna somente salas ingressadas que não são espaços.
pub async fn list_conversations() -> Result<Vec<ConversationSummary>, ConversationError> {
    crate::conversations::list().await
}

/// Estado seguro: nenhum token, DTO do SDK ou chave pode atravessar FRB.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SessionState {
    pub account: Option<AccountSummary>,
}

/// Falhas locais e remotas classificadas sem conteúdo de arquivos ou do cofre.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SessionError {
    OperationInProgress,
    Network,
    Tls,
    InvalidSession,
    CorruptedSession,
    SecureStorage,
    Persistence,
    Internal,
}

/// Consulta primeiro a autoridade em memória, inclusive após hot restart do Dart.
pub async fn initialize_session() -> Result<SessionState, SessionError> {
    crate::auth::initialize().await
}
