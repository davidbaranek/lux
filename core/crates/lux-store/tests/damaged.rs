//! A file the store cannot use, made the honest way (a store written, then its bytes damaged): a
//! store that is a cache (`open_or_replace`) starts anew in its place, on opening or when a call
//! finds the damage, and an error of the disk around it leaves the file be.

#![allow(
    clippy::unwrap_used,
    clippy::indexing_slicing,
    reason = "a test's helpers fail it as its asserts do"
)]

use std::fs;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

use lux_core::timeline::IndexedMessage;
use lux_store::{Error, Key, Store, TextSearch};
use tempfile::TempDir;

const PAGE: usize = 4096;

fn key() -> Key {
    Key::from_hex(&"ab".repeat(32)).unwrap()
}

fn file(folder: &TempDir) -> PathBuf {
    folder.path().join("lux-index/search.sqlite")
}

fn with_suffix(path: &Path, suffix: &str) -> PathBuf {
    let mut name = path.as_os_str().to_owned();
    name.push(suffix);
    name.into()
}

fn messages(count: u64) -> Vec<IndexedMessage> {
    (0..count)
        .map(|n| IndexedMessage {
            event_id: format!("$m{n}").into(),
            room: "!a:x".into(),
            sender_name: "Anna Nováková".into(),
            body: format!("zpráva {n}: plán výletu na Sněžku"),
            links: Vec::new(),
            thread: None,
            date: SystemTime::UNIX_EPOCH + Duration::from_secs(1_700_000_000 + n),
            is_own: false,
        })
        .collect()
}

async fn found(store: &Store, text: &str) -> Result<usize, Error> {
    let search = TextSearch {
        text: text.into(),
        limit: 10_000,
        ..TextSearch::default()
    };
    store.search(search).await.map(|hits| hits.len())
}

/// A store with messages and a large kept value (its pages last in the file), closed.
async fn written(path: &Path) {
    let store = Store::open(path, key()).await.unwrap();
    store.add(messages(300)).await.unwrap();
    store.keep("photo".into(), vec![7; 40 * PAGE]).await.unwrap();
    store.close().await;
}

/// The store works as new: empty, and it keeps and finds what is added.
async fn works_as_new(store: &Store) {
    assert_eq!(store.message_count().await.unwrap(), 0);
    assert_eq!(store.kept("photo".into()).await.unwrap(), None);
    store.add(messages(3)).await.unwrap();
    assert_eq!(found(store, "výletu").await.unwrap(), 3);
}

/// Opens `path` as the app opens a cache, and checks it opens as new.
async fn opens_as_new(path: &Path) {
    let store = Store::open_or_replace(path, key()).await.unwrap();
    works_as_new(&store).await;
}

#[tokio::test]
async fn a_file_that_is_not_a_database_gives_way_to_a_new_one() {
    let folder = TempDir::new().unwrap();
    let path = file(&folder);
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(&path, vec![0x5a; 3 * PAGE]).unwrap();
    assert!(matches!(Store::open(&path, key()).await, Err(Error::Unreadable)));
    opens_as_new(&path).await;
}

/// The schema SQLite reads on opening is malformed (`SQLITE_CORRUPT`).
#[tokio::test]
async fn a_malformed_schema_gives_way_to_a_new_one() {
    let folder = TempDir::new().unwrap();
    let path = file(&folder);
    written(&path).await;
    {
        let connection = raw(&path);
        connection
            .execute_batch(
                "PRAGMA writable_schema = ON;
                 UPDATE sqlite_master SET sql = 'CREATE TABLE messages(' WHERE name = 'messages';",
            )
            .unwrap();
    }
    assert!(matches!(Store::open(&path, key()).await, Err(Error::Damaged)));
    opens_as_new(&path).await;
}

/// The file's version says a migration ran that its schema does not have: the migration after it
/// fails on it.
#[tokio::test]
async fn a_file_whose_migration_fails_gives_way_to_a_new_one() {
    let folder = TempDir::new().unwrap();
    let path = file(&folder);
    written(&path).await;
    raw(&path).pragma_update(None, "user_version", 3).unwrap();
    assert!(matches!(Store::open(&path, key()).await, Err(Error::Damaged)));
    opens_as_new(&path).await;
}

/// The file's first page fails SQLCipher's check: the store cannot read its schema.
#[tokio::test]
async fn a_damaged_first_page_gives_way_to_a_new_one() {
    let folder = TempDir::new().unwrap();
    let path = file(&folder);
    written(&path).await;
    let mut bytes = fs::read(&path).unwrap();
    damage(&mut bytes[200..300]);
    fs::write(&path, bytes).unwrap();
    opens_as_new(&path).await;
}

/// A page the store reads only later fails SQLCipher's check: the call that finds it fails, and
/// the store starts anew for the next.
#[tokio::test]
async fn a_page_found_damaged_later_gives_way_to_a_new_store() {
    let folder = TempDir::new().unwrap();
    let path = file(&folder);
    written(&path).await;
    let mut bytes = fs::read(&path).unwrap();
    // the kept value's pages, written last.
    damage_kept_value(&mut bytes);
    fs::write(&path, bytes).unwrap();

    let store = Store::open_or_replace(&path, key()).await.unwrap();
    assert_eq!(found(&store, "výletu").await.unwrap(), 300);
    let replaced = store.replaced();
    assert!(matches!(store.kept("photo".into()).await, Err(Error::Damaged)));
    replaced.await.unwrap();
    works_as_new(&store).await;
}

/// The crash the store's write was in when SQLCipher freed its key: a frame of the write-ahead
/// log written whole, its checksum right, but its page encrypted with other bytes. It is read
/// after the next launch, as the page's newest version.
#[tokio::test]
async fn a_log_frame_that_fails_its_check_gives_way_to_a_new_store() {
    let folder = TempDir::new().unwrap();
    let path = file(&folder);
    written(&path).await;
    let copy = folder.path().join("copy/search.sqlite");
    {
        // the log holds the write until the store closes: copied while it is open.
        let store = Store::open(&path, key()).await.unwrap();
        store.keep("photo".into(), vec![8; 40 * PAGE]).await.unwrap();
        fs::create_dir_all(copy.parent().unwrap()).unwrap();
        fs::copy(&path, &copy).unwrap();
        fs::copy(with_suffix(&path, "-wal"), with_suffix(&copy, "-wal")).unwrap();
        store.close().await;
    }
    let wal = with_suffix(&copy, "-wal");
    let mut log = fs::read(&wal).unwrap();
    let damaged = damage_frames_but_the_first_page(&mut log);
    assert!(damaged > 0);
    fs::write(&wal, log).unwrap();

    let store = Store::open_or_replace(&copy, key()).await.unwrap();
    let replaced = store.replaced();
    assert!(matches!(store.kept("photo".into()).await, Err(Error::Damaged)));
    replaced.await.unwrap();
    works_as_new(&store).await;
}

/// A store that is not a cache (`open`: the share extension, beside the app that owns the file)
/// reports the damage and keeps its file; what is not damaged it still reads.
#[tokio::test]
async fn a_store_that_is_not_a_cache_keeps_its_damaged_file() {
    let folder = TempDir::new().unwrap();
    let path = file(&folder);
    written(&path).await;
    let mut bytes = fs::read(&path).unwrap();
    damage_kept_value(&mut bytes);
    fs::write(&path, &bytes).unwrap();

    let store = Store::open(&path, key()).await.unwrap();
    assert!(matches!(store.kept("photo".into()).await, Err(Error::Damaged)));
    assert_eq!(found(&store, "výletu").await.unwrap(), 300);
    store.close().await;
    assert_eq!(fs::read(&path).unwrap(), bytes);
}

/// Two processes open a file of an older version at once (the app and its share extension after
/// an update): each migration runs once, and neither takes the other's for damage.
#[tokio::test]
async fn two_stores_migrating_one_file_at_once_both_open_it() {
    for _ in 0..20 {
        let folder = TempDir::new().unwrap();
        let path = file(&folder);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        // an encrypted file without a schema: every migration is to run.
        raw(&path)
            .execute_batch("PRAGMA journal_mode = WAL; CREATE TABLE t(x); DROP TABLE t;")
            .unwrap();
        let (first, second) = tokio::join!(Store::open_or_replace(&path, key()), Store::open(&path, key()));
        let (first, second) = (first.unwrap(), second.unwrap());
        first.add(messages(3)).await.unwrap();
        assert_eq!(second.message_count().await.unwrap(), 3);
        first.close().await;
        second.close().await;
    }
}

/// Damage that comes back soon after the store made a new file gives way a few times, then
/// stays, for its cause to be found: the calls report it.
#[tokio::test]
async fn damage_that_keeps_coming_back_stops_being_replaced() {
    let folder = TempDir::new().unwrap();
    let path = file(&folder);
    let store = Store::open_or_replace(&path, key()).await.unwrap();
    for replacement in 0..3 {
        store.add(messages(300)).await.unwrap();
        store.keep("photo".into(), vec![7; 40 * PAGE]).await.unwrap();
        // closed (its log written into the file), damaged, and opened again by the next call.
        store.pause().await.unwrap();
        store.resume();
        let mut bytes = fs::read(&path).unwrap();
        damage_kept_value(&mut bytes);
        fs::write(&path, &bytes).unwrap();
        let replaced = store.replaced();
        assert!(matches!(store.kept("photo".into()).await, Err(Error::Damaged)));
        if replacement < 2 {
            replaced.await.unwrap();
            works_as_new(&store).await;
        } else {
            store.pause().await.unwrap();
            assert_eq!(fs::read(&path).unwrap(), bytes);
        }
    }
}

/// The disk refuses (no permission): the error surfaces and the file stays as it was.
#[tokio::test]
async fn an_error_of_the_disk_leaves_the_file_be() {
    use std::os::unix::fs::PermissionsExt;

    let folder = TempDir::new().unwrap();
    let path = file(&folder);
    written(&path).await;
    let bytes = fs::read(&path).unwrap();
    let parent = path.parent().unwrap();
    fs::set_permissions(parent, fs::Permissions::from_mode(0o500)).unwrap();
    fs::set_permissions(&path, fs::Permissions::from_mode(0o400)).unwrap();
    let opened = Store::open_or_replace(&path, key()).await;
    fs::set_permissions(parent, fs::Permissions::from_mode(0o700)).unwrap();
    fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap();
    let error = opened.err().unwrap();
    assert!(matches!(error, Error::Sqlite(_) | Error::Io(_)), "{error:?}");
    assert_eq!(fs::read(&path).unwrap(), bytes);
    let store = Store::open(&path, key()).await.unwrap();
    assert_eq!(found(&store, "výletu").await.unwrap(), 300);
}

/// The file cannot be opened again after the store paused and resumed (the app back from the
/// background, the device still locked): data protection refuses a protected file then, as the
/// disk refuses one without permission here. The error surfaces, nothing is replaced, and once
/// the file can be read again the store goes on with all it held.
#[tokio::test]
async fn a_file_refused_after_a_pause_is_not_damage() {
    use std::os::unix::fs::PermissionsExt;

    let folder = TempDir::new().unwrap();
    let path = file(&folder);
    written(&path).await;
    let store = Store::open_or_replace(&path, key()).await.unwrap();
    store.pause().await.unwrap();
    store.resume();
    let bytes = fs::read(&path).unwrap();
    fs::set_permissions(&path, fs::Permissions::from_mode(0o000)).unwrap();
    let refused = found(&store, "výletu").await;
    fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap();
    let error = refused.err().unwrap();
    assert!(matches!(error, Error::Sqlite(_) | Error::Io(_)), "{error:?}");
    assert_eq!(fs::read(&path).unwrap(), bytes);
    assert_eq!(found(&store, "výletu").await.unwrap(), 300);
}

/// A folder that cannot be made (a file is in its place): the error surfaces.
#[tokio::test]
async fn a_folder_that_cannot_be_made_is_an_error() {
    let folder = TempDir::new().unwrap();
    let path = file(&folder);
    fs::write(path.parent().unwrap(), b"a file").unwrap();
    assert!(matches!(Store::open_or_replace(&path, key()).await, Err(Error::Io(_))));
    assert_eq!(fs::read(path.parent().unwrap()).unwrap(), b"a file");
}

/// The file opened as the store opens it, with SQLite's own calls.
fn raw(path: &Path) -> rusqlite::Connection {
    let connection = rusqlite::Connection::open(path).unwrap();
    // the store's salt, "lux-store.salt.1", in hex.
    let salt = "6c75782d73746f72652e73616c742e31";
    connection
        .execute_batch(&format!(
            "PRAGMA key = \"x'{}{salt}'\"; PRAGMA cipher_plaintext_header_size = 32;",
            "ab".repeat(32)
        ))
        .unwrap();
    connection
}

/// Damages a page in the middle of the kept value's forty, the last thing `written` wrote.
fn damage_kept_value(file: &mut [u8]) {
    let page = file.len() - 20 * PAGE;
    damage(&mut file[page + 100..page + 200]);
}

fn damage(bytes: &mut [u8]) {
    for byte in bytes {
        *byte ^= 0xa5;
    }
}

/// Damages the page of every frame in a write-ahead log but the first page's, and writes the
/// frames' checksums again, as SQLite would have for those bytes; how many it damaged.
fn damage_frames_but_the_first_page(log: &mut [u8]) -> usize {
    const HEADER: usize = 32;
    const FRAME_HEADER: usize = 24;
    let word = |bytes: &[u8], at: usize| u32::from_be_bytes(bytes[at..at + 4].try_into().unwrap());
    let big_endian = word(log, 0) & 1 == 1;
    let page = word(log, 8) as usize;
    let mut sums = (word(log, 24), word(log, 28));
    let mut damaged = 0;
    let mut at = HEADER;
    while at + FRAME_HEADER + page <= log.len() {
        if word(log, at) != 1 {
            damage(&mut log[at + FRAME_HEADER + 100..at + FRAME_HEADER + 200]);
            damaged += 1;
        }
        sums = checksum(&log[at..at + 8], sums, big_endian);
        sums = checksum(&log[at + FRAME_HEADER..at + FRAME_HEADER + page], sums, big_endian);
        log[at + 16..at + 20].copy_from_slice(&sums.0.to_be_bytes());
        log[at + 20..at + 24].copy_from_slice(&sums.1.to_be_bytes());
        at += FRAME_HEADER + page;
    }
    damaged
}

/// SQLite's checksum of the write-ahead log, on from `sums`.
fn checksum(bytes: &[u8], (mut first, mut second): (u32, u32), big_endian: bool) -> (u32, u32) {
    let read = |word: [u8; 4]| {
        if big_endian {
            u32::from_be_bytes(word)
        } else {
            u32::from_le_bytes(word)
        }
    };
    for [a, b] in bytes.as_chunks::<4>().0.as_chunks::<2>().0 {
        first = first.wrapping_add(read(*a)).wrapping_add(second);
        second = second.wrapping_add(read(*b)).wrapping_add(first);
    }
    (first, second)
}
