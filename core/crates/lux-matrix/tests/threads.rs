//! Matrix threads against the SDK's mock server: the room's own timeline hides a thread's replies
//! behind its root's summary, the thread's timeline shows the root and its replies, what is sent
//! there goes as the thread's reply, a bridge's thread joins by its reaction (mautrix-discord's
//! "join thread"), and the room lists its threads.

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
use lux_core::ids::{EventId, RoomId, TimelineId};
use lux_core::ports::{ChatSending, ChatTimelines};
use lux_core::preview::PreviewKind;
use lux_core::timeline::TimelineMessage;
use lux_matrix::MatrixTimelines;
use matrix_sdk::ruma::{event_id, room_id, user_id};
use matrix_sdk::test_utils::mocks::{MatrixMockServer, RoomRelationsResponseTemplate};
use matrix_sdk::{Client, ThreadingSupport};
use matrix_sdk_test::JoinedRoomBuilder;
use matrix_sdk_test::event_factory::EventFactory;
use serde_json::json;

const ROOM: &str = "!chat:example.org";

/// A signed-in client of the mock server with Matrix threads, in a plain room.
async fn client(server: &MatrixMockServer) -> Client {
    let client = server
        .client_builder()
        .on_builder(|builder| {
            builder.with_threading_support(ThreadingSupport::Enabled {
                with_subscriptions: false,
            })
        })
        .build()
        .await;
    server.mock_room_state_encryption().plain().mount().await;
    client
}

fn room() -> TimelineId {
    TimelineId::from(RoomId::from(ROOM))
}

fn thread() -> TimelineId {
    TimelineId::thread(RoomId::from(ROOM), EventId::from("$root"))
}

/// The timeline's messages once they satisfy `done`.
async fn until(
    timelines: &MatrixTimelines,
    timeline: &TimelineId,
    done: impl Fn(&[Arc<TimelineMessage>]) -> bool,
) -> Vec<Arc<TimelineMessage>> {
    let mut batches = timelines.messages(timeline).await.unwrap();
    let mut messages = eyeball_im::Vector::new();
    tokio::time::timeout(Duration::from_secs(10), async {
        while let Some(batch) = batches.next().await {
            for diff in batch {
                diff.apply(&mut messages);
            }
            let now: Vec<_> = messages.iter().cloned().collect();
            if done(&now) {
                return now;
            }
        }
        panic!("the timeline closed");
    })
    .await
    .expect("the timeline did not get there in time")
}

/// The thread held and open, a page back of it asked for, as a thread's view does.
async fn opened(timelines: &MatrixTimelines) -> lux_core::ports::TimelineHold {
    let hold = timelines.hold(&thread());
    drop(timelines.messages(&thread()).await.unwrap());
    timelines.load_older(&thread(), 50).await.unwrap();
    hold
}

fn bodies(messages: &[Arc<TimelineMessage>]) -> Vec<&str> {
    messages.iter().map(|message| message.message.body.as_str()).collect()
}

/// The room: a root with two replies (a bridge's notice, its join reaction there, and alice's),
/// and a message after them.
async fn synced(server: &MatrixMockServer, client: &Client) {
    let factory = EventFactory::new().room(room_id!("!chat:example.org"));
    let alice = user_id!("@alice:example.org");
    let bot = user_id!("@discordbot:example.org");
    let latest = || {
        factory
            .text_msg("count me in")
            .sender(alice)
            .event_id(event_id!("$second"))
            .in_thread(event_id!("$root"), event_id!("$notice"))
    };
    server
        .sync_room(
            client,
            JoinedRoomBuilder::new(room_id!("!chat:example.org"))
                .add_timeline_event(
                    factory
                        .text_msg("trip on saturday?")
                        .sender(alice)
                        .event_id(event_id!("$root"))
                        .with_bundled_thread_summary(latest().into_raw(), 2, false),
                )
                .add_timeline_event(
                    factory
                        .notice(
                            "Thread created. React to this message with \"join thread\" to join the thread on Discord.",
                        )
                        .sender(bot)
                        .event_id(event_id!("$notice"))
                        .in_thread(event_id!("$root"), event_id!("$root")),
                )
                .add_timeline_event(factory.reaction(event_id!("$notice"), "join thread").sender(bot))
                .add_timeline_event(latest())
                .add_timeline_event(
                    factory
                        .text_msg("unrelated")
                        .sender(alice)
                        .event_id(event_id!("$after")),
                ),
        )
        .await;
}

#[tokio::test(flavor = "multi_thread")]
async fn the_rooms_own_timeline_hides_the_replies_and_sums_them_up_on_the_root() {
    let server = MatrixMockServer::new().await;
    let client = client(&server).await;
    synced(&server, &client).await;
    let timelines = MatrixTimelines::new(client, None);

    let page = until(&timelines, &room(), |page| {
        page.len() == 2 && page[0].thread.as_ref().is_some_and(|thread| thread.latest.is_some())
    })
    .await;
    assert_eq!(bodies(&page), ["trip on saturday?", "unrelated"]);
    let summary = page[0].thread.as_ref().unwrap();
    assert_eq!(summary.replies, 2);
    let latest = summary.latest.as_ref().unwrap();
    assert_eq!(latest.kind, PreviewKind::Text("count me in".to_owned()));
    assert_eq!(latest.sender.user.as_str(), "@alice:example.org");
    // the last to reply first; the bridge's bot among them, as the device holds its notice.
    assert_eq!(summary.participants[0].user.as_str(), "@alice:example.org");
    assert!(
        summary
            .participants
            .iter()
            .any(|participant| participant.user.as_str() == "@discordbot:example.org")
    );
    assert!(page[1].thread.is_none());
}

#[tokio::test(flavor = "multi_thread")]
async fn a_thread_shows_its_root_and_replies_and_sends_its_replies() {
    let server = MatrixMockServer::new().await;
    let client = client(&server).await;
    synced(&server, &client).await;
    let factory = EventFactory::new().room(room_id!("!chat:example.org"));
    server
        .mock_room_event()
        .match_event_id()
        .ok(factory
            .text_msg("trip on saturday?")
            .sender(user_id!("@alice:example.org"))
            .event_id(event_id!("$root"))
            .into())
        .mount()
        .await;
    server
        .mock_room_relations()
        .match_target_event(event_id!("$root").to_owned())
        .ok(RoomRelationsResponseTemplate::default())
        .mount()
        .await;
    // a reply goes in the thread, after its last reply.
    server
        .mock_room_send()
        .body_matches_partial_json(json!({
            "body": "see you there",
            "m.relates_to": { "rel_type": "m.thread", "event_id": "$root" },
        }))
        .ok(event_id!("$mine"))
        .mock_once()
        .mount()
        .await;
    let timelines = MatrixTimelines::new(client, None);
    let _hold = opened(&timelines).await;

    let page = until(&timelines, &thread(), |page| page.len() == 3).await;
    assert_eq!(bodies(&page)[0], "trip on saturday?");
    assert_eq!(bodies(&page)[2], "count me in");
    // the root in the thread is not summed up again; it is the same message, by its event.
    assert!(page[0].thread.is_none());
    let main = until(&timelines, &room(), |page| page.len() == 2).await;
    assert_eq!(main[0].message.id, page[0].message.id);

    timelines.send_text(&thread(), "see you there", None).await.unwrap();
    let page = until(&timelines, &thread(), |page| {
        page.last()
            .is_some_and(|message| message.message.body == "see you there" && message.event_id.is_some())
    })
    .await;
    assert!(page.last().unwrap().is_own);
    // the room's own timeline does not show it.
    let main = until(&timelines, &room(), |page| page.len() == 2).await;
    assert!(bodies(&main).iter().all(|body| *body != "see you there"));
}

#[tokio::test(flavor = "multi_thread")]
async fn a_thread_paged_back_to_its_root_is_at_its_start() {
    let server = MatrixMockServer::new().await;
    let client = client(&server).await;
    synced(&server, &client).await;
    let factory = EventFactory::new().room(room_id!("!chat:example.org"));
    server
        .mock_room_event()
        .match_event_id()
        .ok(factory
            .text_msg("trip on saturday?")
            .sender(user_id!("@alice:example.org"))
            .event_id(event_id!("$root"))
            .into())
        .mount()
        .await;
    // no older replies: the next page back is the root's.
    server
        .mock_room_relations()
        .match_target_event(event_id!("$root").to_owned())
        .ok(RoomRelationsResponseTemplate::default())
        .mount()
        .await;
    let timelines = MatrixTimelines::new(client, None);
    let _hold = timelines.hold(&thread());
    let _messages = timelines.messages(&thread()).await.unwrap();

    // the SDK marks no start item on a thread's timeline: its page back says it.
    assert!(timelines.load_older(&thread(), 50).await.unwrap());
}

#[tokio::test(flavor = "multi_thread")]
async fn reacting_join_thread_to_the_bridges_notice_joins_and_its_replies_come_in() {
    let server = MatrixMockServer::new().await;
    let client = client(&server).await;
    synced(&server, &client).await;
    let factory = EventFactory::new().room(room_id!("!chat:example.org"));
    server
        .mock_room_event()
        .match_event_id()
        .ok(factory
            .text_msg("trip on saturday?")
            .sender(user_id!("@alice:example.org"))
            .event_id(event_id!("$root"))
            .into())
        .mount()
        .await;
    server
        .mock_room_relations()
        .match_target_event(event_id!("$root").to_owned())
        .ok(RoomRelationsResponseTemplate::default())
        .mount()
        .await;
    // the reaction mautrix-discord takes as joining: its key, on its notice.
    server
        .mock_room_send()
        .body_matches_partial_json(json!({
            "m.relates_to": { "rel_type": "m.annotation", "event_id": "$notice", "key": "join thread" },
        }))
        .ok(event_id!("$joined"))
        .mock_once()
        .mount()
        .await;
    let timelines = MatrixTimelines::new(client.clone(), None);
    let _hold = opened(&timelines).await;
    let page = until(&timelines, &thread(), |page| page.len() == 3).await;
    let notice = &page[1];
    assert!(notice.message.body.starts_with("Thread created."));
    assert!(
        notice
            .reactions
            .iter()
            .any(|reaction| reaction.key == "join thread" && !reaction.is_mine)
    );

    timelines
        .toggle_reaction(&RoomId::from(ROOM), &notice.message.id, "join thread")
        .await
        .unwrap();
    until(&timelines, &thread(), |page| {
        page[1]
            .reactions
            .iter()
            .any(|reaction| reaction.key == "join thread" && reaction.is_mine && reaction.count == 2)
    })
    .await;

    // the bridge brings the Discord thread's messages as the thread's replies.
    server
        .sync_room(
            &client,
            JoinedRoomBuilder::new(room_id!("!chat:example.org")).add_timeline_event(
                factory
                    .text_msg("welcome aboard")
                    .sender(user_id!("@discord_bob:example.org"))
                    .event_id(event_id!("$welcome"))
                    .in_thread(event_id!("$root"), event_id!("$second")),
            ),
        )
        .await;
    let page = until(&timelines, &thread(), |page| page.len() == 4).await;
    assert_eq!(bodies(&page)[3], "welcome aboard");
    let main = until(&timelines, &room(), |page| {
        page[0].thread.as_ref().is_some_and(|thread| thread.replies == 3)
    })
    .await;
    assert_eq!(bodies(&main), ["trip on saturday?", "unrelated"]);
}

#[tokio::test(flavor = "multi_thread")]
async fn the_rooms_threads_list_a_page_at_a_time() {
    let server = MatrixMockServer::new().await;
    let client = client(&server).await;
    synced(&server, &client).await;
    let factory = EventFactory::new().room(room_id!("!chat:example.org"));
    let alice = user_id!("@alice:example.org");
    let latest = factory
        .text_msg("count me in")
        .sender(alice)
        .event_id(event_id!("$second"))
        .in_thread(event_id!("$root"), event_id!("$notice"))
        .into_raw();
    server
        .mock_room_threads()
        .ok(
            vec![
                factory
                    .text_msg("trip on saturday?")
                    .sender(alice)
                    .event_id(event_id!("$root"))
                    .with_bundled_thread_summary(latest, 2, false)
                    .into_raw(),
            ],
            Some("older".to_owned()),
        )
        .mock_once()
        .mount()
        .await;
    let timelines = MatrixTimelines::new(client, None);
    let page = timelines.threads(&RoomId::from(ROOM), None).await.unwrap();
    assert_eq!(page.next.as_deref(), Some("older"));
    let [listed] = page.threads.as_slice() else {
        panic!("one thread: {page:?}");
    };
    assert_eq!(listed.root.as_str(), "$root");
    assert_eq!(listed.kind, PreviewKind::Text("trip on saturday?".to_owned()));
    assert_eq!(listed.summary.replies, 2);
    assert_eq!(
        listed.summary.latest.as_ref().map(|latest| latest.kind.clone()),
        Some(PreviewKind::Text("count me in".to_owned()))
    );
}
