//! The session's secrets, which the platform keeps (the Keychain on Apple's systems): the core
//! asks for them when it opens the account, and hands them back each time the tokens change.

use std::fmt;

use zeroize::{Zeroize, ZeroizeOnDrop};

use crate::ids::{DeviceId, UserId};

/// Everything a device needs to open its session again.
#[derive(Clone, PartialEq, Eq)]
pub struct SessionSecrets {
    /// The account.
    pub user_id: UserId,
    /// This device.
    pub device_id: DeviceId,
    /// The server's client API (`https://matrix-client.matrix.org`).
    pub homeserver_url: String,
    /// The current access token.
    pub access_token: String,
    /// The token that renews it, if the server gave one.
    pub refresh_token: Option<String>,
    /// The app's registration with the server's account service, for a session signed in there
    /// (OAuth); `None` for a password sign-in.
    pub oauth_client_id: Option<String>,
    /// The server syncs natively with simplified sliding sync (MSC4186).
    pub native_sliding_sync: bool,
}

impl fmt::Debug for SessionSecrets {
    // the tokens never go to a log.
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("SessionSecrets")
            .field("user_id", &self.user_id)
            .field("device_id", &self.device_id)
            .field("homeserver_url", &self.homeserver_url)
            .field("oauth_client_id", &self.oauth_client_id)
            .field("native_sliding_sync", &self.native_sliding_sync)
            .finish_non_exhaustive()
    }
}

/// Why the platform could not keep or give the secrets.
#[derive(Debug, thiserror::Error)]
pub enum SecretStoreError {
    /// The platform's store is locked or refused (the device has not been unlocked since it
    /// started, an access prompt was declined…).
    #[error("the secret store is unavailable: {reason}")]
    Unavailable {
        /// What the platform said.
        reason: String,
    },
    /// What the platform keeps cannot be read as a session.
    #[error("the kept session cannot be read: {reason}")]
    Invalid {
        /// What was wrong.
        reason: String,
    },
}

/// The key of the account's stores on this device (the SDK's state, crypto, event cache and media
/// stores): 32 random bytes the platform keeps beside the session. Never logged; wiped when
/// dropped.
#[derive(Clone, PartialEq, Eq, Zeroize, ZeroizeOnDrop)]
pub struct StoreKey([u8; StoreKey::LENGTH]);

impl StoreKey {
    /// The key's length in bytes.
    pub const LENGTH: usize = 32;

    /// The key in `bytes`, as the platform keeps it.
    ///
    /// # Errors
    /// [`SecretStoreError::Invalid`] when `bytes` is not 32 bytes long.
    pub fn from_bytes(bytes: &[u8]) -> Result<Self, SecretStoreError> {
        let key = <[u8; Self::LENGTH]>::try_from(bytes).map_err(|_| SecretStoreError::Invalid {
            reason: format!("a store key of {} bytes", bytes.len()),
        })?;
        Ok(Self(key))
    }

    /// The key's bytes.
    #[must_use]
    pub fn as_bytes(&self) -> &[u8] {
        &self.0
    }
}

impl fmt::Debug for StoreKey {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("StoreKey(…)")
    }
}

/// Where the platform keeps one account's session. Calls are quick and blocking (a Keychain
/// read); the core makes them off the apps' main threads.
pub trait SecretStore: Send + Sync {
    /// The kept session, or `None` when there is none.
    ///
    /// # Errors
    /// When the platform's store cannot be read.
    fn load(&self) -> Result<Option<SessionSecrets>, SecretStoreError>;

    /// Keeps `secrets` in place of what was kept.
    ///
    /// # Errors
    /// When the platform's store cannot be written.
    fn save(&self, secrets: &SessionSecrets) -> Result<(), SecretStoreError>;

    /// The key of the account's stores, or `None` when none is kept.
    ///
    /// # Errors
    /// When the platform's store cannot be read, or what it keeps is not a key.
    fn store_key(&self) -> Result<Option<StoreKey>, SecretStoreError>;

    /// Keeps `key` as the key of the account's stores, in place of any other.
    ///
    /// # Errors
    /// When the platform's store cannot be written.
    fn save_store_key(&self, key: &StoreKey) -> Result<(), SecretStoreError>;

    /// Deletes the kept session and the store key, and any other secret of the account's: the
    /// account is gone from this device.
    ///
    /// # Errors
    /// When the platform's store cannot be written.
    fn delete(&self) -> Result<(), SecretStoreError>;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_key_is_32_bytes_and_never_shown() {
        let key = StoreKey::from_bytes(&[7; 32]).unwrap();
        assert_eq!(key.as_bytes(), &[7; 32]);
        assert_eq!(format!("{key:?}"), "StoreKey(…)");
        assert!(matches!(
            StoreKey::from_bytes(&[7; 31]),
            Err(SecretStoreError::Invalid { .. })
        ));
    }
}
