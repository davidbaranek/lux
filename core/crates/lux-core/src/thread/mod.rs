//! A chat's thread as a view model: one task follows the live timelines of the chat's rooms (one,
//! or a merged chat's), presents the shown messages as rows, and sends its listener a batch of
//! row diffs and the thread's state at most once a frame. The apps forward the user's intents
//! and measure and draw the rows.
//!
//! What the task decides: which messages show (the first screen, then all since and those
//! paged back to), the merged chat's conversation and the room a new message goes to, the
//! composer's mode and what sending does, the first unread message and when a read receipt is
//! due, who is typing and when the others see the user type.

mod decide;
mod rows;
mod task;
#[cfg(test)]
mod tests;

use std::path::PathBuf;
use std::sync::Arc;
use std::time::SystemTime;

use eyeball_im::VectorDiff;
use jiff::tz::TimeZone;
use tokio::runtime::Handle;
use tokio::sync::{mpsc, oneshot};

pub use decide::{ComposerMode, ReadReceipts, ReplyTarget};
pub use rows::{RowShows, ThreadRow};

use crate::chat::ChatRoom;
use crate::ids::{ChatId, EventId, MessageId, MessageRef, RoomId};
use crate::ports::{BackendError, ThreadBackend};
use crate::timeline::Typist;

/// The chat a thread shows.
#[derive(Clone, Debug)]
pub struct ThreadSpec {
    /// Its id in the chat list (a merged chat's names no room).
    pub chat: ChatId,
    /// Its rooms: one, or a merged chat's, in the merge's order.
    pub rooms: Vec<ChatRoom>,
    /// Where a chat with no messages yet writes; it also keeps the draft.
    pub default_room: RoomId,
    /// The chat list counted unread messages in it: the server's read receipt can be out of
    /// reach of the loaded messages, so the count is the surer sign.
    pub listed_unread: bool,
    /// How the chat tells the others it was read.
    pub read_receipts: ReadReceipts,
    /// The days of the separators are this zone's.
    pub zone: TimeZone,
}

/// What the thread shows besides its rows; sent whole when any of it changes.
#[allow(clippy::struct_excessive_bools, reason = "flags the apps read one by one")]
#[derive(Clone, Debug, PartialEq)]
pub struct ThreadState {
    /// Messages come from the server (the opening fill, older ones, a jump): the app shows it.
    pub is_loading: bool,
    /// Older messages can be asked for: none are loading, and the first message does not show.
    pub can_load_older: bool,
    /// The first message of the chat shows.
    pub is_at_start: bool,
    /// The first unread message when the chat opened: "New messages" goes above it.
    pub first_unread: Option<MessageId>,
    /// Others wrote something the user's read receipt does not cover yet.
    pub needs_read_receipt: bool,
    /// Who else is typing, in the rooms shown.
    pub typists: Vec<Typist>,
    /// The one room shown alone, or `None`: all of them.
    pub shown_room: Option<RoomId>,
    /// Where a new message goes: the room shown alone, else the room of the conversation's last
    /// message, else the default.
    pub send_room: RoomId,
    /// What sending does.
    pub mode: ComposerMode,
    /// Files waiting to go with the next message.
    pub pending_files: Vec<PathBuf>,
    /// The send room can have messages sent later.
    pub can_send_later: bool,
}

/// One frame's changes: the rows' diffs (the first batch a `Reset`), and the state if it
/// changed.
#[derive(Clone, Debug, Default)]
pub struct ThreadUpdate {
    /// The rows' changes, in order.
    pub rows: Vec<VectorDiff<Arc<ThreadRow>>>,
    /// The state, when it changed.
    pub state: Option<ThreadState>,
}

/// Files to send, one message each: the platform prepares and uploads them.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Upload {
    /// The files, in order.
    pub files: Vec<PathBuf>,
    /// Where they go.
    pub room: RoomId,
    /// The first one's text.
    pub caption: Option<String>,
    /// The message the first one answers.
    pub reply: Option<MessageRef>,
}

/// Hears a thread, from the task that owns it.
pub trait ThreadListener: Send + Sync + 'static {
    /// One frame's changes.
    fn on_update(&self, update: ThreadUpdate);
    /// Files the user sent, for the platform to upload.
    fn on_upload(&self, upload: Upload);
    /// An action failed.
    fn on_error(&self, error: BackendError);
}

/// The thread of one chat, alive while this lives: dropping it ends its task and lets the rooms'
/// timelines go.
#[derive(Debug)]
pub struct ThreadViewModel {
    intents: mpsc::UnboundedSender<Intent>,
}

/// What the user does, to the task.
#[derive(Debug)]
enum Intent {
    LoadOlder,
    JumpToReplied(MessageId, oneshot::Sender<Option<MessageId>>),
    JumpToEvent(EventId, oneshot::Sender<Option<MessageId>>),
    FirstUnread(oneshot::Sender<Option<MessageId>>),
    Loaded(oneshot::Sender<()>),
    ToggleDetail(MessageId),
    TogglePost(MessageId),
    ShowRoom(Option<RoomId>),
    Reply(MessageId),
    Edit(MessageId),
    CancelMode,
    Send { text: String, via: Option<RoomId> },
    SendLater(String, SystemTime, oneshot::Sender<Result<(), BackendError>>),
    Attach(Vec<PathBuf>),
    RemovePending(PathBuf),
    Message(MessageAction),
    DidReadLatest,
    SendReadReceipt,
    SetReadReceipts(ReadReceipts),
    WatchTyping,
    StopWatchingTyping,
    ComposerChanged(String),
    Draft(DraftIntent),
}

/// A message's menu: each goes to the message's room.
#[derive(Debug)]
enum MessageAction {
    ToggleReaction(MessageId, String),
    Delete(MessageId),
    Retry(MessageId),
    Discard(MessageId),
    Forward(MessageId, RoomId),
    Save(MessageId),
    Unsave(MessageId),
}

/// The composer's kept draft.
#[derive(Debug)]
enum DraftIntent {
    Load(oneshot::Sender<String>),
    Save(String),
}

impl ThreadViewModel {
    /// Opens the thread of `spec` on `runtime`: it holds the rooms' timelines and tells
    /// `listener` its first rows once every room's messages and the first unread one are known.
    pub fn open<B: ThreadBackend>(
        runtime: &Handle,
        backend: Arc<B>,
        spec: ThreadSpec,
        listener: Arc<dyn ThreadListener>,
    ) -> Self {
        let (intents, receiver) = mpsc::unbounded_channel();
        runtime.spawn(task::run(backend, spec, listener, receiver));
        Self { intents }
    }

    fn send(&self, intent: Intent) {
        // the task ends only when this goes: a failed send cannot happen while it lives.
        let _ = self.intents.send(intent);
    }

    async fn ask<T>(&self, intent: impl FnOnce(oneshot::Sender<T>) -> Intent) -> Option<T> {
        let (answer, answered) = oneshot::channel();
        self.send(intent(answer));
        answered.await.ok()
    }

    /// Shows older messages: those the timelines hold, then the server's (the user scrolled up).
    pub fn load_older(&self) {
        self.send(Intent::LoadOlder);
    }

    /// Brings the message `message` answers into the thread; its id, for the app to scroll to.
    pub async fn jump_to_replied(&self, message: MessageId) -> Option<MessageId> {
        self.ask(|answer| Intent::JumpToReplied(message, answer))
            .await
            .flatten()
    }

    /// Brings the message of `event` into the thread (a saved message the chat opened at).
    pub async fn jump_to_event(&self, event: EventId) -> Option<MessageId> {
        self.ask(|answer| Intent::JumpToEvent(event, answer)).await.flatten()
    }

    /// The first unread message when the chat opened, once known.
    pub async fn first_unread(&self) -> Option<MessageId> {
        self.ask(Intent::FirstUnread).await.flatten()
    }

    /// Returns once the opening fill is in (the rooms' first screens, from the server too).
    pub async fn loaded(&self) {
        self.ask(Intent::Loaded).await;
    }

    /// Shows a message's full time (and its network in a merged chat), or hides them.
    pub fn toggle_detail(&self, message: MessageId) {
        self.send(Intent::ToggleDetail(message));
    }

    /// Shows a shared post's whole caption, or folds it to its first lines again.
    pub fn toggle_post(&self, message: MessageId) {
        self.send(Intent::TogglePost(message));
    }

    /// Shows one room of a merged chat alone (its messages, writing to it), or all (`None`).
    pub fn show_room(&self, room: Option<RoomId>) {
        self.send(Intent::ShowRoom(room));
    }

    /// The composer answers `message`.
    pub fn reply(&self, message: MessageId) {
        self.send(Intent::Reply(message));
    }

    /// The composer edits the user's `message`.
    pub fn edit(&self, message: MessageId) {
        self.send(Intent::Edit(message));
    }

    /// The composer writes a new message again.
    pub fn cancel_mode(&self) {
        self.send(Intent::CancelMode);
    }

    /// Sends the composer's text as the mode says (waiting files first, the text their caption);
    /// a new message goes `via` that room if given, else to the send room.
    pub fn send_text(&self, text: String, via: Option<RoomId>) {
        self.send(Intent::Send { text, via });
    }

    /// Has the server send the composer's text at `at`.
    ///
    /// # Errors
    /// When the server refuses (an encrypted chat, a time past).
    pub async fn send_later(&self, text: String, at: SystemTime) -> Result<(), BackendError> {
        self.ask(|answer| Intent::SendLater(text, at, answer))
            .await
            .unwrap_or(Ok(()))
    }

    /// Puts files in the composer; they go with the next message.
    pub fn attach(&self, files: Vec<PathBuf>) {
        self.send(Intent::Attach(files));
    }

    /// Takes a file out of the composer.
    pub fn remove_pending(&self, file: PathBuf) {
        self.send(Intent::RemovePending(file));
    }

    /// Adds the user's reaction `key` to a message, or takes it away.
    pub fn toggle_reaction(&self, message: MessageId, key: String) {
        self.send(Intent::Message(MessageAction::ToggleReaction(message, key)));
    }

    /// Deletes a message for everyone.
    pub fn delete(&self, message: MessageId) {
        self.send(Intent::Message(MessageAction::Delete(message)));
    }

    /// Sends a failed message again.
    pub fn retry(&self, message: MessageId) {
        self.send(Intent::Message(MessageAction::Retry(message)));
    }

    /// Drops a message that did not go.
    pub fn discard(&self, message: MessageId) {
        self.send(Intent::Message(MessageAction::Discard(message)));
    }

    /// Sends a copy of a message to `target`.
    pub fn forward(&self, message: MessageId, target: RoomId) {
        self.send(Intent::Message(MessageAction::Forward(message, target)));
    }

    /// Saves a message.
    pub fn save(&self, message: MessageId) {
        self.send(Intent::Message(MessageAction::Save(message)));
    }

    /// Takes a message out of the saved ones.
    pub fn unsave(&self, message: MessageId) {
        self.send(Intent::Message(MessageAction::Unsave(message)));
    }

    /// The reader is at the newest message: a receipt goes, if the chat sends them by itself.
    pub fn did_read_latest(&self) {
        self.send(Intent::DidReadLatest);
    }

    /// Tells the others the chat was read, up to its newest message.
    pub fn send_read_receipt(&self) {
        self.send(Intent::SendReadReceipt);
    }

    /// The chat's way of telling the others it was read changed.
    pub fn set_read_receipts(&self, receipts: ReadReceipts) {
        self.send(Intent::SetReadReceipts(receipts));
    }

    /// Follows who is typing (the chat is on screen).
    pub fn watch_typing(&self) {
        self.send(Intent::WatchTyping);
    }

    /// Stops following who is typing, and tells the others the user stopped.
    pub fn stop_watching_typing(&self) {
        self.send(Intent::StopWatchingTyping);
    }

    /// The composer's text changed: the others see the user typing.
    pub fn composer_changed(&self, text: String) {
        self.send(Intent::ComposerChanged(text));
    }

    /// The text the composer had when the chat was left (its reply becomes the mode).
    pub async fn load_draft(&self) -> String {
        self.ask(|answer| Intent::Draft(DraftIntent::Load(answer)))
            .await
            .unwrap_or_default()
    }

    /// Keeps the composer's text (and its reply) for the next visit; an edit is no draft.
    pub fn save_draft(&self, text: String) {
        self.send(Intent::Draft(DraftIntent::Save(text)));
    }
}
