//! The kept list: the chat list as it was last shown, kept in the account's encrypted store
//! (`lux-store`) so the next launch draws it before the account opens.
//!
//! It is one value in the store (JSON, encrypted with the rest), replaced whole each time.

use std::sync::Arc;
use std::time::SystemTime;

use eyeball_im::Vector;

use lux_core::chat::{Chat, ChatRoom, Folder};
use lux_core::ids::{ChatId, MediaId, RoomId};
use lux_core::network::Network;
use lux_core::preview::{Author, Membership, Preview, PreviewKind};
use lux_store::Store;
use serde::{Deserialize, Serialize};

/// The value's key in the store.
const KEY: &str = "core-chat-list";

/// The value's format; another version is not read.
const VERSION: u32 = 2;

/// Reads and writes one account's kept list.
#[derive(Clone, Debug)]
pub struct KeptList {
    store: Arc<Store>,
}

impl KeptList {
    /// The kept list in the account's store.
    #[must_use]
    pub fn new(store: Arc<Store>) -> Self {
        Self { store }
    }

    /// The kept chats; empty when none were kept, or when they cannot be read.
    pub async fn read(&self) -> Vec<Chat> {
        let Ok(Some(bytes)) = self.store.kept(KEY.to_owned()).await else {
            return Vec::new();
        };
        match serde_json::from_slice::<Kept>(&bytes) {
            Ok(kept) if kept.version == VERSION => kept.chats.into_iter().map(Chat::from).collect(),
            _ => Vec::new(),
        }
    }

    /// Keeps `chats` in place of the kept ones. They are written out away from the runtime's
    /// threads: a list of thousands takes a while.
    ///
    /// # Errors
    /// When the store cannot write.
    pub async fn write(&self, chats: Vector<Arc<Chat>>) -> Result<(), lux_store::Error> {
        let written = tokio::task::spawn_blocking(move || {
            let kept = Kept {
                version: VERSION,
                chats: chats.iter().map(|chat| KeptChat::from(chat.as_ref())).collect(),
            };
            // a list of plain strings and numbers always serializes.
            serde_json::to_vec(&kept)
        })
        .await;
        match written {
            Ok(Ok(bytes)) => self.store.keep(KEY.to_owned(), bytes).await,
            // nothing to write: the kept list stays as it was.
            Ok(Err(_)) | Err(_) => Ok(()),
        }
    }
}

#[derive(Serialize, Deserialize)]
struct Kept {
    version: u32,
    chats: Vec<KeptChat>,
}

/// A chat as the file keeps it: the core's type stays free of a format.
#[derive(Serialize, Deserialize)]
struct KeptChat {
    id: String,
    name: String,
    preview: Option<KeptPreview>,
    date: Option<SystemTime>,
    unread_count: u32,
    is_marked_unread: bool,
    is_muted: bool,
    network: String,
    avatar: Option<String>,
    member_avatars: Vec<String>,
    reminder: Option<SystemTime>,
    is_group: bool,
    folder: KeptFolder,
    pinned: Option<f64>,
    rooms: Vec<(String, String)>,
    default_room: Option<String>,
}

/// A preview as the store keeps it.
#[derive(Serialize, Deserialize)]
struct KeptPreview {
    author: Option<KeptAuthor>,
    kind: KeptKind,
}

#[derive(Serialize, Deserialize)]
enum KeptAuthor {
    Own,
    Named(String),
}

#[derive(Serialize, Deserialize)]
enum KeptKind {
    Text(String),
    Image,
    Video,
    Audio,
    Voice,
    File(Option<String>),
    Location,
    Sticker,
    Poll(String),
    Encrypted,
    Deleted,
    Reaction(String),
    Call,
    Membership(KeptMembership),
    Other,
}

#[derive(Clone, Copy, Serialize, Deserialize)]
enum KeptMembership {
    Joined,
    Invited,
    Knocked,
}

impl From<Membership> for KeptMembership {
    fn from(membership: Membership) -> Self {
        match membership {
            Membership::Joined => Self::Joined,
            Membership::Invited => Self::Invited,
            Membership::Knocked => Self::Knocked,
        }
    }
}

impl From<KeptMembership> for Membership {
    fn from(membership: KeptMembership) -> Self {
        match membership {
            KeptMembership::Joined => Self::Joined,
            KeptMembership::Invited => Self::Invited,
            KeptMembership::Knocked => Self::Knocked,
        }
    }
}

impl From<&Preview> for KeptPreview {
    fn from(preview: &Preview) -> Self {
        Self {
            author: preview.author.as_ref().map(|author| match author {
                Author::Own => KeptAuthor::Own,
                Author::Named(name) => KeptAuthor::Named(name.clone()),
            }),
            kind: match &preview.kind {
                PreviewKind::Text(text) => KeptKind::Text(text.clone()),
                PreviewKind::Image => KeptKind::Image,
                PreviewKind::Video => KeptKind::Video,
                PreviewKind::Audio => KeptKind::Audio,
                PreviewKind::Voice => KeptKind::Voice,
                PreviewKind::File(name) => KeptKind::File(name.clone()),
                PreviewKind::Location => KeptKind::Location,
                PreviewKind::Sticker => KeptKind::Sticker,
                PreviewKind::Poll(question) => KeptKind::Poll(question.clone()),
                PreviewKind::Encrypted => KeptKind::Encrypted,
                PreviewKind::Deleted => KeptKind::Deleted,
                PreviewKind::Reaction(key) => KeptKind::Reaction(key.clone()),
                PreviewKind::Call => KeptKind::Call,
                PreviewKind::Membership(membership) => KeptKind::Membership((*membership).into()),
                PreviewKind::Other => KeptKind::Other,
            },
        }
    }
}

impl From<KeptPreview> for Preview {
    fn from(kept: KeptPreview) -> Self {
        Self {
            author: kept.author.map(|author| match author {
                KeptAuthor::Own => Author::Own,
                KeptAuthor::Named(name) => Author::Named(name),
            }),
            kind: match kept.kind {
                KeptKind::Text(text) => PreviewKind::Text(text),
                KeptKind::Image => PreviewKind::Image,
                KeptKind::Video => PreviewKind::Video,
                KeptKind::Audio => PreviewKind::Audio,
                KeptKind::Voice => PreviewKind::Voice,
                KeptKind::File(name) => PreviewKind::File(name),
                KeptKind::Location => PreviewKind::Location,
                KeptKind::Sticker => PreviewKind::Sticker,
                KeptKind::Poll(question) => PreviewKind::Poll(question),
                KeptKind::Encrypted => PreviewKind::Encrypted,
                KeptKind::Deleted => PreviewKind::Deleted,
                KeptKind::Reaction(key) => PreviewKind::Reaction(key),
                KeptKind::Call => PreviewKind::Call,
                KeptKind::Membership(membership) => PreviewKind::Membership(membership.into()),
                KeptKind::Other => PreviewKind::Other,
            },
        }
    }
}

#[derive(Serialize, Deserialize)]
enum KeptFolder {
    Inbox,
    LowPriority,
    Archive,
}

impl From<&Chat> for KeptChat {
    fn from(chat: &Chat) -> Self {
        Self {
            id: chat.id.to_string(),
            name: chat.name.clone(),
            preview: chat.preview.as_ref().map(KeptPreview::from),
            date: chat.date,
            unread_count: chat.unread_count,
            is_marked_unread: chat.is_marked_unread,
            is_muted: chat.is_muted,
            network: chat.network.as_str().to_owned(),
            avatar: chat.avatar.as_ref().map(ToString::to_string),
            member_avatars: chat.member_avatars.iter().map(ToString::to_string).collect(),
            reminder: chat.reminder,
            is_group: chat.is_group,
            folder: match chat.folder {
                Folder::Inbox => KeptFolder::Inbox,
                Folder::LowPriority => KeptFolder::LowPriority,
                Folder::Archive => KeptFolder::Archive,
            },
            pinned: chat.pinned,
            rooms: chat
                .rooms
                .iter()
                .map(|room| (room.id.to_string(), room.network.as_str().to_owned()))
                .collect(),
            default_room: chat.default_room.as_ref().map(ToString::to_string),
        }
    }
}

impl From<KeptChat> for Chat {
    fn from(kept: KeptChat) -> Self {
        Self {
            id: ChatId::from(kept.id),
            name: kept.name,
            preview: kept.preview.map(Preview::from),
            date: kept.date,
            unread_count: kept.unread_count,
            is_marked_unread: kept.is_marked_unread,
            is_muted: kept.is_muted,
            network: Network::from_id(&kept.network),
            avatar: kept.avatar.map(MediaId::from),
            member_avatars: kept.member_avatars.into_iter().map(MediaId::from).collect(),
            reminder: kept.reminder,
            is_group: kept.is_group,
            folder: match kept.folder {
                KeptFolder::Inbox => Folder::Inbox,
                KeptFolder::LowPriority => Folder::LowPriority,
                KeptFolder::Archive => Folder::Archive,
            },
            pinned: kept.pinned,
            rooms: kept
                .rooms
                .into_iter()
                .map(|(id, network)| ChatRoom {
                    id: RoomId::from(id),
                    network: Network::from_id(&network),
                })
                .collect(),
            default_room: kept.default_room.map(RoomId::from),
        }
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;
    use std::time::{Duration, UNIX_EPOCH};

    use lux_core::chat::{Chat, Folder};
    use lux_core::network::Network;
    use lux_core::preview::{Preview, PreviewSource, Sender};
    use lux_store::{Key, Store};

    use super::KeptList;

    fn chat(id: &str) -> Chat {
        Chat {
            id: id.into(),
            name: "Anna".to_owned(),
            preview: Some(Preview::new(PreviewSource::Text("ok"), Sender::Own, false)),
            date: Some(UNIX_EPOCH + Duration::from_secs(1_700_000_000)),
            unread_count: 2,
            is_marked_unread: false,
            is_muted: true,
            network: Network::WhatsApp,
            avatar: Some("mxc://example.org/a".into()),
            member_avatars: Vec::new(),
            reminder: None,
            is_group: false,
            folder: Folder::LowPriority,
            pinned: Some(0.5),
            rooms: Vec::new(),
            default_room: None,
        }
    }

    async fn store(folder: &std::path::Path) -> Arc<Store> {
        let key = Key::from_hex(&"0d".repeat(32)).unwrap();
        Arc::new(Store::open(folder.join("index.sqlite"), key).await.unwrap())
    }

    #[tokio::test]
    async fn a_kept_list_reads_back_as_it_was() {
        let folder = tempfile::tempdir().unwrap();
        let kept = KeptList::new(store(folder.path()).await);
        let chats = vec![chat("!a:example.org"), chat("!b:example.org")];
        kept.write(chats.iter().cloned().map(Arc::new).collect()).await.unwrap();
        assert_eq!(kept.read().await, chats);
    }

    #[tokio::test]
    async fn no_kept_list_reads_as_empty() {
        let folder = tempfile::tempdir().unwrap();
        let store = store(folder.path()).await;
        assert!(KeptList::new(Arc::clone(&store)).read().await.is_empty());
        store.keep(super::KEY.to_owned(), b"{ not json".to_vec()).await.unwrap();
        assert!(KeptList::new(store).read().await.is_empty());
    }
}
