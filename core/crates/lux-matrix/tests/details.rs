//! A chat's details against the SDK's mock server: a group's state and what the account may change
//! of it, renaming it, its members, and what its history shared.

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

use lux_core::ids::RoomId;
use lux_core::ports::{ChatAccount, ChatDetails, NotificationMode, Role, SharedContent};
use lux_matrix::MatrixAccount;
use matrix_sdk::ruma::{event_id, mxc_uri, owned_mxc_uri, room_id, user_id};
use matrix_sdk::test_utils::mocks::MatrixMockServer;
use matrix_sdk_test::event_factory::EventFactory;
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
async fn a_groups_admin_sees_its_state_and_may_rename_it() {
    let server = server().await;
    let (account, _folder) = signed_in(&server).await;

    let details = account.room_details(&crew()).await.unwrap();
    assert_eq!(details.name, "Climbing crew");
    assert_eq!(details.topic.as_deref(), Some("Wednesdays at the wall"));
    assert_eq!(details.address.as_deref(), Some("#crew:matrix.org"));
    assert!(details.is_encrypted);
    assert!(!details.is_direct);
    assert_eq!(details.notifications, NotificationMode::Default);
    assert!(details.may.rename && details.may.change_topic && details.may.change_avatar);

    Mock::given(method("PUT"))
        .and(path_regex(
            r"^/_matrix/client/v3/rooms/!crew:matrix.org/state/m.room.name/?$",
        ))
        .and(body_partial_json(json!({ "name": "Crew" })))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({ "event_id": "$renamed" })))
        .expect(1)
        .mount(server.server())
        .await;
    account.rename_room(&crew(), "  Crew ").await.unwrap();
}

#[tokio::test(flavor = "multi_thread")]
async fn a_groups_members_load_once_with_their_roles() {
    let server = server().await;
    let (account, _folder) = signed_in(&server).await;
    let factory = EventFactory::new().room(room_id!("!crew:matrix.org"));
    server
        .mock_get_members()
        .ok(vec![
            factory
                .member(user_id!("@cheeky_monkey:matrix.org"))
                .display_name("Cheeky")
                .into_raw(),
            factory
                .member(user_id!("@anna:matrix.org"))
                .display_name("Anna")
                .avatar_url(mxc_uri!("mxc://matrix.org/anna"))
                .into_raw(),
            factory.member(user_id!("@petr:matrix.org")).into_raw(),
        ])
        .mock_once()
        .mount()
        .await;

    let members = account.members(&crew()).await.unwrap();
    let anna = members.iter().find(|member| member.name == "Anna").unwrap();
    assert_eq!(anna.role, Role::Moderator);
    assert_eq!(
        anna.avatar.as_ref().map(lux_core::ids::MediaId::as_str),
        Some("mxc://matrix.org/anna")
    );
    let own = members.iter().find(|member| member.is_own).unwrap();
    assert_eq!(own.role, Role::Admin);
    // a member without a display name goes by their id.
    assert!(members.iter().any(|member| member.name == "petr"));
    // loaded once: the mock answers once.
    assert_eq!(account.members(&crew()).await.unwrap().len(), 3);
}

#[tokio::test(flavor = "multi_thread")]
async fn the_history_shares_its_photos_files_and_links_newest_first() {
    let server = server().await;
    let (account, _folder) = signed_in(&server).await;
    let factory = EventFactory::new()
        .room(room_id!("!crew:matrix.org"))
        .sender(user_id!("@anna:matrix.org"));
    let chunk = json!([
        factory
            .text_msg("the route: https://example.org/route")
            .event_id(event_id!("$link"))
            .into_raw_timeline(),
        factory
            .text_msg("see you")
            .event_id(event_id!("$text"))
            .into_raw_timeline(),
        factory
            .image("wall.jpg".to_owned(), owned_mxc_uri!("mxc://matrix.org/wall"))
            .event_id(event_id!("$photo"))
            .into_raw_timeline(),
    ]);
    Mock::given(method("GET"))
        .and(path("/_matrix/client/v3/rooms/!crew:matrix.org/messages"))
        .respond_with(
            ResponseTemplate::new(200).set_body_json(json!({ "chunk": chunk, "start": "now", "end": "older" })),
        )
        .mount(server.server())
        .await;

    let page = account.shared(&crew(), None).await.unwrap();
    assert_eq!(page.next.as_deref(), Some("older"));
    let events: Vec<&str> = page.items.iter().map(|item| item.event.as_str()).collect();
    assert_eq!(events, ["$link", "$photo"]);
    assert!(matches!(&page.items[0].content, SharedContent::Link { url, .. } if url == "https://example.org/route"));
    assert!(matches!(page.items[1].content, SharedContent::Photo { .. }));
    assert_eq!(page.items[0].sender_name, "anna");
}
