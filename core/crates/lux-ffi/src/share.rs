//! The share extension: the chats to share to (the list as the app last kept it) and the
//! account, opened to send what the user shares.

use std::sync::Arc;

use lux_core::chat::{Chat, Folder};
use lux_core::ids::{ChatId, MediaId, RoomId};
use lux_matrix::{KeptList, MatrixShare, StoreFolder};

use crate::account::{CoreAccountError, CoreSessionKeeper, Keeper};
use crate::runtime;
use crate::store::CoreStore;
use crate::timeline::CoreOutgoingAttachment;

/// A chat to share to, as the list last showed it.
#[derive(uniffi::Record)]
pub struct CoreShareChat {
    /// The chat's id (a room's, or a merged chat's): the one the app's notifications and
    /// suggestions name.
    pub id: String,
    /// The room it is sent to: a merged chat's default room.
    pub room_id: String,
    /// Its name.
    pub name: String,
    /// Its picture.
    pub avatar: Option<String>,
    /// A group with no picture: two members' pictures.
    pub member_avatars: Vec<String>,
    /// More than two people.
    pub is_group: bool,
    /// Its network.
    pub network: String,
}

impl CoreShareChat {
    /// `chat` as a target; none for a merged chat with no room to write to.
    fn of(chat: &Chat) -> Option<Self> {
        let room = match &chat.id {
            ChatId::Room(room) => room.clone(),
            ChatId::Merge(_) => chat
                .default_room
                .clone()
                .or_else(|| chat.rooms.first().map(|room| room.id.clone()))?,
        };
        Some(Self {
            id: chat.id.to_string(),
            room_id: room.to_string(),
            name: chat.name.clone(),
            avatar: chat.avatar.as_ref().map(ToString::to_string),
            member_avatars: chat.member_avatars.iter().map(ToString::to_string).collect(),
            is_group: chat.is_group,
            network: chat.network.as_str().to_owned(),
        })
    }
}

/// The chats to share to, from the list the app kept in `store`: the inbox's first (pinned on
/// top, as the list shows them), then low priority; archived chats are left out.
#[uniffi::export(async_runtime = "tokio")]
pub async fn share_chats(store: Arc<CoreStore>) -> Vec<CoreShareChat> {
    targets(KeptList::new(Arc::clone(&store.store)).read().await)
}

/// The targets among the list's `chats`, in the order [`share_chats`] gives them.
fn targets(mut chats: Vec<Chat>) -> Vec<CoreShareChat> {
    chats.retain(|chat| chat.folder != Folder::Archive);
    // a stable sort: each folder keeps the list's order.
    chats.sort_by_key(|chat| chat.folder != Folder::Inbox);
    chats.iter().filter_map(CoreShareChat::of).collect()
}

/// The account, opened in the share extension.
#[derive(uniffi::Object)]
pub struct CoreShareSender {
    share: Arc<MatrixShare>,
}

impl Drop for CoreShareSender {
    fn drop(&mut self) {
        // the SDK's client closes on the runtime.
        let share = Arc::clone(&self.share);
        runtime::handle().spawn(async move { drop(share) });
    }
}

/// Opens the account kept in the folder at `store_folder`, its session kept by `keeper`, as the
/// share extension; none when no session is kept.
///
/// # Errors
/// When the folder does not hold the session's device, or the store cannot be opened.
#[uniffi::export(async_runtime = "tokio")]
pub async fn open_share_sender(
    store_folder: String,
    keeper: Arc<dyn CoreSessionKeeper>,
) -> Result<Option<Arc<CoreShareSender>>, CoreAccountError> {
    let opened = MatrixShare::open(&StoreFolder::new(store_folder), Arc::new(Keeper(keeper))).await?;
    Ok(opened.map(|share| Arc::new(CoreShareSender { share: Arc::new(share) })))
}

#[uniffi::export(async_runtime = "tokio")]
impl CoreShareSender {
    /// Sends `attachments` and `text` to `room_id`; returns once the server has them. What the
    /// extension cannot wait for goes out when the app opens next.
    ///
    /// # Errors
    /// When the room is not the account's, a file cannot be read, or the server refuses.
    pub async fn send(
        &self,
        room_id: String,
        text: String,
        attachments: Vec<CoreOutgoingAttachment>,
    ) -> Result<(), CoreAccountError> {
        let attachments: Vec<_> = attachments.into_iter().map(Into::into).collect();
        Ok(self.share.send(&RoomId::from(room_id), &text, &attachments).await?)
    }

    /// The picture at `media` (a chat's or a person's), as image file bytes.
    pub async fn picture(&self, media: String) -> Option<Vec<u8>> {
        self.share.picture(&MediaId::from(media)).await
    }
}

#[cfg(test)]
mod tests {
    use lux_core::chat::ChatRoom;
    use lux_core::ids::MergeId;
    use lux_core::network::Network;

    use super::*;

    fn chat(id: ChatId, folder: Folder) -> Chat {
        Chat {
            name: id.to_string(),
            id,
            preview: None,
            date: None,
            unread_count: 0,
            is_marked_unread: false,
            is_muted: false,
            network: Network::from_id("matrix"),
            avatar: None,
            member_avatars: Vec::new(),
            reminder: None,
            is_group: false,
            folder,
            pinned: None,
            rooms: Vec::new(),
            default_room: None,
        }
    }

    #[test]
    fn the_inboxs_chats_come_first_and_archived_ones_not_at_all() {
        let room = |id: &str| ChatId::Room(RoomId::from(id));
        let chats = vec![
            chat(room("!low"), Folder::LowPriority),
            chat(room("!old"), Folder::Archive),
            chat(room("!a"), Folder::Inbox),
            chat(room("!b"), Folder::Inbox),
        ];
        let ids: Vec<_> = targets(chats).into_iter().map(|target| target.room_id).collect();
        assert_eq!(ids, ["!a", "!b", "!low"]);
    }

    #[test]
    fn a_merged_chat_is_sent_to_its_default_room_else_its_first() {
        let mut merged = chat(ChatId::Merge(MergeId::from("m")), Folder::Inbox);
        merged.rooms = vec![
            ChatRoom {
                id: RoomId::from("!wa"),
                network: Network::from_id("whatsapp"),
            },
            ChatRoom {
                id: RoomId::from("!sig"),
                network: Network::from_id("signal"),
            },
        ];
        assert_eq!(
            CoreShareChat::of(&merged).map(|target| target.room_id).as_deref(),
            Some("!wa")
        );
        merged.default_room = Some(RoomId::from("!sig"));
        assert_eq!(
            CoreShareChat::of(&merged).map(|target| target.room_id).as_deref(),
            Some("!sig")
        );
        merged.rooms.clear();
        merged.default_room = None;
        assert!(CoreShareChat::of(&merged).is_none());
    }
}
