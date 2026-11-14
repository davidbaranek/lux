//! A chat as the list shows it, and what the list gathers besides chats.

use std::collections::HashSet;
use std::sync::Arc;
use std::time::SystemTime;

use crate::ids::{ChatId, EventId, LabelId, MediaId, RoomId, ScheduledId};
use crate::network::Network;
use crate::preview::Preview;

/// Which of the list's folders a chat is in.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub enum Folder {
    /// The chats the user deals with.
    #[default]
    Inbox,
    /// Shown below the inbox's chats, in their own place.
    LowPriority,
    /// Out of the inbox until a new message brings them back.
    Archive,
}

/// One network's room of a merged chat.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct ChatRoom {
    /// The room.
    pub id: RoomId,
    /// Its network.
    pub network: Network,
}

/// One row of the chat list: what the row shows, so equal chats render the same.
#[derive(Clone, Debug, PartialEq)]
pub struct Chat {
    /// Its id: a room's, or a merged chat's.
    pub id: ChatId,
    /// Its name.
    pub name: String,
    /// The newest message in one line, with its sender in a group; `None` for a chat with none.
    pub preview: Option<Preview>,
    /// When the newest message came; `None` for a chat with none.
    pub date: Option<SystemTime>,
    /// Unread messages, not counting mentions apart.
    pub unread_count: u32,
    /// The user marked it unread by hand.
    pub is_marked_unread: bool,
    /// Its notifications are off.
    pub is_muted: bool,
    /// Its network; a merged chat's is that of its newest message.
    pub network: Network,
    /// Its picture.
    pub avatar: Option<MediaId>,
    /// A group with no picture: two members' pictures, drawn as one.
    pub member_avatars: Vec<MediaId>,
    /// When to answer it, if the user asked to be reminded and has not answered since.
    pub reminder: Option<SystemTime>,
    /// More than two people: messages show their sender's name.
    pub is_group: bool,
    /// The folder it is in.
    pub folder: Folder,
    /// Pinned on top of the inbox, at this place among the pinned (lower first).
    pub pinned: Option<f64>,
    /// A merged chat's rooms, in the user's order; empty for any other chat.
    pub rooms: Vec<ChatRoom>,
    /// The room a merged chat writes to when the conversation gives no other.
    pub default_room: Option<RoomId>,
}

impl Chat {
    /// Unread messages, or marked unread.
    #[must_use]
    pub fn is_unread(&self) -> bool {
        self.unread_count > 0 || self.is_marked_unread
    }

    /// One person's chats on several networks, shown as one.
    #[must_use]
    pub fn is_merged(&self) -> bool {
        !self.rooms.is_empty()
    }
}

/// An invitation the user has not answered.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Request {
    /// The room it invites to.
    pub id: RoomId,
    /// The room's or the inviter's name.
    pub name: String,
    /// Its picture.
    pub avatar: Option<MediaId>,
    /// Who invited; empty when the invite does not say.
    pub inviter_name: String,
    /// A conversation of two, not a group.
    pub is_direct: bool,
}

/// One of the user's labels, and the chats in it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Label {
    /// Its id.
    pub id: LabelId,
    /// Its name.
    pub name: String,
    /// The chats in it.
    pub chats: HashSet<ChatId>,
}

/// A Matrix space the user is in.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Space {
    /// Its room.
    pub id: RoomId,
    /// Its name.
    pub name: String,
    /// Its picture.
    pub avatar: Option<MediaId>,
    /// Its chats, those of the spaces inside it too.
    pub chats: HashSet<ChatId>,
    /// The spaces it is inside of (none for a top-level one).
    pub parents: Vec<RoomId>,
}

/// What a saved message is, as its row shows it.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub enum SavedKind {
    /// Text.
    Text,
    /// A photo, by its caption.
    Image,
    /// A video, by its caption.
    Video,
    /// A voice message.
    Voice,
    /// A sound file.
    Audio,
    /// A file, by its name.
    File,
    /// A sticker.
    Sticker,
    /// Anything else.
    #[default]
    Other,
}

/// A message the user saved, to find again across chats, with what its row shows as it was
/// when saved.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SavedMessage {
    /// The message.
    pub event: EventId,
    /// The room it is in.
    pub room: RoomId,
    /// Its sender's name when it was saved (their id when it had none).
    pub sender_name: String,
    /// The account wrote it.
    pub is_own: bool,
    /// Its text or caption (empty for none).
    pub body: String,
    /// What it is.
    pub kind: SavedKind,
    /// A file's name; empty for others.
    pub file_name: String,
    /// When it was sent.
    pub date: SystemTime,
    /// When it was saved.
    pub saved_at: SystemTime,
}

/// A message waiting on the server to go at a later time.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ScheduledMessage {
    /// The server's id for the waiting message.
    pub id: ScheduledId,
    /// The room it goes to.
    pub room: RoomId,
    /// Its text.
    pub body: String,
    /// When it goes.
    pub send_at: SystemTime,
}

/// What the chat list shows, read together: the chats and everything gathered besides them.
/// The rows are shared (`Arc`), so a list made from them copies none.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Snapshot {
    /// The chats, in the server's order.
    pub chats: Vec<Arc<Chat>>,
    /// The spaces the user is in.
    pub spaces: Vec<Space>,
    /// The invitations not answered.
    pub requests: Vec<Arc<Request>>,
    /// The user's labels.
    pub labels: Vec<Label>,
    /// The saved messages, the last saved first.
    pub saved: Vec<Arc<SavedMessage>>,
    /// The messages waiting to go, the soonest first.
    pub scheduled: Vec<Arc<ScheduledMessage>>,
}
