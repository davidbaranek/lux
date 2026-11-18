//! What the share extension sends: the session the app keeps, opened without its sync, sends the
//! user's text and files to a chat the app synced, and says whether the server took them all.

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
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Duration;

use lux_core::ids::RoomId;
use lux_core::ports::{BackendError, ChatAccount, SecretStore, SignIn};
use lux_core::timeline::{OutgoingAttachment, OutgoingKind};
use lux_matrix::{MatrixShare, MatrixSignIn, StoreFolder};
use matrix_sdk::test_utils::mocks::MatrixMockServer;
use serde_json::{Value, json};
use wiremock::matchers::{body_string, method, path, path_regex};
use wiremock::{Mock, Request, Respond, ResponseTemplate};

mod support;
use support::{MemorySecrets, Requests, server};

const ROOM: &str = "!anna:matrix.org";

/// The share extension's account, over the session and the store the app left after it synced
/// [`ROOM`]; the folder holding them.
async fn share(server: &MatrixMockServer) -> (MatrixShare, tempfile::TempDir) {
    Mock::given(method("POST"))
        .and(path("/_matrix/client/unstable/org.matrix.simplified_msc3575/sync"))
        .respond_with(
            ResponseTemplate::new(200)
                .set_body_json(json!({
                    "pos": "1",
                    "lists": { "all_rooms": { "count": 1 } },
                    "rooms": { ROOM: { "name": "Anna", "initial": true, "joined_count": 2 } }
                }))
                // the sync long-polls: not every few milliseconds.
                .set_delay(Duration::from_millis(200)),
        )
        .mount(server.server())
        .await;
    server.mock_room_state_encryption().plain().mount().await;
    server.mock_authenticated_media_config().ok_default().mount().await;
    let folder = tempfile::tempdir().unwrap();
    let secrets: Arc<dyn SecretStore> = Arc::new(MemorySecrets::default());
    let app = MatrixSignIn::new(StoreFolder::new(folder.path()), Arc::clone(&secrets))
        .sign_in_with_password(&server.uri(), "cheeky_monkey", "secret", "Lux (Test)")
        .await
        .unwrap();
    tokio::time::timeout(Duration::from_secs(10), app.wait_for_first_sync())
        .await
        .unwrap();
    // the app goes to the background, its stores closed, as the user shares from another app.
    app.pause_sync().await;
    drop(app);
    let share = MatrixShare::open(&StoreFolder::new(folder.path()), secrets)
        .await
        .unwrap()
        .unwrap();
    (share, folder)
}

/// What `sharing` ends with (boxed: the send's future is large); the test fails when it does not
/// end in time.
async fn within<T>(sharing: impl Future<Output = T>) -> T {
    tokio::time::timeout(Duration::from_secs(10), sharing)
        .await
        .expect("the share did not end in time")
}

/// A file named `name` holding its own name, in `folder`.
fn file(folder: &tempfile::TempDir, name: &str) -> OutgoingAttachment {
    let file = folder.path().join(name);
    std::fs::write(&file, name).unwrap();
    OutgoingAttachment {
        file,
        name: name.to_owned(),
        mimetype: "text/plain".to_owned(),
        size: name.len() as u64,
        kind: OutgoingKind::File,
        thumbnail: None,
    }
}

/// A sent message, as the server had it: its type, its text and its file's name, if any.
#[derive(Debug, PartialEq)]
struct Sent {
    msgtype: String,
    body: String,
    filename: Option<String>,
}

impl Sent {
    fn text(body: &str) -> Self {
        Self {
            msgtype: "m.text".to_owned(),
            body: body.to_owned(),
            filename: None,
        }
    }

    fn file(name: &str, caption: Option<&str>) -> Self {
        Self {
            msgtype: "m.file".to_owned(),
            body: caption.unwrap_or(name).to_owned(),
            filename: caption.map(|_| name.to_owned()),
        }
    }
}

/// The messages the server had, in the order they came.
async fn sent(server: &MatrixMockServer) -> Vec<Sent> {
    server
        .server()
        .received_requests()
        .await
        .unwrap()
        .iter()
        .filter(|request| request.method.as_str() == "PUT" && request.url.path().contains("/send/m.room.message/"))
        .map(|request| {
            let content: Value = serde_json::from_slice(&request.body).unwrap();
            Sent {
                msgtype: content["msgtype"].as_str().unwrap().to_owned(),
                body: content["body"].as_str().unwrap().to_owned(),
                filename: content["filename"].as_str().map(str::to_owned),
            }
        })
        .collect()
}

/// Answers each request with a new id, `<prefix>-<n>`, under `key`.
struct Numbered {
    key: &'static str,
    prefix: &'static str,
    count: AtomicUsize,
}

impl Respond for Numbered {
    fn respond(&self, _: &Request) -> ResponseTemplate {
        let n = self.count.fetch_add(1, Ordering::SeqCst);
        ResponseTemplate::new(200).set_body_json(json!({ self.key: format!("{}-{n}", self.prefix) }))
    }
}

fn numbered(key: &'static str, prefix: &'static str) -> Numbered {
    Numbered {
        key,
        prefix,
        count: AtomicUsize::new(0),
    }
}

/// The server takes every file and message, each its own id, as a real one does.
async fn takes_everything(server: &MatrixMockServer) {
    Mock::given(method("POST"))
        .and(path("/_matrix/media/v3/upload"))
        .respond_with(numbered("content_uri", "mxc://example.org/file"))
        .mount(server.server())
        .await;
    Mock::given(method("PUT"))
        .and(path_regex("/send/"))
        .respond_with(numbered("event_id", "$event"))
        .mount(server.server())
        .await;
}

#[tokio::test(flavor = "multi_thread")]
async fn one_shared_file_carries_the_text_as_its_caption() {
    let server = server().await;
    takes_everything(&server).await;
    let (share, folder) = share(&server).await;

    within(Box::pin(share.send(
        &RoomId::from(ROOM),
        "  for you  ",
        &[file(&folder, "notes.txt")],
    )))
    .await
    .unwrap();

    assert_eq!(sent(&server).await, [Sent::file("notes.txt", Some("for you"))]);
}

#[tokio::test(flavor = "multi_thread")]
async fn with_several_shared_files_the_text_goes_first_on_its_own_and_no_file_has_a_caption() {
    let server = server().await;
    takes_everything(&server).await;
    let (share, folder) = share(&server).await;

    within(Box::pin(share.send(
        &RoomId::from(ROOM),
        "for you",
        &[file(&folder, "one.txt"), file(&folder, "two.txt")],
    )))
    .await
    .unwrap();

    assert_eq!(
        sent(&server).await,
        [
            Sent::text("for you"),
            Sent::file("one.txt", None),
            Sent::file("two.txt", None)
        ]
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn a_file_the_server_refuses_fails_the_share_and_keeps_what_went_before_sent_and_what_comes_after_unsent() {
    let server = server().await;
    let uploads = Requests::default();
    Mock::given(method("POST"))
        .and(path("/_matrix/media/v3/upload"))
        .and(body_string("two.txt"))
        .respond_with(uploads.answering(ResponseTemplate::new(413).set_body_json(json!({
            "errcode": "M_TOO_LARGE", "error": "Too large"
        }))))
        .with_priority(1)
        .mount(server.server())
        .await;
    Mock::given(method("POST"))
        .and(path("/_matrix/media/v3/upload"))
        .respond_with(
            uploads
                .answering(ResponseTemplate::new(200).set_body_json(json!({ "content_uri": "mxc://example.org/one" }))),
        )
        .mount(server.server())
        .await;
    Mock::given(method("PUT"))
        .and(path_regex("/send/"))
        .respond_with(numbered("event_id", "$event"))
        .mount(server.server())
        .await;
    let (share, folder) = share(&server).await;

    let refused = within(Box::pin(share.send(
        &RoomId::from(ROOM),
        "for you",
        &[
            file(&folder, "one.txt"),
            file(&folder, "two.txt"),
            file(&folder, "three.txt"),
        ],
    )))
    .await
    .unwrap_err();

    assert!(matches!(refused, BackendError::Server { .. }), "{refused:?}");
    assert_eq!(
        sent(&server).await,
        [Sent::text("for you"), Sent::file("one.txt", None)]
    );
    // the refused file holds back the ones after it.
    assert_eq!(uploads.counts().values().sum::<usize>(), 2);
    assert!(
        !uploads.more_within(Duration::from_secs(1)).await,
        "a file after the refused one went"
    );
}
