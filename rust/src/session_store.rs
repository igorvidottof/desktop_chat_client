use std::{
    fs,
    io::Write,
    path::{Path, PathBuf},
    sync::Mutex,
};

use directories::ProjectDirs;
use matrix_sdk::authentication::matrix::MatrixSession;
use serde::{Deserialize, Serialize};
use zeroize::{Zeroize, Zeroizing};

use crate::{api::simple::SessionError, matrix};

const SERVICE: &str = "desktop_chat_client.matrix.v1";

// Retained until native process exit, including logout and Dart hot restart.
// Never unlink this file: a second inode would permit two owners of one root.
static PROCESS_LOCK: Mutex<Option<fs::File>> = Mutex::new(None);

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct CleanupRecord {
    version: u8,
    store_id: String,
}

struct ProcessOwnership {
    file: fs::File,
    root: PathBuf,
}

impl ProcessOwnership {
    fn acquire(root: &Path) -> Result<Self, SessionError> {
        fs::create_dir_all(root).map_err(|_| SessionError::Persistence)?;
        reject_symlink(root)?;
        let path = root.join("process.lock");
        reject_symlink(&path)?;
        let file = fs::OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .open(path)
            .map_err(|_| SessionError::Persistence)?;
        file.try_lock().map_err(|error| match error {
            std::fs::TryLockError::WouldBlock => SessionError::OperationInProgress,
            std::fs::TryLockError::Error(_) => SessionError::Persistence,
        })?;
        Ok(Self {
            file,
            root: root.to_owned(),
        })
    }
}

pub(crate) fn initialize_local_lifecycle() -> Result<(), SessionError> {
    initialize_lifecycle(&PROCESS_LOCK, &SessionStore::platform()?)
}

fn initialize_lifecycle<S: Secrets>(
    process_lock: &Mutex<Option<fs::File>>,
    store: &SessionStore<S>,
) -> Result<(), SessionError> {
    let mut lock = process_lock.lock().map_err(|_| SessionError::Internal)?;
    if lock.is_none() {
        let owner = ProcessOwnership::acquire(&store.root)?;
        let pending = store.cleanup_at_process_start(&owner)?;
        if pending > 0 {
            eprintln!("Matrix session-store cleanup remains pending.");
        }
        *lock = Some(owner.file);
    }
    Ok(())
}

fn reject_symlink(path: &Path) -> Result<(), SessionError> {
    match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.file_type().is_symlink() => Err(SessionError::CorruptedSession),
        Ok(_) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(_) => Err(SessionError::Persistence),
    }
}

fn sync_directory(path: &Path) -> Result<(), SessionError> {
    #[cfg(unix)]
    fs::File::open(path)
        .and_then(|dir| dir.sync_all())
        .map_err(|_| SessionError::Persistence)?;
    #[cfg(not(unix))]
    let _ = path;
    Ok(())
}

// O manifest contém um identificador opaco, nunca credenciais.
// Cada tentativa usa outra pasta: uma falha não mistura contas no store do SDK.
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Manifest {
    version: u8,
    store_id: String,
    // Compatibilidade de leitura: o marcador anterior não controla mais a sessão.
    #[serde(rename = "crypto", default, skip_serializing)]
    _legacy_metadata: Option<serde::de::IgnoredAny>,
}

// Serializamos o tipo oficial do SDK dentro do cofre do SO, não em arquivo JSON.
// O dispositivo e o store correspondem à sessão autenticada que será restaurada.
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
    fn delete(&self, id: &str) -> Result<(), SessionError>;
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

    fn delete(&self, id: &str) -> Result<(), SessionError> {
        let entry = keyring::Entry::new(SERVICE, id).map_err(|_| SessionError::SecureStorage)?;
        // Ausência já satisfaz a remoção; indisponibilidade do cofre exige retry.
        match entry.delete_credential() {
            Ok(()) | Err(keyring::Error::NoEntry) => Ok(()),
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

    fn active_manifest(&self) -> Result<Option<Manifest>, SessionError> {
        let path = self.root.join("active-session.json");
        reject_symlink(&path)?;
        let bytes = match fs::read(path) {
            Ok(bytes) => bytes,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(_) => return Err(SessionError::Persistence),
        };
        let manifest: Manifest =
            serde_json::from_slice(&bytes).map_err(|_| SessionError::CorruptedSession)?;
        if !matches!(manifest.version, 1 | 2) || !valid_id(&manifest.store_id) {
            return Err(SessionError::CorruptedSession);
        }
        Ok(Some(manifest))
    }

    fn cleanup_path(&self, id: &str) -> Result<PathBuf, SessionError> {
        self.store_path(id)?;
        Ok(self.root.join(format!("cleanup-{id}.json")))
    }

    fn read_cleanup(&self, id: &str) -> Result<CleanupRecord, SessionError> {
        let path = self.cleanup_path(id)?;
        reject_symlink(&path)?;
        let record: CleanupRecord =
            serde_json::from_slice(&fs::read(path).map_err(|_| SessionError::Persistence)?)
                .map_err(|_| SessionError::CorruptedSession)?;
        if record.version != 1 || record.store_id != id || !valid_id(&record.store_id) {
            return Err(SessionError::CorruptedSession);
        }
        Ok(record)
    }

    pub(crate) fn record_cleanup(&self, id: &str) -> Result<(), SessionError> {
        let path = self.cleanup_path(id)?;
        if path.exists() {
            self.read_cleanup(id)?;
            return sync_directory(&self.root);
        }
        let bytes = serde_json::to_vec(&CleanupRecord {
            version: 1,
            store_id: id.into(),
        })
        .map_err(|_| SessionError::Internal)?;
        let pending = self.root.join(format!("pending-{}.json", random_hex(16)?));
        let mut file = fs::File::create_new(&pending).map_err(|_| SessionError::Persistence)?;
        file.write_all(&bytes)
            .and_then(|_| file.sync_all())
            .map_err(|_| SessionError::Persistence)?;
        drop(file);
        fs::rename(pending, path).map_err(|_| SessionError::Persistence)?;
        sync_directory(&self.root)
    }

    // Only called once with newly acquired process ownership, before ANY persistent
    // SDK client opens. Never call after logout or on a Dart hot restart.
    fn cleanup_at_process_start(&self, owner: &ProcessOwnership) -> Result<usize, SessionError> {
        if owner.root != self.root {
            return Err(SessionError::Persistence);
        }
        let mut active = self.active_manifest()?;
        let mut pending = 0;
        for entry in fs::read_dir(&self.root).map_err(|_| SessionError::Persistence)? {
            let entry = entry.map_err(|_| SessionError::Persistence)?;
            let name = entry.file_name();
            let Some(name) = name.to_str() else { continue };
            let Some(id) = name
                .strip_prefix("cleanup-")
                .and_then(|s| s.strip_suffix(".json"))
            else {
                continue;
            };
            self.read_cleanup(id)?;
            // A record expresses intent, not proof of credential revocation. A:
            // if the credential still exists, protect the store (active or not).
            match self.secrets.read(id) {
                Ok(None) => {}
                Ok(Some(_)) | Err(_) => {
                    pending += 1;
                    continue;
                }
            }
            if active
                .as_ref()
                .is_some_and(|manifest| manifest.store_id == id)
            {
                // B: credential removal was committed, but manifest removal was
                // interrupted. Remove only this exact now-non-restorable manifest.
                fs::remove_file(self.root.join("active-session.json"))
                    .map_err(|_| SessionError::Persistence)?;
                sync_directory(&self.root)?;
                active = None;
            }
            // C/D: failures retain tracking; absent stores are idempotent success.
            if self.remove_store(id).is_err() {
                pending += 1;
                continue;
            }
            if fs::remove_file(self.cleanup_path(id)?).is_err()
                || sync_directory(&self.root).is_err()
            {
                pending += 1;
            }
        }
        Ok(pending)
    }

    pub(crate) fn load(&self) -> Result<Option<SavedSession>, SessionError> {
        let Some(manifest) = self.active_manifest()? else {
            return Ok(None);
        };
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

    pub(crate) fn remove_restoration(&self, id: &str) -> Result<(), SessionError> {
        self.record_cleanup(id)?;
        // O cofre reúne sessão e passphrase numa só entrada. Apagá-la primeiro
        // impede restauração mesmo se a retirada durável do manifest falhar.
        // Mantemos o ID no cliente para retry sem reler segredos já removidos.
        self.secrets.delete(id)?;
        let active = self.root.join("active-session.json");
        match fs::read(&active) {
            Ok(bytes) => {
                let manifest: Manifest =
                    serde_json::from_slice(&bytes).map_err(|_| SessionError::CorruptedSession)?;
                if !matches!(manifest.version, 1 | 2) || manifest.store_id != id {
                    return Err(SessionError::CorruptedSession);
                }
                fs::remove_file(active).map_err(|_| SessionError::Persistence)?;
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(_) => return Err(SessionError::Persistence),
        }
        #[cfg(unix)]
        fs::File::open(&self.root)
            .and_then(|dir| dir.sync_all())
            .map_err(|_| SessionError::Persistence)?;
        Ok(())
    }

    fn remove_store(&self, id: &str) -> Result<(), SessionError> {
        // Produção chama somente no início de um novo processo, antes de abrir SDK stores.
        // Nunca removemos a raiz nem stores de outras tentativas/contas.
        let path = self.store_path(id)?;
        if self
            .active_manifest()?
            .is_some_and(|manifest| manifest.store_id == id)
            || self.secrets.read(id)?.is_some()
        {
            return Err(SessionError::Persistence);
        }
        reject_symlink(&self.root)?;
        reject_symlink(&self.root.join("stores"))?;
        reject_symlink(&path)?;
        match fs::remove_dir_all(&path) {
            Ok(()) => sync_directory(&self.root.join("stores")),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(_) => Err(SessionError::Persistence),
        }
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
        // Órfãos de tentativas não publicadas ficam para limpeza futura; logout
        // remove somente os recursos da sessão ativa, sem enumerar outras contas.
        self.secrets.write(&saved.store_id, &encoded)?;
        let manifest = serde_json::to_vec(&Manifest {
            version: 1,
            store_id: saved.store_id.clone(),
            _legacy_metadata: None,
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
        fail_delete: Cell<bool>,
    }
    impl Secrets for FakeSecrets {
        fn read(&self, id: &str) -> Result<Option<Zeroizing<String>>, SessionError> {
            if self.fail_read.get() {
                return Err(SessionError::SecureStorage);
            }
            Ok(self.entries.borrow().get(id).cloned().map(Zeroizing::new))
        }
        fn delete(&self, id: &str) -> Result<(), SessionError> {
            if self.fail_delete.get() {
                return Err(SessionError::SecureStorage);
            }
            self.entries.borrow_mut().remove(id);
            Ok(())
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
    #[test]
    fn previous_manifest_restores_session_and_logout_removes_authority() {
        for marker in ["MigrationInProgress", "CryptoInitialized"] {
            let fixture = Fixture::new();
            let saved = fixture.saved();
            fixture.0.persist(&saved).unwrap();
            let active = fixture.0.root.join("active-session.json");
            fs::write(
                &active,
                serde_json::json!({
                    "version": 2, "store_id": saved.store_id, "crypto": marker,
                })
                .to_string(),
            )
            .unwrap();
            let loaded = fixture.0.load().unwrap().unwrap();
            assert!(loaded.session == saved.session);
            assert!(loaded.passphrase == saved.passphrase);
            fixture.0.persist(&loaded).unwrap();
            let manifest: serde_json::Value =
                serde_json::from_slice(&fs::read(&active).unwrap()).unwrap();
            assert_eq!(manifest["version"], 1);
            assert!(manifest.get("crypto").is_none());
            fixture.0.remove_restoration(&saved.store_id).unwrap();
            assert!(fixture.0.load().unwrap().is_none());
            assert!(!active.exists());
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
    fn logout_removes_only_active_resources_and_restart_is_empty() {
        let fixture = Fixture::new();
        let active = fixture.saved();
        let other = fixture.saved();
        fixture.0.persist(&active).unwrap();
        fixture
            .0
            .secrets
            .write(&other.store_id, "synthetic-other-entry")
            .unwrap();
        fixture.0.remove_restoration(&active.store_id).unwrap();
        fixture.0.remove_store(&active.store_id).unwrap();
        assert!(fixture.0.load().unwrap().is_none());
        assert!(fixture.0.secrets.read(&active.store_id).unwrap().is_none());
        assert!(!fixture.0.store_path(&active.store_id).unwrap().exists());
        assert!(fixture.0.store_path(&other.store_id).unwrap().exists());
        assert!(fixture.0.secrets.read(&other.store_id).unwrap().is_some());
        // Ausência de entrada e arquivos é idempotente, inclusive após retry.
        fixture.0.remove_restoration(&active.store_id).unwrap();
        fixture.0.remove_store(&active.store_id).unwrap();
        fixture.0.persist(&other).unwrap();
        assert_eq!(fixture.0.load().unwrap().unwrap().store_id, other.store_id);
    }

    #[test]
    fn credential_failure_preserves_manifest_and_retry_removes_session() {
        let fixture = Fixture::new();
        let active = fixture.saved();
        fixture.0.persist(&active).unwrap();
        fixture.0.secrets.fail_delete.set(true);
        assert_eq!(
            fixture.0.remove_restoration(&active.store_id),
            Err(SessionError::SecureStorage)
        );
        assert!(fixture.0.load().unwrap().is_some());
        fixture.0.secrets.fail_delete.set(false);
        fixture.0.remove_restoration(&active.store_id).unwrap();
        assert!(fixture.0.load().unwrap().is_none());
    }

    #[test]
    fn manifest_failure_never_reports_success_and_does_not_delete_other_manifest() {
        let fixture = Fixture::new();
        let active = fixture.saved();
        fixture.0.persist(&active).unwrap();
        fs::remove_file(fixture.0.root.join("active-session.json")).unwrap();
        fs::create_dir(fixture.0.root.join("active-session.json")).unwrap();
        assert_eq!(
            fixture.0.remove_restoration(&active.store_id),
            Err(SessionError::Persistence)
        );
        assert!(fixture.0.secrets.read(&active.store_id).unwrap().is_none());
        fs::remove_dir(fixture.0.root.join("active-session.json")).unwrap();
        fixture.0.remove_restoration(&active.store_id).unwrap();
        let other = fixture.saved();
        fixture.0.persist(&other).unwrap();
        assert_eq!(
            fixture.0.remove_restoration(&active.store_id),
            Err(SessionError::CorruptedSession)
        );
        assert_eq!(fixture.0.load().unwrap().unwrap().store_id, other.store_id);
    }

    #[test]
    fn store_failure_cannot_restore_after_credential_and_manifest_removal() {
        let fixture = Fixture::new();
        let active = fixture.saved();
        fixture.0.persist(&active).unwrap();
        fixture.0.remove_restoration(&active.store_id).unwrap();
        let path = fixture.0.store_path(&active.store_id).unwrap();
        fs::remove_dir(&path).unwrap();
        fs::write(&path, b"synthetic-obstruction").unwrap();
        assert_eq!(
            fixture.0.remove_store(&active.store_id),
            Err(SessionError::Persistence)
        );
        assert!(fixture.0.load().unwrap().is_none());
        assert!(fixture.0.secrets.read(&active.store_id).unwrap().is_none());
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

    fn restart_cleanup(fixture: &Fixture) -> usize {
        let owner = ProcessOwnership::acquire(&fixture.0.root).unwrap();
        fixture.0.cleanup_at_process_start(&owner).unwrap()
    }

    #[test]
    fn crash_before_credential_removal_protects_active_restorable_store() {
        let fixture = Fixture::new();
        let saved = fixture.saved();
        fixture.0.persist(&saved).unwrap();
        fixture.0.record_cleanup(&saved.store_id).unwrap();
        assert_eq!(restart_cleanup(&fixture), 1);
        assert!(fixture.0.load().unwrap().unwrap().session == saved.session);
        assert!(fixture.0.store_path(&saved.store_id).unwrap().exists());
        assert_eq!(
            fixture.0.remove_store(&saved.store_id),
            Err(SessionError::Persistence)
        );
    }

    #[test]
    fn crash_after_credential_removal_resolves_only_matching_manifest() {
        let fixture = Fixture::new();
        let saved = fixture.saved();
        fixture.0.persist(&saved).unwrap();
        fixture.0.record_cleanup(&saved.store_id).unwrap();
        fixture.0.secrets.delete(&saved.store_id).unwrap();
        assert_eq!(restart_cleanup(&fixture), 0);
        assert!(fixture.0.load().unwrap().is_none());
        assert!(!fixture.0.store_path(&saved.store_id).unwrap().exists());
        assert!(!fixture.0.cleanup_path(&saved.store_id).unwrap().exists());
    }

    #[test]
    fn revoked_orphan_is_cleaned_before_an_unrelated_session_is_loaded() {
        let fixture = Fixture::new();
        let old = fixture.saved();
        fixture.0.persist(&old).unwrap();
        fixture.0.remove_restoration(&old.store_id).unwrap();
        let active = fixture.saved();
        fixture.0.persist(&active).unwrap();
        assert_eq!(restart_cleanup(&fixture), 0);
        assert!(!fixture.0.store_path(&old.store_id).unwrap().exists());
        assert!(fixture.0.load().unwrap().unwrap().session == active.session);
        assert!(fixture.0.store_path(&active.store_id).unwrap().exists());
    }

    #[test]
    fn deleted_store_with_stale_record_is_idempotently_resolved() {
        let fixture = Fixture::new();
        let saved = fixture.saved();
        fixture.0.persist(&saved).unwrap();
        fixture.0.remove_restoration(&saved.store_id).unwrap();
        fixture.0.remove_store(&saved.store_id).unwrap();
        assert!(fixture.0.cleanup_path(&saved.store_id).unwrap().exists());
        assert_eq!(restart_cleanup(&fixture), 0);
        assert_eq!(restart_cleanup(&fixture), 0);
        assert!(!fixture.0.cleanup_path(&saved.store_id).unwrap().exists());
    }

    #[test]
    fn deletion_failure_keeps_record_and_does_not_block_unrelated_restoration() {
        let fixture = Fixture::new();
        let old = fixture.saved();
        fixture.0.persist(&old).unwrap();
        fixture.0.remove_restoration(&old.store_id).unwrap();
        // Deterministic isolated fixture: a file cannot be removed as a directory.
        let path = fixture.0.store_path(&old.store_id).unwrap();
        fs::remove_dir(&path).unwrap();
        fs::write(&path, b"synthetic-obstruction").unwrap();
        let active = fixture.saved();
        fixture.0.persist(&active).unwrap();
        assert_eq!(restart_cleanup(&fixture), 1);
        assert!(fixture.0.cleanup_path(&old.store_id).unwrap().exists());
        assert!(fixture.0.load().unwrap().unwrap().store_id == active.store_id);
        fs::remove_file(&path).unwrap();
        assert_eq!(restart_cleanup(&fixture), 0);
    }

    #[test]
    fn cleanup_intent_survives_credential_failure_and_contains_no_secrets() {
        let fixture = Fixture::new();
        let saved = fixture.saved();
        fixture.0.persist(&saved).unwrap();
        fixture.0.secrets.fail_delete.set(true);
        assert_eq!(
            fixture.0.remove_restoration(&saved.store_id),
            Err(SessionError::SecureStorage)
        );
        assert_eq!(restart_cleanup(&fixture), 1);
        let bytes = fs::read(fixture.0.cleanup_path(&saved.store_id).unwrap()).unwrap();
        let value: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(value.as_object().unwrap().len(), 2);
        for secret in [&saved.passphrase, &saved.session.tokens.access_token] {
            assert!(!bytes
                .windows(secret.len())
                .any(|window| window == secret.as_bytes()));
        }
        fixture.0.secrets.fail_delete.set(false);
        fixture.0.remove_restoration(&saved.store_id).unwrap();
        assert_eq!(restart_cleanup(&fixture), 0);
    }

    #[test]
    fn cleanup_rejects_untrusted_ids_and_mismatched_records() {
        let fixture = Fixture::new();
        for id in [
            "../outside",
            "/tmp/outside",
            "",
            "ABCDEF0123456789abcdef0123456789",
            "a/../../outside",
        ] {
            assert!(fixture.0.record_cleanup(id).is_err());
            assert!(fixture.0.remove_store(id).is_err());
        }
        let saved = fixture.saved();
        let owner = ProcessOwnership::acquire(&fixture.0.root).unwrap();
        fs::write(
            fixture.0.cleanup_path(&saved.store_id).unwrap(),
            br#"{"version":1,"store_id":"../../outside"}"#,
        )
        .unwrap();
        assert_eq!(
            fixture.0.cleanup_at_process_start(&owner),
            Err(SessionError::CorruptedSession)
        );
        assert!(fixture.0.store_path(&saved.store_id).unwrap().exists());
    }

    #[cfg(unix)]
    #[test]
    fn cleanup_rejects_symlinked_store_parent() {
        let fixture = Fixture::new();
        let saved = fixture.saved();
        fixture.0.persist(&saved).unwrap();
        fixture.0.remove_restoration(&saved.store_id).unwrap();
        let stores = fixture.0.root.join("stores");
        let target = fixture.0.root.join("outside");
        fs::rename(&stores, &target).unwrap();
        std::os::unix::fs::symlink(&target, &stores).unwrap();
        assert_eq!(restart_cleanup(&fixture), 1);
        assert!(target.join(&saved.store_id).exists());
    }

    #[test]
    fn process_lock_probe() {
        if let Some(root) = std::env::var_os("MATRIX_LOCK_TEST_ROOT") {
            assert!(matches!(
                ProcessOwnership::acquire(Path::new(&root)),
                Err(SessionError::OperationInProgress)
            ));
        }
    }

    #[test]
    fn process_lock_excludes_another_native_process_and_releases_on_drop() {
        let fixture = Fixture::new();
        let owner = ProcessOwnership::acquire(&fixture.0.root).unwrap();
        let output = std::process::Command::new(std::env::current_exe().unwrap())
            .args(["session_store::tests::process_lock_probe", "--exact"])
            .env("MATRIX_LOCK_TEST_ROOT", &fixture.0.root)
            .output()
            .unwrap();
        assert!(output.status.success(), "lock probe failed");
        drop(owner);
        assert!(ProcessOwnership::acquire(&fixture.0.root).is_ok());
    }

    #[test]
    fn cleanup_runs_once_and_never_deletes_a_store_used_in_this_process() {
        let fixture = Fixture::new();
        let process_lock = Mutex::new(None);
        initialize_lifecycle(&process_lock, &fixture.0).unwrap();
        let saved = fixture.saved();
        fixture.0.persist(&saved).unwrap();
        fixture.0.remove_restoration(&saved.store_id).unwrap();
        initialize_lifecycle(&process_lock, &fixture.0).unwrap();
        assert!(fixture.0.store_path(&saved.store_id).unwrap().exists());
        assert!(fixture.0.cleanup_path(&saved.store_id).unwrap().exists());
        drop(process_lock);
        assert_eq!(restart_cleanup(&fixture), 0);
    }

    #[test]
    fn record_write_failure_cannot_revoke_credentials_or_publish_logout() {
        let fixture = Fixture::new();
        let saved = fixture.saved();
        fixture.0.persist(&saved).unwrap();
        fs::create_dir(fixture.0.cleanup_path(&saved.store_id).unwrap()).unwrap();
        assert_eq!(
            fixture.0.remove_restoration(&saved.store_id),
            Err(SessionError::Persistence)
        );
        assert!(fixture.0.load().unwrap().unwrap().store_id == saved.store_id);
        assert!(fixture.0.secrets.read(&saved.store_id).unwrap().is_some());
    }

    #[test]
    fn credentials_protect_unreferenced_store_and_wrong_root_lock_is_rejected() {
        let fixture = Fixture::new();
        let saved = fixture.saved();
        fixture.0.persist(&saved).unwrap();
        fixture.0.record_cleanup(&saved.store_id).unwrap();
        fs::remove_file(fixture.0.root.join("active-session.json")).unwrap();
        assert_eq!(restart_cleanup(&fixture), 1);
        assert!(fixture.0.store_path(&saved.store_id).unwrap().exists());
        let other = Fixture::new();
        let owner = ProcessOwnership::acquire(&other.0.root).unwrap();
        assert_eq!(
            fixture.0.cleanup_at_process_start(&owner),
            Err(SessionError::Persistence)
        );
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
        // Fecha os bancos pelo ciclo de vida suportado pelo SDK antes da exclusão.
        reopened.pause().await.unwrap();
        drop(reopened);
        fixture.0.remove_restoration(&saved.store_id).unwrap();
        fixture.0.remove_store(&saved.store_id).unwrap();
        assert!(fixture.0.load().unwrap().is_none());
        assert!(!path.exists());
    }
}
