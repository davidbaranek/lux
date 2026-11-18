//! What can go wrong.

use std::io;

use rusqlite::ErrorCode;

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
    /// The file is damaged: SQLite finds it malformed, or a page fails SQLCipher's check (a page
    /// written with another key, or not written whole), or its schema is not the one its version
    /// says.
    #[error("the store's file is damaged")]
    Damaged,
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
    /// SQLite's error on the first read, read as the store's: a file the key does not open is
    /// `Unreadable`, a malformed one `Damaged`.
    pub(crate) fn from_sqlite(error: rusqlite::Error) -> Self {
        match error.sqlite_error_code() {
            Some(ErrorCode::NotADatabase) => Self::Unreadable,
            Some(ErrorCode::DatabaseCorrupt) => Self::Damaged,
            _ => Self::Sqlite(error),
        }
    }

    /// Whether the file is one the store cannot use (another key, not a database, a newer app's,
    /// damaged), as opposed to a failure of the disk or the system around it.
    pub(crate) fn is_unusable_file(&self) -> bool {
        matches!(self, Self::Unreadable | Self::NewerSchema { .. } | Self::Damaged)
    }

    /// This error, `Damaged` if it says so of the file. SQLCipher reports a page that fails its
    /// check (in the file or in its write-ahead log) as SQLite's "out of memory": SQLite's own
    /// allocations do not fail on the apps' platforms (the system ends the app first), so the
    /// store reads that error as a damaged page.
    pub(crate) fn examined(self) -> Self {
        let Self::Sqlite(error) = &self else { return self };
        match error.sqlite_error_code() {
            Some(ErrorCode::DatabaseCorrupt | ErrorCode::NotADatabase | ErrorCode::OutOfMemory) => Self::Damaged,
            _ => self,
        }
    }
}
