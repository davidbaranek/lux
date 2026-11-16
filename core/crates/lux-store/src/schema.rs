//! The schema, as numbered migrations: the file's `user_version` says how many it has.

use rusqlite::Connection;

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
    // files, and the thread each message replies in. Every chat is read again for them.
    "
    ALTER TABLE messages ADD COLUMN thread TEXT;
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
];

/// Brings the file's schema up to this version's, each migration in its own transaction.
pub(crate) fn migrate(connection: &mut Connection) -> Result<()> {
    let supported = u32::try_from(MIGRATIONS.len()).unwrap_or(u32::MAX);
    let found: u32 = connection.pragma_query_value(None, "user_version", |row| row.get(0))?;
    if found > supported {
        return Err(Error::NewerSchema { found, supported });
    }
    for (version, migration) in (found + 1..).zip(&MIGRATIONS[found as usize..]) {
        let transaction = connection.transaction()?;
        transaction.execute_batch(migration)?;
        transaction.pragma_update(None, "user_version", version)?;
        transaction.commit()?;
    }
    Ok(())
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
