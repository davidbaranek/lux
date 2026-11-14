//! The demo's encryption: an account whose devices verify each other in a few made-up seconds,
//! so the apps' verification and recovery screens can be shown and tested with no server.
//!
//! [`DemoEncryption`] says where the account starts: verified with recovery, a new device that
//! must verify, or an account without recovery. A request from another device can be made to
//! arrive a moment after the app listens for them.

use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

use futures_util::stream;
use tokio::sync::watch;

use super::watched;
use crate::ports::{
    BackendError, DeviceTrust, EncryptionSetup, OwnDevice, RecoveryState, Security, ValueStream, Verification,
    VerificationEmoji, VerificationStep,
};

/// The only recovery key that opens the demo's backup.
pub const DEMO_RECOVERY_KEY: &str = "EsTj 3yST y93F SLpB jJsz eAXc 2XzA ygD3 w69H fGaN TKBj jXEd";

/// The key the demo's recovery setup makes.
const MADE_RECOVERY_KEY: &str = "EsTc Lux1 Demo 2Key 3For 4The 5App 6Set 7Up8 9Rec ov3r y5Ke";

/// How long the made-up other device takes for each of its steps.
const OTHER_DEVICE_TAKES: Duration = Duration::from_millis(1_500);

/// Where the demo's encryption starts.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum DemoEncryption {
    /// This device is verified and the backup open.
    #[default]
    Ready,
    /// A new device: the account keeps recovery, this device must verify.
    Unverified,
    /// A new account: verified, with no recovery yet.
    NoRecovery,
}

/// The demo account's encryption state.
pub(super) struct DemoSecurity {
    state: Arc<watch::Sender<(DeviceTrust, RecoveryState)>>,
    devices: Arc<Mutex<Vec<OwnDevice>>>,
    /// A request from another device arrives this long after the app listens.
    incoming_after: Option<Duration>,
}

impl DemoSecurity {
    pub(super) fn new(start: DemoEncryption, incoming_after: Option<Duration>) -> Self {
        let state = match start {
            DemoEncryption::Ready => (DeviceTrust::Verified, RecoveryState::Enabled),
            DemoEncryption::Unverified => (DeviceTrust::Unverified, RecoveryState::Incomplete),
            DemoEncryption::NoRecovery => (DeviceTrust::Verified, RecoveryState::Disabled),
        };
        let this_verified = state.0 == DeviceTrust::Verified;
        let devices = vec![
            OwnDevice {
                id: "DEMODEVICE".to_owned(),
                name: Some("Lux".to_owned()),
                is_verified: this_verified,
                is_this_device: true,
            },
            OwnDevice {
                id: "ELEMENTX01".to_owned(),
                name: Some("Element X on iPhone".to_owned()),
                is_verified: true,
                is_this_device: false,
            },
            OwnDevice {
                id: "WEBLAPTOP2".to_owned(),
                name: Some("Element on the web".to_owned()),
                is_verified: false,
                is_this_device: false,
            },
        ];
        Self {
            state: Arc::new(watch::Sender::new(state)),
            devices: Arc::new(Mutex::new(devices)),
            incoming_after,
        }
    }

    fn device(&self, id: &str) -> Option<OwnDevice> {
        lock(&self.devices).iter().find(|device| device.id == id).cloned()
    }

    fn verification(&self, step: VerificationStep, other: Option<OwnDevice>) -> DemoVerification {
        DemoVerification {
            steps: Arc::new(watch::Sender::new(step)),
            other,
            state: Arc::clone(&self.state),
            devices: Arc::clone(&self.devices),
        }
    }
}

impl Security for DemoSecurity {
    type Verification = DemoVerification;

    async fn is_device_verified(&self) -> bool {
        self.state.borrow().0 == DeviceTrust::Verified
    }

    fn encryption_setup(&self) -> ValueStream<EncryptionSetup> {
        use futures_util::StreamExt;
        Box::pin(watched(self.state.subscribe()).map(|(trust, recovery)| EncryptionSetup::of(trust, recovery)))
    }

    async fn verify_this_device(&self) -> Result<DemoVerification, BackendError> {
        let verification = self.verification(VerificationStep::Waiting, None);
        verification.after_other_device(VerificationStep::Waiting);
        Ok(verification)
    }

    async fn own_devices(&self) -> Result<Vec<OwnDevice>, BackendError> {
        Ok(lock(&self.devices).clone())
    }

    async fn verify_device(&self, device: &str) -> Result<DemoVerification, BackendError> {
        let other = self
            .device(device)
            .filter(|other| !other.is_this_device)
            .ok_or(BackendError::NotAllowed)?;
        let verification = self.verification(VerificationStep::Waiting, Some(other));
        verification.after_other_device(VerificationStep::Waiting);
        Ok(verification)
    }

    fn verification_requests(&self) -> ValueStream<Arc<DemoVerification>> {
        let Some(after) = self.incoming_after else {
            return Box::pin(stream::empty());
        };
        let request = Arc::new(self.verification(VerificationStep::Requested, self.device("ELEMENTX01")));
        Box::pin(stream::once(async move {
            tokio::time::sleep(after).await;
            request
        }))
    }

    fn recovery_state(&self) -> RecoveryState {
        self.state.borrow().1
    }

    async fn recover(&self, key: &str) -> Result<(), BackendError> {
        if key.split_whitespace().ne(DEMO_RECOVERY_KEY.split_whitespace()) {
            return Err(BackendError::WrongRecoveryKey);
        }
        // the key opens the secrets: this device signs itself, as a real one does.
        self.state.send_replace((DeviceTrust::Verified, RecoveryState::Enabled));
        mark_verified(&self.devices, |device| device.is_this_device);
        Ok(())
    }

    async fn set_up_recovery(&self) -> Result<String, BackendError> {
        let (trust, recovery) = *self.state.borrow();
        if trust == DeviceTrust::Unverified || recovery != RecoveryState::Disabled {
            return Err(BackendError::NotAllowed);
        }
        tokio::time::sleep(OTHER_DEVICE_TAKES).await;
        self.state.send_replace((DeviceTrust::Verified, RecoveryState::Enabled));
        Ok(MADE_RECOVERY_KEY.to_owned())
    }
}

/// A made-up verification: the other device accepts, the emojis come, each a moment later.
pub struct DemoVerification {
    steps: Arc<watch::Sender<VerificationStep>>,
    other: Option<OwnDevice>,
    state: Arc<watch::Sender<(DeviceTrust, RecoveryState)>>,
    devices: Arc<Mutex<Vec<OwnDevice>>>,
}

impl DemoVerification {
    /// From `from`, the other device's steps: accepted, then the emojis.
    fn after_other_device(&self, from: VerificationStep) {
        let steps = Arc::clone(&self.steps);
        tokio::spawn(async move {
            tokio::time::sleep(OTHER_DEVICE_TAKES).await;
            if !advance(&steps, &from, VerificationStep::Accepted) {
                return;
            }
            tokio::time::sleep(OTHER_DEVICE_TAKES).await;
            advance(&steps, &VerificationStep::Accepted, VerificationStep::Compare(emojis()));
        });
    }

    fn comparing(&self) -> Result<(), BackendError> {
        match *self.steps.borrow() {
            VerificationStep::Compare(_) => Ok(()),
            // no emojis to compare yet.
            _ => Err(BackendError::NotAllowed),
        }
    }
}

impl Verification for DemoVerification {
    fn other_device(&self) -> Option<OwnDevice> {
        self.other.clone()
    }

    fn steps(&self) -> ValueStream<VerificationStep> {
        watched(self.steps.subscribe())
    }

    async fn accept(&self) -> Result<(), BackendError> {
        if !advance(&self.steps, &VerificationStep::Requested, VerificationStep::Accepted) {
            return Err(BackendError::NotAllowed);
        }
        let steps = Arc::clone(&self.steps);
        tokio::spawn(async move {
            tokio::time::sleep(OTHER_DEVICE_TAKES).await;
            advance(&steps, &VerificationStep::Accepted, VerificationStep::Compare(emojis()));
        });
        Ok(())
    }

    async fn confirm(&self) -> Result<(), BackendError> {
        self.comparing()?;
        // the two devices sign each other: an unverified one is verified now, this one included.
        if let Some(other) = &self.other {
            mark_verified(&self.devices, |device| device.id == other.id);
        } else {
            mark_verified(&self.devices, |device| device.is_this_device);
            self.state.send_modify(|(trust, recovery)| {
                *trust = DeviceTrust::Verified;
                // the other device shares the backup's key.
                if *recovery == RecoveryState::Incomplete {
                    *recovery = RecoveryState::Enabled;
                }
            });
        }
        self.steps.send_replace(VerificationStep::Done);
        Ok(())
    }

    async fn deny(&self) -> Result<(), BackendError> {
        self.comparing()?;
        self.steps.send_replace(VerificationStep::Failed);
        Ok(())
    }

    async fn cancel(&self) {
        self.steps.send_if_modified(|step| {
            let open = !matches!(
                step,
                VerificationStep::Done | VerificationStep::Cancelled | VerificationStep::Failed
            );
            if open {
                *step = VerificationStep::Cancelled;
            }
            open
        });
    }
}

/// Moves `steps` from `from` to `to`; false when it had moved on (cancelled meanwhile).
fn advance(steps: &watch::Sender<VerificationStep>, from: &VerificationStep, to: VerificationStep) -> bool {
    steps.send_if_modified(|step| {
        let at = step == from;
        if at {
            *step = to;
        }
        at
    })
}

fn mark_verified(devices: &Mutex<Vec<OwnDevice>>, which: impl Fn(&OwnDevice) -> bool) {
    for device in lock(devices).iter_mut().filter(|device| which(device)) {
        device.is_verified = true;
    }
}

fn lock<T>(mutex: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    // each change is whole before the lock is let go.
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

/// The seven emojis both made-up devices show.
fn emojis() -> Vec<VerificationEmoji> {
    [
        ("🐶", "Dog"),
        ("🔑", "Key"),
        ("🚀", "Rocket"),
        ("🎸", "Guitar"),
        ("🌍", "Globe"),
        ("☂️", "Umbrella"),
        ("🍕", "Pizza"),
    ]
    .into_iter()
    .map(|(symbol, name)| VerificationEmoji {
        symbol: symbol.to_owned(),
        name: name.to_owned(),
    })
    .collect()
}

#[cfg(test)]
mod tests {
    use futures_util::StreamExt;

    use super::*;

    async fn step_after(stream: &mut ValueStream<VerificationStep>, wanted: fn(&VerificationStep) -> bool) {
        while let Some(step) = stream.next().await {
            if wanted(&step) {
                return;
            }
        }
        panic!("the steps ended first");
    }

    #[tokio::test(start_paused = true)]
    async fn a_new_device_is_verified_by_another_and_reads_the_backup() {
        let security = DemoSecurity::new(DemoEncryption::Unverified, None);
        let mut setup = security.encryption_setup();
        assert_eq!(
            setup.next().await,
            Some(EncryptionSetup::VerifyThisDevice {
                with_recovery_key: true
            })
        );

        let verification = security.verify_this_device().await.unwrap();
        let mut steps = verification.steps();
        step_after(&mut steps, |step| matches!(step, VerificationStep::Compare(_))).await;
        verification.confirm().await.unwrap();

        assert_eq!(steps.next().await, Some(VerificationStep::Done));
        assert_eq!(setup.next().await, Some(EncryptionSetup::Ready));
        assert!(security.own_devices().await.unwrap()[0].is_verified);
    }

    #[tokio::test(start_paused = true)]
    async fn only_the_saved_recovery_key_verifies_this_device() {
        let security = DemoSecurity::new(DemoEncryption::Unverified, None);
        assert!(matches!(
            security.recover("EsTx wrong").await,
            Err(BackendError::WrongRecoveryKey)
        ));
        security.recover(&DEMO_RECOVERY_KEY.replace(' ', "  ")).await.unwrap();
        assert!(security.is_device_verified().await);
        assert_eq!(security.recovery_state(), RecoveryState::Enabled);
    }

    #[tokio::test(start_paused = true)]
    async fn a_request_from_another_device_waits_for_the_user() {
        let security = DemoSecurity::new(DemoEncryption::Ready, Some(Duration::from_secs(3)));
        let request = security.verification_requests().next().await.unwrap();
        assert_eq!(
            request.other_device().map(|device| device.id),
            Some("ELEMENTX01".to_owned())
        );
        let mut steps = request.steps();
        assert_eq!(steps.next().await, Some(VerificationStep::Requested));
        assert!(matches!(request.confirm().await, Err(BackendError::NotAllowed)));

        request.accept().await.unwrap();
        step_after(&mut steps, |step| matches!(step, VerificationStep::Compare(_))).await;
        request.deny().await.unwrap();
        assert_eq!(steps.next().await, Some(VerificationStep::Failed));
    }

    #[tokio::test(start_paused = true)]
    async fn verifying_another_device_marks_it_verified() {
        let security = DemoSecurity::new(DemoEncryption::Ready, None);
        let verification = security.verify_device("WEBLAPTOP2").await.unwrap();
        let mut steps = verification.steps();
        step_after(&mut steps, |step| matches!(step, VerificationStep::Compare(_))).await;
        verification.confirm().await.unwrap();
        let devices = security.own_devices().await.unwrap();
        assert!(devices.iter().all(|device| device.is_verified));
        assert!(matches!(
            security.verify_device("DEMODEVICE").await,
            Err(BackendError::NotAllowed)
        ));
    }

    #[tokio::test(start_paused = true)]
    async fn a_cancelled_verification_stays_cancelled() {
        let security = DemoSecurity::new(DemoEncryption::Ready, None);
        let verification = security.verify_device("WEBLAPTOP2").await.unwrap();
        verification.cancel().await;
        tokio::time::sleep(OTHER_DEVICE_TAKES * 3).await;
        assert_eq!(verification.steps().next().await, Some(VerificationStep::Cancelled));
    }

    #[tokio::test(start_paused = true)]
    async fn recovery_is_set_up_once() {
        let security = DemoSecurity::new(DemoEncryption::NoRecovery, None);
        let mut setup = security.encryption_setup();
        assert_eq!(setup.next().await, Some(EncryptionSetup::SetUpRecovery));
        let key = security.set_up_recovery().await.unwrap();
        assert!(key.starts_with("EsT"));
        assert_eq!(setup.next().await, Some(EncryptionSetup::Ready));
        assert!(matches!(
            security.set_up_recovery().await,
            Err(BackendError::NotAllowed)
        ));
    }
}
