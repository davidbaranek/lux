//! The view model over the demo's timelines, in paused time: what it sends, and when.

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
use crate::ids::MessageRef;
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
        let _ = self.0.send(Heard::Update(update));
    }

    fn on_upload(&self, upload: Upload) {
        let _ = self.0.send(Heard::Upload(upload));
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
    let (sender, heard) = mpsc::unbounded_channel();
    let spec = ThreadSpec {
        chat: rooms[0].id.as_str().into(),
        default_room: rooms[0].id.clone(),
        rooms,
        listed_unread: false,
        read_receipts: receipts,
        zone: TimeZone::UTC,
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
        .send_text(&"!a:demo".into(), "news", None)
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
    assert_eq!(target.map(|id| id.to_string()), Some("!r:demo/79".to_owned()));
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
            .send_attachment(&"!r:demo".into(), &photo, None, None)
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
    let row = thread.model.jump_to_event(EventId::from(photo.as_str())).await;
    assert_eq!(row.as_ref(), Some(album.id()));
}
