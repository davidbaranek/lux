//! The account's encryption as the user sees it: verifying this device or another of the
//! account's (comparing emojis), the key backup's recovery key, and what this device still needs
//! before it reads the account's encrypted messages.

use std::future::Future;
use std::sync::Arc;

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

/// Whether the account trusts this device.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum DeviceTrust {
    /// Signed by the account's identity: its other devices trust it.
    Verified,
    /// The account has an identity that has not signed this device.
    Unverified,
    /// The account has no identity yet (a new account): nothing to verify with.
    NoIdentity,
    /// Not known yet.
    Unknown,
}

/// What this device still needs to read the account's encrypted messages, as the app offers it
/// after signing in.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum EncryptionSetup {
    /// Not known yet: offer nothing.
    Unknown,
    /// This device must prove it is the account's: by another of its devices, or (when the
    /// account keeps its secrets on the server) by the recovery key.
    VerifyThisDevice {
        /// The account keeps a recovery key that would verify this device.
        with_recovery_key: bool,
    },
    /// The account keeps no recovery: one is to be set up, so a new device can read the history.
    SetUpRecovery,
    /// Nothing is needed.
    Ready,
}

impl EncryptionSetup {
    /// What a device that `trust` describes needs, with the key backup in `recovery`.
    #[must_use]
    pub fn of(trust: DeviceTrust, recovery: RecoveryState) -> Self {
        match (trust, recovery) {
            (DeviceTrust::Unknown, _) | (_, RecoveryState::Unknown) => Self::Unknown,
            (DeviceTrust::Unverified, recovery) => Self::VerifyThisDevice {
                // `Incomplete`: secrets on the server this device has not opened.
                with_recovery_key: recovery == RecoveryState::Incomplete,
            },
            // a verified device whose backup is not open yet takes its key from the other
            // devices; Settings has the recovery key's field for when they do not answer.
            (DeviceTrust::Verified, RecoveryState::Enabled | RecoveryState::Incomplete) => Self::Ready,
            // no recovery, or no identity at all (setting up starts from the identity).
            (DeviceTrust::Verified, RecoveryState::Disabled) | (DeviceTrust::NoIdentity, _) => Self::SetUpRecovery,
        }
    }
}

/// One of the account's devices.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct OwnDevice {
    /// Its id.
    pub id: String,
    /// The name it gave itself, if any.
    pub name: Option<String>,
    /// The account's identity has signed it.
    pub is_verified: bool,
    /// This device.
    pub is_this_device: bool,
}

/// How another of the account's devices is signed out.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum DeviceSignOut {
    /// On the server's account page, in the browser: the address opens it at the device. A
    /// server whose sign-in is its own (OAuth) signs devices out only there.
    InBrowser(String),
    /// Here, with the account's password.
    WithPassword,
}

/// One emoji to compare with the other device's.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct VerificationEmoji {
    /// The emoji.
    pub symbol: String,
    /// Its name, in English, as the specification names it.
    pub name: String,
}

/// Where a verification is.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum VerificationStep {
    /// Another device asks to verify: waiting for the user to accept here.
    Requested,
    /// Waiting for the other device to accept.
    Waiting,
    /// Both accepted; the emojis are on their way.
    Accepted,
    /// The emojis to compare with the other device's.
    Compare(Vec<VerificationEmoji>),
    /// Verified: the two devices trust each other.
    Done,
    /// Cancelled, here or on the other device.
    Cancelled,
    /// It failed (the emojis did not match, or the other device gave up).
    Failed,
}

/// A verification between this device and another of the account's, in progress.
pub trait Verification: Send + Sync {
    /// The other device, when known: the one asking, or the one asked; none while all of the
    /// account's devices are asked.
    fn other_device(&self) -> Option<OwnDevice>;

    /// Its steps, the current one first; it ends after the last.
    fn steps(&self) -> ValueStream<VerificationStep>;

    /// Accepts the other device's request ([`VerificationStep::Requested`]).
    fn accept(&self) -> impl Future<Output = Result<(), BackendError>> + Send;

    /// The emojis match.
    fn confirm(&self) -> impl Future<Output = Result<(), BackendError>> + Send;

    /// The emojis do not match: the verification fails on both devices.
    fn deny(&self) -> impl Future<Output = Result<(), BackendError>> + Send;

    /// The user gave up, or declined the request.
    fn cancel(&self) -> impl Future<Output = ()> + Send;
}

/// Verification and recovery.
pub trait Security: Send + Sync {
    /// A verification in progress.
    type Verification: Verification + 'static;

    /// Whether the account's other devices trust this one.
    fn is_device_verified(&self) -> impl Future<Output = bool> + Send;

    /// What this device needs, now and as it changes.
    fn encryption_setup(&self) -> ValueStream<EncryptionSetup>;

    /// Asks the account's other devices to verify this one.
    fn verify_this_device(&self) -> impl Future<Output = Result<Self::Verification, BackendError>> + Send;

    /// The account's devices, as the server has them now, this one first.
    fn own_devices(&self) -> impl Future<Output = Result<Vec<OwnDevice>, BackendError>> + Send;

    /// Asks the account's device `device` to verify with this one.
    fn verify_device(&self, device: &str) -> impl Future<Output = Result<Self::Verification, BackendError>> + Send;

    /// How the account's device `device` is signed out.
    ///
    /// The error is [`BackendError::NotAllowed`] for this device: it signs out on its own.
    fn device_sign_out(&self, device: &str) -> impl Future<Output = Result<DeviceSignOut, BackendError>> + Send;

    /// Signs the account's device `device` out with the account's password, where the server
    /// allows it ([`DeviceSignOut::WithPassword`]): its session ends, and it no longer reads the
    /// account's messages.
    ///
    /// The error is [`BackendError::WrongCredentials`] for a wrong password,
    /// [`BackendError::NotAllowed`] for this device.
    fn sign_out_device(&self, device: &str, password: &str) -> impl Future<Output = Result<(), BackendError>> + Send;

    /// The verifications the account's other devices ask for, as they arrive.
    fn verification_requests(&self) -> ValueStream<Arc<Self::Verification>>;

    /// Whether this device has the key backup open.
    fn recovery_state(&self) -> RecoveryState;

    /// Opens the key backup with the recovery key.
    ///
    /// The error is [`BackendError::WrongRecoveryKey`] for a key that does not open it.
    fn recover(&self, key: &str) -> impl Future<Output = Result<(), BackendError>> + Send;

    /// Sets up recovery for an account that has none: its identity if it has none yet, a key
    /// backup with this device's keys in it, and the secrets kept on the server under a new
    /// recovery key. The key, for the user to save.
    ///
    /// The error is [`BackendError::NotAllowed`] when the account already has a backup or this
    /// device is not verified: nothing is replaced.
    fn set_up_recovery(&self) -> impl Future<Output = Result<String, BackendError>> + Send;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn nothing_is_offered_until_both_are_known() {
        assert_eq!(
            EncryptionSetup::of(DeviceTrust::Unknown, RecoveryState::Disabled),
            EncryptionSetup::Unknown
        );
        assert_eq!(
            EncryptionSetup::of(DeviceTrust::Unverified, RecoveryState::Unknown),
            EncryptionSetup::Unknown
        );
    }

    #[test]
    fn an_unverified_device_offers_the_recovery_key_only_when_the_account_keeps_one() {
        assert_eq!(
            EncryptionSetup::of(DeviceTrust::Unverified, RecoveryState::Incomplete),
            EncryptionSetup::VerifyThisDevice {
                with_recovery_key: true
            }
        );
        assert_eq!(
            EncryptionSetup::of(DeviceTrust::Unverified, RecoveryState::Disabled),
            EncryptionSetup::VerifyThisDevice {
                with_recovery_key: false
            }
        );
    }

    #[test]
    fn an_account_without_recovery_sets_it_up() {
        assert_eq!(
            EncryptionSetup::of(DeviceTrust::Verified, RecoveryState::Disabled),
            EncryptionSetup::SetUpRecovery
        );
        assert_eq!(
            EncryptionSetup::of(DeviceTrust::NoIdentity, RecoveryState::Disabled),
            EncryptionSetup::SetUpRecovery
        );
    }

    #[test]
    fn a_verified_device_with_recovery_needs_nothing() {
        assert_eq!(
            EncryptionSetup::of(DeviceTrust::Verified, RecoveryState::Enabled),
            EncryptionSetup::Ready
        );
        assert_eq!(
            EncryptionSetup::of(DeviceTrust::Verified, RecoveryState::Incomplete),
            EncryptionSetup::Ready
        );
    }
}
