//! What a chat's menu does to it (the chat list's intents, `list.rs`).

use lux_core::ports::ChatChange;

/// What a chat's menu does to it.
#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum CoreChatChange {
    /// Read.
    Read,
    /// Marked unread.
    Unread,
    /// Muted.
    Mute,
    /// Unmuted.
    Unmute,
    /// Into Low Priority.
    LowPriority,
    /// Back to the inbox.
    Inbox,
    /// Archived.
    Archive,
    /// Out of the archive.
    Unarchive,
    /// Deleted from the app.
    Delete,
    /// Pinned.
    Pin,
    /// Unpinned.
    Unpin,
}

impl From<CoreChatChange> for ChatChange {
    fn from(change: CoreChatChange) -> Self {
        match change {
            CoreChatChange::Read => Self::Read,
            CoreChatChange::Unread => Self::Unread,
            CoreChatChange::Mute => Self::Mute,
            CoreChatChange::Unmute => Self::Unmute,
            CoreChatChange::LowPriority => Self::LowPriority,
            CoreChatChange::Inbox => Self::Inbox,
            CoreChatChange::Archive => Self::Archive,
            CoreChatChange::Unarchive => Self::Unarchive,
            CoreChatChange::Delete => Self::Delete,
            CoreChatChange::Pin => Self::Pin,
            CoreChatChange::Unpin => Self::Unpin,
        }
    }
}
