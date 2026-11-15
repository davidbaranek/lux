//! The task that owns a thread: the only writer of its state. It takes the user's intents and
//! the backend's events (the rooms' diffs, the answers of what it spawned) in turn, and once a
//! frame, when anything changed, presents the rows and sends their diffs with the state.

use std::collections::HashMap;
use std::future::Future;
use std::mem;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use eyeball_im::{Vector, VectorDiff};
use futures_util::StreamExt;
use futures_util::future::join_all;
use jiff::tz::TimeZone;
use tokio::sync::{mpsc, oneshot};
use tokio::task::JoinSet;
use tokio::time::Instant;

use super::decide::{self, ComposerMode, ReadReceipts, ReadState, ReplyTarget, TypingNotice};
use super::rows::{self, OLDER, RoomMessages, ThreadRow};
use super::{DraftIntent, Intent, MessageAction, ThreadListener, ThreadSpec, ThreadState, ThreadUpdate, Upload};
use crate::FRAME;
use crate::actions::Actions;
use crate::diff;
use crate::ids::{EventId, MessageId, MessageRef, RoomId, TimelineId};
use crate::merge;
use crate::ports::{BackendError, ChatSending, ChatTimelines, Diffs, ThreadBackend, TimelineHold};
use crate::timeline::{Draft, Receipt, TimelineMessage, Typist};

/// The longest the first rows wait for the rooms' first unread messages: finding one can page
/// back on the server, and a bad connection must not hold back the messages already in. The
/// lookup goes on; its answer still places the marker.
const UNREAD_WAIT: Duration = Duration::from_secs(1);

/// What the backend and the thread's own spawned work tell the task.
enum Event {
    /// A room's messages changed.
    Diffs(usize, Diffs<Arc<TimelineMessage>>),
    /// A room's messages cannot be read: it shows none.
    Unreadable(usize),
    /// The rooms' first unread messages.
    FirstUnread(Vec<MessageId>),
    /// Finding them takes longer than the first rows wait.
    UnreadSlow,
    /// A room's first screen is in; whether its timeline holds its first message.
    Filled(usize, bool),
    /// A page back of a room is in; whether its timeline now holds its first message.
    Paged(usize, Option<bool>),
    /// A jump's message is in the room's timeline (or was not found).
    Found(Option<(usize, MessageId)>, oneshot::Sender<Option<MessageId>>),
    /// Who is typing in a room.
    Typing(usize, Vec<Typist>),
    /// Whether the room can have messages sent later.
    CanSendLater(RoomId, bool),
    /// The kept draft.
    Draft(Option<Draft>, oneshot::Sender<String>),
}

/// Runs the thread until its view model goes.
pub(super) async fn run<B: ThreadBackend>(
    backend: Arc<B>,
    spec: ThreadSpec,
    listener: Arc<dyn ThreadListener>,
    mut intents: mpsc::UnboundedReceiver<Intent>,
) {
    let (events, mut received) = mpsc::unbounded_channel();
    let mut thread = Thread::new(backend, spec, listener, events);
    thread.open();
    let mut frame: Option<Instant> = None;
    loop {
        tokio::select! {
            intent = intents.recv() => match intent {
                Some(intent) => thread.intent(intent),
                None => break,
            },
            Some(event) = received.recv() => thread.event(event),
            // a follower or a lookup ended: its place in the set goes.
            Some(_) = thread.followers.join_next() => {}
            () = until(frame) => {
                frame = None;
                thread.flush();
            }
        }
        if frame.is_none() && thread.wants_frame() {
            frame = Some(Instant::now() + FRAME);
        }
    }
}

async fn until(deadline: Option<Instant>) {
    match deadline {
        Some(deadline) => tokio::time::sleep_until(deadline).await,
        None => std::future::pending().await,
    }
}

/// What changed since the last frame: the rows to present again, the state to compare.
#[derive(Debug)]
struct Dirty {
    rows: bool,
    state: bool,
}

/// The first unread message is decided once: with the first rows, or after them when finding it
/// took longer than they wait.
#[derive(Debug, PartialEq, Eq)]
enum FirstUnread {
    Undecided,
    /// The rows went without it: it is decided when the lookup ends.
    Late,
    Decided(Option<MessageId>),
}

struct Thread<B> {
    backend: Arc<B>,
    listener: Arc<dyn ThreadListener>,
    events: mpsc::UnboundedSender<Event>,
    default_room: RoomId,
    /// The Matrix thread shown, by its root; `None`: the chat's own timelines.
    root: Option<EventId>,
    listed_unread: bool,
    receipts: ReadReceipts,
    zone: TimeZone,
    rooms: Vec<RoomMessages>,
    /// The room shown alone, by its position in `rooms`.
    shown: Option<usize>,
    unfolded: rows::Unfolded,
    mode: ComposerMode,
    pending_files: Vec<PathBuf>,
    read: ReadState,
    typing_notice: TypingNotice,
    typing_by_room: HashMap<RoomId, Vec<Typist>>,
    typists: Vec<Typist>,
    /// The followers of who types, while the chat is on screen.
    watching: Option<JoinSet<()>>,
    /// The rooms' followers, the opening's work and the one-off lookups (a draft, a page, a
    /// jump): they end with the thread, so none answers after it closed.
    followers: JoinSet<()>,
    holds: Vec<TimelineHold>,
    /// The rows sent last.
    rows: Vec<Arc<ThreadRow>>,
    /// The state sent last.
    sent: Option<ThreadState>,
    /// What changed since the last frame.
    dirty: Dirty,
    /// The rooms' first unread messages; `None` until known.
    unread_found: Option<Vec<MessageId>>,
    /// Finding them takes longer than the first rows wait.
    unread_slow: bool,
    /// The first unread message, decided with the first rows.
    first_unread: FirstUnread,
    /// Rooms whose first screen is not in yet, pages back, and jumps under way.
    filling: usize,
    paging: usize,
    jumping: usize,
    /// Messages to show once their room's timeline has them, and who waits for them.
    reveals: Vec<(MessageId, Option<oneshot::Sender<Option<MessageId>>>)>,
    /// Jumps to messages now shown, answered with their rows once the rows are presented.
    jumped: Vec<(MessageId, oneshot::Sender<Option<MessageId>>)>,
    loaded_waiters: Vec<oneshot::Sender<()>>,
    unread_waiters: Vec<oneshot::Sender<Option<MessageId>>>,
    send_room: RoomId,
    can_send_later: bool,
    /// The backend actions, in the order asked for on each target.
    actions: Actions<Target>,
}

/// What a thread's action changes: those on one target reach the server in the order asked.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
enum Target {
    /// A message: its reactions, edit, deletion, retry, forward, saving.
    Message(MessageId),
    /// The messages sent to a room, in the order written.
    Sends(RoomId),
    /// A timeline's kept draft.
    Draft(TimelineId),
    /// The typing notices to a room: a stop must not overtake its start.
    Typing(RoomId),
}

impl<B: ThreadBackend> Thread<B> {
    fn new(
        backend: Arc<B>,
        spec: ThreadSpec,
        listener: Arc<dyn ThreadListener>,
        events: mpsc::UnboundedSender<Event>,
    ) -> Self {
        let mut rooms: Vec<RoomMessages> = spec.rooms.into_iter().map(RoomMessages::new).collect();
        if rooms.is_empty() {
            rooms.push(RoomMessages::new(crate::chat::ChatRoom {
                id: spec.default_room.clone(),
                network: crate::network::Network::Matrix,
            }));
        }
        Self {
            backend,
            listener,
            events,
            send_room: spec.default_room.clone(),
            default_room: spec.default_room,
            root: spec.thread,
            listed_unread: spec.listed_unread,
            receipts: spec.read_receipts,
            zone: spec.zone,
            filling: rooms.len(),
            rooms,
            shown: None,
            unfolded: rows::Unfolded::default(),
            mode: ComposerMode::Message,
            pending_files: Vec::new(),
            read: ReadState::default(),
            typing_notice: TypingNotice::default(),
            typing_by_room: HashMap::new(),
            typists: Vec::new(),
            watching: None,
            followers: JoinSet::new(),
            holds: Vec::new(),
            rows: Vec::new(),
            sent: None,
            dirty: Dirty {
                rows: true,
                state: true,
            },
            unread_found: None,
            unread_slow: false,
            first_unread: FirstUnread::Undecided,
            paging: 0,
            jumping: 0,
            reveals: Vec::new(),
            jumped: Vec::new(),
            loaded_waiters: Vec::new(),
            unread_waiters: Vec::new(),
            can_send_later: false,
            actions: Actions::new(),
        }
    }

    // MARK: opening

    /// Holds the rooms' timelines, follows their messages, and asks for their first unread
    /// messages and their opening fill.
    fn open(&mut self) {
        let ids: Vec<TimelineId> = self.rooms.iter().map(|room| self.timeline(&room.room.id)).collect();
        for (index, id) in ids.iter().enumerate() {
            self.holds.push(self.backend.timelines().hold(id));
            let (backend, events, listener, timeline) = (
                Arc::clone(&self.backend),
                self.events.clone(),
                Arc::clone(&self.listener),
                id.clone(),
            );
            self.followers.spawn(async move {
                match backend.timelines().messages(&timeline).await {
                    Ok(mut batches) => {
                        while let Some(batch) = batches.next().await {
                            if events.send(Event::Diffs(index, batch)).is_err() {
                                break;
                            }
                        }
                    }
                    Err(error) => {
                        listener.on_error(error);
                        let _ = events.send(Event::Unreadable(index));
                    }
                }
            });
            let (backend, events, id) = (Arc::clone(&self.backend), self.events.clone(), id.clone());
            self.followers.spawn(async move {
                let timelines = backend.timelines();
                timelines.wait_until_filled(&id).await;
                let at_start = timelines.is_at_start(&id).await.unwrap_or(false);
                let _ = events.send(Event::Filled(index, at_start));
            });
        }
        let (backend, events) = (Arc::clone(&self.backend), self.events.clone());
        self.followers.spawn(async move {
            let timelines = backend.timelines();
            let mut found = std::pin::pin!(join_all(ids.iter().map(|id| timelines.first_unread(id))));
            let found = if let Ok(found) = tokio::time::timeout(UNREAD_WAIT, &mut found).await {
                found
            } else {
                // the rows go without it; the marker follows.
                let _ = events.send(Event::UnreadSlow);
                found.await
            };
            let found = found.into_iter().filter_map(|found| found.ok().flatten()).collect();
            let _ = events.send(Event::FirstUnread(found));
        });
        self.refresh_can_send_later();
    }

    // MARK: the loop's steps

    /// The first rows wait for every room's messages and, for a while, the first unread one.
    fn ready(&self) -> bool {
        (self.unread_found.is_some() || self.unread_slow) && self.rooms.iter().all(|room| room.loaded)
    }

    fn wants_frame(&self) -> bool {
        self.ready() && (self.dirty.rows || self.dirty.state)
    }

    fn event(&mut self, event: Event) {
        match event {
            Event::Diffs(index, diffs) => {
                self.rooms[index].apply(diffs);
                self.reveal_waiting();
                self.dirty.rows = true;
            }
            Event::Unreadable(index) => {
                self.rooms[index].loaded = true;
                self.dirty.rows = true;
            }
            Event::FirstUnread(found) => {
                self.reveals.extend(found.iter().map(|id| (id.clone(), None)));
                self.unread_found = Some(found);
                self.reveal_waiting();
                self.dirty.rows = true;
            }
            Event::UnreadSlow => {
                self.unread_slow = true;
                self.dirty.rows = true;
            }
            Event::Filled(index, at_start) => {
                self.rooms[index].at_start = at_start;
                self.filling = self.filling.saturating_sub(1);
                if self.filling == 0 {
                    for waiter in self.loaded_waiters.drain(..) {
                        let _ = waiter.send(());
                    }
                }
                self.dirty.state = true;
            }
            Event::Paged(index, at_start) => {
                let room = &mut self.rooms[index];
                if let Some(at_start) = at_start {
                    room.at_start = at_start;
                }
                room.paging = false;
                self.dirty.rows = true;
                self.paging = self.paging.saturating_sub(1);
                self.dirty.state = true;
            }
            Event::Found(found, answer) => {
                self.jumping = self.jumping.saturating_sub(1);
                self.dirty.state = true;
                match found {
                    Some((index, id)) if self.rooms[index].reveal(&id) => {
                        self.dirty.rows = true;
                        self.jumped.push((id, answer));
                    }
                    // the room's list has not caught up yet: it shows once it does.
                    Some((_, id)) => self.reveals.push((id, Some(answer))),
                    None => {
                        let _ = answer.send(None);
                    }
                }
            }
            Event::Typing(index, typists) => {
                self.typing_by_room.insert(self.rooms[index].room.id.clone(), typists);
                self.update_typists();
            }
            Event::CanSendLater(room, can) => {
                if room == self.send_room {
                    self.can_send_later = can;
                    self.dirty.state = true;
                }
            }
            Event::Draft(draft, answer) => {
                let draft = draft.unwrap_or_default();
                if let Some(quote) = draft.reply {
                    self.mode = ComposerMode::Reply(ReplyTarget::of_quote(quote));
                    self.dirty.state = true;
                }
                let _ = answer.send(draft.text);
            }
        }
    }

    /// Sends the frame's changes: the rows presented anew and diffed against those sent, and
    /// the state if it changed. The first frame sends all the rows, even none.
    fn flush(&mut self) {
        if !self.ready() {
            return;
        }
        let first = self.sent.is_none();
        let mut update = ThreadUpdate::default();
        if self.dirty.rows || first {
            self.dirty.rows = false;
            for room in &mut self.rooms {
                room.reveal_older();
            }
            let rows = rows::present(&mut self.rooms, self.shown, &self.unfolded, &self.zone);
            update.rows = if first {
                vec![VectorDiff::Reset {
                    values: rows.iter().cloned().collect::<Vector<_>>(),
                }]
            } else {
                diff::changes(&self.rows, &rows, |row| row.id())
            };
            self.rows = rows;
            self.answer_jumps();
            self.after_rows();
        }
        self.dirty.state = false;
        let state = self.state();
        if self.sent.as_ref() != Some(&state) {
            update.state = Some(state.clone());
            self.sent = Some(state);
        }
        if first || !update.rows.is_empty() || update.state.is_some() {
            self.listener.on_update(update);
        }
    }

    /// What follows from new rows: the first unread message (with the first rows, or once
    /// found), the room a new message goes to, the read state.
    fn after_rows(&mut self) {
        self.decide_first_unread();
        let shown = self.shown.map(|index| &self.rooms[index].room.id);
        let send_room =
            merge::send_room(shown, self.rows.iter().map(|row| Some(&row.room)), &self.default_room).clone();
        if send_room != self.send_room {
            self.send_room = send_room;
            self.refresh_can_send_later();
        }
        self.read
            .update(self.rows.last().map(|row| (row.id(), row.message.is_own)));
    }

    /// Decides the first unread message from the rows once the lookup ended. The first rows
    /// that go without it answer those waiting with none (the chat opens at the bottom) and leave
    /// the read state to the chat list's count, or to the lookup when the list counted none.
    fn decide_first_unread(&mut self) {
        let Some(found) = self.unread_found.as_deref() else {
            if self.first_unread == FirstUnread::Undecided {
                if self.listed_unread {
                    self.read.opened(true);
                }
                for waiter in self.unread_waiters.drain(..) {
                    let _ = waiter.send(None);
                }
                self.first_unread = FirstUnread::Late;
            }
            return;
        };
        if matches!(self.first_unread, FirstUnread::Decided(_)) {
            return;
        }
        // the earliest of the rooms' first unread messages, as the conversation shows them.
        let first = self
            .rows
            .iter()
            .map(|row| row.id())
            .find(|id| found.contains(id))
            .or_else(|| found.first())
            .cloned();
        self.read.opened(self.listed_unread || first.is_some());
        for waiter in self.unread_waiters.drain(..) {
            let _ = waiter.send(first.clone());
        }
        self.first_unread = FirstUnread::Decided(first);
    }

    /// The chat's first message shows: every room shown shows its first.
    fn shows_start(&mut self) -> bool {
        let shown = self.shown;
        self.rooms
            .iter_mut()
            .enumerate()
            .filter(|(index, _)| shown.is_none_or(|shown| shown == *index))
            .all(|(_, room)| room.shows_start())
    }

    fn state(&mut self) -> ThreadState {
        let shown = self.shown;
        let at_start = self.shows_start();
        ThreadState {
            is_loading: self.filling > 0 || self.paging > 0 || self.jumping > 0,
            can_load_older: self.paging == 0 && !self.older_due() && !at_start,
            is_at_start: at_start,
            first_unread: match &self.first_unread {
                FirstUnread::Decided(first) => first.clone(),
                FirstUnread::Undecided | FirstUnread::Late => None,
            },
            needs_read_receipt: self.read.needs_receipt,
            typists: self.typists.clone(),
            shown_room: shown.map(|index| self.rooms[index].room.id.clone()),
            send_room: self.send_room.clone(),
            mode: self.mode.clone(),
            pending_files: self.pending_files.clone(),
            can_send_later: self.can_send_later,
        }
    }

    // MARK: intents

    fn intent(&mut self, intent: Intent) {
        match intent {
            Intent::LoadOlder => self.load_older(),
            Intent::JumpToReplied(message, answer) => self.jump_to_replied(&message, answer),
            Intent::JumpToEvent(event, answer) => {
                let shown = self.shown_rooms().collect();
                self.jump(shown, event, answer);
            }
            Intent::FirstUnread(answer) => match &self.first_unread {
                FirstUnread::Decided(first) => {
                    let _ = answer.send(first.clone());
                }
                FirstUnread::Late => {
                    let _ = answer.send(None);
                }
                FirstUnread::Undecided => self.unread_waiters.push(answer),
            },
            Intent::Loaded(answer) => {
                if self.filling == 0 {
                    let _ = answer.send(());
                } else {
                    self.loaded_waiters.push(answer);
                }
            }
            Intent::ToggleDetail(message) => {
                rows::Unfolded::toggle(&mut self.unfolded.details, message);
                self.dirty.rows = true;
            }
            Intent::TogglePost(message) => {
                rows::Unfolded::toggle(&mut self.unfolded.posts, message);
                self.dirty.rows = true;
            }
            Intent::ShowRoom(room) => self.show_room(room.as_ref()),
            Intent::Reply(message) => {
                if let Some(target) = self.message(&message).map(|message| ReplyTarget::of(message)) {
                    self.set_mode(ComposerMode::Reply(target));
                }
            }
            Intent::Edit(message) => {
                if let Some(found) = self.message(&message).filter(|found| found.is_editable) {
                    let original = found.message.body.clone();
                    self.set_mode(ComposerMode::Edit { message, original });
                }
            }
            Intent::CancelMode => self.set_mode(ComposerMode::Message),
            Intent::Send { text, via } => self.send(text.trim(), via),
            Intent::SendLater(text, at, answer) => self.send_later(text.trim(), at, answer),
            Intent::Attach(files) => {
                for file in files {
                    if !self.pending_files.contains(&file) {
                        self.pending_files.push(file);
                    }
                }
                self.dirty.state = true;
            }
            Intent::RemovePending(file) => {
                self.pending_files.retain(|pending| pending != &file);
                self.dirty.state = true;
            }
            Intent::Message(action) => self.message_action(action),
            Intent::DidReadLatest => {
                if self.receipts == ReadReceipts::Automatic {
                    self.send_read_receipt();
                }
            }
            Intent::SendReadReceipt => self.send_read_receipt(),
            Intent::SetReadReceipts(receipts) => self.receipts = receipts,
            Intent::WatchTyping => {
                if self.watching.is_none() {
                    self.watch_typing();
                }
            }
            Intent::StopWatchingTyping => {
                self.end_typing();
                self.composer_changed("");
            }
            Intent::ComposerChanged(text) => self.composer_changed(&text),
            Intent::Draft(intent) => self.draft(intent),
        }
    }

    /// The composer's kept draft: read when the chat opens, kept when it closes.
    fn draft(&mut self, intent: DraftIntent) {
        match intent {
            DraftIntent::Load(answer) => {
                let (backend, events, listener, timeline) = (
                    Arc::clone(&self.backend),
                    self.events.clone(),
                    Arc::clone(&self.listener),
                    self.timeline(&self.default_room),
                );
                self.followers.spawn(async move {
                    let draft = backend.timelines().draft(&timeline).await.unwrap_or_else(|error| {
                        listener.on_error(error);
                        None
                    });
                    let _ = events.send(Event::Draft(draft, answer));
                });
            }
            DraftIntent::Save(text) => {
                // an edit in progress is no draft.
                if matches!(self.mode, ComposerMode::Edit { .. }) {
                    return;
                }
                let (reply, timeline, text) = (
                    self.mode.reply().cloned(),
                    self.timeline(&self.default_room),
                    text.trim().to_owned(),
                );
                self.act(Target::Draft(timeline.clone()), move |backend| async move {
                    backend.timelines().save_draft(&timeline, &text, reply.as_ref()).await
                });
            }
        }
    }

    /// A message's menu: the action goes to the message's room.
    fn message_action(&mut self, action: MessageAction) {
        match action {
            MessageAction::ToggleReaction(message, key) => {
                let room = self.room_of(&message);
                self.act(Target::Message(message.clone()), move |backend| async move {
                    backend.timelines().toggle_reaction(&room, &message, &key).await
                });
            }
            MessageAction::Delete(message) => {
                let room = self.room_of(&message);
                self.act(Target::Message(message.clone()), move |backend| async move {
                    backend.timelines().delete(&room, &message).await
                });
            }
            MessageAction::Retry(message) => {
                let room = self.room_of(&message);
                self.act(Target::Message(message.clone()), move |backend| async move {
                    backend.timelines().retry(&room, &message).await
                });
            }
            MessageAction::Discard(message) => {
                let room = self.room_of(&message);
                self.act(Target::Message(message.clone()), move |backend| async move {
                    backend.timelines().discard(&room, &message).await
                });
            }
            MessageAction::Forward(message, target) => {
                let room = self.room_of(&message);
                self.act(Target::Message(message.clone()), move |backend| async move {
                    backend.timelines().forward(&room, &message, &target).await
                });
            }
            MessageAction::Save(message) => self.saved(&message, true),
            MessageAction::Unsave(message) => self.saved(&message, false),
        }
    }

    /// Shows more of the shown rooms' older messages: those their timelines hold at once, the
    /// rest as the server's pages come in.
    fn load_older(&mut self) {
        if self.older_due() || self.paging > 0 || self.shows_start() {
            return;
        }
        let shown: Vec<usize> = self.shown_rooms().collect();
        for index in shown {
            let timeline = self.timeline(&self.rooms[index].room.id);
            let room = &mut self.rooms[index];
            room.older_due = OLDER;
            let missing = OLDER.saturating_sub(room.held_before());
            if missing == 0 || room.at_start {
                continue;
            }
            room.paging = true;
            self.paging += 1;
            let (backend, events, listener, id) = (
                Arc::clone(&self.backend),
                self.events.clone(),
                Arc::clone(&self.listener),
                timeline,
            );
            self.followers.spawn(async move {
                let timelines = backend.timelines();
                let paged = match timelines.load_older(&id, missing).await {
                    Ok(()) => timelines.is_at_start(&id).await,
                    Err(error) => Err(error),
                };
                let at_start = paged.map_err(|error| listener.on_error(error)).ok();
                let _ = events.send(Event::Paged(index, at_start));
            });
        }
        self.dirty.rows = true;
        self.dirty.state = true;
    }

    /// Older messages are still going in, a few a frame.
    fn older_due(&self) -> bool {
        self.rooms.iter().any(|room| room.older_due > 0)
    }

    /// Brings the message `message` answers into the thread.
    fn jump_to_replied(&mut self, message: &MessageId, answer: oneshot::Sender<Option<MessageId>>) {
        let replied = self.rooms.iter().enumerate().find_map(|(index, room)| {
            room.message(message)
                .and_then(|message| message.reply.as_ref())
                .map(|quote| (index, quote.event_id.clone()))
        });
        match replied {
            Some((index, event)) => self.jump(vec![index], event, answer),
            None => {
                let _ = answer.send(None);
            }
        }
    }

    /// Brings the message of `event` into the thread, from the first of `rooms` that has it.
    fn jump(&mut self, rooms: Vec<usize>, event: EventId, answer: oneshot::Sender<Option<MessageId>>) {
        for &index in &rooms {
            if let Some(id) = self.rooms[index].find_event(&event) {
                self.rooms[index].reveal(&id);
                self.dirty.rows = true;
                self.jumped.push((id, answer));
                return;
            }
        }
        self.jumping += 1;
        self.dirty.state = true;
        let ids: Vec<(usize, TimelineId)> = rooms
            .into_iter()
            .map(|index| (index, self.timeline(&self.rooms[index].room.id)))
            .collect();
        let (backend, events, listener) = (
            Arc::clone(&self.backend),
            self.events.clone(),
            Arc::clone(&self.listener),
        );
        self.followers.spawn(async move {
            let mut found = None;
            for (index, room) in ids {
                match backend.timelines().show_event(&room, &event).await {
                    Ok(Some(id)) => {
                        found = Some((index, id));
                        break;
                    }
                    Ok(None) => {}
                    Err(error) => listener.on_error(error),
                }
            }
            let _ = events.send(Event::Found(found, answer));
        });
    }

    fn show_room(&mut self, room: Option<&RoomId>) {
        let index = match room {
            None => None,
            Some(room) => match self.rooms.iter().position(|known| &known.room.id == room) {
                Some(index) => Some(index),
                None => return,
            },
        };
        if index == self.shown {
            return;
        }
        self.shown = index;
        self.dirty.rows = true;
        self.dirty.state = true;
        if self.watching.is_some() {
            self.end_typing();
            self.watch_typing();
        }
    }

    fn set_mode(&mut self, mode: ComposerMode) {
        self.mode = mode;
        self.dirty.state = true;
    }

    /// Sends what the composer holds: waiting files first (an edit sends none), the text as the
    /// first one's caption; else the text as the mode says.
    fn send(&mut self, text: &str, via: Option<RoomId>) {
        let editing = matches!(self.mode, ComposerMode::Edit { .. });
        if !self.pending_files.is_empty() && !editing {
            let reply = self.mode.reply().cloned();
            self.set_mode(ComposerMode::Message);
            self.composer_changed("");
            // an answer goes to its message's room; a new message to the one chosen.
            let room = match &reply {
                Some(reply) => self.reply_room(reply),
                None => via.unwrap_or_else(|| self.send_room.clone()),
            };
            let upload = Upload {
                files: mem::take(&mut self.pending_files),
                room,
                caption: (!text.is_empty()).then(|| text.to_owned()),
                reply,
                thread: self.root.clone(),
            };
            self.listener.on_upload(upload);
            return;
        }
        if text.is_empty() {
            return;
        }
        let mode = mem::take(&mut self.mode);
        self.dirty.state = true;
        self.composer_changed("");
        let text = text.to_owned();
        match mode {
            ComposerMode::Message => {
                let room = via.unwrap_or_else(|| self.send_room.clone());
                let timeline = self.timeline(&room);
                self.act(Target::Sends(room), move |backend| async move {
                    backend.timelines().send_text(&timeline, &text, None).await
                });
            }
            ComposerMode::Reply(target) => {
                let room = self.reply_room(&target.message);
                let timeline = self.timeline(&room);
                self.act(Target::Sends(room), move |backend| async move {
                    backend
                        .timelines()
                        .send_text(&timeline, &text, Some(&target.message))
                        .await
                });
            }
            ComposerMode::Edit { message, original } => {
                if text != original {
                    let room = self.room_of(&message);
                    self.act(Target::Message(message.clone()), move |backend| async move {
                        backend.timelines().edit(&room, &message, &text).await
                    });
                }
            }
        }
    }

    fn send_later(&mut self, text: &str, at: std::time::SystemTime, answer: oneshot::Sender<Result<(), BackendError>>) {
        if text.is_empty() {
            let _ = answer.send(Ok(()));
            return;
        }
        let reply = self.mode.reply().cloned();
        let room = reply
            .as_ref()
            .map_or_else(|| self.send_room.clone(), |reply| self.reply_room(reply));
        let reply = reply.and_then(|reply| self.reply_event(&reply));
        self.set_mode(ComposerMode::Message);
        let (backend, text) = (Arc::clone(&self.backend), text.to_owned());
        self.actions.push(Target::Sends(room.clone()), async move {
            let _ = answer.send(backend.send_later(&room, &text, reply.as_ref(), at).await.map(drop));
        });
    }

    fn saved(&mut self, message: &MessageId, saved: bool) {
        let room = self.room_of(message);
        let Some(event) = self.message(message).and_then(|found| found.event_id.clone()) else {
            // only a message the server has can be saved.
            self.listener.on_error(BackendError::NotSavable);
            return;
        };
        self.act(Target::Message(message.clone()), move |backend| async move {
            if saved {
                backend.save_message(&room, &event).await
            } else {
                backend.unsave_message(&room, &event).await
            }
        });
    }

    /// Tells the others the chat was read up to its newest message: every room of a merged
    /// chat, since what shows together is read together.
    fn send_read_receipt(&mut self) {
        let latest = self.rows.last().map(|row| row.id().clone());
        if !self.read.read(latest.as_ref()) {
            return;
        }
        self.dirty.state = true;
        // a newer receipt covers an older one: none waits for another, or for any action.
        let timelines: Vec<TimelineId> = self.rooms.iter().map(|room| self.timeline(&room.room.id)).collect();
        for timeline in timelines {
            self.act_now(move |backend| async move { backend.timelines().mark_read(&timeline, Receipt::Public).await });
        }
    }

    // MARK: typing

    fn watch_typing(&mut self) {
        let mut watching = JoinSet::new();
        let shown: Vec<usize> = self.shown_rooms().collect();
        for index in shown {
            match self.backend.timelines().typing(&self.rooms[index].room.id) {
                Ok(mut typing) => {
                    let events = self.events.clone();
                    watching.spawn(async move {
                        while let Some(typists) = typing.next().await {
                            if events.send(Event::Typing(index, typists)).is_err() {
                                break;
                            }
                        }
                    });
                }
                Err(error) => self.listener.on_error(error),
            }
        }
        self.watching = Some(watching);
    }

    fn end_typing(&mut self) {
        self.watching = None;
        self.typing_by_room.clear();
        self.update_typists();
    }

    fn update_typists(&mut self) {
        let rooms: Vec<RoomId> = self
            .shown_rooms()
            .map(|index| self.rooms[index].room.id.clone())
            .collect();
        let typists = decide::typists(rooms.into_iter(), &self.typing_by_room);
        if typists != self.typists {
            self.typists = typists;
            self.dirty.state = true;
        }
    }

    /// The composer's text changed: the others see the user typing, only where the chat tells
    /// them it was read by itself (both show the user is there).
    fn composer_changed(&mut self, text: &str) {
        let typing = !text.is_empty() && self.receipts == ReadReceipts::Automatic;
        if let Some(typing) = self.typing_notice.changed(typing, Instant::now()) {
            let room = self.send_room.clone();
            self.act(Target::Typing(room.clone()), move |backend| async move {
                backend.timelines().set_typing(&room, typing).await
            });
        }
    }

    // MARK: helpers

    /// The timeline of `room` the thread shows: the Matrix thread's, or the room's own.
    fn timeline(&self, room: &RoomId) -> TimelineId {
        TimelineId {
            room: room.clone(),
            thread: self.root.clone(),
        }
    }

    fn shown_rooms(&self) -> impl Iterator<Item = usize> + use<B> {
        let shown = self.shown;
        (0..self.rooms.len()).filter(move |index| shown.is_none_or(|shown| shown == *index))
    }

    /// The message `id`, in any room.
    fn message(&self, id: &MessageId) -> Option<&Arc<TimelineMessage>> {
        self.rooms.iter().find_map(|room| room.message(id))
    }

    /// The room a message is in; the send room when none has it.
    fn room_of(&self, id: &MessageId) -> RoomId {
        self.room_where(|room| room.message(id).is_some())
    }

    /// The room of the message a reply answers; the send room when none has it.
    fn reply_room(&self, reply: &MessageRef) -> RoomId {
        self.room_where(|room| room.find(reply).is_some())
    }

    fn room_where(&self, holds: impl Fn(&RoomMessages) -> bool) -> RoomId {
        self.rooms
            .iter()
            .find(|room| holds(room))
            .map_or_else(|| self.send_room.clone(), |room| room.room.id.clone())
    }

    /// The event id of the message a reply answers, once the server has it.
    fn reply_event(&self, reply: &MessageRef) -> Option<EventId> {
        match reply {
            MessageRef::Local(id) => self.message(id)?.event_id.clone(),
            MessageRef::Event(event) => Some(event.clone()),
        }
    }

    /// Answers the jumps whose messages show now: with the row that shows each, an album's for a
    /// photo in it (the apps scroll to rows).
    fn answer_jumps(&mut self) {
        for (id, answer) in mem::take(&mut self.jumped) {
            let row = self
                .rows
                .iter()
                .find(|row| row.id() == &id || row.album.iter().any(|message| message.message.id == id))
                .map(|row| row.id().clone());
            let _ = answer.send(row.or(Some(id)));
        }
    }

    /// Shows the messages waiting to show whose room now has them, and answers who waits.
    fn reveal_waiting(&mut self) {
        let mut waiting = mem::take(&mut self.reveals);
        waiting.retain_mut(|(id, answer)| {
            if !self.rooms.iter_mut().any(|room| room.reveal(id)) {
                return true;
            }
            self.dirty.rows = true;
            if let Some(answer) = answer.take() {
                self.jumped.push((id.clone(), answer));
            }
            false
        });
        self.reveals = waiting;
    }

    fn refresh_can_send_later(&mut self) {
        // the server's message sent later goes to the room's own timeline, not a Matrix thread.
        if self.root.is_some() {
            return;
        }
        let (backend, events, room) = (Arc::clone(&self.backend), self.events.clone(), self.send_room.clone());
        self.followers.spawn(async move {
            let can = backend.can_send_later(&room).await;
            let _ = events.send(Event::CanSendLater(room, can));
        });
    }

    /// Runs an action on the backend after those asked for before it on `target`; a failure
    /// goes to the listener.
    fn act<F>(&mut self, target: Target, action: impl FnOnce(Arc<B>) -> F)
    where
        F: Future<Output = Result<(), BackendError>> + Send + 'static,
    {
        let job = self.reported(action);
        self.actions.push(target, job);
    }

    /// Runs an action on the backend at once, beside the others; a failure goes to the listener.
    fn act_now<F>(&self, action: impl FnOnce(Arc<B>) -> F)
    where
        F: Future<Output = Result<(), BackendError>> + Send + 'static,
    {
        tokio::spawn(self.reported(action));
    }

    fn reported<F>(&self, action: impl FnOnce(Arc<B>) -> F) -> impl Future<Output = ()> + Send + 'static
    where
        F: Future<Output = Result<(), BackendError>> + Send + 'static,
    {
        let listener = Arc::clone(&self.listener);
        let action = action(Arc::clone(&self.backend));
        async move {
            if let Err(error) = action.await {
                listener.on_error(error);
            }
        }
    }
}
