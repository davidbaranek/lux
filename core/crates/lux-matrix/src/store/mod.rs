//! The account's store on this device, and the SDK client over it.
//!
//! One folder per account: `data/` (the state and crypto stores) and `cache/` (the event cache
//! and the media). The stores are encrypted with a key the platform keeps beside the session
//! ([`StoreKey`]), made at sign-in: the SDK encrypts each value and hashes each key with it (its
//! `StoreCipher`; the files stay SQLite). A kept session is opened only over its own encrypted
//! store ([`kept_store_key`]); the app forgets an account whose store cannot be opened
//! ([`forget`]), and signs in again.

mod files;
mod key;

#[cfg(test)]
mod tests;

use std::io;
use std::path::{Path, PathBuf};

use lux_core::ports::{BackendError, SecretStore, StoreKey, UnusableStore};
use matrix_sdk::cross_process_lock::CrossProcessLockConfig;
use matrix_sdk::encryption::{BackupDownloadStrategy, EncryptionSettings};
use matrix_sdk::sliding_sync::VersionBuilder;
use matrix_sdk::{Client, ClientBuilder, SqliteStoreConfig};
use matrix_sdk_base::crypto::{DecryptionSettings, TrustRequirement};
use tracing::{info, warn};

use files::Encryption;

/// Which process opens the store: each holds the store's cross-process locks (and the token
/// refresh lock) under its own name, so the SDK knows when the other one wrote.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Process {
    /// The app.
    App,
    /// The notification service extension: it reads one event, and syncs nothing else.
    NotificationExtension,
    /// The share extension: it sends what the user shares to one chat, and syncs nothing.
    ShareExtension,
}

impl Process {
    /// The name the process holds the locks under.
    pub(crate) fn lock_holder(self) -> &'static str {
        match self {
            Self::App => "app",
            Self::NotificationExtension => "nse",
            Self::ShareExtension => "share",
        }
    }
}

/// The crypto store's file in `data/`: the device's keys. Its presence tells a store that holds
/// a device from a folder that was never one.
const CRYPTO_STORE: &str = "matrix-sdk-crypto.sqlite3";

/// One account's folder on this device.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct StoreFolder {
    root: PathBuf,
    /// The folder of every account's folder, when known: the app deletes the others there.
    stores: Option<PathBuf>,
}

impl StoreFolder {
    /// The folder at `root` (`…/Application Support/matrix/<store>`), alone.
    #[must_use]
    pub fn new(root: impl Into<PathBuf>) -> Self {
        Self {
            root: root.into(),
            stores: None,
        }
    }

    /// The folder `name` in `stores`, the folder that holds every account's folder on this
    /// device (`…/Application Support/matrix`): once this one's account is open, the app deletes
    /// the others there.
    #[must_use]
    pub fn in_stores(stores: impl Into<PathBuf>, name: impl AsRef<Path>) -> Self {
        let stores = stores.into();
        Self {
            root: stores.join(name),
            stores: Some(stores),
        }
    }

    /// The folder.
    #[must_use]
    pub fn root(&self) -> &Path {
        &self.root
    }

    fn data(&self) -> PathBuf {
        self.root.join("data")
    }

    fn cache(&self) -> PathBuf {
        self.root.join("cache")
    }

    /// Whether the folder holds a device's keys, from a sign-in.
    #[must_use]
    pub fn holds_device(&self) -> bool {
        self.data().join(CRYPTO_STORE).is_file()
    }

    /// Whether the folder's crypto store, which must exist, is encrypted, read from its file.
    fn encryption(&self) -> Result<Encryption, BackendError> {
        files::encryption(&self.data().join(CRYPTO_STORE)).map_err(BackendError::store)
    }

    /// Whether `key` opens the folder's encrypted crypto store, read from its file.
    fn key_opens(&self, key: &StoreKey) -> Result<bool, BackendError> {
        files::key_opens(&self.data().join(CRYPTO_STORE), key.as_bytes()).map_err(BackendError::store)
    }

    /// The client's builder over this folder, its stores encrypted with `key`; the caller names
    /// the server. A new sign-in discovers the server's sliding sync; a restore knows it from the
    /// session, and opens without the network.
    pub(crate) fn client_builder(
        &self,
        sliding_sync: VersionBuilder,
        process: Process,
        key: &StoreKey,
    ) -> ClientBuilder {
        let app = process == Process::App;
        // an extension lives in a few megabytes: few connections, small caches.
        let store = if app {
            SqliteStoreConfig::new(self.data())
        } else {
            SqliteStoreConfig::with_low_memory_config(self.data()).pool_max_size(2)
        };
        // a raw key: the SDK derives nothing from it.
        let store = store.key(Some(key.as_bytes()));
        Client::builder()
            .sqlite_store_with_config_and_cache_path(store, Some(self.cache()))
            // the app and its extensions open the same store, each from its process.
            .cross_process_store_config(CrossProcessLockConfig::MultiProcess {
                holder_name: process.lock_holder().to_owned(),
            })
            .sliding_sync_version_builder(sliding_sync)
            .handle_refresh_tokens()
            .with_encryption_settings(EncryptionSettings {
                auto_enable_cross_signing: false,
                // once the key backup is open, a message whose key this device lacks takes it
                // from the backup.
                backup_download_strategy: BackupDownloadStrategy::AfterDecryptionFailure,
                auto_enable_backups: false,
            })
            .with_decryption_settings(DecryptionSettings {
                sender_device_trust_requirement: TrustRequirement::Untrusted,
            })
            // the chats page back by themselves, as the search index's backfill expects; the
            // extension reads one event and keeps no cache of the chats.
            .with_enable_automatic_back_pagination(app)
            .with_event_cache(app)
    }
}

/// The key to open the kept store of `folder` with: only an encrypted store that holds a device,
/// with its key kept in `secrets`, the key opening it. All of it is read from the files, before
/// any client opens them: a folder the app then forgets has nothing open in it.
///
/// # Errors
/// [`BackendError::StoreUnusable`] when the folder holds no device, its store is not encrypted,
/// or its key is not kept or does not open it; others when the folder or the secret store cannot
/// be read.
pub(crate) fn kept_store_key(folder: &StoreFolder, secrets: &dyn SecretStore) -> Result<StoreKey, BackendError> {
    if !folder.holds_device() {
        return Err(BackendError::StoreUnusable(UnusableStore::Missing));
    }
    if folder.encryption()? == Encryption::Plain {
        return Err(BackendError::StoreUnusable(UnusableStore::NotEncrypted));
    }
    let key = secrets
        .store_key()?
        .ok_or(BackendError::StoreUnusable(UnusableStore::KeyMissing))?;
    if !folder.key_opens(&key)? {
        return Err(BackendError::StoreUnusable(UnusableStore::WrongKey));
    }
    Ok(key)
}

/// Forgets the account of `folder`: deletes the folder and the account's secrets, so the next
/// launch is signed out. Only the app calls it, with no client open over the folder.
///
/// # Errors
/// When the folder or the secrets cannot be deleted.
pub(crate) fn forget(folder: &StoreFolder, secrets: &dyn SecretStore) -> Result<(), BackendError> {
    match std::fs::remove_dir_all(folder.root()) {
        Ok(()) => {}
        Err(error) if error.kind() == io::ErrorKind::NotFound => {}
        Err(error) => return Err(BackendError::store(format!("the account's folder stays: {error}"))),
    }
    Ok(secrets.delete()?)
}

/// Deletes every other account folder in the stores' folder of `live`, the folder of the account
/// just opened: stores no account opens any more (a sign-out that failed halfway, a sign-in that
/// stopped, an earlier build's), which hold a device's keys. Only the app calls it, once an
/// account is open, so the live folder is known for certain; nothing goes for a folder made
/// alone ([`StoreFolder::new`]), or one not directly in its stores' folder. A folder that cannot
/// be deleted stays, for the next launch.
pub(crate) async fn remove_others(live: &StoreFolder) {
    let Some(stores) = live.stores.clone() else {
        return;
    };
    let live = live.root().to_owned();
    if live.parent() != Some(stores.as_path()) {
        warn!("the account's folder is not in the stores' folder: nothing is deleted");
        return;
    }
    let removed = tokio::task::spawn_blocking(move || {
        let entries = match std::fs::read_dir(&stores) {
            Ok(entries) => entries,
            Err(error) => {
                warn!(%error, "the stores' folder cannot be listed");
                return;
            }
        };
        for entry in entries.flatten() {
            let path = entry.path();
            if path == live || !entry.file_type().is_ok_and(|kind| kind.is_dir()) {
                continue;
            }
            match std::fs::remove_dir_all(&path) {
                Ok(()) => info!("a store no account opens is deleted"),
                Err(error) => warn!(%error, "a store no account opens stays"),
            }
        }
    })
    .await;
    if let Err(error) = removed {
        warn!(%error, "the other stores were not deleted");
    }
}

/// The key for a new account's stores: a new one, kept by the platform before any store is made
/// with it.
///
/// # Errors
/// When the platform cannot keep it.
pub(crate) fn new_store_key(secrets: &dyn SecretStore) -> Result<StoreKey, BackendError> {
    key::new_kept(secrets)
}
