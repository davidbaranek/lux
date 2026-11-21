//! Push notifications against the SDK's mock server: the device's pusher, and a pushed event read
//! as the notification extension reads it, from the kept store without the app's sync.

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
use lux_core::ids::{ChatId, RoomId, TimelineId};
use lux_core::ports::{
    BackendError, ChatAccount, ChatActions, ChatChange, Push, SecretStore, SessionSecrets, SignIn, UnusableStore,
};
use lux_core::preview::PreviewKind;
use lux_core::push::{PushEnvironment, PushKey, PushedEvent, Pusher};
use lux_matrix::{MatrixNotifications, MatrixSignIn, StoreFolder};
use matrix_sdk::test_utils::mocks::MatrixMockServer;
use serde_json::{Value, json};
use wiremock::matchers::{method, path, path_regex};
use wiremock::{Mock, ResponseTemplate};

mod support;
use support::{MemorySecrets, Requests, server, signed_in};

const SYNC: &str = "/_matrix/client/unstable/org.matrix.simplified_msc3575/sync";

/// Every sliding sync, the app's and the extension's, answers with one direct chat and its
/// newest message; the syncs that reach `server`.
/// The write-ahead logs in `folder`: a store's lives while a connection holds it open.
fn logs(folder: &std::path::Path) -> Vec<std::path::PathBuf> {
    let mut found = Vec::new();
    let mut folders = vec![folder.to_path_buf()];
    while let Some(folder) = folders.pop() {
        for entry in std::fs::read_dir(&folder).unwrap() {
            let path = entry.unwrap().path();
            if path.is_dir() {
                folders.push(path);
            } else if path.to_string_lossy().ends_with("-wal") {
                found.push(path);
            }
        }
    }
    found
}

async fn mount_sync(server: &MatrixMockServer) -> Requests {
    mount_sync_with(server, 1_700_000_000_000, &[], &[]).await
}

/// Every sliding sync answers with one direct chat, its message sent at `sent` (ms) and the events
/// `after` it, one unread notification, and the account data `account_data`; the syncs that reach
/// `server`.
async fn mount_sync_with(server: &MatrixMockServer, sent: u64, after: &[Value], account_data: &[Value]) -> Requests {
    let syncs = Requests::default();
    let mut timeline = vec![json!({
        "type": "m.room.message",
        "event_id": "$hello",
        "sender": "@anna:matrix.org",
        "origin_server_ts": sent,
        "content": { "msgtype": "m.text", "body": "hello\nthere" }
    })];
    timeline.extend_from_slice(after);
    Mock::given(method("POST"))
        .and(path(SYNC))
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
                                "notification_count": 1,
                                // the account's own membership: the push rules need its name.
                                "required_state": [{
                                    "type": "m.room.member",
                                    "state_key": "@cheeky_monkey:matrix.org",
                                    "event_id": "$joined",
                                    "sender": "@cheeky_monkey:matrix.org",
                                    "origin_server_ts": 1_600_000_000_000_u64,
                                    "content": { "membership": "join", "displayname": "Me" }
                                }],
                                "heroes": [{
                                    "user_id": "@anna:matrix.org",
                                    "displayname": "Anna",
                                    "avatar_url": "mxc://matrix.org/anna"
                                }],
                                "timeline": timeline
                            }
                        },
                        "extensions": { "account_data": { "global": account_data } }
                    }))
                    // the sync long-polls: not every few milliseconds.
                    .set_delay(Duration::from_millis(200)),
            ),
        )
        .mount(server.server())
        .await;
    syncs
}

/// Waits until the account's chat list has the test's room.
async fn wait_for_room(account: &lux_matrix::MatrixAccount) {
    let mut chats = account.chats();
    let mut rows = eyeball_im::Vector::new();
    tokio::time::timeout(Duration::from_secs(10), async {
        while let Some(batch) = chats.next().await {
            for diff in batch {
                diff.apply(&mut rows);
            }
            if rows.iter().any(|chat| chat.id == ChatId::from("!anna:matrix.org")) {
                return;
            }
        }
    })
    .await
    .expect("the room in time");
}

fn pusher(token: u8, environment: PushEnvironment) -> Pusher {
    Pusher {
        app_id: environment.app_id("com.example.ios"),
        push_key: PushKey::from_token(&[token; 4]),
        gateway_url: "https://push.example.com/_matrix/push/v1/notify".to_owned(),
        app_name: "Lux".to_owned(),
        device_name: "Lux (iPhone)".to_owned(),
        language: "en".to_owned(),
        fallback_text: "New message".to_owned(),
    }
}

/// The bodies of the requests the server had at `endpoint`, in order.
async fn bodies(server: &MatrixMockServer, endpoint: &str) -> Vec<Value> {
    server
        .server()
        .received_requests()
        .await
        .unwrap()
        .into_iter()
        .filter(|request| request.url.path().ends_with(endpoint))
        .map(|request| serde_json::from_slice(&request.body).unwrap())
        .collect()
}

#[tokio::test(flavor = "multi_thread")]
async fn the_pusher_is_replaced_when_its_token_changes_and_goes_on_sign_out() {
    let server = server().await;
    Mock::given(method("POST"))
        .and(path_regex(r"/_matrix/client/[^/]+/pushers/set$"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({})))
        .mount(server.server())
        .await;
    Mock::given(method("POST"))
        .and(path_regex(r"/_matrix/client/[^/]+/logout$"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({})))
        .mount(server.server())
        .await;
    let (account, _folder) = signed_in(&server).await;

    account.set_pusher(&pusher(1, PushEnvironment::Sandbox)).await.unwrap();
    // the same pusher again (each launch): renewed, nothing removed.
    account.set_pusher(&pusher(1, PushEnvironment::Sandbox)).await.unwrap();
    // a new token: the new pusher, then the old one removed.
    account.set_pusher(&pusher(2, PushEnvironment::Sandbox)).await.unwrap();
    account.sign_out().await.unwrap();

    let sent = bodies(&server, "/pushers/set").await;
    assert_eq!(sent.len(), 5, "{sent:#?}");
    assert_eq!(
        sent[0],
        json!({
            "pushkey": "01010101",
            "app_id": "com.example.ios.dev",
            "kind": "http",
            "app_display_name": "Lux",
            "device_display_name": "Lux (iPhone)",
            "lang": "en",
            "data": {
                "url": "https://push.example.com/_matrix/push/v1/notify",
                "format": "event_id_only",
                "default_payload": {
                    "aps": { "mutable-content": 1, "alert": { "body": "New message" }, "sound": "default" }
                }
            }
        })
    );
    assert_eq!(sent[1]["pushkey"], "01010101");
    assert_eq!(sent[2]["pushkey"], "02020202");
    assert_eq!(sent[2]["kind"], "http");
    // deletions: `kind` null.
    assert_eq!(
        (&sent[3]["pushkey"], &sent[3]["kind"]),
        (&json!("01010101"), &Value::Null)
    );
    assert_eq!(
        (&sent[4]["pushkey"], &sent[4]["kind"]),
        (&json!("02020202"), &Value::Null)
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn the_extension_reads_a_pushed_message_from_the_kept_store() {
    let server = server().await;
    mount_sync(&server).await;
    server.mock_room_state_encryption().plain().mount().await;
    let folder = tempfile::tempdir().unwrap();
    let secrets = Arc::new(MemorySecrets::default());
    let sign_in = MatrixSignIn::new(StoreFolder::new(folder.path()), secrets.clone());
    let account = sign_in
        .sign_in_with_password(&server.uri(), "cheeky_monkey", "secret", "Lux (Test)")
        .await
        .unwrap();
    account.wait_for_first_sync().await;
    account.pause_sync().await;
    drop(account);

    let notifications = MatrixNotifications::open(&StoreFolder::new(folder.path()), secrets.clone())
        .await
        .unwrap()
        .expect("the kept session");
    let pushed = tokio::time::timeout(
        Duration::from_secs(20),
        notifications.read(&"!anna:matrix.org".into(), &"$hello".into()),
    )
    .await
    .expect("the event in time")
    .unwrap();
    let PushedEvent::Shown(notification) = pushed else {
        panic!("not shown: {pushed:?}");
    };
    assert_eq!(notification.room.as_str(), "!anna:matrix.org");
    assert_eq!(notification.chat_name, "Anna");
    assert_eq!(notification.sender_name, "anna");
    assert!(!notification.is_group);
    assert_eq!(notification.kind, PreviewKind::Text("hello there".to_owned()));

    // handed back, the extension closes the stores in the shared folder before it is suspended:
    // a read after fails rather than open them again, and the next push opens the account anew.
    assert!(!logs(folder.path()).is_empty(), "the stores are open while it reads");
    notifications.close().await;
    // every store's connection closes (its log checkpointed and gone); the SDK lets a write that
    // already held the crypto store's connection end first.
    tokio::time::timeout(Duration::from_secs(5), async {
        while !logs(folder.path()).is_empty() {
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
    })
    .await
    .expect("the stores closed");
    drop(notifications);
    let next = MatrixNotifications::open(&StoreFolder::new(folder.path()), secrets)
        .await
        .unwrap()
        .expect("the kept session");
    let pushed = tokio::time::timeout(
        Duration::from_secs(20),
        next.read(&"!anna:matrix.org".into(), &"$hello".into()),
    )
    .await
    .expect("the event in time")
    .unwrap();
    assert!(matches!(pushed, PushedEvent::Shown(_)));
}

/// A reaction is pushed when the server cannot read its type (in an encrypted chat it is
/// `m.room.encrypted`, which `.m.rule.encrypted` pushes); read on the device, the push rules'
/// `.m.rule.reaction` filters it out: the extension shows nothing of it (quietly, without Apple's
/// filtering entitlement), never the reaction as a message.
#[tokio::test(flavor = "multi_thread")]
async fn a_pushed_reaction_is_not_to_be_shown() {
    let server = server().await;
    let reaction = json!({
        "type": "m.reaction",
        "event_id": "$like",
        "sender": "@anna:matrix.org",
        "origin_server_ts": 1_700_000_001_000_u64,
        "content": { "m.relates_to": { "rel_type": "m.annotation", "event_id": "$hello", "key": "👍" } }
    });
    mount_sync_with(&server, 1_700_000_000_000, &[reaction], &[]).await;
    server.mock_room_state_encryption().plain().mount().await;
    let folder = tempfile::tempdir().unwrap();
    let secrets = Arc::new(MemorySecrets::default());
    let sign_in = MatrixSignIn::new(StoreFolder::new(folder.path()), secrets.clone());
    let account = sign_in
        .sign_in_with_password(&server.uri(), "cheeky_monkey", "secret", "Lux (Test)")
        .await
        .unwrap();
    account.wait_for_first_sync().await;
    account.pause_sync().await;
    drop(account);

    let notifications = MatrixNotifications::open(&StoreFolder::new(folder.path()), secrets)
        .await
        .unwrap()
        .expect("the kept session");
    let room = RoomId::from("!anna:matrix.org");
    let pushed = tokio::time::timeout(Duration::from_secs(20), notifications.read(&room, &"$like".into()))
        .await
        .expect("the event in time")
        .unwrap();
    assert_eq!(pushed, PushedEvent::FilteredOut);
    // the message it reacts to is shown.
    let pushed = tokio::time::timeout(Duration::from_secs(20), notifications.read(&room, &"$hello".into()))
        .await
        .expect("the event in time")
        .unwrap();
    assert!(matches!(pushed, PushedEvent::Shown(_)), "{pushed:?}");
    notifications.close().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn the_extension_never_opens_a_session_without_its_store() {
    let folder = tempfile::tempdir().unwrap();
    let secrets = Arc::new(MemorySecrets::default());
    let none = MatrixNotifications::open(&StoreFolder::new(folder.path()), secrets.clone()).await;
    assert!(matches!(none, Ok(None)));
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
    let missing = MatrixNotifications::open(&StoreFolder::new(folder.path().join("gone")), secrets.clone()).await;
    assert!(matches!(
        missing,
        Err(BackendError::StoreUnusable(UnusableStore::Missing))
    ));
    // the extension forgets nothing: the app does.
    assert!(secrets.load().unwrap().is_some());
    assert!(!folder.path().join("gone").exists());
}

#[tokio::test(flavor = "multi_thread")]
async fn a_notifications_reply_and_read_reach_the_server_before_returning() {
    let server = server().await;
    mount_sync(&server).await;
    server.mock_room_state_encryption().plain().mount().await;
    server
        .mock_room_send()
        .ok(matrix_sdk::ruma::event_id!("$reply"))
        .mount()
        .await;
    Mock::given(method("POST"))
        .and(path_regex(r"/rooms/[^/]+/receipt/m\.read/[^/]+$"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({})))
        .mount(server.server())
        .await;
    let (account, _folder) = signed_in(&server).await;
    account.wait_for_first_sync().await;
    let room = RoomId::from("!anna:matrix.org");
    // the room comes with the first answer's rooms.
    wait_for_room(&account).await;

    account
        .send_now(&TimelineId::from(&room), "on my **way**")
        .await
        .unwrap();
    account
        .mark_read_up_to(&TimelineId::from(&room), &"$hello".into())
        .await
        .unwrap();
    assert!(matches!(
        account
            .send_now(&TimelineId::from(RoomId::from("!gone:matrix.org")), "hi")
            .await,
        Err(BackendError::UnknownChat(_))
    ));

    let requests = server.server().received_requests().await.unwrap();
    let sent = requests
        .iter()
        .find(|request| request.url.path().contains("/send/m.room.message/"))
        .expect("the reply");
    let body: Value = serde_json::from_slice(&sent.body).unwrap();
    assert_eq!(body["body"], "on my **way**");
    assert_eq!(body["formatted_body"], "on my <strong>way</strong>");
    assert!(
        requests
            .iter()
            .any(|request| request.url.path().ends_with("/receipt/m.read/$hello"))
    );

    // a thread's reply answers in the thread, and reads the thread alone.
    let thread = TimelineId::thread(room.clone(), "$root".into());
    account.send_now(&thread, "in the thread").await.unwrap();
    account.mark_read_up_to(&thread, &"$reply".into()).await.unwrap();
    let requests = server.server().received_requests().await.unwrap();
    let threaded = requests
        .iter()
        .filter(|request| request.url.path().contains("/send/m.room.message/"))
        .map(|request| serde_json::from_slice::<Value>(&request.body).unwrap())
        .find(|body| body["body"] == "in the thread")
        .expect("the thread's reply");
    assert_eq!(threaded["m.relates_to"]["rel_type"], "m.thread");
    assert_eq!(threaded["m.relates_to"]["event_id"], "$root");
    let receipt = requests
        .iter()
        .find(|request| request.url.path().ends_with("/receipt/m.read/$reply"))
        .expect("the thread's receipt");
    let receipt: Value = serde_json::from_slice(&receipt.body).unwrap();
    assert_eq!(receipt["thread_id"], "$root");
}

#[tokio::test(flavor = "multi_thread")]
async fn muting_a_chat_leaves_the_server_nothing_to_push() {
    let server = server().await;
    mount_sync(&server).await;
    Mock::given(path_regex(r"/pushrules/"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({})))
        .mount(server.server())
        .await;
    let (account, _folder) = signed_in(&server).await;
    account.wait_for_first_sync().await;
    wait_for_room(&account).await;

    account
        .change(&"!anna:matrix.org".into(), ChatChange::Mute)
        .await
        .unwrap();

    let requests = server.server().received_requests().await.unwrap();
    let rules: Vec<(String, Value)> = requests
        .iter()
        .filter(|request| request.method.as_str() == "PUT" && request.url.path().contains("/pushrules/global/"))
        .map(|request| {
            (
                request.url.path().to_owned(),
                serde_json::from_slice(&request.body).unwrap(),
            )
        })
        .collect();
    // the room's override rule, before the default mention rules, and no action that notifies.
    let mute = rules
        .iter()
        .find(|(path, _)| path.ends_with("/override/!anna:matrix.org"))
        .expect("the mute rule");
    assert_eq!(mute.1["actions"], json!([]), "{mute:?}");
    assert_eq!(mute.1["conditions"][0]["pattern"], "!anna:matrix.org");
    // the app's own mention rule only highlights: the server pushes for `notify` alone.
    let mention = rules
        .iter()
        .find(|(path, _)| path.contains("/override/com.bardav.lux.mention."))
        .expect("the mention rule");
    let actions = mention.1["actions"].as_array().unwrap();
    assert!(!actions.contains(&json!("notify")), "{mention:?}");
    assert_eq!(actions, &vec![json!({ "set_tweak": "highlight" })]);
}

#[tokio::test(flavor = "multi_thread")]
async fn the_extension_names_the_merged_chat_and_brings_the_pictures() {
    let server = server().await;
    let merges = json!({
        "type": "com.bardav.lux.merges",
        "content": { "merges": [{
            "id": "anna",
            "name": "Anna Novak",
            "rooms": ["!other:matrix.org", "!anna:matrix.org"],
            "default": "!other:matrix.org"
        }]}
    });
    mount_sync_with(&server, 1_700_000_000_000, &[], &[merges]).await;
    server.mock_room_state_encryption().plain().mount().await;
    Mock::given(method("GET"))
        .and(path_regex(r"/thumbnail/matrix\.org/anna$"))
        .respond_with(ResponseTemplate::new(200).set_body_raw(b"anna's face".to_vec(), "image/jpeg"))
        .mount(server.server())
        .await;
    let folder = tempfile::tempdir().unwrap();
    let secrets = Arc::new(MemorySecrets::default());
    let sign_in = MatrixSignIn::new(StoreFolder::new(folder.path()), secrets.clone());
    let account = sign_in
        .sign_in_with_password(&server.uri(), "cheeky_monkey", "secret", "Lux (Test)")
        .await
        .unwrap();
    account.wait_for_first_sync().await;
    wait_for_room(&account).await;
    account.pause_sync().await;
    drop(account);

    let notifications = MatrixNotifications::open(&StoreFolder::new(folder.path()), secrets)
        .await
        .unwrap()
        .expect("the kept session");
    let pushed = tokio::time::timeout(
        Duration::from_secs(20),
        notifications.read(&"!anna:matrix.org".into(), &"$hello".into()),
    )
    .await
    .expect("the event in time")
    .unwrap();
    let PushedEvent::Shown(notification) = pushed else {
        panic!("not shown: {pushed:?}");
    };
    assert_eq!(notification.chat, ChatId::from("merge:anna"));
    assert_eq!(notification.chat_name, "Anna Novak");
    assert_eq!(notification.event.as_str(), "$hello");
    let pictures = notifications.pictures(&notification).await;
    assert_eq!(pictures.sender.as_deref(), Some(&b"anna's face"[..]));
}

#[tokio::test(flavor = "multi_thread")]
async fn a_picture_the_server_will_not_thumbnail_comes_as_it_is() {
    let server = server().await;
    mount_sync_with(&server, 1_700_000_000_000, &[], &[]).await;
    server.mock_room_state_encryption().plain().mount().await;
    // a server that made no thumbnail ahead and makes none on demand.
    Mock::given(method("GET"))
        .and(path_regex(r"/thumbnail/matrix\.org/anna$"))
        .respond_with(ResponseTemplate::new(400).set_body_json(json!({
            "errcode": "M_UNKNOWN",
            "error": "Cannot find any thumbnails for the requested media"
        })))
        .mount(server.server())
        .await;
    Mock::given(method("GET"))
        .and(path_regex(r"/download/matrix\.org/anna$"))
        .respond_with(ResponseTemplate::new(200).set_body_raw(b"anna's face".to_vec(), "image/jpeg"))
        .mount(server.server())
        .await;
    let folder = tempfile::tempdir().unwrap();
    let secrets = Arc::new(MemorySecrets::default());
    let account = MatrixSignIn::new(StoreFolder::new(folder.path()), secrets.clone())
        .sign_in_with_password(&server.uri(), "cheeky_monkey", "secret", "Lux (Test)")
        .await
        .unwrap();
    account.wait_for_first_sync().await;
    wait_for_room(&account).await;
    account.pause_sync().await;
    drop(account);

    let notifications = MatrixNotifications::open(&StoreFolder::new(folder.path()), secrets)
        .await
        .unwrap()
        .expect("the kept session");
    let pushed = tokio::time::timeout(
        Duration::from_secs(20),
        notifications.read(&"!anna:matrix.org".into(), &"$hello".into()),
    )
    .await
    .expect("the event in time")
    .unwrap();
    let PushedEvent::Shown(notification) = pushed else {
        panic!("not shown: {pushed:?}");
    };
    let pictures = notifications.pictures(&notification).await;
    assert_eq!(pictures.sender.as_deref(), Some(&b"anna's face"[..]));
}

#[tokio::test(flavor = "multi_thread")]
async fn the_running_app_hears_a_new_message_once() {
    let server = server().await;
    let now = u64::try_from(
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_millis(),
    )
    .unwrap();
    // sent a moment from now: after the app follows.
    mount_sync_with(&server, now + 2_000, &[], &[]).await;
    let (account, _folder) = signed_in(&server).await;
    let mut live = account.live_notifications();

    let notification = tokio::time::timeout(Duration::from_secs(10), live.next())
        .await
        .expect("the notification in time")
        .expect("the stream goes on");
    assert_eq!(notification.room.as_str(), "!anna:matrix.org");
    assert_eq!(notification.event.as_str(), "$hello");
    assert_eq!(notification.chat_name, "Anna");
    assert_eq!(notification.kind, PreviewKind::Text("hello there".to_owned()));
    assert!(notification.is_noisy);
    // each answer brings the message again: it notifies once.
    let again = tokio::time::timeout(Duration::from_secs(1), live.next()).await;
    assert!(again.is_err(), "{again:?}");
}
