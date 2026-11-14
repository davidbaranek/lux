//! The store as the app uses it: the index, the kept values, the file's encryption.

#![allow(clippy::unwrap_used, reason = "a test's helpers fail it as its asserts do")]

use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

use lux_core::ids::RoomId;
use lux_core::timeline::IndexedMessage;
use lux_store::{Error, IndexedChat, Key, Store};
use tempfile::TempDir;

fn key() -> Key {
    Key::from_hex(&"ab".repeat(32)).unwrap()
}

fn file(folder: &TempDir) -> PathBuf {
    folder.path().join("lux-search/index.sqlite")
}

fn at(seconds: u64) -> SystemTime {
    SystemTime::UNIX_EPOCH + Duration::from_secs(1_700_000_000 + seconds)
}

fn message(id: &str, body: &str, room: &str, seconds: u64) -> IndexedMessage {
    IndexedMessage {
        event_id: id.into(),
        room: room.into(),
        sender_name: "Anna Nováková".into(),
        body: body.into(),
        date: at(seconds),
        is_own: false,
    }
}

async fn found(store: &Store, text: &str) -> Vec<String> {
    let hits = store.search(text, None, 50).await.unwrap();
    hits.into_iter().map(|hit| hit.event_id.to_string()).collect()
}

#[tokio::test]
async fn finds_word_starts_without_accents_newest_first() {
    let folder = TempDir::new().unwrap();
    let store = Store::open(file(&folder), key()).await.unwrap();
    store
        .add(vec![
            message("$1", "Zítra jdeme na výlet", "!a", 1),
            message("$2", "zitra ne", "!a", 2),
            message("$3", "Něco jiného", "!b", 3),
        ])
        .await
        .unwrap();
    assert_eq!(found(&store, "zit").await, ["$2", "$1"]);
    assert_eq!(found(&store, "ZÍTRA výl").await, ["$1"]);
    // the sender's name is found too.
    assert_eq!(found(&store, "anna jine").await, ["$3"]);
    assert!(found(&store, "  ").await.is_empty());
    // a quote or an operator in the text is only text.
    assert!(found(&store, "\"zit OR").await.is_empty());
    // one chat's.
    let hits = store.search("zitra", Some(RoomId::from("!b")), 50).await.unwrap();
    assert!(hits.is_empty());
    let hits = store.search("zitra", None, 1).await.unwrap();
    assert_eq!(hits.len(), 1);
}

#[tokio::test]
async fn the_excerpt_marks_the_found_words() {
    let folder = TempDir::new().unwrap();
    let store = Store::open(file(&folder), key()).await.unwrap();
    store
        .add(vec![message("$1", "Uvidíme se zítra ráno", "!a", 0)])
        .await
        .unwrap();
    let hit = store.search("zit", None, 50).await.unwrap().remove(0);
    assert_eq!(hit.excerpt, "Uvidíme se zítra ráno");
    let utf16: Vec<u16> = hit.excerpt.encode_utf16().collect();
    let words: Vec<String> = hit
        .matches
        .iter()
        .map(|range| String::from_utf16(&utf16[range.start as usize..range.end as usize]).unwrap())
        .collect();
    assert_eq!(words, ["zítra"]);
    assert_eq!(hit.room_id, RoomId::from("!a"));
    assert_eq!(hit.sender_name, "Anna Nováková");
    assert_eq!(hit.date, at(0));
    assert!(!hit.is_own);
}

#[tokio::test]
async fn an_edit_replaces_the_text() {
    let folder = TempDir::new().unwrap();
    let store = Store::open(file(&folder), key()).await.unwrap();
    store.add(vec![message("$1", "old words", "!a", 0)]).await.unwrap();
    store.add(vec![message("$1", "new words", "!a", 0)]).await.unwrap();
    assert!(found(&store, "old").await.is_empty());
    assert_eq!(found(&store, "new").await, ["$1"]);
}

#[tokio::test]
async fn a_deleted_chat_forgets_its_messages_up_to_the_delete_and_a_gone_chat_all_of_them() {
    let folder = TempDir::new().unwrap();
    let store = Store::open(file(&folder), key()).await.unwrap();
    store
        .add(vec![
            message("$1", "before the delete", "!a", 0),
            message("$2", "after the delete", "!a", 2),
            message("$3", "a chat that went", "!b", 0),
        ])
        .await
        .unwrap();
    let complete = IndexedChat {
        newest: at(2),
        complete: true,
    };
    store.set_chat("!a".into(), complete).await.unwrap();
    store.set_chat("!b".into(), complete).await.unwrap();

    store.forget_chat("!a".into(), Some(at(1))).await.unwrap();
    store.forget_chat("!b".into(), None).await.unwrap();

    assert!(found(&store, "before").await.is_empty());
    assert_eq!(found(&store, "after").await, ["$2"]);
    assert!(found(&store, "went").await.is_empty());
    let chats = store.chats().await.unwrap();
    assert!(chats.contains_key(&RoomId::from("!a")) && !chats.contains_key(&RoomId::from("!b")));
}

#[tokio::test]
async fn a_deleted_message_is_forgotten() {
    let folder = TempDir::new().unwrap();
    let store = Store::open(file(&folder), key()).await.unwrap();
    store
        .add(vec![
            message("$1", "secret plan", "!a", 0),
            message("$2", "secret too", "!a", 1),
        ])
        .await
        .unwrap();
    store.remove(vec!["$1".into(), "$unknown".into()]).await.unwrap();
    assert_eq!(found(&store, "secret").await, ["$2"]);
    assert_eq!(store.message_count().await.unwrap(), 1);
}

#[tokio::test]
async fn a_released_store_opens_again_on_the_next_call() {
    let folder = TempDir::new().unwrap();
    let store = Store::open(file(&folder), key()).await.unwrap();
    store.add(vec![message("$1", "kept", "!a", 0)]).await.unwrap();
    store.release().await.unwrap();
    // the connection is gone with its journal: nothing holds the file.
    assert!(!folder.path().join("lux-search/index.sqlite-wal").exists());
    assert_eq!(found(&store, "kept").await, ["$1"]);
}

#[tokio::test]
async fn dropping_the_store_closes_the_file_before_it_returns() {
    let folder = TempDir::new().unwrap();
    let store = Store::open(file(&folder), key()).await.unwrap();
    store.add(vec![message("$1", "kept", "!a", 0)]).await.unwrap();
    drop(store);
    // closed, not left to the process's exit: the last connection took its journal with it.
    assert!(!folder.path().join("lux-search/index.sqlite-wal").exists());
}

#[tokio::test]
async fn keeps_how_far_each_chat_is_read() {
    let folder = TempDir::new().unwrap();
    let store = Store::open(file(&folder), key()).await.unwrap();
    let long_ago = SystemTime::UNIX_EPOCH - Duration::from_hours(17_259_888);
    store
        .set_chat(
            "!a".into(),
            IndexedChat {
                newest: at(5),
                complete: false,
            },
        )
        .await
        .unwrap();
    store
        .set_chat(
            "!b".into(),
            IndexedChat {
                newest: long_ago,
                complete: true,
            },
        )
        .await
        .unwrap();
    store
        .set_chat(
            "!a".into(),
            IndexedChat {
                newest: at(9),
                complete: true,
            },
        )
        .await
        .unwrap();
    let chats = store.chats().await.unwrap();
    assert_eq!(chats.len(), 2);
    assert_eq!(
        chats[&RoomId::from("!a")],
        IndexedChat {
            newest: at(9),
            complete: true
        }
    );
    assert_eq!(chats[&RoomId::from("!b")].newest, long_ago);
}

#[tokio::test]
async fn kept_values_come_back_after_reopening() {
    let folder = TempDir::new().unwrap();
    {
        let store = Store::open(file(&folder), key()).await.unwrap();
        store.keep("chat-list".into(), b"{\"rows\":[]}".to_vec()).await.unwrap();
    }
    let store = Store::open(file(&folder), key()).await.unwrap();
    assert_eq!(
        store.kept("chat-list".into()).await.unwrap().as_deref(),
        Some(&b"{\"rows\":[]}"[..])
    );
    assert_eq!(store.kept("other".into()).await.unwrap(), None);
}

fn contains(haystack: &[u8], needle: &[u8]) -> bool {
    haystack.windows(needle.len()).any(|window| window == needle)
}

fn database_bytes(path: &Path) -> Vec<u8> {
    let mut bytes = std::fs::read(path).unwrap();
    let mut wal = path.as_os_str().to_owned();
    wal.push("-wal");
    bytes.extend(std::fs::read(PathBuf::from(wal)).unwrap_or_default());
    bytes
}

#[tokio::test]
async fn the_file_is_encrypted_and_needs_its_key() {
    let folder = TempDir::new().unwrap();
    let path = file(&folder);
    {
        let store = Store::open(&path, key()).await.unwrap();
        store.add(vec![message("$1", "secret plans", "!a", 0)]).await.unwrap();
        store.keep("chat-list".into(), b"kept secret".to_vec()).await.unwrap();
    }
    let bytes = database_bytes(&path);
    assert!(!bytes.starts_with(b"SQLite format 3"));
    assert!(!contains(&bytes, b"secret plans"));
    assert!(!contains(&bytes, b"kept secret"));

    let other = Key::from_hex(&"cd".repeat(32)).unwrap();
    assert!(matches!(
        Store::open(&path, other.clone()).await,
        Err(Error::Unreadable)
    ));
    let store = Store::open(&path, key()).await.unwrap();
    assert_eq!(found(&store, "secret").await, ["$1"]);
    drop(store);

    // the index is a cache: a file another key wrote gives way to a new one.
    let store = Store::open_or_replace(&path, other.clone()).await.unwrap();
    assert_eq!(store.message_count().await.unwrap(), 0);
    drop(store);
    assert!(Store::open(&path, other).await.is_ok());
}
