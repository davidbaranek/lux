//! The stores' encryption against the SDK's mock server: a new account's stores are encrypted,
//! and a kept session is opened only over its own encrypted store.

use std::path::Path;
use std::sync::{Arc, Mutex};

use lux_core::ports::{BackendError, SecretStore, SecretStoreError, SessionSecrets, SignIn, StoreKey, UnusableStore};
use matrix_sdk::Client;
use matrix_sdk::test_utils::mocks::MatrixMockServer;

use super::files::{self, Encryption};
use super::{CRYPTO_STORE, Process, StoreFolder};
use crate::session;
use crate::sign_in::{MatrixSignIn, restored_client};

/// The state store's file in `data/`.
const STATE_STORE: &str = "matrix-sdk-state.sqlite3";

/// The platform's Keychain, in memory.
#[derive(Default)]
struct MemorySecrets {
    session: Mutex<Option<SessionSecrets>>,
    key: Mutex<Option<StoreKey>>,
}

impl MemorySecrets {
    fn is_empty(&self) -> bool {
        self.session.lock().unwrap().is_none() && self.key.lock().unwrap().is_none()
    }
}

impl SecretStore for MemorySecrets {
    fn load(&self) -> Result<Option<SessionSecrets>, SecretStoreError> {
        Ok(self.session.lock().unwrap().clone())
    }

    fn save(&self, secrets: &SessionSecrets) -> Result<(), SecretStoreError> {
        *self.session.lock().unwrap() = Some(secrets.clone());
        Ok(())
    }

    fn store_key(&self) -> Result<Option<StoreKey>, SecretStoreError> {
        Ok(self.key.lock().unwrap().clone())
    }

    fn save_store_key(&self, key: &StoreKey) -> Result<(), SecretStoreError> {
        *self.key.lock().unwrap() = Some(key.clone());
        Ok(())
    }

    fn delete(&self) -> Result<(), SecretStoreError> {
        *self.session.lock().unwrap() = None;
        *self.key.lock().unwrap() = None;
        Ok(())
    }
}

async fn server() -> MatrixMockServer {
    let server = MatrixMockServer::new().await;
    server.mock_versions().with_simplified_sliding_sync().ok().mount().await;
    server.mock_login().ok().mount().await;
    server
}

fn encryption(file: &Path) -> Encryption {
    files::encryption(file).unwrap()
}

/// Runs `setup` on a runtime of its own, ended before this returns: the clients it made have
/// closed their stores, as at the next launch. Dropping a client leaves its tasks to close the
/// stores later, while the test already deletes or opens them.
async fn closed<T: Send + 'static>(setup: impl Future<Output = T> + Send + 'static) -> T {
    let (sender, done) = tokio::sync::oneshot::channel();
    std::thread::spawn(move || {
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()
            .unwrap();
        let value = runtime.block_on(setup);
        // waits for the tasks and the stores' blocking work to end.
        drop(runtime);
        let _ = sender.send(value);
    });
    done.await.unwrap()
}

/// A folder signed in to `server` by the app: its stores encrypted, its session and key kept.
async fn signed_in(server: &MatrixMockServer) -> (tempfile::TempDir, StoreFolder, Arc<MemorySecrets>) {
    let root = tempfile::tempdir().unwrap();
    let folder = StoreFolder::new(root.path().join("account"));
    let secrets = Arc::new(MemorySecrets::default());
    let (server, made) = (server.uri(), (folder.clone(), secrets.clone()));
    closed(async move {
        MatrixSignIn::new(made.0, made.1)
            .sign_in_with_password(&server, "cheeky_monkey", "secret", "Lux (Test)")
            .await
            .unwrap();
    })
    .await;
    (root, folder, secrets)
}

/// A folder signed in to `server` with a plain store (no key), its session kept.
async fn signed_in_plain(server: &MatrixMockServer) -> (tempfile::TempDir, StoreFolder, Arc<MemorySecrets>) {
    let root = tempfile::tempdir().unwrap();
    let folder = StoreFolder::new(root.path().join("account"));
    let secrets = Arc::new(MemorySecrets::default());
    let (server, made) = (server.uri(), (folder.clone(), secrets.clone()));
    closed(async move {
        let client = Client::builder()
            .sqlite_store(made.0.data(), None)
            .homeserver_url(server)
            .build()
            .await
            .unwrap();
        client
            .matrix_auth()
            .login_username("cheeky_monkey", "secret")
            .await
            .unwrap();
        session::save(&client, made.1.as_ref()).unwrap();
    })
    .await;
    assert!(folder.holds_device());
    assert_eq!(folder.encryption().unwrap(), Encryption::Plain);
    (root, folder, secrets)
}

async fn restore(
    folder: &StoreFolder,
    secrets: &Arc<MemorySecrets>,
    process: Process,
) -> Result<Option<Client>, BackendError> {
    let secrets: Arc<dyn SecretStore> = secrets.clone();
    restored_client(folder, &secrets, process).await
}

/// The app opened nothing, and forgot the account: its folder and secrets are gone.
async fn assert_forgotten(folder: &StoreFolder, secrets: &Arc<MemorySecrets>) {
    let restored = restore(folder, secrets, Process::App).await;
    assert!(
        matches!(restored, Ok(None)),
        "{:?}",
        restored.map(|client| client.is_some())
    );
    assert!(!folder.root().exists(), "the folder is deleted");
    assert!(secrets.is_empty(), "the secrets are deleted");
}

#[tokio::test(flavor = "multi_thread")]
async fn a_new_sign_in_makes_encrypted_stores_that_open_again() {
    let server = server().await;
    let (_root, folder, secrets) = signed_in(&server).await;

    assert!(secrets.store_key().unwrap().is_some());
    assert_eq!(folder.encryption().unwrap(), Encryption::Encrypted);
    assert_eq!(encryption(&folder.data().join(STATE_STORE)), Encryption::Encrypted);
    for cache in ["matrix-sdk-event-cache.sqlite3", "matrix-sdk-media.sqlite3"] {
        assert_eq!(
            encryption(&folder.cache().join(cache)),
            Encryption::Encrypted,
            "{cache}"
        );
    }

    drop(restore(&folder, &secrets, Process::App).await.unwrap().unwrap());
    assert!(
        restore(&folder, &secrets, Process::NotificationExtension)
            .await
            .unwrap()
            .is_some()
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn the_app_forgets_an_account_whose_store_is_plain() {
    let server = server().await;
    let (_root, folder, secrets) = signed_in_plain(&server).await;
    assert_forgotten(&folder, &secrets).await;
}

#[tokio::test(flavor = "multi_thread")]
async fn the_extension_never_opens_a_plain_store_and_leaves_it() {
    let server = server().await;
    let (_root, folder, secrets) = signed_in_plain(&server).await;

    let refused = restore(&folder, &secrets, Process::NotificationExtension).await;
    assert!(matches!(
        refused,
        Err(BackendError::StoreUnusable(UnusableStore::NotEncrypted))
    ));
    assert!(folder.data().join(CRYPTO_STORE).is_file());
    assert_eq!(folder.encryption().unwrap(), Encryption::Plain);
    assert!(secrets.load().unwrap().is_some());
}

#[tokio::test(flavor = "multi_thread")]
async fn the_app_forgets_an_account_whose_key_is_gone() {
    let server = server().await;
    let (_root, folder, secrets) = signed_in(&server).await;
    *secrets.key.lock().unwrap() = None;

    let refused = restore(&folder, &secrets, Process::NotificationExtension).await;
    assert!(matches!(
        refused,
        Err(BackendError::StoreUnusable(UnusableStore::KeyMissing))
    ));
    assert_forgotten(&folder, &secrets).await;
}

#[tokio::test(flavor = "multi_thread")]
async fn the_app_forgets_an_account_its_key_does_not_open() {
    let server = server().await;
    let (_root, folder, secrets) = signed_in(&server).await;
    *secrets.key.lock().unwrap() = Some(StoreKey::from_bytes(&[9; 32]).unwrap());

    let refused = restore(&folder, &secrets, Process::NotificationExtension).await;
    assert!(
        matches!(refused, Err(BackendError::StoreUnusable(UnusableStore::WrongKey))),
        "{refused:?}"
    );
    assert!(folder.holds_device(), "the extension deletes nothing");
    assert_forgotten(&folder, &secrets).await;
}

#[tokio::test(flavor = "multi_thread")]
async fn the_app_forgets_an_account_whose_store_is_missing() {
    let server = server().await;
    let (_root, folder, secrets) = signed_in(&server).await;
    std::fs::remove_dir_all(folder.data()).unwrap();

    let refused = restore(&folder, &secrets, Process::NotificationExtension).await;
    assert!(matches!(
        refused,
        Err(BackendError::StoreUnusable(UnusableStore::Missing))
    ));
    assert!(!folder.data().exists(), "nothing is made in its place");
    assert_forgotten(&folder, &secrets).await;
}

/// A folder a sign-out or an earlier build left in `stores`, holding a device's keys.
fn orphan(stores: &Path, name: &str) -> std::path::PathBuf {
    let orphan = stores.join(name);
    std::fs::create_dir_all(orphan.join("data")).unwrap();
    std::fs::write(orphan.join("data").join(CRYPTO_STORE), b"keys").unwrap();
    orphan
}

#[tokio::test(flavor = "multi_thread")]
async fn an_open_account_deletes_the_other_stores_beside_it() {
    let server = server().await;
    let stores = tempfile::tempdir().unwrap();
    let folder = StoreFolder::in_stores(stores.path(), "live");
    let secrets = Arc::new(MemorySecrets::default());
    let left = orphan(stores.path(), "left-by-a-sign-out");
    // not a store: it stays.
    std::fs::write(stores.path().join("a-file"), b"").unwrap();

    let sign_in = MatrixSignIn::new(folder.clone(), secrets.clone());
    drop(
        sign_in
            .sign_in_with_password(&server.uri(), "cheeky_monkey", "secret", "Lux (Test)")
            .await
            .unwrap(),
    );
    assert!(!left.exists(), "the orphan is deleted after the sign-in");
    assert!(folder.holds_device(), "the live store stays");
    assert!(stores.path().join("a-file").exists());

    // a restore deletes one that appeared since.
    let later = orphan(stores.path(), "left-later");
    drop(sign_in.restore().await.unwrap().unwrap());
    assert!(!later.exists(), "the orphan is deleted after the restore");
    assert!(folder.holds_device());
}

#[tokio::test(flavor = "multi_thread")]
async fn nothing_is_deleted_while_no_account_opens() {
    let stores = tempfile::tempdir().unwrap();
    let folder = StoreFolder::in_stores(stores.path(), "live");
    let left = orphan(stores.path(), "left-by-a-sign-out");

    // no session kept: signed out.
    let secrets = Arc::new(MemorySecrets::default());
    let sign_in = MatrixSignIn::new(folder.clone(), secrets.clone());
    assert!(sign_in.restore().await.unwrap().is_none());
    assert!(left.exists());

    // a kept session whose store cannot be opened: forgotten, nothing else deleted.
    let server = server().await;
    let (_root, plain, plain_secrets) = signed_in_plain(&server).await;
    *secrets.session.lock().unwrap() = plain_secrets.load().unwrap();
    std::fs::rename(plain.root(), folder.root()).unwrap();
    assert!(sign_in.restore().await.unwrap().is_none());
    assert!(!folder.root().exists());
    assert!(left.exists(), "no account opened: the other stores stay");
}

#[tokio::test(flavor = "multi_thread")]
async fn a_folder_made_alone_deletes_nothing_beside_it() {
    let server = server().await;
    let stores = tempfile::tempdir().unwrap();
    let left = orphan(stores.path(), "beside");
    let secrets = Arc::new(MemorySecrets::default());
    drop(
        MatrixSignIn::new(StoreFolder::new(stores.path().join("alone")), secrets)
            .sign_in_with_password(&server.uri(), "cheeky_monkey", "secret", "Lux (Test)")
            .await
            .unwrap(),
    );
    assert!(left.exists());
}

#[tokio::test(flavor = "multi_thread")]
async fn the_share_extension_sends_to_a_room_the_app_synced() {
    let server = server().await;
    let (_root, folder, secrets) = signed_in(&server).await;
    let room = matrix_sdk::ruma::room_id!("!shared:example.org");
    let app = restore(&folder, &secrets, Process::App).await.unwrap().unwrap();
    server.sync_joined_room(&app, room).await;
    drop(app);
    // the token the mock server's login gives.
    server
        .mock_room_state_encryption()
        .expect_access_token("abc123")
        .plain()
        .mount()
        .await;
    server
        .mock_room_send()
        .expect_access_token("abc123")
        .ok(matrix_sdk::ruma::event_id!("$sent"))
        .mock_once()
        .mount()
        .await;

    let secrets: Arc<dyn SecretStore> = secrets;
    let share = crate::MatrixShare::open(&folder, secrets).await.unwrap().unwrap();
    share
        .send(&lux_core::ids::RoomId::from(room.as_str()), "hello", &[])
        .await
        .unwrap();
}
