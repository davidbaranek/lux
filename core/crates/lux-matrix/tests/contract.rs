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

use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Duration;

use lux_core::contract::ContractBackend;
use lux_core::ids::RoomId;
use lux_core::ports::ChatAccount;
use lux_matrix::MatrixAccount;
use matrix_sdk::test_utils::mocks::MatrixMockServer;
use serde_json::json;
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

/// The server's answer to each event sent: a new event id.
struct NewEvents(AtomicUsize);

impl Respond for NewEvents {
    fn respond(&self, _: &Request) -> ResponseTemplate {
        let n = self.0.fetch_add(1, Ordering::SeqCst);
        ResponseTemplate::new(200).set_body_json(json!({ "event_id": format!("$sent-{n}") }))
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
    Mock::given(method("PUT"))
        .and(path_regex(r"/rooms/[^/]+/(send|redact)/"))
        .respond_with(NewEvents(AtomicUsize::new(0)))
        .mount(server.server())
        .await;
    let (account, folder) = signed_in(&server).await;
    tokio::time::timeout(Duration::from_secs(10), account.wait_for_first_sync())
        .await
        .unwrap();
    Matrix {
        account,
        _server: server,
        _folder: folder,
    }
}

lux_core::contract_tests!(
    #[tokio::test(flavor = "multi_thread")]
    matrix().await
);
