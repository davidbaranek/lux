//! People and the account's security, as the apps see them: contacts, conversations, the
//! profile; this device's verification (a listener receives its steps) and recovery.

use std::sync::Arc;

use futures_util::StreamExt;
use lux_core::ports::ChatAccount;
use lux_core::ports::{
    Contact, ContactAccount, ContactProblem, People, RecoveryState, Security, Verification, VerificationStep,
};
use lux_matrix::MatrixVerification;

use crate::account::{Backend, CoreAccount, CoreAccountError, CoreListenerHandle};
use crate::runtime;

/// Someone to write to.
#[derive(Clone, uniffi::Record)]
pub struct CoreContact {
    /// Unique among a listing's contacts.
    pub id: String,
    /// The account that reaches them: `"matrix"`, or a bridge login's key.
    pub account_id: String,
    /// Their name.
    pub name: String,
    /// Their address on that account.
    pub identifier: String,
    /// Their network.
    pub network: String,
    /// Their picture.
    pub avatar: Option<String>,
}

/// What `account_id` says for Matrix itself.
const MATRIX: &str = "matrix";

impl From<Contact> for CoreContact {
    fn from(contact: Contact) -> Self {
        Self {
            id: contact.id,
            account_id: match contact.account {
                ContactAccount::Matrix => MATRIX.to_owned(),
                ContactAccount::Bridge(key) => key,
            },
            name: contact.name,
            identifier: contact.identifier,
            network: contact.network,
            avatar: contact.avatar.map(|avatar| avatar.to_string()),
        }
    }
}

impl From<CoreContact> for Contact {
    fn from(contact: CoreContact) -> Self {
        Self {
            id: contact.id,
            account: if contact.account_id == MATRIX {
                ContactAccount::Matrix
            } else {
                ContactAccount::Bridge(contact.account_id)
            },
            name: contact.name,
            identifier: contact.identifier,
            network: contact.network,
            avatar: contact.avatar.map(Into::into),
        }
    }
}

/// A part of a search that could not be done.
#[derive(Clone, uniffi::Enum)]
pub enum CoreContactProblem {
    /// The user directory did not answer.
    MatrixSearch,
    /// The bridges could not be found.
    Discovery,
    /// Some bridges did not answer.
    SomeAccounts,
    /// One account's contacts could not be read.
    Account {
        /// Its name.
        name: String,
    },
}

/// What a contact search found.
#[derive(uniffi::Record)]
pub struct CoreContactListing {
    /// The contacts.
    pub contacts: Vec<CoreContact>,
    /// What could not be searched.
    pub problems: Vec<CoreContactProblem>,
}

/// The account's profile.
#[derive(uniffi::Record)]
pub struct CoreProfile {
    /// The account.
    pub user_id: String,
    /// Its name.
    pub name: String,
    /// Its picture.
    pub avatar: Option<String>,
}

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
    /// Waiting for another device.
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

/// A verification of this device in progress.
#[derive(uniffi::Object)]
pub struct CoreVerification {
    verification: Arc<MatrixVerification>,
}

#[uniffi::export(async_runtime = "tokio")]
impl CoreVerification {
    /// Sends the steps to `listener` until the handle is let go.
    pub fn listen(&self, listener: Arc<dyn CoreVerificationListener>) -> Arc<CoreListenerHandle> {
        let steps = self.verification.steps();
        let task = runtime::handle().spawn(steps.for_each(move |step| {
            listener.on_step(step.into());
            async {}
        }));
        Arc::new(CoreListenerHandle { tasks: vec![task] })
    }

    /// The emojis match.
    ///
    /// # Errors
    /// When there are none to compare yet, or the answer cannot be sent.
    pub async fn confirm(&self) -> Result<(), CoreAccountError> {
        Ok(self.verification.confirm().await?)
    }

    /// The emojis do not match.
    ///
    /// # Errors
    /// When there are none to compare yet, or the answer cannot be sent.
    pub async fn deny(&self) -> Result<(), CoreAccountError> {
        Ok(self.verification.deny().await?)
    }

    /// The user gave up.
    pub async fn cancel(&self) {
        self.verification.cancel().await;
    }
}

#[uniffi::export(async_runtime = "tokio")]
impl CoreAccount {
    /// People to write to, by `query` (the demo knows none).
    ///
    /// # Errors
    /// When the account is gone.
    pub async fn contacts(&self, query: String) -> Result<CoreContactListing, CoreAccountError> {
        let Backend::Matrix(account) = self.backend() else {
            return Ok(CoreContactListing {
                contacts: Vec::new(),
                problems: Vec::new(),
            });
        };
        let listing = account.contacts(&query).await?;
        Ok(CoreContactListing {
            contacts: listing.contacts.into_iter().map(CoreContact::from).collect(),
            problems: listing
                .problems
                .into_iter()
                .map(|problem| match problem {
                    ContactProblem::MatrixSearch => CoreContactProblem::MatrixSearch,
                    ContactProblem::Discovery => CoreContactProblem::Discovery,
                    ContactProblem::SomeAccounts => CoreContactProblem::SomeAccounts,
                    ContactProblem::Account(name) => CoreContactProblem::Account { name },
                })
                .collect(),
        })
    }

    /// The conversation with a contact: the one there is, else a new one. Its room.
    ///
    /// # Errors
    /// When the server or the bridge refuses.
    pub async fn start_conversation(&self, contact: CoreContact) -> Result<String, CoreAccountError> {
        Ok(self
            .matrix_account()?
            .start_conversation(&contact.into())
            .await?
            .to_string())
    }

    /// A new encrypted group. Its room.
    ///
    /// # Errors
    /// When the server refuses.
    pub async fn create_room(&self, name: String) -> Result<String, CoreAccountError> {
        Ok(self.matrix_account()?.create_room(&name).await?.to_string())
    }

    /// The account's profile; the demo's is its user, named by its id.
    ///
    /// # Errors
    /// When the server cannot be reached.
    pub async fn profile(&self) -> Result<CoreProfile, CoreAccountError> {
        let account = match self.backend() {
            Backend::Matrix(account) => account,
            Backend::Demo(demo) => {
                let user_id = demo.own_user_id().to_string();
                return Ok(CoreProfile {
                    name: user_id.clone(),
                    user_id,
                    avatar: None,
                });
            }
        };
        let profile = account.profile().await?;
        Ok(CoreProfile {
            user_id: profile.user_id.to_string(),
            name: profile.name,
            avatar: profile.avatar.map(|avatar| avatar.to_string()),
        })
    }

    /// Whether the account's other devices trust this one (the demo's has none to ask).
    pub async fn is_device_verified(&self) -> bool {
        match self.backend() {
            Backend::Matrix(account) => account.is_device_verified().await,
            Backend::Demo(_) => true,
        }
    }

    /// Asks the account's other devices to verify this one.
    ///
    /// # Errors
    /// When the account has no identity yet, or the request cannot be sent.
    pub async fn verify_this_device(&self) -> Result<Arc<CoreVerification>, CoreAccountError> {
        let verification = self.matrix_account()?.verify_this_device().await?;
        Ok(Arc::new(CoreVerification {
            verification: Arc::new(verification),
        }))
    }

    /// Whether the key backup is open on this device (the demo keeps none).
    #[must_use]
    pub fn recovery_state(&self) -> CoreRecoveryState {
        let Backend::Matrix(account) = self.backend() else {
            return CoreRecoveryState::Disabled;
        };
        match account.recovery_state() {
            RecoveryState::Enabled => CoreRecoveryState::Enabled,
            RecoveryState::Incomplete => CoreRecoveryState::Incomplete,
            RecoveryState::Disabled => CoreRecoveryState::Disabled,
            RecoveryState::Unknown => CoreRecoveryState::Unknown,
        }
    }

    /// Opens the key backup with the recovery key.
    ///
    /// # Errors
    /// `WrongRecoveryKey` for a key that does not open it.
    pub async fn recover(&self, key: String) -> Result<(), CoreAccountError> {
        Ok(self.matrix_account()?.recover(&key).await?)
    }
}
