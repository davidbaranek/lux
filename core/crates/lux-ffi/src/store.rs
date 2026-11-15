//! The account's encrypted store (`lux-store`), as the apps see it.

use std::sync::Arc;
use std::time::SystemTime;

use lux_core::timeline::{IndexedImage, IndexedMessage};
use lux_store::{Error, Hit, ImageHit, ImageRead, ImageReason, ImageSearch, IndexedChat, Key, Store};

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

/// A photo for the search index.
#[derive(uniffi::Record)]
pub struct CoreStoreImage {
    /// Its event id.
    pub event_id: String,
    /// Its room.
    pub room_id: String,
    /// Its sender's name.
    pub sender_name: String,
    /// The words sent with it.
    pub caption: String,
    /// When it was sent.
    pub date: SystemTime,
    /// The user sent it.
    pub is_own: bool,
}

/// A photo for the app to read.
#[derive(uniffi::Record)]
pub struct CoreImageToRead {
    /// Its event id.
    pub event_id: String,
    /// Its room.
    pub room_id: String,
}

/// What the app read in a photo.
#[derive(uniffi::Record)]
pub struct CoreImageRead {
    /// Its event id.
    pub event_id: String,
    /// Who read it, with the reader's version.
    pub reader: String,
    /// The words in it.
    pub words: String,
    /// Its unit embedding; none when the reader makes none.
    pub embedding: Option<Vec<f32>>,
}

/// A search for photos.
#[derive(uniffi::Record)]
pub struct CoreImageSearch {
    /// The typed words.
    pub text: String,
    /// The words' embedding in the photos' space; none finds by words only.
    pub embedding: Option<Vec<f32>>,
    /// The least cosine a photo found by its look has to the words'.
    pub min_similarity: f32,
    /// One chat's photos only.
    pub room_id: Option<String>,
    /// At most this many.
    pub limit: u32,
}

/// Why a search found a photo.
#[derive(uniffi::Enum)]
pub enum CoreImageReason {
    /// Its caption or the words in it.
    Words {
        /// The words around the found ones.
        excerpt: String,
        /// The found words in `excerpt`.
        matches: Vec<CoreStoreMatch>,
    },
    /// A message sent near it.
    Nearby {
        /// That message's words around the found ones.
        excerpt: String,
        /// The found words in `excerpt`.
        matches: Vec<CoreStoreMatch>,
    },
    /// How it looks.
    Looks {
        /// The cosine of its and the words' embeddings.
        similarity: f32,
    },
}

/// A photo a search found.
#[derive(uniffi::Record)]
pub struct CoreImageHit {
    /// Its event id.
    pub event_id: String,
    /// Its room.
    pub room_id: String,
    /// Its sender's name.
    pub sender_name: String,
    /// When it was sent.
    pub date: SystemTime,
    /// The user sent it.
    pub is_own: bool,
    /// Why it was found.
    pub reason: CoreImageReason,
}

/// How many photos the index has, and how many were read.
#[derive(uniffi::Record)]
pub struct CoreImageCounts {
    /// The photos.
    pub total: u64,
    /// Those the reader asked about has read.
    pub read: u64,
    /// Those whose words were read, by any reader.
    pub with_words: u64,
    /// Those with an embedding.
    pub with_embedding: u64,
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

#[uniffi::export]
impl CoreStore {
    /// Adds photos, or changes their captions, in one transaction.
    pub async fn add_images(&self, images: Vec<CoreStoreImage>) -> Result<(), CoreStoreError> {
        let images = images
            .into_iter()
            .map(|image| IndexedImage {
                event_id: image.event_id.into(),
                room: image.room_id.into(),
                sender_name: image.sender_name,
                caption: image.caption,
                date: image.date,
                is_own: image.is_own,
            })
            .collect();
        Ok(self.store.add_images(images).await?)
    }

    /// The photos `reader` has not read yet, the newest first, at most `limit`.
    pub async fn images_to_read(&self, reader: String, limit: u32) -> Result<Vec<CoreImageToRead>, CoreStoreError> {
        let images = self.store.images_to_read(reader, limit).await?;
        Ok(images
            .into_iter()
            .map(|(event_id, room_id)| CoreImageToRead {
                event_id: event_id.to_string(),
                room_id: room_id.to_string(),
            })
            .collect())
    }

    /// Keeps what the app read in photos.
    pub async fn set_images_read(&self, reads: Vec<CoreImageRead>) -> Result<(), CoreStoreError> {
        let reads = reads
            .into_iter()
            .map(|read| ImageRead {
                event_id: read.event_id.into(),
                reader: read.reader,
                words: read.words,
                embedding: read.embedding,
            })
            .collect();
        Ok(self.store.set_images_read(reads).await?)
    }

    /// Counts a failed reading of a photo; after a few, it is not asked for again.
    pub async fn image_unread(&self, event_id: String) -> Result<(), CoreStoreError> {
        Ok(self.store.image_unread(event_id.into()).await?)
    }

    /// Asks again for every photo that could not be read.
    pub async fn retry_unread_images(&self) -> Result<(), CoreStoreError> {
        Ok(self.store.retry_unread_images().await?)
    }

    /// Forgets every photo's embedding (search by look turned off); their words stay, as read by
    /// `reader`.
    pub async fn forget_image_embeddings(&self, reader: String) -> Result<(), CoreStoreError> {
        Ok(self.store.forget_image_embeddings(reader).await?)
    }

    /// How many photos the index has, and how many `reader` has read.
    pub async fn image_counts(&self, reader: String) -> Result<CoreImageCounts, CoreStoreError> {
        let counts = self.store.image_counts(reader).await?;
        Ok(CoreImageCounts {
            total: counts.total,
            read: counts.read,
            with_words: counts.with_words,
            with_embedding: counts.with_embedding,
        })
    }

    /// The photos that match, by their words, the messages near them and their look; the best
    /// first.
    pub async fn search_images(&self, search: CoreImageSearch) -> Result<Vec<CoreImageHit>, CoreStoreError> {
        let hits = self
            .store
            .search_images(ImageSearch {
                text: search.text,
                embedding: search.embedding,
                min_similarity: search.min_similarity,
                room_id: search.room_id.map(Into::into),
                limit: search.limit,
            })
            .await?;
        Ok(hits.into_iter().map(CoreImageHit::from).collect())
    }
}

impl From<ImageHit> for CoreImageHit {
    fn from(hit: ImageHit) -> Self {
        Self {
            event_id: hit.event_id.to_string(),
            room_id: hit.room_id.to_string(),
            sender_name: hit.sender_name,
            date: hit.date,
            is_own: hit.is_own,
            reason: match hit.reason {
                ImageReason::Words { excerpt, matches } => CoreImageReason::Words {
                    excerpt,
                    matches: matched(matches),
                },
                ImageReason::Nearby { excerpt, matches } => CoreImageReason::Nearby {
                    excerpt,
                    matches: matched(matches),
                },
                ImageReason::Looks { similarity } => CoreImageReason::Looks { similarity },
            },
        }
    }
}

fn matched(ranges: Vec<std::ops::Range<u32>>) -> Vec<CoreStoreMatch> {
    ranges
        .into_iter()
        .map(|range| CoreStoreMatch {
            start: range.start,
            length: range.end - range.start,
        })
        .collect()
}

impl From<Hit> for CoreStoreHit {
    fn from(hit: Hit) -> Self {
        Self {
            event_id: hit.event_id.to_string(),
            room_id: hit.room_id.to_string(),
            sender_name: hit.sender_name,
            excerpt: hit.excerpt,
            matches: matched(hit.matches),
            date: hit.date,
            is_own: hit.is_own,
        }
    }
}
