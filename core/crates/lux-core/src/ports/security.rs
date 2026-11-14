//! The account's encryption as the user sees it: verifying this device from another one
//! (comparing emojis), and opening the key backup with the recovery key.

use std::future::Future;

use super::{BackendError, ValueStream};

/// Whether this device can read the account's encrypted history from its key backup.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum RecoveryState {
    /// The backup is open on this device.
    Enabled,
    /// The account has a backup this device has not opened: it needs the recovery key.
    Incomplete,
    /// The account keeps no backup.
    Disabled,
    /// Not known yet (the first sync has not answered).
    Unknown,
}

/// One emoji to compare with the other device's.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct VerificationEmoji {
    /// The emoji.
    pub symbol: String,
    /// Its name, in English, as the specification names it.
    pub name: String,
}

/// Where a verification of this device is.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum VerificationStep {
    /// Waiting for another device to accept.
    Waiting,
    /// Another device accepted; the emojis are on their way.
    Accepted,
    /// The emojis to compare with the other device's.
    Compare(Vec<VerificationEmoji>),
    /// Verified: the account's other devices trust this one.
    Done,
    /// Cancelled, here or on the other device.
    Cancelled,
    /// It failed (the emojis did not match, or the other device gave up).
    Failed,
}

/// A verification of this device in progress.
pub trait Verification: Send + Sync {
    /// Its steps, the current one first; it ends after the last.
    fn steps(&self) -> ValueStream<VerificationStep>;

    /// The emojis match.
    fn confirm(&self) -> impl Future<Output = Result<(), BackendError>> + Send;

    /// The emojis do not match: the verification fails on both devices.
    fn deny(&self) -> impl Future<Output = Result<(), BackendError>> + Send;

    /// The user gave up.
    fn cancel(&self) -> impl Future<Output = ()> + Send;
}

/// Verification and recovery.
pub trait Security: Send + Sync {
    /// A verification in progress.
    type Verification: Verification;

    /// Whether the account's other devices trust this one.
    fn is_device_verified(&self) -> impl Future<Output = bool> + Send;

    /// Asks the account's other devices to verify this one.
    fn verify_this_device(&self) -> impl Future<Output = Result<Self::Verification, BackendError>> + Send;

    /// Whether this device has the key backup open.
    fn recovery_state(&self) -> RecoveryState;

    /// Opens the key backup with the recovery key.
    ///
    /// The error is [`BackendError::WrongRecoveryKey`] for a key that does not open it.
    fn recover(&self, key: &str) -> impl Future<Output = Result<(), BackendError>> + Send;
}
