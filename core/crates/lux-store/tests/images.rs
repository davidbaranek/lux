//! Photo search as the app uses it: photos from the history, what the apps read in them, and
//! finding them by their words, the messages near them and their look.

#![allow(clippy::unwrap_used, reason = "a test's helpers fail it as its asserts do")]

use std::time::{Duration, SystemTime};

use lux_core::ids::{EventId, RoomId};
use lux_core::timeline::{IndexedImage, IndexedMessage};
use lux_store::{ImageCounts, ImageRead, ImageReason, ImageSearch, Key, Store};
use tempfile::TempDir;

const READER: &str = "test-reader-1";

async fn store(folder: &TempDir) -> Store {
    let key = Key::from_hex(&"cd".repeat(32)).unwrap();
    Store::open(folder.path().join("index.sqlite"), key).await.unwrap()
}

fn at(seconds: u64) -> SystemTime {
    SystemTime::UNIX_EPOCH + Duration::from_secs(1_700_000_000 + seconds)
}

fn image(id: &str, room: &str, caption: &str, seconds: u64) -> IndexedImage {
    IndexedImage {
        event_id: id.into(),
        room: room.into(),
        sender_name: "Anna".into(),
        caption: caption.into(),
        date: at(seconds),
        is_own: false,
    }
}

fn read(id: &str, words: &str, embedding: Option<Vec<f32>>) -> ImageRead {
    ImageRead {
        event_id: id.into(),
        reader: READER.into(),
        words: words.into(),
        embedding,
    }
}

fn search(text: &str, embedding: Option<Vec<f32>>) -> ImageSearch {
    ImageSearch {
        text: text.into(),
        embedding,
        min_similarity: 0.5,
        room_id: None,
        limit: 20,
    }
}

async fn found(store: &Store, search: ImageSearch) -> Vec<String> {
    let hits = store.search_images(search).await.unwrap();
    hits.into_iter().map(|hit| hit.event_id.to_string()).collect()
}

#[tokio::test]
async fn photos_wait_to_be_read_newest_first_and_a_newer_reader_reads_them_again() {
    let folder = TempDir::new().unwrap();
    let store = store(&folder).await;
    store
        .add_images(vec![image("$old", "!a", "", 1), image("$new", "!b", "", 2)])
        .await
        .unwrap();
    let waiting = store.images_to_read(READER.into(), 10).await.unwrap();
    assert_eq!(
        waiting,
        [
            (EventId::from("$new"), RoomId::from("!b")),
            (EventId::from("$old"), RoomId::from("!a"))
        ]
    );
    store.set_images_read(vec![read("$new", "", None)]).await.unwrap();
    assert_eq!(store.images_to_read(READER.into(), 10).await.unwrap().len(), 1);
    assert_eq!(
        store.image_counts(READER.into()).await.unwrap(),
        ImageCounts {
            total: 2,
            read: 1,
            with_words: 1,
            with_embedding: 0
        }
    );
    // a newer reader has read none.
    assert_eq!(store.images_to_read("test-reader-2".into(), 10).await.unwrap().len(), 2);
}

#[tokio::test]
async fn a_photo_that_fails_three_times_is_not_asked_for_again() {
    let folder = TempDir::new().unwrap();
    let store = store(&folder).await;
    store.add_images(vec![image("$1", "!a", "", 1)]).await.unwrap();
    for _ in 0..3 {
        assert_eq!(store.images_to_read(READER.into(), 10).await.unwrap().len(), 1);
        store.image_unread("$1".into()).await.unwrap();
    }
    assert!(store.images_to_read(READER.into(), 10).await.unwrap().is_empty());
}

#[tokio::test]
async fn finds_a_photo_by_its_caption_and_the_words_in_it() {
    let folder = TempDir::new().unwrap();
    let store = store(&folder).await;
    store
        .add_images(vec![
            image("$receipt", "!a", "", 1),
            image("$beach", "!a", "Pláž v Chorvatsku", 2),
        ])
        .await
        .unwrap();
    store
        .set_images_read(vec![read("$receipt", "Faktura č. 2024-11 Celkem 1 250 Kč", None)])
        .await
        .unwrap();
    assert_eq!(found(&store, search("faktura", None)).await, ["$receipt"]);
    assert_eq!(found(&store, search("plaz chorv", None)).await, ["$beach"]);
    let hit = store.search_images(search("celkem", None)).await.unwrap().remove(0);
    let ImageReason::Words { excerpt, matches } = hit.reason else {
        panic!("found by its words");
    };
    let utf16: Vec<u16> = excerpt.encode_utf16().collect();
    let range = &matches[0];
    assert_eq!(
        String::from_utf16(&utf16[range.start as usize..range.end as usize]).unwrap(),
        "Celkem"
    );
}

#[tokio::test]
async fn finds_a_photo_by_a_message_sent_near_it_in_its_chat() {
    let folder = TempDir::new().unwrap();
    let store = store(&folder).await;
    store
        .add_images(vec![
            image("$near", "!a", "", 1_000),
            image("$later", "!a", "", 1_000 + 10 * 60),
            image("$elsewhere", "!b", "", 1_000),
        ])
        .await
        .unwrap();
    store
        .add(vec![IndexedMessage {
            event_id: "$text".into(),
            room: "!a".into(),
            sender_name: "Anna".into(),
            body: "Fotky z dovolené v Chorvatsku".into(),
            date: at(1_000 - 30),
            is_own: false,
        }])
        .await
        .unwrap();
    let hits = store.search_images(search("dovolen", None)).await.unwrap();
    assert_eq!(hits.len(), 1);
    assert_eq!(hits[0].event_id, EventId::from("$near"));
    assert!(matches!(&hits[0].reason, ImageReason::Nearby { excerpt, .. } if excerpt.contains("dovolené")));
}

#[tokio::test]
async fn finds_a_photo_by_its_look_and_ranks_one_found_both_ways_first() {
    let folder = TempDir::new().unwrap();
    let store = store(&folder).await;
    store
        .add_images(vec![
            image("$dog", "!a", "", 1),
            image("$cat", "!a", "", 2),
            image("$sign", "!a", "", 3),
        ])
        .await
        .unwrap();
    store
        .set_images_read(vec![
            read("$dog", "", Some(vec![1.0, 0.0, 0.0])),
            read("$cat", "", Some(vec![0.0, 1.0, 0.0])),
            read("$sign", "DOG PARK", Some(vec![0.8, 0.0, 0.6])),
        ])
        .await
        .unwrap();
    let counts = store.image_counts(READER.into()).await.unwrap();
    assert_eq!((counts.with_words, counts.with_embedding), (3, 3));
    // by look alone: the most alike first, the unlike left out.
    assert_eq!(
        found(&store, search("", Some(vec![1.0, 0.0, 0.0]))).await,
        ["$dog", "$sign"]
    );
    // found by its words and its look, the sign comes first.
    assert_eq!(
        found(&store, search("dog", Some(vec![1.0, 0.0, 0.0]))).await,
        ["$sign", "$dog"]
    );
    let hits = store
        .search_images(search("", Some(vec![1.0, 0.0, 0.0])))
        .await
        .unwrap();
    assert!(matches!(hits[0].reason, ImageReason::Looks { similarity } if similarity > 0.99));
}

#[tokio::test]
async fn turned_off_the_embeddings_go_the_words_stay_and_a_deleted_photo_goes() {
    let folder = TempDir::new().unwrap();
    let store = store(&folder).await;
    store
        .add_images(vec![image("$1", "!a", "", 1), image("$2", "!a", "", 2)])
        .await
        .unwrap();
    store
        .set_images_read(vec![
            read("$1", "Faktura", Some(vec![1.0, 0.0])),
            read("$2", "Faktura", None),
        ])
        .await
        .unwrap();
    store.remove(vec!["$2".into()]).await.unwrap();
    assert_eq!(found(&store, search("faktura", None)).await, ["$1"]);
    store.forget_image_embeddings("words-only".into()).await.unwrap();
    // found by its words still, no longer by its look; read by the reader without the model.
    assert_eq!(found(&store, search("faktura", None)).await, ["$1"]);
    assert!(found(&store, search("", Some(vec![1.0, 0.0]))).await.is_empty());
    assert_eq!(
        store.image_counts("words-only".into()).await.unwrap(),
        ImageCounts {
            total: 1,
            read: 1,
            with_words: 1,
            with_embedding: 0
        }
    );
    // a forgotten chat's photos go with its messages.
    store.forget_chat("!a".into(), None).await.unwrap();
    assert_eq!(store.image_counts(READER.into()).await.unwrap().total, 0);
}
