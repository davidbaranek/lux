//! The store and its calls.

use std::collections::HashMap;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::time::SystemTime;

use lux_core::ids::{EventId, RoomId};
use lux_core::timeline::{IndexedFile, IndexedImage, IndexedMessage};
use rusqlite::functions::FunctionFlags;
use rusqlite::{Connection, OptionalExtension, params};

use crate::connection::Worker;
use crate::embedding;
use crate::search::{Ranked, fuse, query, unmark};
use crate::types::{from_millis, to_millis};
use crate::{
    Browse, Error, FileHit, Hit, ImageCounts, ImageHit, ImageRead, ImageReason, ImageSearch, IndexedChat, Key, LinkHit,
    MessageEmbedding, Result, TextSearch, ThreadHit, schema,
};

/// Adds a message, or changes its text and sender (an edit keeps its event id); an unchanged
/// message writes nothing, so the index does not grow its deleted rows.
const UPSERT_MESSAGE: &str = "
    INSERT INTO messages(event_id, room_id, sender, body, ts, own, thread) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
    ON CONFLICT(event_id) DO UPDATE SET body = excluded.body, sender = excluded.sender, thread = excluded.thread,
        embedding = iif(body = excluded.body, embedding, NULL), embedder = iif(body = excluded.body, embedder, NULL)
    WHERE body != excluded.body OR sender != excluded.sender OR thread IS NOT excluded.thread";

/// The messages whose meaning is most like the query's embedding (`?1`), at least `?3` alike.
const SEARCH_MEANING: &str = "
    SELECT event_id, room_id, sender, body, ts, own, similarity(embedding, ?1) AS alike FROM messages
    WHERE embedding IS NOT NULL AND (?2 IS NULL OR room_id = ?2) AND alike >= ?3
    ORDER BY alike DESC LIMIT ?4";

/// How long a found message's excerpt is when it was found by its meaning, not by its words.
const MEANING_EXCERPT: usize = 160;

/// Adds a file, or changes its name and sender.
const UPSERT_FILE: &str = "
    INSERT INTO files(event_id, room_id, sender, name, size, mimetype, ts, own) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
    ON CONFLICT(event_id) DO UPDATE SET name = excluded.name, sender = excluded.sender
    WHERE name != excluded.name OR sender != excluded.sender";

/// The photos, the newest first.
const LIST_IMAGES: &str = "
    SELECT event_id, room_id, sender, ts, own FROM images
    WHERE ?1 IS NULL OR room_id = ?1 ORDER BY ts DESC LIMIT ?2 OFFSET ?3";

/// The addresses messages sent, the newest first; with words (`?1`), those of the messages that
/// have them.
const LIST_LINKS: &str = "
    SELECT m.event_id, m.room_id, m.sender, l.url, m.body, m.ts, m.own
    FROM links l JOIN messages m ON m.event_id = l.event_id
    WHERE (?1 IS NULL OR m.id IN (SELECT rowid FROM messages_fts WHERE messages_fts MATCH ?1))
    AND (?2 IS NULL OR m.room_id = ?2)
    ORDER BY m.ts DESC, l.url LIMIT ?3 OFFSET ?4";

/// The files, the newest first; with words (`?1`), those whose name has them.
const LIST_FILES: &str = "
    SELECT event_id, room_id, sender, name, size, mimetype, ts, own FROM files
    WHERE (?1 IS NULL OR id IN (SELECT rowid FROM files_fts WHERE files_fts MATCH ?1))
    AND (?2 IS NULL OR room_id = ?2)
    ORDER BY ts DESC LIMIT ?3 OFFSET ?4";

/// The threads, by their newest reply, the newest first: each with its root when the index holds
/// it; with words (`?1`), those whose root or a reply has them.
const LIST_THREADS: &str = "
    WITH replies AS (
        SELECT thread, room_id, count(*) AS replies, max(ts) AS latest FROM messages
        WHERE thread IS NOT NULL AND (?2 IS NULL OR room_id = ?2)
        AND (?1 IS NULL OR thread IN (
            SELECT coalesce(m.thread, m.event_id) FROM messages_fts JOIN messages m ON m.id = messages_fts.rowid
            WHERE messages_fts MATCH ?1))
        GROUP BY thread ORDER BY latest DESC LIMIT ?3 OFFSET ?4)
    SELECT r.thread, r.room_id, root.sender, root.body, r.replies, newest.sender, newest.body, r.latest
    FROM replies r
    LEFT JOIN messages root ON root.event_id = r.thread
    JOIN messages newest ON newest.id = (
        SELECT id FROM messages WHERE thread = r.thread ORDER BY ts DESC LIMIT 1)
    ORDER BY r.latest DESC";

/// The messages that match, newest first, each with its text around the found words; the
/// markers are `search::OPEN` and `search::CLOSE`.
const SEARCH: &str = "
    SELECT m.event_id, m.room_id, m.sender, snippet(messages_fts, 0, '\u{E000}', '\u{E001}', '…', 24), m.ts, m.own
    FROM messages_fts JOIN messages m ON m.id = messages_fts.rowid
    WHERE messages_fts MATCH ?1 AND (?2 IS NULL OR m.room_id = ?2)
    ORDER BY m.ts DESC LIMIT ?3";

/// Adds a photo, or changes its caption and sender; what was read in it stays.
const UPSERT_IMAGE: &str = "
    INSERT INTO images(event_id, room_id, sender, caption, ts, own) VALUES (?1, ?2, ?3, ?4, ?5, ?6)
    ON CONFLICT(event_id) DO UPDATE SET caption = excluded.caption, sender = excluded.sender
    WHERE caption != excluded.caption OR sender != excluded.sender";

/// A photo the apps read three times without an answer (deleted, never decrypted) is not asked
/// for again.
const MAX_TRIES: u32 = 3;

/// How near a message is to a photo for its words to find the photo: sent within two minutes of
/// it, before or after (a photo's description, a reply to it).
const NEARBY_MILLIS: i64 = 2 * 60 * 1000;

/// The photos whose caption or words match, best first.
const SEARCH_IMAGE_WORDS: &str = "
    SELECT i.event_id, i.room_id, i.sender, i.ts, i.own, snippet(images_fts, -1, '\u{E000}', '\u{E001}', '…', 16)
    FROM images_fts JOIN images i ON i.id = images_fts.rowid
    WHERE images_fts MATCH ?1 AND (?2 IS NULL OR i.room_id = ?2)
    ORDER BY rank LIMIT ?3";

/// The photos sent near a message that matches, the best message first.
const SEARCH_IMAGES_NEARBY: &str = "
    SELECT i.event_id, i.room_id, i.sender, i.ts, i.own, snippet(messages_fts, 0, '\u{E000}', '\u{E001}', '…', 16)
    FROM messages_fts JOIN messages m ON m.id = messages_fts.rowid
    JOIN images i ON i.room_id = m.room_id AND i.ts BETWEEN m.ts - ?4 AND m.ts + ?4
    WHERE messages_fts MATCH ?1 AND (?2 IS NULL OR m.room_id = ?2)
    ORDER BY rank LIMIT ?3";

/// The photos that look most like the query's embedding, at least `?3` alike.
const SEARCH_IMAGE_LOOKS: &str = "
    SELECT event_id, room_id, sender, ts, own, similarity(embedding, ?1) AS alike FROM images
    WHERE embedding IS NOT NULL AND (?2 IS NULL OR room_id = ?2) AND alike >= ?3
    ORDER BY alike DESC LIMIT ?4";

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
                    let mut forget_links = transaction.prepare_cached("DELETE FROM links WHERE event_id = ?1")?;
                    let mut link =
                        transaction.prepare_cached("INSERT OR IGNORE INTO links(event_id, url) VALUES (?1, ?2)")?;
                    for message in &messages {
                        statement.execute(params![
                            message.event_id.as_str(),
                            message.room.as_str(),
                            message.sender_name,
                            message.body,
                            to_millis(message.date),
                            message.is_own,
                            message.thread.as_ref().map(EventId::as_str),
                        ])?;
                        // an edit may have changed them.
                        forget_links.execute([message.event_id.as_str()])?;
                        for url in &message.links {
                            link.execute(params![message.event_id.as_str(), url])?;
                        }
                    }
                }
                transaction.commit()?;
                Ok(())
            })
            .await
    }

    /// Removes messages (deleted in their chat), photos and files too; the index forgets their
    /// text, links and what was read in them.
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
                    let mut messages = transaction.prepare_cached("DELETE FROM messages WHERE event_id = ?1")?;
                    let mut images = transaction.prepare_cached("DELETE FROM images WHERE event_id = ?1")?;
                    let mut files = transaction.prepare_cached("DELETE FROM files WHERE event_id = ?1")?;
                    for event in &events {
                        messages.execute([event.as_str()])?;
                        images.execute([event.as_str()])?;
                        files.execute([event.as_str()])?;
                    }
                }
                transaction.commit()?;
                Ok(())
            })
            .await
    }

    /// Adds photos, or changes their captions, in one transaction.
    ///
    /// # Errors
    /// SQLite's, or [`Error::Closed`].
    pub async fn add_images(&self, images: Vec<IndexedImage>) -> Result<()> {
        if images.is_empty() {
            return Ok(());
        }
        self.worker
            .run(move |connection| {
                let transaction = connection.transaction()?;
                {
                    let mut statement = transaction.prepare_cached(UPSERT_IMAGE)?;
                    for image in &images {
                        statement.execute(params![
                            image.event_id.as_str(),
                            image.room.as_str(),
                            image.sender_name,
                            image.caption,
                            to_millis(image.date),
                            image.is_own,
                        ])?;
                    }
                }
                transaction.commit()?;
                Ok(())
            })
            .await
    }

    /// Adds files, or changes their names, in one transaction.
    ///
    /// # Errors
    /// SQLite's, or [`Error::Closed`].
    pub async fn add_files(&self, files: Vec<IndexedFile>) -> Result<()> {
        if files.is_empty() {
            return Ok(());
        }
        self.worker
            .run(move |connection| {
                let transaction = connection.transaction()?;
                {
                    let mut statement = transaction.prepare_cached(UPSERT_FILE)?;
                    for file in &files {
                        statement.execute(params![
                            file.event_id.as_str(),
                            file.room.as_str(),
                            file.sender_name,
                            file.name,
                            file.size.and_then(|size| i64::try_from(size).ok()),
                            file.mimetype,
                            to_millis(file.date),
                            file.is_own,
                        ])?;
                    }
                }
                transaction.commit()?;
                Ok(())
            })
            .await
    }

    /// The photos, the newest first, a page of them (`browse`'s words are not looked at: a search
    /// by words is [`Store::search_images`]).
    ///
    /// # Errors
    /// SQLite's, or [`Error::Closed`].
    pub async fn images(&self, browse: Browse) -> Result<Vec<ImageHit>> {
        self.worker
            .run(move |connection| {
                let mut statement = connection.prepare_cached(LIST_IMAGES)?;
                let rows = statement.query_map(
                    params![browse.room_id.as_ref().map(RoomId::as_str), browse.limit, browse.offset],
                    |row| {
                        Ok(ImageHit {
                            event_id: EventId::from(row.get::<_, String>(0)?),
                            room_id: RoomId::from(row.get::<_, String>(1)?),
                            sender_name: row.get(2)?,
                            date: from_millis(row.get(3)?),
                            is_own: row.get(4)?,
                            reason: ImageReason::Listed,
                        })
                    },
                )?;
                Ok(rows.collect::<rusqlite::Result<_>>()?)
            })
            .await
    }

    /// The web addresses messages sent, the newest first: all, or those of the messages with
    /// every word of `browse.text`.
    ///
    /// # Errors
    /// SQLite's, or [`Error::Closed`].
    pub async fn links(&self, browse: Browse) -> Result<Vec<LinkHit>> {
        let words = query(&browse.text);
        self.worker
            .run(move |connection| {
                let mut statement = connection.prepare_cached(LIST_LINKS)?;
                let rows = statement.query_map(
                    params![
                        words,
                        browse.room_id.as_ref().map(RoomId::as_str),
                        browse.limit,
                        browse.offset
                    ],
                    |row| {
                        Ok(LinkHit {
                            event_id: EventId::from(row.get::<_, String>(0)?),
                            room_id: RoomId::from(row.get::<_, String>(1)?),
                            sender_name: row.get(2)?,
                            url: row.get(3)?,
                            text: row.get(4)?,
                            date: from_millis(row.get(5)?),
                            is_own: row.get(6)?,
                        })
                    },
                )?;
                Ok(rows.collect::<rusqlite::Result<_>>()?)
            })
            .await
    }

    /// The files, the newest first: all, or those whose name has every word of `browse.text`.
    ///
    /// # Errors
    /// SQLite's, or [`Error::Closed`].
    pub async fn files(&self, browse: Browse) -> Result<Vec<FileHit>> {
        let words = query(&browse.text);
        self.worker
            .run(move |connection| {
                let mut statement = connection.prepare_cached(LIST_FILES)?;
                let rows = statement.query_map(
                    params![
                        words,
                        browse.room_id.as_ref().map(RoomId::as_str),
                        browse.limit,
                        browse.offset
                    ],
                    |row| {
                        Ok(FileHit {
                            event_id: EventId::from(row.get::<_, String>(0)?),
                            room_id: RoomId::from(row.get::<_, String>(1)?),
                            sender_name: row.get(2)?,
                            name: row.get(3)?,
                            size: row.get::<_, Option<i64>>(4)?.map(i64::unsigned_abs),
                            mimetype: row.get(5)?,
                            date: from_millis(row.get(6)?),
                            is_own: row.get(7)?,
                        })
                    },
                )?;
                Ok(rows.collect::<rusqlite::Result<_>>()?)
            })
            .await
    }

    /// The threads, by their newest reply, the newest first: all, or those whose root or a reply
    /// has every word of `browse.text`.
    ///
    /// # Errors
    /// SQLite's, or [`Error::Closed`].
    pub async fn threads(&self, browse: Browse) -> Result<Vec<ThreadHit>> {
        let words = query(&browse.text);
        self.worker
            .run(move |connection| {
                let mut statement = connection.prepare_cached(LIST_THREADS)?;
                let rows = statement.query_map(
                    params![
                        words,
                        browse.room_id.as_ref().map(RoomId::as_str),
                        browse.limit,
                        browse.offset
                    ],
                    |row| {
                        Ok(ThreadHit {
                            root: EventId::from(row.get::<_, String>(0)?),
                            room_id: RoomId::from(row.get::<_, String>(1)?),
                            root_sender: row.get(2)?,
                            root_text: row.get(3)?,
                            replies: row.get(4)?,
                            latest_sender: row.get(5)?,
                            latest_text: row.get(6)?,
                            latest: from_millis(row.get(7)?),
                        })
                    },
                )?;
                Ok(rows.collect::<rusqlite::Result<_>>()?)
            })
            .await
    }

    /// The photos `reader` has not read yet, the newest first, at most `limit`: each with its
    /// chat. A photo whose reading failed too often is left out, and so is one a reader that
    /// does more read (`covers`): the words-only reader leaves the model's photos as they are.
    ///
    /// # Errors
    /// SQLite's, or [`Error::Closed`].
    pub async fn images_to_read(&self, reader: String, limit: u32) -> Result<Vec<(EventId, RoomId)>> {
        self.worker
            .run(move |connection| {
                let mut statement = connection.prepare_cached(
                    "SELECT event_id, room_id FROM images WHERE NOT covers(?1, reader) AND tries < ?2 \
                     ORDER BY ts DESC LIMIT ?3",
                )?;
                let rows = statement.query_map(params![reader, MAX_TRIES, limit], |row| {
                    Ok((
                        EventId::from(row.get::<_, String>(0)?),
                        RoomId::from(row.get::<_, String>(1)?),
                    ))
                })?;
                Ok(rows.collect::<rusqlite::Result<_>>()?)
            })
            .await
    }

    /// Keeps what the apps read in photos, in one transaction.
    ///
    /// # Errors
    /// SQLite's, or [`Error::Closed`].
    pub async fn set_images_read(&self, reads: Vec<ImageRead>) -> Result<()> {
        if reads.is_empty() {
            return Ok(());
        }
        self.worker
            .run(move |connection| {
                let transaction = connection.transaction()?;
                {
                    let mut statement = transaction.prepare_cached(
                        "UPDATE images SET reader = ?2, words = ?3, embedding = ?4, tries = 0 WHERE event_id = ?1",
                    )?;
                    for read in &reads {
                        statement.execute(params![
                            read.event_id.as_str(),
                            read.reader,
                            read.words,
                            read.embedding.as_deref().map(embedding::kept),
                        ])?;
                    }
                }
                transaction.commit()?;
                Ok(())
            })
            .await
    }

    /// Counts a failed reading of a photo; after a few, it is not asked for again.
    ///
    /// # Errors
    /// SQLite's, or [`Error::Closed`].
    pub async fn image_unread(&self, event_id: EventId) -> Result<()> {
        self.worker
            .run(move |connection| {
                connection
                    .prepare_cached("UPDATE images SET tries = tries + 1 WHERE event_id = ?1")?
                    .execute([event_id.as_str()])?;
                Ok(())
            })
            .await
    }

    /// Gives every photo that could not be read its tries back: the reasons may be gone (the
    /// model is another, the photo downloads now), so they are asked for again.
    ///
    /// # Errors
    /// SQLite's, or [`Error::Closed`].
    pub async fn retry_unread_images(&self) -> Result<()> {
        self.worker
            .run(|connection| {
                connection
                    .prepare_cached("UPDATE images SET tries = 0 WHERE tries > 0")?
                    .execute([])?;
                Ok(())
            })
            .await
    }

    /// Forgets every photo's embedding (search by how photos look turned off), and keeps their
    /// words as read by `reader`: the reader without the model, so they are not read again.
    ///
    /// # Errors
    /// SQLite's, or [`Error::Closed`].
    pub async fn forget_image_embeddings(&self, reader: String) -> Result<()> {
        self.worker
            .run(move |connection| {
                connection
                    .prepare_cached("UPDATE images SET embedding = NULL, reader = ?1 WHERE reader IS NOT NULL")?
                    .execute([reader])?;
                Ok(())
            })
            .await
    }

    /// How many photos the index has, how many `reader` has read, how many had their words read
    /// and how many have an embedding.
    ///
    /// # Errors
    /// SQLite's, or [`Error::Closed`].
    pub async fn image_counts(&self, reader: String) -> Result<ImageCounts> {
        self.worker
            .run(move |connection| {
                let counts: [i64; 4] = connection
                    .prepare_cached(
                        "SELECT count(*), count(*) FILTER (WHERE covers(?1, reader) OR tries >= ?2), count(reader), \
                         count(embedding) FROM images",
                    )?
                    .query_row(params![reader, MAX_TRIES], |row| {
                        Ok([row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?])
                    })?;
                let [total, read, with_words, with_embedding] = counts.map(i64::unsigned_abs);
                Ok(ImageCounts {
                    total,
                    read,
                    with_words,
                    with_embedding,
                })
            })
            .await
    }

    /// The photos that match: by their caption and the words in them, by the messages sent near
    /// them, and by how they look (when the search has an embedding); the best first.
    ///
    /// # Errors
    /// SQLite's, or [`Error::Closed`].
    pub async fn search_images(&self, search: ImageSearch) -> Result<Vec<ImageHit>> {
        let words = query(&search.text);
        if words.is_none() && search.embedding.is_none() {
            return Ok(Vec::new());
        }
        self.worker
            .run(move |connection| {
                let room = search.room_id.as_ref().map(RoomId::as_str);
                let mut rankings: Vec<Ranked<ImageHit>> = Vec::with_capacity(3);
                if let Some(words) = &words {
                    let excerpt = |row: &rusqlite::Row<'_>| -> rusqlite::Result<(String, Vec<std::ops::Range<u32>>)> {
                        Ok(unmark(&row.get::<_, String>(5)?))
                    };
                    let mut statement = connection.prepare_cached(SEARCH_IMAGE_WORDS)?;
                    rankings.push(image_hits(
                        statement.query(params![words, room, search.limit])?,
                        |row| excerpt(row).map(|(excerpt, matches)| ImageReason::Words { excerpt, matches }),
                    )?);
                    let mut statement = connection.prepare_cached(SEARCH_IMAGES_NEARBY)?;
                    rankings.push(image_hits(
                        statement.query(params![words, room, search.limit, NEARBY_MILLIS])?,
                        |row| excerpt(row).map(|(excerpt, matches)| ImageReason::Nearby { excerpt, matches }),
                    )?);
                }
                if let Some(query) = &search.embedding {
                    let mut statement = connection.prepare_cached(SEARCH_IMAGE_LOOKS)?;
                    rankings.push(image_hits(
                        statement.query(params![
                            embedding::query_bytes(query),
                            room,
                            f64::from(search.min_similarity),
                            search.limit
                        ])?,
                        |row| {
                            // a cosine within ±1 fits a 32-bit float.
                            #[allow(clippy::cast_possible_truncation)]
                            let similarity = row.get::<_, f64>(5)? as f32;
                            Ok(ImageReason::Looks { similarity })
                        },
                    )?);
                }
                Ok(fuse(rankings, search.limit as usize))
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

    /// Closes the store for good, after the calls made before: later calls fail with
    /// [`Error::Closed`]. Awaited, it blocks no thread while the connection closes, which
    /// dropping the last handle without it does.
    pub async fn close(&self) {
        self.worker.close().await;
    }

    /// Forgets a chat's messages, photos and files: up to `until` (the chat was deleted then), or all of them and
    /// how far the index read it (`None`: the chat is gone from the account's list).
    ///
    /// # Errors
    /// SQLite's, or [`Error::Closed`].
    pub async fn forget_chat(&self, room_id: RoomId, until: Option<SystemTime>) -> Result<()> {
        self.worker
            .run(move |connection| {
                let transaction = connection.transaction()?;
                if let Some(until) = until {
                    for forget in [
                        "DELETE FROM messages WHERE room_id = ?1 AND ts <= ?2",
                        "DELETE FROM images WHERE room_id = ?1 AND ts <= ?2",
                        "DELETE FROM files WHERE room_id = ?1 AND ts <= ?2",
                    ] {
                        transaction
                            .prepare_cached(forget)?
                            .execute(params![room_id.as_str(), to_millis(until)])?;
                    }
                } else {
                    for forget in [
                        "DELETE FROM messages WHERE room_id = ?1",
                        "DELETE FROM images WHERE room_id = ?1",
                        "DELETE FROM files WHERE room_id = ?1",
                    ] {
                        transaction.prepare_cached(forget)?.execute([room_id.as_str()])?;
                    }
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
                    .prepare_cached(
                        "INSERT OR REPLACE INTO chats(room_id, newest, complete, oldest, older) VALUES (?1, ?2, ?3, ?4, ?5)",
                    )?
                    .execute(params![
                        room_id.as_str(),
                        to_millis(chat.newest),
                        chat.complete,
                        chat.oldest.map(to_millis),
                        chat.older
                    ])?;
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
                let mut statement =
                    connection.prepare_cached("SELECT room_id, newest, complete, oldest, older FROM chats")?;
                let rows = statement.query_map([], |row| {
                    Ok((
                        RoomId::from(row.get::<_, String>(0)?),
                        IndexedChat {
                            newest: from_millis(row.get(1)?),
                            complete: row.get(2)?,
                            oldest: row.get::<_, Option<i64>>(3)?.map(from_millis),
                            older: row.get(4)?,
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

    /// The messages with every word of `search.text`, each word matched by its start, without
    /// case or accents, the newest first; and, with the words' embedding, those whose meaning is
    /// like the words', the most alike first: the two merged, a message found by both first. At
    /// most `search.limit`; `search.room_id` keeps one chat's.
    ///
    /// # Errors
    /// SQLite's, or [`Error::Closed`].
    pub async fn search(&self, search: TextSearch) -> Result<Vec<Hit>> {
        let words = query(&search.text);
        if words.is_none() && search.embedding.is_none() {
            return Ok(Vec::new());
        }
        self.worker
            .run(move |connection| {
                let room = search.room_id.as_ref().map(RoomId::as_str);
                let mut rankings: Vec<Ranked<Hit>> = Vec::with_capacity(2);
                if let Some(words) = &words {
                    let mut statement = connection.prepare_cached(SEARCH)?;
                    let rows = statement.query_map(params![words, room, search.limit], |row| {
                        let (excerpt, matches) = unmark(&row.get::<_, String>(3)?);
                        hit(row, excerpt, matches)
                    })?;
                    rankings.push(ranked(rows)?);
                }
                if let Some(embedding) = &search.embedding {
                    let mut statement = connection.prepare_cached(SEARCH_MEANING)?;
                    let rows = statement.query_map(
                        params![
                            embedding::query_bytes(embedding),
                            room,
                            f64::from(search.min_similarity),
                            search.limit
                        ],
                        |row| {
                            let body: String = row.get(3)?;
                            let excerpt = match body.char_indices().nth(MEANING_EXCERPT) {
                                Some((end, _)) => format!("{}…", body.get(..end).unwrap_or_default()),
                                None => body,
                            };
                            hit(row, excerpt, Vec::new())
                        },
                    )?;
                    rankings.push(ranked(rows)?);
                }
                if rankings.len() == 1 {
                    return Ok(rankings.remove(0).into_iter().map(|(_, hit)| hit).collect());
                }
                Ok(fuse(rankings, search.limit as usize))
            })
            .await
    }

    /// Messages the index has not read the meaning of, the newest first, at most `limit`: each
    /// with its text. A message shorter than `min_chars` is left (too little to mean).
    ///
    /// # Errors
    /// SQLite's, or [`Error::Closed`].
    pub async fn messages_to_embed(&self, min_chars: u32, limit: u32) -> Result<Vec<(EventId, String)>> {
        self.worker
            .run(move |connection| {
                let mut statement = connection.prepare_cached(
                    "SELECT event_id, body FROM messages WHERE embedder IS NULL AND length(body) >= ?1 \
                     ORDER BY ts DESC LIMIT ?2",
                )?;
                let rows = statement.query_map(params![min_chars, limit], |row| {
                    Ok((EventId::from(row.get::<_, String>(0)?), row.get(1)?))
                })?;
                Ok(rows.collect::<rusqlite::Result<_>>()?)
            })
            .await
    }

    /// Keeps what a model read of messages' meaning, in one transaction.
    ///
    /// # Errors
    /// SQLite's, or [`Error::Closed`].
    pub async fn set_message_embeddings(&self, embeddings: Vec<MessageEmbedding>) -> Result<()> {
        if embeddings.is_empty() {
            return Ok(());
        }
        self.worker
            .run(move |connection| {
                let transaction = connection.transaction()?;
                {
                    let mut statement = transaction
                        .prepare_cached("UPDATE messages SET embedding = ?2, embedder = ?3 WHERE event_id = ?1")?;
                    for read in &embeddings {
                        statement.execute(params![
                            read.event_id.as_str(),
                            read.embedding.as_deref().map(embedding::kept),
                            read.embedder,
                        ])?;
                    }
                }
                transaction.commit()?;
                Ok(())
            })
            .await
    }

    /// Forgets the messages' embeddings but `keep`'s (the model that reads them now): search by
    /// meaning was turned off (`None`), or another model reads them again.
    ///
    /// # Errors
    /// SQLite's, or [`Error::Closed`].
    pub async fn forget_message_embeddings(&self, keep: Option<String>) -> Result<()> {
        self.worker
            .run(move |connection| {
                connection
                    .prepare_cached(
                        "UPDATE messages SET embedding = NULL, embedder = NULL \
                         WHERE embedder IS NOT NULL AND embedder IS NOT ?1",
                    )?
                    .execute([keep])?;
                Ok(())
            })
            .await
    }

    /// How many messages are long enough to have a meaning (`min_chars`), and how many of them the
    /// index has read the meaning of.
    ///
    /// # Errors
    /// SQLite's, or [`Error::Closed`].
    pub async fn embedding_counts(&self, min_chars: u32) -> Result<(u64, u64)> {
        self.worker
            .run(move |connection| {
                let counts: (i64, i64) = connection
                    .prepare_cached("SELECT count(*), count(embedder) FROM messages WHERE length(body) >= ?1")?
                    .query_row([min_chars], |row| Ok((row.get(0)?, row.get(1)?)))?;
                Ok((counts.0.unsigned_abs(), counts.1.unsigned_abs()))
            })
            .await
    }

    /// Forgets the whole search index (messages, photos, files, links, how far each chat is
    /// read) and gives its space back, keeping the kept values: the index moved to a store of
    /// its own, and this one keeps only what the app's extensions read.
    ///
    /// # Errors
    /// SQLite's, or [`Error::Closed`].
    pub async fn clear_index(&self) -> Result<()> {
        self.worker
            .run(|connection| {
                connection.execute_batch(
                    "BEGIN; DELETE FROM links; DELETE FROM messages; DELETE FROM images; DELETE FROM files; \
                     DELETE FROM chats; COMMIT; VACUUM;",
                )?;
                Ok(())
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
    // the raw key and salt (`x'…'`, hex digits only): no passphrase derivation, the key is already
    // random. The file's first 32 bytes stay plain ("SQLite format 3" and the page size): iOS knows
    // the file for a WAL database by them and lets a suspended app keep its lock in the shared
    // App Group folder; an encrypted header gets the app killed there (0xdead10cc), as Signal found.
    // A file written with an encrypted header no longer opens, and `open_or_replace` makes it anew.
    connection.execute_batch(&format!(
        "PRAGMA key = \"{}\"; PRAGMA cipher_plaintext_header_size = 32;",
        key.pragma_value()
    ))?;
    // plain SQLite ignores the key and would write the file in the clear; SQLCipher names itself.
    let cipher: Option<String> = connection
        .query_row("PRAGMA cipher_version", [], |row| row.get(0))
        .optional()?;
    if cipher.is_none() {
        return Err(Error::NotEncrypted);
    }
    // a wrong key fails here, on the first read. With the header plain, SQLite reads it as a
    // database's and only the first page's check fails, which SQLCipher reports as SQLITE_NOMEM;
    // a file with an encrypted header (or none at all) fails as SQLITE_NOTADB.
    connection
        .query_row("SELECT count(*) FROM sqlite_master", [], |_| Ok(()))
        .map_err(|error| match error.sqlite_error_code() {
            Some(rusqlite::ErrorCode::OutOfMemory) => Error::Unreadable,
            _ => Error::from_sqlite(error),
        })?;
    connection.execute_batch("PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL;")?;
    schema::migrate(&mut connection)?;
    embedding::register(&connection)?;
    register_covers(&connection)?;
    Ok(connection)
}

/// The photos a search's rows name, in their order, each with why `reason` says it was found.
fn image_hits(
    mut rows: rusqlite::Rows<'_>,
    reason: impl Fn(&rusqlite::Row<'_>) -> rusqlite::Result<ImageReason>,
) -> Result<Ranked<ImageHit>> {
    let mut hits: Ranked<ImageHit> = Vec::new();
    while let Some(row) = rows.next()? {
        let event_id: String = row.get(0)?;
        // a photo near two matching messages: found once, by the better.
        if hits.iter().any(|(id, _)| *id == event_id) {
            continue;
        }
        let hit = ImageHit {
            event_id: EventId::from(event_id.clone()),
            room_id: RoomId::from(row.get::<_, String>(1)?),
            sender_name: row.get(2)?,
            date: from_millis(row.get(3)?),
            is_own: row.get(4)?,
            reason: reason(row)?,
        };
        hits.push((event_id, hit));
    }
    Ok(hits)
}

/// A found message from its row: event, room, sender, (text), date, own.
fn hit(row: &rusqlite::Row<'_>, excerpt: String, matches: Vec<std::ops::Range<u32>>) -> rusqlite::Result<Hit> {
    Ok(Hit {
        event_id: EventId::from(row.get::<_, String>(0)?),
        room_id: RoomId::from(row.get::<_, String>(1)?),
        sender_name: row.get(2)?,
        excerpt,
        matches,
        date: from_millis(row.get(4)?),
        is_own: row.get(5)?,
    })
}

/// Found messages as a ranking to merge, by their event ids.
fn ranked(rows: impl Iterator<Item = rusqlite::Result<Hit>>) -> Result<Ranked<Hit>> {
    let mut ranking = Vec::new();
    for hit in rows {
        let hit = hit?;
        ranking.push((hit.event_id.to_string(), hit));
    }
    Ok(ranking)
}

/// The SQL function `covers(asked, reader)`: whether what `reader` read of a photo is all that
/// `asked` would read. A reader is named by what it does, the words' reader first and each further
/// reading after a `+` ("vision-text-1+siglip2@256"), so a reader covers itself and every reader
/// that extends it; NULL (never read) covers nothing.
fn register_covers(connection: &Connection) -> rusqlite::Result<()> {
    connection.create_scalar_function(
        "covers",
        2,
        FunctionFlags::SQLITE_UTF8 | FunctionFlags::SQLITE_DETERMINISTIC,
        |context| {
            let asked: String = context.get(0)?;
            let Some(reader) = context.get::<Option<String>>(1)? else {
                return Ok(false);
            };
            Ok(covers(&asked, &reader))
        },
    )
}

fn covers(asked: &str, reader: &str) -> bool {
    reader == asked || reader.strip_prefix(asked).is_some_and(|rest| rest.starts_with('+'))
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
