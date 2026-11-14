//! The SQLCipher this crate links is the only SQLite in the library, the sdk's included (Cargo
//! unifies `libsqlite3-sys`'s features). Without a key it must read and write plain SQLite files
//! as SQLite does: the sdk's stores have no key.

#![allow(clippy::unwrap_used, reason = "a test's helpers fail it as its asserts do")]

use std::path::Path;

use matrix_sdk_base::store::StateStore;
use matrix_sdk_sqlite::SqliteStateStore;
use rusqlite::Connection;
use tempfile::TempDir;

fn is_plain_sqlite(path: &Path) -> bool {
    std::fs::read(path).unwrap().starts_with(b"SQLite format 3\0")
}

#[test]
fn the_linked_sqlite_is_sqlcipher() {
    let connection = Connection::open_in_memory().unwrap();
    let version: String = connection
        .query_row("PRAGMA cipher_version", [], |row| row.get(0))
        .unwrap();
    assert!(version.starts_with('4'), "{version}");
}

#[test]
fn opens_a_file_plain_sqlite_wrote() {
    // `fixtures/plain.sqlite3`: made by the system's own sqlite3 (3.54), a table `kv` with one row.
    let folder = TempDir::new().unwrap();
    let path = folder.path().join("plain.sqlite3");
    std::fs::copy(
        concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fixtures/plain.sqlite3"),
        &path,
    )
    .unwrap();
    {
        let connection = Connection::open(&path).unwrap();
        let value: String = connection
            .query_row("SELECT value FROM kv WHERE key = 'written-by'", [], |row| row.get(0))
            .unwrap();
        assert_eq!(value, "plain sqlite");
        connection
            .execute_batch("PRAGMA journal_mode = WAL; INSERT INTO kv VALUES ('then', 'sqlcipher');")
            .unwrap();
    }
    let connection = Connection::open(&path).unwrap();
    let count: i64 = connection
        .query_row("SELECT count(*) FROM kv", [], |row| row.get(0))
        .unwrap();
    assert_eq!(count, 2);
    drop(connection);
    assert!(is_plain_sqlite(&path));
}

#[tokio::test]
async fn the_sdks_store_works_unkeyed() {
    let folder = TempDir::new().unwrap();
    {
        let store = SqliteStateStore::open(folder.path(), None).await.unwrap();
        store.set_custom_value(b"probe", b"value".to_vec()).await.unwrap();
    }
    let store = SqliteStateStore::open(folder.path(), None).await.unwrap();
    assert_eq!(
        store.get_custom_value(b"probe").await.unwrap().as_deref(),
        Some(&b"value"[..])
    );
    assert!(is_plain_sqlite(
        &folder.path().join(matrix_sdk_sqlite::STATE_STORE_DATABASE_NAME)
    ));
}
