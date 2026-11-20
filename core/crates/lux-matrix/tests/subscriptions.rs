//! An open chat's room subscription against a mock server that keeps a sync's timeline window as
//! a server does: the room list asks each room for its last event, a subscription for its last
//! 20, and a sync that brings more than the window is limited, with a gap before it.

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

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use futures_util::StreamExt;
use lux_core::chat::ChatRoom;
use lux_core::ids::{ChatId, MessageId, RoomId, TimelineId};
use lux_core::message::SendState;
use lux_core::network::Network;
use lux_core::ports::{ChatAccount, ChatSending, ChatTimelines, DiffStream};
use lux_core::thread::{ReadReceipts, ThreadListener, ThreadRow, ThreadSpec, ThreadUpdate, ThreadViewModel, Upload};
use lux_core::timeline::TimelineMessage;
use matrix_sdk::test_utils::mocks::RoomMessagesResponseTemplate;
use serde_json::{Value, json};
use tokio::sync::watch;
use wiremock::matchers::{method, path, path_regex};
use wiremock::{Mock, Request, Respond, ResponseTemplate};

mod support;
use support::{server, signed_in};

const ROOM: &str = "!anna:example.org";

/// The room's events the next sync brings, and whether the last sync subscribed to the room.
#[derive(Clone)]
struct Room {
    pending: Arc<Mutex<Vec<Value>>>,
    subscribed: Arc<watch::Sender<bool>>,
    position: Arc<AtomicUsize>,
}

impl Room {
    fn new(events: &[(&str, &str)]) -> Self {
        let room = Self {
            pending: Arc::default(),
            subscribed: Arc::new(watch::channel(false).0),
            position: Arc::default(),
        };
        room.bring(events);
        room
    }

    /// The next sync brings `events` (id, body): Anna's, or the account's own `$hello`.
    fn bring(&self, events: &[(&str, &str)]) {
        let mut pending = self.pending.lock().unwrap();
        for (id, body) in events {
            let sender = if *id == "$hello" {
                "@cheeky_monkey:matrix.org"
            } else {
                "@anna:example.org"
            };
            pending.push(json!({
                "type": "m.room.message", "event_id": id, "sender": sender,
                "origin_server_ts": 1_700_000_000_000_u64,
                "content": { "msgtype": "m.text", "body": body },
            }));
        }
    }
}

impl Respond for Room {
    fn respond(&self, request: &Request) -> ResponseTemplate {
        let body: Value = serde_json::from_slice(&request.body).unwrap_or_default();
        let position = self.position.fetch_add(1, Ordering::SeqCst).to_string();
        // the sync long-polls: not every few milliseconds.
        let answer = |body: Value| {
            ResponseTemplate::new(200)
                .set_body_json(body)
                .set_delay(Duration::from_millis(200))
        };
        if body["conn_id"] != "room-list" {
            return answer(json!({ "pos": position }));
        }
        let subscription = &body["room_subscriptions"][ROOM];
        self.subscribed.send_replace(subscription.is_object());
        let window = subscription["timeline_limit"]
            .as_u64()
            .or_else(|| body["lists"]["all_rooms"]["timeline_limit"].as_u64())
            .and_then(|window| usize::try_from(window).ok())
            .unwrap_or(1);
        let mut events = std::mem::take(&mut *self.pending.lock().unwrap());
        let limited = events.len() > window;
        let timeline = events.split_off(events.len().saturating_sub(window));
        let mut room = json!({
            "name": "Anna", "initial": true, "joined_count": 2,
            "timeline": timeline, "limited": limited,
        });
        if limited {
            room["prev_batch"] = json!("gap");
        }
        answer(json!({
            "pos": position,
            "lists": { "all_rooms": { "count": 1 } },
            "rooms": { ROOM: room },
        }))
    }
}

/// Applies the next batch of `batches` to `shown`.
async fn next_batch(batches: &mut DiffStream<Arc<TimelineMessage>>, shown: &mut Vec<Arc<TimelineMessage>>) {
    let mut list: eyeball_im::Vector<Arc<TimelineMessage>> = shown.iter().cloned().collect();
    for diff in batches.next().await.unwrap() {
        diff.apply(&mut list);
    }
    *shown = list.into_iter().collect();
}

fn bodies(shown: &[Arc<TimelineMessage>]) -> Vec<&str> {
    shown.iter().map(|message| message.message.body.as_str()).collect()
}

#[tokio::test(flavor = "multi_thread")]
async fn a_send_in_an_open_chat_and_an_answer_in_one_sync_keep_the_chats_messages() {
    let server = server().await;
    let room = Room::new(&[("$one", "one")]);
    Mock::given(method("POST"))
        .and(path("/_matrix/client/unstable/org.matrix.simplified_msc3575/sync"))
        .respond_with(room.clone())
        .mount(server.server())
        .await;
    server.mock_room_state_encryption().plain().mount().await;
    // the room's start: nothing before what the syncs brought.
    server
        .mock_room_messages()
        .ok(RoomMessagesResponseTemplate::default())
        .mount()
        .await;
    Mock::given(method("PUT"))
        .and(path_regex(r"/rooms/[^/]+/send/"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({ "event_id": "$hello" })))
        .mount(server.server())
        .await;
    let (account, _folder) = signed_in(&server).await;
    tokio::time::timeout(Duration::from_secs(10), account.wait_for_first_sync())
        .await
        .unwrap();

    // the chat opens: its room is subscribed, its window 20 events.
    let chat = TimelineId::from(&RoomId::from(ROOM));
    let timelines = account.timelines();
    let _hold = timelines.hold(&chat);
    tokio::time::timeout(Duration::from_secs(10), room.subscribed.subscribe().wait_for(|on| *on))
        .await
        .unwrap()
        .unwrap();
    room.bring(&[("$two", "two")]);
    let mut batches = timelines.messages(&chat).await.unwrap();
    let mut shown = Vec::new();
    tokio::time::timeout(Duration::from_secs(10), async {
        while !bodies(&shown).contains(&"two") {
            next_batch(&mut batches, &mut shown).await;
        }
    })
    .await
    .expect("the chat shows its messages");

    timelines.send_text(&chat, &"hello".into(), None).await.unwrap();
    tokio::time::timeout(Duration::from_secs(10), async {
        while !shown
            .iter()
            .any(|message| message.message.body == "hello" && message.message.state == SendState::Sent)
        {
            next_batch(&mut batches, &mut shown).await;
        }
    })
    .await
    .expect("the message is sent");
    let before: Vec<(String, MessageId)> = shown
        .iter()
        .map(|message| (message.message.body.clone(), message.message.id.clone()))
        .collect();

    // one sync brings the sent message and Anna's answer: more than the room list's window of one
    // event, within the subscription's.
    room.bring(&[("$hello", "hello"), ("$six", "six")]);
    tokio::time::timeout(Duration::from_secs(10), async {
        while !bodies(&shown).contains(&"six") {
            next_batch(&mut batches, &mut shown).await;
            for (body, id) in &before {
                assert!(
                    shown
                        .iter()
                        .any(|message| message.message.body == *body && message.message.id == *id),
                    "{body} left the chat or changed its id: {:?}",
                    bodies(&shown)
                );
            }
        }
    })
    .await
    .expect("the answer arrives");
    assert_eq!(bodies(&shown), ["one", "two", "hello", "six"]);
}

/// The view model's next update, applied to `rows`.
async fn next_update(
    heard: &mut tokio::sync::mpsc::UnboundedReceiver<ThreadUpdate>,
    rows: &mut eyeball_im::Vector<Arc<ThreadRow>>,
) -> ThreadUpdate {
    let update = tokio::time::timeout(Duration::from_secs(10), heard.recv())
        .await
        .expect("an update in time")
        .unwrap();
    for diff in update.rows.clone() {
        diff.apply(rows);
    }
    update
}

/// Hears an open chat's view model: its updates, in order.
struct Ear(tokio::sync::mpsc::UnboundedSender<ThreadUpdate>);

impl ThreadListener for Ear {
    fn on_update(&self, update: ThreadUpdate) {
        self.0.send(update).unwrap();
    }

    fn on_upload(&self, _upload: Upload) {}

    fn on_error(&self, error: lux_core::ports::BackendError) {
        panic!("an action failed: {error}");
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn a_reset_keeps_an_open_chats_rows_until_its_view_pages_its_gap_back() {
    let server = server().await;
    let room = Room::new(&[("$one", "one")]);
    Mock::given(method("POST"))
        .and(path("/_matrix/client/unstable/org.matrix.simplified_msc3575/sync"))
        .respond_with(room.clone())
        .mount(server.server())
        .await;
    server.mock_room_state_encryption().plain().mount().await;
    // the gap a limited sync leaves: its page back comes slowly, as from a busy server.
    let event = |id: &str, body: &str| {
        json!({
            "type": "m.room.message", "event_id": id, "sender": "@anna:example.org",
            "origin_server_ts": 1_700_000_000_000_u64, "room_id": ROOM,
            "content": { "msgtype": "m.text", "body": body },
        })
    };
    let gap: Vec<Value> = (0..5)
        .rev()
        .map(|n| event(&format!("$new{n}"), &format!("new {n}")))
        .chain([event("$one", "one")])
        .collect();
    Mock::given(method("GET"))
        .and(path_regex(r"/rooms/[^/]+/messages$"))
        .and(wiremock::matchers::query_param("from", "gap"))
        .respond_with(
            ResponseTemplate::new(200)
                .set_body_json(json!({ "start": "gap", "chunk": gap }))
                .set_delay(Duration::from_millis(300)),
        )
        .expect(1)
        .mount(server.server())
        .await;
    // the room's start: nothing before what the syncs brought.
    server
        .mock_room_messages()
        .ok(RoomMessagesResponseTemplate::default())
        .mount()
        .await;
    let (account, _folder) = signed_in(&server).await;
    tokio::time::timeout(Duration::from_secs(10), account.wait_for_first_sync())
        .await
        .unwrap();
    let account = Arc::new(account);

    // the chat opens on its one message.
    let (ear, mut heard) = tokio::sync::mpsc::unbounded_channel();
    let chat = RoomId::from(ROOM);
    let spec = ThreadSpec {
        chat: ChatId::Room(chat.clone()),
        rooms: vec![ChatRoom {
            id: chat.clone(),
            network: Network::Matrix,
        }],
        default_room: chat,
        listed_unread: false,
        read_receipts: ReadReceipts::Manual,
        zone: jiff::tz::TimeZone::UTC,
        thread: None,
    };
    let _model = ThreadViewModel::open(
        &tokio::runtime::Handle::current(),
        Arc::clone(&account),
        spec,
        Arc::new(Ear(ear)),
    );
    let mut rows: eyeball_im::Vector<Arc<ThreadRow>> = eyeball_im::Vector::new();
    let bodies = |rows: &eyeball_im::Vector<Arc<ThreadRow>>| -> Vec<String> {
        rows.iter().map(|row| row.message.message.body.clone()).collect()
    };
    let mut loading = true;
    while bodies(&rows) != ["one"] || loading {
        let update = next_update(&mut heard, &mut rows).await;
        loading = update.state.map_or(loading, |state| state.is_loading);
    }
    let before = rows.clone();

    // a sync brings more than the subscription's window of 20: it is limited, and the timeline
    // is reset to its newest 20, a gap before them.
    let newest: Vec<(String, String)> = (0..25).map(|n| (format!("$new{n}"), format!("new {n}"))).collect();
    room.bring(
        &newest
            .iter()
            .map(|(id, body)| (id.as_str(), body.as_str()))
            .collect::<Vec<_>>(),
    );
    let mut updates = Vec::new();
    while rows.len() < 1 + 25 {
        updates.push(next_update(&mut heard, &mut rows).await);
    }
    // the rows never shrank: the reset's batch was held back until the page back brought the
    // rows the chat showed, by the same ids, then the rest went in around them, no news.
    let mut shown: eyeball_im::Vector<Arc<ThreadRow>> = before.clone();
    for update in &updates {
        for diff in update.rows.clone() {
            diff.apply(&mut shown);
        }
        assert!(shown.len() >= before.len() && shown.front().map(|row| row.id()) == before.front().map(|row| row.id()));
        assert_eq!(update.cause, None);
    }
    // the view paged back for the gap, once: the refill, not the rows the reset left.
    server.server().verify().await;
}
