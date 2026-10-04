//! Rust-only crypto lifecycle. SDK owns all accounts, keys and database formats.
use std::path::Path;

use matrix_sdk::{SessionMeta, SqliteCryptoStore};
use matrix_sdk_crypto::{store::CryptoStore, OlmMachineBuilder};

use crate::{api::simple::SessionError, session_store::CryptoLifecycle};

const WITNESS: &str = "desktop_chat_client.crypto-migration.v1";
const DATABASE: &str = "matrix-sdk-crypto.sqlite3";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum CryptoError {
    Initialization,
    Persistence,
    MissingAccount,
    IdentityMismatch,
    InterruptedMigration,
    UnsupportedStore,
}

impl From<CryptoError> for SessionError {
    fn from(error: CryptoError) -> Self {
        match error {
            CryptoError::Persistence => SessionError::Persistence,
            _ => SessionError::CorruptedSession,
        }
    }
}

// Public keys only. Never exported through FRB or printed in errors/tests.
#[derive(Clone, PartialEq, Eq)]
pub(crate) struct PublicIdentity {
    ed25519: String,
    curve25519: String,
}

async fn open(path: &Path, passphrase: &str) -> Result<SqliteCryptoStore, CryptoError> {
    SqliteCryptoStore::open(path, Some(passphrase))
        .await
        .map_err(|_| CryptoError::UnsupportedStore)
}

async fn account(
    store: &SqliteCryptoStore,
    meta: &SessionMeta,
) -> Result<Option<PublicIdentity>, CryptoError> {
    let Some(account) = store
        .load_account()
        .await
        .map_err(|_| CryptoError::UnsupportedStore)?
    else {
        return Ok(None);
    };
    if account.user_id() != meta.user_id || account.device_id() != meta.device_id {
        return Err(CryptoError::IdentityMismatch);
    }
    let keys = account.identity_keys();
    Ok(Some(PublicIdentity {
        ed25519: keys.ed25519.to_base64(),
        curve25519: keys.curve25519.to_base64(),
    }))
}

async fn finish<T>(
    store: SqliteCryptoStore,
    result: Result<T, CryptoError>,
) -> Result<T, CryptoError> {
    let closed = store.close().await.map_err(|_| CryptoError::Persistence);
    result.and_then(|value| closed.map(|()| value))
}

/// Preflight never initializes an account. A v1 manifest is the only Legacy authority.
/// The witness binds incomplete migration to the original SDK store; own device
/// data means the SDK may already have generated keys, so absence is ambiguous.
pub(crate) async fn preflight(
    path: &Path,
    id: &str,
    passphrase: &str,
    meta: &SessionMeta,
    lifecycle: Option<CryptoLifecycle>,
) -> Result<Option<PublicIdentity>, CryptoError> {
    if lifecycle.is_some() && !path.join(DATABASE).is_file() {
        return Err(if lifecycle == Some(CryptoLifecycle::CryptoInitialized) {
            CryptoError::MissingAccount
        } else {
            CryptoError::InterruptedMigration
        });
    }
    let store = open(path, passphrase).await?;
    let result = async {
        let identity = account(&store, meta).await?;
        match lifecycle {
            Some(CryptoLifecycle::CryptoInitialized) => {
                identity.ok_or(CryptoError::MissingAccount).map(Some)
            }
            Some(CryptoLifecycle::MigrationInProgress) => {
                if store
                    .get_custom_value(WITNESS)
                    .await
                    .map_err(|_| CryptoError::UnsupportedStore)?
                    .as_deref()
                    != Some(id.as_bytes())
                {
                    return Err(CryptoError::InterruptedMigration);
                }
                if let Some(identity) = identity {
                    return Ok(Some(identity));
                }
                if store
                    .get_device(&meta.user_id, &meta.device_id)
                    .await
                    .map_err(|_| CryptoError::UnsupportedStore)?
                    .is_some()
                {
                    return Err(CryptoError::InterruptedMigration);
                }
                Ok(None)
            }
            None => {
                if identity.is_some()
                    || store
                        .get_device(&meta.user_id, &meta.device_id)
                        .await
                        .map_err(|_| CryptoError::UnsupportedStore)?
                        .is_some()
                {
                    return Err(CryptoError::InterruptedMigration);
                }
                match store
                    .get_custom_value(WITNESS)
                    .await
                    .map_err(|_| CryptoError::UnsupportedStore)?
                {
                    Some(value) if value != id.as_bytes() => {
                        return Err(CryptoError::InterruptedMigration)
                    }
                    Some(_) => (),
                    None => store
                        .set_custom_value(WITNESS, id.as_bytes().to_vec())
                        .await
                        .map_err(|_| CryptoError::Persistence)?,
                }
                Ok(None)
            }
        }
    }
    .await;
    finish(store, result).await
}

/// Initialize only after MigrationInProgress is durable. This official SDK
/// builder persists the account without network activity or a second sync loop.
/// The caller finalizes the marker before MatrixAuth starts background tasks.
pub(crate) async fn initialize_migration(
    path: &Path,
    passphrase: &str,
    meta: &SessionMeta,
) -> Result<PublicIdentity, CryptoError> {
    let store = open(path, passphrase).await?;
    let result = async {
        let machine = OlmMachineBuilder::new(&meta.user_id, &meta.device_id)
            .with_crypto_store(store.clone())
            .build()
            .await
            .map_err(|_| CryptoError::Initialization)?;
        let identity = account(&store, meta)
            .await?
            .ok_or(CryptoError::Persistence)?;
        drop(machine);
        Ok(identity)
    }
    .await;
    finish(store, result).await
}

/// Independent load from disk, after SDK login/restore has persisted its account.
pub(crate) async fn persisted_identity(
    path: &Path,
    passphrase: &str,
    meta: &SessionMeta,
) -> Result<PublicIdentity, CryptoError> {
    if !path.join(DATABASE).is_file() {
        return Err(CryptoError::MissingAccount);
    }
    let store = open(path, passphrase).await?;
    let result = account(&store, meta)
        .await
        .and_then(|account| account.ok_or(CryptoError::MissingAccount));
    finish(store, result).await
}

/// One ordering shared by production and isolated-store tests.
pub(crate) async fn prepare_restoration<F, Fut>(
    path: &Path,
    id: &str,
    passphrase: &str,
    meta: &SessionMeta,
    lifecycle: Option<CryptoLifecycle>,
    mut advance: F,
) -> Result<PublicIdentity, SessionError>
where
    F: FnMut(CryptoLifecycle) -> Fut,
    Fut: std::future::Future<Output = Result<(), SessionError>>,
{
    let before = preflight(path, id, passphrase, meta, lifecycle).await?;
    if lifecycle == Some(CryptoLifecycle::CryptoInitialized) {
        return before.ok_or(SessionError::CorruptedSession);
    }
    if lifecycle.is_none() {
        advance(CryptoLifecycle::MigrationInProgress).await?;
    }
    let identity = match before {
        Some(identity) => identity,
        None => initialize_migration(path, passphrase, meta).await?,
    };
    advance(CryptoLifecycle::CryptoInitialized).await?;
    Ok(identity)
}

/// Verify disk persistence before permitting durable new-session publication.
pub(crate) async fn finalize_login<Fut>(
    path: &Path,
    passphrase: &str,
    meta: &SessionMeta,
    publish: impl FnOnce() -> Fut,
) -> Result<(), SessionError>
where
    Fut: std::future::Future<Output = Result<(), SessionError>>,
{
    persisted_identity(path, passphrase, meta).await?;
    publish().await
}
