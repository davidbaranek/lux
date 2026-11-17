//! The view model over the demo's timelines, in paused time: what it sends, and when.

use crate::gone::OtherEndGone;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use eyeball_im::VectorDiff;
use jiff::tz::TimeZone;
use tokio::runtime::Handle;
use tokio::sync::mpsc;

use super::*;
use crate::FRAME;
use crate::demo::{DemoAccount, DemoConfig, DemoTimelines};
use crate::ids::{MessageRef, TimelineId};
use crate::network::Network;
use crate::ports::ChatSending;
use crate::ports::ThreadBackend;

struct Ear(mpsc::UnboundedSender<Heard>);

#[derive(Debug)]
enum Heard {
    Update(ThreadUpdate),
    Upload(Upload),
}

impl ThreadListener for Ear {
    fn on_update(&self, update: ThreadUpdate) {
        self.0.send(Heard::Update(update)).other_end_may_be_gone("the test");
    }

    fn on_upload(&self, upload: Upload) {
        self.0.send(Heard::Upload(upload)).other_end_may_be_gone("the test");
    }

    fn on_error(&self, error: BackendError) {
        panic!("an action failed: {error}");
    }
}

struct Opened {
    threads: Arc<DemoAccount>,
    model: ThreadViewModel,
    heard: mpsc::UnboundedReceiver<Heard>,
    rows: Vec<Arc<ThreadRow>>,
    state: Option<ThreadState>,
}

fn chat_room(id: &str, network: &str) -> ChatRoom {
    ChatRoom {
        id: id.into(),
        network: Network::from_id(network),
    }
}

async fn open(rooms: Vec<ChatRoom>, messages: usize, receipts: ReadReceipts) -> Opened {
    let threads = Arc::new(DemoAccount::new(DemoConfig {
        messages_per_room: messages,
        ..DemoConfig::new(30)
    }));
    open_on(threads, rooms, receipts, None).await
}

/// The view model of `rooms` (the Matrix thread of `thread` in the one room, if given), over
/// `threads`.
async fn open_on(
    threads: Arc<DemoAccount>,
    rooms: Vec<ChatRoom>,
    receipts: ReadReceipts,
    thread: Option<EventId>,
) -> Opened {
    let (sender, heard) = mpsc::unbounded_channel();
    let spec = ThreadSpec {
        chat: rooms[0].id.as_str().into(),
        default_room: rooms[0].id.clone(),
        rooms,
        listed_unread: false,
        read_receipts: receipts,
        zone: TimeZone::UTC,
        thread,
    };
    let model = ThreadViewModel::open(&Handle::current(), Arc::clone(&threads), spec, Arc::new(Ear(sender)));
    let mut opened = Opened {
        threads,
        model,
        heard,
        rows: Vec::new(),
        state: None,
    };
    let first = opened.frame().await;
    assert!(matches!(first.rows.as_slice(), [VectorDiff::Reset { .. }]));
    opened
}

impl Opened {
    fn demo(&self) -> &DemoTimelines {
        self.threads.timelines()
    }

    /// Waits a frame and more, and returns the one update it brought (applied to `rows`).
    async fn frame(&mut self) -> ThreadUpdate {
        tokio::time::sleep(FRAME * 3).await;
        let mut updates = self.updates();
        assert_eq!(updates.len(), 1, "one update a frame: {updates:?}");
        updates.remove(0)
    }

    /// What came since, applied.
    fn updates(&mut self) -> Vec<ThreadUpdate> {
        let mut updates = Vec::new();
        while let Ok(heard) = self.heard.try_recv() {
            if let Heard::Update(update) = heard {
                let mut rows: eyeball_im::Vector<_> = self.rows.iter().cloned().collect();
                for diff in update.rows.clone() {
                    diff.apply(&mut rows);
                }
                self.rows = rows.into_iter().collect();
                if let Some(state) = &update.state {
                    self.state = Some(state.clone());
                }
                updates.push(update);
            }
        }
        updates
    }

    fn state(&self) -> &ThreadState {
        self.state.as_ref().expect("a state came")
    }

    fn ids(&self) -> Vec<&str> {
        self.rows.iter().map(|row| row.id().as_str()).collect()
    }
}

#[tokio::test(start_paused = true)]
async fn it_opens_on_the_first_screen_with_the_first_unread_message() {
    let thread = open(vec![chat_room("!r:demo", "matrix")], 200, ReadReceipts::Automatic).await;
    let shown: usize = thread.rows.iter().map(|row| row.album.len().max(1)).sum();
    assert_eq!(shown, 60);
    assert_eq!(thread.rows.last().map(|row| row.id().as_str()), Some("!r:demo/199"));
    let state = thread.state();
    assert_eq!(state.first_unread.as_ref().map(MessageId::as_str), Some("!r:demo/195"));
    assert!(!state.is_loading);
    assert!(state.can_load_older);
    assert_eq!(
        thread.model.first_unread().await.map(|id| id.to_string()),
        Some("!r:demo/195".to_owned())
    );
    // the user's own message is the newest: nothing to read.
    assert!(!state.needs_read_receipt);
}

#[tokio::test(start_paused = true)]
async fn changes_within_a_frame_go_as_one_batch_of_row_diffs() {
    let mut thread = open(vec![chat_room("!r:demo", "matrix")], 30, ReadReceipts::Automatic).await;
    for text in ["one", "two", "three"] {
        thread.model.send_text(text.to_owned(), None);
    }
    let update = thread.frame().await;
    // three new rows, and the rows before whose run they continue: no reset.
    assert!(update.rows.iter().all(|diff| !matches!(diff, VectorDiff::Reset { .. })));
    let ids = thread.ids();
    assert_eq!(ids.len(), 33);
    assert!(ids[30..].iter().all(|id| id.starts_with("demo-sent-")));
    // nothing changed: nothing is sent.
    tokio::time::sleep(FRAME * 5).await;
    assert!(thread.updates().is_empty());
}

#[tokio::test(start_paused = true)]
async fn a_shared_posts_whole_caption_unfolds_and_folds_in_its_row_alone() {
    let mut thread = open(vec![chat_room("!r:demo", "matrix")], 30, ReadReceipts::Automatic).await;
    let id = thread.rows[3].id().clone();
    thread.model.toggle_post(id.clone());
    let update = thread.frame().await;
    assert!(matches!(update.rows.as_slice(), [VectorDiff::Set { index: 3, value }] if value.shows.whole_post));
    thread.model.toggle_post(id);
    let update = thread.frame().await;
    assert!(matches!(update.rows.as_slice(), [VectorDiff::Set { index: 3, value }] if !value.shows.whole_post));
}

#[tokio::test(start_paused = true)]
async fn a_toggled_detail_sets_only_its_row() {
    let mut thread = open(vec![chat_room("!r:demo", "matrix")], 30, ReadReceipts::Automatic).await;
    let id = thread.rows[3].id().clone();
    thread.model.toggle_detail(id.clone());
    let update = thread.frame().await;
    assert!(matches!(update.rows.as_slice(), [VectorDiff::Set { index: 3, value }] if value.shows.detail));
    assert!(update.state.is_none());
}

#[tokio::test(start_paused = true)]
async fn a_merged_chat_writes_where_the_conversation_is_or_to_the_room_shown() {
    let rooms = vec![chat_room("!a:demo", "whatsapp"), chat_room("!b:demo", "signal")];
    let mut thread = open(rooms, 20, ReadReceipts::Automatic).await;
    // both histories end at the same minute: the stable sort puts the second room's last.
    assert_eq!(thread.state().send_room.as_str(), "!b:demo");
    assert_eq!(
        thread.rows.last().and_then(|row| row.network.as_ref()),
        Some(&Network::Signal)
    );
    thread
        .demo()
        .send_text(&RoomId::from("!a:demo").into(), "news", None)
        .await
        .expect("sends");
    thread.frame().await;
    assert_eq!(thread.state().send_room.as_str(), "!a:demo");
    thread.model.show_room(Some("!b:demo".into()));
    thread.frame().await;
    assert_eq!(thread.state().send_room.as_str(), "!b:demo");
    assert_eq!(thread.state().shown_room.as_ref().map(RoomId::as_str), Some("!b:demo"));
    assert!(thread.rows.iter().all(|row| row.room.as_str() == "!b:demo"));
}

#[tokio::test(start_paused = true)]
async fn an_answer_goes_to_its_message_and_files_go_with_the_text_as_caption() {
    let rooms = vec![chat_room("!a:demo", "whatsapp"), chat_room("!b:demo", "signal")];
    let mut thread = open(rooms, 20, ReadReceipts::Automatic).await;
    thread.model.reply("!a:demo/18".into());
    thread.frame().await;
    assert!(
        matches!(&thread.state().mode, ComposerMode::Reply(target) if target.message == MessageRef::Local("!a:demo/18".into()))
    );
    thread
        .model
        .attach(vec![PathBuf::from("/tmp/a.jpg"), PathBuf::from("/tmp/b.jpg")]);
    thread.model.attach(vec![PathBuf::from("/tmp/a.jpg")]);
    thread.model.send_text("  look  ".to_owned(), None);
    tokio::time::sleep(FRAME * 3).await;
    let mut upload = None;
    while let Ok(heard) = thread.heard.try_recv() {
        if let Heard::Upload(heard) = heard {
            upload = Some(heard);
        }
    }
    assert_eq!(
        upload,
        Some(Upload {
            files: vec![PathBuf::from("/tmp/a.jpg"), PathBuf::from("/tmp/b.jpg")],
            room: "!a:demo".into(),
            caption: Some("look".to_owned()),
            reply: Some("!a:demo/18".into()),
            thread: None,
        })
    );
}

#[tokio::test(start_paused = true)]
async fn an_unread_chat_needs_a_receipt_which_goes_by_itself_only_where_the_chat_sends_them() {
    for receipts in [ReadReceipts::Automatic, ReadReceipts::Manual] {
        // the newest message is another's, after the first unread one.
        let mut thread = open(vec![chat_room("!r:demo", "matrix")], 30, receipts).await;
        assert_eq!(thread.rows.last().map(|row| row.message.is_own), Some(false));
        assert!(thread.state().needs_read_receipt);
        thread.model.did_read_latest();
        tokio::time::sleep(FRAME * 3).await;
        let updates = thread.updates();
        if receipts == ReadReceipts::Manual {
            // reading the end sends nothing: the eye button does.
            assert!(updates.is_empty());
            thread.model.send_read_receipt();
            thread.frame().await;
        }
        assert!(!thread.state().needs_read_receipt);
        // the user's own message needs none either.
        thread.model.send_text("ok".to_owned(), None);
        thread.frame().await;
        assert!(!thread.state().needs_read_receipt);
    }
}

#[tokio::test(start_paused = true)]
async fn older_messages_show_as_the_user_scrolls_up_until_the_first() {
    let mut thread = open(vec![chat_room("!r:demo", "matrix")], 100, ReadReceipts::Automatic).await;
    thread.model.load_older();
    thread.frame().await;
    assert_eq!(thread.rows.first().map(|row| row.id().as_str()), Some("!r:demo/0"));
    assert!(thread.state().is_at_start);
    assert!(!thread.state().can_load_older);
    let target = thread.model.jump_to_replied("!r:demo/89".into()).await;
    assert_eq!(target, Ok(Jumped::Here("!r:demo/79".into())));
}

/// Opens a chat of 100 messages whose first unread one takes `unread` to find.
fn open_slow(unread: Duration, listed_unread: bool) -> (ThreadViewModel, mpsc::UnboundedReceiver<Heard>) {
    let threads = Arc::new(DemoAccount::new(DemoConfig {
        messages_per_room: 100,
        ..DemoConfig::new(30)
    }));
    let millis = u64::try_from(unread.as_millis()).unwrap();
    threads
        .timelines()
        .unread_millis
        .store(millis, std::sync::atomic::Ordering::Relaxed);
    let (sender, heard) = mpsc::unbounded_channel();
    let room = chat_room("!r:demo", "matrix");
    let spec = ThreadSpec {
        chat: room.id.as_str().into(),
        default_room: room.id.clone(),
        rooms: vec![room],
        listed_unread,
        read_receipts: ReadReceipts::Automatic,
        zone: TimeZone::UTC,
        thread: None,
    };
    let model = ThreadViewModel::open(&Handle::current(), threads, spec, Arc::new(Ear(sender)));
    (model, heard)
}

fn next_update(heard: &mut mpsc::UnboundedReceiver<Heard>) -> Option<ThreadUpdate> {
    while let Ok(heard) = heard.try_recv() {
        if let Heard::Update(update) = heard {
            return Some(update);
        }
    }
    None
}

#[tokio::test(start_paused = true)]
async fn the_rows_do_not_wait_long_for_a_hanging_first_unread() {
    let (model, mut heard) = open_slow(Duration::from_secs(3600), true);
    tokio::time::sleep(Duration::from_secs(2)).await;
    let first = next_update(&mut heard).expect("the rows came");
    assert!(matches!(first.rows.as_slice(), [VectorDiff::Reset { values }] if !values.is_empty()));
    let state = first.state.expect("the first update has the state");
    assert_eq!(state.first_unread, None);
    // the chat list counted unread messages: a receipt is due all the same.
    assert!(state.needs_read_receipt);
    // who waits for the first unread message opens the chat at the bottom.
    assert_eq!(model.first_unread().await, None);
}

#[tokio::test(start_paused = true)]
async fn a_first_unread_found_late_still_places_the_marker() {
    let (_model, mut heard) = open_slow(Duration::from_secs(5), false);
    tokio::time::sleep(Duration::from_secs(2)).await;
    let first = next_update(&mut heard).expect("the rows came");
    let state = first.state.expect("the first update has the state");
    assert_eq!(state.first_unread, None);
    // the list counted none, and the lookup has not said: no receipt is asked for yet.
    assert!(!state.needs_read_receipt);
    tokio::time::sleep(Duration::from_secs(4)).await;
    let late = next_update(&mut heard).expect("the marker came");
    let state = late.state.expect("the state changed");
    assert_eq!(state.first_unread.as_ref().map(MessageId::as_str), Some("!r:demo/95"));
    assert!(next_update(&mut heard).is_none());
}

#[tokio::test(start_paused = true)]
async fn a_slow_forward_holds_back_only_its_message() {
    let mut thread = open(vec![chat_room("!r:demo", "matrix")], 30, ReadReceipts::Automatic).await;
    thread
        .demo()
        .forward_millis
        .store(60_000, std::sync::atomic::Ordering::Relaxed);
    thread.model.forward("!r:demo/20".into(), "!other:demo".into());
    thread.model.delete("!r:demo/20".into());
    thread.model.toggle_reaction("!r:demo/21".into(), "👍".to_owned());
    thread.frame().await;
    let row = |thread: &Opened, id: &str| {
        let row = thread.rows.iter().find(|row| row.id().as_str() == id).cloned();
        row.expect("the message shows")
    };
    // the reaction on another message went at once; the deletion waits for the forward.
    assert!(row(&thread, "!r:demo/21").message.message.has_reactions);
    assert!(!row(&thread, "!r:demo/20").message.message.body.is_empty());
    tokio::time::sleep(Duration::from_secs(61)).await;
    thread.updates();
    assert!(row(&thread, "!r:demo/20").message.message.body.is_empty());
}

#[tokio::test(start_paused = true)]
async fn a_jump_to_a_photo_in_an_album_answers_the_albums_row() {
    let mut thread = open(vec![chat_room("!r:demo", "matrix")], 20, ReadReceipts::Automatic).await;
    // two photos sent together, without words: an album.
    for name in ["a.jpg", "b.jpg"] {
        let photo = crate::timeline::OutgoingAttachment {
            file: PathBuf::from(format!("/tmp/{name}")),
            name: name.to_owned(),
            mimetype: "image/jpeg".to_owned(),
            size: 1,
            kind: crate::timeline::OutgoingKind::Photo { width: 10, height: 10 },
            thumbnail: None,
        };
        thread
            .threads
            .timelines()
            .send_attachment(&RoomId::from("!r:demo").into(), &photo, None, None)
            .await
            .unwrap();
    }
    thread.frame().await;
    let album = thread
        .rows
        .iter()
        .find(|row| row.album.len() > 1)
        .expect("the demo's history has an album");
    let photo = album.album[1].message.id.clone();
    assert_ne!(&photo, album.id());
    // the demo's events are its messages.
    let row = thread.model.jump("!r:demo".into(), EventId::from(photo.as_str())).await;
    assert_eq!(row, Ok(Jumped::Here(album.id().clone())));
}

// MARK: Matrix threads

/// The demo's room `!r:demo` of 30 messages, its newest thread's root being its 22nd.
fn thread_demo() -> Arc<DemoAccount> {
    Arc::new(DemoAccount::new(DemoConfig {
        messages_per_room: 30,
        ..DemoConfig::new(30)
    }))
}

#[tokio::test(start_paused = true)]
async fn the_rooms_timeline_shows_a_threads_root_with_its_summary_and_not_its_replies() {
    let thread = open(vec![chat_room("!r:demo", "matrix")], 30, ReadReceipts::Automatic).await;
    let root = thread
        .rows
        .iter()
        .find(|row| row.id().as_str() == "!r:demo/22")
        .expect("the root shows");
    let summary = root.message.thread.as_ref().expect("its summary");
    assert!(summary.replies >= 2);
    assert!(summary.latest.is_some());
    assert!(!summary.participants.is_empty());
    assert!(thread.ids().iter().all(|id| !id.contains("/thread")));
}

#[tokio::test(start_paused = true)]
async fn a_thread_opens_on_its_root_and_replies_and_what_is_sent_goes_there() {
    let demo = thread_demo();
    let mut chat = open_on(
        Arc::clone(&demo),
        vec![chat_room("!r:demo", "matrix")],
        ReadReceipts::Automatic,
        None,
    )
    .await;
    let replies_before = chat
        .rows
        .iter()
        .find(|row| row.id().as_str() == "!r:demo/22")
        .expect("root")
        .message
        .thread
        .as_ref()
        .expect("summary")
        .replies;
    let mut thread = open_on(
        Arc::clone(&demo),
        vec![chat_room("!r:demo", "matrix")],
        ReadReceipts::Automatic,
        Some(EventId::from("!r:demo/22")),
    )
    .await;
    let ids = thread.ids();
    assert_eq!(ids[0], "!r:demo/22/thread");
    assert_eq!(ids.len(), 1 + replies_before as usize);
    assert!(ids[1..].iter().all(|id| id.starts_with("!r:demo/22/thread/")));
    // nothing is sent later in a thread: the server's message would go to the room.
    assert!(!thread.state().can_send_later);
    thread.model.send_text("in the thread".to_owned(), None);
    thread.frame().await;
    assert_eq!(
        thread.rows.last().map(|row| row.message.message.body.as_str()),
        Some("in the thread")
    );
    // the room's timeline: the reply does not show, the root counts it.
    chat.frame().await;
    assert!(chat.rows.iter().all(|row| row.message.message.body != "in the thread"));
    let summary = chat
        .rows
        .iter()
        .find(|row| row.id().as_str() == "!r:demo/22")
        .expect("root")
        .message
        .thread
        .clone()
        .expect("summary");
    assert_eq!(summary.replies, replies_before + 1);
    assert_eq!(summary.participants[0].name, "Me");
    assert_eq!(
        summary.latest.map(|latest| latest.kind),
        Some(crate::preview::PreviewKind::Text("in the thread".to_owned()))
    );
}

#[tokio::test(start_paused = true)]
async fn files_sent_in_a_thread_go_to_it() {
    let mut thread = open_on(
        thread_demo(),
        vec![chat_room("!r:demo", "matrix")],
        ReadReceipts::Automatic,
        Some(EventId::from("!r:demo/22")),
    )
    .await;
    thread.model.attach(vec![PathBuf::from("/tmp/a.jpg")]);
    thread.model.send_text(String::new(), None);
    tokio::time::sleep(FRAME * 3).await;
    let mut upload = None;
    while let Ok(heard) = thread.heard.try_recv() {
        if let Heard::Upload(sent) = heard {
            upload = Some(sent);
        }
    }
    let upload = upload.expect("an upload");
    assert_eq!(
        upload.timeline(),
        TimelineId::thread("!r:demo".into(), "!r:demo/22".into())
    );
}

#[tokio::test(start_paused = true)]
async fn reacting_join_thread_to_a_bridges_notice_brings_the_threads_replies() {
    let demo = thread_demo();
    // the thread whose first reply is the bridge's notice, its join reaction waiting.
    let mut found = None;
    for index in [11, 22] {
        let root = EventId::from(format!("!r:demo/{index}"));
        let thread = open_on(
            Arc::clone(&demo),
            vec![chat_room("!r:demo", "matrix")],
            ReadReceipts::Automatic,
            Some(root.clone()),
        )
        .await;
        if thread
            .rows
            .get(1)
            .is_some_and(|row| row.message.message.body.starts_with("Thread created."))
        {
            found = Some(thread);
        }
    }
    let mut thread = found.expect("a bridged thread among the demo's");
    let notice = thread.rows[1].message.clone();
    assert!(
        notice
            .reactions
            .iter()
            .any(|reaction| reaction.key == "join thread" && !reaction.is_mine)
    );
    let before = thread.rows.len();
    thread
        .model
        .toggle_reaction(notice.message.id.clone(), "join thread".to_owned());
    tokio::time::sleep(FRAME * 3).await;
    thread.updates();
    assert!(
        thread.rows[1]
            .message
            .reactions
            .iter()
            .any(|reaction| reaction.key == "join thread" && reaction.is_mine)
    );
    assert_eq!(thread.rows.len(), before + 2);
    assert!(thread.rows.last().is_some_and(|row| !row.message.is_own));
}

#[tokio::test]
async fn a_rooms_threads_list_the_latest_active_first_a_page_at_a_time() {
    use crate::ports::ChatDetails;
    let demo = Arc::new(DemoAccount::new(DemoConfig {
        messages_per_room: 200,
        ..DemoConfig::new(30)
    }));
    let page = demo.threads(&"!room1:demo".into(), None).await.expect("listed");
    assert!(page.threads.len() >= 2);
    let latest = |thread: &crate::ports::ListedThread| thread.summary.latest.as_ref().map(|latest| latest.date);
    assert!(page.threads.windows(2).all(|pair| latest(&pair[0]) >= latest(&pair[1])));
    assert_eq!(page.threads[0].root.as_str(), "!room1:demo/192");
}

// MARK: jumps to old messages

/// The demo's `rooms` of `messages` messages each, whose live timelines hold only their newest
/// `tail` (as a device holds a long chat's latest): an older message is a jump away.
async fn open_long(rooms: Vec<ChatRoom>, messages: usize, tail: usize) -> Opened {
    let threads = Arc::new(DemoAccount::new(DemoConfig {
        messages_per_room: messages,
        ..DemoConfig::new(30)
    }));
    threads
        .timelines()
        .live_tail
        .store(tail, std::sync::atomic::Ordering::Relaxed);
    open_on(threads, rooms, ReadReceipts::Automatic, None).await
}

fn here(jumped: Result<Jumped, JumpFailure>) -> MessageId {
    match jumped {
        Ok(Jumped::Here(row)) => row,
        other => panic!("the jump did not land here: {other:?}"),
    }
}

/// Frames until the state says the rows are live (or not), with the updates on the way.
async fn until_live(thread: &mut Opened, live: bool) -> Vec<ThreadUpdate> {
    let mut seen = Vec::new();
    for _ in 0..20 {
        tokio::time::sleep(FRAME * 3).await;
        seen.extend(thread.updates());
        if thread.state().is_live == live {
            return seen;
        }
    }
    panic!("the rows did not become live == {live}");
}

#[tokio::test(start_paused = true)]
async fn a_message_the_live_rows_hold_is_scrolled_to_and_they_stay_live() {
    let mut thread = open_long(vec![chat_room("!r:demo", "matrix")], 200, 0).await;
    let row = here(thread.model.jump("!r:demo".into(), EventId::from("!r:demo/120")).await);
    assert_eq!(row.as_str(), "!r:demo/120");
    thread.updates();
    assert!(thread.ids().contains(&"!r:demo/120"));
    assert!(thread.state().is_live);
}

#[tokio::test(start_paused = true)]
async fn an_old_message_shows_among_its_neighbours_until_the_user_returns() {
    let mut thread = open_long(vec![chat_room("!r:demo", "matrix")], 300, 60).await;
    let row = here(thread.model.jump("!r:demo".into(), EventId::from("!r:demo/40")).await);
    until_live(&mut thread, false).await;
    assert!(thread.ids().contains(&row.as_str()));
    assert!(
        thread.ids().iter().all(|id| id.starts_with('@')),
        "only the jump's rows"
    );
    assert!(thread.state().can_load_newer);

    thread.model.return_to_live();
    until_live(&mut thread, true).await;
    assert_eq!(thread.ids().last(), Some(&"!r:demo/299"));
    assert!(thread.ids().iter().all(|id| !id.starts_with('@')));
    assert!(!thread.state().can_load_newer);
}

#[tokio::test(start_paused = true)]
async fn paging_forward_to_the_newest_switches_to_the_live_rows_at_the_readers_message() {
    let mut thread = open_long(vec![chat_room("!r:demo", "matrix")], 300, 60).await;
    here(thread.model.jump("!r:demo".into(), EventId::from("!r:demo/200")).await);
    until_live(&mut thread, false).await;
    // the reader looks at a message the live rows do not hold yet (they start at the 240th).
    let reading = thread
        .rows
        .iter()
        .find(|row| row.message.event_id == Some(EventId::from("!r:demo/230")))
        .map(|row| row.id().clone())
        .expect("the jump's rows hold it");
    thread.model.set_anchor(reading.clone());
    thread.model.load_newer();

    let updates = until_live(&mut thread, true).await;
    let anchor = updates
        .iter()
        .find_map(|update| update.anchor.clone())
        .expect("the switch keeps the reader's row");
    assert_eq!(anchor.from, reading);
    assert_eq!(anchor.to.as_str(), "!r:demo/230");
    // the live rows from the reader's message to the newest: none twice, none missing.
    let ids = thread.ids();
    let from = ids
        .iter()
        .position(|id| *id == "!r:demo/230")
        .expect("the live rows show it");
    let expected: Vec<String> = (230..300).map(|index| format!("!r:demo/{index}")).collect();
    let shown: Vec<String> = ids[from..]
        .iter()
        .flat_map(|id| {
            let row = thread.rows.iter().find(|row| row.id().as_str() == *id).unwrap();
            if row.album.is_empty() {
                vec![row.id().to_string()]
            } else {
                row.album.iter().map(|message| message.message.id.to_string()).collect()
            }
        })
        .collect();
    assert_eq!(shown, expected);
}

#[tokio::test(start_paused = true)]
async fn sending_from_a_jumps_rows_returns_to_the_live_ones_first() {
    let mut thread = open_long(vec![chat_room("!r:demo", "matrix")], 300, 60).await;
    here(thread.model.jump("!r:demo".into(), EventId::from("!r:demo/40")).await);
    until_live(&mut thread, false).await;
    thread.model.send_text("back to now".to_owned(), None);
    until_live(&mut thread, true).await;
    let last = thread.rows.last().expect("rows");
    assert_eq!(last.message.message.body, "back to now");
}

#[tokio::test(start_paused = true)]
async fn a_merged_chat_shows_a_jumps_room_alone_and_its_own_filter_again_after() {
    let rooms = vec![chat_room("!a:demo", "whatsapp"), chat_room("!b:demo", "signal")];
    let mut thread = open_long(rooms, 300, 60).await;
    here(thread.model.jump("!b:demo".into(), EventId::from("!b:demo/40")).await);
    until_live(&mut thread, false).await;
    assert_eq!(thread.state().shown_room.as_ref().map(RoomId::as_str), Some("!b:demo"));
    assert!(thread.rows.iter().all(|row| row.room.as_str() == "!b:demo"));
    assert!(
        thread.rows.iter().all(|row| row.network.is_some()),
        "a merged chat's rows tell their network"
    );

    // all rooms again is the live rows.
    thread.model.show_room(None);
    until_live(&mut thread, true).await;
    assert_eq!(thread.state().shown_room, None);
    assert!(thread.rows.iter().any(|row| row.room.as_str() == "!a:demo"));
}

#[tokio::test(start_paused = true)]
async fn a_jump_the_server_cannot_show_leaves_the_rows_as_they_are() {
    let mut thread = open_long(vec![chat_room("!r:demo", "matrix")], 300, 60).await;
    let before = thread.ids().iter().map(|id| (*id).to_owned()).collect::<Vec<_>>();
    assert_eq!(
        thread.model.jump("!r:demo".into(), EventId::from("$gone")).await,
        Err(JumpFailure::NotFound)
    );
    assert_eq!(
        thread
            .model
            .jump("!elsewhere:demo".into(), EventId::from("!r:demo/40"))
            .await,
        Err(JumpFailure::NotFound)
    );
    tokio::time::sleep(FRAME * 3).await;
    thread.updates();
    assert!(thread.state().is_live);
    assert_eq!(thread.ids(), before.iter().map(String::as_str).collect::<Vec<_>>());
}
