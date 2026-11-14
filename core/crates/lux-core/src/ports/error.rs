//! What can go wrong in a backend.

use super::SecretStoreError;
use crate::ids::ChatId;
use crate::organizer::LabelError;

/// What made a failure happen, kept for the logs: the apps decide by the variant, never by it.
pub type Cause = Box<dyn std::error::Error + Send + Sync>;

/// Why a backend's action failed.
#[derive(Debug, thiserror::Error)]
pub enum BackendError {
    /// No session is kept on this device.
    #[error("no account is signed in")]
    SignedOut,
    /// The kept session's store on this device cannot be opened, so the session is not opened
    /// over it: the app forgets the account and signs in again.
    #[error("the account's store cannot be opened: {0}")]
    StoreUnusable(UnusableStore),
    /// The store holds another account or device than the session.
    #[error("the account's store belongs to another session")]
    StoreMismatch,
    /// No Matrix server answers at the address.
    #[error("no Matrix server answers at this address")]
    ServerNotFound,
    /// The server does not offer this way of signing in.
    #[error("the server does not offer this way of signing in")]
    UnsupportedLogin,
    /// The user name or password is wrong.
    #[error("the user name or password is wrong")]
    WrongCredentials,
    /// The callback of a sign-in in the browser was not the one the sign-in waits for.
    #[error("the sign-in's callback is not valid")]
    InvalidCallback,
    /// The server no longer knows the session (signed out from another device).
    #[error("the session has ended")]
    SessionEnded,
    /// The chat is not one of the account's (not joined, not known yet, or merged no more).
    #[error("the chat {0} is not in the account")]
    UnknownChat(ChatId),
    /// The contact cannot be written to: no such Matrix user, or no login on its network.
    #[error("the contact {0} cannot be reached")]
    UnknownContact(String),
    /// A change to the labels was refused.
    #[error(transparent)]
    Label(#[from] LabelError),
    /// The message cannot be saved: the server does not have it yet, or it is no message.
    #[error("the message cannot be saved")]
    NotSavable,
    /// An end-to-end encrypted chat cannot have messages sent later: the server sends them.
    #[error("an encrypted chat cannot send messages later")]
    EncryptedChat,
    /// The time to send a message at has passed.
    #[error("the time is past")]
    TimePassed,
    /// The waiting message is gone: it went, or was cancelled.
    #[error("the waiting message is gone")]
    NotWaiting,
    /// The recovery key does not open the account's key backup.
    #[error("the recovery key is wrong")]
    WrongRecoveryKey,
    /// The message is not in the chat's timeline.
    #[error("the message is not in the chat")]
    UnknownMessage,
    /// This cannot be done now: to another's message, a message not sent yet, a verification
    /// not that far, an account without its encryption identity.
    #[error("this cannot be done now")]
    NotAllowed,
    /// A file on the device could not be read or written, or is no attachment.
    #[error("a file on the device failed")]
    File(#[source] Cause),
    /// The platform could not keep or give the session's secrets.
    #[error(transparent)]
    Secrets(#[from] SecretStoreError),
    /// The store on this device failed.
    #[error("the store failed")]
    Store(#[source] Cause),
    /// The server could not be reached.
    #[error("the network failed ({kind:?})")]
    Network {
        /// How.
        kind: NetworkFailure,
        /// The failure.
        #[source]
        source: Cause,
    },
    /// The server, or a bridge through it, answered with an error.
    #[error("the server refused (status {status:?}, {errcode:?})")]
    Server {
        /// The HTTP status, when it answered with one.
        status: Option<u16>,
        /// The Matrix error code (`M_FORBIDDEN`, …), when it gave one.
        errcode: Option<String>,
        /// The failure.
        #[source]
        source: Cause,
    },
}

/// How the network failed, to tell waiting it out from a request that cannot go.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum NetworkFailure {
    /// The server did not answer in time.
    Timeout,
    /// No connection to the server could be made (offline, no address).
    Offline,
    /// The connection failed otherwise.
    Other,
}

impl BackendError {
    /// A store failure caused by `cause`.
    pub fn store(cause: impl Into<Cause>) -> Self {
        Self::Store(cause.into())
    }

    /// A refusal with no status, caused by `cause` (a bridge's, an SDK step's).
    pub fn refused(cause: impl Into<Cause>) -> Self {
        Self::Server {
            status: None,
            errcode: None,
            source: cause.into(),
        }
    }

    /// A file failure caused by `cause`.
    pub fn file(cause: impl Into<Cause>) -> Self {
        Self::File(cause.into())
    }
}

/// Why the kept session's store cannot be opened.
#[derive(Clone, Copy, Debug, PartialEq, Eq, thiserror::Error)]
pub enum UnusableStore {
    /// The folder holds no device: opening it would make a new, empty store for a device the
    /// server knows, without its encryption keys.
    #[error("it is missing")]
    Missing,
    /// The store is not encrypted.
    #[error("it is not encrypted")]
    NotEncrypted,
    /// The store is encrypted, but its key is not kept on this device.
    #[error("its key is missing")]
    KeyMissing,
    /// The kept key does not open the store.
    #[error("the kept key does not open it")]
    WrongKey,
}
