//! What a chat's details screen reads and changes: each room's name, topic, picture, encryption
//! and notifications, its members, what was shared in it, and leaving it.

use std::future::Future;
use std::time::{Duration, SystemTime};

use crate::ids::{ChatId, EventId, MediaId, RoomId, UserId};
use crate::timeline::Picture as SharedPicture;

use super::{BackendError, Picture};

/// When a room's messages notify the user.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub enum NotificationMode {
    /// As the account's settings say for a chat of its kind.
    #[default]
    Default,
    /// Every message.
    All,
    /// Only mentions of the account and its keywords.
    Mentions,
    /// Nothing (a mention still shows in the list).
    Off,
}

/// A room as its details show it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RoomDetails {
    /// The room.
    pub id: RoomId,
    /// Its name.
    pub name: String,
    /// What it is about; `None` when it says nothing.
    pub topic: Option<String>,
    /// Its picture.
    pub avatar: Option<MediaId>,
    /// Its address (`#room:server`), when it has one.
    pub address: Option<String>,
    /// Its messages are end-to-end encrypted.
    pub is_encrypted: bool,
    /// A conversation of two, not a group.
    pub is_direct: bool,
    /// How many have joined it.
    pub joined_members: u64,
    /// When its messages notify.
    pub notifications: NotificationMode,
    /// What the account may change of it.
    pub may: RoomPermissions,
}

/// What the account may change of a room, by its power level there.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct RoomPermissions {
    /// Its name.
    pub rename: bool,
    /// Its topic.
    pub change_topic: bool,
    /// Its picture.
    pub change_avatar: bool,
}

/// What a member may do in a room, by their power level.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum Role {
    /// Made the room: can never be demoted.
    Creator,
    /// Can change everything.
    Admin,
    /// Can remove others' messages and people.
    Moderator,
    /// Takes part.
    #[default]
    Member,
}

/// Someone who joined a room.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Member {
    /// Their account.
    pub user: UserId,
    /// Their name in the room, else their id's local part.
    pub name: String,
    /// Their picture.
    pub avatar: Option<MediaId>,
    /// What they may do.
    pub role: Role,
    /// The account itself.
    pub is_own: bool,
}

/// What a shared item is.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SharedContent {
    /// A photo, by its thumbnail.
    Photo {
        /// What shows.
        picture: SharedPicture,
        /// The words sent with it; empty when none.
        caption: String,
    },
    /// A video, by its poster.
    Video {
        /// Its poster, when the sender sent one.
        poster: Option<SharedPicture>,
        /// Its length, when the sender said.
        duration: Option<Duration>,
        /// The words sent with it; empty when none.
        caption: String,
    },
    /// A file or a sound.
    File {
        /// Its name.
        name: String,
        /// Its size in bytes, when the sender said.
        size: Option<u64>,
        /// Its type; empty when the sender did not say.
        mimetype: String,
    },
    /// A web address in a message's text.
    Link {
        /// Where it leads.
        url: String,
        /// The message's text around it.
        text: String,
    },
}

/// Which kind of shared item a list holds.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum SharedKind {
    /// Photos and videos.
    Media,
    /// Files and sounds.
    Files,
    /// Web addresses.
    Links,
}

impl SharedContent {
    /// The list it belongs to.
    #[must_use]
    pub fn kind(&self) -> SharedKind {
        match self {
            Self::Photo { .. } | Self::Video { .. } => SharedKind::Media,
            Self::File { .. } => SharedKind::Files,
            Self::Link { .. } => SharedKind::Links,
        }
    }
}

/// Something shared in a room: a photo, a video, a file or a link.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SharedItem {
    /// The message's event.
    pub event: EventId,
    /// Its room.
    pub room: RoomId,
    /// Who shared it.
    pub sender_name: String,
    /// When.
    pub date: SystemTime,
    /// What it is.
    pub content: SharedContent,
}

/// One page of a room's history, read back from the server for what was shared.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct SharedPage {
    /// What the page shared, newest first (a message with several links gives one each).
    pub items: Vec<SharedItem>,
    /// Where the next older page starts; `None` at the room's first message.
    pub next: Option<String>,
}

/// A chat's details, and what its details screen changes.
pub trait ChatDetails: Send + Sync {
    /// The room's details, as this device knows them.
    fn room_details(&self, room: &RoomId) -> impl Future<Output = Result<RoomDetails, BackendError>> + Send;

    /// The room's joined members, loaded from the server once if this device does not have them.
    fn members(&self, room: &RoomId) -> impl Future<Output = Result<Vec<Member>, BackendError>> + Send;

    /// One page of the room's history back from `from` (the newest message when `None`), with
    /// what it shared.
    fn shared(
        &self,
        room: &RoomId,
        from: Option<&str>,
    ) -> impl Future<Output = Result<SharedPage, BackendError>> + Send;

    /// When `chat`'s messages notify (each room's, for a merged one).
    fn set_notifications(
        &self,
        chat: &ChatId,
        mode: NotificationMode,
    ) -> impl Future<Output = Result<(), BackendError>> + Send;

    /// Renames the room for everyone in it.
    fn rename_room(&self, room: &RoomId, name: &str) -> impl Future<Output = Result<(), BackendError>> + Send;

    /// Sets what the room is about; an empty topic removes it.
    fn set_topic(&self, room: &RoomId, topic: &str) -> impl Future<Output = Result<(), BackendError>> + Send;

    /// Uploads `picture` and makes it the room's.
    fn set_room_avatar(&self, room: &RoomId, picture: Picture)
    -> impl Future<Output = Result<(), BackendError>> + Send;

    /// Removes the room's picture.
    fn remove_room_avatar(&self, room: &RoomId) -> impl Future<Output = Result<(), BackendError>> + Send;

    /// Leaves `chat`: each room of a merged one. It goes from the list.
    fn leave(&self, chat: &ChatId) -> impl Future<Output = Result<(), BackendError>> + Send;
}
