//! A room's pinned messages against the SDK's mock server: the pinned event read and named, the
//! right to pin by the power levels, and pinning sending the room's new `m.room.pinned_events`.

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

use std::time::Duration;

use futures_util::StreamExt;
use lux_core::ids::RoomId;
use lux_core::ports::{ChatAccount, ChatTimelines};
use lux_core::preview::PreviewKind;
use lux_matrix::MatrixAccount;
use matrix_sdk::test_utils::mocks::MatrixMockServer;
use serde_json::json;
use wiremock::matchers::{body_partial_json, method, path, path_regex};
use wiremock::{Mock, ResponseTemplate};

mod support;

const OWN: &str = "@cheeky_monkey:matrix.org";

fn crew() -> RoomId {
    RoomId::from("!crew:matrix.org")
}

/// A server whose sync brings one encrypted group, "Climbing crew", which the account administers.
async fn server() -> MatrixMockServer {
    let server = support::server().await;
    let state = |kind: &str, key: &str, content: serde_json::Value| {
        json!({
            "type": kind, "state_key": key, "content": content, "sender": OWN,
            "event_id": format!("${kind}"), "origin_server_ts": 1_700_000_000_000_u64,
        })
    };
    Mock::given(method("POST"))
        .and(path("/_matrix/client/unstable/org.matrix.simplified_msc3575/sync"))
        .respond_with(
            ResponseTemplate::new(200)
                .set_body_json(json!({
                    "pos": "1",
                    "lists": { "all_rooms": { "count": 1 } },
                    "rooms": { "!crew:matrix.org": {
                        "name": "Climbing crew",
                        "initial": true,
                        "joined_count": 3,
                        "required_state": [
                            state("m.room.create", "", json!({ "creator": "@anna:matrix.org", "room_version": "10" })),
                            state("m.room.name", "", json!({ "name": "Climbing crew" })),
                            state("m.room.topic", "", json!({ "topic": "Wednesdays at the wall" })),
                            state("m.room.encryption", "", json!({ "algorithm": "m.megolm.v1.aes-sha2" })),
                            state("m.room.canonical_alias", "", json!({ "alias": "#crew:matrix.org" })),
                            state("m.room.power_levels", "", json!({
                                "users": { OWN: 100, "@anna:matrix.org": 50 },
                                "users_default": 0, "state_default": 50,
                            })),
                            state("m.room.member", OWN, json!({ "membership": "join" })),
                            state("m.room.pinned_events", "", json!({ "pinned": ["$pinned"] })),
                        ],
                    }},
                }))
                .set_delay(Duration::from_millis(200)),
        )
        .mount(server.server())
        .await;
    server
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
async fn a_rooms_pinned_message_is_read_and_another_is_pinned() {
    let server = server().await;
    let (account, _folder) = signed_in(&server).await;
    Mock::given(method("GET"))
        .and(path_regex(
            r"^/_matrix/client/v3/rooms/!crew:matrix.org/event/\$pinned/?$",
        ))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "type": "m.room.message", "event_id": "$pinned", "sender": "@anna:matrix.org",
            "origin_server_ts": 1_700_000_000_000_u64, "room_id": "!crew:matrix.org",
            "content": { "msgtype": "m.text", "body": "Meet at the wall at six" },
        })))
        .mount(server.server())
        .await;

    let mut pins = account.timelines().pins(&crew()).unwrap();
    let first = tokio::time::timeout(Duration::from_secs(10), pins.next())
        .await
        .unwrap()
        .unwrap();
    assert!(first.may_pin, "the account's power level lets it pin");
    let pinned: Vec<&str> = first.messages.iter().map(|pin| pin.event.as_str()).collect();
    assert_eq!(pinned, ["$pinned"]);
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
        .set_pinned(&crew(), &lux_core::ids::EventId::from("$new"), true)
        .await
        .unwrap();
}
