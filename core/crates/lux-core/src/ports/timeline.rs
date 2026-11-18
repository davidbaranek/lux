//! A chat's messages: reading its timeline, sending to it, and loading its media.
//!
//! The backend keeps one live timeline per room or Matrix thread opened ([`TimelineId`]), from
//! the first call that names it: those the apps hold (a chat or a thread on screen), and a few
//! used last; the others close. A room's own timeline does not show its threads' replies: their
//! roots carry a [`ThreadSummary`](crate::timeline::ThreadSummary) instead.
//!
//! What is done to a message names its room alone: its id is unique among all timelines, and
//! the backend finds the open timeline that shows it.

use std::future::Future;
use std::path::{Path, PathBuf};
use std::pin::Pin;
use std::sync::Arc;
use std::time::SystemTime;

use futures_core::Stream;

use crate::ids::{ChatId, EventId, MessageId, MessageRef, RoomId, TimelineId};
use crate::message::SendState;
use crate::timeline::{
    Draft, Focused, ImageSource, IndexHistory, OutgoingAttachment, Receipt, TimelineMessage, Typist,
};

use super::{BackendError, DiffStream};

/// The rooms whose open timeline changed, one each time a batch changes it.
pub type RoomChanges = Pin<Box<dyn Stream<Item = RoomId> + Send>>;

/// One upload's states, as the room's send queue reports them: how much has gone, each time
/// more has, then sent or failed, the last. It ends there, or when the message is discarded
/// before it went.
pub type UploadStream = Pin<Box<dyn Stream<Item = SendState> + Send>>;

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

    /// Keeps the timeline open, once a call opens it, until the hold goes.
    fn hold(&self, timeline: &TimelineId) -> TimelineHold;

    /// The timeline's messages, oldest first, as they change: a `Reset` with those it has, then
    /// each batch. No two messages share an id, in this timeline or any other.
    ///
    /// A timeline opened around a message ([`TimelineId::at`]) is fetched first: its first batch
    /// holds that message and its neighbours. It shows no new messages (those come to the live
    /// one), only what changes on those it holds.
    ///
    /// # Errors
    /// [`BackendError::UnknownMessage`] when the server has no such message, and
    /// [`BackendError::NotAllowed`] when the account may not see it.
    fn messages(
        &self,
        timeline: &TimelineId,
    ) -> impl Future<Output = Result<DiffStream<Arc<TimelineMessage>>, BackendError>> + Send;

    /// Opens the timeline ahead of time (its first screen from the server if the device has
    /// none), so the chat opens at once.
    fn prefetch(&self, timeline: &TimelineId) -> impl Future<Output = Result<(), BackendError>> + Send;

    /// Returns once the opened chat's first screen is in, its server pages included.
    fn wait_until_filled(&self, timeline: &TimelineId) -> impl Future<Output = ()> + Send;

    /// Pages back on the server until the timeline holds `count` more messages than now, or the
    /// timeline's first one. Which of them show is the thread's choice ([`Window`](crate::timeline::Window)).
    fn load_older(&self, timeline: &TimelineId, count: usize) -> impl Future<Output = Result<(), BackendError>> + Send;

    /// Pages forward on the server, a timeline opened around a message (a live one is always at
    /// the newest): `true` once it holds the newest message, nothing newer to ask for.
    fn load_newer(
        &self,
        timeline: &TimelineId,
        count: usize,
    ) -> impl Future<Output = Result<bool, BackendError>> + Send;

    /// The message a timeline was opened around ([`TimelineId::at`]): its id there, and the
    /// Matrix thread the server put it in (a thread's reply shows among its thread's).
    fn focused(&self, timeline: &TimelineId) -> impl Future<Output = Result<Focused, BackendError>> + Send;

    /// The timeline holds its first message (a thread's root), its first screen in: there is
    /// nothing older on the server.
    fn is_at_start(&self, timeline: &TimelineId) -> impl Future<Output = Result<bool, BackendError>> + Send;

    /// Pages back until the timeline holds the message of `event`; its id there, `None` when it
    /// cannot be found.
    fn show_event(
        &self,
        timeline: &TimelineId,
        event: &EventId,
    ) -> impl Future<Output = Result<Option<MessageId>, BackendError>> + Send;

    /// The first message after the account's read receipt (a thread's own receipt in a thread),
    /// paging back a little when the timeline does not hold it yet; `None` when it is read.
    fn first_unread(
        &self,
        timeline: &TimelineId,
    ) -> impl Future<Output = Result<Option<MessageId>, BackendError>> + Send;

    /// The room's text messages and photos, newest first, back to `since`, the room's start, or
    /// `max_pages` pages from the server: what the search index reads. From the newest, or on
    /// from where an earlier read stopped (`from`, its [`IndexHistory::older`]).
    fn index_history(
        &self,
        room: &RoomId,
        since: SystemTime,
        from: Option<String>,
        max_pages: u32,
    ) -> impl Future<Output = Result<IndexHistory, BackendError>> + Send;

    /// Who else is typing in the room.
    ///
    /// # Errors
    /// When the room is not the account's.
    fn typing(&self, room: &RoomId) -> Result<TypingStream, BackendError>;
}

/// Sending to a chat. Messages go through the room's send queue: the chat shows each at once,
/// `Sending`, then `Sent` or `Failed`.
pub trait ChatSending: Send + Sync {
    /// Sends `text` (Markdown) to the timeline (in a thread, as its reply), answering `reply` if
    /// given.
    fn send_text(
        &self,
        timeline: &TimelineId,
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

    /// Puts a photo, video or file in the room's send queue, for the timeline (in a thread, as
    /// its reply); the chat shows it at once, uploading. Its upload's states, from the moment it
    /// was queued.
    fn send_attachment(
        &self,
        timeline: &TimelineId,
        attachment: &OutgoingAttachment,
        caption: Option<&str>,
        reply: Option<&MessageRef>,
    ) -> impl Future<Output = Result<UploadStream, BackendError>> + Send;

    /// Sends a copy of a message (its media too, without uploading it again) to the chat
    /// `target`: a merged chat's default room.
    fn forward(
        &self,
        room: &RoomId,
        message: &MessageId,
        target: &ChatId,
    ) -> impl Future<Output = Result<(), BackendError>> + Send;

    /// The draft kept for the timeline (a room's, a thread's).
    fn draft(&self, timeline: &TimelineId) -> impl Future<Output = Result<Option<Draft>, BackendError>> + Send;

    /// Keeps the composer's `text` for the timeline, and the message it answers; an empty draft
    /// is forgotten.
    fn save_draft(
        &self,
        timeline: &TimelineId,
        text: &str,
        reply: Option<&MessageRef>,
    ) -> impl Future<Output = Result<(), BackendError>> + Send;

    /// Marks the timeline read up to its newest message (a thread's receipt for a thread, the
    /// room's own for the room); `receipt` says who sees it.
    fn mark_read(
        &self,
        timeline: &TimelineId,
        receipt: Receipt,
    ) -> impl Future<Output = Result<(), BackendError>> + Send;

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

    /// The original of a shared photo, video or file, by its message's event.
    fn shared_file(
        &self,
        room: &RoomId,
        event: &EventId,
        folder: &Path,
    ) -> impl Future<Output = Result<PathBuf, BackendError>> + Send;

    /// The largest file the server takes, in bytes.
    fn max_upload_size(&self) -> impl Future<Output = Result<u64, BackendError>> + Send;
}
