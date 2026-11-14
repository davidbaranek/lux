//! What can go wrong.

use std::io;

/// A store's failure.
#[derive(Debug, thiserror::Error)]
pub enum Error {
    /// The key is not 64 hex digits.
    #[error("the key is not 64 hex digits")]
    InvalidKey,
    /// The file is not a database this key opens: another key, or not a database at all.
    #[error("the file is not a database this key opens")]
    Unreadable,
    /// The SQLite the library links does not encrypt: the file would be written in the clear.
    #[error("the linked SQLite is not SQLCipher")]
    NotEncrypted,
    /// The file was written by a newer version of the app.
    #[error("the store's schema {found} is newer than this version's {supported}")]
    NewerSchema {
        /// The file's schema version.
        found: u32,
        /// The newest this version knows.
        supported: u32,
    },
    /// The store's thread has ended (it could not start, or it panicked).
    #[error("the store is closed")]
    Closed,
    /// The file or its folder.
    #[error(transparent)]
    Io(#[from] io::Error),
    /// SQLite itself.
    #[error(transparent)]
    Sqlite(#[from] rusqlite::Error),
}

impl Error {
    /// SQLite's error, read as the store's: a file the key does not open is `Unreadable`.
    pub(crate) fn from_sqlite(error: rusqlite::Error) -> Self {
        match error.sqlite_error_code() {
            Some(rusqlite::ErrorCode::NotADatabase) => Self::Unreadable,
            _ => Self::Sqlite(error),
        }
    }
}
