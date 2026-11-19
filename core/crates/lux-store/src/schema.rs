//! The schema, as numbered migrations: the file's `user_version` says how many it has.

use rusqlite::{Connection, TransactionBehavior};

use crate::{Error, Result};

/// The migrations, in order; the file's version is how many ran. Never edit one that shipped: add
/// the next.
const MIGRATIONS: &[&str] = &[
    // 1: the index and the kept values.
    "
    CREATE TABLE messages(
        id INTEGER PRIMARY KEY, event_id TEXT NOT NULL UNIQUE, room_id TEXT NOT NULL,
        sender TEXT NOT NULL, body TEXT NOT NULL, ts INTEGER NOT NULL, own INTEGER NOT NULL);
    CREATE INDEX messages_by_room ON messages(room_id, ts);
    CREATE VIRTUAL TABLE messages_fts USING fts5(
        body, sender, content='messages', content_rowid='id',
        tokenize='unicode61 remove_diacritics 2', prefix='2 3');
    CREATE TRIGGER messages_added AFTER INSERT ON messages BEGIN
        INSERT INTO messages_fts(rowid, body, sender) VALUES (new.id, new.body, new.sender);
    END;
    CREATE TRIGGER messages_removed AFTER DELETE ON messages BEGIN
        INSERT INTO messages_fts(messages_fts, rowid, body, sender) VALUES ('delete', old.id, old.body, old.sender);
    END;
    CREATE TRIGGER messages_changed AFTER UPDATE ON messages BEGIN
        INSERT INTO messages_fts(messages_fts, rowid, body, sender) VALUES ('delete', old.id, old.body, old.sender);
        INSERT INTO messages_fts(rowid, body, sender) VALUES (new.id, new.body, new.sender);
    END;
    CREATE TABLE chats(room_id TEXT PRIMARY KEY, newest INTEGER NOT NULL, complete INTEGER NOT NULL);
    CREATE TABLE kept(key TEXT PRIMARY KEY, value BLOB NOT NULL);
    ",
    // 2: the photos: who sent them and their captions, from the history; what the apps read in
    // them (their words; their embedding, when search by look is on), and by which reader.
    "
    CREATE TABLE images(
        id INTEGER PRIMARY KEY, event_id TEXT NOT NULL UNIQUE, room_id TEXT NOT NULL,
        sender TEXT NOT NULL, caption TEXT NOT NULL, ts INTEGER NOT NULL, own INTEGER NOT NULL,
        words TEXT NOT NULL DEFAULT '', embedding BLOB, reader TEXT, tries INTEGER NOT NULL DEFAULT 0);
    CREATE INDEX images_by_room ON images(room_id, ts);
    CREATE VIRTUAL TABLE images_fts USING fts5(
        caption, words, content='images', content_rowid='id',
        tokenize='unicode61 remove_diacritics 2', prefix='2 3');
    CREATE TRIGGER images_added AFTER INSERT ON images BEGIN
        INSERT INTO images_fts(rowid, caption, words) VALUES (new.id, new.caption, new.words);
    END;
    CREATE TRIGGER images_removed AFTER DELETE ON images BEGIN
        INSERT INTO images_fts(images_fts, rowid, caption, words) VALUES ('delete', old.id, old.caption, old.words);
    END;
    CREATE TRIGGER images_changed AFTER UPDATE OF caption, words ON images BEGIN
        INSERT INTO images_fts(images_fts, rowid, caption, words) VALUES ('delete', old.id, old.caption, old.words);
        INSERT INTO images_fts(rowid, caption, words) VALUES (new.id, new.caption, new.words);
    END;
    -- the chats were read without their photos: read again (their messages, unchanged, write
    -- nothing).
    DELETE FROM chats;
    ",
    // 3: how far back each chat is read, to read on from there: as far as Settings asks, which
    // may be further than before. A chat read before is read again from its newest (what it
    // holds, unchanged, writes nothing), now to its start, not three months back.
    "
    ALTER TABLE chats ADD COLUMN oldest INTEGER;
    ALTER TABLE chats ADD COLUMN older TEXT;
    UPDATE chats SET complete = 0;
    ",
    // 4: what search lists besides messages and photos: the web addresses in messages, the
    // files, and the thread each message replies in; and each message's embedding, for search
    // by meaning, with the model that made it. Every chat is read again for them.
    "
    ALTER TABLE messages ADD COLUMN thread TEXT;
    ALTER TABLE messages ADD COLUMN embedding BLOB;
    ALTER TABLE messages ADD COLUMN embedder TEXT;
    CREATE INDEX messages_to_embed ON messages(ts) WHERE embedder IS NULL;
    CREATE INDEX messages_by_thread ON messages(thread) WHERE thread IS NOT NULL;
    CREATE TABLE links(event_id TEXT NOT NULL, url TEXT NOT NULL, PRIMARY KEY(event_id, url)) WITHOUT ROWID;
    CREATE TRIGGER messages_removed_links AFTER DELETE ON messages BEGIN
        DELETE FROM links WHERE event_id = old.event_id;
    END;
    CREATE TABLE files(
        id INTEGER PRIMARY KEY, event_id TEXT NOT NULL UNIQUE, room_id TEXT NOT NULL,
        sender TEXT NOT NULL, name TEXT NOT NULL, size INTEGER, mimetype TEXT,
        ts INTEGER NOT NULL, own INTEGER NOT NULL);
    CREATE INDEX files_by_room ON files(room_id, ts);
    CREATE INDEX files_by_time ON files(ts);
    CREATE VIRTUAL TABLE files_fts USING fts5(
        name, content='files', content_rowid='id',
        tokenize='unicode61 remove_diacritics 2', prefix='2 3');
    CREATE TRIGGER files_added AFTER INSERT ON files BEGIN
        INSERT INTO files_fts(rowid, name) VALUES (new.id, new.name);
    END;
    CREATE TRIGGER files_removed AFTER DELETE ON files BEGIN
        INSERT INTO files_fts(files_fts, rowid, name) VALUES ('delete', old.id, old.name);
    END;
    CREATE TRIGGER files_changed AFTER UPDATE OF name ON files BEGIN
        INSERT INTO files_fts(files_fts, rowid, name) VALUES ('delete', old.id, old.name);
        INSERT INTO files_fts(rowid, name) VALUES (new.id, new.name);
    END;
    DELETE FROM chats;
    ",
    // 5: a message's meaning is read with the messages before it (`store::CONTEXT_MESSAGES`,
    // four, here as each `LIMIT 4`): its thread's (the root and the replies before it) when it
    // is in one, else its chat's. A message added (an older page read after newer ones), changed
    // or deleted changes what the next four in its thread or chat were read with, and a thread's
    // root its first four replies': they are read again, in the change's own transaction. A
    // thread's replies are found by their thread and time, as the chat's are by their chat and
    // time, so neither looks through the other's.
    "
    DROP INDEX messages_by_thread;
    CREATE INDEX messages_by_thread ON messages(thread, ts) WHERE thread IS NOT NULL;
    CREATE TRIGGER messages_added_context AFTER INSERT ON messages BEGIN
        UPDATE messages SET embedding = NULL, embedder = NULL WHERE embedder IS NOT NULL AND id IN (
            SELECT id FROM messages WHERE new.thread IS NULL AND room_id = new.room_id AND thread IS NULL
            AND (ts, id) > (new.ts, new.id)
            ORDER BY ts, id LIMIT 4);
        UPDATE messages SET embedding = NULL, embedder = NULL WHERE embedder IS NOT NULL AND id IN (
            SELECT id FROM messages WHERE thread = new.thread AND (ts, id) > (new.ts, new.id)
            ORDER BY ts, id LIMIT 4);
        UPDATE messages SET embedding = NULL, embedder = NULL WHERE embedder IS NOT NULL AND id IN (
            SELECT id FROM messages WHERE new.thread IS NULL AND thread = new.event_id
            ORDER BY ts, id LIMIT 4);
    END;
    CREATE TRIGGER messages_removed_context AFTER DELETE ON messages BEGIN
        UPDATE messages SET embedding = NULL, embedder = NULL WHERE embedder IS NOT NULL AND id IN (
            SELECT id FROM messages WHERE old.thread IS NULL AND room_id = old.room_id AND thread IS NULL
            AND (ts, id) > (old.ts, old.id)
            ORDER BY ts, id LIMIT 4);
        UPDATE messages SET embedding = NULL, embedder = NULL WHERE embedder IS NOT NULL AND id IN (
            SELECT id FROM messages WHERE thread = old.thread AND (ts, id) > (old.ts, old.id)
            ORDER BY ts, id LIMIT 4);
        UPDATE messages SET embedding = NULL, embedder = NULL WHERE embedder IS NOT NULL AND id IN (
            SELECT id FROM messages WHERE old.thread IS NULL AND thread = old.event_id
            ORDER BY ts, id LIMIT 4);
    END;
    CREATE TRIGGER messages_changed_context AFTER UPDATE OF body, sender, thread ON messages
    WHEN old.body IS NOT new.body OR old.sender IS NOT new.sender OR old.thread IS NOT new.thread BEGIN
        UPDATE messages SET embedding = NULL, embedder = NULL WHERE embedder IS NOT NULL AND id IN (
            SELECT id FROM messages WHERE old.thread IS NULL AND room_id = old.room_id AND thread IS NULL
            AND (ts, id) > (old.ts, old.id)
            ORDER BY ts, id LIMIT 4);
        UPDATE messages SET embedding = NULL, embedder = NULL WHERE embedder IS NOT NULL AND id IN (
            SELECT id FROM messages WHERE thread = old.thread AND (ts, id) > (old.ts, old.id)
            ORDER BY ts, id LIMIT 4);
        UPDATE messages SET embedding = NULL, embedder = NULL WHERE embedder IS NOT NULL AND id IN (
            SELECT id FROM messages WHERE new.thread IS NULL AND room_id = new.room_id AND thread IS NULL
            AND (ts, id) > (new.ts, new.id)
            ORDER BY ts, id LIMIT 4);
        UPDATE messages SET embedding = NULL, embedder = NULL WHERE embedder IS NOT NULL AND id IN (
            SELECT id FROM messages WHERE thread = new.thread AND (ts, id) > (new.ts, new.id)
            ORDER BY ts, id LIMIT 4);
        UPDATE messages SET embedding = NULL, embedder = NULL WHERE embedder IS NOT NULL AND id IN (
            SELECT id FROM messages WHERE new.thread IS NULL AND thread = new.event_id
            ORDER BY ts, id LIMIT 4);
    END;
    ",
];

/// Brings the file's schema up to this version's, each migration in its own transaction. Two
/// processes may open the file at once (the app and its share extension): each migration takes
/// the write lock first and reads the version under it, so none runs twice.
pub(crate) fn migrate(connection: &mut Connection) -> Result<()> {
    let supported = u32::try_from(MIGRATIONS.len()).unwrap_or(u32::MAX);
    // read without a lock first: a file up to date, as nearly every open finds it, takes none.
    if version(connection, supported)? == supported {
        return Ok(());
    }
    loop {
        let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let found = version(&transaction, supported)?;
        let Some(migration) = MIGRATIONS.get(usize::try_from(found).unwrap_or(usize::MAX)) else {
            return Ok(());
        };
        // a migration that shipped runs on the schema of the version before it.
        transaction.execute_batch(migration).map_err(Error::Migration)?;
        transaction.pragma_update(None, "user_version", found + 1)?;
        transaction.commit()?;
    }
}

/// The file's schema version; a newer one than `supported` is an error.
fn version(connection: &Connection, supported: u32) -> Result<u32> {
    let found: u32 = connection.pragma_query_value(None, "user_version", |row| row.get(0))?;
    if found > supported {
        return Err(Error::NewerSchema { found, supported });
    }
    Ok(found)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn migrates_once_and_refuses_a_newer_file() {
        let mut connection = Connection::open_in_memory().unwrap();
        migrate(&mut connection).unwrap();
        migrate(&mut connection).unwrap();
        let version: u32 = connection
            .pragma_query_value(None, "user_version", |row| row.get(0))
            .unwrap();
        assert_eq!(version as usize, MIGRATIONS.len());

        connection.pragma_update(None, "user_version", 99).unwrap();
        assert!(matches!(
            migrate(&mut connection),
            Err(Error::NewerSchema { found: 99, .. })
        ));
    }
}
