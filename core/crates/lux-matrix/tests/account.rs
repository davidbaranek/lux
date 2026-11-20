//! The account against the SDK's mock server: signing in, opening the same store again, and the
//! chat list from a sync.

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

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use eyeball_im::VectorDiff;
use futures_util::StreamExt;
use lux_core::chat::Chat;
use lux_core::ids::MediaId;
use lux_core::ids::{ChatId, RoomId, TimelineId};
use lux_core::message::SendState;
use lux_core::ports::{
    BackendError, Bridges, ChatAccount, ChatSending, ChatTimelines, SecretStore, Security, SessionSecrets, SignIn,
};
use lux_core::preview::{Membership, PreviewKind};
use lux_matrix::{KeptList, MatrixSignIn, StoreFolder};
use lux_store::{Key, Store};
use matrix_sdk::ruma::event_id;
use matrix_sdk::test_utils::mocks::MatrixMockServer;
use matrix_sdk_base::crypto::EncryptionSettings as CryptoSettings;
use matrix_sdk_base::crypto::olm::{InboundGroupSession, OutboundGroupSession, SenderData};
use matrix_sdk_base::crypto::store::types::BackupDecryptionKey;
use matrix_sdk_base::crypto::types::EventEncryptionAlgorithm;
use matrix_sdk_base::crypto::vodozemac::olm::IdentityKeys;
use matrix_sdk_base::crypto::vodozemac::{Curve25519PublicKey, Curve25519SecretKey, Ed25519SecretKey};
use serde_json::json;
use wiremock::matchers::{method, path};
use wiremock::{Mock, ResponseTemplate};

mod support;
use support::{Counts, MemorySecrets, Requests, server, signed_in};

/// The chat's preview is the text `text`.
fn says(chat: &Chat, text: &str) -> bool {
    chat.preview
        .as_ref()
        .is_some_and(|preview| preview.kind == PreviewKind::Text(text.to_owned()))
}

/// Waits for the first batch of `stream` whose rows, applied to `rows`, satisfy `done`.
async fn until(
    stream: &mut lux_core::ports::DiffStream<Arc<Chat>>,
    rows: &mut eyeball_im::Vector<Arc<Chat>>,
    done: impl Fn(&eyeball_im::Vector<Arc<Chat>>) -> bool,
) {
    tokio::time::timeout(Duration::from_secs(10), async {
        while let Some(batch) = stream.next().await {
            for diff in batch {
                diff.apply(rows);
            }
            if done(rows) {
                return;
            }
        }
    })
    .await
    .expect("the chat list did not get there in time");
}

/// The sync answers with one bridged chat, "!anna:matrix.org", whose last message says "hello
/// there"; the syncs that reach `server`.
async fn sync_anna(server: &MatrixMockServer) -> Requests {
    sync_anna_with(server, json!({})).await
}

/// [`sync_anna`], its message with `unsigned` (its `age`: since the server took it).
async fn sync_anna_with(server: &MatrixMockServer, unsigned: serde_json::Value) -> Requests {
    let syncs = Requests::default();
    Mock::given(method("POST"))
        .and(path("/_matrix/client/unstable/org.matrix.simplified_msc3575/sync"))
        .respond_with(
            syncs.answering(
                ResponseTemplate::new(200)
                    .set_body_json(json!({
                        "pos": "1",
                        "lists": { "all_rooms": { "count": 1 } },
                        "rooms": {
                            "!anna:matrix.org": {
                                "name": "Anna",
                                "initial": true,
                                "joined_count": 2,
                                "heroes": [{ "user_id": "@whatsapp_4912345:matrix.org", "displayname": "Anna" }],
                                "timeline": [{
                                    "type": "m.room.message",
                                    "event_id": "$hello",
                                    "sender": "@whatsapp_4912345:matrix.org",
                                    "origin_server_ts": 1_700_000_000_000_u64,
                                    "content": { "msgtype": "m.text", "body": "hello\nthere" },
                                    "unsigned": unsigned
                                }]
                            }
                        }
                    }))
                    // the sync long-polls: not every few milliseconds.
                    .set_delay(Duration::from_millis(200)),
            ),
        )
        .mount(server.server())
        .await;
    syncs
}

/// Whether the account's sync stopped: no sliding sync arrives within a second (the mock answers
/// each in 200 ms). That it goes on is awaited instead, with [`Requests::another`].
async fn stopped(syncs: &Requests) -> bool {
    !syncs.more_within(Duration::from_secs(1)).await
}

/// Waits until each of the sync's two loops (the room list's, the encryption's) sent another
/// request since `before`.
async fn both_loops_sent_since(syncs: &Requests, before: &Counts) {
    syncs
        .until(|now| {
            ["room-list", "encryption"]
                .iter()
                .all(|id| now.get(*id).unwrap_or(&0) > before.get(*id).unwrap_or(&0))
        })
        .await;
}

#[tokio::test(flavor = "multi_thread")]
async fn a_password_sign_in_keeps_its_session_and_opens_the_same_store_again() {
    let server = server().await;
    let folder = tempfile::tempdir().unwrap();
    let secrets = Arc::new(MemorySecrets::default());
    let sign_in = MatrixSignIn::new(StoreFolder::new(folder.path()), secrets.clone());

    let account = sign_in
        .sign_in_with_password(&server.uri(), "cheeky_monkey", "secret", "Lux (Test)")
        .await
        .unwrap();
    assert_eq!(account.own_user_id().as_str(), "@cheeky_monkey:matrix.org");
    let device = account.device_id().clone();
    drop(account);

    let kept = secrets.load().unwrap().unwrap();
    assert_eq!(kept.device_id, device);
    assert_eq!(kept.access_token, "abc123");
    assert!(kept.oauth_client_id.is_none());
    assert!(kept.native_sliding_sync);
    assert!(StoreFolder::new(folder.path()).holds_device());

    // the next launch: the same device, from the same store.
    let restored = sign_in.restore().await.unwrap().unwrap();
    assert_eq!(restored.device_id(), &device);
}

#[tokio::test(flavor = "multi_thread")]
async fn a_session_without_its_store_is_never_opened_but_forgotten() {
    let folder = tempfile::tempdir().unwrap();
    let secrets = Arc::new(MemorySecrets::default());
    secrets
        .save(&SessionSecrets {
            user_id: "@anna:example.org".into(),
            device_id: "ABCDEFGHIJ".into(),
            homeserver_url: "https://example.org/".to_owned(),
            access_token: "token".to_owned(),
            refresh_token: None,
            oauth_client_id: None,
            native_sliding_sync: true,
        })
        .unwrap();
    let sign_in = MatrixSignIn::new(StoreFolder::new(folder.path().join("gone")), secrets.clone());
    // the account is forgotten: signed out.
    assert!(matches!(sign_in.restore().await, Ok(None)));
    assert!(secrets.load().unwrap().is_none());
    // nothing was made in its place.
    assert!(!folder.path().join("gone").exists());
}

#[tokio::test(flavor = "multi_thread")]
async fn no_session_restores_nothing() {
    let folder = tempfile::tempdir().unwrap();
    let sign_in = MatrixSignIn::new(StoreFolder::new(folder.path()), Arc::new(MemorySecrets::default()));
    assert!(sign_in.restore().await.unwrap().is_none());
}

#[tokio::test(flavor = "multi_thread")]
async fn a_session_the_server_refuses_ends() {
    let server = server().await;
    Mock::given(method("POST"))
        .and(path("/_matrix/client/unstable/org.matrix.simplified_msc3575/sync"))
        .respond_with(ResponseTemplate::new(401).set_body_json(json!({
            "errcode": "M_UNKNOWN_TOKEN",
            "error": "Invalid access token",
            "soft_logout": false
        })))
        .mount(server.server())
        .await;
    let (account, _folder) = signed_in(&server).await;

    tokio::time::timeout(Duration::from_secs(10), account.session_end())
        .await
        .expect("the session did not end");
}

#[tokio::test(flavor = "multi_thread")]
async fn a_session_the_server_answers_does_not_end() {
    let server = server().await;
    let syncs = sync_anna(&server).await;
    let (account, _folder) = signed_in(&server).await;
    syncs.until(|counts| counts.values().sum::<usize>() >= 3).await;

    assert!(
        tokio::time::timeout(Duration::from_millis(500), account.session_end())
            .await
            .is_err()
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn a_wrong_password_says_so() {
    let server = MatrixMockServer::new().await;
    server.mock_versions().with_simplified_sliding_sync().ok().mount().await;
    Mock::given(method("POST"))
        .and(path("/_matrix/client/v3/login"))
        .respond_with(
            ResponseTemplate::new(403).set_body_json(json!({"errcode": "M_FORBIDDEN", "error": "Invalid password"})),
        )
        .mount(server.server())
        .await;
    let folder = tempfile::tempdir().unwrap();
    let sign_in = MatrixSignIn::new(StoreFolder::new(folder.path()), Arc::new(MemorySecrets::default()));
    let result = sign_in
        .sign_in_with_password(&server.uri(), "anna", "wrong", "Lux (Test)")
        .await;
    assert!(matches!(result, Err(BackendError::WrongCredentials)));
}

#[tokio::test(flavor = "multi_thread")]
async fn the_chat_list_shows_a_synced_bridged_chat() {
    let server = server().await;
    sync_anna(&server).await;
    let folder = tempfile::tempdir().unwrap();
    let key = Key::from_hex(&"0d".repeat(32)).unwrap();
    let store = Arc::new(
        Store::open(folder.path().join("lux-search/index.sqlite"), key)
            .await
            .unwrap(),
    );
    let sign_in = MatrixSignIn::new(StoreFolder::new(folder.path()), Arc::new(MemorySecrets::default()))
        .with_store(Arc::clone(&store));
    let account = sign_in
        .sign_in_with_password(&server.uri(), "cheeky_monkey", "secret", "Lux (Test)")
        .await
        .unwrap();

    let mut chats = account.chats();
    let mut rows = eyeball_im::Vector::new();
    // the first batch is the whole list, as it is.
    let first = chats.next().await.unwrap();
    assert!(matches!(first.first(), Some(VectorDiff::Reset { .. })));
    for diff in first {
        diff.apply(&mut rows);
    }
    until(&mut chats, &mut rows, |rows| {
        rows.iter().any(|chat| says(chat, "hello there"))
    })
    .await;
    let chat = rows
        .iter()
        .find(|chat| chat.id == ChatId::from("!anna:matrix.org"))
        .unwrap();
    assert_eq!(chat.name, "Anna");
    assert_eq!(chat.network.as_str(), "whatsapp");
    assert!(!chat.is_group);
    assert!(chat.date.is_some());

    tokio::time::timeout(Duration::from_secs(10), account.wait_for_first_sync())
        .await
        .unwrap();

    // going to the background keeps the list for the next launch, and pauses the store: a call
    // meanwhile does not open its file again, which iOS would find held as it suspends the app.
    account.pause_sync().await;
    assert!(matches!(
        store.kept("core-chat-list".into()).await,
        Err(lux_store::Error::Paused)
    ));
    // the share extension reads it on a connection of its own.
    let extension = Store::open(
        folder.path().join("lux-search/index.sqlite"),
        Key::from_hex(&"0d".repeat(32)).unwrap(),
    )
    .await
    .unwrap();
    let kept = KeptList::new(Arc::new(extension)).read().await;
    assert!(kept.iter().any(|chat| says(chat, "hello there")));
    // back in front, the app's store opens again.
    account.resume_sync().await;
    assert!(!KeptList::new(store).read().await.is_empty());
}

#[tokio::test(flavor = "multi_thread")]
async fn an_old_message_from_a_bridges_user_in_a_room_without_its_bridge_state_is_that_networks_history() {
    let server = server().await;
    // a new room a bridge made: its first sync brings no `m.bridge` (the room list asks for no
    // such state), only the bridge's user and a message sent long ago.
    sync_anna(&server).await;
    let (account, _folder) = signed_in(&server).await;

    let mut catching_up = account.catching_up();
    let networks = tokio::time::timeout(Duration::from_secs(10), async {
        while let Some(networks) = catching_up.next().await {
            if !networks.is_empty() {
                return networks;
            }
        }
        Vec::new()
    })
    .await
    .expect("no network caught up in time");
    assert_eq!(networks.len(), 1);
    assert_eq!(networks[0].network.as_str(), "whatsapp");
    assert_eq!(networks[0].messages, 1);
}

#[tokio::test(flavor = "multi_thread")]
async fn an_old_message_the_server_took_long_ago_is_no_history_however_often_the_sync_brings_it() {
    let server = server().await;
    // an opened chat's latest messages, a sync that starts over: the server took them when they
    // were sent (their age as long as they are old), and each sync brings them again.
    let age = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH + Duration::from_secs(1_700_000_000))
        .unwrap();
    let syncs = sync_anna_with(&server, json!({ "age": u64::try_from(age.as_millis()).unwrap() })).await;
    let (account, _folder) = signed_in(&server).await;

    let mut catching_up = account.catching_up();
    let caught_up = tokio::time::timeout(Duration::from_secs(2), async {
        while let Some(networks) = catching_up.next().await {
            if !networks.is_empty() {
                return networks;
            }
        }
        Vec::new()
    })
    .await;
    assert!(syncs.more_within(Duration::from_secs(1)).await, "the sync stopped");
    assert!(caught_up.is_err(), "a network caught up: {caught_up:?}");
}

#[tokio::test(flavor = "multi_thread")]
async fn an_old_message_the_server_just_took_is_its_bridges_history() {
    let server = server().await;
    // a bridge's backfill: the message keeps its time on the network, the server took it now.
    sync_anna_with(&server, json!({ "age": 1_000 })).await;
    let (account, _folder) = signed_in(&server).await;

    let mut catching_up = account.catching_up();
    let networks = tokio::time::timeout(Duration::from_secs(10), async {
        while let Some(networks) = catching_up.next().await {
            if !networks.is_empty() {
                return networks;
            }
        }
        Vec::new()
    })
    .await
    .expect("no network caught up in time");
    assert_eq!(networks[0].network.as_str(), "whatsapp");
}

#[tokio::test(flavor = "multi_thread")]
async fn a_rooms_unread_count_is_the_servers_when_the_device_holds_too_few_of_its_messages() {
    let server = server().await;
    let own = "@cheeky_monkey:matrix.org";
    let message = |id: &str| {
        json!({
            "type": "m.room.message",
            "event_id": id,
            "sender": "@discord_1:matrix.org",
            "origin_server_ts": 1_700_000_000_000_u64,
            "content": { "msgtype": "m.text", "body": "hi" }
        })
    };
    // the room list brings each room's latest event only: seven unread, one of them here.
    Mock::given(method("POST"))
        .and(path("/_matrix/client/unstable/org.matrix.simplified_msc3575/sync"))
        .respond_with(
            ResponseTemplate::new(200)
                .set_body_json(json!({
                    "pos": "1",
                    "lists": { "all_rooms": { "count": 2 } },
                    "rooms": {
                        "!general:matrix.org": {
                            "name": "general",
                            "initial": true,
                            "joined_count": 3,
                            "notification_count": 7,
                            "highlight_count": 2,
                            "required_state": [joined(own, None)],
                            "timeline": [message("$general")]
                        },
                        "!secret:matrix.org": {
                            "name": "secret",
                            "initial": true,
                            "joined_count": 3,
                            "notification_count": 7,
                            "highlight_count": 2,
                            "required_state": [
                                joined(own, None),
                                state("m.room.encryption", "", own, json!({ "algorithm": "m.megolm.v1.aes-sha2" })),
                            ],
                            "timeline": [message("$secret")]
                        }
                    }
                }))
                .set_delay(Duration::from_millis(200)),
        )
        .mount(server.server())
        .await;
    let (account, _folder) = signed_in(&server).await;

    let mut chats = account.chats();
    let mut rows = eyeball_im::Vector::new();
    let row =
        |rows: &eyeball_im::Vector<Arc<Chat>>, id: &str| rows.iter().find(|chat| chat.id == ChatId::from(id)).cloned();
    until(&mut chats, &mut rows, |rows| {
        row(rows, "!general:matrix.org").is_some_and(|chat| chat.unread_count == 7)
            && row(rows, "!secret:matrix.org").is_some()
    })
    .await;
    assert_eq!(row(&rows, "!general:matrix.org").unwrap().unread_mentions, 2);
    // an encrypted room's server count counts what it cannot read: the device's only.
    let secret = row(&rows, "!secret:matrix.org").unwrap();
    assert!(secret.unread_count < 7 && secret.unread_mentions < 2, "{secret:?}");
}

#[tokio::test(flavor = "multi_thread")]
async fn every_latest_event_reads_as_what_happened_and_a_direct_chat_shows_its_person() {
    let server = server().await;
    let own = "@cheeky_monkey:matrix.org";
    let bob = "@whatsapp_1:matrix.org";
    Mock::given(method("POST"))
        .and(path("/_matrix/client/unstable/org.matrix.simplified_msc3575/sync"))
        .respond_with(
            ResponseTemplate::new(200)
                .set_body_json(json!({
                    "pos": "1",
                    "lists": { "all_rooms": { "count": 3 } },
                    "rooms": {
                        "!dm:matrix.org": {
                            "name": "Bob",
                            "initial": true,
                            "joined_count": 2,
                            "heroes": [{ "user_id": bob, "displayname": "Bob", "avatar_url": "mxc://matrix.org/bob" }],
                            "timeline": [{
                                "type": "m.room.message",
                                "event_id": "$hi",
                                "sender": bob,
                                "origin_server_ts": 1_700_000_000_000_u64,
                                "content": { "msgtype": "m.text", "body": "hi" }
                            }, {
                                "type": "m.room.message",
                                "event_id": "$edit",
                                "sender": bob,
                                "origin_server_ts": 1_700_000_001_000_u64,
                                "content": {
                                    "msgtype": "m.text",
                                    "body": "* hi there",
                                    "m.new_content": { "msgtype": "m.text", "body": "hi there" },
                                    "m.relates_to": { "rel_type": "m.replace", "event_id": "$hi" }
                                }
                            }]
                        },
                        "!call:matrix.org": {
                            "name": "Call",
                            "initial": true,
                            "joined_count": 2,
                            "timeline": [{
                                "type": "m.call.invite",
                                "event_id": "$ring",
                                "sender": bob,
                                "origin_server_ts": 1_700_000_002_000_u64,
                                "content": {
                                    "call_id": "1",
                                    "lifetime": 60_000,
                                    "offer": { "type": "offer", "sdp": "v=0" },
                                    "version": 0
                                }
                            }]
                        },
                        "!joined:matrix.org": {
                            "name": "Joined",
                            "initial": true,
                            "joined_count": 5,
                            "timeline": [{
                                "type": "m.room.member",
                                "event_id": "$join",
                                "sender": own,
                                "state_key": own,
                                "origin_server_ts": 1_700_000_003_000_u64,
                                "content": { "membership": "join" }
                            }]
                        }
                    }
                }))
                .set_delay(Duration::from_millis(200)),
        )
        .mount(server.server())
        .await;
    let (account, _folder) = signed_in(&server).await;
    let mut chats = account.chats();
    let mut rows = eyeball_im::Vector::new();
    let kind_of = |rows: &eyeball_im::Vector<Arc<Chat>>, id: &str| {
        rows.iter()
            .find(|chat| chat.id == ChatId::from(id))
            .and_then(|chat| chat.preview.clone())
    };
    until(&mut chats, &mut rows, |rows| {
        kind_of(rows, "!dm:matrix.org").is_some_and(|preview| preview.kind == PreviewKind::Text("hi there".to_owned()))
            && kind_of(rows, "!call:matrix.org").is_some_and(|preview| preview.kind == PreviewKind::Call)
            && kind_of(rows, "!joined:matrix.org").is_some()
    })
    .await;
    let joined = kind_of(&rows, "!joined:matrix.org").unwrap();
    assert_eq!(joined.kind, PreviewKind::Membership(Membership::Joined));
    assert!(joined.is_own());
    // a conversation of two with no picture of its own shows the other person's.
    let dm = rows
        .iter()
        .find(|chat| chat.id == ChatId::from("!dm:matrix.org"))
        .unwrap();
    assert_eq!(dm.avatar.as_ref().map(MediaId::as_str), Some("mxc://matrix.org/bob"));
}

#[tokio::test(flavor = "multi_thread")]
async fn a_room_with_messages_from_before_the_account_arrived_tells_of_the_newest() {
    let server = server().await;
    let own = "@cheeky_monkey:matrix.org";
    let bob = "@whatsapp_1:matrix.org";
    // a bridge filled the room with its history before the account was let in.
    Mock::given(method("POST"))
        .and(path("/_matrix/client/unstable/org.matrix.simplified_msc3575/sync"))
        .respond_with(
            ResponseTemplate::new(200)
                .set_body_json(json!({
                    "pos": "1",
                    "lists": { "all_rooms": { "count": 1 } },
                    "rooms": {
                        "!history:matrix.org": {
                            "name": "History",
                            "initial": true,
                            "joined_count": 5,
                            "timeline": [{
                                "type": "m.room.message",
                                "event_id": "$before",
                                "sender": bob,
                                "origin_server_ts": 1_600_000_000_000_u64,
                                "content": { "msgtype": "m.text", "body": "from before" }
                            }, {
                                "type": "m.room.member",
                                "event_id": "$arrived",
                                "sender": own,
                                "state_key": own,
                                "origin_server_ts": 1_700_000_000_000_u64,
                                "content": { "membership": "join" }
                            }]
                        }
                    }
                }))
                .set_delay(Duration::from_millis(200)),
        )
        .mount(server.server())
        .await;
    let (account, _folder) = signed_in(&server).await;
    let mut chats = account.chats();
    let mut rows = eyeball_im::Vector::new();
    until(&mut chats, &mut rows, |rows| {
        rows.iter().any(|chat| chat.preview.is_some())
    })
    .await;
    let history = rows
        .iter()
        .find(|chat| chat.id == ChatId::from("!history:matrix.org"))
        .unwrap();
    let preview = history.preview.as_ref().unwrap();
    assert_eq!(preview.kind, PreviewKind::Text("from before".to_owned()));
    assert!(!preview.is_own());
    // dated by that message, not by the arrival.
    assert_eq!(
        history.date,
        Some(std::time::UNIX_EPOCH + Duration::from_secs(1_600_000_000))
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn an_edit_of_an_old_message_keeps_the_date_of_the_message() {
    let server = server().await;
    let bob = "@whatsapp_1:matrix.org";
    // a bridge filled in an old photo later (an edit), after another chat's newer message.
    Mock::given(method("POST"))
        .and(path("/_matrix/client/unstable/org.matrix.simplified_msc3575/sync"))
        .respond_with(
            ResponseTemplate::new(200)
                .set_body_json(json!({
                    "pos": "1",
                    "lists": { "all_rooms": { "count": 2 } },
                    "rooms": {
                        "!photo:matrix.org": {
                            "name": "Photo",
                            "initial": true,
                            "joined_count": 2,
                            "timeline": [{
                                "type": "m.room.message",
                                "event_id": "$album",
                                "sender": bob,
                                "origin_server_ts": 1_600_000_000_000_u64,
                                "content": { "msgtype": "m.text", "body": "Sent an album" }
                            }, {
                                "type": "m.room.message",
                                "event_id": "$filled",
                                "sender": bob,
                                "origin_server_ts": 1_700_000_200_000_u64,
                                "content": {
                                    "msgtype": "m.image",
                                    "body": "* photo.jpg",
                                    "url": "mxc://matrix.org/photo",
                                    "m.new_content": { "msgtype": "m.image", "body": "photo.jpg", "url": "mxc://matrix.org/photo" },
                                    "m.relates_to": { "rel_type": "m.replace", "event_id": "$album" }
                                }
                            }]
                        },
                        "!text:matrix.org": {
                            "name": "Text",
                            "initial": true,
                            "joined_count": 2,
                            "timeline": [{
                                "type": "m.room.message",
                                "event_id": "$text",
                                "sender": bob,
                                "origin_server_ts": 1_650_000_000_000_u64,
                                "content": { "msgtype": "m.text", "body": "newer" }
                            }]
                        }
                    }
                }))
                .set_delay(Duration::from_millis(200)),
        )
        .mount(server.server())
        .await;
    let (account, _folder) = signed_in(&server).await;
    let mut chats = account.chats();
    let mut rows = eyeball_im::Vector::new();
    until(&mut chats, &mut rows, |rows| {
        rows.len() == 2 && rows.iter().all(|chat| chat.preview.is_some())
    })
    .await;
    // dated by the photo's message, not by the edit: the newest message order puts it after the
    // other chat (the order is the list's, `lux_core::places`).
    let photo = rows
        .iter()
        .find(|chat| chat.id == ChatId::from("!photo:matrix.org"))
        .unwrap();
    assert_eq!(
        photo.date,
        Some(std::time::UNIX_EPOCH + Duration::from_secs(1_600_000_000))
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn a_sign_in_on_the_server_page_keeps_its_oauth_session() {
    let server = MatrixMockServer::new().await;
    server.mock_versions().with_simplified_sliding_sync().ok().mount().await;
    let oauth = server.oauth();
    oauth.mock_server_metadata().ok().mount().await;
    oauth.mock_registration().ok().mount().await;
    oauth.mock_token().ok().mount().await;
    server.mock_who_am_i().ok().mount().await;

    let folder = tempfile::tempdir().unwrap();
    let secrets = Arc::new(MemorySecrets::default());
    let sign_in = MatrixSignIn::new(StoreFolder::new(folder.path()), secrets.clone());
    let client = lux_core::ports::OAuthClient {
        name: "Lux".to_owned(),
        redirect_uri: "com.example.app:/callback".to_owned(),
        client_uri: "https://app.example.com".to_owned(),
    };
    let pending = sign_in.begin_oauth(&server.uri(), &client).await.unwrap();
    let page = url::Url::parse(lux_core::ports::OAuthSignIn::url(&pending)).unwrap();
    let state = page
        .query_pairs()
        .find(|(key, _)| key == "state")
        .map(|(_, value)| value.into_owned())
        .unwrap();

    let account =
        lux_core::ports::OAuthSignIn::finish(&pending, &format!("com.example.app:/callback?code=42&state={state}"))
            .await
            .unwrap();
    let kept = secrets.load().unwrap().unwrap();
    assert_eq!(kept.oauth_client_id.as_deref(), Some("test_client_id"));
    assert_eq!(&kept.device_id, account.device_id());
    assert!(StoreFolder::new(folder.path()).holds_device());
    drop(account);

    // the next launch opens it as an oauth session, on the same device.
    let restored = sign_in.restore().await.unwrap().unwrap();
    assert_eq!(restored.device_id(), &kept.device_id);
}

#[tokio::test(flavor = "multi_thread")]
async fn a_callback_for_another_sign_in_is_refused() {
    let server = MatrixMockServer::new().await;
    server.mock_versions().with_simplified_sliding_sync().ok().mount().await;
    let oauth = server.oauth();
    oauth.mock_server_metadata().ok().mount().await;
    oauth.mock_registration().ok().mount().await;

    let folder = tempfile::tempdir().unwrap();
    let sign_in = MatrixSignIn::new(StoreFolder::new(folder.path()), Arc::new(MemorySecrets::default()));
    let client = lux_core::ports::OAuthClient {
        name: "Lux".to_owned(),
        redirect_uri: "com.example.app:/callback".to_owned(),
        client_uri: "https://app.example.com".to_owned(),
    };
    let pending = sign_in.begin_oauth(&server.uri(), &client).await.unwrap();
    let finished =
        lux_core::ports::OAuthSignIn::finish(&pending, "com.example.app:/callback?code=42&state=other").await;
    assert!(finished.is_err());
    lux_core::ports::OAuthSignIn::cancel(&pending).await;
}

#[tokio::test(flavor = "multi_thread")]
async fn a_send_that_failed_for_a_moment_goes_out_by_itself_while_the_sync_runs() {
    let server = server().await;
    sync_anna(&server).await;
    server.mock_room_state_encryption().plain().mount().await;
    // the server fails for a moment (the queue's own three tries), then takes everything.
    server.mock_room_send().error500().up_to_n_times(3).mount().await;
    server.mock_room_send().ok(event_id!("$sent")).mount().await;
    let (account, _folder) = signed_in(&server).await;
    tokio::time::timeout(Duration::from_secs(10), account.wait_for_first_sync())
        .await
        .unwrap();
    let room = RoomId::from("!anna:matrix.org");
    let timelines = account.timelines();
    let mut messages = timelines.messages(&room.clone().into()).await.unwrap();

    timelines
        .send_text(&room.clone().into(), &"are you there?".into(), None)
        .await
        .unwrap();
    let mut rows = eyeball_im::Vector::new();
    let mut failed = false;
    // no retry: the queue sends again once the failure has passed.
    tokio::time::timeout(Duration::from_secs(20), async {
        while let Some(batch) = messages.next().await {
            for diff in batch {
                diff.apply(&mut rows);
            }
            let Some(sent) = rows.iter().find(|message| message.message.body == "are you there?") else {
                continue;
            };
            match sent.message.state {
                SendState::Failed => failed = true,
                SendState::Sent if failed => return,
                _ => {}
            }
        }
    })
    .await
    .expect("the message did not go out");
}

/// Whether the server is out of reach: a test switches it.
#[derive(Clone, Default)]
struct Unreachable(Arc<AtomicBool>);

impl wiremock::Match for Unreachable {
    fn matches(&self, _: &wiremock::Request) -> bool {
        self.0.load(Ordering::SeqCst)
    }
}

/// While `unreachable`, `endpoint` of `server` fails as a server out of reach does; the
/// requests it fails.
async fn fails_while(server: &MatrixMockServer, unreachable: &Unreachable, endpoint: impl Into<String>) -> Requests {
    let failed = Requests::default();
    Mock::given(wiremock::matchers::path_regex(endpoint))
        .and(unreachable.clone())
        .respond_with(failed.answering(ResponseTemplate::new(503)))
        .with_priority(1)
        .mount(server.server())
        .await;
    failed
}

/// Waits until the message `body` of `messages`, applied to `rows`, is in `state`.
async fn until_state(
    messages: &mut lux_core::ports::DiffStream<Arc<lux_core::timeline::TimelineMessage>>,
    rows: &mut eyeball_im::Vector<Arc<lux_core::timeline::TimelineMessage>>,
    body: &str,
    state: SendState,
) {
    tokio::time::timeout(Duration::from_secs(20), async {
        while let Some(batch) = messages.next().await {
            for diff in batch {
                diff.apply(rows);
            }
            if rows
                .iter()
                .any(|message| message.message.body == body && message.message.state == state)
            {
                return;
            }
        }
    })
    .await
    .unwrap_or_else(|_| panic!("{body:?} is not {state:?}"));
}

#[tokio::test(flavor = "multi_thread")]
async fn a_send_that_failed_offline_waits_for_the_server_and_goes_out_once_it_is_back() {
    let server = server().await;
    sync_anna(&server).await;
    server.mock_room_state_encryption().plain().mount().await;
    server.mock_room_send().ok(event_id!("$sent")).mount().await;
    let unreachable = Unreachable::default();
    fails_while(&server, &unreachable, "/sync$").await;
    let checks = fails_while(&server, &unreachable, "^/_matrix/client/versions$").await;
    let sends = fails_while(&server, &unreachable, "/send/m.room.message/").await;
    let (account, _folder) = signed_in(&server).await;
    tokio::time::timeout(Duration::from_secs(10), account.wait_for_first_sync())
        .await
        .unwrap();
    let room = RoomId::from("!anna:matrix.org");
    let timelines = account.timelines();
    let mut messages = timelines.messages(&room.clone().into()).await.unwrap();
    let mut rows = eyeball_im::Vector::new();

    // the server goes out of reach: the sync stops and checks for it to come back.
    unreachable.0.store(true, Ordering::SeqCst);
    checks.another().await;
    timelines
        .send_text(&room.clone().into(), &"are you there?".into(), None)
        .await
        .unwrap();
    until_state(&mut messages, &mut rows, "are you there?", SendState::Failed).await;

    // longer than a send that failed waits while the sync runs: offline, it is not tried again.
    assert!(
        !sends.more_within(Duration::from_secs(7)).await,
        "sent again while offline"
    );

    unreachable.0.store(false, Ordering::SeqCst);
    until_state(&mut messages, &mut rows, "are you there?", SendState::Sent).await;
}

#[tokio::test(flavor = "multi_thread")]
async fn a_refresh_stops_the_sync_only_in_the_background() {
    let server = server().await;
    let syncs = sync_anna(&server).await;
    let (account, _folder) = signed_in(&server).await;
    let mut chats = account.chats();
    let mut rows = eyeball_im::Vector::new();
    // the sync's first answer settles before the app goes away (closing the stores under the
    // SDK's work drops what it has not kept yet).
    until(&mut chats, &mut rows, |rows| {
        rows.iter().any(|chat| says(chat, "hello there"))
    })
    .await;

    // the app came to the front during a refresh: the sync goes on.
    assert!(account.refresh_within(Duration::from_secs(10)).await);
    syncs.another().await;

    // in the background, a refresh syncs until the server answers, then stops again, and so
    // does one out of time.
    account.pause_sync().await;
    assert!(stopped(&syncs).await);
    let before = syncs.counts();
    assert!(account.refresh_within(Duration::from_secs(10)).await);
    assert!(
        syncs.counts().get("room-list") > before.get("room-list"),
        "the refresh's sync reached the server"
    );
    assert!(stopped(&syncs).await);
    assert!(!account.refresh_within(Duration::ZERO).await);
    assert!(stopped(&syncs).await);

    // back in front, the stores open again and the chats are still there.
    account.resume_sync().await;
    syncs.another().await;
    let mut chats = account.chats();
    let first = chats.next().await.unwrap();
    let mut rows = eyeball_im::Vector::new();
    for diff in first {
        diff.apply(&mut rows);
    }
    assert!(rows.iter().any(|chat| says(chat, "hello there")));
}

#[tokio::test(flavor = "multi_thread")]
async fn a_pause_during_a_refresh_leaves_the_sync_stopped() {
    let server = server().await;
    let syncs = sync_anna(&server).await;
    let (account, _folder) = signed_in(&server).await;
    let mut chats = account.chats();
    let mut rows = eyeball_im::Vector::new();
    until(&mut chats, &mut rows, |rows| {
        rows.iter().any(|chat| says(chat, "hello there"))
    })
    .await;
    account.pause_sync().await;
    let refresh = || async {
        tokio::time::timeout(Duration::from_secs(5), account.refresh_within(Duration::from_secs(10)))
            .await
            .expect("the refresh ends")
    };

    // the app goes to the background again as a refresh begins: the refresh syncs, then stops.
    let ((), answered) = tokio::join!(account.pause_sync(), refresh());
    assert!(answered);
    assert!(stopped(&syncs).await);

    // and while the server holds the room list's request (the encryption's loop goes on, so a
    // sync that missed the stop shows): the refresh ends at once, unanswered, and the sync stays
    // stopped.
    syncs.hold("room-list");
    let before = syncs.counts();
    let pause = async {
        // the sync's loops run (the sdk misses a stop sent before they listen).
        both_loops_sent_since(&syncs, &before).await;
        account.pause_sync().await;
    };
    let (answered, ()) = tokio::join!(refresh(), pause);
    assert!(!answered, "answered with a pause while the room list's request is held");
    assert!(
        stopped(&syncs).await,
        "syncing after a pause while the room list's request is held"
    );

    // and as the server answers: whether the answer or the pause comes first, the refresh ends
    // and the sync stays stopped.
    syncs.release();
    let before = syncs.counts();
    let pause = async {
        both_loops_sent_since(&syncs, &before).await;
        account.pause_sync().await;
    };
    let (_, ()) = tokio::join!(refresh(), pause);
    assert!(stopped(&syncs).await, "syncing after a pause as the server answers");

    // the stores open again in front, and the chats are still there.
    account.resume_sync().await;
    syncs.another().await;
    let mut chats = account.chats();
    let first = chats.next().await.unwrap();
    let mut rows = eyeball_im::Vector::new();
    for diff in first {
        diff.apply(&mut rows);
    }
    assert!(rows.iter().any(|chat| says(chat, "hello there")));
}

#[tokio::test(flavor = "multi_thread")]
async fn an_account_opened_in_the_background_syncs_only_once_the_app_is_in_front() {
    let server = server().await;
    let syncs = sync_anna(&server).await;
    let folder = tempfile::tempdir().unwrap();
    let secrets = Arc::new(MemorySecrets::default());
    let sign_in = MatrixSignIn::new(StoreFolder::new(folder.path()), secrets.clone());
    let account = sign_in
        .sign_in_with_password(&server.uri(), "cheeky_monkey", "secret", "Lux (Test)")
        .await
        .unwrap();
    let mut chats = account.chats();
    let mut rows = eyeball_im::Vector::new();
    until(&mut chats, &mut rows, |rows| {
        rows.iter().any(|chat| says(chat, "hello there"))
    })
    .await;
    drop(chats);
    account.pause_sync().await;
    drop(account);

    // the system launched the app for a background task: the account opens, its sync waits.
    let account = sign_in.in_background().restore().await.unwrap().unwrap();
    account.begin_background_work().await;
    assert!(stopped(&syncs).await, "syncing while opened in the background");
    // the work ends in the background: the sync stays stopped, the stores close.
    account.end_background_work().await;
    assert!(stopped(&syncs).await);

    // the app comes to the front: the sync runs, and a later end of work leaves it running.
    account.resume_sync().await;
    syncs.another().await;
    account.end_background_work().await;
    syncs.another().await;
    account.pause_sync().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn a_refresh_dropped_while_it_waits_leaves_the_sync_stopped() {
    let server = server().await;
    let syncs = sync_anna(&server).await;
    let (account, _folder) = signed_in(&server).await;
    let mut chats = account.chats();
    let mut rows = eyeball_im::Vector::new();
    until(&mut chats, &mut rows, |rows| {
        rows.iter().any(|chat| says(chat, "hello there"))
    })
    .await;
    account.pause_sync().await;

    // the system takes the time back: the refresh's future goes while the server holds the room
    // list's request (its answer).
    syncs.hold("room-list");
    let before = syncs.counts();
    let started = both_loops_sent_since(&syncs, &before);
    tokio::select! {
        _ = account.refresh_within(Duration::from_secs(10)) => panic!("answered before it was dropped"),
        () = started => {}
    }

    assert!(stopped(&syncs).await);
    syncs.release();
    account.resume_sync().await;
    syncs.another().await;
}

/// A member's join, as a room's state carries it.
fn joined(user: &str, avatar: Option<&str>) -> serde_json::Value {
    json!({
        "type": "m.room.member",
        "event_id": format!("$join-{user}"),
        "sender": user,
        "state_key": user,
        "origin_server_ts": 1_699_000_000_000_u64,
        "content": { "membership": "join", "avatar_url": avatar }
    })
}

/// A message from `sender`, the room's latest.
fn message(sender: &str, id: &str) -> serde_json::Value {
    json!({
        "type": "m.room.message",
        "event_id": id,
        "sender": sender,
        "origin_server_ts": 1_700_000_000_000_u64,
        "content": { "msgtype": "m.text", "body": "hi" }
    })
}

#[tokio::test(flavor = "multi_thread")]
async fn rows_take_their_pictures_from_the_heroes_or_else_the_members_the_store_holds() {
    let server = server().await;
    let own = "@cheeky_monkey:matrix.org";
    Mock::given(method("POST"))
        .and(path("/_matrix/client/unstable/org.matrix.simplified_msc3575/sync"))
        .respond_with(
            ResponseTemplate::new(200)
                .set_body_json(json!({
                    "pos": "1",
                    "lists": { "all_rooms": { "count": 4 } },
                    "rooms": {
                        // a named group (a sliding sync names no heroes): its stored members.
                        "!family:matrix.org": {
                            "name": "Family",
                            "initial": true,
                            "joined_count": 5,
                            "required_state": [
                                joined(own, None),
                                joined("@whatsapp_1:matrix.org", Some("mxc://matrix.org/alice")),
                                joined("@whatsappbot:matrix.org", Some("mxc://matrix.org/bot")),
                                joined("@whatsapp_2:matrix.org", None),
                                joined("@whatsapp_3:matrix.org", Some("mxc://matrix.org/bob")),
                            ],
                            "timeline": [message("@whatsapp_1:matrix.org", "$family")]
                        },
                        // a group without a name: its heroes.
                        "!friends:matrix.org": {
                            "initial": true,
                            "joined_count": 3,
                            "heroes": [
                                { "user_id": "@carol:matrix.org", "displayname": "Carol", "avatar_url": "mxc://matrix.org/carol" },
                                { "user_id": "@dave:matrix.org", "displayname": "Dave", "avatar_url": "mxc://matrix.org/dave" }
                            ],
                            "timeline": [message("@carol:matrix.org", "$friends")]
                        },
                        // a bridged conversation of two, named, not marked direct: the other
                        // person's picture, past the bridge's bot.
                        "!erin:matrix.org": {
                            "name": "Erin",
                            "initial": true,
                            "joined_count": 3,
                            "required_state": [
                                joined(own, None),
                                joined("@metabot:matrix.org", Some("mxc://matrix.org/bot")),
                                joined("@meta_100:matrix.org", Some("mxc://matrix.org/erin")),
                            ],
                            "timeline": [message("@meta_100:matrix.org", "$erin")]
                        },
                        // two people besides the account, in a room of two: whose picture is
                        // not sure, so none (rather than someone else's).
                        "!unsure:matrix.org": {
                            "initial": true,
                            "joined_count": 2,
                            "heroes": [
                                { "user_id": "@frank:matrix.org", "avatar_url": "mxc://matrix.org/frank" },
                                { "user_id": "@grace:matrix.org", "avatar_url": "mxc://matrix.org/grace" }
                            ],
                            "timeline": [message("@grace:matrix.org", "$unsure")]
                        }
                    }
                }))
                .set_delay(Duration::from_millis(200)),
        )
        .mount(server.server())
        .await;
    let (account, _folder) = signed_in(&server).await;
    let mut chats = account.chats();
    let mut rows = eyeball_im::Vector::new();
    let ids = [
        "!family:matrix.org",
        "!friends:matrix.org",
        "!erin:matrix.org",
        "!unsure:matrix.org",
    ];
    until(&mut chats, &mut rows, |rows| {
        ids.iter().all(|id| {
            rows.iter()
                .any(|chat| chat.id == ChatId::from(*id) && chat.date.is_some())
        })
    })
    .await;
    let row = |id: &str| rows.iter().find(|chat| chat.id == ChatId::from(id)).unwrap().clone();
    let urls = |chat: &Chat| -> Vec<String> { chat.member_avatars.iter().map(ToString::to_string).collect() };

    let family = row("!family:matrix.org");
    assert!(family.is_group && family.avatar.is_none());
    assert_eq!(family.network.as_str(), "whatsapp");
    assert_eq!(urls(&family), ["mxc://matrix.org/alice", "mxc://matrix.org/bob"]);

    let friends = row("!friends:matrix.org");
    assert!(friends.is_group && friends.avatar.is_none());
    assert_eq!(urls(&friends), ["mxc://matrix.org/carol", "mxc://matrix.org/dave"]);

    let erin = row("!erin:matrix.org");
    assert!(!erin.is_group);
    // no bridge event in the room list's state: its members tell the bridge.
    assert_eq!(erin.network.as_str(), "messenger");
    assert_eq!(erin.avatar.as_ref().map(MediaId::as_str), Some("mxc://matrix.org/erin"));
    assert!(erin.member_avatars.is_empty());

    let unsure = row("!unsure:matrix.org");
    assert!(!unsure.is_group);
    assert!(unsure.avatar.is_none() && unsure.member_avatars.is_empty());
}

#[tokio::test(flavor = "multi_thread")]
async fn a_group_whose_people_a_sync_did_not_name_shows_their_pictures_without_being_opened() {
    let server = server().await;
    let own = "@cheeky_monkey:matrix.org";
    Mock::given(method("POST"))
        .and(path("/_matrix/client/unstable/org.matrix.simplified_msc3575/sync"))
        .respond_with(
            ResponseTemplate::new(200)
                .set_body_json(json!({
                    "pos": "1",
                    "lists": { "all_rooms": { "count": 1 } },
                    "rooms": {
                        // a named group, as a new device first sees it: only the account and the
                        // latest message's sender.
                        "!climbing:matrix.org": {
                            "name": "Climbing",
                            "initial": true,
                            "joined_count": 4,
                            "required_state": [
                                joined(own, None),
                                joined("@meta_1:matrix.org", None),
                            ],
                            "timeline": [message("@meta_1:matrix.org", "$climbing")]
                        }
                    }
                }))
                .set_delay(Duration::from_millis(200)),
        )
        .mount(server.server())
        .await;
    // the room's members, as the server lists them.
    let member = |user: &str, avatar: Option<&str>| {
        let mut event = joined(user, avatar);
        event["room_id"] = json!("!climbing:matrix.org");
        event
    };
    Mock::given(method("GET"))
        .and(path("/_matrix/client/v3/rooms/!climbing:matrix.org/members"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "chunk": [
                member(own, None),
                member("@meta_1:matrix.org", None),
                member("@meta_2:matrix.org", Some("mxc://matrix.org/ivan")),
                member("@meta_3:matrix.org", Some("mxc://matrix.org/judy")),
            ]
        })))
        .mount(server.server())
        .await;
    let (account, _folder) = signed_in(&server).await;
    let mut chats = account.chats();
    let mut rows = eyeball_im::Vector::new();
    until(&mut chats, &mut rows, |rows| {
        rows.iter().any(|chat| {
            chat.id == ChatId::from("!climbing:matrix.org")
                && chat
                    .member_avatars
                    .iter()
                    .map(MediaId::as_str)
                    .eq(["mxc://matrix.org/ivan", "mxc://matrix.org/judy"])
        })
    })
    .await;
}

#[tokio::test(flavor = "multi_thread")]
async fn a_group_names_its_latest_senders_whom_the_sync_did_not_name_without_being_opened() {
    let server = server().await;
    let own = "@cheeky_monkey:matrix.org";
    Mock::given(method("POST"))
        .and(path("/_matrix/client/unstable/org.matrix.simplified_msc3575/sync"))
        .respond_with(
            ResponseTemplate::new(200)
                .set_body_json(json!({
                    "pos": "1",
                    "lists": { "all_rooms": { "count": 1 } },
                    "rooms": {
                        // a picture of its own: only the sender's name needs the members.
                        "!climbing:matrix.org": {
                            "name": "Climbing",
                            "avatar": "mxc://matrix.org/wall",
                            "initial": true,
                            "joined_count": 4,
                            "required_state": [joined(own, None)],
                            "timeline": [message("@messenger_7:matrix.org", "$climbing")]
                        }
                    }
                }))
                .set_delay(Duration::from_millis(200)),
        )
        .mount(server.server())
        .await;
    let mut ivan = joined("@messenger_7:matrix.org", None);
    ivan["content"]["displayname"] = json!("Ivan");
    ivan["room_id"] = json!("!climbing:matrix.org");
    Mock::given(method("GET"))
        .and(path("/_matrix/client/v3/rooms/!climbing:matrix.org/members"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({ "chunk": [ivan] })))
        .mount(server.server())
        .await;
    let (account, _folder) = signed_in(&server).await;
    let mut chats = account.chats();
    let mut rows = eyeball_im::Vector::new();

    until(&mut chats, &mut rows, |rows| {
        rows.iter().any(|chat| {
            chat.id == ChatId::from("!climbing:matrix.org")
                && chat.preview.as_ref().and_then(|preview| preview.author.clone())
                    == Some(lux_core::preview::Author::Named("Ivan".to_owned()))
        })
    })
    .await;
}

#[tokio::test(flavor = "multi_thread")]
async fn a_sender_the_store_did_not_hold_is_named_once_it_does() {
    let server = server().await;
    let sync = |pos: &str, body: &str, state: Vec<serde_json::Value>| {
        json!({
            "pos": pos,
            "lists": { "all_rooms": { "count": 1 } },
            "rooms": {
                "!club:matrix.org": {
                    "name": "Club",
                    "initial": pos == "1",
                    "joined_count": 4,
                    "required_state": state,
                    "timeline": [{
                        "type": "m.room.message",
                        "event_id": format!("${pos}"),
                        "sender": "@xavier:matrix.org",
                        "origin_server_ts": 1_700_000_000_000_u64 + u64::from(pos == "2"),
                        "content": { "msgtype": "m.text", "body": body }
                    }]
                }
            }
        })
    };
    let first = sync("1", "first", Vec::new());
    let later = sync(
        "2",
        "later",
        vec![json!({
            "type": "m.room.member",
            "event_id": "$xavier",
            "sender": "@xavier:matrix.org",
            "state_key": "@xavier:matrix.org",
            "origin_server_ts": 1_699_000_000_000_u64,
            "content": { "membership": "join", "displayname": "Xavier" }
        })],
    );
    Mock::given(method("POST"))
        .and(path("/_matrix/client/unstable/org.matrix.simplified_msc3575/sync"))
        .respond_with(
            ResponseTemplate::new(200)
                .set_body_json(first)
                .set_delay(Duration::from_millis(200)),
        )
        // the list shows a chat's latest message from the next answer on; the sender's member
        // comes only with the later ones.
        .up_to_n_times(4)
        .mount(server.server())
        .await;
    Mock::given(method("POST"))
        .and(path("/_matrix/client/unstable/org.matrix.simplified_msc3575/sync"))
        .respond_with(
            ResponseTemplate::new(200)
                .set_body_json(later)
                .set_delay(Duration::from_millis(200)),
        )
        .mount(server.server())
        .await;
    let (account, _folder) = signed_in(&server).await;
    let mut chats = account.chats();
    let mut rows = eyeball_im::Vector::new();
    let author = |rows: &eyeball_im::Vector<Arc<Chat>>| {
        rows.iter()
            .find(|chat| chat.id == ChatId::from("!club:matrix.org"))
            .and_then(|chat| chat.preview.clone())
            .and_then(|preview| preview.author)
    };
    until(&mut chats, &mut rows, |rows| {
        author(rows) == Some(lux_core::preview::Author::Named("xavier".to_owned()))
    })
    .await;
    until(&mut chats, &mut rows, |rows| {
        rows.iter().any(|chat| says(chat, "later"))
            && author(rows) == Some(lux_core::preview::Author::Named("Xavier".to_owned()))
    })
    .await;
}

#[tokio::test(flavor = "multi_thread")]
async fn a_member_who_renames_is_named_anew_in_the_group_preview() {
    let server = server().await;
    let sync = |pos: &str, body: &str, name: &str| {
        json!({
            "pos": pos,
            "lists": { "all_rooms": { "count": 1 } },
            "rooms": {
                "!club:matrix.org": {
                    "name": "Club",
                    "initial": pos == "1",
                    "joined_count": 4,
                    "required_state": [{
                        "type": "m.room.member",
                        "event_id": format!("$xavier{pos}"),
                        "sender": "@xavier:matrix.org",
                        "state_key": "@xavier:matrix.org",
                        "origin_server_ts": 1_699_000_000_000_u64 + u64::from(pos == "2"),
                        "content": { "membership": "join", "displayname": name }
                    }],
                    "timeline": [{
                        "type": "m.room.message",
                        "event_id": format!("${pos}"),
                        "sender": "@xavier:matrix.org",
                        "origin_server_ts": 1_700_000_000_000_u64 + u64::from(pos == "2"),
                        "content": { "msgtype": "m.text", "body": body }
                    }]
                }
            }
        })
    };
    Mock::given(method("POST"))
        .and(path("/_matrix/client/unstable/org.matrix.simplified_msc3575/sync"))
        .respond_with(
            ResponseTemplate::new(200)
                .set_body_json(sync("1", "first", "Xavier"))
                .set_delay(Duration::from_millis(200)),
        )
        .up_to_n_times(4)
        .mount(server.server())
        .await;
    Mock::given(method("POST"))
        .and(path("/_matrix/client/unstable/org.matrix.simplified_msc3575/sync"))
        .respond_with(
            ResponseTemplate::new(200)
                .set_body_json(sync("2", "later", "Xavier Brown"))
                .set_delay(Duration::from_millis(200)),
        )
        .mount(server.server())
        .await;
    let (account, _folder) = signed_in(&server).await;
    let mut chats = account.chats();
    let mut rows = eyeball_im::Vector::new();
    let author = |rows: &eyeball_im::Vector<Arc<Chat>>| {
        rows.iter()
            .find(|chat| chat.id == ChatId::from("!club:matrix.org"))
            .and_then(|chat| chat.preview.clone())
            .and_then(|preview| preview.author)
    };
    let named = |name: &str| Some(lux_core::preview::Author::Named(name.to_owned()));
    until(&mut chats, &mut rows, |rows| author(rows) == named("Xavier")).await;
    until(&mut chats, &mut rows, |rows| {
        rows.iter().any(|chat| says(chat, "later")) && author(rows) == named("Xavier Brown")
    })
    .await;
}

/// A state event of a sync, sent by `sender`.
fn state(event_type: &str, state_key: &str, sender: &str, content: serde_json::Value) -> serde_json::Value {
    // an event id of the room versions since 4: no server name.
    let event_id =
        format!("${event_type}{state_key}{sender}").replace(|c: char| !c.is_ascii_alphanumeric() && c != '$', "_");
    let mut event = json!({
        "type": event_type,
        "state_key": state_key,
        "sender": sender,
        "event_id": event_id,
        "origin_server_ts": 1_700_000_000_000_u64,
    });
    event["content"] = content;
    event
}

/// A joined space of the sync, created by `creator`, with the chat `child` and `extra` state.
fn space(name: &str, creator: &str, child: &str, extra: Vec<serde_json::Value>) -> serde_json::Value {
    let mut required_state = vec![
        state(
            "m.room.create",
            "",
            creator,
            json!({ "creator": creator, "room_version": "10", "type": "m.space" }),
        ),
        state(
            "m.room.member",
            "@cheeky_monkey:matrix.org",
            "@cheeky_monkey:matrix.org",
            json!({ "membership": "join" }),
        ),
        state("m.room.name", "", creator, json!({ "name": name })),
        state("m.space.child", child, creator, json!({ "via": ["matrix.org"] })),
    ];
    required_state.extend(extra);
    json!({ "name": name, "initial": true, "joined_count": 2, "required_state": required_state })
}

#[tokio::test(flavor = "multi_thread")]
async fn the_spaces_leave_out_those_a_bridge_made_for_a_login() {
    let server = server().await;
    let wa_bridge = json!({
        "bridgebot": "@wa:matrix.org",
        "protocol": { "id": "whatsapp" },
        "channel": { "id": "4912345" },
    });
    Mock::given(method("POST"))
        .and(path("/_matrix/client/unstable/org.matrix.simplified_msc3575/sync"))
        .respond_with(
            ResponseTemplate::new(200)
                .set_body_json(json!({
                    "pos": "1",
                    "lists": { "all_rooms": { "count": 6 } },
                    "rooms": {
                        // bridgev2's space for a login.
                        "!meta:matrix.org": space("Instagram (Anna)", "@metabot:matrix.org", "!ig:matrix.org", vec![
                            state("m.bridge", "personal", "@metabot:matrix.org", json!({
                                "bridgebot": "@metabot:matrix.org",
                                "protocol": { "id": "instagram" },
                                "channel": { "id": "__personal_filtering_space__" },
                                "com.beeper.room_type.v2": "personal_filtering_space",
                            })),
                        ]),
                        // an older bridge's space, by a bot its chat's bridge state names.
                        "!wa:matrix.org": space("WhatsApp", "@wa:matrix.org", "!anna:matrix.org", Vec::new()),
                        "!anna:matrix.org": {
                            "name": "Anna", "initial": true, "joined_count": 2,
                            "required_state": [state("m.bridge", "4912345", "@wa:matrix.org", wa_bridge)],
                        },
                        // an older bridge's space the user shares with its bot alone.
                        "!signal:matrix.org": space("Signal", "@admin:matrix.org", "!anna:matrix.org", vec![
                            state("m.room.member", "@signalbot:matrix.org", "@signalbot:matrix.org", json!({ "membership": "join" })),
                        ]),
                        // the user's own space.
                        "!mine:matrix.org": space("Family", "@cheeky_monkey:matrix.org", "!anna:matrix.org", Vec::new()),
                        // a space someone else made.
                        "!club:matrix.org": space("Club", "@bob:matrix.org", "!anna:matrix.org", Vec::new()),
                    }
                }))
                .set_delay(Duration::from_millis(200)),
        )
        .mount(server.server())
        .await;
    let (account, _folder) = signed_in(&server).await;

    let mut spaces = lux_core::ports::Spaces::spaces(&account);
    // the space service reads the spaces' chats as they come: wait for them all.
    tokio::time::timeout(Duration::from_secs(10), async {
        while let Some(spaces) = spaces.next().await {
            let mut names: Vec<&str> = spaces.iter().map(|space| space.name.as_str()).collect();
            names.sort_unstable();
            if names == ["Club", "Family"] {
                return;
            }
        }
    })
    .await
    .expect("the bridges' spaces stayed, or the others did not come");
}

#[tokio::test(flavor = "multi_thread")]
async fn a_bridges_space_for_its_network_stays_though_the_sync_brings_it_without_its_bridge_state() {
    let server = server().await;
    Mock::given(method("POST"))
        .and(path("/_matrix/client/unstable/org.matrix.simplified_msc3575/sync"))
        .respond_with(
            ResponseTemplate::new(200)
                .set_body_json(json!({
                    "pos": "1",
                    "lists": { "all_rooms": { "count": 2 } },
                    "rooms": {
                        // a space the bridge's bot made for a part of its network, its bridge state
                        // left out of the sync, as the room list asks for none.
                        "!market:matrix.org": space("Marketplace", "@messengerbot:matrix.org", "!anna:matrix.org", Vec::new()),
                        "!anna:matrix.org": { "name": "Anna", "initial": true, "joined_count": 2 },
                    }
                }))
                .set_delay(Duration::from_millis(200)),
        )
        .mount(server.server())
        .await;
    // the server holds it: a channel of the network, not a login's space.
    Mock::given(method("GET"))
        .and(path("/_matrix/client/v3/rooms/!market:matrix.org/state"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!([state(
            "m.bridge",
            "messenger",
            "@messengerbot:matrix.org",
            json!({
                "bridgebot": "@messengerbot:matrix.org",
                "protocol": { "id": "facebookgo" },
                "channel": { "id": "-12", "displayname": "Marketplace" },
                "com.beeper.room_type.v2": "space",
            })
        ),])))
        .mount(server.server())
        .await;
    let (account, _folder) = signed_in(&server).await;

    let mut spaces = lux_core::ports::Spaces::spaces(&account);
    tokio::time::timeout(Duration::from_secs(10), async {
        while let Some(spaces) = spaces.next().await {
            if spaces.iter().any(|space| space.name == "Marketplace") {
                return;
            }
        }
    })
    .await
    .expect("the bridge's space for its network was left out");
}

/// The bridge state the Discord bridge gives a room of the server `guild`: the server's space,
/// one of its categories, or one of its channels (`channel`).
fn discord(room: &str, guild: &str, channel: Option<&str>) -> serde_json::Value {
    let key = channel.map_or_else(
        || format!("fi.mau.discord://discord/{guild}"),
        |channel| format!("fi.mau.discord://discord/{guild}/{channel}"),
    );
    state(
        "m.bridge",
        &key,
        "@discordbot:matrix.org",
        json!({
            "bridgebot": "@discordbot:matrix.org",
            "protocol": { "id": "discordgo" },
            "channel": { "id": channel.unwrap_or(guild), "displayname": room },
        }),
    )
}

/// `m.space.child` events of a space made by the Discord bridge, for `children`.
fn children(children: &[&str]) -> Vec<serde_json::Value> {
    children
        .iter()
        .map(|child| {
            state(
                "m.space.child",
                child,
                "@discordbot:matrix.org",
                json!({ "via": ["matrix.org"] }),
            )
        })
        .collect()
}

#[tokio::test(flavor = "multi_thread")]
async fn a_server_in_the_discord_bridges_login_space_lists_its_categories() {
    let server = server().await;
    let bot = "@discordbot:matrix.org";
    let channel = |name: &str, id: &str| {
        json!({
            "name": name, "initial": true, "joined_count": 2,
            "required_state": [discord(name, "1", Some(id))],
        })
    };
    let mut radian = children(&["!general:matrix.org", "!empty:matrix.org"]);
    radian.push(discord("Radian", "1", None));
    // an empty category: a space with no child.
    let mut empty = space(
        "Voice Channels",
        bot,
        "",
        vec![discord("Voice Channels", "1", Some("11"))],
    );
    if let Some(events) = empty["required_state"].as_array_mut() {
        events.retain(|event| event["type"] != "m.space.child");
    }
    Mock::given(method("POST"))
        .and(path("/_matrix/client/unstable/org.matrix.simplified_msc3575/sync"))
        .respond_with(
            ResponseTemplate::new(200)
                .set_body_json(json!({
                    "pos": "1",
                    "lists": { "all_rooms": { "count": 6 } },
                    "rooms": {
                        // the older Discord bridge's space for the login: no bridge state, the
                        // servers inside it.
                        "!discord:matrix.org": space("Discord", bot, "!radian:matrix.org", Vec::new()),
                        // a server, its categories inside it: one with a channel, one empty.
                        "!radian:matrix.org": space("Radian", bot, "!chat:matrix.org", radian),
                        "!general:matrix.org": space("General", bot, "!open:matrix.org", vec![discord("General", "1", Some("10"))]),
                        "!empty:matrix.org": empty,
                        "!chat:matrix.org": channel("radian", "12"),
                        "!open:matrix.org": channel("open-space", "13"),
                    }
                }))
                .set_delay(Duration::from_millis(200)),
        )
        .mount(server.server())
        .await;
    let (account, _folder) = signed_in(&server).await;

    let mut spaces = lux_core::ports::Spaces::spaces(&account);
    let radian = RoomId::from("!radian:matrix.org");
    // each space's name and parents' names, by name.
    let shape = |spaces: &[lux_core::chat::Space]| {
        let mut shape: Vec<(String, Vec<String>)> = spaces
            .iter()
            .map(|space| {
                (
                    space.name.clone(),
                    space.parents.iter().map(ToString::to_string).collect(),
                )
            })
            .collect();
        shape.sort();
        shape
    };
    let wanted = vec![
        ("General".to_owned(), vec![radian.to_string()]),
        ("Radian".to_owned(), Vec::new()),
        ("Voice Channels".to_owned(), vec![radian.to_string()]),
    ];
    let mut last = Vec::new();
    // the space service reads the spaces' chats as they come: wait for them all.
    let found = tokio::time::timeout(Duration::from_secs(10), async {
        while let Some(spaces) = spaces.next().await {
            last = shape(&spaces);
            if last == wanted {
                return spaces;
            }
        }
        Arc::from(Vec::new())
    })
    .await;
    let spaces = found.unwrap_or_else(|_| panic!("the spaces stayed {last:?}"));
    let chats = |name: &str| {
        let mut chats: Vec<String> = spaces
            .iter()
            .find(|space| space.name == name)
            .map(|space| space.chats.iter().map(ToString::to_string).collect())
            .unwrap_or_default();
        chats.sort();
        chats
    };
    assert!(chats("Radian").contains(&"!open:matrix.org".to_owned()));
    assert_eq!(chats("General"), ["!open:matrix.org"]);
    assert!(chats("Voice Channels").iter().all(|chat| chat != "!open:matrix.org"));
}

#[tokio::test(flavor = "multi_thread")]
async fn a_space_in_two_spaces_shows_once() {
    let server = server().await;
    let own = "@cheeky_monkey:matrix.org";
    Mock::given(method("POST"))
        .and(path("/_matrix/client/unstable/org.matrix.simplified_msc3575/sync"))
        .respond_with(
            ResponseTemplate::new(200)
                .set_body_json(json!({
                    "pos": "1",
                    "lists": { "all_rooms": { "count": 4 } },
                    "rooms": {
                        "!family:matrix.org": space("Family", own, "!trips:matrix.org", Vec::new()),
                        "!friends:matrix.org": space("Friends", own, "!trips:matrix.org", Vec::new()),
                        // in both of them.
                        "!trips:matrix.org": space("Trips", own, "!anna:matrix.org", Vec::new()),
                        "!anna:matrix.org": { "name": "Anna", "initial": true, "joined_count": 2 },
                    }
                }))
                .set_delay(Duration::from_millis(200)),
        )
        .mount(server.server())
        .await;
    let (account, _folder) = signed_in(&server).await;

    let mut spaces = lux_core::ports::Spaces::spaces(&account);
    tokio::time::timeout(Duration::from_secs(10), async {
        while let Some(spaces) = spaces.next().await {
            let mut names: Vec<&str> = spaces.iter().map(|space| space.name.as_str()).collect();
            names.sort_unstable();
            if names == ["Family", "Friends", "Trips"] {
                let trips = spaces.iter().find(|space| space.name == "Trips").unwrap();
                assert_eq!(trips.parents.len(), 2);
                return;
            }
        }
    })
    .await
    .expect("the space in two spaces did not show once");
}

#[tokio::test(flavor = "multi_thread")]
async fn a_space_the_account_left_does_not_show_though_its_parent_lists_it() {
    let server = server().await;
    let own = "@cheeky_monkey:matrix.org";
    let mut left = space("Old trips", own, "!anna:matrix.org", Vec::new());
    left["required_state"][1]["content"]["membership"] = json!("leave");
    Mock::given(method("POST"))
        .and(path("/_matrix/client/unstable/org.matrix.simplified_msc3575/sync"))
        .respond_with(
            ResponseTemplate::new(200)
                .set_body_json(json!({
                    "pos": "1",
                    "lists": { "all_rooms": { "count": 3 } },
                    "rooms": {
                        "!family:matrix.org": space("Family", own, "!old:matrix.org", Vec::new()),
                        // listed by its parent, but the account left it.
                        "!old:matrix.org": left,
                        "!anna:matrix.org": { "name": "Anna", "initial": true, "joined_count": 2 },
                    }
                }))
                .set_delay(Duration::from_millis(200)),
        )
        .mount(server.server())
        .await;
    let (account, _folder) = signed_in(&server).await;

    let mut spaces = lux_core::ports::Spaces::spaces(&account);
    let mut seen = Vec::new();
    let found = tokio::time::timeout(Duration::from_secs(5), async {
        while let Some(spaces) = spaces.next().await {
            seen = spaces.iter().map(|space| space.name.clone()).collect::<Vec<_>>();
            if seen.contains(&"Family".to_owned()) && spaces.len() == 1 {
                return true;
            }
        }
        false
    })
    .await;
    assert!(found.unwrap_or(false), "the spaces were {seen:?}");
}

/// The account's key backup on `server`, as the SDK's own tests keep it: secret storage that the
/// passphrase "mypassphrase" opens, holding the backup's decryption key
/// [`BACKUP_DECRYPTION_KEY`], and the backup itself (whose keys none are mounted yet).
async fn mock_key_backup(server: &MatrixMockServer) {
    const KEY_ID: &str = "yJWwBm2Ts8jHygTBslKpABFyykavhhfA";
    let data = |name: &str, body: serde_json::Value| {
        Mock::given(method("GET"))
            .and(path(format!(
                "/_matrix/client/v3/user/@cheeky_monkey:matrix.org/account_data/{name}"
            )))
            .respond_with(ResponseTemplate::new(200).set_body_json(body))
    };
    data("m.secret_storage.default_key", json!({ "key": KEY_ID }))
        .mount(server.server())
        .await;
    data(
        &format!("m.secret_storage.key.{KEY_ID}"),
        json!({
            "algorithm": "m.secret_storage.v1.aes-hmac-sha2",
            "iv": "1Sl4os6UhNRkVQcT6ArQ0g",
            "mac": "UCZlTzqVT7mNvLkwlcCJmuq9nA27oxqpXGdLr9SxD/Y",
            "passphrase": { "algorithm": "m.pbkdf2", "iterations": 1, "salt": "ooLiz7Kz0TeWH2eYcyjP2fCegEB7PH5B" }
        }),
    )
    .mount(server.server())
    .await;
    data(
        "m.megolm_backup.v1",
        json!({
            "encrypted": { KEY_ID: {
                "ciphertext": "c39B25f6GSvW7gCUZI1OC0V821Ht2WUfxPWB43rvFSsubouHf16ImqLrwQ",
                "iv": "hpyoGAElX8YRuigbqa7tfA",
                "mac": "nE/RCVmFQxu+KuqxmYDDzIxf2JUlxz2oTpoJTj5pUxM"
            }}
        }),
    )
    .mount(server.server())
    .await;
    // the device's keys, kept as it uploads them and given back when asked for.
    let device_keys = Arc::new(Mutex::new(serde_json::Value::Null));
    let uploaded = Arc::clone(&device_keys);
    Mock::given(method("POST"))
        .and(path("/_matrix/client/v3/keys/upload"))
        .respond_with(move |request: &wiremock::Request| {
            let body: serde_json::Value = serde_json::from_slice(&request.body).unwrap();
            if let Some(keys) = body.get("device_keys") {
                *uploaded.lock().unwrap() = keys.clone();
            }
            ResponseTemplate::new(200).set_body_json(json!({ "one_time_key_counts": {} }))
        })
        .mount(server.server())
        .await;
    Mock::given(method("POST"))
        .and(path("/_matrix/client/v3/keys/query"))
        .respond_with(move |_: &wiremock::Request| {
            let keys = device_keys.lock().unwrap().clone();
            let devices = match keys["device_id"].as_str() {
                Some(device) => json!({ "@cheeky_monkey:matrix.org": { device: keys } }),
                None => json!({}),
            };
            ResponseTemplate::new(200).set_body_json(json!({ "device_keys": devices }))
        })
        .mount(server.server())
        .await;
    // no cross-signing keys in it.
    for name in [
        "m.cross_signing.master",
        "m.cross_signing.user_signing",
        "m.cross_signing.self_signing",
    ] {
        Mock::given(method("GET"))
            .and(path(format!(
                "/_matrix/client/v3/user/@cheeky_monkey:matrix.org/account_data/{name}"
            )))
            .respond_with(
                ResponseTemplate::new(404)
                    .set_body_json(json!({ "errcode": "M_NOT_FOUND", "error": "Account data not found" })),
            )
            .mount(server.server())
            .await;
    }
    Mock::given(method("GET"))
        .and(path("/_matrix/client/v3/room_keys/version"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "algorithm": "m.megolm_backup.v1.curve25519-aes-sha2",
            "auth_data": { "public_key": "hdx5rSn94rBuvJI5cwnhKAVmFyZgfJjk7vwEBD6mIHc", "signatures": {} },
            "count": 1,
            "etag": "1",
            "version": "6"
        })))
        .mount(server.server())
        .await;
}

/// The key backup's decryption key, as [`mock_key_backup`]'s secret storage holds it.
const BACKUP_DECRYPTION_KEY: &str = "IeJv45zHC4AamrFtCi3MedkLMBZYXjPbKUnv53Iqzho";

/// A message encrypted in a session whose key only the key backup of [`mock_key_backup`] holds.
struct BackedUpMessage {
    /// The `m.room.encrypted` event's content.
    content: serde_json::Value,
    session_id: String,
    /// The session's key, as the backup gives it.
    backed_up_key: serde_json::Value,
}

impl BackedUpMessage {
    async fn new(room: &matrix_sdk::ruma::RoomId, body: &str) -> Self {
        let sender = IdentityKeys {
            ed25519: Ed25519SecretKey::new().public_key(),
            curve25519: Curve25519PublicKey::from(&Curve25519SecretKey::new()),
        };
        let outbound = OutboundGroupSession::new(
            matrix_sdk::ruma::owned_device_id!("SENDER"),
            Arc::new(sender),
            room,
            CryptoSettings::default(),
        )
        .unwrap();
        let inbound = InboundGroupSession::new(
            outbound.sender_key(),
            sender.ed25519,
            room,
            &outbound.session_key().await,
            SenderData::unknown(),
            None,
            EventEncryptionAlgorithm::MegolmV1AesSha2,
            None,
            false,
        )
        .unwrap();
        let content = json!({ "msgtype": "m.text", "body": body });
        let encrypted = outbound
            .encrypt("m.room.message", &serde_json::from_value(content).unwrap())
            .await;
        let session_id = inbound.session_id().to_owned();
        let backed_up_key = BackupDecryptionKey::from_base64(BACKUP_DECRYPTION_KEY)
            .unwrap()
            .megolm_v1_public_key()
            .encrypt(inbound)
            .await
            .unwrap();
        Self {
            content: serde_json::to_value(encrypted.content).unwrap(),
            session_id,
            backed_up_key: serde_json::to_value(backed_up_key).unwrap(),
        }
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn a_message_synced_before_the_key_backup_opened_is_read_in_the_list_after_a_relaunch() {
    let server = server().await;
    let own = "@cheeky_monkey:matrix.org";
    let room = matrix_sdk::ruma::room_id!("!climbing:matrix.org");
    let message = BackedUpMessage::new(room, "see you at the wall").await;
    Mock::given(method("POST"))
        .and(path("/_matrix/client/unstable/org.matrix.simplified_msc3575/sync"))
        .respond_with(
            ResponseTemplate::new(200)
                .set_body_json(json!({
                    "pos": "1",
                    "lists": { "all_rooms": { "count": 1 } },
                    "rooms": {
                        "!climbing:matrix.org": {
                            "name": "Climbing",
                            "initial": true,
                            "joined_count": 2,
                            "required_state": [
                                joined(own, None),
                                state("m.room.encryption", "", own, json!({ "algorithm": "m.megolm.v1.aes-sha2" })),
                            ],
                            "timeline": [
                                joined(own, None),
                                {
                                    "type": "m.room.encrypted",
                                    "event_id": "$wall",
                                    "sender": "@meta_1:matrix.org",
                                    "origin_server_ts": 1_700_000_000_000_u64,
                                    "content": message.content
                                }
                            ]
                        }
                    }
                }))
                .set_delay(Duration::from_millis(200)),
        )
        .mount(server.server())
        .await;
    mock_key_backup(&server).await;
    let folder = tempfile::tempdir().unwrap();
    let sign_in = MatrixSignIn::new(StoreFolder::new(folder.path()), Arc::new(MemorySecrets::default()));
    let account = sign_in
        .sign_in_with_password(&server.uri(), "cheeky_monkey", "secret", "Lux (Test)")
        .await
        .unwrap();
    let mut chats = account.chats();
    let mut rows = eyeball_im::Vector::new();
    // the message cannot be read: the row says the account joined.
    until(&mut chats, &mut rows, |rows| {
        rows.iter().any(|chat| {
            chat.id == ChatId::from(room.as_str())
                && chat
                    .preview
                    .as_ref()
                    .is_some_and(|preview| matches!(preview.kind, PreviewKind::Membership(_)))
        })
    })
    .await;
    // the key backup opens while the server does not give its keys yet.
    account.recover("mypassphrase").await.unwrap();
    drop((chats, account));

    // the next launch: the backup gives the key.
    Mock::given(method("GET"))
        .and(path(format!(
            "/_matrix/client/v3/room_keys/keys/{room}/{}",
            message.session_id.replace('/', "%2F")
        )))
        .respond_with(ResponseTemplate::new(200).set_body_json(message.backed_up_key))
        .mount(server.server())
        .await;
    let account = sign_in.restore().await.unwrap().unwrap();
    let mut chats = account.chats();
    let mut rows = eyeball_im::Vector::new();
    until(&mut chats, &mut rows, |rows| {
        rows.iter()
            .any(|chat| chat.id == ChatId::from(room.as_str()) && says(chat, "see you at the wall"))
    })
    .await;
}

/// How many descriptors this process holds open on `file`: one per SQLite connection to it.
#[allow(unsafe_code, reason = "F_GETPATH is how macOS tells an open descriptor's path")]
fn connections_to(file: &std::path::Path) -> usize {
    use std::os::unix::ffi::OsStrExt;
    let file = file.canonicalize().unwrap();
    // SAFETY: it reads no memory of ours.
    let descriptors = unsafe { libc::getdtablesize() };
    (0..descriptors)
        .filter(|&descriptor| {
            let mut buffer = [0 as libc::c_char; libc::PATH_MAX as usize];
            // SAFETY: F_GETPATH writes a C string of at most PATH_MAX bytes into the buffer.
            if unsafe { libc::fcntl(descriptor, libc::F_GETPATH, buffer.as_mut_ptr()) } != 0 {
                return false;
            }
            // SAFETY: the call succeeded, so the buffer holds a C string.
            let path = unsafe { std::ffi::CStr::from_ptr(buffer.as_ptr()) };
            path.to_bytes() == file.as_os_str().as_bytes()
        })
        .count()
}

#[tokio::test(flavor = "multi_thread")]
async fn opening_many_chats_at_once_keeps_a_few_connections_to_each_store() {
    const ROOMS: usize = 40;
    let server = server().await;
    let rooms: serde_json::Map<String, serde_json::Value> = (0..ROOMS)
        .map(|room| {
            let room_id = format!("!room{room}:matrix.org");
            let body = json!({
                "name": format!("Room {room}"),
                "initial": true,
                "joined_count": 2,
                "timeline": [message("@anna:matrix.org", &format!("$message{room}"))],
                "prev_batch": format!("before{room}"),
            });
            (room_id, body)
        })
        .collect();
    Mock::given(method("POST"))
        .and(path("/_matrix/client/unstable/org.matrix.simplified_msc3575/sync"))
        .respond_with(
            ResponseTemplate::new(200)
                .set_body_json(json!({ "pos": "1", "lists": { "all_rooms": { "count": ROOMS } }, "rooms": rooms }))
                // the sync long-polls: not every few milliseconds.
                .set_delay(Duration::from_millis(200)),
        )
        .mount(server.server())
        .await;
    let (account, folder) = signed_in(&server).await;
    let mut chats = account.chats();
    let mut rows = eyeball_im::Vector::new();
    until(&mut chats, &mut rows, |rows| rows.len() == ROOMS).await;

    // the chats open at once, each reading the stores.
    let timelines = account.timelines();
    let opened = futures_util::future::join_all((0..ROOMS).map(|room| async move {
        let room = RoomId::from(format!("!room{room}:matrix.org").as_str());
        timelines.messages(&TimelineId::from(&room)).await
    }))
    .await;
    assert!(opened.iter().all(Result::is_ok));

    // a connection stays open as long as the account, with its page cache: a few, not one for
    // each read that came at once.
    for store in [
        "data/matrix-sdk-state.sqlite3",
        "data/matrix-sdk-crypto.sqlite3",
        "cache/matrix-sdk-event-cache.sqlite3",
    ] {
        let connections = connections_to(&folder.path().join(store));
        assert!((1..=8).contains(&connections), "{connections} connections to {store}");
    }
}
