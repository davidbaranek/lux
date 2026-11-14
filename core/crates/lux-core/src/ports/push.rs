//! Push notifications on the account's side: the device's pusher, and what a notification's
//! actions do without opening the chat.

use std::future::Future;
use std::pin::Pin;

use futures_core::Stream;

use crate::ids::{EventId, RoomId};
use crate::push::{Notification, Pusher};

use super::BackendError;

/// The notifications of what the sync brings, while the app runs.
pub type NotificationStream = Pin<Box<dyn Stream<Item = Notification> + Send>>;

/// The account's pusher for this device, and the actions a notification offers.
pub trait Push: Send + Sync {
    /// Registers `pusher` with the server, in place of the one this device registered before
    /// (another token, or another environment's app id). Asking again for the same one renews it.
    fn set_pusher(&self, pusher: &Pusher) -> impl Future<Output = Result<(), BackendError>> + Send;

    /// Removes the pusher this device registered, if any (signing out).
    fn remove_pusher(&self) -> impl Future<Output = Result<(), BackendError>> + Send;

    /// Sends `text` to `room` and returns once the server has it: the app may be suspended right
    /// after (a reply from a notification).
    fn send_now(&self, room: &RoomId, text: &str) -> impl Future<Output = Result<(), BackendError>> + Send;

    /// Marks `room` read up to `event`, the message a notification showed.
    fn mark_read_up_to(&self, room: &RoomId, event: &EventId) -> impl Future<Output = Result<(), BackendError>> + Send;

    /// What the sync brings that notifies, as it comes, while the app runs: where no push wakes
    /// an extension (the Mac), the app shows these itself. Only noisy messages from others, not
    /// yet read, sent since the stream was taken, each once
    /// ([`LiveNotifications`](crate::push::LiveNotifications)).
    fn live_notifications(&self) -> NotificationStream;
}
