//! The account's own store on this device: one SQLite database encrypted with SQLCipher (AES-256,
//! a raw 32-byte key the app keeps in the Keychain), as Signal keeps its own.
//!
//! It holds the message search index (FTS5: a word matches by its start, without case or accents;
//! the newest messages first), the photos the apps read for photo search (their words and their
//! embeddings, compared on the store's thread), and a few kept values (the last chat list, drawn at
//! launch). The index is a cache: what it loses is read again from the server.
//!
//! One thread owns the connection ([`Store`] sends it jobs), so SQLite never blocks an async
//! runtime and statements stay prepared between calls.

mod connection;
mod embedding;
mod error;
mod exit;
mod key;
mod schema;
mod search;
mod store;
mod types;

pub use error::Error;
pub use key::Key;
pub use store::Store;
pub use types::{
    Browse, ContextMessage, FileHit, Hit, ImageCounts, ImageHit, ImageRead, ImageReason, ImageSearch, IndexedChat,
    LinkHit, MessageEmbedding, MessageToEmbed, TextSearch, ThreadHit,
};

/// What the store's calls return.
pub type Result<T, E = Error> = std::result::Result<T, E>;
