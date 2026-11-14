//! The chat list's shared types, as the apps see them.

use lux_core::chat::{Folder, Label, SavedKind, SavedMessage, ScheduledMessage};
use lux_core::preview::{Author, Membership, Preview, PreviewKind};
use std::time::SystemTime;

/// A position in a list the apps gave, as the bindings carry it.
pub(crate) fn position(index: usize) -> u32 {
    u32::try_from(index).unwrap_or(u32::MAX)
}

/// A file's path as the bindings carry it.
pub(crate) fn path_text(path: &std::path::Path) -> String {
    path.to_string_lossy().into_owned()
}

/// Which of the list's folders a chat is in.
#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum CoreFolder {
    /// The chats the user deals with.
    Inbox,
    /// Below the inbox's chats.
    LowPriority,
    /// Out of the inbox until a new message.
    Archive,
}

impl From<CoreFolder> for Folder {
    fn from(folder: CoreFolder) -> Self {
        match folder {
            CoreFolder::Inbox => Self::Inbox,
            CoreFolder::LowPriority => Self::LowPriority,
            CoreFolder::Archive => Self::Archive,
        }
    }
}

impl From<Folder> for CoreFolder {
    fn from(folder: Folder) -> Self {
        match folder {
            Folder::Inbox => Self::Inbox,
            Folder::LowPriority => Self::LowPriority,
            Folder::Archive => Self::Archive,
        }
    }
}

/// What a chat's newest message is, or a quoted one.
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum CorePreviewKind {
    /// Text, on one line.
    Text {
        /// The text.
        text: String,
    },
    /// A photo.
    Image,
    /// A video.
    Video,
    /// A sound file.
    Audio,
    /// A voice message.
    Voice,
    /// A file.
    File {
        /// Its name, if it has one.
        name: Option<String>,
    },
    /// A shared location.
    Location,
    /// A sticker.
    Sticker,
    /// A poll.
    Poll {
        /// Its question.
        question: String,
    },
    /// Not readable on this device yet.
    Encrypted,
    /// Deleted.
    Deleted,
    /// A reaction to a message.
    Reaction {
        /// Its key (an emoji).
        key: String,
    },
    /// A call.
    Call,
    /// Someone joined, was invited, or asks to join.
    Membership {
        /// Which.
        membership: CoreMembership,
    },
    /// Anything else.
    Other,
}

/// A change to who is in a chat.
#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum CoreMembership {
    /// Joined.
    Joined,
    /// Was invited.
    Invited,
    /// Asks to join.
    Knocked,
}

impl From<Membership> for CoreMembership {
    fn from(membership: Membership) -> Self {
        match membership {
            Membership::Joined => Self::Joined,
            Membership::Invited => Self::Invited,
            Membership::Knocked => Self::Knocked,
        }
    }
}

/// Whom a preview names before the message.
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum CoreAuthor {
    /// The account itself.
    Own,
    /// Someone else.
    Named {
        /// Their name.
        name: String,
    },
}

/// A chat's newest message in one line, for the app to word.
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct CorePreview {
    /// Whom the line names; none in a direct chat.
    pub author: Option<CoreAuthor>,
    /// What the message is.
    pub kind: CorePreviewKind,
}

impl From<Preview> for CorePreview {
    fn from(preview: Preview) -> Self {
        Self {
            author: preview.author.map(|author| match author {
                Author::Own => CoreAuthor::Own,
                Author::Named(name) => CoreAuthor::Named { name },
            }),
            kind: preview.kind.into(),
        }
    }
}

impl From<PreviewKind> for CorePreviewKind {
    fn from(kind: PreviewKind) -> Self {
        match kind {
            PreviewKind::Text(text) => Self::Text { text },
            PreviewKind::Image => Self::Image,
            PreviewKind::Video => Self::Video,
            PreviewKind::Audio => Self::Audio,
            PreviewKind::Voice => Self::Voice,
            PreviewKind::File(name) => Self::File { name },
            PreviewKind::Location => Self::Location,
            PreviewKind::Sticker => Self::Sticker,
            PreviewKind::Poll(question) => Self::Poll { question },
            PreviewKind::Encrypted => Self::Encrypted,
            PreviewKind::Deleted => Self::Deleted,
            PreviewKind::Reaction(key) => Self::Reaction { key },
            PreviewKind::Call => Self::Call,
            PreviewKind::Membership(membership) => Self::Membership {
                membership: membership.into(),
            },
            PreviewKind::Other => Self::Other,
        }
    }
}

/// A label and its chats.
#[derive(uniffi::Record)]
pub struct CoreLabel {
    /// Its id.
    pub id: String,
    /// Its name.
    pub name: String,
    /// Its chats.
    pub chats: Vec<String>,
}

/// What a saved message is.
#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum CoreSavedKind {
    /// Text.
    Text,
    /// A photo.
    Image,
    /// A video.
    Video,
    /// A voice message.
    Voice,
    /// A sound file.
    Audio,
    /// A file.
    File,
    /// A sticker.
    Sticker,
    /// Anything else.
    Other,
}

impl From<SavedKind> for CoreSavedKind {
    fn from(kind: SavedKind) -> Self {
        match kind {
            SavedKind::Text => Self::Text,
            SavedKind::Image => Self::Image,
            SavedKind::Video => Self::Video,
            SavedKind::Voice => Self::Voice,
            SavedKind::Audio => Self::Audio,
            SavedKind::File => Self::File,
            SavedKind::Sticker => Self::Sticker,
            SavedKind::Other => Self::Other,
        }
    }
}

/// A saved message, with what its row shows.
#[derive(uniffi::Record)]
pub struct CoreSavedMessage {
    /// Its event.
    pub event: String,
    /// Its room.
    pub room: String,
    /// Its sender's name when saved.
    pub sender_name: String,
    /// The account wrote it.
    pub is_own: bool,
    /// Its text or caption.
    pub body: String,
    /// What it is.
    pub kind: CoreSavedKind,
    /// A file's name.
    pub file_name: String,
    /// When it was sent.
    pub date: SystemTime,
    /// When it was saved.
    pub saved_at: SystemTime,
}

impl From<SavedMessage> for CoreSavedMessage {
    fn from(saved: SavedMessage) -> Self {
        Self {
            event: saved.event.to_string(),
            room: saved.room.to_string(),
            sender_name: saved.sender_name,
            is_own: saved.is_own,
            body: saved.body,
            kind: saved.kind.into(),
            file_name: saved.file_name,
            date: saved.date,
            saved_at: saved.saved_at,
        }
    }
}

/// A message waiting to go.
#[derive(uniffi::Record)]
pub struct CoreScheduledMessage {
    /// The server's id for it.
    pub id: String,
    /// Its room.
    pub room: String,
    /// Its text.
    pub body: String,
    /// When it goes.
    pub send_at: SystemTime,
}

impl From<ScheduledMessage> for CoreScheduledMessage {
    fn from(message: ScheduledMessage) -> Self {
        Self {
            id: message.id.to_string(),
            room: message.room.to_string(),
            body: message.body,
            send_at: message.send_at,
        }
    }
}

impl From<Label> for CoreLabel {
    fn from(label: Label) -> Self {
        Self {
            id: label.id.to_string(),
            name: label.name,
            chats: label.chats.iter().map(ToString::to_string).collect(),
        }
    }
}
