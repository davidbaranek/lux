//! A chat's messages: reading its timeline, sending to it, and loading its media.
//!
//! The backend keeps one live timeline per chat opened, from the first call that names the room:
//! those the apps hold (a chat on screen), and a few used last; the others close.

use std::future::Future;
use std::path::{Path, PathBuf};
use std::pin::Pin;
use std::sync::Arc;
use std::time::SystemTime;

use futures_core::Stream;

use crate::ids::{EventId, MessageId, MessageRef, RoomId};
use crate::message::SendState;
use crate::timeline::{Draft, ImageSource, OutgoingAttachment, Receipt, TextHistory, TimelineMessage, Typist};

use super::{BackendError, DiffStream};

/// The rooms whose open timeline changed, one each time a batch changes it.
pub type RoomChanges = Pin<Box<dyn Stream<Item = RoomId> + Send>>;

/// Who else is typing in a chat, each time it changes; empty when nobody is.
pub type TypingStream = Pin<Box<dyn Stream<Item = Vec<Typist>> + Send>>;

/// Keeps a chat's timeline open while it lives: the backend closes the timelines nobody holds
/// once more than a few are open, and a closed one opens afresh (its paging back lost).
#[must_use = "the timeline may close as soon as the hold goes"]
pub struct TimelineHold {
    release: Option<Box<dyn FnOnce() + Send + Sync>>,
}

impl TimelineHold {
    /// A hold that calls `release` when it goes.
    pub fn new(release: impl FnOnce() + Send + Sync + 'static) -> Self {
        Self {
            release: Some(Box::new(release)),
        }
    }
}

impl Drop for TimelineHold {
    fn drop(&mut self) {
        if let Some(release) = self.release.take() {
            release();
        }
    }
}

impl std::fmt::Debug for TimelineHold {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.debug_struct("TimelineHold").finish_non_exhaustive()
    }
}

/// Reading a chat's messages.
pub trait ChatTimelines: Send + Sync {
    /// The rooms whose open timeline changes, from now on.
    fn changes(&self) -> RoomChanges;

    /// Keeps the room's timeline open, once a call opens it, until the hold goes.
    fn hold(&self, room: &RoomId) -> TimelineHold;

    /// The room's messages, oldest first, as they change: a `Reset` with those the timeline has,
    /// then each batch. No two messages share an id, in this room or any other.
    fn messages(
        &self,
        room: &RoomId,
    ) -> impl Future<Output = Result<DiffStream<Arc<TimelineMessage>>, BackendError>> + Send;

    /// Opens the room's timeline ahead of time (its first screen from the server if the device
    /// has none), so the chat opens at once.
    fn prefetch(&self, room: &RoomId) -> impl Future<Output = Result<(), BackendError>> + Send;

    /// Returns once the opened chat's first screen is in, its server pages included.
    fn wait_until_filled(&self, room: &RoomId) -> impl Future<Output = ()> + Send;

    /// Pages back on the server until the timeline holds `count` more messages than now, or the
    /// room's first one. Which of them show is the thread's choice ([`Window`](crate::timeline::Window)).
    fn load_older(&self, room: &RoomId, count: usize) -> impl Future<Output = Result<(), BackendError>> + Send;

    /// The timeline holds the room's first message, its first screen in: there is nothing older
    /// on the server.
    fn is_at_start(&self, room: &RoomId) -> impl Future<Output = Result<bool, BackendError>> + Send;

    /// Pages back until the timeline holds the message of `event`; its id there, `None` when it
    /// cannot be found.
    fn show_event(
        &self,
        room: &RoomId,
        event: &EventId,
    ) -> impl Future<Output = Result<Option<MessageId>, BackendError>> + Send;

    /// The first message after the account's read receipt, paging back a little when the
    /// timeline does not hold it yet; `None` when the chat is read.
    fn first_unread(&self, room: &RoomId) -> impl Future<Output = Result<Option<MessageId>, BackendError>> + Send;

    /// The room's text messages, newest first, back to `since`, the room's start, or `max_pages`
    /// pages from the server: what the search index reads.
    fn text_history(
        &self,
        room: &RoomId,
        since: SystemTime,
        max_pages: u32,
    ) -> impl Future<Output = Result<TextHistory, BackendError>> + Send;

    /// Who else is typing in the room.
    ///
    /// # Errors
    /// When the room is not the account's.
    fn typing(&self, room: &RoomId) -> Result<TypingStream, BackendError>;
}

/// Sending to a chat. Messages go through the room's send queue: the chat shows each at once,
/// `Sending`, then `Sent` or `Failed`.
pub trait ChatSending: Send + Sync {
    /// Sends `text` (Markdown), answering `reply` if given.
    fn send_text(
        &self,
        room: &RoomId,
        text: &str,
        reply: Option<&MessageRef>,
    ) -> impl Future<Output = Result<(), BackendError>> + Send;

    /// Replaces the text of the account's own message.
    fn edit(
        &self,
        room: &RoomId,
        message: &MessageId,
        text: &str,
    ) -> impl Future<Output = Result<(), BackendError>> + Send;

    /// Deletes a message for everyone.
    fn delete(&self, room: &RoomId, message: &MessageId) -> impl Future<Output = Result<(), BackendError>> + Send;

    /// Sends a failed message again.
    fn retry(&self, room: &RoomId, message: &MessageId) -> impl Future<Output = Result<(), BackendError>> + Send;

    /// Drops a message that has not gone.
    fn discard(&self, room: &RoomId, message: &MessageId) -> impl Future<Output = Result<(), BackendError>> + Send;

    /// Adds the account's reaction `key` to a message, or takes it away.
    fn toggle_reaction(
        &self,
        room: &RoomId,
        message: &MessageId,
        key: &str,
    ) -> impl Future<Output = Result<(), BackendError>> + Send;

    /// Puts a photo, video or file in the room's send queue; the chat shows it at once,
    /// uploading. Its message's id, `None` if it did not show in time.
    fn send_attachment(
        &self,
        room: &RoomId,
        attachment: &OutgoingAttachment,
        caption: Option<&str>,
        reply: Option<&MessageRef>,
    ) -> impl Future<Output = Result<Option<MessageId>, BackendError>> + Send;

    /// Where a message being sent is; `None` when the timeline no longer has it.
    fn send_state(
        &self,
        room: &RoomId,
        message: &MessageId,
    ) -> impl Future<Output = Result<Option<SendState>, BackendError>> + Send;

    /// Sends a copy of a message (its media too, without uploading it again) to `target`.
    fn forward(
        &self,
        room: &RoomId,
        message: &MessageId,
        target: &RoomId,
    ) -> impl Future<Output = Result<(), BackendError>> + Send;

    /// The draft kept for the room.
    fn draft(&self, room: &RoomId) -> impl Future<Output = Result<Option<Draft>, BackendError>> + Send;

    /// Keeps the composer's `text` for the room, and the message it answers; an empty draft is
    /// forgotten.
    fn save_draft(
        &self,
        room: &RoomId,
        text: &str,
        reply: Option<&MessageRef>,
    ) -> impl Future<Output = Result<(), BackendError>> + Send;

    /// Marks the room read up to its newest message; `receipt` says who sees it.
    fn mark_read(&self, room: &RoomId, receipt: Receipt) -> impl Future<Output = Result<(), BackendError>> + Send;

    /// Tells the room whether the account is typing.
    fn set_typing(&self, room: &RoomId, typing: bool) -> impl Future<Output = Result<(), BackendError>> + Send;
}

/// Media as files on the device, loaded once into the folder the app gives (encrypted media
/// decrypted).
pub trait ChatMedia: Send + Sync {
    /// The file of a picture; `None` when there is none.
    fn image_file(
        &self,
        source: &ImageSource,
        folder: &Path,
    ) -> impl Future<Output = Result<Option<PathBuf>, BackendError>> + Send;

    /// A photo's, a video's or a file's original.
    fn media_file(
        &self,
        room: &RoomId,
        message: &MessageId,
        folder: &Path,
    ) -> impl Future<Output = Result<PathBuf, BackendError>> + Send;

    /// The largest file the server takes, in bytes.
    fn max_upload_size(&self) -> impl Future<Output = Result<u64, BackendError>> + Send;
}
