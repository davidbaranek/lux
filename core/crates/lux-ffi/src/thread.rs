//! A chat's thread as the apps see it (`lux_core::thread`): a view model object taking the
//! user's intents, and a listener receiving each frame's batch of row diffs and the state.

use std::path::PathBuf;
use std::sync::Arc;
use std::time::SystemTime;

use eyeball_im::VectorDiff;
use lux_core::chat::ChatRoom;
use lux_core::ids::{ChatId, EventId, RoomId};
use lux_core::message::Separator;
use lux_core::network::Network;
use lux_core::ports::BackendError;
use lux_core::thread::{
    ComposerMode, ReadReceipts, ThreadListener, ThreadRow, ThreadSpec, ThreadState, ThreadUpdate, ThreadViewModel,
    Upload,
};

use crate::account::{CoreAccount, CoreAccountError, with_account};
use crate::chat::{CorePreviewKind, path_text};
use crate::message::{CoreFooter, CoreLink, CoreSeparator, zone};
use crate::runtime;
use crate::timeline::{CoreMessage, CoreTypist};

// MARK: records

/// One room of a chat.
#[derive(uniffi::Record)]
pub struct CoreThreadRoom {
    /// The room.
    pub id: String,
    /// Its network.
    pub network: String,
}

/// How a chat tells the others it was read.
#[derive(uniffi::Enum)]
pub enum CoreReadReceipts {
    /// By itself, as the user reads.
    Automatic,
    /// When the user asks.
    Manual,
}

impl From<CoreReadReceipts> for ReadReceipts {
    fn from(receipts: CoreReadReceipts) -> Self {
        match receipts {
            CoreReadReceipts::Automatic => Self::Automatic,
            CoreReadReceipts::Manual => Self::Manual,
        }
    }
}

/// The chat a thread opens on.
#[derive(uniffi::Record)]
pub struct CoreThreadOpening {
    /// Its id in the chat list.
    pub chat_id: String,
    /// Its rooms: one, or a merged chat's.
    pub rooms: Vec<CoreThreadRoom>,
    /// Where it writes with no messages yet; it keeps the draft.
    pub default_room: String,
    /// The chat list counted unread messages in it.
    pub listed_unread: bool,
    /// How it tells the others it was read.
    pub read_receipts: CoreReadReceipts,
    /// The time zone of its days (an IANA name; the system's if unknown).
    pub time_zone: String,
    /// The Matrix thread it shows, by its root's event id (in the chat's one room); none: the
    /// chat's own timeline.
    pub thread_root: Option<String>,
}

impl From<CoreThreadOpening> for ThreadSpec {
    fn from(opening: CoreThreadOpening) -> Self {
        Self {
            chat: opening.chat_id.into(),
            rooms: opening
                .rooms
                .into_iter()
                .map(|room| ChatRoom {
                    id: room.id.into(),
                    network: Network::from_id(&room.network),
                })
                .collect(),
            default_room: opening.default_room.into(),
            listed_unread: opening.listed_unread,
            read_receipts: opening.read_receipts.into(),
            zone: zone(&opening.time_zone),
            thread: opening.thread_root.map(EventId::from),
        }
    }
}

/// One row of the thread (`lux_core::thread::ThreadRow`).
#[derive(uniffi::Record)]
pub struct CoreThreadRow {
    /// The message it shows (an album's first).
    pub message: CoreMessage,
    /// An album's other messages, after this one; empty for anything else.
    pub album_rest: Vec<CoreMessage>,
    /// Its room.
    pub room_id: String,
    /// Its room's network, in a merged chat.
    pub network: Option<String>,
    /// Starts a run of one sender.
    pub starts_run: bool,
    /// Ends the run.
    pub ends_run: bool,
    /// What shows above it.
    pub separator: Option<CoreSeparator>,
    /// Its links.
    pub links: Vec<CoreLink>,
    /// What shows under it.
    pub footer: Option<CoreFooter>,
    /// What the user unfolded of it.
    pub shows: CoreRowShows,
}

/// What a row shows besides itself.
#[derive(uniffi::Record)]
pub struct CoreRowShows {
    /// Its full time (and network).
    pub detail: bool,
    /// Its shared post's whole caption.
    pub whole_post: bool,
}

impl From<&ThreadRow> for CoreThreadRow {
    fn from(row: &ThreadRow) -> Self {
        Self {
            message: CoreMessage::from(row.message.as_ref()),
            album_rest: row
                .album
                .iter()
                .skip(1)
                .map(|message| CoreMessage::from(message.as_ref()))
                .collect(),
            room_id: row.room.to_string(),
            network: row.network.as_ref().map(|network| network.as_str().to_owned()),
            starts_run: row.starts_run,
            ends_run: row.ends_run,
            separator: row.separator.map(|separator| match separator {
                Separator::Day => CoreSeparator::Day,
                Separator::Pause => CoreSeparator::Pause,
            }),
            links: row.links.iter().cloned().map(CoreLink::from).collect(),
            footer: row.footer.map(CoreFooter::from),
            shows: CoreRowShows {
                detail: row.shows.detail,
                whole_post: row.shows.whole_post,
            },
        }
    }
}

crate::account::list_diff!(
    /// A change to the thread's rows.
    CoreThreadRowDiff of CoreThreadRow from Arc<ThreadRow>, |row: &Arc<ThreadRow>| CoreThreadRow::from(row.as_ref())
);

/// The message a reply answers, for the reply bar.
#[derive(uniffi::Record)]
pub struct CoreReplyTarget {
    /// The message (or its event id).
    pub message_id: String,
    /// Its sender's name.
    pub sender_name: String,
    /// The user sent it.
    pub is_own: bool,
    /// What it is; none until known.
    pub kind: Option<CorePreviewKind>,
}

/// What sending does.
#[derive(uniffi::Enum)]
pub enum CoreComposerMode {
    /// A new message.
    Message,
    /// An answer.
    Reply {
        /// To this.
        target: CoreReplyTarget,
    },
    /// A new text for the user's message.
    Edit {
        /// The message.
        message_id: String,
        /// Its text now.
        original: String,
    },
}

impl From<ComposerMode> for CoreComposerMode {
    fn from(mode: ComposerMode) -> Self {
        match mode {
            ComposerMode::Message => Self::Message,
            ComposerMode::Reply(target) => Self::Reply {
                target: CoreReplyTarget {
                    message_id: target.message.to_string(),
                    sender_name: target.sender_name,
                    is_own: target.is_own,
                    kind: target.kind.map(CorePreviewKind::from),
                },
            },
            ComposerMode::Edit { message, original } => Self::Edit {
                message_id: message.to_string(),
                original,
            },
        }
    }
}

/// What the thread shows besides its rows (`lux_core::thread::ThreadState`).
#[allow(clippy::struct_excessive_bools, reason = "flags the apps read one by one")]
#[derive(uniffi::Record)]
pub struct CoreThreadState {
    /// Messages come from the server.
    pub is_loading: bool,
    /// Older messages can be asked for.
    pub can_load_older: bool,
    /// The chat's first message shows.
    pub is_at_start: bool,
    /// The first unread message when the chat opened.
    pub first_unread: Option<String>,
    /// A read receipt is due.
    pub needs_read_receipt: bool,
    /// Who else is typing.
    pub typists: Vec<CoreTypist>,
    /// The room shown alone.
    pub shown_room: Option<String>,
    /// Where a new message goes.
    pub send_room: String,
    /// What sending does.
    pub mode: CoreComposerMode,
    /// Files waiting in the composer (paths).
    pub pending_files: Vec<String>,
    /// The send room can have messages sent later.
    pub can_send_later: bool,
}

impl From<ThreadState> for CoreThreadState {
    fn from(state: ThreadState) -> Self {
        Self {
            is_loading: state.is_loading,
            can_load_older: state.can_load_older,
            is_at_start: state.is_at_start,
            first_unread: state.first_unread.map(|id| id.to_string()),
            needs_read_receipt: state.needs_read_receipt,
            typists: state.typists.into_iter().map(CoreTypist::from).collect(),
            shown_room: state.shown_room.map(|room| room.to_string()),
            send_room: state.send_room.to_string(),
            mode: state.mode.into(),
            pending_files: state.pending_files.iter().map(|file| path_text(file)).collect(),
            can_send_later: state.can_send_later,
        }
    }
}

/// One frame's changes.
#[derive(uniffi::Record)]
pub struct CoreThreadUpdate {
    /// The rows' changes, in order.
    pub rows: Vec<CoreThreadRowDiff>,
    /// The state, when it changed.
    pub state: Option<CoreThreadState>,
}

/// Files to send, one message each.
#[derive(uniffi::Record)]
pub struct CoreUpload {
    /// Their paths, in order.
    pub files: Vec<String>,
    /// Where they go.
    pub room_id: String,
    /// The first one's text.
    pub caption: Option<String>,
    /// The message the first one answers.
    pub reply_to: Option<String>,
    /// The Matrix thread they go to, by its root's event id.
    pub thread_root: Option<String>,
}

// MARK: the listener

/// Hears a thread, from the core's task: one call a frame at most.
#[uniffi::export(with_foreign)]
pub trait CoreThreadListener: Send + Sync {
    /// One frame's changes.
    fn on_update(&self, update: CoreThreadUpdate);
    /// Files the user sent, to prepare and upload.
    fn on_upload(&self, upload: CoreUpload);
    /// An action failed.
    fn on_error(&self, error: CoreAccountError);
}

/// The app's listener as the core's.
pub(crate) struct Listener(pub(crate) Arc<dyn CoreThreadListener>);

impl ThreadListener for Listener {
    fn on_update(&self, update: ThreadUpdate) {
        self.0.on_update(CoreThreadUpdate {
            rows: update.rows.into_iter().map(CoreThreadRowDiff::from).collect(),
            state: update.state.map(CoreThreadState::from),
        });
    }

    fn on_upload(&self, upload: Upload) {
        self.0.on_upload(CoreUpload {
            files: upload.files.iter().map(|file| path_text(file)).collect(),
            room_id: upload.room.to_string(),
            caption: upload.caption,
            reply_to: upload.reply.map(|id| id.to_string()),
            thread_root: upload.thread.map(|root| root.to_string()),
        });
    }

    fn on_error(&self, error: BackendError) {
        self.0.on_error(error.into());
    }
}

// MARK: the view model

/// A chat's thread, alive while the app holds it.
#[derive(uniffi::Object)]
pub struct CoreThread {
    model: ThreadViewModel,
}

impl CoreThread {
    pub(crate) fn new(model: ThreadViewModel) -> Arc<Self> {
        Arc::new(Self { model })
    }
}

#[uniffi::export(async_runtime = "tokio")]
impl CoreThread {
    /// Shows older messages.
    pub fn load_older(&self) {
        self.model.load_older();
    }

    /// Brings the message `message_id` answers into the thread; its id.
    pub async fn jump_to_replied(&self, message_id: String) -> Option<String> {
        self.model
            .jump_to_replied(message_id.into())
            .await
            .map(|id| id.to_string())
    }

    /// Brings the message of `event_id` into the thread; its id there.
    pub async fn jump_to_event(&self, event_id: String) -> Option<String> {
        self.model
            .jump_to_event(EventId::from(event_id))
            .await
            .map(|id| id.to_string())
    }

    /// The first unread message when the chat opened.
    pub async fn first_unread(&self) -> Option<String> {
        self.model.first_unread().await.map(|id| id.to_string())
    }

    /// Returns once the opening fill is in.
    pub async fn loaded(&self) {
        self.model.loaded().await;
    }

    /// Shows or hides a message's details.
    pub fn toggle_detail(&self, message_id: String) {
        self.model.toggle_detail(message_id.into());
    }

    /// Shows a shared post's whole caption, or folds it.
    pub fn toggle_post(&self, message_id: String) {
        self.model.toggle_post(message_id.into());
    }

    /// Shows one room of a merged chat alone, or all.
    pub fn show_room(&self, room_id: Option<String>) {
        self.model.show_room(room_id.map(RoomId::from));
    }

    /// The composer answers a message.
    pub fn reply(&self, message_id: String) {
        self.model.reply(message_id.into());
    }

    /// The composer edits the user's message.
    pub fn edit(&self, message_id: String) {
        self.model.edit(message_id.into());
    }

    /// The composer writes a new message.
    pub fn cancel_mode(&self) {
        self.model.cancel_mode();
    }

    /// Sends the composer's text, `via` a room of a merged chat if given.
    pub fn send(&self, text: String, via_room_id: Option<String>) {
        self.model.send_text(text, via_room_id.map(RoomId::from));
    }

    /// Has the server send the composer's text at `at`.
    ///
    /// # Errors
    /// When the server refuses.
    pub async fn send_later(&self, text: String, at: SystemTime) -> Result<(), CoreAccountError> {
        Ok(self.model.send_later(text, at).await?)
    }

    /// Puts files in the composer.
    pub fn attach(&self, files: Vec<String>) {
        self.model.attach(files.into_iter().map(PathBuf::from).collect());
    }

    /// Takes a file out of the composer.
    pub fn remove_pending(&self, file: String) {
        self.model.remove_pending(PathBuf::from(file));
    }

    /// Adds or takes away the user's reaction.
    pub fn toggle_reaction(&self, message_id: String, key: String) {
        self.model.toggle_reaction(message_id.into(), key);
    }

    /// Deletes a message for everyone.
    pub fn delete(&self, message_id: String) {
        self.model.delete(message_id.into());
    }

    /// Sends a failed message again.
    pub fn retry(&self, message_id: String) {
        self.model.retry(message_id.into());
    }

    /// Drops a message that did not go.
    pub fn discard(&self, message_id: String) {
        self.model.discard(message_id.into());
    }

    /// Sends a copy of a message to another chat (a room's, or a merged chat's).
    pub fn forward(&self, message_id: String, target_chat_id: String) {
        self.model.forward(message_id.into(), ChatId::from(target_chat_id));
    }

    /// Saves a message.
    pub fn save(&self, message_id: String) {
        self.model.save(message_id.into());
    }

    /// Takes a message out of the saved ones.
    pub fn unsave(&self, message_id: String) {
        self.model.unsave(message_id.into());
    }

    /// The reader is at the newest message.
    pub fn did_read_latest(&self) {
        self.model.did_read_latest();
    }

    /// Tells the others the chat was read.
    pub fn send_read_receipt(&self) {
        self.model.send_read_receipt();
    }

    /// The chat's read receipts changed.
    pub fn set_read_receipts(&self, receipts: CoreReadReceipts) {
        self.model.set_read_receipts(receipts.into());
    }

    /// Follows who is typing.
    pub fn watch_typing(&self) {
        self.model.watch_typing();
    }

    /// Stops following who is typing.
    pub fn stop_watching_typing(&self) {
        self.model.stop_watching_typing();
    }

    /// The composer's text changed.
    pub fn composer_changed(&self, text: String) {
        self.model.composer_changed(text);
    }

    /// The text the composer had.
    pub async fn load_draft(&self) -> String {
        self.model.load_draft().await
    }

    /// Keeps the composer's text for the next visit.
    pub fn save_draft(&self, text: String) {
        self.model.save_draft(text);
    }
}

#[uniffi::export]
impl CoreAccount {
    /// Opens the thread of a chat: `listener` hears its rows and state.
    pub fn open_thread(&self, opening: CoreThreadOpening, listener: Arc<dyn CoreThreadListener>) -> Arc<CoreThread> {
        let listener = Arc::new(Listener(listener));
        CoreThread::new(with_account!(self.backend(), account => {
            ThreadViewModel::open(&runtime::handle(), Arc::clone(account), opening.into(), listener)
        }))
    }
}
