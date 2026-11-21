//! Mentions against the SDK's mock server: a message with pills goes with the spec's intentional
//! mentions (its body the names, its HTML `matrix.to` links, `m.mentions` the members), a reply
//! mentions the sender it answers, an edit notifies only who is new; a pill coming in shows the
//! member's name now, a bridged ghost's too, and a message mentioning the account is set apart.

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
use lux_core::ids::{MessageRef, RoomId, UserId};
use lux_core::mention::{ComposedText, Mention, MentionTarget};
use lux_core::message::SendState;
use lux_core::ports::{ChatSending, ChatTimelines};
use lux_core::timeline::{OutgoingAttachment, OutgoingKind, StyleKind, TimelineMessage};
use lux_matrix::MatrixTimelines;
use matrix_sdk::Client;
use matrix_sdk::ruma::events::Mentions;
use matrix_sdk::ruma::{event_id, mxc_uri, owned_user_id, room_id, user_id};
use matrix_sdk::test_utils::mocks::MatrixMockServer;
use matrix_sdk_test::JoinedRoomBuilder;
use matrix_sdk_test::event_factory::EventFactory;
use serde_json::{Value, json};

const ROOM: &str = "!chat:example.org";

async fn client(server: &MatrixMockServer) -> Client {
    let client = server.client_builder().build().await;
    server.mock_room_state_encryption().plain().mount().await;
    client
}

fn room() -> RoomId {
    RoomId::from(ROOM)
}

async fn snapshot(timelines: &MatrixTimelines) -> Vec<Arc<TimelineMessage>> {
    let mut batches = timelines.messages(&room().into()).await.unwrap();
    let mut messages = eyeball_im::Vector::new();
    for diff in batches.next().await.unwrap_or_default() {
        diff.apply(&mut messages);
    }
    messages.into_iter().collect()
}

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

fn pill(user: &str, start: usize, end: usize) -> Mention {
    Mention {
        target: MentionTarget::User(UserId::from(user)),
        range: start..end,
    }
}

/// The bodies of the messages the server was sent, in order.
async fn sent(server: &MatrixMockServer) -> Vec<Value> {
    server
        .server()
        .received_requests()
        .await
        .unwrap()
        .iter()
        .filter(|request| request.url.path().contains("/send/m.room.message/"))
        .map(|request| serde_json::from_slice(&request.body).unwrap())
        .collect()
}

#[tokio::test(flavor = "multi_thread")]
async fn a_reply_with_pills_mentions_its_members_and_the_sender_it_answers_never_the_account() {
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
    server.mock_room_send().ok(event_id!("$answer")).mount().await;
    let timelines = MatrixTimelines::new(client, None);
    let page = page_until(&timelines, |page| !page.is_empty()).await;
    let question = MessageRef::Local(page[0].message.id.clone());

    // Petr is a bridged ghost; the account's own pill notifies nobody.
    let text = ComposedText {
        text: "ask Petr and Me, **now**".to_owned(),
        mentions: vec![
            pill("@discord_123:example.org", 4, 8),
            pill("@example:localhost", 13, 15),
        ],
    };
    timelines
        .send_text(&room().into(), &text, Some(&question))
        .await
        .unwrap();
    page_until(&timelines, |page| {
        page.iter()
            .any(|message| message.is_own && message.message.state == SendState::Sent)
    })
    .await;

    let body = sent(&server).await.pop().expect("the reply");
    assert_eq!(body["body"], "ask Petr and Me, **now**");
    assert_eq!(body["format"], "org.matrix.custom.html");
    assert_eq!(
        body["formatted_body"],
        "ask <a href=\"https://matrix.to/#/@discord_123:example.org\">Petr</a> and \
         <a href=\"https://matrix.to/#/@example:localhost\">Me</a>, <strong>now</strong>"
    );
    assert_eq!(
        body["m.mentions"],
        json!({ "user_ids": ["@alice:example.org", "@discord_123:example.org"] })
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn a_message_without_pills_mentions_nobody_and_room_mentions_the_room() {
    let server = MatrixMockServer::new().await;
    let client = client(&server).await;
    server
        .sync_room(&client, JoinedRoomBuilder::new(room_id!("!chat:example.org")))
        .await;
    server.mock_room_send().ok(event_id!("$one")).mock_once().mount().await;
    server.mock_room_send().ok(event_id!("$two")).mock_once().mount().await;
    let timelines = MatrixTimelines::new(client, None);
    // the room's timeline shows the sends' echoes.
    snapshot(&timelines).await;

    timelines
        .send_text(&room().into(), &"hi Anna".into(), None)
        .await
        .unwrap();
    let room_mention = ComposedText {
        text: "@room lunch".to_owned(),
        mentions: vec![Mention {
            target: MentionTarget::Room,
            range: 0..5,
        }],
    };
    timelines.send_text(&room().into(), &room_mention, None).await.unwrap();
    page_until(&timelines, |page| {
        page.iter()
            .filter(|message| message.is_own && message.message.state == SendState::Sent)
            .count()
            == 2
    })
    .await;

    let bodies = sent(&server).await;
    // an empty `m.mentions`: the legacy rules do not notify an Anna by her name in the text.
    assert_eq!(bodies[0]["m.mentions"], json!({}));
    assert!(bodies[0].get("formatted_body").is_none());
    assert_eq!(bodies[1]["m.mentions"], json!({ "room": true }));
    assert_eq!(bodies[1]["body"], "@room lunch");
}

#[tokio::test(flavor = "multi_thread")]
async fn an_edit_keeps_its_pills_and_notifies_only_who_it_adds() {
    let server = MatrixMockServer::new().await;
    let client = client(&server).await;
    let factory = EventFactory::new().room(room_id!("!chat:example.org"));
    let own = user_id!("@example:localhost");
    server
        .sync_room(
            &client,
            JoinedRoomBuilder::new(room_id!("!chat:example.org")).add_timeline_event(
                factory
                    .text_html(
                        "hi Anna",
                        "hi <a href=\"https://matrix.to/#/@anna:example.org\">Anna</a>",
                    )
                    .mentions(Mentions::with_user_ids([owned_user_id!("@anna:example.org")]))
                    .sender(own)
                    .event_id(event_id!("$mine")),
            ),
        )
        .await;
    server.mock_room_send().ok(event_id!("$edit")).mount().await;
    let timelines = MatrixTimelines::new(client, None);
    let page = page_until(&timelines, |page| !page.is_empty()).await;
    let mine = page[0].message.id.clone();

    let text = ComposedText {
        text: "hi Anna and Bob".to_owned(),
        mentions: vec![pill("@anna:example.org", 3, 7), pill("@bob:example.org", 12, 15)],
    };
    timelines.edit(&room(), &mine, &text).await.unwrap();
    page_until(&timelines, |page| {
        page.iter().any(|message| message.message.body == "hi Anna and Bob")
    })
    .await;

    let body = sent(&server).await.pop().unwrap();
    assert_eq!(body["m.mentions"], json!({ "user_ids": ["@bob:example.org"] }));
    assert_eq!(
        body["m.new_content"]["m.mentions"],
        json!({ "user_ids": ["@anna:example.org", "@bob:example.org"] })
    );
    assert_eq!(body["m.new_content"]["body"], "hi Anna and Bob");
}

#[tokio::test(flavor = "multi_thread")]
async fn a_pill_shows_the_members_name_now_and_a_mention_of_the_account_is_set_apart() {
    let server = MatrixMockServer::new().await;
    let client = client(&server).await;
    let factory = EventFactory::new().room(room_id!("!chat:example.org"));
    let alice = user_id!("@alice:example.org");
    let ghost = user_id!("@discord_123:example.org");
    server
        .sync_room(
            &client,
            JoinedRoomBuilder::new(room_id!("!chat:example.org"))
                .add_state_event(factory.member(ghost).display_name("Petr (Discord)"))
                .add_state_event(factory.member(user_id!("@example:localhost")).display_name("Example"))
                .add_timeline_event(
                    factory
                        .text_html(
                            "thanks petr",
                            "thanks <a href=\"https://matrix.to/#/@discord_123:example.org\">petr</a>",
                        )
                        .mentions(Mentions::with_user_ids([ghost.to_owned()]))
                        .sender(alice)
                        .event_id(event_id!("$thanks")),
                )
                .add_timeline_event(
                    factory
                        .text_html(
                            "Example, look",
                            "<a href=\"https://matrix.to/#/@example:localhost\">Example</a>, look",
                        )
                        .mentions(Mentions::with_user_ids([owned_user_id!("@example:localhost")]))
                        .sender(alice)
                        .event_id(event_id!("$look")),
                ),
        )
        .await;
    let timelines = MatrixTimelines::new(client, None);
    let page = page_until(&timelines, |page| page.len() == 2).await;

    let thanks = &page[0];
    assert_eq!(thanks.message.body, "thanks Petr (Discord)");
    assert_eq!(
        thanks.styles[0].kind,
        StyleKind::Mention(MentionTarget::User(UserId::from("@discord_123:example.org")))
    );
    assert_eq!(thanks.styles[0].range, 7..21);
    assert!(!thanks.mentions_me);
    // the server's default push rules highlight a mention of the account.
    assert!(page[1].mentions_me);
}

#[tokio::test(flavor = "multi_thread")]
async fn a_draft_keeps_its_pills() {
    let server = MatrixMockServer::new().await;
    let client = client(&server).await;
    server
        .sync_room(&client, JoinedRoomBuilder::new(room_id!("!chat:example.org")))
        .await;
    let timelines = MatrixTimelines::new(client, None);
    let text = ComposedText {
        text: "ask *Ája* later".to_owned(),
        mentions: vec![pill("@aja:example.org", 4, 9)],
    };
    timelines.save_draft(&room().into(), &text, None).await.unwrap();
    assert_eq!(
        timelines.draft(&room().into()).await.unwrap().map(|draft| draft.text),
        Some(text)
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn a_photos_caption_mentions_its_pills() {
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
    let caption = ComposedText {
        text: "for Anna".to_owned(),
        mentions: vec![pill("@anna:example.org", 4, 8)],
    };
    let states: Vec<SendState> = timelines
        .send_attachment(&room().into(), &attachment, Some(&caption), None)
        .await
        .unwrap()
        .collect()
        .await;
    assert_eq!(states.last(), Some(&SendState::Sent));

    let body = sent(&server).await.pop().expect("the photo");
    assert_eq!(body["msgtype"], "m.image");
    assert_eq!(body["body"], "for Anna");
    assert_eq!(
        body["formatted_body"],
        "for <a href=\"https://matrix.to/#/@anna:example.org\">Anna</a>"
    );
    assert_eq!(body["m.mentions"], json!({ "user_ids": ["@anna:example.org"] }));
}
