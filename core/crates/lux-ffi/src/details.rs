//! A chat's details, as the apps see them: each room's state and networks, the members found as
//! the user types, what was shared read back page by page, and the details screen's changes.

use lux_core::mention::mention_suggestions;
use std::path::Path;
use std::sync::Arc;
use std::time::SystemTime;

use lux_core::details::{SharedHistory, chat_notifications, find_members, sort_members};
use lux_core::ids::{ChatId, EventId, RoomId};
use lux_core::ports::{
    ChatActions, ChatDetails, ChatMedia, Member, NotificationMode, Picture, Role, RoomDetails, SharedContent,
    SharedItem, SharedKind,
};

use crate::account::{Backend, CoreAccount, CoreAccountError, with_account};
use crate::chat::CorePreviewKind;
use crate::chat::path_text;
use crate::mention::CoreMentionSuggestion;
use crate::organizing::CoreChatChange;
use crate::profile::CorePictureFormat;
use crate::time_span::TimeSpan;
use crate::timeline::{CoreParticipant, CorePicture, CoreThreadSummary, picture};

/// When a chat's messages notify.
#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum CoreNotificationMode {
    /// As the account's settings say.
    Default,
    /// Every message.
    All,
    /// Mentions and keywords only.
    Mentions,
    /// Nothing.
    Off,
}

impl From<NotificationMode> for CoreNotificationMode {
    fn from(mode: NotificationMode) -> Self {
        match mode {
            NotificationMode::Default => Self::Default,
            NotificationMode::All => Self::All,
            NotificationMode::Mentions => Self::Mentions,
            NotificationMode::Off => Self::Off,
        }
    }
}

impl From<CoreNotificationMode> for NotificationMode {
    fn from(mode: CoreNotificationMode) -> Self {
        match mode {
            CoreNotificationMode::Default => Self::Default,
            CoreNotificationMode::All => Self::All,
            CoreNotificationMode::Mentions => Self::Mentions,
            CoreNotificationMode::Off => Self::Off,
        }
    }
}

/// One room of a chat, as its details show it.
#[allow(clippy::struct_excessive_bools, reason = "flags the apps read one by one")]
#[derive(uniffi::Record)]
pub struct CoreRoomDetails {
    /// The room.
    pub id: String,
    /// Its network (`"whatsapp"`, `"matrix"`).
    pub network: String,
    /// Its name.
    pub name: String,
    /// What it is about.
    pub topic: Option<String>,
    /// Its picture (a media URL).
    pub avatar: Option<String>,
    /// Its address (`#room:server`).
    pub address: Option<String>,
    /// End-to-end encrypted.
    pub is_encrypted: bool,
    /// A conversation of two.
    pub is_direct: bool,
    /// How many have joined.
    pub joined_members: u64,
    /// When it notifies.
    pub notifications: CoreNotificationMode,
    /// The account may rename it.
    pub can_rename: bool,
    /// The account may change its topic.
    pub can_change_topic: bool,
    /// The account may change its picture.
    pub can_change_avatar: bool,
}

impl CoreRoomDetails {
    fn new(details: RoomDetails, network: String) -> Self {
        Self {
            id: details.id.to_string(),
            network,
            name: details.name,
            topic: details.topic,
            avatar: details.avatar.map(|avatar| avatar.to_string()),
            address: details.address,
            is_encrypted: details.is_encrypted,
            is_direct: details.is_direct,
            joined_members: details.joined_members,
            notifications: details.notifications.into(),
            can_rename: details.may.rename,
            can_change_topic: details.may.change_topic,
            can_change_avatar: details.may.change_avatar,
        }
    }
}

/// A chat's details: its rooms (a merged chat's, in its order), and their one notification
/// setting.
#[derive(uniffi::Record)]
pub struct CoreChatDetails {
    /// Its rooms.
    pub rooms: Vec<CoreRoomDetails>,
    /// When it notifies; none when its rooms differ.
    pub notifications: Option<CoreNotificationMode>,
}

/// What a member may do.
#[derive(Clone, Copy, uniffi::Enum)]
pub enum CoreRole {
    /// Made the room.
    Creator,
    /// An admin.
    Admin,
    /// A moderator.
    Moderator,
    /// Takes part.
    Member,
}

/// Someone who joined a room.
#[derive(uniffi::Record)]
pub struct CoreMember {
    /// Their account.
    pub user_id: String,
    /// Their name.
    pub name: String,
    /// Their picture (a media URL).
    pub avatar: Option<String>,
    /// What they may do.
    pub role: CoreRole,
    /// The account itself.
    pub is_own: bool,
}

impl From<&Member> for CoreMember {
    fn from(member: &Member) -> Self {
        Self {
            user_id: member.user.to_string(),
            name: member.name.clone(),
            avatar: member.avatar.as_ref().map(ToString::to_string),
            role: match member.role {
                Role::Creator => CoreRole::Creator,
                Role::Admin => CoreRole::Admin,
                Role::Moderator => CoreRole::Moderator,
                Role::Member => CoreRole::Member,
            },
            is_own: member.is_own,
        }
    }
}

/// A room's members, loaded once, in the order the screen lists them.
#[derive(uniffi::Object)]
pub struct CoreMemberList {
    members: Vec<Member>,
}

/// A Matrix thread of a room, as the room's list of threads shows it.
#[derive(uniffi::Record)]
pub struct CoreListedThread {
    /// Its root's event: the thread opens by it.
    pub root_event_id: String,
    /// Who wrote the root.
    pub sender: CoreParticipant,
    /// What the root is.
    pub kind: CorePreviewKind,
    /// When the root was sent.
    pub date: SystemTime,
    /// Its replies, summed up.
    pub summary: CoreThreadSummary,
}

/// One page of a room's Matrix threads.
#[derive(uniffi::Record)]
pub struct CoreThreadPage {
    /// The page's threads, the latest active first.
    pub threads: Vec<CoreListedThread>,
    /// Where the next page starts; none after the last.
    pub next: Option<String>,
}

#[uniffi::export]
impl CoreMemberList {
    /// How many there are.
    #[must_use]
    pub fn count(&self) -> u64 {
        u64::try_from(self.members.len()).unwrap_or(u64::MAX)
    }

    /// The members (and `@room`, where the account may notify the room) a mention's `query`
    /// offers, the best match first, at most `limit`; never the account.
    #[must_use]
    pub fn mention_suggestions(&self, query: &str, limit: u32) -> Vec<CoreMentionSuggestion> {
        mention_suggestions(&self.members, query, usize::try_from(limit).unwrap_or(usize::MAX))
            .into_iter()
            .map(CoreMentionSuggestion::from)
            .collect()
    }

    /// The members whose name or id holds every word of `query` (without case or accents), at
    /// most `limit`; all of them for an empty query.
    #[must_use]
    pub fn find(&self, query: &str, limit: u32) -> Vec<CoreMember> {
        find_members(&self.members, query)
            .take(usize::try_from(limit).unwrap_or(usize::MAX))
            .map(CoreMember::from)
            .collect()
    }
}

/// Which kind of shared item.
#[derive(Clone, Copy, uniffi::Enum)]
pub enum CoreSharedKind {
    /// Photos and videos.
    Media,
    /// Files and sounds.
    Files,
    /// Web addresses.
    Links,
}

impl From<CoreSharedKind> for SharedKind {
    fn from(kind: CoreSharedKind) -> Self {
        match kind {
            CoreSharedKind::Media => Self::Media,
            CoreSharedKind::Files => Self::Files,
            CoreSharedKind::Links => Self::Links,
        }
    }
}

/// What a shared item is.
#[derive(uniffi::Enum)]
pub enum CoreSharedContent {
    /// A photo.
    Photo {
        /// Its thumbnail.
        picture: CorePicture,
    },
    /// A video.
    Video {
        /// Its poster.
        poster: Option<CorePicture>,
        /// Its length.
        duration: Option<TimeSpan>,
    },
    /// A file or a sound.
    File {
        /// Its name.
        name: String,
        /// Its size in bytes.
        size: Option<u64>,
        /// Its type; empty when not said.
        mimetype: String,
    },
    /// A web address.
    Link {
        /// Where it leads.
        url: String,
        /// The message's text.
        text: String,
    },
}

/// Something shared in a chat.
#[derive(uniffi::Record)]
pub struct CoreSharedItem {
    /// Its message's event.
    pub event_id: String,
    /// Its room.
    pub room_id: String,
    /// Who shared it.
    pub sender_name: String,
    /// When.
    pub date: SystemTime,
    /// What it is.
    pub content: CoreSharedContent,
}

impl From<SharedItem> for CoreSharedItem {
    fn from(item: SharedItem) -> Self {
        Self {
            event_id: item.event.to_string(),
            room_id: item.room.to_string(),
            sender_name: item.sender_name,
            date: item.date,
            content: match item.content {
                SharedContent::Photo { picture: shown, .. } => CoreSharedContent::Photo {
                    picture: picture(&shown),
                },
                SharedContent::Video { poster, duration, .. } => CoreSharedContent::Video {
                    poster: poster.as_ref().map(picture),
                    duration: duration.map(TimeSpan),
                },
                SharedContent::File { name, size, mimetype } => CoreSharedContent::File { name, size, mimetype },
                SharedContent::Link { url, text } => CoreSharedContent::Link { url, text },
            },
        }
    }
}

/// What was shared in a chat, of one kind, read back the newest first as the user scrolls.
#[derive(uniffi::Object)]
pub struct CoreSharedHistory {
    backend: Backend,
    history: tokio::sync::Mutex<SharedHistory>,
}

#[uniffi::export(async_runtime = "tokio")]
impl CoreSharedHistory {
    /// The next `count` items, older than those given; fewer at the chat's start, or when a long
    /// stretch shared none (ask again to read on).
    ///
    /// # Errors
    /// When the history cannot be read.
    pub async fn next(&self, count: u32) -> Result<Vec<CoreSharedItem>, CoreAccountError> {
        let want = usize::try_from(count).unwrap_or(usize::MAX);
        let mut history = self.history.lock().await;
        let items = with_account!(&self.backend, account => history.next(account.as_ref(), want).await)?;
        Ok(items.into_iter().map(CoreSharedItem::from).collect())
    }

    /// Everything was read back to the chat's start.
    pub async fn is_at_start(&self) -> bool {
        self.history.lock().await.is_at_start()
    }
}

impl CoreAccount {
    /// The rooms of the chat `chat_id` with their networks, as the chat list shows it.
    async fn rooms_with_networks(&self, chat_id: &str) -> Result<Vec<(RoomId, String)>, CoreAccountError> {
        let chat_id = ChatId::from(chat_id);
        let chats = self.current_chats().await;
        let chat = chats
            .iter()
            .find(|chat| chat.id == chat_id)
            .ok_or_else(|| CoreAccountError::NoSuchChat {
                chat: chat_id.to_string(),
            })?;
        Ok(if chat.rooms.is_empty() {
            chat.id
                .room()
                .map(|room| (room.clone(), chat.network.as_str().to_owned()))
                .into_iter()
                .collect()
        } else {
            chat.rooms
                .iter()
                .map(|room| (room.id.clone(), room.network.as_str().to_owned()))
                .collect()
        })
    }
}

#[uniffi::export(async_runtime = "tokio")]
impl CoreAccount {
    /// The details of the chat `chat_id`: each of its rooms'.
    ///
    /// # Errors
    /// When the chat is not in the list, or a room's details cannot be read.
    pub async fn chat_details(&self, chat_id: String) -> Result<CoreChatDetails, CoreAccountError> {
        let mut rooms = Vec::new();
        for (room, network) in self.rooms_with_networks(&chat_id).await? {
            let details = with_account!(self.backend(), account => account.room_details(&room).await)?;
            rooms.push((details, network));
        }
        let all: Vec<RoomDetails> = rooms.iter().map(|(details, _)| details.clone()).collect();
        Ok(CoreChatDetails {
            notifications: chat_notifications(&all).map(Into::into),
            rooms: rooms
                .into_iter()
                .map(|(details, network)| CoreRoomDetails::new(details, network))
                .collect(),
        })
    }

    /// The room's members, loaded from the server once if this device does not have them.
    ///
    /// # Errors
    /// When the room is not the account's, or its members cannot be loaded.
    pub async fn room_members(&self, room_id: String) -> Result<Arc<CoreMemberList>, CoreAccountError> {
        let room = RoomId::from(room_id);
        let mut members = with_account!(self.backend(), account => account.members(&room).await)?;
        sort_members(&mut members);
        Ok(Arc::new(CoreMemberList { members }))
    }

    /// What was shared in the chat `chat_id` (each room of a merged one), of `kind`; with a
    /// `query`, only what holds its words (a file's name, a link's address or text, a photo's or
    /// a video's caption).
    ///
    /// # Errors
    /// When the chat is not in the list.
    pub async fn shared_history(
        &self,
        chat_id: String,
        kind: CoreSharedKind,
        query: Option<String>,
    ) -> Result<Arc<CoreSharedHistory>, CoreAccountError> {
        let rooms = self.rooms_with_networks(&chat_id).await?;
        let history = SharedHistory::new(rooms.into_iter().map(|(room, _)| room).collect(), kind.into())
            .finding(query.as_deref().unwrap_or_default());
        Ok(Arc::new(CoreSharedHistory {
            backend: self.backend().clone(),
            history: tokio::sync::Mutex::new(history),
        }))
    }

    /// One page of the room's Matrix threads from `from` (the latest active first when none).
    ///
    /// # Errors
    /// When the room is not the account's, or the server does not answer.
    pub async fn room_threads(
        &self,
        room_id: String,
        from: Option<String>,
    ) -> Result<CoreThreadPage, CoreAccountError> {
        let room = RoomId::from(room_id);
        let page = with_account!(self.backend(), account => account.threads(&room, from.as_deref()).await)?;
        Ok(CoreThreadPage {
            threads: page
                .threads
                .into_iter()
                .map(|thread| CoreListedThread {
                    root_event_id: thread.root.to_string(),
                    sender: thread.sender.into(),
                    kind: thread.kind.into(),
                    date: thread.date,
                    summary: thread.summary.into(),
                })
                .collect(),
            next: page.next,
        })
    }

    /// When the chat's messages notify (each room's, for a merged one).
    ///
    /// # Errors
    /// When the server refuses.
    pub async fn set_chat_notifications(
        &self,
        chat_id: String,
        mode: CoreNotificationMode,
    ) -> Result<(), CoreAccountError> {
        let chat = ChatId::from(chat_id.as_str());
        Ok(with_account!(self.backend(), account => account.set_notifications(&chat, mode.into()).await)?)
    }

    /// Renames the room for everyone in it.
    ///
    /// # Errors
    /// `NameTooLong`, or when the server refuses.
    pub async fn rename_room(&self, room_id: String, name: String) -> Result<(), CoreAccountError> {
        let room = RoomId::from(room_id);
        Ok(with_account!(self.backend(), account => account.rename_room(&room, &name).await)?)
    }

    /// Sets what the room is about; an empty topic removes it.
    ///
    /// # Errors
    /// When the server refuses.
    pub async fn set_room_topic(&self, room_id: String, topic: String) -> Result<(), CoreAccountError> {
        let room = RoomId::from(room_id);
        Ok(with_account!(self.backend(), account => account.set_topic(&room, &topic).await)?)
    }

    /// Uploads a picture and makes it the room's.
    ///
    /// # Errors
    /// When the upload or the server's change fails.
    pub async fn set_room_picture(
        &self,
        room_id: String,
        data: Vec<u8>,
        format: CorePictureFormat,
    ) -> Result<(), CoreAccountError> {
        let room = RoomId::from(room_id);
        let picture = Picture {
            data,
            format: format.into(),
        };
        Ok(with_account!(self.backend(), account => account.set_room_avatar(&room, picture).await)?)
    }

    /// Removes the room's picture.
    ///
    /// # Errors
    /// When the server refuses.
    pub async fn remove_room_picture(&self, room_id: String) -> Result<(), CoreAccountError> {
        let room = RoomId::from(room_id);
        Ok(with_account!(self.backend(), account => account.remove_room_avatar(&room).await)?)
    }

    /// Does one of a chat's menu actions from its details, and returns once the server has it.
    ///
    /// # Errors
    /// When the server refuses.
    pub async fn change_chat(&self, chat_id: String, change: CoreChatChange) -> Result<(), CoreAccountError> {
        let chat = ChatId::from(chat_id.as_str());
        Ok(with_account!(self.backend(), account => account.change(&chat, change.into()).await)?)
    }

    /// Leaves the chat (each room of a merged one).
    ///
    /// # Errors
    /// When the server refuses.
    pub async fn leave_chat(&self, chat_id: String) -> Result<(), CoreAccountError> {
        let chat = ChatId::from(chat_id.as_str());
        Ok(with_account!(self.backend(), account => account.leave(&chat).await)?)
    }

    /// A shared photo's, video's or file's original, loaded once into `folder`.
    ///
    /// # Errors
    /// When it has none, or it cannot be loaded or written.
    pub async fn shared_file(
        &self,
        room_id: String,
        event_id: String,
        folder: String,
    ) -> Result<String, CoreAccountError> {
        let account = self.matrix_account()?;
        // the download's future is large: on the heap.
        let file = Box::pin(account.timelines().shared_file(
            &RoomId::from(room_id),
            &EventId::from(event_id),
            Path::new(&folder),
        ))
        .await?;
        Ok(path_text(&file))
    }
}
