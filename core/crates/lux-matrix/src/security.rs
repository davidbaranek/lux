//! Verifying this device from another of the account's (comparing emojis, SAS), and opening
//! the key backup with the recovery key.
//!
//! One task follows a verification: the request until another device accepts it, then the
//! emoji comparison, and publishes each step. The answer to the comparison goes to the SAS it
//! started.

use futures_util::StreamExt;
use lux_core::ports::{
    BackendError, RecoveryState, Security, ValueStream, Verification, VerificationEmoji, VerificationStep,
};
use matrix_sdk::encryption::VerificationState;
use matrix_sdk::encryption::identities::RequestVerificationError;
use matrix_sdk::encryption::recovery::{RecoveryError, RecoveryState as SdkRecoveryState};
use matrix_sdk::encryption::secret_storage::SecretStorageError;
use matrix_sdk::encryption::verification::{SasState, SasVerification, VerificationRequest, VerificationRequestState};
use matrix_sdk::ruma::events::key::verification::cancel::CancelCode;
use tokio::sync::watch;
use tokio::task::JoinHandle;

use crate::account::MatrixAccount;
use crate::errors::from_sdk;
use crate::streams::watched;

impl Security for MatrixAccount {
    type Verification = MatrixVerification;

    async fn is_device_verified(&self) -> bool {
        let encryption = self.client.encryption();
        // the state is known once the device's identity is read; a moment after launch.
        encryption.wait_for_e2ee_initialization_tasks().await;
        matches!(encryption.verification_state().get(), VerificationState::Verified)
    }

    async fn verify_this_device(&self) -> Result<MatrixVerification, BackendError> {
        let own = self.client.user_id().ok_or(BackendError::SignedOut)?.to_owned();
        let identity = self
            .client
            .encryption()
            .get_user_identity(&own)
            .await
            .map_err(BackendError::store)?
            // no identity yet: the account's encryption is not set up.
            .ok_or(BackendError::NotAllowed)?;
        let request = identity.request_verification().await.map_err(|error| match error {
            RequestVerificationError::Sdk(error) => from_sdk(error),
            other @ RequestVerificationError::RoomCreation(_) => BackendError::refused(other),
        })?;
        Ok(MatrixVerification::start(request))
    }

    fn recovery_state(&self) -> RecoveryState {
        match self.client.encryption().recovery().state() {
            SdkRecoveryState::Enabled => RecoveryState::Enabled,
            SdkRecoveryState::Incomplete => RecoveryState::Incomplete,
            SdkRecoveryState::Disabled => RecoveryState::Disabled,
            SdkRecoveryState::Unknown => RecoveryState::Unknown,
        }
    }

    async fn recover(&self, key: &str) -> Result<(), BackendError> {
        match self.client.encryption().recovery().recover(key.trim()).await {
            Ok(()) => Ok(()),
            Err(RecoveryError::SecretStorage(
                SecretStorageError::SecretStorageKey(_) | SecretStorageError::Verification(_),
            )) => Err(BackendError::WrongRecoveryKey),
            Err(RecoveryError::Sdk(error)) => Err(from_sdk(error)),
            Err(error) => Err(BackendError::refused(error)),
        }
    }
}

/// A verification of this device, followed by its task.
pub struct MatrixVerification {
    request: VerificationRequest,
    steps: watch::Receiver<VerificationStep>,
    sas: watch::Receiver<Option<SasVerification>>,
    task: JoinHandle<()>,
}

impl MatrixVerification {
    fn start(request: VerificationRequest) -> Self {
        let (step, steps) = watch::channel(VerificationStep::Waiting);
        let (sas_sender, sas) = watch::channel(None);
        let task = tokio::spawn(follow(request.clone(), step, sas_sender));
        Self {
            request,
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
    fn steps(&self) -> ValueStream<VerificationStep> {
        watched(self.steps.clone())
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
            tracing::warn!(%error, "the verification could not be cancelled");
        }
    }
}

/// Follows the request, then its SAS, publishing each step until the last.
async fn follow(
    request: VerificationRequest,
    step: watch::Sender<VerificationStep>,
    sas_sender: watch::Sender<Option<SasVerification>>,
) {
    let mut changes = request.changes();
    let sas = loop {
        let state = request.state();
        match state {
            VerificationRequestState::Created { .. } | VerificationRequestState::Requested { .. } => {}
            VerificationRequestState::Ready { .. } => {
                step.send_replace(VerificationStep::Accepted);
                if let Ok(Some(sas)) = request.start_sas().await {
                    break sas;
                }
                step.send_replace(VerificationStep::Failed);
                return;
            }
            VerificationRequestState::Transitioned { verification, .. } => {
                if let Some(sas) = verification.sas() {
                    break sas;
                }
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
    sas_sender.send_replace(Some(sas.clone()));
    // the other device may have started it: this one accepts.
    if !sas.we_started()
        && let Err(error) = sas.accept().await
    {
        tracing::warn!(%error, "the emoji comparison could not be accepted");
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
                return;
            }
            SasState::Cancelled(info) => {
                // a mismatch, here or there, is a failure; anything else the user's choice.
                let failed = *info.cancel_code() == CancelCode::MismatchedSas;
                step.send_replace(if failed {
                    VerificationStep::Failed
                } else {
                    VerificationStep::Cancelled
                });
                return;
            }
            SasState::Created { .. }
            | SasState::Started { .. }
            | SasState::Accepted { .. }
            | SasState::KeysExchanged { .. }
            | SasState::Confirmed => {}
        }
        if changes.next().await.is_none() {
            return;
        }
    }
}
