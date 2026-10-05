use std::sync::{Arc, LazyLock, Mutex};

use matrix_sdk::{ruma::api::error::ErrorKind, Client, HttpError};

use crate::{
    api::simple::{
        AccountSummary, ConversationError, LoginError, LogoutError, LogoutResult, ProbeError,
        RemoteLogoutStatus, SessionError, SessionState,
    },
    matrix,
    session_store::{self, SavedSession, SessionStore},
};

// O contêiner privado possui o único cliente ativo. Nenhum handle atravessa FRB.
// Login e restauração convergem aqui; cada cliente possui um único proprietário de sync.
static AUTH: LazyLock<AuthState<AuthenticatedClient>> = LazyLock::new(AuthState::default);

// Cada operação de salas ou histórico mantém uma leitura até liberar todos os handles do SDK.
// Logout reserva AUTH primeiro e aguarda exclusividade sem bloquear seu mutex.
pub(crate) static CLIENT_OPERATIONS: tokio::sync::RwLock<()> = tokio::sync::RwLock::const_new(());

pub(crate) struct AuthenticatedClient {
    client: Client,
    store_id: String,
    pub(crate) sync: crate::synchronization::SyncOwner,
}

impl std::ops::Deref for AuthenticatedClient {
    type Target = Client;
    fn deref(&self) -> &Client {
        &self.client
    }
}

enum State<T> {
    Idle,
    LoggingIn,
    Restoring,
    LoggingOut,
    Authenticated(Arc<T>),
}

struct AuthState<T> {
    state: Mutex<State<T>>,
}

impl<T> Default for AuthState<T> {
    fn default() -> Self {
        Self {
            state: Mutex::new(State::Idle),
        }
    }
}

impl<T> AuthState<T> {
    async fn authenticate<F, O>(&self, operation: impl FnOnce() -> F) -> Result<O, LoginError>
    where
        F: std::future::Future<Output = Result<(T, O), LoginError>>,
    {
        let attempt = self.begin()?;
        let (client, output) = operation().await?;
        attempt.publish(client)?;
        Ok(output)
    }

    async fn initialize<F>(
        &self,
        operation: impl FnOnce() -> F,
    ) -> Result<Option<Arc<T>>, SessionError>
    where
        F: std::future::Future<Output = Result<Option<T>, SessionError>>,
    {
        let attempt = {
            let mut state = self.state.lock().map_err(|_| SessionError::Internal)?;
            match &*state {
                // Hot restart não precisa ler disco, cofre ou rede novamente.
                State::Authenticated(client) => return Ok(Some(Arc::clone(client))),
                State::LoggingIn | State::Restoring | State::LoggingOut => {
                    return Err(SessionError::OperationInProgress)
                }
                State::Idle => {
                    *state = State::Restoring;
                    LoginAttempt { owner: self }
                }
            }
        };
        match operation().await? {
            Some(client) => {
                attempt
                    .publish(client)
                    .map_err(|_| SessionError::Internal)?;
                self.snapshot()
                    .map(Some)
                    .map_err(|_| SessionError::Internal)
            }
            None => Ok(None),
        }
    }

    fn snapshot(&self) -> Result<Arc<T>, ConversationError> {
        let state = self.state.lock().map_err(|_| ConversationError::Internal)?;
        match &*state {
            State::Authenticated(client) => Ok(Arc::clone(client)),
            _ => Err(ConversationError::NotAuthenticated),
        }
    }

    fn ensure_current(&self, snapshot: &Arc<T>) -> Result<(), ConversationError> {
        let current = self.snapshot()?;
        if Arc::ptr_eq(&current, snapshot) {
            Ok(())
        } else {
            Err(ConversationError::NotAuthenticated)
        }
    }

    fn begin_logout(&self) -> Result<LogoutAttempt<'_, T>, LogoutError> {
        let mut state = self.state.lock().map_err(|_| LogoutError::Internal)?;
        let client = match &*state {
            State::Idle => return Err(LogoutError::NotAuthenticated),
            State::LoggingOut => return Err(LogoutError::LogoutInProgress),
            State::LoggingIn | State::Restoring => {
                return Err(LogoutError::AuthenticationOperationInProgress)
            }
            State::Authenticated(client) => Arc::clone(client),
        };
        *state = State::LoggingOut;
        Ok(LogoutAttempt {
            owner: self,
            client: Some(client),
        })
    }

    fn begin(&self) -> Result<LoginAttempt<'_, T>, LoginError> {
        let mut state = self.state.lock().map_err(|_| LoginError::Internal)?;
        match &*state {
            State::Idle => {
                *state = State::LoggingIn;
                Ok(LoginAttempt { owner: self })
            }
            State::LoggingIn | State::Restoring | State::LoggingOut => {
                Err(LoginError::LoginInProgress)
            }
            State::Authenticated(_client) => Err(LoginError::AlreadyAuthenticated),
        }
    }
}

// A reserva retém a identidade para retry se o cofre/manifest falhar. O cliente
// deixa de ser acessível a salas imediatamente; somente finish permite novo login.
struct LogoutAttempt<'a, T> {
    owner: &'a AuthState<T>,
    client: Option<Arc<T>>,
}

impl<T> LogoutAttempt<'_, T> {
    fn release_client(&mut self) {
        self.client.take();
    }
    fn finish(self) -> Result<(), LogoutError> {
        let mut state = self.owner.state.lock().map_err(|_| LogoutError::Internal)?;
        *state = State::Idle;
        Ok(())
    }
}

impl<T> Drop for LogoutAttempt<'_, T> {
    fn drop(&mut self) {
        if let Ok(mut state) = self.owner.state.lock() {
            if matches!(*state, State::LoggingOut) {
                *state = self
                    .client
                    .take()
                    .map(State::Authenticated)
                    .unwrap_or(State::Idle);
            }
        }
    }
}

pub(crate) async fn logout() -> Result<LogoutResult, LogoutError> {
    // A tarefa finita é dona da reserva. Cancelar o await FRB não interrompe
    // exclusão no cofre/disco nem abandona AUTH no meio da limpeza.
    tokio::spawn(logout_reserved())
        .await
        .map_err(|_| LogoutError::Internal)?
}

async fn logout_reserved() -> Result<LogoutResult, LogoutError> {
    let attempt = AUTH.begin_logout()?;
    // Revogar AUTH primeiro, parar entrega e aguardar sync antes de fechar SQLite.
    attempt
        .client
        .as_ref()
        .ok_or(LogoutError::Internal)?
        .sync
        .stop()
        .await
        .map_err(|_| LogoutError::Internal)?;
    let _exclusive = CLIENT_OPERATIONS.write().await;
    let id = attempt
        .client
        .as_ref()
        .ok_or(LogoutError::Internal)?
        .store_id
        .clone();
    let cleanup_id = id;
    complete_logout(
        attempt,
        |client| async move {
            match client.matrix_auth().logout().await {
                Ok(_) => RemoteLogoutStatus::Confirmed,
                Err(error) => map_remote_logout(&error),
            }
        },
        || async move {
            session_store::blocking(move || {
                SessionStore::platform()?.remove_restoration(&cleanup_id)
            })
            .await
            .map_err(|error| match error {
                SessionError::SecureStorage => LogoutError::SecureStorage,
                _ => LogoutError::LocalCleanup,
            })
        },
        |client| async move { client.pause().await.is_ok() },
        // pause is a supported close request, not proof that every SDK handle
        // disappeared. Always defer a store used by this native process.
        || std::future::ready(false),
    )
    .await
}

async fn complete_logout<T, R, L, C, S>(
    mut attempt: LogoutAttempt<'_, T>,
    remote: impl FnOnce(Arc<T>) -> R,
    remove_restoration: impl FnOnce() -> L,
    close: impl FnOnce(Arc<T>) -> C,
    remove_store: impl FnOnce() -> S,
) -> Result<LogoutResult, LogoutError>
where
    R: std::future::Future<Output = RemoteLogoutStatus>,
    L: std::future::Future<Output = Result<(), LogoutError>>,
    C: std::future::Future<Output = bool>,
    S: std::future::Future<Output = bool>,
{
    // Falha remota é só um aviso: não pode prender o usuário na sessão local.
    let remote_status = remote(Arc::clone(
        attempt.client.as_ref().ok_or(LogoutError::Internal)?,
    ))
    .await;
    remove_restoration().await?;
    // Restoration authority is already revoked. A close failure cannot restore
    // it; production retains the tracked directory until a later process start.
    // The deletion seam is only eligible when the caller can establish safety.
    let closed = close(Arc::clone(
        attempt.client.as_ref().ok_or(LogoutError::Internal)?,
    ))
    .await;
    attempt.release_client();
    let store_cleanup_pending = !closed || !remove_store().await;
    attempt.finish()?;
    Ok(LogoutResult {
        remote_status,
        store_cleanup_pending,
    })
}

fn map_remote_logout(error: &HttpError) -> RemoteLogoutStatus {
    if let HttpError::Cached(error) = error {
        return map_remote_logout(error);
    }
    if matches!(
        error.client_api_error_kind(),
        Some(ErrorKind::MissingToken | ErrorKind::UnknownToken(_))
    ) {
        return RemoteLogoutStatus::AlreadyInvalid;
    }
    match map_http_error_ref(error, false) {
        LoginError::Network => RemoteLogoutStatus::Network,
        LoginError::Tls => RemoteLogoutStatus::Tls,
        LoginError::RateLimited => RemoteLogoutStatus::RateLimited,
        LoginError::UnusableHomeserver => RemoteLogoutStatus::Server,
        _ => RemoteLogoutStatus::Internal,
    }
}

// A reserva não mantém o mutex bloqueado durante awaits. Falhas, cancelamento
// ou unwinding liberam a tentativa; apenas publish instala um cliente completo.
struct LoginAttempt<'a, T> {
    owner: &'a AuthState<T>,
}

impl<T> LoginAttempt<'_, T> {
    fn publish(self, client: T) -> Result<(), LoginError> {
        let mut state = self.owner.state.lock().map_err(|_| LoginError::Internal)?;
        if !matches!(*state, State::LoggingIn | State::Restoring) {
            return Err(LoginError::Internal);
        }
        *state = State::Authenticated(Arc::new(client));
        Ok(())
    }
}

impl<T> Drop for LoginAttempt<'_, T> {
    fn drop(&mut self) {
        if let Ok(mut state) = self.owner.state.lock() {
            if matches!(*state, State::LoggingIn | State::Restoring) {
                *state = State::Idle;
            }
        }
    }
}

// O Arc externo permite comparar a identidade do cliente ativo após os awaits.
// Client::clone também compartilha ClientInner via Arc no SDK 0.19.1; não cria sessão.
pub(crate) fn authenticated_client() -> Result<Arc<AuthenticatedClient>, ConversationError> {
    AUTH.snapshot()
}

pub(crate) fn ensure_current(client: &Arc<AuthenticatedClient>) -> Result<(), ConversationError> {
    AUTH.ensure_current(client)
}

fn validate_input(username: &str, password: &str) -> Result<(), LoginError> {
    if username.trim().is_empty() || password.is_empty() {
        return Err(LoginError::InvalidInput);
    }
    // Não aparar a senha: espaços podem fazer parte de uma credencial válida.
    Ok(())
}

pub(crate) async fn login(
    address: &str,
    username: &str,
    password: String,
) -> Result<AccountSummary, LoginError> {
    let url = matrix::validate_address(address).map_err(map_probe_error)?;
    validate_input(username, &password)?;
    // A reserva pertence à tarefa nativa, não ao await do chamador FRB. Cancelar
    // Dart/hot restart não libera AUTH enquanto spawn_blocking ainda publica disco.
    // Assim uma gravação antiga nunca ultrapassa uma nova tentativa de login.
    tokio::spawn(login_reserved(url, username.trim().to_owned(), password))
        .await
        .map_err(|_| LoginError::Internal)?
}

async fn login_reserved(
    url: url::Url,
    username: String,
    password: String,
) -> Result<AccountSummary, LoginError> {
    let summary = AUTH
        .authenticate(|| async move {
            session_store::blocking(session_store::initialize_local_lifecycle)
                .await
                .map_err(map_persistence_error)?;
            let (store_id, passphrase, path) =
                session_store::blocking(|| SessionStore::platform()?.prepare())
                    .await
                    .map_err(map_persistence_error)?;
            let client = matrix::client_builder(url)
                .map_err(map_probe_error)?
                .sqlite_store(path, Some(&passphrase))
                .build()
                .await
                .map_err(|_| LoginError::Persistence)?;
            let response = client
                .matrix_auth()
                .get_login_types()
                .await
                .map_err(map_capability_error)?;
            require_password_support(&response.flows)?;

            // A API 0.19.1 copia a senha para o builder e internamente para a requisição.
            // Liberamos nossa String antes do await; isso não garante zeragem da memória.
            // O SDK aplica short_retry no login; o transporte HTTPS/TLS continua o mesmo.
            let builder = client
                .matrix_auth()
                .login_username(username.trim(), &password);
            drop(password);
            // Não retemos nem exportamos a resposta que contém tokens. O SDK instala
            // a sessão no cliente candidato; ele só vira ativo após toda a operação.
            builder.send().await.map_err(map_sdk_error)?;
            let summary = account_summary(&client).map_err(|_| LoginError::Internal)?;
            let session = client.matrix_auth().session().ok_or(LoginError::Internal)?;
            let saved = SavedSession::new(
                client.homeserver().to_string(),
                store_id.clone(),
                passphrase.to_string(),
                session,
            );
            // Só publicamos após confirmar persistência. Falha descarta o candidato;
            // uma gravação de resultado incerto pode ser recuperada por initialize.
            session_store::blocking(move || SessionStore::platform()?.persist(&saved))
                .await
                .map_err(map_persistence_error)?;
            Ok((
                AuthenticatedClient {
                    client,
                    store_id,
                    sync: crate::synchronization::SyncOwner::new(),
                },
                summary,
            ))
        })
        .await?;
    let client = authenticated_client().map_err(|_| LoginError::Internal)?;
    client.sync.start(&client);
    Ok(summary)
}

fn account_summary(client: &Client) -> Result<AccountSummary, SessionError> {
    Ok(AccountSummary {
        user_id: client.user_id().ok_or(SessionError::Internal)?.to_string(),
        device_id: client
            .device_id()
            .ok_or(SessionError::Internal)?
            .to_string(),
        homeserver_address: client.homeserver().to_string(),
    })
}

pub(crate) async fn initialize() -> Result<SessionState, SessionError> {
    // Restauração segue a mesma regra de cancelamento do login; não há tarefas
    // duplicadas: initialize reconecta ao proprietário nativo já existente.
    tokio::spawn(initialize_reserved())
        .await
        .map_err(|_| SessionError::Internal)?
}

async fn initialize_reserved() -> Result<SessionState, SessionError> {
    let _operation = CLIENT_OPERATIONS.read().await;
    let client = AUTH
        .initialize(|| async {
            session_store::blocking(session_store::initialize_local_lifecycle).await?;
            let saved = session_store::blocking(|| SessionStore::platform()?.load()).await?;
            let Some(saved) = saved else {
                return Ok(None);
            };
            let id = saved.store_id.clone();
            let path_id = id.clone();
            let path = session_store::blocking(move || {
                let path = SessionStore::platform()?.store_path(&path_id)?;
                session_store::require_store(&path)?;
                Ok(path)
            })
            .await?;
            let url = matrix::validate_address(&saved.homeserver)
                .map_err(|_| SessionError::CorruptedSession)?;
            let client = matrix::client_builder(url)
                .map_err(|_| SessionError::Internal)?
                .sqlite_store(path, Some(&saved.passphrase))
                .build()
                .await
                .map_err(|_| SessionError::CorruptedSession)?;
            // restore_session instala estado local do SDK; não verifica revogação remota.
            client
                .matrix_auth()
                .restore_session(
                    saved.session.clone(),
                    matrix_sdk::store::RoomLoadSettings::default(),
                )
                .await
                .map_err(|_| SessionError::CorruptedSession)?;
            let identity = client
                .whoami()
                .await
                .map_err(|error| map_restore_http(&error))?;
            if identity.user_id != saved.session.meta.user_id
                || identity
                    .device_id
                    .as_ref()
                    .is_some_and(|id| id != &saved.session.meta.device_id)
            {
                return Err(SessionError::InvalidSession);
            }
            // Não apagamos nada em falhas, inclusive rede/TLS. O candidato só vira
            // autoridade após validação; uma nova tentativa reabre a sessão preservada.
            Ok(Some(AuthenticatedClient {
                client,
                store_id: id,
                sync: crate::synchronization::SyncOwner::new(),
            }))
        })
        .await?;
    if let Some(client) = &client {
        client.sync.start(client);
    }
    Ok(SessionState {
        account: client
            .as_deref()
            .map(|client| account_summary(client))
            .transpose()?,
    })
}

fn map_restore_http(error: &HttpError) -> SessionError {
    if let HttpError::Cached(error) = error {
        return map_restore_http(error);
    }
    if matches!(
        error.client_api_error_kind(),
        Some(ErrorKind::UnknownToken(_) | ErrorKind::MissingToken)
    ) {
        return SessionError::InvalidSession;
    }
    match map_http_error_ref(error, false) {
        LoginError::Network => SessionError::Network,
        LoginError::Tls => SessionError::Tls,
        _ => SessionError::Internal,
    }
}

fn map_persistence_error(error: SessionError) -> LoginError {
    match error {
        SessionError::SecureStorage => LoginError::SecureStorage,
        SessionError::Persistence | SessionError::CorruptedSession => LoginError::Persistence,
        _ => LoginError::Internal,
    }
}

fn require_password_support(
    flows: &[matrix_sdk::ruma::api::client::session::get_login_types::v3::LoginType],
) -> Result<(), LoginError> {
    if matrix::supports_password(flows) {
        Ok(())
    } else {
        Err(LoginError::PasswordLoginUnsupported)
    }
}

fn map_probe_error(error: ProbeError) -> LoginError {
    match error {
        ProbeError::InvalidServerAddress => LoginError::InvalidServerAddress,
        ProbeError::Network => LoginError::Network,
        ProbeError::Tls => LoginError::Tls,
        ProbeError::UnusableHomeserver => LoginError::UnusableHomeserver,
        ProbeError::Internal => LoginError::Internal,
    }
}

fn map_sdk_error(error: matrix_sdk::Error) -> LoginError {
    match error {
        matrix_sdk::Error::Http(error) => map_http_error(*error),
        _ => LoginError::Internal,
    }
}

fn map_capability_error(error: HttpError) -> LoginError {
    // A consulta pública não envia credenciais; um 403 nela não prova senha inválida.
    map_http_error_ref(&error, false)
}

fn map_http_error(error: HttpError) -> LoginError {
    map_http_error_ref(&error, true)
}

pub(crate) fn map_http_error_ref(error: &HttpError, credentials_sent: bool) -> LoginError {
    if let HttpError::Cached(error) = error {
        return map_http_error_ref(error, credentials_sent);
    }
    match error.client_api_error_kind() {
        Some(ErrorKind::Forbidden) if credentials_sent => return LoginError::InvalidCredentials,
        Some(ErrorKind::LimitExceeded(_)) => return LoginError::RateLimited,
        _ => {}
    }
    // A consulta de capacidades detecta ausência de m.login.password. Outros
    // códigos do servidor não são tratados como credenciais inválidas por chute.
    match error {
        HttpError::Reqwest(error) => {
            if matrix::contains_tls_error(error) {
                LoginError::Tls
            } else if error.is_connect() || error.is_timeout() || error.is_body() {
                LoginError::Network
            } else if error.is_decode() || error.is_redirect() || error.is_status() {
                LoginError::UnusableHomeserver
            } else {
                LoginError::Internal
            }
        }
        HttpError::Api(_) => LoginError::UnusableHomeserver,
        _ => LoginError::Internal,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use matrix_sdk::ruma::api::{
        client::{session::get_login_types::v3::PasswordLoginType, uiaa::UiaaResponse},
        error::{ErrorBody, FromHttpResponseError, LimitExceededErrorData, StandardErrorBody},
    };

    #[tokio::test]
    async fn logout_success_offline_and_revoked_all_remove_authority() {
        for status in [
            RemoteLogoutStatus::Confirmed,
            RemoteLogoutStatus::Network,
            RemoteLogoutStatus::AlreadyInvalid,
        ] {
            let auth = AuthState::<u8>::default();
            auth.begin().unwrap().publish(7).unwrap();
            let stale = auth.snapshot().unwrap();
            let weak = Arc::downgrade(&stale);
            let attempt = auth.begin_logout().unwrap();
            assert_eq!(
                auth.ensure_current(&stale),
                Err(ConversationError::NotAuthenticated)
            );
            drop(stale);
            let result = complete_logout(
                attempt,
                |_| std::future::ready(status),
                || std::future::ready(Ok(())),
                |_| std::future::ready(true),
                || {
                    assert!(weak.upgrade().is_none());
                    std::future::ready(true)
                },
            )
            .await
            .unwrap();
            assert_eq!(result.remote_status, status);
            assert!(!result.store_cleanup_pending);
            assert!(matches!(
                auth.snapshot(),
                Err(ConversationError::NotAuthenticated)
            ));
            assert!(auth
                .initialize(|| std::future::ready(Ok(None)))
                .await
                .unwrap()
                .is_none());
            assert!(auth.begin().is_ok());
        }
    }

    #[tokio::test]
    async fn failed_local_cleanup_preserves_identity_for_retry() {
        for error in [LogoutError::SecureStorage, LogoutError::LocalCleanup] {
            let auth = AuthState::<u8>::default();
            auth.begin().unwrap().publish(7).unwrap();
            let original = auth.snapshot().unwrap();
            let result = complete_logout(
                auth.begin_logout().unwrap(),
                |_| std::future::ready(RemoteLogoutStatus::Confirmed),
                || std::future::ready(Err(error)),
                |_| async { panic!("não fechar store antes de remover restauração") },
                || async { panic!("não remover store antes de remover restauração") },
            )
            .await;
            assert_eq!(result, Err(error));
            assert!(Arc::ptr_eq(&original, &auth.snapshot().unwrap()));
            assert!(auth.begin_logout().is_ok());
        }
    }

    #[tokio::test]
    async fn physical_store_failure_is_a_warning_after_local_logout() {
        for closed in [true, false] {
            let auth = AuthState::<u8>::default();
            auth.begin().unwrap().publish(7).unwrap();
            let result = complete_logout(
                auth.begin_logout().unwrap(),
                |_| std::future::ready(RemoteLogoutStatus::Network),
                || std::future::ready(Ok(())),
                |_| std::future::ready(closed),
                || {
                    assert!(closed);
                    std::future::ready(false)
                },
            )
            .await
            .unwrap();
            assert!(result.store_cleanup_pending);
            assert!(matches!(
                auth.snapshot(),
                Err(ConversationError::NotAuthenticated)
            ));
        }
    }

    #[tokio::test]
    async fn logout_reservation_excludes_lifecycle_operations_and_survives_caller_drop() {
        let auth = Arc::new(AuthState::<u8>::default());
        assert!(matches!(
            auth.begin_logout(),
            Err(LogoutError::NotAuthenticated)
        ));
        let login = auth.begin().unwrap();
        assert!(matches!(
            auth.begin_logout(),
            Err(LogoutError::AuthenticationOperationInProgress)
        ));
        drop(login);
        let mut restoring =
            Box::pin(auth.initialize(std::future::pending::<Result<Option<u8>, SessionError>>));
        assert!(poll_once(restoring.as_mut()).is_pending());
        assert!(matches!(
            auth.begin_logout(),
            Err(LogoutError::AuthenticationOperationInProgress)
        ));
        drop(restoring);
        auth.begin().unwrap().publish(7).unwrap();
        let owner = Arc::clone(&auth);
        let (started, starting) = tokio::sync::oneshot::channel();
        let (finish, finishing) = tokio::sync::oneshot::channel();
        let (done, completed) = tokio::sync::oneshot::channel();
        let task = tokio::spawn(async move {
            let attempt = owner.begin_logout().unwrap();
            let result = complete_logout(
                attempt,
                |_| async {
                    started.send(()).unwrap();
                    finishing.await.unwrap();
                    RemoteLogoutStatus::Confirmed
                },
                || std::future::ready(Ok(())),
                |_| std::future::ready(true),
                || std::future::ready(true),
            )
            .await;
            done.send(result).unwrap();
        });
        starting.await.unwrap();
        drop(task);
        assert!(auth.state.try_lock().is_ok());
        assert!(matches!(
            auth.begin_logout(),
            Err(LogoutError::LogoutInProgress)
        ));
        assert!(matches!(auth.begin(), Err(LoginError::LoginInProgress)));
        assert!(matches!(
            auth.initialize(|| std::future::ready(Ok(None))).await,
            Err(SessionError::OperationInProgress)
        ));
        finish.send(()).unwrap();
        completed.await.unwrap().unwrap();
        assert!(matches!(
            auth.snapshot(),
            Err(ConversationError::NotAuthenticated)
        ));
    }

    #[tokio::test]
    async fn conversation_lease_must_drain_before_store_cleanup() {
        let gate = Arc::new(tokio::sync::RwLock::new(()));
        let read = Arc::clone(&gate).read_owned().await;
        let mut exclusive = Box::pin(gate.write());
        assert!(poll_once(exclusive.as_mut()).is_pending());
        drop(read);
        assert!(poll_once(exclusive.as_mut()).is_ready());
    }

    #[test]
    fn initialization_distinguishes_empty_persisted_and_native_hot_restart() {
        let auth = AuthState::<u8>::default();
        let mut empty = Box::pin(auth.initialize(|| std::future::ready(Ok(None))));
        assert!(matches!(
            poll_once(empty.as_mut()),
            std::task::Poll::Ready(Ok(None))
        ));
        drop(empty);
        assert!(matches!(*auth.state.lock().unwrap(), State::Idle));
        let mut restored = Box::pin(auth.initialize(|| std::future::ready(Ok(Some(7)))));
        assert!(
            matches!(poll_once(restored.as_mut()), std::task::Poll::Ready(Ok(Some(client))) if *client == 7)
        );
        drop(restored);
        let snapshot = auth.snapshot().unwrap();
        let mut hot_restart = Box::pin(auth.initialize(
            || -> std::future::Ready<Result<Option<u8>, SessionError>> {
                panic!("hot restart não deve abrir cofre, disco ou rede")
            },
        ));
        assert!(
            matches!(poll_once(hot_restart.as_mut()), std::task::Poll::Ready(Ok(Some(client))) if Arc::ptr_eq(&client, &snapshot))
        );
    }

    #[test]
    fn failed_restoration_never_publishes_and_retry_can_recover() {
        for error in [
            SessionError::Network,
            SessionError::Tls,
            SessionError::InvalidSession,
            SessionError::CorruptedSession,
            SessionError::SecureStorage,
            SessionError::Persistence,
            SessionError::Internal,
        ] {
            let auth = AuthState::<u8>::default();
            let mut failed = Box::pin(auth.initialize(|| std::future::ready(Err(error))));
            assert!(
                matches!(poll_once(failed.as_mut()), std::task::Poll::Ready(Err(actual)) if actual == error)
            );
            drop(failed);
            assert!(matches!(
                auth.snapshot(),
                Err(ConversationError::NotAuthenticated)
            ));
            assert!(auth.begin().is_ok());
        }
    }

    #[test]
    fn restoration_and_login_reservations_exclude_each_other() {
        let auth = AuthState::<u8>::default();
        let mut restoring =
            Box::pin(auth.initialize(std::future::pending::<Result<Option<u8>, SessionError>>));
        assert!(poll_once(restoring.as_mut()).is_pending());
        assert!(auth.state.try_lock().is_ok());
        assert!(matches!(auth.begin(), Err(LoginError::LoginInProgress)));
        let mut second = Box::pin(auth.initialize(|| std::future::ready(Ok(Some(9)))));
        assert!(matches!(
            poll_once(second.as_mut()),
            std::task::Poll::Ready(Err(SessionError::OperationInProgress))
        ));
        drop(second);
        drop(restoring);
        let login = auth.begin().unwrap();
        let mut during_login = Box::pin(auth.initialize(|| std::future::ready(Ok(Some(9)))));
        assert!(matches!(
            poll_once(during_login.as_mut()),
            std::task::Poll::Ready(Err(SessionError::OperationInProgress))
        ));
        drop(during_login);
        login.publish(7).unwrap();
        assert_eq!(*auth.snapshot().unwrap(), 7);
    }

    #[test]
    fn persistence_failure_after_authentication_does_not_publish_candidate() {
        let auth = AuthState::<u8>::default();
        let mut login = Box::pin(auth.authenticate(|| async {
            let _authenticated_candidate = 7u8;
            Err::<(u8, ()), _>(map_persistence_error(SessionError::SecureStorage))
        }));
        assert!(matches!(
            poll_once(login.as_mut()),
            std::task::Poll::Ready(Err(LoginError::SecureStorage))
        ));
        assert!(matches!(
            auth.snapshot(),
            Err(ConversationError::NotAuthenticated)
        ));
    }

    #[tokio::test]
    async fn caller_cancellation_keeps_native_reservation_until_persistence_finishes() {
        let auth = Arc::new(AuthState::<u8>::default());
        let owner = Arc::clone(&auth);
        let (started, starting) = tokio::sync::oneshot::channel();
        let (finish, finishing) = tokio::sync::oneshot::channel();
        let (done, completed) = tokio::sync::oneshot::channel();
        let task = tokio::spawn(async move {
            let result = owner
                .authenticate(|| async {
                    started.send(()).unwrap();
                    // Representa publicação bloqueante que não pode ser cancelada.
                    let client = finishing.await.unwrap();
                    Ok((client, ()))
                })
                .await;
            done.send(result).unwrap();
        });
        starting.await.unwrap();
        drop(task);
        assert!(matches!(auth.begin(), Err(LoginError::LoginInProgress)));
        assert!(auth.state.try_lock().is_ok());
        finish.send(7).unwrap();
        completed.await.unwrap().unwrap();
        assert_eq!(*auth.snapshot().unwrap(), 7);
    }

    #[test]
    fn remote_logout_maps_revocation_rate_limit_and_server_without_details() {
        use matrix_sdk::ruma::api::error::UnknownTokenErrorData;
        for (kind, status) in [
            (ErrorKind::MissingToken, RemoteLogoutStatus::AlreadyInvalid),
            (
                ErrorKind::UnknownToken(UnknownTokenErrorData::new()),
                RemoteLogoutStatus::AlreadyInvalid,
            ),
            (
                ErrorKind::LimitExceeded(LimitExceededErrorData::new()),
                RemoteLogoutStatus::RateLimited,
            ),
            (ErrorKind::Forbidden, RemoteLogoutStatus::Server),
            (ErrorKind::Unknown, RemoteLogoutStatus::Server),
        ] {
            let error = api_error(kind);
            assert_eq!(map_remote_logout(&error), status);
            assert_eq!(
                map_remote_logout(&HttpError::Cached(Arc::new(error))),
                status
            );
            assert!(!format!("{status:?}").contains("untrusted"));
        }
    }

    #[test]
    fn rejected_session_maps_without_server_details() {
        use matrix_sdk::ruma::api::error::UnknownTokenErrorData;
        for kind in [
            ErrorKind::MissingToken,
            ErrorKind::UnknownToken(UnknownTokenErrorData::new()),
        ] {
            let error = api_error(kind);
            assert_eq!(map_restore_http(&error), SessionError::InvalidSession);
            assert_eq!(
                map_restore_http(&HttpError::Cached(Arc::new(error))),
                SessionError::InvalidSession
            );
        }
        assert_eq!(
            map_restore_http(&api_error(ErrorKind::Forbidden)),
            SessionError::Internal
        );
    }

    #[test]
    fn snapshot_releases_lock_and_rejects_changed_authentication() {
        let auth = AuthState::<u8>::default();
        assert_eq!(
            auth.snapshot().unwrap_err(),
            ConversationError::NotAuthenticated
        );
        auth.begin().unwrap().publish(7).unwrap();
        let snapshot = auth.snapshot().unwrap();
        assert!(auth.state.try_lock().is_ok());
        assert_eq!(auth.ensure_current(&snapshot), Ok(()));
        *auth.state.lock().unwrap() = State::Authenticated(Arc::new(7));
        assert_eq!(
            auth.ensure_current(&snapshot),
            Err(ConversationError::NotAuthenticated)
        );
        *auth.state.lock().unwrap() = State::Idle;
        assert_eq!(
            auth.ensure_current(&snapshot),
            Err(ConversationError::NotAuthenticated)
        );
    }

    #[test]
    fn validates_required_input_without_changing_password() {
        for username in ["", "  ", "\n"] {
            assert_eq!(validate_input(username, " "), Err(LoginError::InvalidInput));
        }
        assert_eq!(validate_input("fixture", ""), Err(LoginError::InvalidInput));
        assert_eq!(validate_input("fixture", " "), Ok(()));
    }

    #[test]
    fn unsupported_password_login_is_safe() {
        assert_eq!(
            require_password_support(&[]),
            Err(LoginError::PasswordLoginUnsupported)
        );
        assert_eq!(
            require_password_support(&[
                matrix_sdk::ruma::api::client::session::get_login_types::v3::LoginType::Password(
                    PasswordLoginType::new()
                )
            ]),
            Ok(())
        );
    }

    #[test]
    fn failure_and_cancellation_release_reservation_without_publishing() {
        let auth = AuthState::<()>::default();
        {
            let _attempt = auth.begin().unwrap();
            assert!(matches!(auth.begin(), Err(LoginError::LoginInProgress)));
            // O mesmo Drop roda ao retornar uma falha ou cancelar o futuro.
        }
        assert!(matches!(*auth.state.lock().unwrap(), State::Idle));
        assert!(auth.begin().is_ok());
    }

    #[test]
    fn successful_publish_retains_account_and_prevents_replacement() {
        let auth = AuthState::<u8>::default();
        auth.begin().unwrap().publish(7).unwrap();
        assert!(matches!(
            *auth.state.lock().unwrap(),
            State::Authenticated(ref client) if **client == 7
        ));
        assert!(matches!(
            auth.begin(),
            Err(LoginError::AlreadyAuthenticated)
        ));
        assert!(matches!(
            *auth.state.lock().unwrap(),
            State::Authenticated(ref client) if **client == 7
        ));
    }

    fn api_error(kind: ErrorKind) -> HttpError {
        let body = ErrorBody::Standard(StandardErrorBody::new(
            kind,
            "untrusted fixture body".into(),
        ));
        let error = body.into_error(matrix_sdk::reqwest::StatusCode::FORBIDDEN);
        HttpError::Api(Box::new(FromHttpResponseError::Server(
            UiaaResponse::MatrixError(error),
        )))
    }

    #[test]
    fn maps_typed_failures_without_server_messages() {
        assert_eq!(
            map_capability_error(api_error(ErrorKind::Forbidden)),
            LoginError::UnusableHomeserver
        );
        assert_eq!(
            map_capability_error(api_error(ErrorKind::LimitExceeded(
                LimitExceededErrorData::new()
            ))),
            LoginError::RateLimited
        );
        assert_eq!(
            map_http_error(api_error(ErrorKind::Forbidden)),
            LoginError::InvalidCredentials
        );
        assert_eq!(
            map_sdk_error(matrix_sdk::Error::Http(Box::new(api_error(
                ErrorKind::Forbidden
            )))),
            LoginError::InvalidCredentials
        );
        assert_eq!(
            map_http_error(api_error(ErrorKind::LimitExceeded(
                LimitExceededErrorData::new()
            ))),
            LoginError::RateLimited
        );
        assert_eq!(
            map_http_error(HttpError::Cached(std::sync::Arc::new(api_error(
                ErrorKind::Forbidden
            )))),
            LoginError::InvalidCredentials
        );
        assert_eq!(
            map_http_error(api_error(ErrorKind::Unknown)),
            LoginError::UnusableHomeserver
        );
        assert_eq!(
            map_sdk_error(matrix_sdk::Error::AuthenticationRequired),
            LoginError::Internal
        );
        for (probe, login) in [
            (
                ProbeError::InvalidServerAddress,
                LoginError::InvalidServerAddress,
            ),
            (ProbeError::Tls, LoginError::Tls),
            (ProbeError::Network, LoginError::Network),
            (
                ProbeError::UnusableHomeserver,
                LoginError::UnusableHomeserver,
            ),
            (ProbeError::Internal, LoginError::Internal),
        ] {
            assert_eq!(map_probe_error(probe), login);
        }
    }
    fn poll_once<F: std::future::Future>(
        future: std::pin::Pin<&mut F>,
    ) -> std::task::Poll<F::Output> {
        future.poll(&mut std::task::Context::from_waker(std::task::Waker::noop()))
    }

    #[test]
    fn failed_operation_does_not_install_client_and_can_retry() {
        let auth = AuthState::<u8>::default();
        let mut failed = Box::pin(auth.authenticate(|| {
            std::future::ready(Err::<(u8, ()), _>(LoginError::InvalidCredentials))
        }));
        assert_eq!(
            poll_once(failed.as_mut()),
            std::task::Poll::Ready(Err(LoginError::InvalidCredentials))
        );
        assert!(matches!(*auth.state.lock().unwrap(), State::Idle));
        let mut success =
            Box::pin(auth.authenticate(|| std::future::ready(Ok((7, "safe summary")))));
        assert_eq!(
            poll_once(success.as_mut()),
            std::task::Poll::Ready(Ok("safe summary"))
        );
        let mut replacement = Box::pin(auth.authenticate(
            || -> std::future::Ready<Result<(u8, ()), LoginError>> {
                panic!("não deve executar outra autenticação")
            },
        ));
        assert_eq!(
            poll_once(replacement.as_mut()),
            std::task::Poll::Ready(Err::<(), _>(LoginError::AlreadyAuthenticated))
        );
    }

    #[test]
    fn concurrent_attempt_is_rejected_and_cancelled_future_releases_state() {
        let auth = AuthState::<u8>::default();
        let mut pending =
            Box::pin(auth.authenticate(std::future::pending::<Result<(u8, ()), LoginError>>));
        assert!(poll_once(pending.as_mut()).is_pending());
        let mut concurrent = Box::pin(auth.authenticate(|| std::future::ready(Ok((9, ())))));
        assert_eq!(
            poll_once(concurrent.as_mut()),
            std::task::Poll::Ready(Err(LoginError::LoginInProgress))
        );
        drop(pending);
        assert!(matches!(*auth.state.lock().unwrap(), State::Idle));
    }
}
