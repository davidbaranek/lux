//! What a thread's view model needs of the account: its rooms' timelines and sending, and the
//! saving and sending later a message's menu and the composer do.

use super::{ChatSending, ChatTimelines, SavedMessages, Scheduling};

/// The account a thread runs on, as [`ThreadViewModel`](crate::thread::ThreadViewModel) uses it.
pub trait ThreadBackend: SavedMessages + Scheduling + Send + Sync + 'static {
    /// The chats' timelines and their sending.
    type Timelines: ChatTimelines + ChatSending + 'static;

    /// The account's timelines.
    fn timelines(&self) -> &Self::Timelines;
}
