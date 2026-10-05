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
#[flutter_rust_bridge::frb]
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConversationSummary {
    pub id: String,
    pub display_name: String,
    #[frb(default = 0)]
    pub unread_message_count: u32,
    #[frb(default = false)]
    pub is_encrypted: bool,
    #[frb(default = false)]
    pub is_invited: bool,
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

/// Lê o retrato do store atualizado pelo único proprietário de sync contínuo.
pub async fn list_conversations() -> Result<Vec<ConversationSummary>, ConversationError> {
    crate::conversations::list().await
}

/// Aceita somente um convite conhecido; o SDK mantém sessão e associação em Rust.
pub async fn accept_room_invitation(
    conversation_id: String,
) -> Result<ConversationSummary, ConversationError> {
    crate::conversations::accept(conversation_id).await
}

/// Marca a sala como lida com recibo privado, sem divulgar a leitura a outros usuários.
pub async fn mark_conversation_read(conversation_id: String) -> Result<(), ConversationError> {
    crate::conversations::mark_read(&conversation_id).await
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

/// Sucesso local confirmado; avisos não incluem detalhes remotos nem segredos.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LogoutResult {
    pub remote_status: RemoteLogoutStatus,
    pub store_cleanup_pending: bool,
}

/// A sessão já revogada também satisfaz o encerramento remoto.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RemoteLogoutStatus {
    Confirmed,
    AlreadyInvalid,
    Network,
    Tls,
    RateLimited,
    Server,
    Internal,
}

/// Err nunca afirma sucesso local; o cliente permanece reservado para nova tentativa.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LogoutError {
    NotAuthenticated,
    LogoutInProgress,
    AuthenticationOperationInProgress,
    SecureStorage,
    LocalCleanup,
    Internal,
}

/// Encerra a sessão remota quando possível e remove a capacidade local de restauração.
pub async fn logout() -> Result<LogoutResult, LogoutError> {
    crate::auth::logout().await
}

/// Projeção textual; eventos, JSON e segredos do SDK permanecem em Rust.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MessageSummary {
    pub id: String,
    pub sender_id: String,
    pub body: String,
    pub timestamp_ms: i64,
    pub is_own: bool,
}

/// Categorias fixas sem conteúdo remoto ou detalhes internos.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MessageHistoryError {
    NotAuthenticated,
    InvalidConversationId,
    ConversationNotFound,
    ConversationNotJoined,
    EncryptionUnsupported,
    Network,
    Tls,
    RateLimited,
    History,
    Internal,
}

/// Retorna um retrato limitado do histórico textual, do mais antigo ao mais novo.
pub async fn load_message_history(
    conversation_id: String,
) -> Result<Vec<MessageSummary>, MessageHistoryError> {
    crate::message_history::load(&conversation_id).await
}

/// Confirmação do servidor; o envio não fornece origin_server_ts nem evento completo.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SendMessageResult {
    pub event_id: String,
}

/// Falhas fixas; uma falha de transporte pode deixar a aceitação remota incerta.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SendMessageError {
    NotAuthenticated,
    InvalidConversationId,
    ConversationNotFound,
    ConversationNotJoined,
    EncryptionUnsupported,
    EmptyMessage,
    MessageTooLong,
    SendInProgress,
    Network,
    Tls,
    RateLimited,
    Send,
    Internal,
}

/// Envia texto literal; a tarefa nativa finita sobrevive ao cancelamento do await.
pub async fn send_text_message(
    conversation_id: String,
    body: String,
) -> Result<SendMessageResult, SendMessageError> {
    crate::message_send::send(conversation_id, body).await
}

/// Apenas projeções da aplicação; nenhum evento ou token Matrix atravessa FRB.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MatrixUpdateKind {
    Message,
    ConversationsChanged,
    ResyncRequired,
    Status,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MatrixSyncStatus {
    Connecting,
    Connected,
    Reconnecting,
    AuthenticationRequired,
}

/// subscription_id/sequence controlam entrega, nunca representam tokens Matrix.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MatrixUpdate {
    pub subscription_id: String,
    pub sequence: u32,
    pub kind: MatrixUpdateKind,
    pub conversation_id: Option<String>,
    pub message: Option<MessageSummary>,
    pub status: MatrixSyncStatus,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MatrixStreamError {
    NotAuthenticated,
    SubscriberLimit,
    SubscriptionClosed,
    Internal,
}

/// Registra um consumidor no broadcast limitado da sessão atual, sem iniciar sync.
pub async fn open_matrix_updates() -> Result<String, MatrixStreamError> {
    crate::synchronization::open().await
}

/// StreamSink gera `Stream<MatrixUpdate>` em Dart. Um evento em voo por consumidor.
pub async fn matrix_updates(
    subscription_id: String,
    sink: crate::frb_generated::StreamSink<MatrixUpdate>,
) -> Result<(), MatrixStreamError> {
    crate::synchronization::stream(subscription_id, sink).await
}

/// ACK de consumo limita inclusive a fila da porta FRB; não consulta atualizações.
pub async fn acknowledge_matrix_update(subscription_id: String, sequence: u32) {
    crate::synchronization::acknowledge(&subscription_id, sequence);
}

pub async fn close_matrix_updates(subscription_id: String) {
    crate::synchronization::close(&subscription_id);
}
