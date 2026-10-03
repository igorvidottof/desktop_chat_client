use std::sync::{LazyLock, Mutex};

use matrix_sdk::{ruma::api::error::ErrorKind, Client, HttpError};

use crate::{
    api::simple::{AccountSummary, LoginError, ProbeError},
    matrix,
};

// O contêiner privado possui o único cliente ativo. Nenhum handle atravessa FRB.
// O SDK usa o armazenamento padrão em memória; não abrimos banco nem iniciamos sync.
static AUTH: LazyLock<AuthState<Client>> = LazyLock::new(AuthState::default);

enum State<T> {
    Idle,
    LoggingIn,
    Authenticated(T),
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

    fn begin(&self) -> Result<LoginAttempt<'_, T>, LoginError> {
        let mut state = self.state.lock().map_err(|_| LoginError::Internal)?;
        match &*state {
            State::Idle => {
                *state = State::LoggingIn;
                Ok(LoginAttempt { owner: self })
            }
            State::LoggingIn => Err(LoginError::LoginInProgress),
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
        if !matches!(*state, State::LoggingIn) {
            return Err(LoginError::Internal);
        }
        *state = State::Authenticated(client);
        Ok(())
    }
}

impl<T> Drop for LoginAttempt<'_, T> {
    fn drop(&mut self) {
        if let Ok(mut state) = self.owner.state.lock() {
            if matches!(*state, State::LoggingIn) {
                *state = State::Idle;
            }
        }
    }
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
    AUTH.authenticate(|| async move {
        let client = matrix::build_client(url).await.map_err(map_probe_error)?;
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
        let summary = AccountSummary {
            user_id: client.user_id().ok_or(LoginError::Internal)?.to_string(),
            device_id: client.device_id().ok_or(LoginError::Internal)?.to_string(),
            homeserver_address: client.homeserver().to_string(),
        };
        Ok((client, summary))
    })
    .await
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

fn map_http_error_ref(error: &HttpError, credentials_sent: bool) -> LoginError {
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
            State::Authenticated(7)
        ));
        assert!(matches!(
            auth.begin(),
            Err(LoginError::AlreadyAuthenticated)
        ));
        assert!(matches!(
            *auth.state.lock().unwrap(),
            State::Authenticated(7)
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
