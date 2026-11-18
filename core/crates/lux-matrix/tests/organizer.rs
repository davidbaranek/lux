//! The organizing kept in the account's data, against the SDK's mock server: what the sync
//! brings is applied to the chat list (and follows another device's changes live), and the
//! user's changes are written in the formats the account already has.

// the sdk's futures nest deeply.
#![recursion_limit = "256"]
// a test crate: a failed step is the test failing.
#![allow(
    clippy::unwrap_used,
    clippy::expect_used,
    clippy::panic,
    clippy::indexing_slicing,
    reason = "a test's helpers fail it as its asserts do"
)]

use std::sync::Arc;
use std::time::Duration;

use futures_util::StreamExt;
use lux_core::chat::{Chat, Folder};
use lux_core::ids::{ChatId, RoomId};
use lux_core::organizer::Organized;
use lux_core::ports::{ChatAccount, ChatActions, ChatChange, ChatTimelines, DiffStream, Organizing, Scheduling};
use lux_core::timeline::TimelineMessage;
use lux_matrix::MatrixAccount;
use matrix_sdk::test_utils::mocks::MatrixMockServer;
use serde_json::{Value, json};
use wiremock::matchers::{body_partial_json, method, path, path_regex, query_param_contains};
use wiremock::{Mock, ResponseTemplate};

mod support;
use support::signed_in;

const ROOM: &str = "!anna:matrix.org";
const OTHER: &str = "!bob:matrix.org";
/// The rooms' newest message.
const NEWEST: u64 = 1_700_000_000_000;

fn room(name: &str, sender: &str, ts: u64) -> Value {
    json!({
        "name": name,
        "initial": true,
        "joined_count": 2,
        "timeline": [{
            "type": "m.room.message",
            "event_id": format!("$m{ts}{name}"),
            "sender": sender,
            "origin_server_ts": ts,
            "content": { "msgtype": "m.text", "body": "hello" }
        }]
    })
}

/// A sliding sync answer with the two rooms and `account_data` (global events).
fn answer(pos: &str, account_data: &[Value]) -> Value {
    json!({
        "pos": pos,
        "lists": { "all_rooms": { "count": 2 } },
        "rooms": {
            ROOM: room("Anna", "@anna:matrix.org", NEWEST),
            OTHER: room("Bob", "@bob:matrix.org", NEWEST - 1000),
        },
        "extensions": { "account_data": { "global": account_data } }
    })
}

/// Answers the room list's next sliding sync once with `body` (the encryption's sync is another).
async fn sync_once(server: &MatrixMockServer, body: Value) {
    Mock::given(method("POST"))
        .and(path("/_matrix/client/unstable/org.matrix.simplified_msc3575/sync"))
        .and(body_partial_json(json!({ "conn_id": "room-list" })))
        .respond_with(ResponseTemplate::new(200).set_body_json(body))
        .up_to_n_times(1)
        .with_priority(1)
        .mount(server.server())
        .await;
}

/// A server that answers the first sync with the rooms and `account_data`, then waits.
async fn server(account_data: &[Value]) -> MatrixMockServer {
    let server = support::server().await;
    // the rooms are not encrypted.
    Mock::given(method("GET"))
        .and(path_regex(
            r"^/_matrix/client/v3/rooms/[^/]+/state/m\.room\.encryption/?$",
        ))
        .respond_with(
            ResponseTemplate::new(404).set_body_json(json!({ "errcode": "M_NOT_FOUND", "error": "no encryption" })),
        )
        .mount(server.server())
        .await;
    sync_once(&server, answer("1", account_data)).await;
    // then nothing new: the sync long-polls.
    Mock::given(method("POST"))
        .and(path("/_matrix/client/unstable/org.matrix.simplified_msc3575/sync"))
        .respond_with(
            ResponseTemplate::new(200)
                .set_body_json(json!({ "pos": "idle", "lists": { "all_rooms": { "count": 2 } } }))
                .set_delay(Duration::from_millis(300)),
        )
        .with_priority(5)
        .mount(server.server())
        .await;
    server
}

/// Follows the chat list until `done` holds.
async fn list_until(account: &MatrixAccount, done: impl Fn(&[Chat]) -> bool) -> Vec<Chat> {
    let mut stream = account.chats();
    let mut rows = eyeball_im::Vector::new();
    tokio::time::timeout(Duration::from_secs(10), async {
        while let Some(batch) = stream.next().await {
            for diff in batch {
                diff.apply(&mut rows);
            }
            let list: Vec<Chat> = rows.iter().map(|chat: &Arc<Chat>| Chat::clone(chat)).collect();
            if done(&list) {
                return list;
            }
        }
        panic!("the chat list ended");
    })
    .await
    .expect("the chat list did not get there in time")
}

/// Follows what is organized until `done` holds.
async fn organized_until(account: &MatrixAccount, done: impl Fn(&Organized) -> bool) -> Arc<Organized> {
    let mut stream = account.organized();
    tokio::time::timeout(Duration::from_secs(10), async {
        while let Some(organized) = stream.next().await {
            if done(&organized) {
                return organized;
            }
        }
        panic!("the organizer ended");
    })
    .await
    .expect("the organizing did not get there in time")
}

fn find<'a>(list: &'a [Chat], id: &str) -> Option<&'a Chat> {
    list.iter().find(|chat| chat.id == ChatId::from(id))
}

/// The room is listed with its newest message.
fn listed(list: &[Chat], id: &str) -> bool {
    find(list, id).is_some_and(|chat| chat.date.is_some())
}

/// Both rooms are listed with their newest message: the sync's rooms come into the list one by
/// one, and the user acts only on chats the list shows.
fn both_listed(list: &[Chat]) -> bool {
    listed(list, ROOM) && listed(list, OTHER)
}

/// Accepts a write of the account data event `event_type` whose content holds `body`.
async fn expect_write(server: &MatrixMockServer, event_type: &str, body: Value) {
    Mock::given(method("PUT"))
        .and(path_regex(format!(
            "^/_matrix/client/v3/user/[^/]+/account_data/{}$",
            regex(event_type)
        )))
        .and(body_partial_json(body))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({})))
        .expect(1)
        .mount(server.server())
        .await;
}

fn regex(text: &str) -> String {
    text.replace('.', r"\.")
}

#[tokio::test(flavor = "multi_thread")]
async fn the_account_data_from_the_sync_organizes_the_list() {
    let server = server(&[
        json!({ "type": "com.bardav.lux.chats", "content": {
            "archived": { ROOM: { "ts": NEWEST } }, "hidden": {}, "cleared": {}
        }}),
        json!({ "type": "com.bardav.lux.reminders", "content": {
            "reminders": { OTHER: { "at": NEWEST + 60_000, "set": NEWEST - 5000 } }
        }}),
    ])
    .await;
    let (account, _folder) = signed_in(&server).await;

    let list = list_until(&account, |list| {
        both_listed(list) && find(list, ROOM).is_some_and(|chat| chat.folder == Folder::Archive)
    })
    .await;
    let other = find(&list, OTHER).unwrap();
    assert_eq!(other.folder, Folder::Inbox);
    assert!(other.reminder.is_some());

    // another device merges the two: the next sync brings it, and the list follows.
    sync_once(
        &server,
        json!({
            "pos": "2",
            "lists": { "all_rooms": { "count": 2 } },
            "extensions": { "account_data": { "global": [{
                "type": "com.bardav.lux.merges",
                "content": { "merges": [{ "id": "M", "name": "Anna & Bob", "rooms": [OTHER, ROOM], "default": ROOM }] }
            }]}}
        }),
    )
    .await;
    let list = list_until(&account, |list| find(list, "merge:M").is_some()).await;
    assert_eq!(list.len(), 1);
    let merged = &list[0];
    assert_eq!(merged.name, "Anna & Bob");
    assert_eq!(merged.default_room, Some(RoomId::from(ROOM)));
    // the merged chat stands for its rooms: their reminder and the newest one's folder.
    assert!(merged.reminder.is_some());
    assert_eq!(merged.folder, Folder::Archive);
}

#[tokio::test(flavor = "multi_thread")]
async fn archiving_writes_the_mark_and_the_list_shows_it_at_once() {
    // another device archived Bob, and a later version of the app keeps more in the event.
    let server = server(&[json!({ "type": "com.bardav.lux.chats", "content": {
        "archived": { OTHER: { "ts": NEWEST } }, "later": 1
    }})])
    .await;
    expect_write(
        &server,
        "com.bardav.lux.chats",
        json!({ "archived": { ROOM: { "ts": NEWEST }, OTHER: { "ts": NEWEST } }, "later": 1 }),
    )
    .await;
    let (account, _folder) = signed_in(&server).await;
    list_until(&account, |list| {
        listed(list, ROOM) && find(list, OTHER).is_some_and(|chat| chat.folder == Folder::Archive)
    })
    .await;

    account.change(&ChatId::from(ROOM), ChatChange::Archive).await.unwrap();
    list_until(&account, |list| {
        find(list, ROOM).is_some_and(|chat| chat.folder == Folder::Archive)
    })
    .await;
}

#[tokio::test(flavor = "multi_thread")]
async fn a_deleted_chat_leaves_the_list_and_its_thread_is_cut() {
    let server = server(&[]).await;
    expect_write(
        &server,
        "com.bardav.lux.chats",
        json!({ "hidden": { ROOM: { "ts": NEWEST } }, "cleared": { ROOM: { "ts": NEWEST } } }),
    )
    .await;
    let (account, _folder) = signed_in(&server).await;
    list_until(&account, |list| listed(list, ROOM)).await;
    let mut thread = account.timelines().messages(&RoomId::from(ROOM).into()).await.unwrap();
    let mut messages = eyeball_im::Vector::new();
    let says_hello = |messages: &eyeball_im::Vector<Arc<TimelineMessage>>| {
        messages.iter().any(|message| message.message.body == "hello")
    };
    follow_until(&mut thread, &mut messages, says_hello).await;

    account.change(&ChatId::from(ROOM), ChatChange::Delete).await.unwrap();
    list_until(&account, |list| {
        find(list, ROOM).is_none() && find(list, OTHER).is_some()
    })
    .await;
    // the open thread starts after the delete: the message from before is gone.
    follow_until(&mut thread, &mut messages, |messages| !says_hello(messages)).await;
}

#[tokio::test(flavor = "multi_thread")]
async fn a_deleted_chat_gives_search_nothing_from_before_the_delete() {
    let server = server(&[]).await;
    expect_write(
        &server,
        "com.bardav.lux.chats",
        json!({ "hidden": { ROOM: { "ts": NEWEST } }, "cleared": { ROOM: { "ts": NEWEST } } }),
    )
    .await;
    // the room's history, as the server pages back: the message from before the delete.
    Mock::given(method("GET"))
        .and(path_regex(r"/rooms/.*/messages$"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "start": "t1",
            "chunk": [{
                "type": "m.room.message",
                "event_id": "$before",
                "room_id": ROOM,
                "sender": "@anna:matrix.org",
                "origin_server_ts": NEWEST,
                "content": { "msgtype": "m.text", "body": "hello" }
            }]
        })))
        .mount(server.server())
        .await;
    let (account, _folder) = signed_in(&server).await;
    list_until(&account, |list| listed(list, ROOM)).await;
    let since = std::time::SystemTime::UNIX_EPOCH;
    let room = RoomId::from(ROOM);
    let before = account.timelines().index_history(&room, since, None, 1).await.unwrap();
    assert_eq!(before.messages.len(), 1);
    assert_eq!(before.deleted_until, None);

    account.change(&ChatId::from(ROOM), ChatChange::Delete).await.unwrap();
    list_until(&account, |list| find(list, ROOM).is_none()).await;

    let after = account.timelines().index_history(&room, since, None, 1).await.unwrap();
    assert!(after.messages.is_empty());
    assert_eq!(
        after.deleted_until,
        Some(std::time::SystemTime::UNIX_EPOCH + Duration::from_millis(NEWEST))
    );
}

/// Follows a thread's messages until `done` holds.
async fn follow_until(
    thread: &mut DiffStream<Arc<TimelineMessage>>,
    messages: &mut eyeball_im::Vector<Arc<TimelineMessage>>,
    done: impl Fn(&eyeball_im::Vector<Arc<TimelineMessage>>) -> bool,
) {
    tokio::time::timeout(Duration::from_secs(10), async {
        while let Some(batch) = thread.next().await {
            for diff in batch {
                diff.apply(messages);
            }
            if done(messages) {
                return;
            }
        }
        panic!("the thread ended");
    })
    .await
    .expect("the thread did not get there in time");
}

/// Accepts the label records: a name record named `name`, room records, and the markers that
/// tell other devices to read them again.
async fn accept_label_writes(server: &MatrixMockServer, name: &str, rooms: u64, markers: u64) {
    Mock::given(method("PUT"))
        .and(path_regex(
            r"^/_matrix/client/v3/user/[^/]+/account_data/com\.bardav\.lux\.labels\.v2\.name\.[0-9a-f]{64}$",
        ))
        .and(body_partial_json(json!({ "name": name })))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({})))
        .expect(1)
        .mount(server.server())
        .await;
    Mock::given(method("PUT"))
        .and(path_regex(
            r"^/_matrix/client/v3/user/[^/]+/account_data/com\.bardav\.lux\.labels\.v2\.room\.[0-9a-f]{64}$",
        ))
        .and(body_partial_json(json!({ "roomId": ROOM, "included": true })))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({})))
        .expect(rooms)
        .mount(server.server())
        .await;
    Mock::given(method("PUT"))
        .and(path_regex(
            r"^/_matrix/client/v3/user/[^/]+/account_data/com\.bardav\.lux\.labels\.changed$",
        ))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({})))
        .expect(markers)
        .mount(server.server())
        .await;
}

#[tokio::test(flavor = "multi_thread")]
async fn a_chat_put_in_a_new_label_shows_in_it_and_is_written_as_records() {
    let server = server(&[]).await;
    accept_label_writes(&server, "Work", 1, 2).await;
    let (account, _folder) = signed_in(&server).await;
    list_until(&account, both_listed).await;

    let label = account.make_label(" Work ").await.unwrap();
    assert_eq!(label.name, "Work");
    account
        .set_in_label(&ChatId::from(ROOM), &label.id, true)
        .await
        .unwrap();
    organized_until(&account, |organized| {
        organized
            .labels
            .iter()
            .any(|label| label.chats.contains(&ChatId::from(ROOM)))
    })
    .await;
}

#[tokio::test(flavor = "multi_thread")]
async fn a_label_name_taken_in_another_case_is_refused() {
    let server = server(&[]).await;
    accept_label_writes(&server, "Work", 0, 1).await;
    let (account, _folder) = signed_in(&server).await;
    list_until(&account, both_listed).await;

    account.make_label("Work").await.unwrap();
    assert!(matches!(
        account.make_label("work").await,
        Err(lux_core::ports::BackendError::Label(
            lux_core::organizer::LabelError::DuplicateName
        ))
    ));
}

#[tokio::test(flavor = "multi_thread")]
async fn merged_chats_are_written_and_show_as_one() {
    let server = server(&[]).await;
    expect_write(
        &server,
        "com.bardav.lux.merges",
        json!({ "merges": [{ "name": "Anna", "rooms": [ROOM, OTHER], "default": OTHER }] }),
    )
    .await;
    let (account, _folder) = signed_in(&server).await;
    list_until(&account, both_listed).await;

    let merged = account
        .merge(&[ChatId::from(ROOM), ChatId::from(OTHER)], "Anna", &RoomId::from(OTHER))
        .await
        .unwrap();
    let list = list_until(&account, |list| find(list, &merged.to_string()).is_some()).await;
    assert_eq!(list.len(), 1);
}

#[tokio::test(flavor = "multi_thread")]
async fn a_reminder_of_a_merged_chat_is_written_for_each_of_its_rooms() {
    let server = server(&[json!({ "type": "com.bardav.lux.merges", "content": {
        "merges": [{ "id": "M", "name": "Anna", "rooms": [ROOM, OTHER], "default": ROOM }]
    }})])
    .await;
    let at = NEWEST + 3_600_000;
    expect_write(
        &server,
        "com.bardav.lux.reminders",
        json!({ "reminders": { ROOM: { "at": at }, OTHER: { "at": at } } }),
    )
    .await;
    let (account, _folder) = signed_in(&server).await;
    list_until(&account, |list| find(list, "merge:M").is_some()).await;

    let when = std::time::UNIX_EPOCH + Duration::from_millis(at);
    account
        .set_reminder(&ChatId::from("merge:M"), Some(when))
        .await
        .unwrap();
    list_until(&account, |list| {
        find(list, "merge:M").is_some_and(|chat| chat.reminder == Some(when))
    })
    .await;
}

#[tokio::test(flavor = "multi_thread")]
async fn the_places_arrangement_is_written() {
    let server = server(&[]).await;
    expect_write(
        &server,
        "com.bardav.lux.place_order",
        json!({ "order": ["network:whatsapp"], "hidden": ["space:!s"] }),
    )
    .await;
    let (account, _folder) = signed_in(&server).await;

    let mut arrangement = lux_core::places::Arrangement::default();
    arrangement.order.push("network:whatsapp".into());
    arrangement.hidden.insert("space:!s".into());
    arrangement
        .themes
        .insert("space:!s".into(), lux_core::places::Theme::Teal);
    arrangement.theme = lux_core::places::Theme::Purple;
    account.set_arrangement(&arrangement).await.unwrap();
    organized_until(&account, |organized| organized.arrangement == arrangement).await;
}

#[tokio::test(flavor = "multi_thread")]
async fn the_labels_records_are_read_from_the_server_at_launch() {
    let server = server(&[]).await;
    Mock::given(method("GET"))
        .and(path("/_matrix/client/v3/sync"))
        .and(query_param_contains("filter", "com.bardav.lux.labels.v2.*"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "next_batch": "s1",
            "account_data": { "events": [
                { "type": "com.bardav.lux.labels", "content": { "labels": [{ "id": "W", "name": "Work", "roomIds": [ROOM] }] } },
                { "type": "com.bardav.lux.labels.v2.room.f17805b160f67e0ce2987ce0d66d65ba6eeb5a163e5897f2c6ef8fc8eb52ae21",
                  "content": { "id": "L", "roomId": "!a:x", "included": true } },
                { "type": "com.bardav.lux.labels.v2.name.ee6482e3c3ed581458c69fea1a4b38f7dc4e095b9cd4f87177abe73eaa2a364f",
                  "content": { "id": "L", "name": "Later" } }
            ]}
        })))
        .mount(server.server())
        .await;
    let (account, _folder) = signed_in(&server).await;
    let organized = organized_until(&account, |organized| organized.labels.len() == 2).await;
    assert_eq!(organized.labels[0].name, "Work");
    assert_eq!(organized.labels[1].name, "Later");
    assert!(organized.labels[1].chats.contains(&ChatId::from("!a:x")));
}

#[tokio::test(flavor = "multi_thread")]
async fn pinning_tags_the_room_after_the_pinned_ones() {
    let server = server(&[]).await;
    Mock::given(method("PUT"))
        .and(path_regex(
            r"^/_matrix/client/v3/user/[^/]+/rooms/[^/]+/tags/m\.favourite$",
        ))
        .and(body_partial_json(json!({ "order": 0.5 })))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({})))
        .expect(1)
        .mount(server.server())
        .await;
    let (account, _folder) = signed_in(&server).await;
    list_until(&account, |list| find(list, ROOM).is_some()).await;
    account.change(&ChatId::from(ROOM), ChatChange::Pin).await.unwrap();
}

#[tokio::test(flavor = "multi_thread")]
async fn a_refusal_reaches_the_caller_with_the_servers_status_and_code() {
    let server = server(&[]).await;
    Mock::given(method("PUT"))
        .and(path_regex(
            r"^/_matrix/client/v3/user/[^/]+/rooms/[^/]+/tags/m\.favourite$",
        ))
        .respond_with(ResponseTemplate::new(400).set_body_json(json!({ "errcode": "M_BAD_JSON", "error": "no" })))
        .mount(server.server())
        .await;
    let (account, _folder) = signed_in(&server).await;
    list_until(&account, |list| find(list, ROOM).is_some()).await;

    let refused = account.change(&ChatId::from(ROOM), ChatChange::Pin).await;
    assert!(
        matches!(
            &refused,
            Err(lux_core::ports::BackendError::Server { status: Some(400), errcode: Some(code), .. })
                if code == "M_BAD_JSON"
        ),
        "{refused:?}"
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn a_message_is_sent_later_by_the_server() {
    let server = server(&[]).await;
    Mock::given(method("PUT"))
        .and(path_regex(
            r"^/_matrix/client/v3/rooms/[^/]+/send/m\.room\.message/[^/]+$",
        ))
        .and(query_param_contains("org.matrix.msc4140.delay", ""))
        .and(body_partial_json(json!({ "msgtype": "m.text", "body": "later" })))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({ "delay_id": "D1" })))
        .expect(1)
        .mount(server.server())
        .await;
    Mock::given(method("GET"))
        .and(path("/_matrix/client/unstable/org.matrix.msc4140/delayed_events"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({ "delayed_events": [{
            "delay_id": "D1", "room_id": ROOM, "type": "m.room.message",
            "content": { "msgtype": "m.text", "body": "later" },
            "delay": 60_000, "running_since": NEWEST
        }]})))
        .mount(server.server())
        .await;
    let (account, _folder) = signed_in(&server).await;
    list_until(&account, |list| find(list, ROOM).is_some()).await;

    let room = RoomId::from(ROOM);
    assert!(account.can_send_later(&room).await);
    let at = std::time::SystemTime::now() + Duration::from_secs(3600);
    assert_eq!(account.send_later(&room, "later", None, at).await.unwrap(), "D1".into());
    let waiting = account.scheduled().await.unwrap();
    assert_eq!(waiting.len(), 1);
    assert_eq!(waiting[0].body, "later");
    assert!(matches!(
        account
            .send_later(&room, "past", None, std::time::SystemTime::UNIX_EPOCH)
            .await,
        Err(lux_core::ports::BackendError::TimePassed)
    ));
}
