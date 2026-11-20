//! What the user does to the account's chats besides writing in them: a chat's menu, the
//! invitations, and the organizing kept with the account (labels, reminders, saved messages,
//! merged chats, the places' arrangement), each change from another device arriving live.

use std::future::Future;
use std::pin::Pin;
use std::sync::Arc;
use std::time::SystemTime;

use futures_core::Stream;

use crate::chat::{Label, ScheduledMessage, Space};
use crate::ids::{ChatId, EventId, LabelId, RoomId, ScheduledId};
use crate::organizer::Organized;
use crate::places::Arrangement;

use super::BackendError;

/// A value each time it changes, the current one first. It ends when the account closes.
pub type ValueStream<T> = Pin<Box<dyn Stream<Item = T> + Send>>;

/// What a chat's menu does to it (and to each room of a merged one).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum ChatChange {
    /// Read up to its newest message, and not marked unread.
    Read,
    /// Marked unread by hand.
    Unread,
    /// Its messages notify nothing.
    Mute,
    /// Its messages notify as the account's settings say.
    Unmute,
    /// Into Low Priority (unpinned).
    LowPriority,
    /// Out of Low Priority, back to the inbox.
    Inbox,
    /// Into the archive until a newer message.
    Archive,
    /// Out of the archive.
    Unarchive,
    /// In no list until a newer message, its thread shown from then on.
    Delete,
    /// Pinned after the pinned chats.
    Pin,
    /// Unpinned.
    Unpin,
}

/// A chat's actions and the invitations.
pub trait ChatActions: Send + Sync {
    /// Does `change` to `chat`: to each of its rooms, for a merged chat.
    fn change(&self, chat: &ChatId, change: ChatChange) -> impl Future<Output = Result<(), BackendError>> + Send;

    /// Answers an invitation: accepting joins the room, declining refuses it.
    fn answer_request(&self, room: &RoomId, accept: bool) -> impl Future<Output = Result<(), BackendError>> + Send;
}

/// The organizing the account keeps with it. A change shows in [`Organizing::organized`] (and in
/// the chat list) as soon as the server has it.
pub trait Organizing: Send + Sync {
    /// Everything organized, each time any of it changes, here or on another device.
    fn organized(&self) -> ValueStream<Arc<Organized>>;

    /// Makes a label named `name`.
    fn make_label(&self, name: &str) -> impl Future<Output = Result<Label, BackendError>> + Send;

    /// Deletes label `id`; its chats stay as they are.
    fn remove_label(&self, id: &LabelId) -> impl Future<Output = Result<(), BackendError>> + Send;

    /// Puts `chat` (each room of a merged one) in label `id`, or takes it out.
    fn set_in_label(
        &self,
        chat: &ChatId,
        id: &LabelId,
        included: bool,
    ) -> impl Future<Output = Result<(), BackendError>> + Send;

    /// Reminds the user to answer `chat` at `at`; `None` takes the reminder away.
    fn set_reminder(
        &self,
        chat: &ChatId,
        at: Option<SystemTime>,
    ) -> impl Future<Output = Result<(), BackendError>> + Send;

    /// Shows `chats` (a merged one's rooms count each) as one chat named `name`, writing to
    /// `default_room` unless another is picked. Merging chats of a merge changes that merge.
    /// The merged chat's id.
    fn merge(
        &self,
        chats: &[ChatId],
        name: &str,
        default_room: &RoomId,
    ) -> impl Future<Output = Result<ChatId, BackendError>> + Send;

    /// Takes a merged chat apart: its rooms show as their own chats again.
    fn unmerge(&self, chat: &ChatId) -> impl Future<Output = Result<(), BackendError>> + Send;

    /// Keeps how the user arranged the places.
    fn set_arrangement(&self, arrangement: &Arrangement) -> impl Future<Output = Result<(), BackendError>> + Send;

    /// Keeps `chat` (named `name`) from every AI in Lux, or shows it again: on every device.
    fn set_hidden_from_ai(
        &self,
        chat: &ChatId,
        name: &str,
        hidden: bool,
    ) -> impl Future<Output = Result<(), BackendError>> + Send;
}

/// The messages the user saved, across chats; they show in [`Organizing::organized`].
pub trait SavedMessages: Send + Sync {
    /// Saves a message the server has, as it is now.
    fn save_message(&self, room: &RoomId, event: &EventId) -> impl Future<Output = Result<(), BackendError>> + Send;

    /// Takes a message out of the saved ones.
    fn unsave_message(&self, room: &RoomId, event: &EventId) -> impl Future<Output = Result<(), BackendError>> + Send;
}

/// The Matrix spaces the user is in.
pub trait Spaces: Send + Sync {
    /// The top-level spaces and those inside them (with their parents), each time they change.
    fn spaces(&self) -> ValueStream<Arc<[Space]>>;
}

/// Messages the server holds to send at a later time.
pub trait Scheduling: Send + Sync {
    /// Whether the room can have messages sent later: it is not end-to-end encrypted.
    fn can_send_later(&self, room: &RoomId) -> impl Future<Output = bool> + Send;

    /// Has the server send `text` to `room` at `at`, answering `reply_to`. Its id.
    fn send_later(
        &self,
        room: &RoomId,
        text: &str,
        reply_to: Option<&EventId>,
        at: SystemTime,
    ) -> impl Future<Output = Result<ScheduledId, BackendError>> + Send;

    /// The messages waiting, the soonest first.
    fn scheduled(&self) -> impl Future<Output = Result<Vec<ScheduledMessage>, BackendError>> + Send;

    /// Cancels a waiting message: it never goes.
    fn cancel_scheduled(&self, id: &ScheduledId) -> impl Future<Output = Result<(), BackendError>> + Send;
}
