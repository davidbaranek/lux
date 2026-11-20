//! Timelines opened around an old message (a jump) against the SDK's mock server: one context
//! request instead of paging the live timeline back, paging both ways from there, the thread of a
//! reply, and the server's refusals.

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

use eyeball_im::Vector;
use futures_util::StreamExt;
use lux_core::ids::{EventId, RoomId, TimelineId};
use lux_core::ports::{BackendError, ChatTimelines, DiffStream};
use lux_core::timeline::TimelineMessage;
use lux_matrix::MatrixTimelines;
use matrix_sdk::Client;
use matrix_sdk::ruma::{event_id, room_id, user_id};
use matrix_sdk::test_utils::mocks::{MatrixMockServer, RoomContextResponseTemplate, RoomMessagesResponseTemplate};
use matrix_sdk_test::JoinedRoomBuilder;
use matrix_sdk_test::event_factory::EventFactory;
use serde_json::json;

const ROOM: &str = "!chat:example.org";

/// A signed-in client of the mock server, in a plain room whose live timeline holds one message.
async fn client(server: &MatrixMockServer) -> Client {
    let client = server.client_builder().build().await;
    server.mock_room_state_encryption().plain().mount().await;
    let factory = EventFactory::new().room(room_id!("!chat:example.org"));
    server
        .sync_room(
            &client,
            JoinedRoomBuilder::new(room_id!("!chat:example.org")).add_timeline_event(
                factory
                    .text_msg("today")
                    .sender(user_id!("@alice:example.org"))
                    .event_id(event_id!("$today")),
            ),
        )
        .await;
    client
}

fn live() -> TimelineId {
    TimelineId::from(RoomId::from(ROOM))
}

fn around(event: &str) -> TimelineId {
    live().around(EventId::from(event))
}

/// The server's context of `$old`: two messages before it, two after, and tokens both ways.
async fn mount_context(server: &MatrixMockServer) {
    let factory = EventFactory::new().room(room_id!("!chat:example.org"));
    let alice = user_id!("@alice:example.org");
    server
        .mock_room_event_context()
        .room(room_id!("!chat:example.org"))
        .match_event_id()
        .ok(RoomContextResponseTemplate::new(
            factory
                .text_msg("old")
                .sender(alice)
                .event_id(event_id!("$old"))
                .into_event(),
        )
        // newest first, as the server gives them.
        .events_before(vec![
            factory
                .text_msg("before old")
                .sender(alice)
                .event_id(event_id!("$b1"))
                .into_event(),
            factory
                .text_msg("long before")
                .sender(alice)
                .event_id(event_id!("$b2"))
                .into_event(),
        ])
        .events_after(vec![
            factory
                .text_msg("after old")
                .sender(alice)
                .event_id(event_id!("$a1"))
                .into_event(),
            factory
                .text_msg("long after")
                .sender(alice)
                .event_id(event_id!("$a2"))
                .into_event(),
        ])
        .start("back")
        .end("forward"))
        .mount()
        .await;
}

/// The list's batches, and the list as they leave it.
struct Watched {
    batches: DiffStream<Arc<TimelineMessage>>,
    messages: Vector<Arc<TimelineMessage>>,
}

impl Watched {
    async fn open(timelines: &MatrixTimelines, timeline: &TimelineId) -> Result<Self, BackendError> {
        let mut watched = Self {
            batches: timelines.messages(timeline).await?,
            messages: Vector::new(),
        };
        watched.next().await;
        Ok(watched)
    }

    async fn next(&mut self) {
        for diff in self.batches.next().await.unwrap_or_default() {
            diff.apply(&mut self.messages);
        }
    }

    /// Waits for the batches until the list satisfies `done`.
    async fn until(&mut self, done: impl Fn(&[&str]) -> bool) {
        tokio::time::timeout(Duration::from_secs(10), async {
            while !done(&self.bodies()) {
                self.next().await;
            }
        })
        .await
        .expect("the list did not get there in time");
    }

    fn bodies(&self) -> Vec<&str> {
        self.messages
            .iter()
            .map(|message| message.message.body.as_str())
            .collect()
    }
}

/// How many context requests the server has had.
async fn context_requests(server: &MatrixMockServer) -> usize {
    server
        .server()
        .received_requests()
        .await
        .unwrap_or_default()
        .iter()
        .filter(|request| request.url.path().contains("/context/"))
        .count()
}

#[tokio::test(flavor = "multi_thread")]
async fn a_jump_opens_the_old_message_among_its_neighbours_from_one_request() {
    let server = MatrixMockServer::new().await;
    let client = client(&server).await;
    mount_context(&server).await;
    // a jump never pages the live timeline back.
    server
        .mock_room_messages()
        .ok(RoomMessagesResponseTemplate::default())
        .never()
        .mount()
        .await;
    let timelines = MatrixTimelines::new(client, None);

    let opened = Watched::open(&timelines, &around("$old")).await.unwrap();
    assert_eq!(
        opened.bodies(),
        ["long before", "before old", "old", "after old", "long after"]
    );
    let focused = timelines.focused(&around("$old")).await.unwrap();
    let old = opened
        .messages
        .iter()
        .find(|message| message.message.body == "old")
        .unwrap();
    assert_eq!(focused.message, old.message.id);
    assert_eq!(focused.thread, None);
    assert_eq!(context_requests(&server).await, 1);

    // the live timeline is another: its messages never share an id with the jump's.
    let live = Watched::open(&timelines, &live()).await.unwrap();
    assert_eq!(live.bodies(), ["today"]);
    assert!(live.messages.iter().all(|message| {
        opened
            .messages
            .iter()
            .all(|other| other.message.id != message.message.id)
    }));
}

#[tokio::test(flavor = "multi_thread")]
async fn a_jump_pages_back_to_the_start_and_forward_to_the_newest() {
    let server = MatrixMockServer::new().await;
    let client = client(&server).await;
    mount_context(&server).await;
    let factory = EventFactory::new().room(room_id!("!chat:example.org"));
    let alice = user_id!("@alice:example.org");
    server
        .mock_room_messages()
        .match_from("back")
        .ok(RoomMessagesResponseTemplate::default().events(vec![
            factory.text_msg("first").sender(alice).event_id(event_id!("$first")),
        ]))
        .mount()
        .await;
    server
        .mock_room_messages()
        .match_from("forward")
        .ok(RoomMessagesResponseTemplate::default().events(vec![
            factory.text_msg("today").sender(alice).event_id(event_id!("$today")),
        ]))
        .mount()
        .await;
    let timelines = MatrixTimelines::new(client, None);
    let mut opened = Watched::open(&timelines, &around("$old")).await.unwrap();

    // the page's own answer says it reached the start.
    assert!(timelines.load_older(&around("$old"), 50).await.unwrap());
    opened.until(|bodies| bodies.first() == Some(&"first")).await;

    assert!(timelines.load_newer(&around("$old"), 50).await.unwrap());
    opened.until(|bodies| bodies.last() == Some(&"today")).await;
    // the live timeline, once open, is at the newest already.
    let _live = timelines.messages(&live()).await.unwrap();
    assert!(timelines.load_newer(&live(), 50).await.unwrap());
}

#[tokio::test(flavor = "multi_thread")]
async fn a_jump_to_a_thread_reply_shows_its_thread_around_it() {
    let server = MatrixMockServer::new().await;
    let client = client(&server).await;
    let factory = EventFactory::new().room(room_id!("!chat:example.org"));
    let alice = user_id!("@alice:example.org");
    server
        .mock_room_event_context()
        .room(room_id!("!chat:example.org"))
        .match_event_id()
        .ok(RoomContextResponseTemplate::new(
            factory
                .text_msg("reply")
                .sender(alice)
                .in_thread(event_id!("$root"), event_id!("$root"))
                .event_id(event_id!("$reply"))
                .into_event(),
        )
        .events_before(vec![
            factory
                .text_msg("unrelated")
                .sender(alice)
                .event_id(event_id!("$other"))
                .into_event(),
            factory
                .text_msg("root")
                .sender(alice)
                .event_id(event_id!("$root"))
                .into_event(),
        ]))
        .mount()
        .await;
    let timelines = MatrixTimelines::new(client, None);

    let opened = Watched::open(&timelines, &around("$reply")).await.unwrap();
    assert_eq!(opened.bodies(), ["root", "reply"]);
    let focused = timelines.focused(&around("$reply")).await.unwrap();
    assert_eq!(focused.thread, Some(EventId::from("$root")));
}

#[tokio::test(flavor = "multi_thread")]
async fn a_jump_to_a_message_the_server_has_not_or_will_not_show_says_so() {
    let server = MatrixMockServer::new().await;
    let client = client(&server).await;
    server
        .mock_room_event_context()
        .room(room_id!("!chat:example.org"))
        .respond_with_code_and_json(404, json!({ "errcode": "M_NOT_FOUND", "error": "Event not found." }))
        .mock_once()
        .mount()
        .await;
    server
        .mock_room_event_context()
        .room(room_id!("!chat:example.org"))
        .respond_with_code_and_json(403, json!({ "errcode": "M_FORBIDDEN", "error": "Not allowed." }))
        .mount()
        .await;
    let timelines = MatrixTimelines::new(client, None);

    assert!(matches!(
        timelines.messages(&around("$gone")).await,
        Err(BackendError::UnknownMessage)
    ));
    assert!(matches!(
        timelines.messages(&around("$hidden")).await,
        Err(BackendError::NotAllowed)
    ));
}
