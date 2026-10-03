use std::sync::{Arc, LazyLock, Mutex};

use matrix_sdk::{ruma::api::error::ErrorKind, Client, HttpError};

use crate::{
    api::simple::{
        AccountSummary, ConversationError, LoginError, ProbeError, SessionError, SessionState,
    },
    matrix,
    session_store::{self, SavedSession, SessionStore},
};

// O contêiner privado possui o único cliente ativo. Nenhum handle atravessa FRB.
// Login e restauração convergem aqui; somente a operação de salas solicita sync único.
static AUTH: LazyLock<AuthState<Client>> = LazyLock::new(AuthState::default);

enum State<T> {
    Idle,
    LoggingIn,
    Restoring,
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
                State::LoggingIn | State::Restoring => {
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

    fn begin(&self) -> Result<LoginAttempt<'_, T>, LoginError> {
        let mut state = self.state.lock().map_err(|_| LoginError::Internal)?;
        match &*state {
            State::Idle => {
                *state = State::LoggingIn;
                Ok(LoginAttempt { owner: self })
            }
            State::LoggingIn | State::Restoring => Err(LoginError::LoginInProgress),
            State::Authenticated(_client) => Err(LoginError::AlreadyAuthenticated),
        }
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
pub(crate) fn authenticated_client() -> Result<Arc<Client>, ConversationError> {
    AUTH.snapshot()
}

pub(crate) fn ensure_current(client: &Arc<Client>) -> Result<(), ConversationError> {
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
    AUTH.authenticate(|| async move {
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
            store_id,
            passphrase.to_string(),
            session,
        );
        // Só publicamos após confirmar persistência. Falha descarta o candidato;
        // uma gravação de resultado incerto pode ser recuperada por initialize.
        session_store::blocking(move || SessionStore::platform()?.persist(&saved))
            .await
            .map_err(map_persistence_error)?;
        Ok((client, summary))
    })
    .await
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
    // permanentes nem sync contínuo, apenas a operação finita protegida por AUTH.
    tokio::spawn(initialize_reserved())
        .await
        .map_err(|_| SessionError::Internal)?
}

async fn initialize_reserved() -> Result<SessionState, SessionError> {
    let client = AUTH
        .initialize(|| async {
            let saved = session_store::blocking(|| SessionStore::platform()?.load()).await?;
            let Some(saved) = saved else {
                return Ok(None);
            };
            let id = saved.store_id.clone();
            let path = session_store::blocking(move || {
                let path = SessionStore::platform()?.store_path(&id)?;
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
            // O mesmo device/store/passphrase permite habilitar crypto-store depois,
            // sem inventar cache concorrente ou recriar a identidade do dispositivo.
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
            Ok(Some(client))
        })
        .await?;
    Ok(SessionState {
        account: client.as_deref().map(account_summary).transpose()?,
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
