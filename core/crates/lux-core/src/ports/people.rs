//! The people around the account: whom to write to, starting a conversation.

use std::future::Future;

use crate::ids::{MediaId, RoomId};

use super::BackendError;

/// The account a contact is reached through.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum ContactAccount {
    /// Matrix itself: the contact's identifier is a user id (a person, a bridge's bot or ghost).
    Matrix,
    /// A bridge's login (a WhatsApp number signed in to a bridge), by the core's own key for it.
    Bridge(String),
}

/// Someone to write to: a Matrix user, or a contact of a bridged network.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct Contact {
    /// Unique among a listing's contacts.
    pub id: String,
    /// The account that reaches them.
    pub account: ContactAccount,
    /// Their name.
    pub name: String,
    /// Their address on that account: a Matrix id, a phone number, a user name.
    pub identifier: String,
    /// Their network (`"matrix"`, `"whatsapp"`).
    pub network: String,
    /// Their picture.
    pub avatar: Option<MediaId>,
}

/// A part of a contact search that could not be done; the others' contacts are listed.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum ContactProblem {
    /// The server's user directory did not answer.
    MatrixSearch,
    /// The server's bridges could not be found.
    Discovery,
    /// Some bridges did not say which accounts they have.
    SomeAccounts,
    /// One bridge account's contacts could not be read, by its name.
    Account(String),
}

/// What a contact search found.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ContactListing {
    /// The contacts.
    pub contacts: Vec<Contact>,
    /// What could not be searched.
    pub problems: Vec<ContactProblem>,
}

/// Contacts and conversations.
pub trait People: Send + Sync {
    /// People to write to, by `query`: the server's user directory, and the contacts of the
    /// accounts the server's bridges hold for the user.
    fn contacts(&self, query: &str) -> impl Future<Output = Result<ContactListing, BackendError>> + Send;

    /// The conversation with `contact`: the joined one there is, else a new one. Its room.
    fn start_conversation(&self, contact: &Contact) -> impl Future<Output = Result<RoomId, BackendError>> + Send;

    /// A new, encrypted group named `name`. Its room.
    fn create_room(&self, name: &str) -> impl Future<Output = Result<RoomId, BackendError>> + Send;
}
