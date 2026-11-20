//! The store as the app uses it: the index, the kept values, the file's encryption.

#![allow(
    clippy::unwrap_used,
    clippy::indexing_slicing,
    reason = "a test's helpers fail it as its asserts do"
)]

use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

use lux_core::ids::RoomId;
use lux_core::timeline::{IndexedFile, IndexedMessage};
use lux_store::{Browse, Error, IndexedChat, Key, MessageEmbedding, Store, TextSearch};
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
        links: Vec::new(),
        thread: None,
        date: at(seconds),
        is_own: false,
    }
}

fn words(text: &str, room_id: Option<RoomId>, limit: u32) -> TextSearch {
    TextSearch {
        text: text.into(),
        room_id,
        limit,
        ..TextSearch::default()
    }
}

async fn found(store: &Store, text: &str) -> Vec<String> {
    let hits = store.search(words(text, None, 50)).await.unwrap();
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
    let hits = store
        .search(words("zitra", Some(RoomId::from("!b")), 50))
        .await
        .unwrap();
    assert!(hits.is_empty());
    let hits = store.search(words("zitra", None, 1)).await.unwrap();
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
    let hit = store.search(words("zit", None, 50)).await.unwrap().remove(0);
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
        oldest: None,
        older: None,
    };
    store.set_chat("!a".into(), complete.clone()).await.unwrap();
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
async fn a_paused_store_opens_again_on_the_first_call_after_it_resumes() {
    let folder = TempDir::new().unwrap();
    let store = Store::open(file(&folder), key()).await.unwrap();
    store.add(vec![message("$1", "kept", "!a", 0)]).await.unwrap();
    store.pause().await.unwrap();
    // the connection is gone with its journal: nothing holds the file.
    assert!(!folder.path().join("lux-search/index.sqlite-wal").exists());
    // a call meanwhile (the kept list's, in the background) does not open it again.
    assert!(matches!(
        store.keep("chat-list".into(), vec![1]).await,
        Err(Error::Paused)
    ));
    assert!(!folder.path().join("lux-search/index.sqlite-wal").exists());
    store.resume();
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
async fn keeps_how_far_each_chat_is_read_and_where_it_reads_on() {
    let folder = TempDir::new().unwrap();
    let store = Store::open(file(&folder), key()).await.unwrap();
    let long_ago = SystemTime::UNIX_EPOCH - Duration::from_hours(17_259_888);
    store
        .set_chat(
            "!a".into(),
            IndexedChat {
                newest: at(5),
                complete: false,
                oldest: Some(at(1)),
                older: Some("t1-older".into()),
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
                oldest: None,
                older: None,
            },
        )
        .await
        .unwrap();
    store
        .set_chat(
            "!a".into(),
            IndexedChat {
                newest: at(9),
                complete: false,
                oldest: Some(at(0)),
                older: Some("t0-older".into()),
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
            complete: false,
            oldest: Some(at(0)),
            older: Some("t0-older".into()),
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
    // the header stays plain, so iOS knows the file for a database (and its locks for SQLite's);
    // the pages after it are encrypted.
    assert!(bytes.starts_with(b"SQLite format 3\0"));
    assert!(!contains(&bytes[32..], b"CREATE TABLE"));
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

/// A file from before the plain header (SQLCipher's salt in its first bytes) no longer opens, and
/// the store, a cache, starts anew in its place.
#[tokio::test]
async fn a_file_with_an_encrypted_header_gives_way_to_a_new_one() {
    let folder = TempDir::new().unwrap();
    let path = file(&folder);
    {
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        let connection = rusqlite::Connection::open(&path).unwrap();
        connection
            .execute_batch(&format!(
                "PRAGMA key = \"x'{}'\"; CREATE TABLE old(x); INSERT INTO old VALUES (1);",
                "ab".repeat(32)
            ))
            .unwrap();
    }
    assert!(!database_bytes(&path).starts_with(b"SQLite format 3"));
    assert!(matches!(Store::open(&path, key()).await, Err(Error::Unreadable)));
    let store = Store::open_or_replace(&path, key()).await.unwrap();
    assert_eq!(store.message_count().await.unwrap(), 0);
    drop(store);
    assert!(database_bytes(&path).starts_with(b"SQLite format 3\0"));
}

fn browse(text: &str) -> Browse {
    Browse {
        text: text.into(),
        limit: 50,
        ..Browse::default()
    }
}

#[tokio::test]
async fn lists_the_links_files_and_threads_newest_first_and_by_their_words() {
    let folder = TempDir::new().unwrap();
    let store = Store::open(file(&folder), key()).await.unwrap();
    let mut linked = message("$link", "Plán výletu https://mapy.cz/a", "!a", 1);
    linked.links = vec!["https://mapy.cz/a".into()];
    let mut later = message("$later", "a tohle https://lux.chat", "!b", 5);
    later.links = vec!["https://lux.chat".into()];
    let mut reply = message("$reply", "Jdu taky", "!a", 3);
    reply.thread = Some("$root".into());
    let mut newer = message("$newer", "A já ne", "!a", 4);
    newer.thread = Some("$root".into());
    store
        .add(vec![
            linked,
            later,
            message("$root", "Kdo jde na výlet?", "!a", 2),
            reply,
            newer,
        ])
        .await
        .unwrap();
    store
        .add_files(vec![IndexedFile {
            event_id: "$file".into(),
            room: "!a".into(),
            sender_name: "Anna".into(),
            name: "Faktura_září.pdf".into(),
            size: Some(1_000),
            mimetype: Some("application/pdf".into()),
            date: at(6),
            is_own: false,
        }])
        .await
        .unwrap();

    let urls = |links: Vec<lux_store::LinkHit>| links.into_iter().map(|link| link.url).collect::<Vec<_>>();
    assert_eq!(
        urls(store.links(browse("")).await.unwrap()),
        ["https://lux.chat", "https://mapy.cz/a"]
    );
    assert_eq!(urls(store.links(browse("vylet")).await.unwrap()), ["https://mapy.cz/a"]);
    // an edit without the address forgets it.
    store.add(vec![message("$link", "Plán výletu", "!a", 1)]).await.unwrap();
    assert_eq!(urls(store.links(browse("")).await.unwrap()), ["https://lux.chat"]);

    let files = store.files(browse("faktura zari")).await.unwrap();
    assert_eq!(files.len(), 1);
    assert_eq!(files[0].size, Some(1_000));
    assert!(store.files(browse("smlouva")).await.unwrap().is_empty());

    let threads = store.threads(browse("")).await.unwrap();
    assert_eq!(threads.len(), 1);
    assert_eq!(threads[0].root_text.as_deref(), Some("Kdo jde na výlet?"));
    assert_eq!(threads[0].replies, 2);
    assert_eq!(threads[0].latest_text, "A já ne");
    // found by its root's words or a reply's.
    assert_eq!(store.threads(browse("vylet")).await.unwrap().len(), 1);
    assert_eq!(store.threads(browse("taky")).await.unwrap().len(), 1);
    assert!(store.threads(browse("plan")).await.unwrap().is_empty());

    // a deleted reply leaves the thread; a deleted file is gone.
    store.remove(vec!["$newer".into(), "$file".into()]).await.unwrap();
    assert_eq!(store.threads(browse("")).await.unwrap()[0].latest_text, "Jdu taky");
    assert!(store.files(browse("")).await.unwrap().is_empty());
}

/// A unit embedding along `axis` of four, leaning to `toward` by `lean`.
fn unit(axis: usize, toward: usize, lean: f32) -> Vec<f32> {
    let mut vector = [0.0_f32; 4];
    vector[axis] = 1.0;
    vector[toward] += lean;
    let length = vector.iter().map(|value| value * value).sum::<f32>().sqrt();
    vector.iter().map(|value| value / length).collect()
}

#[tokio::test]
async fn finds_messages_by_their_meaning_and_reads_each_once() {
    let folder = TempDir::new().unwrap();
    let store = Store::open(file(&folder), key()).await.unwrap();
    store
        .add(vec![
            message("$hory", "Zítra jedeme na hory, vezmi lyže", "!a", 1),
            message("$pizza", "Dáme si večer pizzu?", "!a", 2),
            message("$ok", "ok", "!a", 3),
        ])
        .await
        .unwrap();
    // the short one has too little to mean.
    let to_read = store.messages_to_embed(6, 10).await.unwrap();
    assert_eq!(
        to_read
            .iter()
            .map(|message| message.event_id.as_str())
            .collect::<Vec<_>>(),
        ["$pizza", "$hory"]
    );
    let read = |id: &str, embedding| MessageEmbedding {
        event_id: id.into(),
        embedder: "model@1".into(),
        embedding,
    };
    store
        .set_message_embeddings(vec![
            read("$hory", Some(unit(0, 1, 0.0))),
            read("$pizza", Some(unit(2, 1, 0.0))),
        ])
        .await
        .unwrap();
    assert!(store.messages_to_embed(6, 10).await.unwrap().is_empty());
    assert_eq!(store.embedding_counts(6).await.unwrap(), (2, 2));

    let meaning = |text: &str, embedding| TextSearch {
        text: text.into(),
        embedding: Some(embedding),
        min_similarity: 0.5,
        limit: 10,
        ..TextSearch::default()
    };
    // "lyžování" has none of the words, but the meaning of the first.
    let hits = store.search(meaning("lyžování", unit(0, 3, 0.3))).await.unwrap();
    assert_eq!(
        hits.iter().map(|hit| hit.event_id.as_str()).collect::<Vec<_>>(),
        ["$hory"]
    );
    assert!(hits[0].matches.is_empty());
    // found by its words and its meaning: first.
    let hits = store.search(meaning("pizzu", unit(0, 3, 0.3))).await.unwrap();
    assert_eq!(hits[0].event_id.as_str(), "$pizza");

    // an edit is read again, and so is the message read with it; another model reads them all
    // again.
    store
        .add(vec![message("$hory", "Zítra jedeme na hory, vezmi boty", "!a", 1)])
        .await
        .unwrap();
    let unread = async || {
        let messages = store.messages_to_embed(6, 10).await.unwrap();
        messages
            .into_iter()
            .map(|message| message.event_id.to_string())
            .collect::<Vec<_>>()
    };
    assert_eq!(unread().await, ["$pizza", "$hory"]);
    store
        .set_message_embeddings(vec![read("$hory", None), read("$pizza", None)])
        .await
        .unwrap();
    store.forget_message_embeddings(Some("model@2".into())).await.unwrap();
    assert_eq!(unread().await, ["$pizza", "$hory"]);
}

/// The messages whose meaning is not read, at least one character long, by their event ids.
async fn unread(store: &Store) -> Vec<String> {
    let mut ids: Vec<String> = store
        .messages_to_embed(1, 100)
        .await
        .unwrap()
        .into_iter()
        .map(|message| message.event_id.to_string())
        .collect();
    ids.sort();
    ids
}

/// Reads every message's meaning, as `embedder`.
async fn read_all(store: &Store, embedder: &str) {
    let messages = store.messages_to_embed(1, 100).await.unwrap();
    store
        .set_message_embeddings(
            messages
                .into_iter()
                .map(|message| MessageEmbedding {
                    event_id: message.event_id,
                    embedder: embedder.into(),
                    embedding: Some(unit(0, 1, 0.0)),
                })
                .collect(),
        )
        .await
        .unwrap();
    assert!(unread(store).await.is_empty());
}

fn said(id: &str, sender: &str, body: &str, room: &str, seconds: u64, thread: Option<&str>) -> IndexedMessage {
    IndexedMessage {
        sender_name: sender.into(),
        thread: thread.map(Into::into),
        ..message(id, body, room, seconds)
    }
}

/// Each message's context as "sender: text" lines, the oldest first.
async fn contexts(store: &Store) -> Vec<(String, Vec<String>)> {
    let mut messages: Vec<(String, Vec<String>)> = store
        .messages_to_embed(1, 100)
        .await
        .unwrap()
        .into_iter()
        .map(|message| {
            let lines = message
                .context
                .iter()
                .map(|line| format!("{}: {}", line.sender_name, line.body))
                .collect();
            (message.event_id.to_string(), lines)
        })
        .collect();
    messages.sort();
    messages
}

#[tokio::test]
async fn a_message_is_read_with_the_four_before_it_in_its_thread_or_else_its_chat() {
    let folder = TempDir::new().unwrap();
    let store = Store::open(file(&folder), key()).await.unwrap();
    let long = "a".repeat(300);
    store
        .add(vec![
            said("$0", "Me", "Hi!", "!a", 1, None),
            said("$1", "Anna", "Are you free for dinner on Friday?", "!a", 2, None),
            said("$2", "Me", "Which time?", "!a", 3, None),
            said("$root", "Anna", "Who brings what?", "!a", 4, None),
            said("$r1", "Tom", "wine", "!a", 5, Some("$root")),
            said("$4", "Anna", &long, "!a", 6, None),
            said("$r2", "Me", "dessert", "!a", 7, Some("$root")),
            said("$5", "Anna", "yes, Friday at 5 at ours", "!a", 8, None),
            said("$r3", "Anna", "bread", "!a", 9, Some("$root")),
            said("$r4", "Tom", "cheese", "!a", 10, Some("$root")),
            said("$r5", "Me", "salad", "!a", 11, Some("$root")),
            said("$other", "Bob", "in another chat", "!b", 5, None),
        ])
        .await
        .unwrap();
    let lines = |lines: &[&str]| lines.iter().map(ToString::to_string).collect::<Vec<_>>();
    let cut = format!("Anna: {}", "a".repeat(100));
    let mut expected = vec![
        ("$0".to_string(), lines(&[])),
        ("$1".into(), lines(&["Me: Hi!"])),
        (
            "$2".into(),
            lines(&["Me: Hi!", "Anna: Are you free for dinner on Friday?"]),
        ),
        (
            "$root".into(),
            lines(&["Me: Hi!", "Anna: Are you free for dinner on Friday?", "Me: Which time?"]),
        ),
        (
            "$4".into(),
            lines(&[
                "Me: Hi!",
                "Anna: Are you free for dinner on Friday?",
                "Me: Which time?",
                "Anna: Who brings what?",
            ]),
        ),
        // the chat's four before it, not the thread's replies; a long one cut.
        (
            "$5".into(),
            lines(&[
                "Anna: Are you free for dinner on Friday?",
                "Me: Which time?",
                "Anna: Who brings what?",
                &cut,
            ]),
        ),
        ("$other".into(), lines(&[])),
        // a reply's thread: its root and the replies before it.
        ("$r1".into(), lines(&["Anna: Who brings what?"])),
        ("$r2".into(), lines(&["Anna: Who brings what?", "Tom: wine"])),
        (
            "$r3".into(),
            lines(&["Anna: Who brings what?", "Tom: wine", "Me: dessert"]),
        ),
        (
            "$r4".into(),
            lines(&["Anna: Who brings what?", "Tom: wine", "Me: dessert", "Anna: bread"]),
        ),
        // four back: past its root.
        (
            "$r5".into(),
            lines(&["Tom: wine", "Me: dessert", "Anna: bread", "Tom: cheese"]),
        ),
    ];
    expected.sort();
    assert_eq!(contexts(&store).await, expected);
}

#[tokio::test]
async fn what_a_change_reads_again_is_the_changed_message_and_the_four_read_with_it() {
    let folder = TempDir::new().unwrap();
    let store = Store::open(file(&folder), key()).await.unwrap();
    let chat: Vec<IndexedMessage> = (1..=7)
        .map(|n| said(&format!("$m{n}"), "Anna", &format!("message {n}"), "!a", n * 10, None))
        .chain([said("$other", "Bob", "elsewhere", "!b", 15, None)])
        .collect();
    store.add(chat.clone()).await.unwrap();
    read_all(&store, "m").await;

    // the same messages again (a chat read again) change nothing.
    store.add(chat).await.unwrap();
    assert!(unread(&store).await.is_empty());

    // a newer message has none after it.
    store
        .add(vec![said("$m8", "Anna", "message 8", "!a", 80, None)])
        .await
        .unwrap();
    assert_eq!(unread(&store).await, ["$m8"]);
    read_all(&store, "m").await;

    // an older page, read after the newer one: the first four after it in its chat.
    store
        .add(vec![said("$m0", "Anna", "message 0", "!a", 5, None)])
        .await
        .unwrap();
    assert_eq!(unread(&store).await, ["$m0", "$m1", "$m2", "$m3", "$m4"]);
    read_all(&store, "m").await;

    // an edit: the message and the four after it.
    store
        .add(vec![said("$m3", "Anna", "message 3, edited", "!a", 30, None)])
        .await
        .unwrap();
    assert_eq!(unread(&store).await, ["$m3", "$m4", "$m5", "$m6", "$m7"]);
    read_all(&store, "m").await;

    // the sender's new name is read with them too.
    store
        .add(vec![said("$m2", "Anna B.", "message 2", "!a", 20, None)])
        .await
        .unwrap();
    assert_eq!(unread(&store).await, ["$m2", "$m3", "$m4", "$m5", "$m6"]);
    read_all(&store, "m").await;

    // a deletion: the four after it, whose context it left.
    store.remove(vec!["$m1".into()]).await.unwrap();
    assert_eq!(unread(&store).await, ["$m2", "$m3", "$m4", "$m5"]);
}

#[tokio::test]
async fn a_change_in_a_thread_reads_its_replies_again_and_its_root_the_chat_too() {
    let folder = TempDir::new().unwrap();
    let store = Store::open(file(&folder), key()).await.unwrap();
    let reply = |n: u64| {
        said(
            &format!("$r{n}"),
            "Tom",
            &format!("reply {n}"),
            "!a",
            20 + n,
            Some("$root"),
        )
    };
    store
        .add(
            [
                said("$before", "Anna", "before", "!a", 10, None),
                said("$root", "Anna", "Who brings what?", "!a", 20, None),
                said("$after", "Anna", "after", "!a", 30, None),
            ]
            .into_iter()
            .chain((1..=6).map(reply))
            .collect(),
        )
        .await
        .unwrap();
    read_all(&store, "m").await;

    // a reply: the four replies after it, not the chat.
    store.remove(vec!["$r1".into()]).await.unwrap();
    assert_eq!(unread(&store).await, ["$r2", "$r3", "$r4", "$r5"]);
    read_all(&store, "m").await;

    // the root: its first four replies, and the chat's messages after it.
    store
        .add(vec![said(
            "$root",
            "Anna",
            "Who brings what on Friday?",
            "!a",
            20,
            None,
        )])
        .await
        .unwrap();
    assert_eq!(unread(&store).await, ["$after", "$r2", "$r3", "$r4", "$r5", "$root"]);
    read_all(&store, "m").await;

    // a reply moved out of its thread (as the server may say later): both lose it.
    store
        .add(vec![said("$r2", "Tom", "reply 2", "!a", 22, None)])
        .await
        .unwrap();
    assert_eq!(unread(&store).await, ["$after", "$r2", "$r3", "$r4", "$r5", "$r6"]);
}

#[tokio::test]
async fn clearing_the_index_keeps_the_kept_values() {
    let folder = TempDir::new().unwrap();
    let store = Store::open(file(&folder), key()).await.unwrap();
    store
        .add(vec![message("$1", "Zítra jdeme na výlet", "!a", 1)])
        .await
        .unwrap();
    store.keep("chats".into(), vec![1, 2, 3]).await.unwrap();
    store.clear_index().await.unwrap();
    assert!(found(&store, "vylet").await.is_empty());
    assert_eq!(store.message_count().await.unwrap(), 0);
    assert_eq!(store.kept("chats".into()).await.unwrap(), Some(vec![1, 2, 3]));
}

#[tokio::test]
async fn a_closed_store_has_closed_its_file_and_refuses_later_calls() {
    let folder = TempDir::new().unwrap();
    let store = Store::open(file(&folder), key()).await.unwrap();
    store.add(vec![message("$1", "kept", "!a", 0)]).await.unwrap();
    store.close().await;
    // closed once awaited: the last connection took its journal with it.
    assert!(!folder.path().join("lux-search/index.sqlite-wal").exists());
    assert!(matches!(store.message_count().await, Err(Error::Closed)));
    // a second close, and the drop, find it closed.
    store.close().await;
    drop(store);
    let again = Store::open(file(&folder), key()).await.unwrap();
    assert_eq!(found(&again, "kept").await, ["$1"]);
}

#[tokio::test]
async fn a_chats_recent_messages_come_oldest_first_and_page_back() {
    let folder = TempDir::new().unwrap();
    let store = Store::open(file(&folder), key()).await.unwrap();
    store
        .add(vec![
            message("$1", "first", "!a", 1),
            message("$2", "second", "!a", 2),
            message("$3", "other chat", "!b", 3),
            message("$4", "third", "!a", 4),
        ])
        .await
        .unwrap();
    let ids = |hits: Vec<lux_store::Hit>| hits.into_iter().map(|hit| hit.event_id.to_string()).collect::<Vec<_>>();
    let newest = store.recent(RoomId::from("!a"), None, 2).await.unwrap();
    assert_eq!(newest[1].excerpt, "third");
    assert_eq!(ids(newest), ["$2", "$4"]);
    let older = store.recent(RoomId::from("!a"), Some(at(2)), 10).await.unwrap();
    assert_eq!(ids(older), ["$1"]);
}
