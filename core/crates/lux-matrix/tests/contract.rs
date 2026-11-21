//! The ports' contract (`lux_core::contract`) against the Matrix account, over the SDK's mock
//! server: the same behaviours the demo is held to in `lux-core`.

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

use std::sync::{Arc, Mutex, OnceLock, PoisonError};
use std::time::Duration;

use lux_core::contract::ContractBackend;
use lux_core::ids::RoomId;
use lux_core::ports::ChatAccount;
use lux_matrix::MatrixAccount;
use matrix_sdk::test_utils::mocks::MatrixMockServer;
use serde_json::{Value, json};
use wiremock::matchers::{method, path, path_regex};
use wiremock::{Mock, Request, Respond, ResponseTemplate};

mod support;
use support::{server, signed_in};

const ROOM: &str = "!anna:example.org";

/// The Matrix account, signed in to a mock server whose sync brings one chat with Anna, her
/// message in it; the server takes what the account sends.
struct Matrix {
    account: MatrixAccount,
    _server: MatrixMockServer,
    _folder: tempfile::TempDir,
}

impl ContractBackend for Matrix {
    type Account = MatrixAccount;

    fn account(&self) -> &MatrixAccount {
        &self.account
    }

    fn room(&self) -> RoomId {
        RoomId::from(ROOM)
    }
}

/// What the server took: each event the account sent or redacted, by the id it gave it.
#[derive(Default)]
struct Taken {
    /// Each event's type and content, in the order taken.
    events: Mutex<Vec<(String, Value)>>,
    /// The account, the sender of each: known once it signed in, before it sends.
    sender: OnceLock<String>,
}

impl Taken {
    fn events(&self) -> std::sync::MutexGuard<'_, Vec<(String, Value)>> {
        self.events.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

/// The server's answer to each event sent: a new event id, the event kept under it.
struct NewEvents(Arc<Taken>);

impl Respond for NewEvents {
    fn respond(&self, request: &Request) -> ResponseTemplate {
        // `/rooms/{room}/send/{type}/{txn}` or `/rooms/{room}/redact/{event}/{txn}`.
        let segments: Vec<&str> = request.url.path().split('/').collect();
        let kind = match segments.iter().rev().nth(2) {
            Some(&"redact") => "m.room.redaction".to_owned(),
            _ => segments.iter().rev().nth(1).copied().unwrap_or_default().to_owned(),
        };
        let content = serde_json::from_slice(&request.body).unwrap_or(Value::Null);
        let mut events = self.0.events();
        let event_id = format!("$sent-{}", events.len());
        events.push((kind, content));
        ResponseTemplate::new(200).set_body_json(json!({ "event_id": event_id }))
    }
}

/// The room's `/event/{id}`: an event the server took, as a homeserver serves the events it has
/// (the SDK fetches the one it edits when its cache does not hold it yet).
struct TakenEvents(Arc<Taken>);

impl Respond for TakenEvents {
    fn respond(&self, request: &Request) -> ResponseTemplate {
        let requested = request
            .url
            .path()
            .rsplit('/')
            .next()
            .unwrap_or_default()
            .replace("%24", "$");
        let events = self.0.events();
        let taken = requested
            .strip_prefix("$sent-")
            .and_then(|index| index.parse::<usize>().ok())
            .and_then(|index| Some((index, events.get(index)?)));
        let Some((index, (kind, content))) = taken else {
            return ResponseTemplate::new(404)
                .set_body_json(json!({ "errcode": "M_NOT_FOUND", "error": "Event not found." }));
        };
        ResponseTemplate::new(200).set_body_json(json!({
            "type": kind,
            "event_id": requested,
            "room_id": ROOM,
            "sender": self.0.sender.get(),
            "origin_server_ts": 1_700_000_001_000_u64 + index as u64,
            "content": content,
        }))
    }
}

async fn matrix() -> Matrix {
    let server = server().await;
    Mock::given(method("POST"))
        .and(path("/_matrix/client/unstable/org.matrix.simplified_msc3575/sync"))
        .respond_with(
            ResponseTemplate::new(200)
                .set_body_json(json!({
                    "pos": "1",
                    "lists": { "all_rooms": { "count": 1 } },
                    "rooms": {
                        ROOM: {
                            "name": "Anna",
                            "initial": true,
                            "joined_count": 2,
                            "timeline": [{
                                "type": "m.room.message",
                                "event_id": "$hello",
                                "sender": "@anna:example.org",
                                "origin_server_ts": 1_700_000_000_000_u64,
                                "content": { "msgtype": "m.text", "body": "are you coming?" }
                            }]
                        }
                    }
                }))
                // the sync long-polls: not every few milliseconds.
                .set_delay(Duration::from_millis(200)),
        )
        .mount(server.server())
        .await;
    server.mock_room_state_encryption().plain().mount().await;
    let taken = Arc::new(Taken::default());
    Mock::given(method("PUT"))
        .and(path_regex(r"/rooms/[^/]+/(send|redact)/"))
        .respond_with(NewEvents(Arc::clone(&taken)))
        .mount(server.server())
        .await;
    Mock::given(method("GET"))
        .and(path_regex(r"/rooms/[^/]+/event/"))
        .respond_with(TakenEvents(Arc::clone(&taken)))
        .mount(server.server())
        .await;
    let (account, folder) = signed_in(&server).await;
    taken.sender.set(account.own_user_id().to_string()).unwrap();
    tokio::time::timeout(Duration::from_secs(10), account.wait_for_first_sync())
        .await
        .unwrap();
    Matrix {
        account,
        _server: server,
        _folder: folder,
    }
}

// one thread: the SDK's send queue wakes its sender before it tells the timeline of the local
// echo (`RoomSendQueue::send_serialized`); on several threads the send's answer can come first,
// and the timeline, which drops the answer of an echo it does not hold yet, shows it sending for
// good.
lux_core::contract_tests!(
    #[tokio::test]
    matrix().await
);
