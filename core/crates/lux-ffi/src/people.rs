//! People, as the apps see them: contacts, conversations, the profile.

use lux_core::ports::ChatAccount;
use lux_core::ports::{Contact, ContactAccount, ContactProblem, People};

use crate::account::{Backend, CoreAccount, CoreAccountError};

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
}
