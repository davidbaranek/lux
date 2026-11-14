//! The signed-in account: its sync, and its lists as streams of diffs.

use std::future::Future;
use std::pin::Pin;
use std::sync::Arc;

use eyeball_im::VectorDiff;
use futures_core::Stream;

use crate::chat::{Chat, Request};
use crate::ids::{DeviceId, UserId};

use super::BackendError;

/// One batch of changes to a list, to apply in order.
pub type Diffs<T> = Vec<VectorDiff<T>>;

/// A live list: a `Reset` with the whole list first, then the batches that change it. It ends
/// when the account closes.
pub type DiffStream<T> = Pin<Box<dyn Stream<Item = Diffs<T>> + Send>>;

/// A signed-in account: what the chat list needs from it.
///
/// Every method may be called from any task; the streams can be taken more than once, each
/// starting with the whole list.
pub trait ChatAccount: Send + Sync {
    /// The account's user.
    fn own_user_id(&self) -> &UserId;

    /// This device of the account.
    fn device_id(&self) -> &DeviceId;

    /// The joined chats (not spaces), the most recent first: what the chat list shows, before
    /// the user's folders and merges.
    fn chats(&self) -> DiffStream<Arc<Chat>>;

    /// The invitations the user has not answered, the most recent first.
    fn requests(&self) -> DiffStream<Request>;

    /// Returns once the server has answered the first sync of this launch (at once when it
    /// already has): the lists are then up to date.
    fn wait_for_first_sync(&self) -> impl Future<Output = ()> + Send;

    /// Completes once the server has ended this device's session (it refuses its tokens, and
    /// none can be refreshed): the platform then forgets the session and signs in again. Never
    /// completes while the session lives; it holds nothing of the account.
    fn session_end(&self) -> impl Future<Output = ()> + Send + 'static;

    /// Stops the sync cleanly (the app goes to the background); the lists keep what they have.
    fn pause_sync(&self) -> impl Future<Output = ()> + Send;

    /// Starts the sync again (the app is back in front): the lists catch up.
    fn resume_sync(&self) -> impl Future<Output = ()> + Send;

    /// Signs this device out on the server; the platform then forgets the session and deletes
    /// the store.
    fn sign_out(&self) -> impl Future<Output = Result<(), BackendError>> + Send;
}
