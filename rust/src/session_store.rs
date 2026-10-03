use std::{
    fs,
    io::Write,
    path::{Path, PathBuf},
};

use directories::ProjectDirs;
use matrix_sdk::authentication::matrix::MatrixSession;
use serde::{Deserialize, Serialize};
use zeroize::{Zeroize, Zeroizing};

use crate::{api::simple::SessionError, matrix};

const SERVICE: &str = "desktop_chat_client.matrix.v1";

// O único arquivo da aplicação contém um identificador opaco, nunca credenciais.
// Cada tentativa usa outra pasta: uma falha não mistura contas no store do SDK.
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Manifest {
    version: u8,
    store_id: String,
}

// Serializamos o tipo oficial do SDK dentro do cofre do SO, não em arquivo JSON.
// O device_id e o mesmo store são essenciais para a futura continuidade criptográfica.
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct SavedSession {
    version: u8,
    pub(crate) homeserver: String,
    pub(crate) store_id: String,
    pub(crate) passphrase: String,
    pub(crate) session: MatrixSession,
}

impl Drop for SavedSession {
    fn drop(&mut self) {
        self.passphrase.zeroize();
        self.session.tokens.access_token.zeroize();
        if let Some(token) = &mut self.session.tokens.refresh_token {
            token.zeroize();
        }
    }
}

// Fronteira mínima para testes sem acessar o Keychain ou Secret Service reais.
pub(crate) trait Secrets {
    fn read(&self, id: &str) -> Result<Option<Zeroizing<String>>, SessionError>;
    fn write(&self, id: &str, value: &str) -> Result<(), SessionError>;
}

pub(crate) struct OsSecrets;

impl Secrets for OsSecrets {
    fn read(&self, id: &str) -> Result<Option<Zeroizing<String>>, SessionError> {
        let entry = keyring::Entry::new(SERVICE, id).map_err(|_| SessionError::SecureStorage)?;
        match entry.get_secret() {
            Ok(value) => {
                let bytes = Zeroizing::new(value);
                let text =
                    std::str::from_utf8(&bytes).map_err(|_| SessionError::CorruptedSession)?;
                Ok(Some(Zeroizing::new(text.to_owned())))
            }
            Err(keyring::Error::NoEntry) => Ok(None),
            Err(_) => Err(SessionError::SecureStorage),
        }
    }

    fn write(&self, id: &str, value: &str) -> Result<(), SessionError> {
        keyring::Entry::new(SERVICE, id)
            .and_then(|entry| entry.set_secret(value.as_bytes()))
            .map_err(|_| SessionError::SecureStorage)
    }
}

pub(crate) struct SessionStore<S> {
    root: PathBuf,
    secrets: S,
}

impl SessionStore<OsSecrets> {
    pub(crate) fn platform() -> Result<Self, SessionError> {
        // ProjectDirs respeita Application Support, LocalAppData e XDG_DATA_HOME.
        // Em macOS com sandbox, o SO direciona o acesso ao contêiner da aplicação.
        let dirs = ProjectDirs::from("org", "desktop-chat-client", "desktop_chat_client")
            .ok_or(SessionError::Persistence)?;
        Ok(Self {
            root: dirs.data_local_dir().to_path_buf(),
            secrets: OsSecrets,
        })
    }
}

impl<S: Secrets> SessionStore<S> {
    pub(crate) fn store_path(&self, id: &str) -> Result<PathBuf, SessionError> {
        if !valid_id(id) {
            return Err(SessionError::CorruptedSession);
        }
        Ok(self.root.join("stores").join(id))
    }

    pub(crate) fn load(&self) -> Result<Option<SavedSession>, SessionError> {
        let bytes = match fs::read(self.root.join("active-session.json")) {
            Ok(bytes) => bytes,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(_) => return Err(SessionError::Persistence),
        };
        let manifest: Manifest =
            serde_json::from_slice(&bytes).map_err(|_| SessionError::CorruptedSession)?;
        if manifest.version != 1 || !valid_id(&manifest.store_id) {
            return Err(SessionError::CorruptedSession);
        }
        let encoded = self
            .secrets
            .read(&manifest.store_id)?
            .ok_or(SessionError::CorruptedSession)?;
        let saved: SavedSession =
            serde_json::from_str(&encoded).map_err(|_| SessionError::CorruptedSession)?;
        if saved.version != 1
            || saved.store_id != manifest.store_id
            || saved.passphrase.len() != 64
            || !saved.passphrase.bytes().all(|b| b.is_ascii_hexdigit())
            || saved.session.tokens.access_token.is_empty()
            || saved.session.meta.device_id.as_str().is_empty()
            || matrix::validate_address(&saved.homeserver).is_err()
            || !self.store_path(&saved.store_id)?.is_dir()
        {
            return Err(SessionError::CorruptedSession);
        }
        Ok(Some(saved))
    }

    pub(crate) fn prepare(&self) -> Result<(String, Zeroizing<String>, PathBuf), SessionError> {
        let id = random_hex(16)?;
        let passphrase = Zeroizing::new(random_hex(32)?);
        let path = self.store_path(&id)?;
        fs::create_dir_all(&path).map_err(|_| SessionError::Persistence)?;
        Ok((id, passphrase, path))
    }

    pub(crate) fn persist(&self, saved: &SavedSession) -> Result<(), SessionError> {
        let encoded =
            Zeroizing::new(serde_json::to_string(saved).map_err(|_| SessionError::Internal)?);
        // O cofre precisa confirmar a gravação antes do ponto de publicação em disco.
        // Entradas/pastas órfãs de falhas permanecem recuperáveis; logout futuro deverá
        // enumerar stores e remover suas entradas, além do manifest e cliente em memória.
        self.secrets.write(&saved.store_id, &encoded)?;
        let manifest = serde_json::to_vec(&Manifest {
            version: 1,
            store_id: saved.store_id.clone(),
        })
        .map_err(|_| SessionError::Internal)?;
        let pending = self.root.join(format!("pending-{}.json", random_hex(16)?));
        let mut file = fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&pending)
            .map_err(|_| SessionError::Persistence)?;
        file.write_all(&manifest)
            .and_then(|_| file.sync_all())
            .map_err(|_| SessionError::Persistence)?;
        drop(file);
        fs::rename(pending, self.root.join("active-session.json"))
            .map_err(|_| SessionError::Persistence)?;
        #[cfg(unix)]
        fs::File::open(&self.root)
            .and_then(|dir| dir.sync_all())
            .map_err(|_| SessionError::Persistence)?;
        Ok(())
    }
}

impl SavedSession {
    pub(crate) fn new(
        homeserver: String,
        store_id: String,
        passphrase: String,
        session: MatrixSession,
    ) -> Self {
        Self {
            version: 1,
            homeserver,
            store_id,
            passphrase,
            session,
        }
    }
}

fn valid_id(id: &str) -> bool {
    id.len() == 32
        && id
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

fn random_hex(length: usize) -> Result<String, SessionError> {
    let mut bytes = Zeroizing::new(vec![0u8; length]);
    getrandom::fill(&mut bytes).map_err(|_| SessionError::Internal)?;
    Ok(bytes.iter().map(|byte| format!("{byte:02x}")).collect())
}

pub(crate) async fn blocking<T: Send + 'static>(
    operation: impl FnOnce() -> Result<T, SessionError> + Send + 'static,
) -> Result<T, SessionError> {
    // Cofres e filesystem são síncronos; não bloquear o executor nem manter AUTH.
    tokio::task::spawn_blocking(operation)
        .await
        .map_err(|_| SessionError::Internal)?
}

pub(crate) fn require_store(path: &Path) -> Result<(), SessionError> {
    // Nunca recriar silenciosamente um store perdido para um device_id existente.
    if path.join("matrix-sdk-state.sqlite3").is_file() {
        Ok(())
    } else {
        Err(SessionError::CorruptedSession)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use matrix_sdk::{
        ruma::{owned_device_id, owned_user_id},
        SessionMeta, SessionTokens,
    };
    use std::{
        cell::{Cell, RefCell},
        collections::HashMap,
    };

    #[derive(Default)]
    struct FakeSecrets {
        entries: RefCell<HashMap<String, String>>,
        fail_read: Cell<bool>,
        fail_write: Cell<bool>,
    }
    impl Secrets for FakeSecrets {
        fn read(&self, id: &str) -> Result<Option<Zeroizing<String>>, SessionError> {
            if self.fail_read.get() {
                return Err(SessionError::SecureStorage);
            }
            Ok(self.entries.borrow().get(id).cloned().map(Zeroizing::new))
        }
        fn write(&self, id: &str, value: &str) -> Result<(), SessionError> {
            if self.fail_write.get() {
                return Err(SessionError::SecureStorage);
            }
            self.entries.borrow_mut().insert(id.into(), value.into());
            Ok(())
        }
    }
    struct Fixture(SessionStore<FakeSecrets>);
    impl Fixture {
        fn new() -> Self {
            Self(SessionStore {
                root: std::env::temp_dir()
                    .join(format!("matrix-session-test-{}", random_hex(16).unwrap())),
                secrets: FakeSecrets::default(),
            })
        }
        fn saved(&self) -> SavedSession {
            let (id, key, _) = self.0.prepare().unwrap();
            SavedSession::new(
                "https://example.invalid/".into(),
                id,
                key.to_string(),
                sample_session(),
            )
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0.root);
        }
    }
    fn sample_session() -> MatrixSession {
        MatrixSession {
            meta: SessionMeta {
                user_id: owned_user_id!("@fixture:example.invalid"),
                device_id: owned_device_id!("SYNTHETIC_DEVICE"),
            },
            tokens: SessionTokens {
                access_token: "non-production-synthetic-token".into(),
                refresh_token: None,
            },
        }
    }

    #[test]
    fn missing_session_does_not_access_secure_storage() {
        let fixture = Fixture::new();
        fixture.0.secrets.fail_read.set(true);
        assert!(matches!(fixture.0.load(), Ok(None)));
    }

    #[test]
    fn secure_round_trip_writes_only_non_secret_manifest() {
        let fixture = Fixture::new();
        let saved = fixture.saved();
        fixture.0.persist(&saved).unwrap();
        let loaded = fixture.0.load().unwrap().unwrap();
        assert!(loaded.session == saved.session);
        assert!(loaded.passphrase == saved.passphrase);
        fixture.0.secrets.fail_read.set(true);
        assert!(matches!(fixture.0.load(), Err(SessionError::SecureStorage)));
        fixture.0.secrets.fail_read.set(false);
        assert!(fixture.0.load().unwrap().unwrap().session == saved.session);
        let manifest = fs::read(fixture.0.root.join("active-session.json")).unwrap();
        let parsed: serde_json::Value = serde_json::from_slice(&manifest).unwrap();
        assert_eq!(parsed.as_object().unwrap().len(), 2);
        for secret in [&saved.passphrase, &saved.session.tokens.access_token] {
            assert!(!manifest
                .windows(secret.len())
                .any(|bytes| bytes == secret.as_bytes()));
        }
    }

    #[test]
    fn corrupt_metadata_and_missing_credentials_are_safe() {
        let fixture = Fixture::new();
        let saved = fixture.saved();
        fixture.0.persist(&saved).unwrap();
        fixture.0.secrets.entries.borrow_mut().clear();
        assert!(matches!(
            fixture.0.load(),
            Err(SessionError::CorruptedSession)
        ));
        fixture
            .0
            .secrets
            .entries
            .borrow_mut()
            .insert(saved.store_id.clone(), "invalid-json".into());
        assert!(matches!(
            fixture.0.load(),
            Err(SessionError::CorruptedSession)
        ));
        fs::write(fixture.0.root.join("active-session.json"), b"broken").unwrap();
        assert!(matches!(
            fixture.0.load(),
            Err(SessionError::CorruptedSession)
        ));
        assert!(fixture.0.store_path("../../outside").is_err());
    }

    #[test]
    fn secure_storage_failures_and_commit_failure_preserve_previous_session() {
        let fixture = Fixture::new();
        let previous = fixture.saved();
        fixture.0.persist(&previous).unwrap();
        fixture.0.secrets.fail_read.set(true);
        assert!(matches!(fixture.0.load(), Err(SessionError::SecureStorage)));
        fixture.0.secrets.fail_read.set(false);
        let candidate = fixture.saved();
        fixture.0.secrets.fail_write.set(true);
        assert_eq!(
            fixture.0.persist(&candidate),
            Err(SessionError::SecureStorage)
        );
        fixture.0.secrets.fail_write.set(false);
        assert!(fixture.0.load().unwrap().unwrap().store_id == previous.store_id);
        // Falha de publicação após salvar no cofre não torna o candidato ativo.
        fs::rename(
            fixture.0.root.join("active-session.json"),
            fixture.0.root.join("previous.json"),
        )
        .unwrap();
        fs::create_dir(fixture.0.root.join("active-session.json")).unwrap();
        assert_eq!(
            fixture.0.persist(&candidate),
            Err(SessionError::Persistence)
        );
        assert!(fixture
            .0
            .secrets
            .entries
            .borrow()
            .contains_key(&candidate.store_id));
    }

    #[tokio::test]
    async fn sdk_store_reopens_with_same_session_and_rejects_wrong_passphrase() {
        let fixture = Fixture::new();
        let saved = fixture.saved();
        let path = fixture.0.store_path(&saved.store_id).unwrap();
        let builder = || {
            matrix::client_builder(matrix::validate_address(&saved.homeserver).unwrap()).unwrap()
        };
        let client = builder()
            .sqlite_store(&path, Some(&saved.passphrase))
            .build()
            .await
            .unwrap();
        client
            .matrix_auth()
            .restore_session(
                saved.session.clone(),
                matrix_sdk::store::RoomLoadSettings::default(),
            )
            .await
            .unwrap();
        let sdk_marker = "synthetic-sdk-sync-state-marker";
        client
            .state_store()
            .set_kv_data(
                matrix_sdk::store::StateStoreDataKey::SyncToken,
                matrix_sdk::store::StateStoreDataValue::SyncToken(sdk_marker.into()),
            )
            .await
            .unwrap();
        fixture.0.persist(&saved).unwrap();
        drop(client);
        require_store(&path).unwrap();
        let reopened = builder()
            .sqlite_store(&path, Some(&saved.passphrase))
            .build()
            .await
            .unwrap();
        reopened
            .matrix_auth()
            .restore_session(
                saved.session.clone(),
                matrix_sdk::store::RoomLoadSettings::default(),
            )
            .await
            .unwrap();
        let restored_state = reopened
            .state_store()
            .get_kv_data(matrix_sdk::store::StateStoreDataKey::SyncToken)
            .await
            .unwrap()
            .and_then(|value| value.into_sync_token());
        assert!(restored_state.as_deref() == Some(sdk_marker));
        assert!(reopened.user_id() == Some(&saved.session.meta.user_id));
        assert!(reopened.device_id() == Some(&saved.session.meta.device_id));
        assert!(builder()
            .sqlite_store(&path, Some("synthetic-wrong-passphrase"))
            .build()
            .await
            .is_err());
        // Inspeciona bytes sem imprimir segredos nem depender do diretório real.
        for entry in fs::read_dir(&path).unwrap() {
            let bytes = fs::read(entry.unwrap().path()).unwrap();
            assert!(!bytes
                .windows(sdk_marker.len())
                .any(|window| window == sdk_marker.as_bytes()));
            for secret in [&saved.passphrase, &saved.session.tokens.access_token] {
                assert!(!bytes
                    .windows(secret.len())
                    .any(|window| window == secret.as_bytes()));
            }
        }
    }
}
