//! What the core needs from the outside, as traits: a chat backend (a Matrix account; later the
//! demo too) and the platform's keeping of session secrets. Adapters implement them
//! (`lux-matrix`), and the core never names the SDK.
//!
//! Live data comes as streams of batches of [`VectorDiff`](eyeball_im::VectorDiff)s, as the SDK's
//! room list sends them: a stream starts with a `Reset` of the whole list, then sends only what
//! changed. Actions are `async` and fail with a [`BackendError`].
//!
//! Beside [`ChatAccount`] (signing in, the sync, the chat list), each part of the account is its
//! own trait, so an adapter grows piece by piece: a chat's messages ([`ChatTimelines`],
//! [`ChatSending`], [`ChatMedia`]), its actions and the organizing kept with the account
//! ([`ChatActions`], [`Organizing`], [`SavedMessages`]), [`Spaces`], [`Scheduling`], [`People`], the
//! [`AccountProfile`], a chat's [`ChatDetails`], [`Security`], and the
//! device's [`Push`] notifications.
//! A thread's view model takes what it needs of them as one [`ThreadBackend`].

mod account;
mod bridges;
mod details;
mod error;
mod organizing;
mod people;
mod profile;
mod push;
mod secrets;
mod security;
mod sign_in;
mod thread;
mod timeline;

pub use account::{ChatAccount, DiffStream, Diffs};
pub use bridges::{Bridges, StepAnswer};
pub use details::{
    ChatDetails, ListedThread, Member, NotificationMode, Role, RoomDetails, RoomPermissions, SharedContent, SharedItem,
    SharedKind, SharedPage, ThreadPage,
};
pub use error::{BackendError, Cause, NetworkFailure, UnusableStore};
pub use organizing::{ChatActions, ChatChange, Organizing, SavedMessages, Scheduling, Spaces, ValueStream};
pub use people::{Contact, ContactAccount, ContactListing, ContactProblem, People};
pub use profile::{AccountProfile, MAX_NAME_LENGTH, Picture, PictureFormat, Profile, display_name};
pub use push::{NotificationStream, Push};
pub use secrets::{SecretStore, SecretStoreError, SessionSecrets, StoreKey};
pub use security::{
    DeviceSignOut, DeviceTrust, EncryptionSetup, OwnDevice, RecoveryState, Security, Verification, VerificationEmoji,
    VerificationStep,
};
pub use sign_in::{LoginMethods, OAuthClient, OAuthSignIn, SignIn};
pub use thread::ThreadBackend;
pub use timeline::{ChatMedia, ChatSending, ChatTimelines, RoomChanges, TimelineHold, TypingStream};
