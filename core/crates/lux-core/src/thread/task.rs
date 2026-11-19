//! The task that owns a thread: the only writer of its state. It takes the user's intents and
//! the backend's events (the rooms' diffs, the answers of what it spawned) in turn, and once a
//! frame, when anything changed, presents the rows and sends their diffs with the state.

use crate::gone::OtherEndGone;
use std::collections::{HashMap, HashSet};
use std::future::Future;
use std::mem;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use eyeball_im::{Vector, VectorDiff};
use futures_util::StreamExt;
use jiff::tz::TimeZone;
use tokio::sync::{mpsc, oneshot};
use tokio::task::JoinSet;
use tokio::time::Instant;

pub(super) mod jump;

use super::decide::{self, ComposerMode, ReadReceipts, ReadState, ReplyTarget, TypingNotice};
use super::rows::{self, OLDER, Phase, RoomMessages, ThreadRow, Unreading};
use super::{
    Cause, DraftIntent, Intent, JumpFailure, MessageAction, ThreadListener, ThreadSpec, ThreadState, ThreadUpdate,
    Upload,
};
use crate::FRAME;
use crate::actions::Actions;
use crate::diff;
use crate::ids::{EventId, MessageId, MessageRef, RoomId, TimelineId};
use crate::merge;
use crate::ports::{BackendError, ChatSending, ChatTimelines, Diffs, ThreadBackend, TimelineHold};
use crate::timeline::{Draft, Focused, Pins, Receipt, TimelineMessage, Typist, Unread};

/// The longest the first rows wait for the rooms' first unread messages: finding one can page
/// back on the server, and a bad connection must not hold back the messages already in. The
/// lookup goes on; its answer still places the marker.
const UNREAD_WAIT: Duration = Duration::from_secs(1);

/// How many pages back a room's first unread message is looked for.
const UNREAD_PAGES: usize = 10;

/// What the backend and the thread's own spawned work tell the task.
enum Event {
    /// A room's messages changed.
    Diffs(usize, Diffs<Arc<TimelineMessage>>),
    /// A room's messages cannot be read: it shows none.
    Unreadable(usize),
    /// Where a room's unread messages start, as far as its timeline holds them.
    Unread(usize, Result<Unread, BackendError>),
    /// Finding the first unread messages takes longer than the first rows wait.
    UnreadSlow,
    /// A page back of a room is in: whether its timeline now holds the room's first message.
    Paged(usize, Result<bool, BackendError>),
    /// Who is typing in a room.
    Typing(usize, Vec<Typist>),
    /// A room's pinned messages.
    Pins(usize, Pins),
    /// Whether the room can have messages sent later.
    CanSendLater(RoomId, bool),
    /// The kept draft.
    Draft(Option<Draft>, oneshot::Sender<String>),
    /// A jump's timeline opened around its message in a room (or did not).
    JumpOpened(u64, usize, TimelineId, Result<Focused, BackendError>, jump::Answer),
    /// A jump's messages changed.
    JumpDiffs(u64, Diffs<Arc<TimelineMessage>>),
    /// A page of a jump's timeline is in, older or newer: whether it reached that end.
    JumpPaged(u64, bool, Option<bool>),
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
    /// A room's rows, held back while its timeline refilled after a reset, show again: no news.
    refilled: bool,
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

#[expect(
    clippy::struct_excessive_bools,
    reason = "the chat's facts, each read on its own: an enum of their mixes would say less"
)]
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
    /// Each room's pinned messages, as last heard.
    pins_by_room: HashMap<RoomId, Pins>,
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
    /// Pages back and jumps under way.
    paging: usize,
    jumping: usize,
    /// Messages to show once their room's timeline has them (the first unread ones).
    reveals: Vec<MessageId>,
    loaded_waiters: Vec<oneshot::Sender<()>>,
    unread_waiters: Vec<oneshot::Sender<Option<MessageId>>>,
    send_room: RoomId,
    can_send_later: bool,
    /// The user sent a message (or files) whose local echo the rows do not show yet.
    sending: bool,
    /// The backend actions, in the order asked for on each target.
    actions: Actions<Target>,
    /// The jumps to messages the live rows do not hold.
    jumps: jump::Jumps,
    /// Where the jumps landed, for the next update: its rows are those that show them.
    answers: mpsc::UnboundedSender<super::JumpAnswer>,
    answered: mpsc::UnboundedReceiver<super::JumpAnswer>,
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
        let (answers, answered) = mpsc::unbounded_channel();
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
            rooms,
            shown: None,
            unfolded: rows::Unfolded::default(),
            mode: ComposerMode::Message,
            pending_files: Vec::new(),
            read: ReadState::default(),
            typing_notice: TypingNotice::default(),
            typing_by_room: HashMap::new(),
            typists: Vec::new(),
            pins_by_room: HashMap::new(),
            watching: None,
            followers: JoinSet::new(),
            holds: Vec::new(),
            rows: Vec::new(),
            sent: None,
            dirty: Dirty {
                rows: true,
                state: true,
                refilled: false,
            },
            unread_found: None,
            unread_slow: false,
            first_unread: FirstUnread::Undecided,
            paging: 0,
            jumping: 0,
            reveals: Vec::new(),
            loaded_waiters: Vec::new(),
            unread_waiters: Vec::new(),
            can_send_later: false,
            sending: false,
            actions: Actions::new(),
            jumps: jump::Jumps::default(),
            answers,
            answered,
        }
    }

    // MARK: opening

    /// Holds the rooms' timelines and follows their messages; each room's first list asks for
    /// its first unread message and starts its opening fill.
    fn open(&mut self) {
        self.follow_pins();
        let ids: Vec<TimelineId> = self.rooms.iter().map(|room| self.timeline(&room.room.id)).collect();
        for (index, id) in ids.into_iter().enumerate() {
            self.holds.push(self.backend.timelines().hold(&id));
            let (backend, events, listener) = (
                Arc::clone(&self.backend),
                self.events.clone(),
                Arc::clone(&self.listener),
            );
            self.followers.spawn(async move {
                match backend.timelines().messages(&id).await {
                    Ok(mut batches) => {
                        while let Some(batch) = batches.next().await {
                            if events.send(Event::Diffs(index, batch)).is_err() {
                                break;
                            }
                        }
                    }
                    Err(error) => {
                        listener.on_error(error);
                        events
                            .send(Event::Unreadable(index))
                            .other_end_may_be_gone("the thread's task");
                    }
                }
            });
        }
        let events = self.events.clone();
        self.followers.spawn(async move {
            // the rows go without the first unread message after this; the marker follows.
            tokio::time::sleep(UNREAD_WAIT).await;
            events
                .send(Event::UnreadSlow)
                .other_end_may_be_gone("the thread's task");
        });
        self.refresh_can_send_later();
    }

    // MARK: the loop's steps

    /// The first rows wait for every room's messages and, for a while, the first unread one.
    fn ready(&self) -> bool {
        (self.unread_found.is_some() || self.unread_slow) && self.rooms.iter().all(|room| room.phase != Phase::Waiting)
    }

    fn wants_frame(&self) -> bool {
        self.ready() && (self.dirty.rows || self.dirty.state || !self.answered.is_empty())
    }

    fn event(&mut self, event: Event) {
        match event {
            Event::Diffs(index, diffs) => self.room_changed(index, diffs),
            Event::Unreadable(index) => {
                if let Some(room) = self.rooms.get_mut(index) {
                    room.phase = Phase::Live;
                    room.unread = Unreading::Found(None);
                }
                self.unread_answered();
                self.answer_loaded();
                self.dirty.rows = true;
            }
            Event::Unread(index, answer) => {
                if let Some(room) = self.rooms.get_mut(index)
                    && let Unreading::Asking(pages) = room.unread
                {
                    room.unread = match answer {
                        Ok(unread) if !unread.complete && !room.at_start && pages < UNREAD_PAGES => {
                            Unreading::PageDue(pages + 1)
                        }
                        Ok(unread) => Unreading::Found(unread.first),
                        // the chat opens at the bottom.
                        Err(_) => Unreading::Found(None),
                    };
                }
                self.unread_answered();
                self.page_where_due();
            }
            Event::UnreadSlow => {
                if self.unread_found.is_none() {
                    self.unread_slow = true;
                    self.dirty.rows = true;
                }
            }
            Event::Paged(index, paged) => self.paged(index, paged),
            Event::Pins(index, pins) => {
                if let Some(room) = self.rooms.get(index)
                    && self.pins_by_room.get(&room.room.id) != Some(&pins)
                {
                    self.pins_by_room.insert(room.room.id.clone(), pins);
                    self.dirty.state = true;
                }
            }
            Event::Typing(index, typists) => {
                if let Some(room) = self.rooms.get(index) {
                    self.typing_by_room.insert(room.room.id.clone(), typists);
                }
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
                answer.send(draft.text).other_end_may_be_gone("the caller");
            }
            Event::JumpOpened(generation, index, id, focused, answer) => {
                self.jump_opened(generation, index, id, focused, answer);
            }
            Event::JumpDiffs(generation, diffs) => self.jump_diffs(generation, diffs),
            Event::JumpPaged(generation, older, reached) => self.jump_paged(generation, older, reached),
        }
    }

    /// A room's messages changed: its first list opens it (its first unread message asked for,
    /// its fill begun); a reset that took rows the reader sees holds them until the room has
    /// them again.
    fn room_changed(&mut self, index: usize, diffs: Diffs<Arc<TimelineMessage>>) {
        let shown = self.sent.is_some();
        if let Some(room) = self.rooms.get_mut(index) {
            let opening = room.phase == Phase::Waiting;
            if let Some(first) = room.apply(diffs)
                && shown
                && matches!(room.phase, Phase::Filling | Phase::Live)
            {
                room.phase = Phase::Refilling { first, paged: false };
            }
            if opening {
                self.ask_unread(index);
            }
        }
        self.reveal_waiting();
        self.dirty.rows = true;
        self.retry_waiting_jumps();
        self.try_return();
        // its batch is in: the room's next page, if one is due, goes now.
        self.page_where_due();
    }

    /// A page back of a room is in, or failed. Its messages may come after its answer: the next
    /// page waits a frame.
    fn paged(&mut self, index: usize, paged: Result<bool, BackendError>) {
        if let Some(room) = self.rooms.get_mut(index) {
            room.paging = false;
            match paged {
                Ok(at_start) => room.at_start |= at_start,
                Err(error) => {
                    // only the user's own paging tells: the opening's ends quietly.
                    if room.older_due > 0 {
                        self.listener.on_error(error);
                    }
                    if room.phase == Phase::Filling {
                        room.phase = Phase::Live;
                    }
                    if let Unreading::Paging(_) = room.unread {
                        room.unread = Unreading::Paging(UNREAD_PAGES);
                    }
                }
            }
        }
        self.dirty.rows = true;
        self.paging = self.paging.saturating_sub(1);
        self.dirty.state = true;
        self.try_return();
    }

    /// Sends the frame's changes: the rows presented anew and diffed against those sent, why
    /// they changed, and the state if it changed. The first frame sends all the rows, even none.
    /// While a shown room refills after a reset, its rows stay as they were.
    fn flush(&mut self) {
        if !self.ready() {
            return;
        }
        self.page_where_due();
        let first = self.sent.is_none();
        let refilling = !self.is_detached()
            && self.shown_rooms().any(|index| {
                matches!(
                    self.rooms.get(index).map(|room| &room.phase),
                    Some(Phase::Refilling { .. })
                )
            });
        let mut update = ThreadUpdate::default();
        if refilling && !first {
            // its batches and its page's answer call for the frame that shows it again.
            self.dirty.rows = false;
        } else if self.dirty.rows || first {
            self.dirty.rows = false;
            // whether the rows switch, or older messages are coming in: no news either way.
            let switched = self
                .sent
                .as_ref()
                .is_some_and(|sent| sent.is_live == self.is_detached());
            let paging = self.rooms.iter().any(|room| room.paging || room.older_due > 0);
            let merged = self.rooms.len() > 1;
            self.unfold_landed();
            let apart = self.unread_start();
            let rows = if let Some(detached) = self.jumps.detached.as_mut() {
                detached.messages.reveal_older();
                rows::present(
                    std::slice::from_mut(&mut detached.messages),
                    None,
                    merged,
                    &self.unfolded,
                    &apart,
                    &self.zone,
                )
            } else {
                for room in &mut self.rooms {
                    room.reveal_older();
                }
                rows::present(&mut self.rooms, self.shown, merged, &self.unfolded, &apart, &self.zone)
            };
            update.rows = if first {
                vec![VectorDiff::Reset {
                    values: rows.iter().cloned().collect::<Vector<_>>(),
                }]
            } else {
                diff::changes(&self.rows, &rows, |row| row.id())
            };
            let before = mem::replace(&mut self.rows, rows);
            let refilled = mem::take(&mut self.dirty.refilled);
            if !update.rows.is_empty() {
                update.cause = self.cause(&before, switched || refilled || paging);
            }
            self.answer_landed();
            self.after_rows();
        }
        // the jumps answered: with the rows that show them, never before.
        while let Ok(answer) = self.answered.try_recv() {
            update.jumped.push(answer);
        }
        self.dirty.state = false;
        let state = self.state();
        if self.sent.as_ref() != Some(&state) {
            update.state = Some(state.clone());
            self.sent = Some(state);
        }
        if first || !update.rows.is_empty() || update.state.is_some() || !update.jumped.is_empty() {
            self.listener.on_update(update);
        }
    }

    /// Why the live rows changed from `before`: the local echo of what the user sent is the
    /// newest row; or messages arrived after the newest one shown, unless the rows switched,
    /// refilled or took a page (`quiet`), which bring no news.
    fn cause(&mut self, before: &[Arc<ThreadRow>], quiet: bool) -> Option<Cause> {
        if self.is_detached() {
            return None;
        }
        let newest = self.rows.last()?;
        let latest = newest.latest();
        let shown_before = |id: &MessageId| before.iter().rev().any(|row| row.shows(id));
        if self.sending && latest.is_own && !shown_before(&latest.message.id) {
            self.sending = false;
            return Some(Cause::Sent(newest.id().clone()));
        }
        let was_newest = &before.last()?.latest().message.id;
        let arrived =
            !quiet && latest.message.id != *was_newest && self.rows.iter().rev().any(|row| row.shows(was_newest));
        arrived.then_some(Cause::Arrived)
    }

    /// Asks for each room's next page back where one is due (its opening fill, its refill after
    /// a reset, its first unread message), and for the first unread message again once a page
    /// for it is in.
    fn page_where_due(&mut self) {
        for index in 0..self.rooms.len() {
            let Some(room) = self.rooms.get_mut(index) else {
                continue;
            };
            if !room.paging
                && let Unreading::Paging(pages) = room.unread
            {
                room.unread = Unreading::Asking(pages);
                self.ask_unread(index);
            }
            let Some(room) = self.rooms.get_mut(index) else {
                continue;
            };
            let refilling = matches!(room.phase, Phase::Refilling { .. });
            let due = room.page_due();
            if refilling && !matches!(room.phase, Phase::Refilling { .. }) {
                self.dirty.refilled = true;
                self.dirty.rows = true;
            }
            if let Some(count) = due {
                self.page(index, count);
            }
        }
        self.answer_loaded();
    }

    /// One page back of the room at `index`, of `count` messages; its answer comes as an event.
    fn page(&mut self, index: usize, count: usize) {
        let Some(room) = self.rooms.get_mut(index) else { return };
        room.paging = true;
        let id = TimelineId {
            room: room.room.id.clone(),
            thread: self.root.clone(),
            at: None,
        };
        self.paging += 1;
        self.dirty.state = true;
        let (backend, events) = (Arc::clone(&self.backend), self.events.clone());
        self.followers.spawn(async move {
            let paged = backend.timelines().load_older(&id, count).await;
            events
                .send(Event::Paged(index, paged))
                .other_end_may_be_gone("the thread's task");
        });
    }

    /// Asks where the room's unread messages start, from what its timeline holds now.
    fn ask_unread(&mut self, index: usize) {
        let Some(room) = self.rooms.get(index) else { return };
        let (backend, events, id) = (
            Arc::clone(&self.backend),
            self.events.clone(),
            self.timeline(&room.room.id),
        );
        self.followers.spawn(async move {
            let unread = backend.timelines().first_unread(&id).await;
            events
                .send(Event::Unread(index, unread))
                .other_end_may_be_gone("the thread's task");
        });
    }

    /// Every room's first unread message is found: they decide where the marker goes.
    fn unread_answered(&mut self) {
        if self.unread_found.is_some() {
            return;
        }
        let found: Option<Vec<Option<MessageId>>> = self
            .rooms
            .iter()
            .map(|room| match &room.unread {
                Unreading::Found(first) => Some(first.clone()),
                _ => None,
            })
            .collect();
        let Some(found) = found else { return };
        let found: Vec<MessageId> = found.into_iter().flatten().collect();
        self.reveals.extend(found.iter().cloned());
        self.unread_found = Some(found);
        self.reveal_waiting();
        self.dirty.rows = true;
    }

    /// Answers those waiting for the opening fill, once every room's is in.
    fn answer_loaded(&mut self) {
        if self
            .rooms
            .iter()
            .all(|room| !matches!(room.phase, Phase::Waiting | Phase::Filling))
        {
            for waiter in self.loaded_waiters.drain(..) {
                waiter.send(()).other_end_may_be_gone("the caller");
            }
        }
    }

    /// What follows from new rows: the first unread message (with the first rows, or once
    /// found), the room a new message goes to, the read state.
    fn after_rows(&mut self) {
        self.decide_first_unread();
        let shown = self
            .shown
            .and_then(|index| self.rooms.get(index))
            .map(|room| &room.room.id);
        let send_room =
            merge::send_room(shown, self.rows.iter().map(|row| Some(&row.room)), &self.default_room).clone();
        if send_room != self.send_room {
            self.send_room = send_room;
            self.refresh_can_send_later();
        }
        // a jump's rows are not the newest: what they show says nothing of what was read.
        if !self.is_detached() {
            self.read.update(self.rows.last().map(|row| {
                let latest = row.latest();
                (&latest.message.id, latest.is_own)
            }));
        }
    }

    /// The messages where the unread ones may start, each to begin a row of its own (not folded
    /// into a run of deleted ones), so the marker can go above it: the one decided, or, until
    /// then, each room's first unread message.
    fn unread_start(&self) -> HashSet<MessageId> {
        match &self.first_unread {
            FirstUnread::Decided(first) => first.iter().cloned().collect(),
            FirstUnread::Undecided | FirstUnread::Late => self.unread_found.iter().flatten().cloned().collect(),
        }
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
                    waiter.send(None).other_end_may_be_gone("the caller");
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
            waiter.send(first.clone()).other_end_may_be_gone("the caller");
        }
        self.first_unread = FirstUnread::Decided(first);
    }

    /// The chat's first message shows: every room shown shows its first.
    fn shows_start(&mut self) -> bool {
        if let Some(detached) = self.jumps.detached.as_mut() {
            return detached.messages.shows_start();
        }
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
            is_loading: self.paging > 0 || self.jumping > 0,
            can_load_older: self.paging == 0 && !self.older_due() && !at_start,
            is_at_start: at_start,
            first_unread: match &self.first_unread {
                FirstUnread::Decided(first) => first.clone(),
                FirstUnread::Undecided | FirstUnread::Late => None,
            },
            needs_read_receipt: self.read.needs_receipt,
            typists: self.typists.clone(),
            shown_room: shown
                .and_then(|index| self.rooms.get(index))
                .map(|room| room.room.id.clone()),
            send_room: self.send_room.clone(),
            mode: self.mode.clone(),
            pending_files: self.pending_files.clone(),
            can_send_later: self.can_send_later,
            is_live: !self.is_detached(),
            can_load_newer: self.jumps.detached.as_ref().is_some_and(jump::Detached::can_load_newer),
            pinned: self
                .shown_pins()
                .flat_map(|pins| pins.messages.iter().cloned())
                .collect(),
            may_pin_in: self
                .shown_rooms()
                .filter_map(|index| self.rooms.get(index))
                .filter(|room| self.pins_by_room.get(&room.room.id).is_some_and(|pins| pins.may_pin))
                .map(|room| room.room.id.clone())
                .collect(),
            new_pin: self
                .shown_pins()
                .filter_map(Pins::newest_unseen)
                .max_by_key(|pin| pin.date)
                .cloned(),
        }
    }

    /// The pins of the rooms shown are seen: each room's pinned events, as its pins have them.
    fn pins_seen(&mut self) {
        let rooms: Vec<(RoomId, Vec<EventId>)> = self
            .shown_rooms()
            .filter_map(|index| self.rooms.get(index))
            .filter_map(|room| {
                let pins = self.pins_by_room.get(&room.room.id)?;
                pins.newest_unseen()?;
                Some((
                    room.room.id.clone(),
                    pins.messages.iter().map(|pin| pin.event.clone()).collect(),
                ))
            })
            .collect();
        for (room, events) in rooms {
            self.act_now(move |backend| async move { backend.timelines().mark_pins_seen(&room, &events).await });
        }
    }

    /// The shown rooms' pins, in the rooms' order.
    fn shown_pins(&self) -> impl Iterator<Item = &Pins> {
        self.shown_rooms()
            .filter_map(|index| self.rooms.get(index))
            .filter_map(|room| self.pins_by_room.get(&room.room.id))
    }

    // MARK: intents

    fn intent(&mut self, intent: Intent) {
        match intent {
            Intent::LoadOlder => self.load_older(),
            Intent::Jump(room, event, jump) => {
                let answer = jump::Answer::new(jump, self.answers.clone());
                self.jump_to(room, event, answer);
            }
            Intent::LoadNewer => self.load_newer(),
            Intent::ReturnToLive => self.leave_detached(),
            Intent::SetAnchor(message) => self.jumps.anchor = Some(message),
            Intent::JumpToReplied(message, jump) => {
                let answer = jump::Answer::new(jump, self.answers.clone());
                self.jump_to_replied(&message, answer);
            }
            Intent::FirstUnread(answer) => match &self.first_unread {
                FirstUnread::Decided(first) => {
                    answer.send(first.clone()).other_end_may_be_gone("the caller");
                }
                FirstUnread::Late => {
                    answer.send(None).other_end_may_be_gone("the caller");
                }
                FirstUnread::Undecided => self.unread_waiters.push(answer),
            },
            Intent::Loaded(answer) => {
                self.loaded_waiters.push(answer);
                self.answer_loaded();
            }
            Intent::ToggleDetail(message) => {
                rows::Unfolded::toggle(&mut self.unfolded.details, message);
                self.dirty.rows = true;
            }
            Intent::TogglePost(message) => {
                rows::Unfolded::toggle(&mut self.unfolded.posts, message);
                self.dirty.rows = true;
            }
            Intent::UnfoldDeleted(message) => {
                self.dirty.rows |= self.unfolded.deleted.insert(message);
            }
            Intent::ShowRoom(room) => {
                // another room filter is the live rows'.
                self.leave_detached();
                self.show_room(room.as_ref());
            }
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
            Intent::Send { text, via } => {
                // what is sent shows among the live rows.
                self.leave_detached();
                self.send(text.trim(), via);
            }
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
            // a jump's rows are not the newest: nothing is read from them.
            Intent::DidReadLatest | Intent::SendReadReceipt if self.is_detached() => {}
            Intent::DidReadLatest => {
                if self.receipts == ReadReceipts::Automatic {
                    self.send_read_receipt();
                }
            }
            Intent::SendReadReceipt => self.send_read_receipt(),
            Intent::SetReadReceipts(receipts) => self.receipts = receipts,
            Intent::PinsSeen => self.pins_seen(),
            Intent::Unpin(room, event) => {
                self.act_now(move |backend| async move { backend.timelines().set_pinned(&room, &event, false).await });
            }
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
                    events
                        .send(Event::Draft(draft, answer))
                        .other_end_may_be_gone("the thread's task");
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
            MessageAction::Pin(message, pinned) => self.pinned(&message, pinned),
        }
    }

    fn pinned(&mut self, message: &MessageId, pinned: bool) {
        let room = self.room_of(message);
        let Some(event) = self.message(message).and_then(|found| found.event_id.clone()) else {
            // only a message the server has can be pinned.
            self.listener.on_error(BackendError::NotAllowed);
            return;
        };
        self.act(Target::Message(message.clone()), move |backend| async move {
            backend.timelines().set_pinned(&room, &event, pinned).await
        });
    }

    /// Follows each room's pinned messages, for the chat's own view (a Matrix thread's shows none).
    fn follow_pins(&mut self) {
        if self.root.is_some() {
            return;
        }
        for (index, room) in self.rooms.iter().enumerate() {
            match self.backend.timelines().pins(&room.room.id) {
                Ok(mut pins) => {
                    let events = self.events.clone();
                    self.followers.spawn(async move {
                        while let Some(next) = pins.next().await {
                            if events.send(Event::Pins(index, next)).is_err() {
                                break;
                            }
                        }
                    });
                }
                Err(error) => self.listener.on_error(error),
            }
        }
    }

    /// Shows more of the shown rooms' older messages: those their timelines hold at once, the
    /// rest as the server's pages come in.
    fn load_older(&mut self) {
        if self.load_older_detached() {
            return;
        }
        if self.older_due() || self.paging > 0 || self.shows_start() {
            return;
        }
        let shown: Vec<usize> = self.shown_rooms().collect();
        for index in shown {
            let Some(room) = self.rooms.get_mut(index) else {
                continue;
            };
            room.older_due = OLDER;
            let missing = OLDER.saturating_sub(room.held_before());
            if missing > 0 && !room.at_start && !room.paging {
                self.page(index, missing);
            }
        }
        self.dirty.rows = true;
        self.dirty.state = true;
    }

    /// Older messages are still going in, a few a frame.
    fn older_due(&self) -> bool {
        match &self.jumps.detached {
            Some(detached) => detached.messages.older_due > 0,
            None => self.rooms.iter().any(|room| room.older_due > 0),
        }
    }

    /// Brings the message `message` answers into the thread, from the quote's room.
    fn jump_to_replied(&mut self, message: &MessageId, answer: jump::Answer) {
        let replied = self.message(message).and_then(|found| {
            let event = found.reply.as_ref()?.event_id.clone();
            Some((self.room_of(message), event))
        });
        match replied {
            Some((room, event)) => self.jump_to(room, event, answer),
            None => {
                answer
                    .send(Err(JumpFailure::NotFound))
                    .other_end_may_be_gone("the caller");
            }
        }
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
            self.sending = true;
            return;
        }
        if text.is_empty() {
            return;
        }
        let mode = mem::take(&mut self.mode);
        self.dirty.state = true;
        self.composer_changed("");
        let text = text.to_owned();
        // a new message comes back as the newest row, its local echo; an edit changes its row.
        self.sending |= !matches!(mode, ComposerMode::Edit { .. });
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
            answer.send(Ok(())).other_end_may_be_gone("the caller");
            return;
        }
        let reply = self.mode.reply().cloned();
        let room = reply
            .as_ref()
            .map_or_else(|| self.send_room.clone(), |reply| self.reply_room(reply));
        let reply = reply.and_then(|reply| self.reply_event(&reply));
        self.set_mode(ComposerMode::Message);
        let (backend, listener, text) = (Arc::clone(&self.backend), Arc::clone(&self.listener), text.to_owned());
        self.actions.push(Target::Sends(room.clone()), async move {
            let sent = backend.send_later(&room, &text, reply.as_ref(), at).await.map(drop);
            // the caller stopped waiting: its failure is the thread's to show.
            if let Err(Err(error)) = answer.send(sent) {
                listener.on_error(error);
            }
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
        let latest = self.rows.last().map(|row| row.latest().message.id.clone());
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
            let Some(room) = self.rooms.get(index) else { continue };
            match self.backend.timelines().typing(&room.room.id) {
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
            .filter_map(|index| self.rooms.get(index).map(|room| room.room.id.clone()))
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
            at: None,
        }
    }

    fn shown_rooms(&self) -> impl Iterator<Item = usize> + use<B> {
        let shown = self.shown;
        (0..self.rooms.len()).filter(move |index| shown.is_none_or(|shown| shown == *index))
    }

    /// The message `id`, in any room.
    fn message(&self, id: &MessageId) -> Option<&Arc<TimelineMessage>> {
        self.rooms
            .iter()
            .chain(self.jumps.detached.as_ref().map(|detached| &detached.messages))
            .find_map(|room| room.message(id))
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
            .chain(self.jumps.detached.as_ref().map(|detached| &detached.messages))
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

    /// The row that shows the message `id`: its own, or its album's or run's.
    fn row_of(&self, id: &MessageId) -> Option<MessageId> {
        self.rows.iter().find(|row| row.shows(id)).map(|row| row.id().clone())
    }

    /// Shows the messages waiting to show whose room now has them.
    fn reveal_waiting(&mut self) {
        let mut waiting = mem::take(&mut self.reveals);
        waiting.retain(|id| {
            if !self.rooms.iter_mut().any(|room| room.reveal(id)) {
                return true;
            }
            self.dirty.rows = true;
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
            events
                .send(Event::CanSendLater(room, can))
                .other_end_may_be_gone("the thread's task");
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
        #[expect(
            clippy::disallowed_methods,
            reason = "a user's action runs to its end, even once the view that asked for it has closed"
        )]
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
