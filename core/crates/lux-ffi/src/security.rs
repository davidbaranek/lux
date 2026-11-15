//! The account's security, as the apps see them: what this device needs after signing in,
//! verifications with the account's other devices (a listener receives their steps, another the
//! requests that arrive), the account's devices, the recovery key and setting recovery up.
//!
//! The demo answers each of them with its made-up devices, so the screens show without a server.

use std::sync::Arc;

use futures_util::StreamExt;
use lux_core::demo::DemoVerification;
use lux_core::ports::{
    DeviceSignOut, EncryptionSetup, OwnDevice, RecoveryState, Security, Verification, VerificationStep,
};
use lux_matrix::MatrixVerification;

use crate::account::{CoreAccount, CoreAccountError, CoreListenerHandle, with_account};
use crate::runtime;

/// Whether the key backup is open on this device.
#[derive(Clone, Copy, uniffi::Enum)]
pub enum CoreRecoveryState {
    /// Open.
    Enabled,
    /// The account has one this device has not opened.
    Incomplete,
    /// The account keeps none.
    Disabled,
    /// Not known yet.
    Unknown,
}

impl From<RecoveryState> for CoreRecoveryState {
    fn from(state: RecoveryState) -> Self {
        match state {
            RecoveryState::Enabled => Self::Enabled,
            RecoveryState::Incomplete => Self::Incomplete,
            RecoveryState::Disabled => Self::Disabled,
            RecoveryState::Unknown => Self::Unknown,
        }
    }
}

/// What this device needs to read the account's encrypted messages.
#[derive(Clone, Copy, uniffi::Enum)]
pub enum CoreEncryptionSetup {
    /// Not known yet.
    Unknown,
    /// Verify this device: with another device, or with the recovery key when there is one.
    VerifyThisDevice {
        /// The recovery key would verify it.
        with_recovery_key: bool,
    },
    /// Set up recovery: the account keeps none.
    SetUpRecovery,
    /// Nothing.
    Ready,
}

impl From<EncryptionSetup> for CoreEncryptionSetup {
    fn from(setup: EncryptionSetup) -> Self {
        match setup {
            EncryptionSetup::Unknown => Self::Unknown,
            EncryptionSetup::VerifyThisDevice { with_recovery_key } => Self::VerifyThisDevice { with_recovery_key },
            EncryptionSetup::SetUpRecovery => Self::SetUpRecovery,
            EncryptionSetup::Ready => Self::Ready,
        }
    }
}

/// One of the account's devices.
#[derive(Clone, uniffi::Record)]
pub struct CoreOwnDevice {
    /// Its id.
    pub id: String,
    /// Its name, if it gave itself one.
    pub name: Option<String>,
    /// The account's identity signed it.
    pub is_verified: bool,
    /// This device.
    pub is_this_device: bool,
}

impl From<OwnDevice> for CoreOwnDevice {
    fn from(device: OwnDevice) -> Self {
        Self {
            id: device.id,
            name: device.name,
            is_verified: device.is_verified,
            is_this_device: device.is_this_device,
        }
    }
}

/// How another of the account's devices is signed out.
#[derive(Clone, uniffi::Enum)]
pub enum CoreDeviceSignOut {
    /// On the server's account page, in the browser.
    InBrowser {
        /// The page's address, at the device.
        url: String,
    },
    /// Here, with the account's password.
    WithPassword,
}

impl From<DeviceSignOut> for CoreDeviceSignOut {
    fn from(sign_out: DeviceSignOut) -> Self {
        match sign_out {
            DeviceSignOut::InBrowser(url) => Self::InBrowser { url },
            DeviceSignOut::WithPassword => Self::WithPassword,
        }
    }
}

/// One emoji to compare.
#[derive(Clone, uniffi::Record)]
pub struct CoreVerificationEmoji {
    /// The emoji.
    pub symbol: String,
    /// Its name.
    pub name: String,
}

/// Where a verification is.
#[derive(Clone, uniffi::Enum)]
pub enum CoreVerificationStep {
    /// Another device asks; the user accepts or declines.
    Requested,
    /// Waiting for the other device.
    Waiting,
    /// Accepted; the emojis are coming.
    Accepted,
    /// Compare these.
    Compare {
        /// The emojis.
        emojis: Vec<CoreVerificationEmoji>,
    },
    /// Verified.
    Done,
    /// Cancelled.
    Cancelled,
    /// Failed.
    Failed,
}

impl From<VerificationStep> for CoreVerificationStep {
    fn from(step: VerificationStep) -> Self {
        match step {
            VerificationStep::Requested => Self::Requested,
            VerificationStep::Waiting => Self::Waiting,
            VerificationStep::Accepted => Self::Accepted,
            VerificationStep::Compare(emojis) => Self::Compare {
                emojis: emojis
                    .into_iter()
                    .map(|emoji| CoreVerificationEmoji {
                        symbol: emoji.symbol,
                        name: emoji.name,
                    })
                    .collect(),
            },
            VerificationStep::Done => Self::Done,
            VerificationStep::Cancelled => Self::Cancelled,
            VerificationStep::Failed => Self::Failed,
        }
    }
}

/// Receives a verification's steps, from any thread; the current one first.
#[uniffi::export(with_foreign)]
pub trait CoreVerificationListener: Send + Sync {
    /// The verification is at `step`.
    fn on_step(&self, step: CoreVerificationStep);
}

/// Receives what this device needs, from any thread; the current one first.
#[uniffi::export(with_foreign)]
pub trait CoreEncryptionSetupListener: Send + Sync {
    /// This device needs `setup`.
    fn on_setup(&self, setup: CoreEncryptionSetup);
}

/// Receives the verifications another device of the account asks for, from any thread.
#[uniffi::export(with_foreign)]
pub trait CoreVerificationRequestListener: Send + Sync {
    /// Another device asks to verify; the request's first step is `Requested`.
    fn on_request(&self, verification: Arc<CoreVerification>);
}

/// A verification on whichever backend the account runs.
enum AnyVerification {
    Matrix(Arc<MatrixVerification>),
    Demo(Arc<DemoVerification>),
}

/// Evaluates `$body` with `$verification` bound to the verification, whichever backend's.
macro_rules! with_verification {
    ($any:expr, $verification:ident => $body:expr) => {
        match $any {
            AnyVerification::Matrix($verification) => $body,
            AnyVerification::Demo($verification) => $body,
        }
    };
}

/// A verification between this device and another of the account's, in progress.
#[derive(uniffi::Object)]
pub struct CoreVerification {
    verification: AnyVerification,
}

impl From<MatrixVerification> for CoreVerification {
    fn from(verification: MatrixVerification) -> Self {
        Arc::new(verification).into()
    }
}

impl From<Arc<MatrixVerification>> for CoreVerification {
    fn from(verification: Arc<MatrixVerification>) -> Self {
        Self {
            verification: AnyVerification::Matrix(verification),
        }
    }
}

impl From<DemoVerification> for CoreVerification {
    fn from(verification: DemoVerification) -> Self {
        Arc::new(verification).into()
    }
}

impl From<Arc<DemoVerification>> for CoreVerification {
    fn from(verification: Arc<DemoVerification>) -> Self {
        Self {
            verification: AnyVerification::Demo(verification),
        }
    }
}

#[uniffi::export(async_runtime = "tokio")]
impl CoreVerification {
    /// The other device, when known (none while all of the account's devices are asked).
    #[must_use]
    pub fn other_device(&self) -> Option<CoreOwnDevice> {
        with_verification!(&self.verification, verification => verification.other_device()).map(Into::into)
    }

    /// Sends the steps to `listener` until the handle is let go.
    pub fn listen(&self, listener: Arc<dyn CoreVerificationListener>) -> Arc<CoreListenerHandle> {
        let steps = with_verification!(&self.verification, verification => verification.steps());
        let task = runtime::handle().spawn(steps.for_each(move |step| {
            listener.on_step(step.into());
            async {}
        }));
        Arc::new(CoreListenerHandle { tasks: vec![task] })
    }

    /// Accepts another device's request.
    ///
    /// # Errors
    /// When this device asked, or the answer cannot be sent.
    pub async fn accept(&self) -> Result<(), CoreAccountError> {
        Ok(with_verification!(&self.verification, verification => verification.accept().await)?)
    }

    /// The emojis match.
    ///
    /// # Errors
    /// When there are none to compare yet, or the answer cannot be sent.
    pub async fn confirm(&self) -> Result<(), CoreAccountError> {
        Ok(with_verification!(&self.verification, verification => verification.confirm().await)?)
    }

    /// The emojis do not match.
    ///
    /// # Errors
    /// When there are none to compare yet, or the answer cannot be sent.
    pub async fn deny(&self) -> Result<(), CoreAccountError> {
        Ok(with_verification!(&self.verification, verification => verification.deny().await)?)
    }

    /// The user gave up, or declined.
    pub async fn cancel(&self) {
        with_verification!(&self.verification, verification => verification.cancel().await);
    }
}

#[uniffi::export(async_runtime = "tokio")]
impl CoreAccount {
    /// Whether the account's other devices trust this one.
    pub async fn is_device_verified(&self) -> bool {
        with_account!(self.backend(), account => account.is_device_verified().await)
    }

    /// Sends what this device needs to `listener`, now and as it changes, until the handle is
    /// let go.
    pub fn follow_encryption_setup(&self, listener: Arc<dyn CoreEncryptionSetupListener>) -> Arc<CoreListenerHandle> {
        let setups = with_account!(self.backend(), account => account.encryption_setup());
        let task = runtime::handle().spawn(setups.for_each(move |setup| {
            listener.on_setup(setup.into());
            async {}
        }));
        Arc::new(CoreListenerHandle { tasks: vec![task] })
    }

    /// Sends each verification another device of the account asks for to `listener`, until the
    /// handle is let go.
    pub fn follow_verification_requests(
        &self,
        listener: Arc<dyn CoreVerificationRequestListener>,
    ) -> Arc<CoreListenerHandle> {
        let task = match self.backend() {
            crate::account::Backend::Matrix(account) => {
                let requests = account.verification_requests();
                runtime::handle().spawn(requests.for_each(move |request| {
                    listener.on_request(Arc::new(request.into()));
                    async {}
                }))
            }
            crate::account::Backend::Demo(demo) => {
                let requests = demo.verification_requests();
                runtime::handle().spawn(requests.for_each(move |request| {
                    listener.on_request(Arc::new(request.into()));
                    async {}
                }))
            }
        };
        Arc::new(CoreListenerHandle { tasks: vec![task] })
    }

    /// Asks the account's other devices to verify this one.
    ///
    /// # Errors
    /// When the account has no identity yet, or the request cannot be sent.
    pub async fn verify_this_device(&self) -> Result<Arc<CoreVerification>, CoreAccountError> {
        let verification: CoreVerification =
            with_account!(self.backend(), account => account.verify_this_device().await?.into());
        Ok(Arc::new(verification))
    }

    /// The account's devices that can verify, this one first.
    ///
    /// # Errors
    /// When the store cannot be read.
    pub async fn own_devices(&self) -> Result<Vec<CoreOwnDevice>, CoreAccountError> {
        let devices = with_account!(self.backend(), account => account.own_devices().await?);
        Ok(devices.into_iter().map(Into::into).collect())
    }

    /// Asks the account's device `device_id` to verify with this one.
    ///
    /// # Errors
    /// For this device, one without keys, or when the request cannot be sent.
    pub async fn verify_device(&self, device_id: String) -> Result<Arc<CoreVerification>, CoreAccountError> {
        let verification: CoreVerification =
            with_account!(self.backend(), account => account.verify_device(&device_id).await?.into());
        Ok(Arc::new(verification))
    }

    /// How the account's device `device_id` is signed out.
    ///
    /// # Errors
    /// `NotAllowed` for this device; others when the server cannot be asked.
    pub async fn device_sign_out(&self, device_id: String) -> Result<CoreDeviceSignOut, CoreAccountError> {
        let sign_out = with_account!(self.backend(), account => account.device_sign_out(&device_id).await?);
        Ok(sign_out.into())
    }

    /// Signs the account's device `device_id` out with the account's password.
    ///
    /// # Errors
    /// `WrongCredentials` for a wrong password, `NotAllowed` for this device or a server that
    /// asks for more than the password.
    pub async fn sign_out_device(&self, device_id: String, password: String) -> Result<(), CoreAccountError> {
        Ok(with_account!(self.backend(), account => account.sign_out_device(&device_id, &password).await)?)
    }

    /// Whether the key backup is open on this device.
    #[must_use]
    pub fn recovery_state(&self) -> CoreRecoveryState {
        with_account!(self.backend(), account => account.recovery_state()).into()
    }

    /// Opens the key backup with the recovery key; it verifies this device too.
    ///
    /// # Errors
    /// `WrongRecoveryKey` for a key that does not open it.
    pub async fn recover(&self, key: String) -> Result<(), CoreAccountError> {
        Ok(with_account!(self.backend(), account => account.recover(&key).await)?)
    }

    /// Sets up recovery for an account that has none. The recovery key, for the user to save.
    ///
    /// # Errors
    /// `NotAllowed` when the account has a backup already or this device is not verified; others
    /// when the server refuses.
    pub async fn set_up_recovery(&self) -> Result<String, CoreAccountError> {
        Ok(with_account!(self.backend(), account => account.set_up_recovery().await)?)
    }
}
