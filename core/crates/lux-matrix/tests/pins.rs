//! A room's pinned messages against the SDK's mock server: the pinned event read and named, the
//! right to pin by the power levels, pinning sending the room's new `m.room.pinned_events`, and
//! the room subscribed while a chat shows it, as only a subscription brings its pins.

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

use std::collections::BTreeSet;
use std::time::Duration;

use futures_util::StreamExt;
use lux_core::ids::{EventId, RoomId, TimelineId};
use lux_core::ports::{ChatAccount, ChatTimelines, PinsStream};
use lux_core::preview::PreviewKind;
use lux_core::timeline::Pins;
use lux_matrix::MatrixAccount;
use matrix_sdk::test_utils::mocks::MatrixMockServer;
use serde_json::json;
use tokio::sync::watch;
use wiremock::matchers::{PathExactMatcher, body_partial_json, method, path, path_regex};
use wiremock::{Mock, ResponseTemplate};

mod support;

const OWN: &str = "@cheeky_monkey:matrix.org";

fn crew() -> RoomId {
    RoomId::from("!crew:matrix.org")
}

/// A server whose sync brings one encrypted group, "Climbing crew", which the account
/// administers, with the message `$pinned` pinned. As a server does, it sends the room's pinned
/// events only to a sync that subscribes to the room: the room list's own `required_state`
/// leaves them out.
async fn server() -> MatrixMockServer {
    let server = support::server().await;
    answer_subscription(&server, &["$pinned"], 2).await;
    Mock::given(method("POST"))
        .and(sync())
        .respond_with(
            ResponseTemplate::new(200)
                .set_body_json(crew_sync(None))
                .set_delay(Duration::from_millis(200)),
        )
        .mount(server.server())
        .await;
    server
}

fn sync() -> PathExactMatcher {
    path("/_matrix/client/unstable/org.matrix.simplified_msc3575/sync")
}

/// From now on, a sync subscribed to the room brings `pinned` as its pinned events (a lower
/// `priority` answers before a higher one).
async fn answer_subscription(server: &MatrixMockServer, pinned: &[&str], priority: u8) {
    Mock::given(method("POST"))
        .and(sync())
        .and(body_partial_json(
            json!({ "room_subscriptions": { "!crew:matrix.org": {} } }),
        ))
        .respond_with(
            ResponseTemplate::new(200)
                .set_body_json(crew_sync(Some(pinned)))
                .set_delay(Duration::from_millis(200)),
        )
        .with_priority(priority)
        .mount(server.server())
        .await;
}

/// A sync's answer with the group's state, and its pinned events when `pinned` is given.
fn crew_sync(pinned: Option<&[&str]>) -> serde_json::Value {
    let state = |kind: &str, key: &str, content: serde_json::Value| {
        json!({
            "type": kind, "state_key": key, "content": content, "sender": OWN,
            "event_id": format!("${kind}"), "origin_server_ts": 1_700_000_000_000_u64,
        })
    };
    let mut required = vec![
        state(
            "m.room.create",
            "",
            json!({ "creator": "@anna:matrix.org", "room_version": "10" }),
        ),
        state("m.room.name", "", json!({ "name": "Climbing crew" })),
        state("m.room.topic", "", json!({ "topic": "Wednesdays at the wall" })),
        state("m.room.encryption", "", json!({ "algorithm": "m.megolm.v1.aes-sha2" })),
        state("m.room.canonical_alias", "", json!({ "alias": "#crew:matrix.org" })),
        state(
            "m.room.power_levels",
            "",
            json!({
                "users": { OWN: 100, "@anna:matrix.org": 50 },
                "users_default": 0, "state_default": 50,
            }),
        ),
        state("m.room.member", OWN, json!({ "membership": "join" })),
    ];
    if let Some(pinned) = pinned {
        required.push(state("m.room.pinned_events", "", json!({ "pinned": pinned })));
    }
    json!({
        "pos": "1",
        "lists": { "all_rooms": { "count": 1 } },
        "rooms": { "!crew:matrix.org": {
            "name": "Climbing crew",
            "initial": true,
            "joined_count": 3,
            "required_state": required,
        }},
    })
}

/// The server answers for the room's message `id` (`$…`).
async fn answer_event(server: &MatrixMockServer, id: &str, body: &str) {
    let name = id.trim_start_matches('$');
    Mock::given(method("GET"))
        .and(path_regex(format!(
            r"^/_matrix/client/v3/rooms/!crew:matrix.org/event/\${name}/?$"
        )))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "type": "m.room.message", "event_id": id, "sender": "@anna:matrix.org",
            "origin_server_ts": 1_700_000_000_000_u64, "room_id": "!crew:matrix.org",
            "content": { "msgtype": "m.text", "body": body },
        })))
        .mount(server.server())
        .await;
}

/// The pins of `stream` once they list `count` messages: the first answer is the room as it is
/// kept, before the subscription's sync brings its pinned events.
async fn listing(stream: &mut PinsStream, count: usize) -> Pins {
    tokio::time::timeout(Duration::from_secs(10), async {
        loop {
            let pins = stream.next().await.unwrap();
            if pins.messages.len() == count {
                return pins;
            }
        }
    })
    .await
    .expect("the room's pinned events came with its subscription")
}

/// A signed-in account of `server`, synced once, in a new folder (kept with it).
async fn signed_in(server: &MatrixMockServer) -> (MatrixAccount, tempfile::TempDir) {
    let (account, folder) = support::signed_in(server).await;
    tokio::time::timeout(Duration::from_secs(10), account.wait_for_first_sync())
        .await
        .unwrap();
    (account, folder)
}

#[tokio::test(flavor = "multi_thread")]
async fn a_rooms_pinned_message_is_read_seen_and_another_is_pinned() {
    let server = server().await;
    let (account, _folder) = signed_in(&server).await;
    answer_event(&server, "$pinned", "Meet at the wall at six").await;

    // the open chat subscribes to its room, whose sync brings its pinned events.
    let _chat = account.timelines().hold(&TimelineId::from(&crew()));
    let mut pins = account.timelines().pins(&crew()).unwrap();
    let first = listing(&mut pins, 1).await;
    assert!(first.may_pin, "the account's power level lets it pin");
    let pinned: Vec<&str> = first.messages.iter().map(|pin| pin.event.as_str()).collect();
    assert_eq!(pinned, ["$pinned"]);
    assert!(first.seen.is_empty(), "the user has seen no pin yet");
    assert_eq!(
        first.messages[0].kind,
        PreviewKind::Text("Meet at the wall at six".to_owned())
    );

    Mock::given(method("PUT"))
        .and(path_regex(
            r"^/_matrix/client/v3/rooms/!crew:matrix.org/state/m.room.pinned_events/?$",
        ))
        .and(body_partial_json(json!({ "pinned": ["$pinned", "$new"] })))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({ "event_id": "$pins" })))
        .expect(1)
        .mount(server.server())
        .await;
    account
        .timelines()
        .set_pinned(&crew(), &EventId::from("$new"), true)
        .await
        .unwrap();

    // the sync after it brings the room's new pins: the message pinned is among them.
    answer_event(&server, "$new", "Bring the rope").await;
    answer_subscription(&server, &["$pinned", "$new"], 1).await;
    let after = listing(&mut pins, 2).await;
    let pinned: Vec<&str> = after.messages.iter().map(|pin| pin.event.as_str()).collect();
    assert_eq!(pinned, ["$pinned", "$new"]);

    Mock::given(method("PUT"))
        .and(path_regex(
            r"^/_matrix/client/v3/user/[^/]+/rooms/!crew:matrix.org/account_data/im.vector.room.read_pins/?$",
        ))
        .and(body_partial_json(json!({ "event_ids": ["$pinned"] })))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({})))
        .expect(1)
        .mount(server.server())
        .await;
    account
        .timelines()
        .mark_pins_seen(&crew(), &[EventId::from("$pinned")])
        .await
        .unwrap();
}

/// The rooms the room list's syncs subscribed to: how many syncs there were, and the last one's
/// rooms (a matcher that only looks, answering none; the encryption's sync never subscribes).
async fn watch_subscriptions(server: &MatrixMockServer) -> watch::Receiver<(usize, BTreeSet<String>)> {
    let (asked, asks) = watch::channel((0, BTreeSet::new()));
    Mock::given(move |request: &wiremock::Request| {
        let body: serde_json::Value = serde_json::from_slice(&request.body).unwrap_or_default();
        if request.url.path().ends_with("/sync") && body["conn_id"] == "room-list" {
            let rooms = body["room_subscriptions"]
                .as_object()
                .map(|rooms| rooms.keys().cloned().collect())
                .unwrap_or_default();
            asked.send_modify(|(count, last)| {
                *count += 1;
                *last = rooms;
            });
        }
        false
    })
    .respond_with(ResponseTemplate::new(500))
    .with_priority(1)
    .mount(server.server())
    .await;
    asks
}

/// Waits until the room list's syncs subscribe to exactly `rooms`, then checks the next two still
/// do (a change would have shown by then).
async fn subscribed(asks: &mut watch::Receiver<(usize, BTreeSet<String>)>, rooms: &[&str]) {
    let rooms: BTreeSet<String> = rooms.iter().map(ToString::to_string).collect();
    let within = Duration::from_secs(10);
    let count = tokio::time::timeout(within, asks.wait_for(|(_, last)| *last == rooms))
        .await
        .unwrap_or_else(|_| panic!("the sync subscribes to {rooms:?}"))
        .unwrap()
        .0;
    let later = tokio::time::timeout(within, asks.wait_for(|(next, _)| *next >= count + 2))
        .await
        .unwrap()
        .unwrap()
        .1
        .clone();
    assert_eq!(later, rooms, "the sync keeps its rooms while nothing changes");
}

#[tokio::test(flavor = "multi_thread")]
async fn the_rooms_are_subscribed_while_a_chat_or_thread_shows_them() {
    let server = server().await;
    let (account, _folder) = signed_in(&server).await;
    let mut asks = watch_subscriptions(&server).await;
    let timelines = account.timelines();

    // the chat opens in two windows, its thread beside one, and a merged chat shows two rooms.
    let chat = TimelineId::from(&crew());
    let rope = TimelineId::from(&RoomId::from("!rope:matrix.org"));
    let thread = TimelineId::thread(crew(), EventId::from("$root"));
    let (first, second, beside) = (timelines.hold(&chat), timelines.hold(&chat), timelines.hold(&thread));
    let merged = [timelines.hold(&chat), timelines.hold(&rope)];
    subscribed(&mut asks, &["!crew:matrix.org", "!rope:matrix.org"]).await;

    // the merged chat closes, and one window: the other still shows the room.
    drop(merged);
    drop(first);
    subscribed(&mut asks, &["!crew:matrix.org"]).await;

    // the last window closes: its thread still shows the room.
    drop(second);
    subscribed(&mut asks, &["!crew:matrix.org"]).await;

    // the thread closes: the sync lets the room go.
    drop(beside);
    subscribed(&mut asks, &[]).await;
}
