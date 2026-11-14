//! The account's encrypted store (`lux-store`), as the apps see it.

use std::sync::Arc;
use std::time::SystemTime;

use lux_core::timeline::IndexedMessage;
use lux_store::{Error, Hit, IndexedChat, Key, Store};

/// Why a store call failed.
#[derive(Debug, thiserror::Error, uniffi::Error)]
#[uniffi(flat_error)]
pub enum CoreStoreError {
    /// The key is not 64 hex digits.
    #[error("the key is not 64 hex digits")]
    InvalidKey,
    /// The library's SQLite does not encrypt.
    #[error("the linked SQLite is not SQLCipher")]
    NotEncrypted,
    /// The store's thread has ended.
    #[error("the store is closed")]
    Closed,
    /// The file or SQLite.
    #[error("{0}")]
    Failed(String),
}

impl From<Error> for CoreStoreError {
    fn from(error: Error) -> Self {
        match error {
            Error::InvalidKey => Self::InvalidKey,
            Error::NotEncrypted => Self::NotEncrypted,
            Error::Closed => Self::Closed,
            other => Self::Failed(other.to_string()),
        }
    }
}

/// A message for the search index.
#[derive(uniffi::Record)]
pub struct CoreStoreMessage {
    /// Its event id.
    pub event_id: String,
    /// Its room.
    pub room_id: String,
    /// Its sender's name.
    pub sender_name: String,
    /// Its text.
    pub body: String,
    /// When it was sent.
    pub date: SystemTime,
    /// The user sent it.
    pub is_own: bool,
}

/// How far the index has read one chat.
#[derive(uniffi::Record)]
pub struct CoreStoreChat {
    /// Its room.
    pub room_id: String,
    /// The newest message indexed.
    pub newest: SystemTime,
    /// Its history is indexed as far back as the index goes.
    pub complete: bool,
}

/// A run of found words in an excerpt, in UTF-16 code units.
#[derive(uniffi::Record)]
pub struct CoreStoreMatch {
    /// Where it starts.
    pub start: u32,
    /// How long it is.
    pub length: u32,
}

/// A message a search found.
#[derive(uniffi::Record)]
pub struct CoreStoreHit {
    /// Its event id.
    pub event_id: String,
    /// Its room.
    pub room_id: String,
    /// Its sender's name.
    pub sender_name: String,
    /// Its text around the found words.
    pub excerpt: String,
    /// The found words in `excerpt`.
    pub matches: Vec<CoreStoreMatch>,
    /// When it was sent.
    pub date: SystemTime,
    /// The user sent it.
    pub is_own: bool,
}

/// The account's encrypted store on this device: the message search index and kept values.
#[derive(uniffi::Object)]
pub struct CoreStore {
    /// Shared with the account, which keeps its chat list in it.
    pub(crate) store: Arc<Store>,
}

#[uniffi::export]
impl CoreStore {
    /// Opens the store at `path` with `key` (64 hex digits), or makes it; a file the key does not
    /// open gives way to a new one (the store is a cache).
    #[uniffi::constructor]
    pub async fn open(path: String, key: String) -> Result<Arc<Self>, CoreStoreError> {
        let store = Store::open_or_replace(path, Key::from_hex(&key)?).await?;
        Ok(Arc::new(Self { store: Arc::new(store) }))
    }

    /// Adds messages, or changes them (an edit keeps its event id), in one transaction.
    pub async fn add(&self, messages: Vec<CoreStoreMessage>) -> Result<(), CoreStoreError> {
        let messages = messages
            .into_iter()
            .map(|message| IndexedMessage {
                event_id: message.event_id.into(),
                room: message.room_id.into(),
                sender_name: message.sender_name,
                body: message.body,
                date: message.date,
                is_own: message.is_own,
            })
            .collect();
        Ok(self.store.add(messages).await?)
    }

    /// Removes messages deleted in their chat.
    pub async fn remove(&self, event_ids: Vec<String>) -> Result<(), CoreStoreError> {
        Ok(self
            .store
            .remove(event_ids.into_iter().map(Into::into).collect())
            .await?)
    }

    /// Forgets a chat's messages: up to `until` (the chat was deleted then), or all of them and
    /// how far the index read it (`None`: the chat is gone from the account's list).
    pub async fn forget_chat(&self, room_id: String, until: Option<SystemTime>) -> Result<(), CoreStoreError> {
        Ok(self.store.forget_chat(room_id.into(), until).await?)
    }

    /// Keeps how far the index has read a chat.
    pub async fn set_chat(&self, chat: CoreStoreChat) -> Result<(), CoreStoreError> {
        let indexed = IndexedChat {
            newest: chat.newest,
            complete: chat.complete,
        };
        Ok(self.store.set_chat(chat.room_id.into(), indexed).await?)
    }

    /// How far the index has read each chat.
    pub async fn chats(&self) -> Result<Vec<CoreStoreChat>, CoreStoreError> {
        let chats = self.store.chats().await?;
        Ok(chats
            .into_iter()
            .map(|(room_id, chat)| CoreStoreChat {
                room_id: room_id.to_string(),
                newest: chat.newest,
                complete: chat.complete,
            })
            .collect())
    }

    /// How many messages the index holds.
    pub async fn message_count(&self) -> Result<u64, CoreStoreError> {
        Ok(self.store.message_count().await?)
    }

    /// The messages with every word of `text` (each by its start, without case or accents), the
    /// newest first; `room_id` keeps one chat's.
    pub async fn search(
        &self,
        text: String,
        room_id: Option<String>,
        limit: u32,
    ) -> Result<Vec<CoreStoreHit>, CoreStoreError> {
        let hits = self.store.search(&text, room_id.map(Into::into), limit).await?;
        Ok(hits.into_iter().map(CoreStoreHit::from).collect())
    }
}

impl From<Hit> for CoreStoreHit {
    fn from(hit: Hit) -> Self {
        Self {
            event_id: hit.event_id.to_string(),
            room_id: hit.room_id.to_string(),
            sender_name: hit.sender_name,
            excerpt: hit.excerpt,
            matches: hit
                .matches
                .into_iter()
                .map(|range| CoreStoreMatch {
                    start: range.start,
                    length: range.end - range.start,
                })
                .collect(),
            date: hit.date,
            is_own: hit.is_own,
        }
    }
}
