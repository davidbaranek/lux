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
    /// A migration failed on the file's schema.
    #[error("the store's migration failed: {0}")]
    Migration(rusqlite::Error),
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

/// What an error says against the store's file.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub(crate) enum Evidence {
    /// Nothing: the disk, the system, the caller.
    None,
    /// The file cannot be used: another key, not a database, a newer app's, malformed.
    Proof,
    /// It may be damaged: SQLCipher reports a page that fails its check as SQLite's "out of
    /// memory", as it does a failed encryption and SQLite a failed allocation; a migration's SQL
    /// error may be another process's migration, done meanwhile.
    Suspicion,
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

    /// What this error says against the file.
    pub(crate) fn evidence(&self) -> Evidence {
        match self {
            Self::Unreadable | Self::NewerSchema { .. } | Self::Damaged => Evidence::Proof,
            Self::Migration(_) => Evidence::Suspicion,
            Self::Sqlite(error) => match error.sqlite_error_code() {
                Some(ErrorCode::DatabaseCorrupt | ErrorCode::NotADatabase) => Evidence::Proof,
                Some(ErrorCode::OutOfMemory) => Evidence::Suspicion,
                _ => Evidence::None,
            },
            Self::InvalidKey | Self::NotEncrypted | Self::Closed | Self::Io(_) => Evidence::None,
        }
    }

    /// SQLite's extended result code, if SQLite's error this is: what a log of the file's damage
    /// names (`SQLITE_CORRUPT_VTAB` for an FTS index out of step with its table).
    pub(crate) fn extended_code(&self) -> Option<i32> {
        match self {
            Self::Sqlite(error) | Self::Migration(error) => error.sqlite_error().map(|error| error.extended_code),
            _ => None,
        }
    }

    /// This error, for a file found damaged: SQLite's own is [`Error::Damaged`], the store's
    /// stays as it says.
    pub(crate) fn damage(self) -> Self {
        match self {
            Self::Sqlite(_) | Self::Migration(_) => Self::Damaged,
            other => other,
        }
    }
}
