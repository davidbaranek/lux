//! `lux-core`'s ports over the Matrix SDK (`matrix-sdk`, `matrix-sdk-ui`): the account, its sync,
//! its room list and its chats' timelines.
//!
//! - [`MatrixSignIn`] opens the account kept in its folder ([`StoreFolder`]), or signs one in
//!   there; the platform keeps the session's secrets ([`SecretStore`](lux_core::ports::SecretStore)).
//! - [`MatrixAccount`] is the signed-in account: the sync service, and the chat list and the
//!   requests as streams of diffs.
//!   It also implements the account's other ports: a chat's actions and the organizing kept in
//!   the account's data, the spaces, sending later, people, and the encryption's security.
//! - [`MatrixTimelines`] are its chats' timelines: their messages, sending, and media.
//! - [`MatrixNotifications`] reads one pushed event in the notification extension, without the
//!   sync.
//! - [`KeptList`] is the last chat list, kept in the account's encrypted store and read at
//!   launch before the account opens.
//!
//! The SDK's types end here: what leaves this crate is `lux-core`'s.

// the sdk's futures nest deeply.
#![recursion_limit = "256"]

mod account;
mod actions;
mod bridge_state;
mod convert;
mod errors;
mod kept;
mod latest;
mod lifecycle;
mod live;
mod live_list;
mod mapping;
mod members;
mod notification;
mod organizer;
mod people;
mod push;
mod redecrypt;
mod room_list;
mod scheduling;
mod security;
mod send_queue;
mod session;
mod share;
mod sign_in;
mod spaces;
mod store;
mod streams;
mod thread;
mod timeline;

pub use account::MatrixAccount;
pub use kept::KeptList;
pub use notification::{MatrixNotifications, NotificationPictures};
pub use security::MatrixVerification;
pub use share::MatrixShare;
pub use sign_in::{MatrixOAuth, MatrixSignIn, login_methods};
pub use store::StoreFolder;
pub use timeline::MatrixTimelines;
