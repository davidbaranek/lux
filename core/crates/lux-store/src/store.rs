//! The store and its calls.

use std::collections::HashMap;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::time::SystemTime;

use lux_core::ids::{EventId, RoomId};
use lux_core::timeline::IndexedMessage;
use rusqlite::{Connection, OptionalExtension, params};

use crate::connection::Worker;
use crate::search::{query, unmark};
use crate::types::{from_millis, to_millis};
use crate::{Error, Hit, IndexedChat, Key, Result, schema};

/// Adds a message, or changes its text and sender (an edit keeps its event id); an unchanged
/// message writes nothing, so the index does not grow its deleted rows.
const UPSERT_MESSAGE: &str = "
    INSERT INTO messages(event_id, room_id, sender, body, ts, own) VALUES (?1, ?2, ?3, ?4, ?5, ?6)
    ON CONFLICT(event_id) DO UPDATE SET body = excluded.body, sender = excluded.sender
    WHERE body != excluded.body OR sender != excluded.sender";

/// The messages that match, newest first, each with its text around the found words; the
/// markers are `search::OPEN` and `search::CLOSE`.
const SEARCH: &str = "
    SELECT m.event_id, m.room_id, m.sender, snippet(messages_fts, 0, '\u{E000}', '\u{E001}', '…', 24), m.ts, m.own
    FROM messages_fts JOIN messages m ON m.id = messages_fts.rowid
    WHERE messages_fts MATCH ?1 AND (?2 IS NULL OR m.room_id = ?2)
    ORDER BY m.ts DESC LIMIT ?3";

/// The account's encrypted store on this device. Cheap to share behind an `Arc`; each call runs
/// on the store's own thread, in the order sent.
#[derive(Debug)]
pub struct Store {
    worker: Worker,
}

impl Store {
    /// Opens the store at `path` with `key`, or makes it (and its folder).
    ///
    /// # Errors
    /// [`Error::Unreadable`] when `key` does not open the file, [`Error::NotEncrypted`] when the
    /// library links plain SQLite, [`Error::NewerSchema`] for a newer app's file, and the file's
    /// and SQLite's own errors.
    pub async fn open(path: impl Into<PathBuf>, key: Key) -> Result<Self> {
        let path = path.into();
        let worker = Worker::start(move || connect(&path, &key)).await?;
        Ok(Self { worker })
    }

    /// Opens the store, or replaces a file it cannot read (another key, a newer app's, not a
    /// database) with a new one: the store is a cache, and what it held is read again.
    ///
    /// # Errors
    /// As [`Store::open`], but for a file it replaced.
    pub async fn open_or_replace(path: impl Into<PathBuf>, key: Key) -> Result<Self> {
        let path = path.into();
        match Self::open(path.clone(), key.clone()).await {
            Err(Error::Unreadable | Error::NewerSchema { .. }) => {
                remove_database(&path)?;
                Self::open(path, key).await
            }
            opened => opened,
        }
    }

    /// Adds messages, or changes them (an edit keeps its event id), in one transaction.
    ///
    /// # Errors
    /// SQLite's, or [`Error::Closed`].
    pub async fn add(&self, messages: Vec<IndexedMessage>) -> Result<()> {
        if messages.is_empty() {
            return Ok(());
        }
        self.worker
            .run(move |connection| {
                let transaction = connection.transaction()?;
                {
                    let mut statement = transaction.prepare_cached(UPSERT_MESSAGE)?;
                    for message in &messages {
                        statement.execute(params![
                            message.event_id.as_str(),
                            message.room.as_str(),
                            message.sender_name,
                            message.body,
                            to_millis(message.date),
                            message.is_own,
                        ])?;
                    }
                }
                transaction.commit()?;
                Ok(())
            })
            .await
    }

    /// Removes messages (deleted in their chat); the index forgets their text.
    ///
    /// # Errors
    /// SQLite's, or [`Error::Closed`].
    pub async fn remove(&self, events: Vec<EventId>) -> Result<()> {
        if events.is_empty() {
            return Ok(());
        }
        self.worker
            .run(move |connection| {
                let transaction = connection.transaction()?;
                {
                    let mut statement = transaction.prepare_cached("DELETE FROM messages WHERE event_id = ?1")?;
                    for event in &events {
                        statement.execute([event.as_str()])?;
                    }
                }
                transaction.commit()?;
                Ok(())
            })
            .await
    }

    /// Closes the file until the next call: the app goes to the background, where iOS ends an
    /// app that holds a lock on a file in a shared container.
    ///
    /// # Errors
    /// [`Error::Closed`].
    pub async fn release(&self) -> Result<()> {
        self.worker.release().await
    }

    /// Forgets a chat's messages: up to `until` (the chat was deleted then), or all of them and
    /// how far the index read it (`None`: the chat is gone from the account's list).
    ///
    /// # Errors
    /// SQLite's, or [`Error::Closed`].
    pub async fn forget_chat(&self, room_id: RoomId, until: Option<SystemTime>) -> Result<()> {
        self.worker
            .run(move |connection| {
                let transaction = connection.transaction()?;
                if let Some(until) = until {
                    transaction
                        .prepare_cached("DELETE FROM messages WHERE room_id = ?1 AND ts <= ?2")?
                        .execute(params![room_id.as_str(), to_millis(until)])?;
                } else {
                    transaction
                        .prepare_cached("DELETE FROM messages WHERE room_id = ?1")?
                        .execute([room_id.as_str()])?;
                    transaction
                        .prepare_cached("DELETE FROM chats WHERE room_id = ?1")?
                        .execute([room_id.as_str()])?;
                }
                transaction.commit()?;
                Ok(())
            })
            .await
    }

    /// Keeps how far the index has read a chat.
    ///
    /// # Errors
    /// SQLite's, or [`Error::Closed`].
    pub async fn set_chat(&self, room_id: RoomId, chat: IndexedChat) -> Result<()> {
        self.worker
            .run(move |connection| {
                connection
                    .prepare_cached("INSERT OR REPLACE INTO chats(room_id, newest, complete) VALUES (?1, ?2, ?3)")?
                    .execute(params![room_id.as_str(), to_millis(chat.newest), chat.complete])?;
                Ok(())
            })
            .await
    }

    /// How far the index has read each chat.
    ///
    /// # Errors
    /// SQLite's, or [`Error::Closed`].
    pub async fn chats(&self) -> Result<HashMap<RoomId, IndexedChat>> {
        self.worker
            .run(|connection| {
                let mut statement = connection.prepare_cached("SELECT room_id, newest, complete FROM chats")?;
                let rows = statement.query_map([], |row| {
                    Ok((
                        RoomId::from(row.get::<_, String>(0)?),
                        IndexedChat {
                            newest: from_millis(row.get(1)?),
                            complete: row.get(2)?,
                        },
                    ))
                })?;
                Ok(rows.collect::<rusqlite::Result<_>>()?)
            })
            .await
    }

    /// How many messages the index holds.
    ///
    /// # Errors
    /// SQLite's, or [`Error::Closed`].
    pub async fn message_count(&self) -> Result<u64> {
        self.worker
            .run(|connection| {
                let count: i64 = connection
                    .prepare_cached("SELECT count(*) FROM messages")?
                    .query_row([], |row| row.get(0))?;
                Ok(count.unsigned_abs())
            })
            .await
    }

    /// The messages with every word of `text`, each word matched by its start, without case or
    /// accents; the newest first, at most `limit`. `room_id` keeps one chat's.
    ///
    /// # Errors
    /// SQLite's, or [`Error::Closed`].
    pub async fn search(&self, text: &str, room_id: Option<RoomId>, limit: u32) -> Result<Vec<Hit>> {
        let Some(query) = query(text) else {
            return Ok(Vec::new());
        };
        self.worker
            .run(move |connection| {
                let mut statement = connection.prepare_cached(SEARCH)?;
                let rows = statement.query_map(params![query, room_id.as_ref().map(RoomId::as_str), limit], |row| {
                    let (excerpt, matches) = unmark(&row.get::<_, String>(3)?);
                    Ok(Hit {
                        event_id: EventId::from(row.get::<_, String>(0)?),
                        room_id: RoomId::from(row.get::<_, String>(1)?),
                        sender_name: row.get(2)?,
                        excerpt,
                        matches,
                        date: from_millis(row.get(4)?),
                        is_own: row.get(5)?,
                    })
                })?;
                Ok(rows.collect::<rusqlite::Result<_>>()?)
            })
            .await
    }

    /// Keeps a value (the last chat list), encrypted with the rest.
    ///
    /// # Errors
    /// SQLite's, or [`Error::Closed`].
    pub async fn keep(&self, key: String, value: Vec<u8>) -> Result<()> {
        self.worker
            .run(move |connection| {
                connection
                    .prepare_cached("INSERT OR REPLACE INTO kept(key, value) VALUES (?1, ?2)")?
                    .execute(params![key, value])?;
                Ok(())
            })
            .await
    }

    /// The value kept as `key`, if any.
    ///
    /// # Errors
    /// SQLite's, or [`Error::Closed`].
    pub async fn kept(&self, key: String) -> Result<Option<Vec<u8>>> {
        self.worker
            .run(move |connection| {
                Ok(connection
                    .prepare_cached("SELECT value FROM kept WHERE key = ?1")?
                    .query_row([key], |row| row.get(0))
                    .optional()?)
            })
            .await
    }
}

/// Opens the file with the key and brings its schema up to date.
fn connect(path: &Path, key: &Key) -> Result<Connection> {
    if let Some(folder) = path.parent() {
        fs::create_dir_all(folder)?;
    }
    let mut connection = Connection::open(path)?;
    // the raw key (`x'…'`, hex digits only): no passphrase derivation, the key is already random.
    connection.execute_batch(&format!("PRAGMA key = \"{}\";", key.pragma_value()))?;
    // plain SQLite ignores the key and would write the file in the clear; SQLCipher names itself.
    let cipher: Option<String> = connection
        .query_row("PRAGMA cipher_version", [], |row| row.get(0))
        .optional()?;
    if cipher.is_none() {
        return Err(Error::NotEncrypted);
    }
    // a wrong key fails here, on the first read.
    connection
        .query_row("SELECT count(*) FROM sqlite_master", [], |_| Ok(()))
        .map_err(Error::from_sqlite)?;
    connection.execute_batch("PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL;")?;
    schema::migrate(&mut connection)?;
    Ok(connection)
}

/// Removes a database and its journal files.
fn remove_database(path: &Path) -> Result<()> {
    for suffix in ["", "-wal", "-shm"] {
        let mut file = path.as_os_str().to_owned();
        file.push(suffix);
        match fs::remove_file(&file) {
            Err(error) if error.kind() != io::ErrorKind::NotFound => return Err(error.into()),
            _ => {}
        }
    }
    Ok(())
}
