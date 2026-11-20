//! The chats' timelines against the SDK's mock server: reading a room (formatting, replies,
//! reactions, receipts), paging back, sending (text, reply, edit, reaction, attachment), and the
//! account's own read receipt.

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
use lux_core::ids::{MessageId, MessageRef, RoomId};
use lux_core::message::SendState;
use lux_core::ports::{ChatMedia, ChatSending, ChatTimelines};
use lux_core::preview::PreviewKind;
use lux_core::timeline::{Media, OutgoingAttachment, OutgoingKind, Receipt, StyleKind, TimelineMessage};
use lux_matrix::MatrixTimelines;
use matrix_sdk::Client;
use matrix_sdk::ruma::api::client::receipt::create_receipt::v3::ReceiptType;
use matrix_sdk::ruma::events::receipt::{ReceiptThread, ReceiptType as EventReceiptType};
use matrix_sdk::ruma::events::room::message::{
    RedactedRoomMessageEventContent, RoomMessageEventContentWithoutRelation,
};
use matrix_sdk::ruma::{event_id, mxc_uri, room_id, user_id};
use matrix_sdk::test_utils::mocks::{MatrixMockServer, RoomMessagesResponseTemplate};
use matrix_sdk_test::JoinedRoomBuilder;
use matrix_sdk_test::event_factory::EventFactory;

const ROOM: &str = "!chat:example.org";

/// A signed-in client of the mock server, in a plain (unencrypted) room.
async fn client(server: &MatrixMockServer) -> Client {
    let client = server.client_builder().build().await;
    server.mock_room_state_encryption().plain().mount().await;
    client
}

fn room() -> RoomId {
    RoomId::from(ROOM)
}

/// The room's messages now: the first batch of its live list is all of them.
async fn snapshot(timelines: &MatrixTimelines) -> Vec<Arc<TimelineMessage>> {
    let mut batches = timelines.messages(&room().into()).await.unwrap();
    let mut messages = eyeball_im::Vector::new();
    for diff in batches.next().await.unwrap_or_default() {
        diff.apply(&mut messages);
    }
    messages.into_iter().collect()
}

/// Waits until the room's messages satisfy `done`; the messages then.
async fn page_until(
    timelines: &MatrixTimelines,
    done: impl Fn(&[Arc<TimelineMessage>]) -> bool,
) -> Vec<Arc<TimelineMessage>> {
    let mut changes = timelines.changes();
    tokio::time::timeout(Duration::from_secs(10), async {
        loop {
            let page = snapshot(timelines).await;
            if done(&page) {
                return page;
            }
            changes.next().await;
        }
    })
    .await
    .expect("the page did not get there in time")
}

fn body_is(body: &'static str) -> impl Fn(&[Arc<TimelineMessage>]) -> bool {
    move |page| page.iter().any(|message| message.message.body == body)
}

#[tokio::test(flavor = "multi_thread")]
async fn a_room_reads_with_its_formatting_replies_reactions_and_readers() {
    let server = MatrixMockServer::new().await;
    let client = client(&server).await;
    let factory = EventFactory::new().room(room_id!("!chat:example.org"));
    let alice = user_id!("@alice:example.org");
    let bob = user_id!("@bob:example.org");
    server
        .sync_room(
            &client,
            JoinedRoomBuilder::new(room_id!("!chat:example.org"))
                .add_timeline_event(factory.text_msg("hello").sender(alice).event_id(event_id!("$hello")))
                .add_timeline_event(
                    factory
                        .text_html("**bold** move", "<b>bold</b> move")
                        .sender(alice)
                        .event_id(event_id!("$bold")),
                )
                .add_timeline_event(
                    factory
                        .text_msg("hi back")
                        .sender(user_id!("@example:localhost"))
                        .reply_to(event_id!("$hello"))
                        .event_id(event_id!("$reply")),
                )
                .add_timeline_event(factory.reaction(event_id!("$bold"), "👍").sender(bob))
                .add_receipt(
                    factory
                        .read_receipts()
                        .add(
                            event_id!("$reply"),
                            bob,
                            EventReceiptType::Read,
                            ReceiptThread::Unthreaded,
                        )
                        .into_event(),
                ),
        )
        .await;
    let timelines = MatrixTimelines::new(client, None);

    let page = page_until(&timelines, |page| {
        page.len() == 3 && page[2].reply.as_ref().is_some_and(|quote| quote.kind.is_some())
    })
    .await;
    assert_eq!(page[0].message.body, "hello");
    assert_eq!(page[0].sender_name, "alice");
    assert!(!page[0].is_own);

    let bold = &page[1];
    assert_eq!(bold.message.body, "bold move");
    assert_eq!(bold.styles[0].kind, StyleKind::Bold);
    assert_eq!(bold.reactions.len(), 1);
    assert_eq!(bold.reactions[0].key, "👍");
    assert!(!bold.reactions[0].is_mine);
    assert!(bold.message.has_reactions);

    let reply = &page[2];
    assert!(reply.is_own);
    assert!(reply.message.is_reply);
    let quote = reply.reply.as_ref().unwrap();
    assert_eq!(quote.event_id.as_str(), "$hello");
    assert_eq!(quote.kind, Some(PreviewKind::Text("hello".to_owned())));
    assert_eq!(reply.readers.len(), 1);
    assert_eq!(reply.readers[0].user.as_str(), "@bob:example.org");

    // the presentation runs over the page as it is.
    let rows = lux_core::message::present(&page, &jiff::tz::TimeZone::UTC);
    assert_eq!(rows.len(), 3);
}

#[tokio::test(flavor = "multi_thread")]
async fn paging_back_shows_older_messages_and_reaches_the_start() {
    let server = MatrixMockServer::new().await;
    let client = client(&server).await;
    let factory = EventFactory::new().room(room_id!("!chat:example.org"));
    let alice = user_id!("@alice:example.org");
    server
        .sync_room(
            &client,
            JoinedRoomBuilder::new(room_id!("!chat:example.org"))
                .add_timeline_event(factory.text_msg("newest").sender(alice).event_id(event_id!("$new")))
                .set_timeline_limited()
                .set_timeline_prev_batch("back"),
        )
        .await;
    // the room's older messages: one page, then its start.
    server
        .mock_room_messages()
        .match_from("back")
        .ok(RoomMessagesResponseTemplate::default().events(vec![
            factory.text_msg("older").sender(alice).event_id(event_id!("$older")),
            factory.text_msg("oldest").sender(alice).event_id(event_id!("$oldest")),
        ]))
        .mount()
        .await;
    let timelines = MatrixTimelines::new(client, None);

    // opened ahead of time, a page back from the server comes with it.
    timelines.prefetch(&room().into()).await.unwrap();
    let page = page_until(&timelines, |page| page.len() == 3).await;
    assert_eq!(
        page.iter()
            .map(|message| message.message.body.as_str())
            .collect::<Vec<_>>(),
        ["oldest", "older", "newest"]
    );
    // the next page's answer says it is at the start: the SDK's own word, the only one.
    assert!(timelines.load_older(&room().into(), 20).await.unwrap());
}

#[tokio::test(flavor = "multi_thread")]
async fn a_sent_text_shows_at_once_then_as_sent() {
    let server = MatrixMockServer::new().await;
    let client = client(&server).await;
    let factory = EventFactory::new().room(room_id!("!chat:example.org"));
    server
        .sync_room(
            &client,
            JoinedRoomBuilder::new(room_id!("!chat:example.org")).add_timeline_event(
                factory
                    .text_msg("question")
                    .sender(user_id!("@alice:example.org"))
                    .event_id(event_id!("$question")),
            ),
        )
        .await;
    server
        .mock_room_send()
        .ok(event_id!("$answer"))
        .mock_once()
        .mount()
        .await;
    let timelines = MatrixTimelines::new(client, None);
    let page = page_until(&timelines, body_is("question")).await;
    let question = MessageRef::Local(page[0].message.id.clone());

    timelines
        .send_text(&room().into(), &"**sure**".into(), Some(&question))
        .await
        .unwrap();
    let page = page_until(&timelines, |page| {
        page.iter()
            .any(|message| message.message.body == "sure" && message.message.state == SendState::Sent)
    })
    .await;
    let answer = page.iter().find(|message| message.message.body == "sure").unwrap();
    assert!(answer.is_own);
    assert_eq!(
        answer.event_id.as_ref().map(lux_core::ids::EventId::as_str),
        Some("$answer")
    );
    assert_eq!(
        answer.reply.as_ref().map(|quote| quote.event_id.as_str()),
        Some("$question")
    );
    // Markdown went as formatting.
    assert_eq!(answer.styles[0].kind, StyleKind::Bold);
}

#[tokio::test(flavor = "multi_thread")]
async fn a_send_that_failed_for_a_moment_goes_on_retry_with_those_queued_after_it() {
    let server = MatrixMockServer::new().await;
    let client = client(&server).await;
    server
        .sync_room(&client, JoinedRoomBuilder::new(room_id!("!chat:example.org")))
        .await;
    // the server fails for a moment (the queue's own three tries), then takes everything.
    server.mock_room_send().error500().up_to_n_times(3).mount().await;
    server.mock_room_send().ok(event_id!("$sent")).mount().await;
    let timelines = MatrixTimelines::new(client, None);
    snapshot(&timelines).await;

    timelines
        .send_text(&room().into(), &"first".into(), None)
        .await
        .unwrap();
    let page = page_until(&timelines, |page| {
        page.iter()
            .any(|message| message.message.body == "first" && message.message.state == SendState::Failed)
    })
    .await;
    let first = page.iter().find(|message| message.message.body == "first").unwrap();
    // the failure turned the room's queue off: what comes next waits.
    timelines
        .send_text(&room().into(), &"second".into(), None)
        .await
        .unwrap();

    timelines.retry(&room(), &first.message.id).await.unwrap();
    page_until(&timelines, |page| {
        ["first", "second"].iter().all(|body| {
            page.iter()
                .any(|message| message.message.body == *body && message.message.state == SendState::Sent)
        })
    })
    .await;
}

#[tokio::test(flavor = "multi_thread")]
async fn an_own_message_is_edited_and_reacted_to() {
    let server = MatrixMockServer::new().await;
    let client = client(&server).await;
    let factory = EventFactory::new().room(room_id!("!chat:example.org"));
    server
        .sync_room(
            &client,
            JoinedRoomBuilder::new(room_id!("!chat:example.org")).add_timeline_event(
                factory
                    .text_msg("tpyo")
                    .sender(user_id!("@example:localhost"))
                    .event_id(event_id!("$mine")),
            ),
        )
        .await;
    server.mock_room_send().ok(event_id!("$change")).mount().await;
    let timelines = MatrixTimelines::new(client, None);
    let page = page_until(&timelines, body_is("tpyo")).await;
    let mine = page[0].message.id.clone();
    assert!(page[0].is_editable);

    timelines.edit(&room(), &mine, &"typo".into()).await.unwrap();
    let page = page_until(&timelines, body_is("typo")).await;
    assert!(page[0].message.is_edited);

    timelines.toggle_reaction(&room(), &mine, "❤️").await.unwrap();
    let page = page_until(&timelines, |page| !page[0].reactions.is_empty()).await;
    assert!(page[0].reactions[0].is_mine);
    assert_eq!(page[0].reactions[0].key, "❤️");

    // another's message is not the account's to edit.
    assert!(
        timelines
            .edit(&room(), &MessageId::from("$nope"), &"x".into())
            .await
            .is_err()
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn a_photo_is_queued_with_its_local_echo_and_uploads() {
    let server = MatrixMockServer::new().await;
    let client = client(&server).await;
    server.mock_authenticated_media_config().ok_default().mount().await;
    server.sync_joined_room(&client, room_id!("!chat:example.org")).await;
    server
        .mock_upload()
        .ok(mxc_uri!("mxc://example.org/photo"))
        .mount()
        .await;
    server.mock_room_send().ok(event_id!("$photo")).mount().await;
    let timelines = MatrixTimelines::new(client, None);
    timelines.prefetch(&room().into()).await.unwrap();

    let folder = tempfile::tempdir().unwrap();
    let file = folder.path().join("trip.jpg");
    std::fs::write(&file, b"not really a jpeg").unwrap();
    let attachment = OutgoingAttachment {
        file,
        name: "trip.jpg".to_owned(),
        mimetype: "image/jpeg".to_owned(),
        size: 17,
        kind: OutgoingKind::Photo { width: 4, height: 3 },
        thumbnail: None,
    };
    let states: Vec<SendState> = timelines
        .send_attachment(&room().into(), &attachment, Some("Trip"), None)
        .await
        .unwrap()
        .collect()
        .await;
    // its media's share as it goes, then sent, the last.
    assert_eq!(states.last(), Some(&SendState::Sent));
    assert!(
        states[..states.len() - 1]
            .iter()
            .all(|state| matches!(state, SendState::Sending { upload: Some(_) }))
    );

    let page = page_until(&timelines, |page| {
        page.iter()
            .any(|message| message.message.body == "Trip" && message.message.state == SendState::Sent)
    })
    .await;
    let photo = page.iter().find(|message| message.message.body == "Trip").unwrap();
    let Some(Media::Photo { picture, .. }) = &photo.media else {
        panic!("not a photo");
    };
    assert_eq!((picture.width, picture.height), (4, 3));
}

#[tokio::test(flavor = "multi_thread")]
async fn an_upload_the_server_refuses_ends_failed() {
    let server = MatrixMockServer::new().await;
    let client = client(&server).await;
    server.mock_authenticated_media_config().ok_default().mount().await;
    server.sync_joined_room(&client, room_id!("!chat:example.org")).await;
    server.mock_upload().error_too_large().mount().await;
    let timelines = MatrixTimelines::new(client, None);
    timelines.prefetch(&room().into()).await.unwrap();

    let folder = tempfile::tempdir().unwrap();
    let file = folder.path().join("notes.txt");
    std::fs::write(&file, b"far too large").unwrap();
    let attachment = OutgoingAttachment {
        file,
        name: "notes.txt".to_owned(),
        mimetype: "text/plain".to_owned(),
        size: 13,
        kind: OutgoingKind::File,
        thumbnail: None,
    };
    let states: Vec<SendState> = timelines
        .send_attachment(&room().into(), &attachment, None, None)
        .await
        .unwrap()
        .collect()
        .await;
    assert_eq!(states.last(), Some(&SendState::Failed));
}

#[tokio::test(flavor = "multi_thread")]
async fn reading_sends_a_private_receipt_unless_asked_for_a_public_one() {
    let server = MatrixMockServer::new().await;
    let client = client(&server).await;
    let factory = EventFactory::new().room(room_id!("!chat:example.org"));
    server
        .sync_room(
            &client,
            JoinedRoomBuilder::new(room_id!("!chat:example.org")).add_timeline_event(
                factory
                    .text_msg("unread")
                    .sender(user_id!("@alice:example.org"))
                    .event_id(event_id!("$unread")),
            ),
        )
        .await;
    server
        .mock_send_receipt(ReceiptType::ReadPrivate)
        .ok()
        .expect(1)
        .named("private receipt")
        .mount()
        .await;
    server
        .mock_send_receipt(ReceiptType::Read)
        .ok()
        .expect(0)
        .named("public receipt")
        .mount()
        .await;
    let timelines = MatrixTimelines::new(client, None);
    page_until(&timelines, body_is("unread")).await;
    timelines.mark_read(&room().into(), Receipt::Private).await.unwrap();
    server.server().verify().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn the_first_unread_message_is_found_once_a_page_back_holds_the_receipt() {
    let server = MatrixMockServer::new().await;
    let client = client(&server).await;
    let factory = EventFactory::new().room(room_id!("!chat:example.org"));
    let alice = user_id!("@alice:example.org");
    let own = user_id!("@example:localhost");
    // a first screen of unread messages; the receipt is on an older one the timeline lacks.
    let mut joined = JoinedRoomBuilder::new(room_id!("!chat:example.org"));
    for number in 0..60 {
        joined = joined.add_timeline_event(
            factory
                .text_msg(format!("new {number}"))
                .sender(alice)
                .server_ts(2_000 + number),
        );
    }
    let joined = joined
        .add_receipt(
            factory
                .read_receipts()
                .add(
                    event_id!("$read"),
                    own,
                    EventReceiptType::Read,
                    ReceiptThread::Unthreaded,
                )
                .into_event(),
        )
        .set_timeline_limited()
        .set_timeline_prev_batch("back");
    server.sync_room(&client, joined).await;
    server
        .mock_room_messages()
        .match_from("back")
        .ok(RoomMessagesResponseTemplate::default()
            .events(vec![
                factory
                    .text_msg("first unread")
                    .sender(alice)
                    .event_id(event_id!("$unread"))
                    .server_ts(1_500),
                factory
                    .text_msg("read")
                    .sender(alice)
                    .event_id(event_id!("$read"))
                    .server_ts(1_000),
            ])
            .end_token("older"))
        .mount()
        .await;
    let timelines = MatrixTimelines::new(client, None);
    let held = snapshot(&timelines).await;

    // the receipt is older than all the timeline holds: older messages may be unread too.
    let unread = timelines.first_unread(&room().into()).await.unwrap();
    assert!(!unread.complete);
    assert_eq!(unread.first, Some(held[0].message.id.clone()));
    // the thread pages back (nothing pages by itself), and asks again.
    timelines.load_older(&room().into(), 50).await.unwrap();
    page_until(&timelines, body_is("first unread")).await;
    let unread = timelines.first_unread(&room().into()).await.unwrap();
    assert!(unread.complete);
    let first = unread.first.expect("an unread message");
    let page = snapshot(&timelines).await;
    let shown = page
        .iter()
        .find(|message| message.message.id == first)
        .expect("in the timeline");
    assert_eq!(shown.message.body, "first unread");
}

#[tokio::test(flavor = "multi_thread")]
async fn a_newer_receipt_on_an_event_no_row_shows_reads_what_came_before_it() {
    let server = MatrixMockServer::new().await;
    let client = client(&server).await;
    let factory = EventFactory::new().room(room_id!("!chat:example.org"));
    let alice = user_id!("@alice:example.org");
    let own = user_id!("@example:localhost");
    // the private receipt is on an old message; the public one on a later reaction, no row.
    let joined = JoinedRoomBuilder::new(room_id!("!chat:example.org"))
        .add_timeline_event(
            factory
                .text_msg("old")
                .sender(alice)
                .event_id(event_id!("$old"))
                .server_ts(1_000),
        )
        .add_timeline_event(
            factory
                .text_msg("newer")
                .sender(alice)
                .event_id(event_id!("$newer"))
                .server_ts(2_000),
        )
        .add_timeline_event(
            factory
                .reaction(event_id!("$newer"), "👍")
                .sender(own)
                .event_id(event_id!("$liked"))
                .server_ts(3_000),
        )
        .add_receipt(
            factory
                .read_receipts()
                .add(
                    event_id!("$old"),
                    own,
                    EventReceiptType::ReadPrivate,
                    ReceiptThread::Unthreaded,
                )
                .add(
                    event_id!("$liked"),
                    own,
                    EventReceiptType::Read,
                    ReceiptThread::Unthreaded,
                )
                .into_event(),
        );
    server.sync_room(&client, joined).await;
    let timelines = MatrixTimelines::new(client, None);
    snapshot(&timelines).await;

    assert_eq!(timelines.first_unread(&room().into()).await.unwrap().first, None);
}

#[tokio::test(flavor = "multi_thread")]
async fn the_index_history_holds_each_messages_newest_text_and_the_deleted_ones() {
    let server = MatrixMockServer::new().await;
    let client = client(&server).await;
    server
        .sync_room(&client, JoinedRoomBuilder::new(room_id!("!chat:example.org")))
        .await;
    let factory = EventFactory::new()
        .room(room_id!("!chat:example.org"))
        .sender(user_id!("@alice:example.org"));
    let at = |second: u64| 1_700_000_000_000 + second * 1_000;
    // newest first, as the server pages back; then the room's start.
    server
        .mock_room_messages()
        .ok(RoomMessagesResponseTemplate::default().events(vec![
            factory
                .redaction(event_id!("$gone"))
                .event_id(event_id!("$redaction"))
                .server_ts(at(5))
                .into_raw_timeline(),
            factory
                .text_msg("* hi everyone")
                .edit(
                    event_id!("$hi"),
                    RoomMessageEventContentWithoutRelation::text_plain("hi everyone"),
                )
                .event_id(event_id!("$edit2"))
                .server_ts(at(4))
                .into_raw_timeline(),
            factory
                .text_msg("* hi there")
                .edit(
                    event_id!("$hi"),
                    RoomMessageEventContentWithoutRelation::text_plain("hi there"),
                )
                .event_id(event_id!("$edit1"))
                .server_ts(at(3))
                .into_raw_timeline(),
            factory
                .redacted(user_id!("@alice:example.org"), RedactedRoomMessageEventContent::new())
                .event_id(event_id!("$gone"))
                .server_ts(at(2))
                .into_raw_timeline(),
            factory
                .text_msg("hi")
                .event_id(event_id!("$hi"))
                .server_ts(at(1))
                .into_raw_timeline(),
        ]))
        .mount()
        .await;
    let timelines = MatrixTimelines::new(client, None);

    let history = timelines
        .index_history(&room(), std::time::SystemTime::UNIX_EPOCH, None, 3)
        .await
        .unwrap();
    assert!(history.reached_start);
    let [message] = history.messages.as_slice() else {
        panic!("not one message: {:?}", history.messages);
    };
    assert_eq!(message.event_id.as_str(), "$hi");
    assert_eq!(message.body, "hi everyone");
    // dated as the message, not as its edit.
    assert_eq!(
        message.date,
        std::time::SystemTime::UNIX_EPOCH + Duration::from_millis(at(1))
    );
    assert!(history.removed.iter().all(|event| event.as_str() == "$gone"));
    assert!(!history.removed.is_empty());
}

#[tokio::test(flavor = "multi_thread")]
async fn the_index_history_holds_photos_with_their_captions_and_one_loads_by_its_event() {
    use matrix_sdk::ruma::events::room::message::{ImageMessageEventContent, MessageType, RoomMessageEventContent};

    let server = MatrixMockServer::new().await;
    let client = client(&server).await;
    server
        .sync_room(&client, JoinedRoomBuilder::new(room_id!("!chat:example.org")))
        .await;
    let factory = EventFactory::new()
        .room(room_id!("!chat:example.org"))
        .sender(user_id!("@alice:example.org"));
    let mut captioned = ImageMessageEventContent::plain(
        "Our dog on the beach".to_owned(),
        mxc_uri!("mxc://example.org/dog").to_owned(),
    );
    captioned.filename = Some("dog.jpg".to_owned());
    let dog = || {
        factory
            .event(RoomMessageEventContent::new(MessageType::Image(captioned.clone())))
            .event_id(event_id!("$dog"))
            .server_ts(1_700_000_002_000_u64)
    };
    server
        .mock_room_messages()
        .ok(RoomMessagesResponseTemplate::default().events(vec![
            dog().into_raw_timeline(),
            factory
                .image(
                    "IMG_0042.jpg".to_owned(),
                    mxc_uri!("mxc://example.org/plain").to_owned(),
                )
                .event_id(event_id!("$plain"))
                .server_ts(1_700_000_001_000_u64)
                .into_raw_timeline(),
        ]))
        .mock_once()
        .mount()
        .await;
    server
        .mock_room_messages()
        .ok(RoomMessagesResponseTemplate::default())
        .mount()
        .await;
    server
        .mock_room_event()
        .match_event_id()
        .ok(dog().into_event())
        .mount()
        .await;
    server.mock_authed_media_download().ok_image().mount().await;
    let timelines = MatrixTimelines::new(client, None);

    let history = timelines
        .index_history(&room(), std::time::SystemTime::UNIX_EPOCH, None, 3)
        .await
        .unwrap();
    assert!(history.messages.is_empty());
    let photos: Vec<(&str, &str)> = history
        .images
        .iter()
        .map(|image| (image.event_id.as_str(), image.caption.as_str()))
        .collect();
    // a photo's file name is no caption.
    assert_eq!(photos, [("$dog", "Our dog on the beach"), ("$plain", "")]);

    let folder = tempfile::tempdir().unwrap();
    let file = timelines
        .shared_file(&room(), &"$dog".into(), folder.path())
        .await
        .unwrap();
    assert_eq!(std::fs::read(&file).unwrap(), b"binaryjpegfullimagedata");
}

#[tokio::test(flavor = "multi_thread")]
async fn a_photo_loads_once_into_one_file_even_when_asked_twice_at_once() {
    let server = MatrixMockServer::new().await;
    let client = client(&server).await;
    let factory = EventFactory::new().room(room_id!("!chat:example.org"));
    server
        .sync_room(
            &client,
            JoinedRoomBuilder::new(room_id!("!chat:example.org")).add_timeline_event(
                factory
                    .image("beach.jpg".to_owned(), mxc_uri!("mxc://example.org/beach").to_owned())
                    .sender(user_id!("@alice:example.org"))
                    .event_id(event_id!("$beach")),
            ),
        )
        .await;
    server.mock_media_download().ok_image().mount().await;
    server.mock_authed_media_download().ok_image().mount().await;
    let timelines = MatrixTimelines::new(client, None);
    let page = page_until(&timelines, |page| !page.is_empty()).await;
    let photo = page[0].message.id.clone();
    let folder = tempfile::tempdir().unwrap();

    let room = room();
    let (one, other) = tokio::join!(
        timelines.media_file(&room, &photo, folder.path()),
        timelines.media_file(&room, &photo, folder.path()),
    );
    let (one, other) = (one.unwrap(), other.unwrap());
    assert_eq!(one, other);
    assert_eq!(one.file_name().unwrap(), "beach.jpg");
    assert_eq!(std::fs::read(&one).unwrap(), b"binaryjpegfullimagedata");
    // nothing half-written is left beside it.
    assert_eq!(std::fs::read_dir(one.parent().unwrap()).unwrap().count(), 1);
}

#[tokio::test(flavor = "multi_thread")]
async fn pictures_load_once_per_url_and_size_and_without_a_thumbnail_as_they_are() {
    use lux_core::ids::MediaId;
    use lux_core::timeline::ImageSource;
    use wiremock::matchers::{method, path_regex, query_param};
    use wiremock::{Mock, ResponseTemplate};

    let server = MatrixMockServer::new().await;
    let client = client(&server).await;
    let factory = EventFactory::new().room(room_id!("!chat:example.org"));
    server
        .sync_room(
            &client,
            JoinedRoomBuilder::new(room_id!("!chat:example.org")).add_timeline_event(
                factory
                    .image("beach.jpg".to_owned(), mxc_uri!("mxc://example.org/beach").to_owned())
                    .sender(user_id!("@alice:example.org"))
                    .event_id(event_id!("$beach")),
            ),
        )
        .await;
    // the beach's thumbnails at each size, once each; the bridge's picture has none.
    for (side, body) in [("160", "small beach"), ("800", "large beach")] {
        Mock::given(method("GET"))
            .and(path_regex("/media/thumbnail/example.org/beach$"))
            .and(query_param("width", side))
            .respond_with(
                ResponseTemplate::new(200)
                    .set_body_bytes(body)
                    .insert_header("content-type", "image/jpeg"),
            )
            .expect(1)
            .mount(server.server())
            .await;
    }
    Mock::given(method("GET"))
        .and(path_regex("/media/thumbnail/example.org/bridged$"))
        .respond_with(ResponseTemplate::new(404).set_body_json(serde_json::json!({
            "errcode": "M_NOT_FOUND", "error": "no thumbnail"
        })))
        .mount(server.server())
        .await;
    Mock::given(method("GET"))
        .and(path_regex("/media/download/example.org/bridged"))
        .respond_with(
            ResponseTemplate::new(200)
                .set_body_bytes("whole picture")
                .insert_header("content-type", "image/png"),
        )
        .expect(1)
        .mount(server.server())
        .await;
    let timelines = MatrixTimelines::new(client, None);
    let page = page_until(&timelines, |page| !page.is_empty()).await;
    let folder = tempfile::tempdir().unwrap();
    let photo = ImageSource::Photo {
        room: room(),
        message: page[0].message.id.clone(),
    };
    let person = ImageSource::Person(MediaId::from("mxc://example.org/beach"));
    let bridged = ImageSource::Person(MediaId::from("mxc://example.org/bridged"));

    for _ in 0..2 {
        let large = timelines.image_file(&photo, folder.path()).await.unwrap().unwrap();
        let small = timelines.image_file(&person, folder.path()).await.unwrap().unwrap();
        let whole = timelines.image_file(&bridged, folder.path()).await.unwrap().unwrap();
        // one url, two sizes: two files.
        assert_ne!(large, small);
        assert_eq!(std::fs::read(&large).unwrap(), b"large beach");
        assert_eq!(std::fs::read(&small).unwrap(), b"small beach");
        assert_eq!(std::fs::read(&whole).unwrap(), b"whole picture");
        assert!(small.file_name().unwrap().to_str().unwrap().ends_with("-160x160"));
    }
    // the files, and nothing half-written beside them.
    assert_eq!(std::fs::read_dir(folder.path()).unwrap().count(), 3);
}

/// The messages of `room` once it holds `count` of them.
async fn messages_of(timelines: &MatrixTimelines, room: &RoomId, count: usize) -> Vec<Arc<TimelineMessage>> {
    tokio::time::timeout(Duration::from_secs(10), async {
        let mut batches = timelines.messages(&room.into()).await.unwrap();
        let mut messages = eyeball_im::Vector::new();
        while let Some(batch) = batches.next().await {
            for diff in batch {
                diff.apply(&mut messages);
            }
            if messages.len() == count {
                return messages.into_iter().collect();
            }
        }
        panic!("the room's messages ended");
    })
    .await
    .expect("the room's messages did not come in time")
}

#[tokio::test(flavor = "multi_thread")]
async fn messages_of_different_rooms_never_share_an_id() {
    let server = MatrixMockServer::new().await;
    let client = client(&server).await;
    let alice = user_id!("@alice:example.org");
    let other = room_id!("!other:example.org");
    // two rooms alike, as a merged chat shows them side by side.
    for (room, prefix) in [(room_id!("!chat:example.org"), "chat"), (other, "other")] {
        let factory = EventFactory::new().room(room);
        server
            .sync_room(
                &client,
                JoinedRoomBuilder::new(room)
                    .add_timeline_event(
                        factory
                            .text_msg("one")
                            .sender(alice)
                            .event_id(&matrix_sdk::ruma::OwnedEventId::try_from(format!("${prefix}-one")).unwrap()),
                    )
                    .add_timeline_event(
                        factory
                            .text_msg("two")
                            .sender(alice)
                            .event_id(&matrix_sdk::ruma::OwnedEventId::try_from(format!("${prefix}-two")).unwrap()),
                    ),
            )
            .await;
    }
    let timelines = MatrixTimelines::new(client, None);

    let first = messages_of(&timelines, &room(), 2).await;
    let second = messages_of(&timelines, &RoomId::from(other.as_str()), 2).await;
    let ids: std::collections::HashSet<&MessageId> =
        first.iter().chain(&second).map(|message| &message.message.id).collect();
    assert_eq!(ids.len(), 4, "the rooms' messages share ids: {ids:?}");
}

#[tokio::test(flavor = "multi_thread")]
async fn the_index_history_reads_on_from_where_its_pages_ran_out() {
    let server = MatrixMockServer::new().await;
    let client = client(&server).await;
    server
        .sync_room(&client, JoinedRoomBuilder::new(room_id!("!chat:example.org")))
        .await;
    let factory = EventFactory::new()
        .room(room_id!("!chat:example.org"))
        .sender(user_id!("@alice:example.org"));
    server
        .mock_room_messages()
        .match_from("older")
        .ok(RoomMessagesResponseTemplate::default().events(vec![
            factory
                .text_msg("long ago")
                .event_id(event_id!("$old"))
                .server_ts(1_700_000_001_000_u64)
                .into_raw_timeline(),
        ]))
        .mount()
        .await;
    server
        .mock_room_messages()
        .ok(RoomMessagesResponseTemplate::default()
            .events(vec![
                factory
                    .text_msg("lately")
                    .event_id(event_id!("$new"))
                    .server_ts(1_700_000_002_000_u64)
                    .into_raw_timeline(),
            ])
            .end_token("older"))
        .mount()
        .await;
    let timelines = MatrixTimelines::new(client, None);

    // one page: the newest, and where to read on.
    let first = timelines
        .index_history(&room(), std::time::SystemTime::UNIX_EPOCH, None, 1)
        .await
        .unwrap();
    let bodies = |history: &lux_core::timeline::IndexHistory| -> Vec<String> {
        history.messages.iter().map(|message| message.body.clone()).collect()
    };
    assert_eq!(bodies(&first), ["lately"]);
    assert!(!first.reached_start);
    assert_eq!(first.older.as_deref(), Some("older"));
    assert!(!first.reached_since);

    // on from there: the older message, to the start, and nothing more to read.
    let next = timelines
        .index_history(&room(), std::time::SystemTime::UNIX_EPOCH, first.older, 1)
        .await
        .unwrap();
    assert_eq!(bodies(&next), ["long ago"]);
    assert!(next.older.is_none());
}

/// A chat whose first screen is full, then `quiet` pages of state events only (rows the SDK shows,
/// no message), then a page with the message `$target` and the room's start.
async fn chat_with_quiet_pages(server: &MatrixMockServer, quiet: usize) -> MatrixTimelines {
    // as many as the opening pages back for (`lux_matrix`'s first screen).
    const FIRST_SCREEN: usize = 60;
    let client = client(server).await;
    let factory = EventFactory::new().room(room_id!("!chat:example.org"));
    let alice = user_id!("@alice:example.org");
    let id = |id: String| matrix_sdk::ruma::OwnedEventId::try_from(id).unwrap();
    server
        .sync_room(
            &client,
            JoinedRoomBuilder::new(room_id!("!chat:example.org"))
                .add_timeline_event(factory.text_msg("newest").sender(alice).event_id(event_id!("$new")))
                .set_timeline_limited()
                .set_timeline_prev_batch("screen"),
        )
        .await;
    let screen = (0..FIRST_SCREEN)
        .map(|n| {
            factory
                .text_msg(format!("screen {n}"))
                .sender(alice)
                .event_id(&id(format!("$screen{n}")))
        })
        .collect::<Vec<_>>();
    server
        .mock_room_messages()
        .match_from("screen")
        .ok(RoomMessagesResponseTemplate::default()
            .events(screen)
            .end_token("quiet0"))
        .mount()
        .await;
    for page in 0..quiet {
        let topics = (0..5)
            .map(|n| {
                factory
                    .room_topic(format!("topic {page}.{n}"))
                    .sender(alice)
                    .event_id(&id(format!("$topic{page}.{n}")))
            })
            .collect::<Vec<_>>();
        server
            .mock_room_messages()
            .match_from(&format!("quiet{page}"))
            .ok(RoomMessagesResponseTemplate::default()
                .events(topics)
                .end_token(format!("quiet{}", page + 1)))
            .mount()
            .await;
    }
    server
        .mock_room_messages()
        .match_from(&format!("quiet{quiet}"))
        .ok(RoomMessagesResponseTemplate::default().events(vec![
            factory.text_msg("target").sender(alice).event_id(event_id!("$target")),
        ]))
        .mount()
        .await;
    let timelines = MatrixTimelines::new(client, None);
    timelines.prefetch(&room().into()).await.unwrap();
    page_until(&timelines, |page| page.len() > FIRST_SCREEN).await;
    timelines
}

/// Pages without messages in a row: before, each made a page back wait a second for messages it
/// never brought.
const QUIET_PAGES: usize = 5;

/// Far less than the second each quiet page used to cost, far more than mapping takes.
const AT_ONCE: Duration = Duration::from_secs(2);

#[tokio::test(flavor = "multi_thread")]
async fn paging_back_over_pages_without_messages_does_not_wait_on_them() {
    let server = MatrixMockServer::new().await;
    let timelines = chat_with_quiet_pages(&server, QUIET_PAGES).await;

    // more than the room has: back to its start, over the quiet pages, one page an answer.
    let started = std::time::Instant::now();
    let mut pages = 0;
    while !timelines.load_older(&room().into(), 1000).await.unwrap() {
        pages += 1;
        assert!(pages <= QUIET_PAGES + 1, "paged past the start");
    }

    let took = started.elapsed();
    assert!(took < AT_ONCE, "paging back took {took:?}");
    page_until(&timelines, body_is("target")).await;
    assert!(
        snapshot(&timelines)
            .await
            .iter()
            .any(|message| message.message.body == "target")
    );
}

/// A chat the device held `one` and `two` of, then a limited sync with only `six`: `three` to
/// `five` came while the app was away (as notifications), and the server holds them behind the
/// sync's `prev_batch`.
async fn chat_with_a_gap(server: &MatrixMockServer, client: &Client, open_before: bool) -> MatrixTimelines {
    let factory = EventFactory::new().room(room_id!("!chat:example.org"));
    let alice = user_id!("@alice:example.org");
    let id = |id: &str| matrix_sdk::ruma::OwnedEventId::try_from(id).unwrap();
    let text = |body: &str| factory.text_msg(body).sender(alice).event_id(&id(&format!("${body}")));
    server
        .sync_room(
            client,
            JoinedRoomBuilder::new(room_id!("!chat:example.org"))
                .add_timeline_event(text("one"))
                .add_timeline_event(text("two")),
        )
        .await;
    server
        .mock_room_messages()
        .match_from("gap")
        .ok(RoomMessagesResponseTemplate::default().events(vec![
            text("five"),
            text("four"),
            text("three"),
            text("two"),
            text("one"),
        ]))
        .mount()
        .await;
    let timelines = MatrixTimelines::new(client.clone(), None);
    if open_before {
        timelines.prefetch(&room().into()).await.unwrap();
        page_until(&timelines, |page| page.len() == 2).await;
    }
    server
        .sync_room(
            client,
            JoinedRoomBuilder::new(room_id!("!chat:example.org"))
                .add_timeline_event(text("six"))
                .set_timeline_limited()
                .set_timeline_prev_batch("gap"),
        )
        .await;
    timelines
}

fn bodies(page: &[Arc<TimelineMessage>]) -> Vec<&str> {
    page.iter().map(|message| message.message.body.as_str()).collect()
}

/// Every message, the gap's among them, in order.
const NO_GAP: [&str; 6] = ["one", "two", "three", "four", "five", "six"];

#[tokio::test(flavor = "multi_thread")]
async fn a_chat_opened_after_a_limited_sync_shows_what_came_in_its_gap() {
    let server = MatrixMockServer::new().await;
    let client = client(&server).await;
    let timelines = chat_with_a_gap(&server, &client, false).await;

    timelines.prefetch(&room().into()).await.unwrap();
    let page = page_until(&timelines, |page| page.len() == NO_GAP.len()).await;
    assert_eq!(bodies(&page), NO_GAP);
}

#[tokio::test(flavor = "multi_thread")]
async fn an_open_chat_reset_by_a_limited_sync_pages_back_into_its_gap_when_asked() {
    let server = MatrixMockServer::new().await;
    let client = client(&server).await;
    // open before: the limited sync resets it to its newest message, and nothing pages by itself.
    let timelines = chat_with_a_gap(&server, &client, true).await;
    page_until(&timelines, |page| bodies(page) == ["six"]).await;
    let before = snapshot(&timelines).await;

    timelines.load_older(&room().into(), 50).await.unwrap();
    let page = page_until(&timelines, |page| page.len() == NO_GAP.len()).await;
    assert_eq!(bodies(&page), NO_GAP);
    // a message's id is its event's: the same before the reset and after.
    assert!(page.iter().any(|message| message.message.id == before[0].message.id));
    assert_eq!(before[0].message.id.as_str(), "!chat:example.org/$six");
}

#[tokio::test(flavor = "multi_thread")]
async fn a_sent_message_and_those_before_it_keep_their_ids_through_its_echo_and_a_reset() {
    let server = MatrixMockServer::new().await;
    let client = client(&server).await;
    let factory = EventFactory::new().room(room_id!("!chat:example.org"));
    let alice = user_id!("@alice:example.org");
    let id = |id: &str| matrix_sdk::ruma::OwnedEventId::try_from(id).unwrap();
    let text = |body: &str| factory.text_msg(body).sender(alice).event_id(&id(&format!("${body}")));
    server
        .sync_room(
            &client,
            JoinedRoomBuilder::new(room_id!("!chat:example.org"))
                .add_timeline_event(text("one"))
                .add_timeline_event(text("two")),
        )
        .await;
    server
        .mock_room_send()
        .ok(event_id!("$hello"))
        .mock_once()
        .mount()
        .await;
    let timelines = MatrixTimelines::new(client.clone(), None);
    page_until(&timelines, |page| page.len() == 2).await;
    timelines
        .send_text(&room().into(), &"hello".into(), None)
        .await
        .unwrap();
    let before = page_until(&timelines, |page| {
        page.iter()
            .any(|message| message.message.body == "hello" && message.message.state == SendState::Sent)
    })
    .await;
    let ids_before: Vec<(String, MessageId)> = before
        .iter()
        .map(|message| (message.message.body.clone(), message.message.id.clone()))
        .collect();

    // the sync brings the sent message's remote echo and Alice's answer, limited: the timeline is
    // reset to them, its `prev_batch` before three messages the device never had. Only the
    // thread pages back for them: one request, asked for.
    server
        .mock_room_messages()
        .match_from("gap")
        .ok(RoomMessagesResponseTemplate::default().events(vec![
            text("five"),
            text("four"),
            text("three"),
            text("two"),
            text("one"),
        ]))
        .expect(1)
        .mount()
        .await;
    server
        .sync_room(
            &client,
            JoinedRoomBuilder::new(room_id!("!chat:example.org"))
                .add_timeline_event(
                    factory
                        .text_msg("hello")
                        .sender(client.user_id().unwrap())
                        .event_id(&id("$hello")),
                )
                .add_timeline_event(text("six"))
                .set_timeline_limited()
                .set_timeline_prev_batch("gap"),
        )
        .await;
    page_until(&timelines, |page| bodies(page) == ["hello", "six"]).await;
    timelines.load_older(&room().into(), 50).await.unwrap();
    let page = page_until(&timelines, |page| page.len() == 7).await;
    assert_eq!(bodies(&page), ["one", "two", "three", "four", "five", "hello", "six"]);
    for (body, id) in &ids_before {
        assert!(
            page.iter()
                .any(|message| message.message.body == *body && message.message.id == *id),
            "{body} changed its id"
        );
    }

    // a message that stayed is acted on by the id it kept.
    let two = ids_before.iter().find(|(body, _)| body == "two").unwrap().1.clone();
    server.mock_room_send().ok(event_id!("$reaction")).mount().await;
    timelines.toggle_reaction(&room(), &two, "👍").await.unwrap();
    page_until(&timelines, |page| {
        page.iter()
            .any(|message| message.message.id == two && !message.reactions.is_empty())
    })
    .await;
    server.server().verify().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn only_reading_a_timeline_opens_it() {
    let server = MatrixMockServer::new().await;
    let client = client(&server).await;
    server.sync_joined_room(&client, room_id!("!chat:example.org")).await;
    let timelines = MatrixTimelines::new(client, None);

    // a draft is the room's, and opens nothing; nor does sending, through the room's send queue.
    timelines
        .save_draft(&room().into(), &"later".into(), None)
        .await
        .unwrap();
    assert_eq!(
        timelines.draft(&room().into()).await.unwrap().map(|draft| draft.text),
        Some("later".into())
    );
    assert!(matches!(
        timelines.load_older(&room().into(), 50).await,
        Err(lux_core::ports::BackendError::UnknownChat(_))
    ));
    // its messages open it: what is done to it now goes.
    snapshot(&timelines).await;
    assert!(timelines.first_unread(&room().into()).await.is_ok());
}

#[tokio::test(flavor = "multi_thread")]
async fn an_upload_goes_on_once_its_chat_is_closed_and_its_timeline_let_go() {
    let server = MatrixMockServer::new().await;
    let client = client(&server).await;
    server.mock_authenticated_media_config().ok_default().mount().await;
    let others: Vec<String> = (0..8).map(|n| format!("!other{n}:example.org")).collect();
    for room in std::iter::once(ROOM.to_owned()).chain(others.iter().cloned()) {
        let room = matrix_sdk::ruma::OwnedRoomId::try_from(room).unwrap();
        server.sync_joined_room(&client, &room).await;
    }
    // a large file: its upload takes a while.
    wiremock::Mock::given(wiremock::matchers::method("POST"))
        .and(wiremock::matchers::path_regex(r"/media/.*upload"))
        .respond_with(
            wiremock::ResponseTemplate::new(200)
                .set_body_json(serde_json::json!({ "content_uri": "mxc://example.org/trip" }))
                .set_delay(Duration::from_millis(500)),
        )
        .mount(server.server())
        .await;
    server.mock_room_send().ok(event_id!("$trip")).expect(1).mount().await;
    let timelines = MatrixTimelines::new(client, None);
    let hold = timelines.hold(&room().into());
    snapshot(&timelines).await;

    let folder = tempfile::tempdir().unwrap();
    let file = folder.path().join("trip.pdf");
    std::fs::write(&file, b"a long report").unwrap();
    let attachment = OutgoingAttachment {
        file,
        name: "trip.pdf".to_owned(),
        mimetype: "application/pdf".to_owned(),
        size: 13,
        kind: OutgoingKind::File,
        thumbnail: None,
    };
    let states = timelines
        .send_attachment(&room().into(), &attachment, Some("Trip"), None)
        .await
        .unwrap();
    // the chat closes, and eight others open after it: its timeline is let go.
    drop(hold);
    for other in &others {
        let other = RoomId::from(other.as_str());
        let _hold = timelines.hold(&(&other).into());
        messages_of(&timelines, &other, 0).await;
    }

    // the room's send queue goes on with it: uploaded, and its message sent to the room, once.
    let states: Vec<SendState> = tokio::time::timeout(Duration::from_secs(10), states.collect())
        .await
        .unwrap();
    assert_eq!(states.last(), Some(&SendState::Sent));
    server.server().verify().await;
}
