//! The stores' key: made here, kept by the platform.

use lux_core::ports::{BackendError, SecretStore, SecretStoreError, StoreKey};

/// A new random key, kept by the platform and read back: a store is never encrypted with a key
/// the platform did not keep.
pub(super) fn new_kept(secrets: &dyn SecretStore) -> Result<StoreKey, BackendError> {
    let mut bytes = [0; StoreKey::LENGTH];
    getrandom::fill(&mut bytes).map_err(|error| BackendError::store(format!("no random key: {error}")))?;
    let key = StoreKey::from_bytes(&bytes)?;
    bytes.fill(0);
    secrets.save_store_key(&key)?;
    match secrets.store_key()? {
        Some(kept) if kept == key => Ok(key),
        _ => Err(BackendError::Secrets(SecretStoreError::Unavailable {
            reason: "the platform did not keep the store's key".to_owned(),
        })),
    }
}
