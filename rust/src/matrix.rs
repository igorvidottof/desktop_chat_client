use std::{error::Error, time::Duration};

use matrix_sdk::{
    config::RequestConfig, reqwest, ruma::api::client::session::get_login_types::v3::LoginType,
    Client, ClientBuildError, HttpError,
};
use url::Url;

use crate::api::simple::{ProbeError, ServerInfo};

pub(crate) fn validate_address(address: &str) -> Result<Url, ProbeError> {
    let address = address.trim();
    if !address.to_ascii_lowercase().starts_with("https://")
        || address.chars().any(char::is_whitespace)
        || address.contains('\\')
        || address
            .get(8..)
            .is_some_and(|authority| authority.starts_with('/'))
    {
        return Err(ProbeError::InvalidServerAddress);
    }
    let url = Url::parse(address).map_err(|_| ProbeError::InvalidServerAddress)?;
    if url.scheme() != "https"
        || url.host_str().is_none()
        || !url.username().is_empty()
        || url.password().is_some()
        || url.query().is_some()
        || url.fragment().is_some()
    {
        return Err(ProbeError::InvalidServerAddress);
    }
    Ok(url)
}

pub(crate) async fn probe(address: &str) -> Result<ServerInfo, ProbeError> {
    let client = build_client(validate_address(address)?).await?;
    // Construir o cliente não prova conectividade; o sucesso depende desta consulta.
    let response = client
        .matrix_auth()
        .get_login_types()
        .await
        .map_err(map_http_error)?;
    Ok(ServerInfo {
        server_address: client.homeserver().to_string(),
        supports_password_login: supports_password(&response.flows),
    })
}

pub(crate) async fn build_client(url: Url) -> Result<Client, ProbeError> {
    // Sem redirecionamentos: o endereço explícito não pode migrar para HTTP.
    let http_client = reqwest::Client::builder()
        .https_only(true)
        .redirect(reqwest::redirect::Policy::none())
        .connect_timeout(Duration::from_secs(10))
        .timeout(Duration::from_secs(15))
        .build()
        .map_err(|_| ProbeError::Internal)?;
    Client::builder()
        .homeserver_url(url.as_str())
        // A resposta de login não pode trocar o destino explícito por outro URL.
        .respect_login_well_known(false)
        .http_client(http_client)
        .request_config(
            RequestConfig::default()
                .retry_limit(0)
                .timeout(Duration::from_secs(15)),
        )
        .build()
        .await
        .map_err(map_build_error)
}

pub(crate) fn supports_password(flows: &[LoginType]) -> bool {
    flows
        .iter()
        .any(|flow| matches!(flow, LoginType::Password(_)))
}

fn map_build_error(error: ClientBuildError) -> ProbeError {
    match error {
        ClientBuildError::Url(_)
        | ClientBuildError::InvalidServerName
        | ClientBuildError::MissingHomeserver => ProbeError::InvalidServerAddress,
        ClientBuildError::Http(error) => map_http_error(error),
        _ => ProbeError::Internal,
    }
}

pub(crate) fn contains_tls_error(mut error: &(dyn Error + 'static)) -> bool {
    loop {
        if error.downcast_ref::<rustls::Error>().is_some() {
            return true;
        }
        // io::Error pode ocultar o erro interno em source(); inspeciona seu tipo.
        if let Some(inner) = error
            .downcast_ref::<std::io::Error>()
            .and_then(std::io::Error::get_ref)
        {
            if contains_tls_error(inner) {
                return true;
            }
        }
        match error.source() {
            Some(source) => error = source,
            None => return false,
        }
    }
}

pub(crate) fn map_http_error(error: HttpError) -> ProbeError {
    match error {
        HttpError::Reqwest(error) => {
            if contains_tls_error(&error) {
                ProbeError::Tls
            } else if error.is_connect() || error.is_timeout() || error.is_body() {
                ProbeError::Network
            } else if error.is_decode() || error.is_redirect() || error.is_status() {
                ProbeError::UnusableHomeserver
            } else {
                ProbeError::Internal
            }
        }
        HttpError::Api(_) => ProbeError::UnusableHomeserver,
        HttpError::Cached(error) => {
            // Falhas compartilhadas são classificadas sem revelar sua mensagem.
            if contains_tls_error(error.as_ref()) {
                ProbeError::Tls
            } else {
                ProbeError::Internal
            }
        }
        _ => ProbeError::Internal,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn validates_and_normalizes_https_addresses() {
        assert_eq!(
            validate_address("  HTTPS://MATRIX.ORG:443  ")
                .unwrap()
                .as_str(),
            "https://matrix.org/"
        );
        assert_eq!(
            validate_address("https://example.org/matrix/")
                .unwrap()
                .path(),
            "/matrix/"
        );
        assert!(validate_address("https://[::1]:8448").is_ok());
    }

    #[test]
    fn rejects_invalid_insecure_or_credential_bearing_addresses() {
        for address in [
            "",
            "matrix.org",
            "invalid url",
            "http://localhost",
            "ftp://example.org",
            "https://",
            "https:example.org",
            "https:///example.org",
            "https://user:secret@example.org",
            "https://user@example.org",
            "https://example.org?token=secret",
            "https://example.org#secret",
            "https://exa mple.org",
            "https://example.org:99999",
        ] {
            assert_eq!(
                validate_address(address),
                Err(ProbeError::InvalidServerAddress),
                "{address}"
            );
        }
    }

    #[test]
    fn maps_login_capabilities_without_exposing_protocol_data() {
        use matrix_sdk::ruma::api::client::session::get_login_types::v3::{
            PasswordLoginType, TokenLoginType,
        };
        assert!(!supports_password(&[]));
        assert!(!supports_password(&[LoginType::Token(
            TokenLoginType::new()
        )]));
        assert!(supports_password(&[LoginType::Password(
            PasswordLoginType::new()
        )]));
    }

    #[test]
    fn recognizes_typed_tls_errors_in_source_chain() {
        let tls_error = rustls::Error::InvalidCertificate(rustls::CertificateError::Expired);
        assert!(contains_tls_error(&tls_error));
        assert!(contains_tls_error(&std::io::Error::other(tls_error)));
        assert!(!contains_tls_error(&std::io::Error::other(
            "certificate words are not a typed TLS error"
        )));
    }

    #[test]
    fn maps_build_and_response_errors_to_safe_categories() {
        assert_eq!(
            map_build_error(ClientBuildError::MissingHomeserver),
            ProbeError::InvalidServerAddress
        );
        let invalid_body = Vec::from([0xff]);
        let error = matrix_sdk::ruma::api::error::FromHttpResponseError::Deserialization(
            matrix_sdk::ruma::api::error::DeserializationError::Utf8(
                std::str::from_utf8(&invalid_body).unwrap_err(),
            ),
        );
        assert_eq!(
            map_http_error(HttpError::Api(Box::new(error))),
            ProbeError::UnusableHomeserver
        );
    }
}
