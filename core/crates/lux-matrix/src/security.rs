//! Verifying this device or another of the account's (comparing emojis, SAS), the requests the
//! account's other devices send, the key backup's recovery key, and setting recovery up for an
//! account that has none.
//!
//! One task follows a verification: the request until both devices accept it, then the emoji
//! comparison, and publishes each step. The answer to the comparison goes to the SAS it started.
//! Requests from the account's other devices arrive as to-device events; a handler passes each
//! one on to whoever listens.

use std::collections::BTreeMap;
use std::sync::Arc;
use std::time::Duration;

use futures_util::{StreamExt, future, stream};
use lux_core::ports::{
    BackendError, DeviceSignOut, DeviceTrust, EncryptionSetup, OwnDevice, RecoveryState, Security, ValueStream,
    Verification, VerificationEmoji, VerificationStep,
};
use matrix_sdk::Client;
use matrix_sdk::authentication::oauth::error::OAuthDiscoveryError;
use matrix_sdk::encryption::VerificationState;
use matrix_sdk::encryption::identities::{Device, ManualVerifyError, RequestVerificationError};
use matrix_sdk::encryption::recovery::{RecoveryError, RecoveryState as SdkRecoveryState};
use matrix_sdk::encryption::secret_storage::SecretStorageError;
use matrix_sdk::encryption::verification::{SasState, SasVerification, VerificationRequest, VerificationRequestState};
use matrix_sdk::event_handler::EventHandlerHandle;
use matrix_sdk::ruma::OwnedDeviceId;
use matrix_sdk::ruma::api::client::discovery::get_authorization_server_metadata::v1::{
    AccountManagementActionData, DeviceDeleteData,
};
use matrix_sdk::ruma::api::client::keys::get_keys;
use matrix_sdk::ruma::api::client::uiaa::{AuthData, MatrixUserIdentifier, Password, UserIdentifier};
use matrix_sdk::ruma::api::error::ErrorKind;
use matrix_sdk::ruma::events::key::verification::VerificationMethod;
use matrix_sdk::ruma::events::key::verification::cancel::CancelCode;
use matrix_sdk::ruma::events::key::verification::request::ToDeviceKeyVerificationRequestEvent;
use tokio::sync::{broadcast, watch};
use tokio::task::JoinHandle;
use tokio::time::{Instant, sleep};
use tracing::warn;

use crate::account::MatrixAccount;
use crate::errors::{from_http, from_sdk};
use crate::streams::watched;

/// Emojis only: Lux shows no QR code.
fn methods() -> Vec<VerificationMethod> {
    vec![VerificationMethod::SasV1]
}

impl Security for MatrixAccount {
    type Verification = MatrixVerification;

    async fn is_device_verified(&self) -> bool {
        let encryption = self.client.encryption();
        // the state is known once the device's identity is read; a moment after launch.
        encryption.wait_for_e2ee_initialization_tasks().await;
        matches!(encryption.verification_state().get(), VerificationState::Verified)
    }

    fn encryption_setup(&self) -> ValueStream<EncryptionSetup> {
        let client = self.client.clone();
        let encryption = client.encryption();
        let changes = stream::select(
            encryption.verification_state().map(drop),
            encryption.recovery().state_stream().map(drop),
        );
        let setups = stream::once(future::ready(())).chain(changes).then(move |()| {
            let client = client.clone();
            async move { EncryptionSetup::of(trust(&client).await, recovery_state(&client)) }
        });
        // only what changed.
        Box::pin(
            setups
                .scan(None, |last, setup| {
                    let new = *last != Some(setup);
                    *last = Some(setup);
                    future::ready(Some(new.then_some(setup)))
                })
                .filter_map(future::ready),
        )
    }

    async fn verify_this_device(&self) -> Result<MatrixVerification, BackendError> {
        let own = self.client.user_id().ok_or(BackendError::SignedOut)?.to_owned();
        // the other device verifies the keys the server gives it for this one.
        keys_on_server(&self.client).await?;
        let identity = self
            .client
            .encryption()
            .get_user_identity(&own)
            .await
            .map_err(BackendError::store)?
            // no identity yet: the account's encryption is not set up.
            .ok_or(BackendError::NotAllowed)?;
        let request = identity
            .request_verification_with_methods(methods())
            .await
            .map_err(|error| match error {
                RequestVerificationError::Sdk(error) => from_sdk(error),
                other @ RequestVerificationError::RoomCreation(_) => BackendError::refused(other),
            })?;
        Ok(MatrixVerification::start(request, None))
    }

    async fn own_devices(&self) -> Result<Vec<OwnDevice>, BackendError> {
        let own = self.client.user_id().ok_or(BackendError::SignedOut)?.to_owned();
        // the server's list: a device signed out elsewhere is gone from it now, not at the
        // sync's next look. Offline, the store's.
        if let Err(error) = self.client.encryption().request_user_identity(&own).await {
            warn!(%error, "the account's devices could not be asked for");
        }
        let devices = self
            .client
            .encryption()
            .get_user_devices(&own)
            .await
            .map_err(from_sdk)?;
        let this = self.client.device_id();
        let mut devices: Vec<OwnDevice> = devices
            .devices()
            .filter(|device| !device.is_deleted())
            .map(|device| own_device(&device, this))
            .collect();
        devices.sort_by(|a, b| {
            b.is_this_device
                .cmp(&a.is_this_device)
                .then_with(|| a.name.cmp(&b.name))
                .then_with(|| a.id.cmp(&b.id))
        });
        Ok(devices)
    }

    async fn verify_device(&self, device: &str) -> Result<MatrixVerification, BackendError> {
        let own = self.client.user_id().ok_or(BackendError::SignedOut)?.to_owned();
        if self.client.device_id().is_some_and(|this| this.as_str() == device) {
            return Err(BackendError::NotAllowed);
        }
        let device = self
            .client
            .encryption()
            .get_device(&own, device.into())
            .await
            .map_err(BackendError::store)?
            // a device that has no keys cannot verify.
            .ok_or(BackendError::NotAllowed)?;
        let request = device
            .request_verification_with_methods(methods())
            .await
            .map_err(from_sdk)?;
        Ok(MatrixVerification::start(
            request,
            Some(own_device(&device, self.client.device_id())),
        ))
    }

    async fn device_sign_out(&self, device: &str) -> Result<DeviceSignOut, BackendError> {
        let device = other_device_id(&self.client, device)?;
        match self.client.oauth().cached_server_metadata().await {
            // the server signs in with its own account service (OAuth): devices end there, as
            // the client API's deletion asks for a password the service does not take.
            Ok(metadata) => metadata
                .account_management_url_with_action(AccountManagementActionData::DeviceDelete(DeviceDeleteData::new(
                    &device,
                )))
                .map(|url| DeviceSignOut::InBrowser(url.to_string()))
                // an account service with no page for it: no way from here.
                .ok_or(BackendError::NotAllowed),
            Err(OAuthDiscoveryError::NotSupported) => Ok(DeviceSignOut::WithPassword),
            Err(OAuthDiscoveryError::Http(error)) => Err(from_http(error)),
            Err(error) => Err(BackendError::refused(error)),
        }
    }

    async fn sign_out_device(&self, device: &str, password: &str) -> Result<(), BackendError> {
        let devices = [other_device_id(&self.client, device)?];
        let own = self.client.user_id().ok_or(BackendError::SignedOut)?.to_string();
        // the server answers the first ask with the session the password then completes.
        let session = match self.client.delete_devices(&devices, None).await {
            Ok(_) => return Ok(()),
            Err(error) => match error.as_uiaa_response() {
                Some(info) => info.session.clone(),
                None => return Err(from_http(error)),
            },
        };
        let mut auth = Password::new(
            UserIdentifier::Matrix(MatrixUserIdentifier::new(own)),
            password.to_owned(),
        );
        auth.session = session;
        match self
            .client
            .delete_devices(&devices, Some(AuthData::Password(auth)))
            .await
        {
            Ok(_) => Ok(()),
            Err(error) => match error.as_uiaa_response() {
                // asked again, because of the password.
                Some(info)
                    if info
                        .auth_error
                        .as_ref()
                        .is_some_and(|error| matches!(error.kind, ErrorKind::Forbidden)) =>
                {
                    Err(BackendError::WrongCredentials)
                }
                // a step the password does not cover (an email, a captcha).
                Some(_) => Err(BackendError::NotAllowed),
                None => Err(from_http(error)),
            },
        }
    }

    fn verification_requests(&self) -> ValueStream<Arc<MatrixVerification>> {
        let client = self.client.clone();
        let received = stream::unfold(self.verification_requests.subscribe(), |mut receiver| async move {
            loop {
                match receiver.recv().await {
                    Ok(request) => return Some((request, receiver)),
                    // a listener that fell behind misses the oldest; the next still arrive.
                    Err(broadcast::error::RecvError::Lagged(_)) => {}
                    Err(broadcast::error::RecvError::Closed) => return None,
                }
            }
        });
        let requests = received.then(move |(request, from)| {
            let client = client.clone();
            async move {
                let other = other_device(&client, &request, &from).await;
                Arc::new(MatrixVerification::start(request, other))
            }
        });
        Box::pin(requests)
    }

    fn recovery_state(&self) -> RecoveryState {
        recovery_state(&self.client)
    }

    async fn recover(&self, key: &str) -> Result<(), BackendError> {
        // the key signs this device: the server must know it first.
        keys_on_server(&self.client).await?;
        match self.client.encryption().recovery().recover(key.trim()).await {
            Ok(()) => Ok(()),
            Err(RecoveryError::SecretStorage(SecretStorageError::SecretStorageKey(_))) => {
                Err(BackendError::WrongRecoveryKey)
            }
            // the key opened the store, the device's signature did not reach the server.
            Err(RecoveryError::SecretStorage(SecretStorageError::Verification(ManualVerifyError::Http(error)))) => {
                Err(from_http(error))
            }
            Err(RecoveryError::Sdk(error)) => Err(from_sdk(error)),
            Err(error) => Err(BackendError::refused(error)),
        }
    }

    async fn set_up_recovery(&self) -> Result<String, BackendError> {
        let encryption = self.client.encryption();
        encryption.wait_for_e2ee_initialization_tasks().await;
        if encryption.recovery().state() != SdkRecoveryState::Disabled {
            return Err(BackendError::NotAllowed);
        }
        // a new account: its identity first. The SDK asks the server for the account's identity
        // and makes one only when there is none, so an existing identity is never replaced.
        encryption
            .bootstrap_cross_signing_if_needed(None)
            .await
            .map_err(from_sdk)?;
        // the secrets the recovery key keeps: only a device that holds them can set it up (one
        // the account's identity was made on, or that another device verified).
        let holds_identity = encryption
            .cross_signing_status()
            .await
            .is_some_and(|status| status.is_complete());
        if !holds_identity {
            return Err(BackendError::NotAllowed);
        }
        match encryption.recovery().enable().wait_for_backups_to_upload().await {
            Ok(key) => Ok(key),
            // another device made a backup meanwhile: nothing is replaced.
            Err(RecoveryError::BackupExistsOnServer) => Err(BackendError::NotAllowed),
            Err(RecoveryError::Sdk(error)) => Err(from_sdk(error)),
            Err(error) => Err(BackendError::refused(error)),
        }
    }
}

fn recovery_state(client: &Client) -> RecoveryState {
    match client.encryption().recovery().state() {
        SdkRecoveryState::Enabled => RecoveryState::Enabled,
        SdkRecoveryState::Incomplete => RecoveryState::Incomplete,
        SdkRecoveryState::Disabled => RecoveryState::Disabled,
        SdkRecoveryState::Unknown => RecoveryState::Unknown,
    }
}

/// The id of the account's device `device`, if it is not this one: this one signs out on its own.
fn other_device_id(client: &Client, device: &str) -> Result<OwnedDeviceId, BackendError> {
    if client.device_id().is_some_and(|this| this.as_str() == device) {
        return Err(BackendError::NotAllowed);
    }
    Ok(device.into())
}

/// How long a device waits for its keys to reach the server.
const KEYS_UPLOAD_WAIT: Duration = Duration::from_secs(10);

/// Waits until the server holds this device's keys. The sync uploads them in the background, a
/// moment after the sign-in; a signature made before (the recovery key's, or another device's at
/// the end of a verification) is for a device the server does not know, and is lost.
///
/// # Errors
/// `NotAllowed` when they are not there in time; others when the server cannot be asked.
async fn keys_on_server(client: &Client) -> Result<(), BackendError> {
    let own = client.user_id().ok_or(BackendError::SignedOut)?.to_owned();
    let device = client.device_id().ok_or(BackendError::SignedOut)?.to_owned();
    let deadline = Instant::now() + KEYS_UPLOAD_WAIT;
    loop {
        let mut request = get_keys::v3::Request::new();
        request.device_keys = BTreeMap::from([(own.clone(), vec![device.clone()])]);
        let response = client.send(request).await.map_err(from_http)?;
        if response
            .device_keys
            .get(&own)
            .is_some_and(|keys| keys.contains_key(&device))
        {
            return Ok(());
        }
        if Instant::now() >= deadline {
            return Err(BackendError::NotAllowed);
        }
        // the sync's next round uploads them.
        sleep(Duration::from_millis(250)).await;
    }
}

/// Whether the account trusts this device. The SDK's state does not tell an account with no
/// identity from one whose identity it has not asked the server for yet: the server answers.
async fn trust(client: &Client) -> DeviceTrust {
    let encryption = client.encryption();
    encryption.wait_for_e2ee_initialization_tasks().await;
    match encryption.verification_state().get() {
        VerificationState::Verified => return DeviceTrust::Verified,
        VerificationState::Unverified => return DeviceTrust::Unverified,
        VerificationState::Unknown => {}
    }
    let Some(own) = client.user_id() else {
        return DeviceTrust::Unknown;
    };
    match encryption.request_user_identity(own).await {
        Ok(None) => DeviceTrust::NoIdentity,
        Ok(Some(_)) => match encryption.get_own_device().await {
            Ok(Some(device)) if device.is_cross_signed_by_owner() => DeviceTrust::Verified,
            Ok(Some(_)) => DeviceTrust::Unverified,
            Ok(None) | Err(_) => DeviceTrust::Unknown,
        },
        Err(error) => {
            warn!(%error, "the account's identity could not be asked for");
            DeviceTrust::Unknown
        }
    }
}

fn own_device(device: &Device, this: Option<&matrix_sdk::ruma::DeviceId>) -> OwnDevice {
    OwnDevice {
        id: device.device_id().to_string(),
        name: device.display_name().map(str::to_owned),
        is_verified: device.is_cross_signed_by_owner(),
        is_this_device: this == Some(device.device_id()),
    }
}

/// The device a request came from.
async fn other_device(client: &Client, request: &VerificationRequest, id: &OwnedDeviceId) -> Option<OwnDevice> {
    let device = client
        .encryption()
        .get_device(request.other_user_id(), id)
        .await
        .ok()
        .flatten()?;
    Some(own_device(&device, client.device_id()))
}

/// The requests the account's other devices send this one, passed on to each listener.
pub(crate) struct IncomingVerifications {
    client: Client,
    handler: EventHandlerHandle,
    /// Each request, with the device it came from.
    requests: broadcast::Sender<(VerificationRequest, OwnedDeviceId)>,
}

impl IncomingVerifications {
    /// Starts receiving them over `client`.
    pub(crate) fn start(client: &Client) -> Self {
        let (requests, _) = broadcast::channel(8);
        let handler = client.add_event_handler({
            let requests = requests.clone();
            move |event: ToDeviceKeyVerificationRequestEvent, client: Client| {
                let requests = requests.clone();
                async move {
                    // only the account's own devices: verifying other people is not offered.
                    if client.user_id() != Some(&*event.sender) {
                        return;
                    }
                    // the SDK keeps the request (and drops one too old to answer) as it reads
                    // the event, before any handler runs.
                    let request = client
                        .encryption()
                        .get_verification_request(&event.sender, &event.content.transaction_id)
                        .await;
                    if let Some(request) = request
                        && !request.we_started()
                    {
                        // no listener: the app is not up to show it; the request times out.
                        let _ = requests.send((request, event.content.from_device));
                    }
                }
            }
        });
        Self {
            client: client.clone(),
            handler,
            requests,
        }
    }

    fn subscribe(&self) -> broadcast::Receiver<(VerificationRequest, OwnedDeviceId)> {
        self.requests.subscribe()
    }
}

impl Drop for IncomingVerifications {
    fn drop(&mut self) {
        self.client.remove_event_handler(self.handler.clone());
    }
}

/// A verification between this device and another of the account's, followed by its task.
pub struct MatrixVerification {
    request: VerificationRequest,
    other: Option<OwnDevice>,
    steps: watch::Receiver<VerificationStep>,
    sas: watch::Receiver<Option<SasVerification>>,
    task: JoinHandle<()>,
}

impl MatrixVerification {
    fn start(request: VerificationRequest, other: Option<OwnDevice>) -> Self {
        let first = if request.we_started() {
            VerificationStep::Waiting
        } else {
            VerificationStep::Requested
        };
        let (step, steps) = watch::channel(first);
        let (sas_sender, sas) = watch::channel(None);
        let task = tokio::spawn(follow(request.clone(), step, sas_sender));
        Self {
            request,
            other,
            steps,
            sas,
            task,
        }
    }

    fn current_sas(&self) -> Result<SasVerification, BackendError> {
        self.sas
            .borrow()
            .clone()
            // no emojis to compare yet.
            .ok_or(BackendError::NotAllowed)
    }
}

impl Drop for MatrixVerification {
    fn drop(&mut self) {
        self.task.abort();
    }
}

impl Verification for MatrixVerification {
    fn other_device(&self) -> Option<OwnDevice> {
        self.other.clone()
    }

    fn steps(&self) -> ValueStream<VerificationStep> {
        watched(self.steps.clone())
    }

    async fn accept(&self) -> Result<(), BackendError> {
        if self.request.we_started() {
            return Err(BackendError::NotAllowed);
        }
        self.request.accept_with_methods(methods()).await.map_err(from_sdk)
    }

    async fn confirm(&self) -> Result<(), BackendError> {
        self.current_sas()?.confirm().await.map_err(from_sdk)
    }

    async fn deny(&self) -> Result<(), BackendError> {
        self.current_sas()?.mismatch().await.map_err(from_sdk)
    }

    async fn cancel(&self) {
        let sas = self.sas.borrow().clone();
        let cancelled = match sas {
            Some(sas) => sas.cancel().await,
            None => self.request.cancel().await,
        };
        if let Err(error) = cancelled {
            warn!(%error, "the verification could not be cancelled");
        }
    }
}

/// Follows the request, then its SAS, publishing each step until the last.
///
/// The device that asked starts the comparison once the other accepts. A device that starts
/// one too (another app may) meets the specification's rule for two starts: the one from the
/// smaller device id goes on, and the SDK replaces the other's SAS in the request with it. The
/// task then follows the request's SAS, whichever it is now.
async fn follow(
    request: VerificationRequest,
    step: watch::Sender<VerificationStep>,
    sas_sender: watch::Sender<Option<SasVerification>>,
) {
    let mut changes = request.changes();
    let mut sas = loop {
        match request.state() {
            // waiting: for the other device (`Waiting`), or for the user here (`Requested`).
            VerificationRequestState::Created { .. } | VerificationRequestState::Requested { .. } => {}
            VerificationRequestState::Ready { .. } => {
                step.send_replace(VerificationStep::Accepted);
                if request.we_started() {
                    match request.start_sas().await {
                        Ok(Some(sas)) => break sas,
                        // the other device's start came first: the request has transitioned.
                        Ok(None) => {}
                        Err(error) => {
                            warn!(%error, "the emoji comparison could not be started");
                            step.send_replace(VerificationStep::Failed);
                            return;
                        }
                    }
                }
            }
            VerificationRequestState::Transitioned { verification, .. } => {
                if let Some(sas) = verification.sas() {
                    break sas;
                }
                // a QR code, which this app does not show.
                step.send_replace(VerificationStep::Failed);
                return;
            }
            VerificationRequestState::Done => {
                step.send_replace(VerificationStep::Done);
                return;
            }
            VerificationRequestState::Cancelled(_) => {
                step.send_replace(VerificationStep::Cancelled);
                return;
            }
        }
        if changes.next().await.is_none() {
            return;
        }
    };
    loop {
        match follow_sas(&sas, &step, &sas_sender, &request, &mut changes).await {
            Some(replaced) => sas = replaced,
            None => return,
        }
    }
}

/// Follows `sas` until its last step, or until the request replaced it: then the new one.
async fn follow_sas(
    sas: &SasVerification,
    step: &watch::Sender<VerificationStep>,
    sas_sender: &watch::Sender<Option<SasVerification>>,
    request: &VerificationRequest,
    request_changes: &mut (impl futures_util::Stream<Item = VerificationRequestState> + Unpin),
) -> Option<SasVerification> {
    sas_sender.send_replace(Some(sas.clone()));
    // the other device started it: this one accepts.
    if !sas.we_started()
        && let Err(error) = sas.accept().await
    {
        warn!(%error, "the emoji comparison could not be accepted");
    }
    let mut changes = sas.changes();
    loop {
        match sas.state() {
            SasState::KeysExchanged {
                emojis: Some(emojis), ..
            } => {
                let compare = emojis
                    .emojis
                    .iter()
                    .map(|emoji| VerificationEmoji {
                        symbol: emoji.symbol.to_owned(),
                        name: emoji.description.to_owned(),
                    })
                    .collect();
                step.send_replace(VerificationStep::Compare(compare));
            }
            SasState::Done { .. } => {
                step.send_replace(VerificationStep::Done);
                return None;
            }
            SasState::Cancelled(info) => {
                if let Some(replaced) = replacement(request, sas) {
                    return Some(replaced);
                }
                // a mismatch, here or there, is a failure; anything else the user's choice.
                let failed = *info.cancel_code() == CancelCode::MismatchedSas;
                step.send_replace(if failed {
                    VerificationStep::Failed
                } else {
                    VerificationStep::Cancelled
                });
                return None;
            }
            SasState::Created { .. }
            | SasState::Started { .. }
            | SasState::Accepted { .. }
            | SasState::KeysExchanged { .. }
            | SasState::Confirmed => {}
        }
        tokio::select! {
            change = changes.next() => change?,
            change = request_changes.next() => {
                change?;
                if let Some(replaced) = replacement(request, sas) {
                    return Some(replaced);
                }
                continue;
            }
        };
    }
}

/// The request's SAS when it is no longer `sas`: the other device's start replaced it.
fn replacement(request: &VerificationRequest, sas: &SasVerification) -> Option<SasVerification> {
    let VerificationRequestState::Transitioned { verification, .. } = request.state() else {
        return None;
    };
    verification
        .sas()
        .filter(|current| current.we_started() != sas.we_started())
}
