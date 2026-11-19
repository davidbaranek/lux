//! A jump to a message the live rows do not hold. The rows show it among its neighbours, from a
//! timeline the backend opens around it (one request), while the live timelines go on underneath.
//! They are live again when the user returns ("jump to bottom", sending, all rooms of a merged
//! chat), or when paging forward reaches the newest. Then the switch keeps the reader's row: it
//! waits until the live rows hold that message too (a message has the same id in both), paging
//! the live timeline back once, a bounded number of messages, if they do not yet. A page's answer
//! can come before its messages do, so the switch is decided by the live batches themselves,
//! never by the page's end.

use crate::gone::OtherEndGone;
use std::mem;
use std::sync::Arc;

use futures_util::StreamExt;
use tokio::sync::mpsc;

use super::{Event, Thread};
use crate::ids::{EventId, MessageId, RoomId, TimelineId};
use crate::ports::{BackendError, ChatTimelines, Diffs, ThreadBackend, TimelineHold};
use crate::thread::rows::{OLDER, Phase, RETURN_MARGIN, RoomMessages};
use crate::thread::{JumpAnswer, JumpFailure, Jumped};
use crate::timeline::{Focused, TimelineMessage};

/// Who waits for a jump: the app, told with the next update the task sends, after its rows.
pub(in crate::thread) struct Answer {
    jump: u64,
    to: mpsc::UnboundedSender<JumpAnswer>,
}

impl Answer {
    pub(in crate::thread) fn new(jump: u64, to: mpsc::UnboundedSender<JumpAnswer>) -> Self {
        Self { jump, to }
    }

    /// Where the jump landed, or why not, for the next update.
    pub(in crate::thread) fn send(
        self,
        landed: Result<Jumped, JumpFailure>,
    ) -> Result<(), mpsc::error::SendError<JumpAnswer>> {
        self.to.send(JumpAnswer {
            jump: self.jump,
            landed,
        })
    }
}

/// The thread's jumps: the one shown, the one opening, the way back.
#[derive(Default)]
pub(in crate::thread) struct Jumps {
    /// Bumped by each jump that opens a timeline: an older one's answers are stale.
    generation: u64,
    /// The jump shown instead of the live rows.
    pub(in crate::thread) detached: Option<Detached>,
    /// The timeline of the jump opening, kept open until it shows (or is dropped).
    opening: Option<(u64, TimelineHold)>,
    /// The jump's message, shown once the jump's messages hold it, and who waits for it.
    landing: Option<(MessageId, Answer)>,
    /// Jumps whose message shows: answered with their rows once the rows are presented.
    landed: Vec<(MessageId, Answer)>,
    /// Jumps asked for before their room's live messages came.
    waiting: Vec<(RoomId, EventId, Answer)>,
    /// The row the reader looks at, as the app last said.
    pub(in crate::thread) anchor: Option<MessageId>,
    /// Paging forward reached the newest: the switch waits for the live rows to hold this.
    returning: Option<Returning>,
}

/// A jump's rows: one room's timeline opened around a message.
pub(in crate::thread) struct Detached {
    generation: u64,
    /// The room, by its position in the thread's rooms.
    pub(in crate::thread) index: usize,
    id: TimelineId,
    pub(in crate::thread) messages: RoomMessages,
    _hold: TimelineHold,
    /// It holds the newest message.
    at_end: bool,
    /// A page forward is on the server's way.
    paging_newer: bool,
    /// The merged chat's room filter before the jump, restored on returning.
    shown_before: Option<usize>,
}

impl Detached {
    pub(in crate::thread) fn can_load_newer(&self) -> bool {
        !self.at_end && !self.paging_newer
    }
}

/// The switch back to the live rows, waiting for them to hold the reader's message.
struct Returning {
    /// The reader's message.
    message: MessageId,
    /// How many messages the live timeline is paged back for it, once; 0 once asked for.
    budget: usize,
}

/// What a jump's failure is to the user.
fn failure(error: &BackendError) -> JumpFailure {
    match error {
        BackendError::UnknownMessage => JumpFailure::NotFound,
        BackendError::NotAllowed => JumpFailure::NotAllowed,
        _ => JumpFailure::Failed,
    }
}

impl<B: ThreadBackend> Thread<B> {
    /// Brings the message of `event` in `room` into the rows: the jump's rows already hold it,
    /// or the live ones do, or a timeline opens around it.
    pub(super) fn jump_to(&mut self, room: RoomId, event: EventId, answer: Answer) {
        let Some(index) = self.rooms.iter().position(|known| known.room.id == room) else {
            answer
                .send(Err(JumpFailure::NotFound))
                .other_end_may_be_gone("the caller");
            return;
        };
        if self.rooms.get(index).is_some_and(|room| room.phase == Phase::Waiting) {
            // what the device holds decides: its live messages come first.
            self.jumps.waiting.push((room, event, answer));
            return;
        }
        if let Some(detached) = self.jumps.detached.as_mut().filter(|detached| detached.index == index)
            && let Some(id) = detached.messages.find_event(&event)
        {
            detached.messages.reveal(&id);
            self.jumps.landed.push((id, answer));
            self.dirty.rows = true;
            return;
        }
        if let Some(id) = self.rooms.get(index).and_then(|room| room.find_event(&event)) {
            self.leave_detached();
            if let Some(room) = self.rooms.get_mut(index) {
                room.reveal(&id);
            }
            self.jumps.landed.push((id, answer));
            self.dirty.rows = true;
            return;
        }
        self.open_jump(index, event, answer);
    }

    /// Opens the timeline around `event` in the room at `index`; its first batch follows.
    fn open_jump(&mut self, index: usize, event: EventId, answer: Answer) {
        let Some(room) = self.rooms.get(index) else { return };
        self.jumps.generation += 1;
        let generation = self.jumps.generation;
        let id = self.timeline(&room.room.id).around(event);
        self.jumps.opening = Some((generation, self.backend.timelines().hold(&id)));
        self.jumping += 1;
        self.dirty.state = true;
        let (backend, events) = (Arc::clone(&self.backend), self.events.clone());
        self.followers.spawn(async move {
            let timelines = backend.timelines();
            let mut batches = match timelines.messages(&id).await {
                Ok(batches) => batches,
                Err(error) => {
                    events
                        .send(Event::JumpOpened(generation, index, id, Err(error), answer))
                        .other_end_may_be_gone("the thread's task");
                    return;
                }
            };
            let focused = timelines.focused(&id).await;
            let shows = focused.is_ok();
            if events
                .send(Event::JumpOpened(generation, index, id, focused, answer))
                .is_err()
                || !shows
            {
                return;
            }
            while let Some(batch) = batches.next().await {
                if events.send(Event::JumpDiffs(generation, batch)).is_err() {
                    break;
                }
            }
        });
    }

    /// A jump's timeline opened: its rows show instead of the live ones, or the jump answers.
    pub(super) fn jump_opened(
        &mut self,
        generation: u64,
        index: usize,
        id: TimelineId,
        focused: Result<Focused, BackendError>,
        answer: Answer,
    ) {
        self.jumping = self.jumping.saturating_sub(1);
        self.dirty.state = true;
        let hold = match self.jumps.opening.take() {
            Some((opened, hold)) if opened == generation => hold,
            other => {
                // another jump was asked for since: this one is over.
                self.jumps.opening = other;
                answer
                    .send(Err(JumpFailure::Failed))
                    .other_end_may_be_gone("the caller");
                return;
            }
        };
        let focused = match focused {
            Ok(focused) => focused,
            Err(error) => {
                answer.send(Err(failure(&error))).other_end_may_be_gone("the caller");
                return;
            }
        };
        if let (Some(root), None) = (focused.thread, &self.root) {
            // a thread's reply shows in its thread: the app opens it there.
            let event = id.at.clone().unwrap_or_else(|| root.clone());
            answer
                .send(Ok(Jumped::InThread {
                    room: id.room,
                    root,
                    event,
                }))
                .other_end_may_be_gone("the caller");
            return;
        }
        let Some(room) = self.rooms.get(index).map(|room| room.room.clone()) else {
            return;
        };
        let shown_before = match self.jumps.detached.take() {
            Some(detached) => detached.shown_before,
            None => self.shown,
        };
        self.jumps.returning = None;
        self.jumps.anchor = None;
        // a merged chat shows the jump's room alone, as its room filter says.
        self.shown = (self.rooms.len() > 1).then_some(index);
        self.jumps.detached = Some(Detached {
            generation,
            index,
            id,
            messages: RoomMessages::new(room),
            _hold: hold,
            at_end: false,
            paging_newer: false,
            shown_before,
        });
        if let Some((_, earlier)) = self.jumps.landing.replace((focused.message, answer)) {
            earlier
                .send(Err(JumpFailure::Failed))
                .other_end_may_be_gone("the caller");
        }
        self.dirty.rows = true;
    }

    /// The jump's messages changed: the jump's message shows once they hold it.
    pub(super) fn jump_diffs(&mut self, generation: u64, diffs: Diffs<Arc<TimelineMessage>>) {
        let Some(detached) = self
            .jumps
            .detached
            .as_mut()
            .filter(|detached| detached.generation == generation)
        else {
            return;
        };
        detached.messages.apply(diffs);
        if let Some((target, answer)) = self.jumps.landing.take() {
            if detached.messages.reveal(&target) {
                self.jumps.landed.push((target, answer));
            } else {
                self.jumps.landing = Some((target, answer));
            }
        }
        self.dirty.rows = true;
    }

    /// Asks for older messages of the jump's rows; `false` when the live rows show.
    pub(super) fn load_older_detached(&mut self) -> bool {
        let Some(detached) = self.jumps.detached.as_mut() else {
            return false;
        };
        let messages = &mut detached.messages;
        if messages.older_due > 0 || messages.paging || messages.shows_start() {
            return true;
        }
        messages.older_due = OLDER;
        let missing = OLDER.saturating_sub(messages.held_before());
        self.dirty.rows = true;
        self.dirty.state = true;
        if missing == 0 || messages.at_start {
            return true;
        }
        messages.paging = true;
        self.paging += 1;
        let (generation, id) = (detached.generation, detached.id.clone());
        let (backend, events) = (Arc::clone(&self.backend), self.events.clone());
        self.followers.spawn(async move {
            let at_start = backend.timelines().load_older(&id, missing).await.ok();
            events
                .send(Event::JumpPaged(generation, true, at_start))
                .other_end_may_be_gone("the thread's task");
        });
        true
    }

    /// Asks for newer messages of the jump's rows; at the newest, the rows go live again.
    pub(super) fn load_newer(&mut self) {
        let Some(detached) = self
            .jumps
            .detached
            .as_mut()
            .filter(|detached| detached.can_load_newer())
        else {
            return;
        };
        detached.paging_newer = true;
        self.paging += 1;
        self.dirty.state = true;
        let (generation, id) = (detached.generation, detached.id.clone());
        let (backend, events) = (Arc::clone(&self.backend), self.events.clone());
        self.followers.spawn(async move {
            let reached = backend.timelines().load_newer(&id, OLDER).await.ok();
            events
                .send(Event::JumpPaged(generation, false, reached))
                .other_end_may_be_gone("the thread's task");
        });
    }

    /// A page of the jump's timeline is in: whether it reached that end (`None`: it failed).
    pub(super) fn jump_paged(&mut self, generation: u64, older: bool, reached: Option<bool>) {
        self.paging = self.paging.saturating_sub(1);
        self.dirty.state = true;
        self.dirty.rows = true;
        let Some(detached) = self
            .jumps
            .detached
            .as_mut()
            .filter(|detached| detached.generation == generation)
        else {
            return;
        };
        if older {
            detached.messages.paging = false;
            detached.messages.at_start |= reached == Some(true);
            return;
        }
        detached.paging_newer = false;
        if reached == Some(true) {
            detached.at_end = true;
            self.start_return();
        }
    }

    /// The jump's rows reached the newest: they switch to the live ones at the reader's row.
    fn start_return(&mut self) {
        let Some(detached) = self.jumps.detached.as_ref() else {
            return;
        };
        let messages = &detached.messages.messages;
        let from = self
            .jumps
            .anchor
            .as_ref()
            .and_then(|anchor| messages.iter().position(|message| &message.message.id == anchor))
            .or_else(|| messages.len().checked_sub(1));
        let Some((position, message)) = from.and_then(|position| Some((position, messages.get(position)?))) else {
            self.leave_detached();
            return;
        };
        self.jumps.returning = Some(Returning {
            message: message.message.id.clone(),
            // the reader's message is at most this many before the newest.
            budget: messages.len() - position + RETURN_MARGIN,
        });
        self.try_return();
    }

    /// Switches to the live rows once they hold the reader's message, its row where the reader
    /// sees it; pages the live timeline back for it, once, as far as the budget goes; else the
    /// jump's rows stay.
    pub(super) fn try_return(&mut self) {
        let Some(index) = self.jumps.detached.as_ref().map(|detached| detached.index) else {
            self.jumps.returning = None;
            return;
        };
        let (Some(returning), Some(room)) = (self.jumps.returning.as_mut(), self.rooms.get_mut(index)) else {
            return;
        };
        if room.reveal(&returning.message) {
            self.leave_detached();
            return;
        }
        if room.paging || room.at_start || returning.budget == 0 {
            // the live batches still on their way may bring it; if they never do, the jump's rows
            // stay and "jump to bottom" returns.
            return;
        }
        let missing = mem::take(&mut returning.budget);
        self.page(index, missing);
    }

    /// Shows the live rows again, at the newest: no row is kept in place.
    pub(super) fn leave_detached(&mut self) {
        self.jumps.returning = None;
        if let Some(detached) = self.jumps.detached.take() {
            self.shown = detached.shown_before;
            if let Some((_, answer)) = self.jumps.landing.take() {
                answer
                    .send(Err(JumpFailure::Failed))
                    .other_end_may_be_gone("the caller");
            }
            self.dirty.rows = true;
            self.dirty.state = true;
        }
    }

    /// Takes up the jumps that waited for their room's live messages.
    pub(super) fn retry_waiting_jumps(&mut self) {
        for (room, event, answer) in mem::take(&mut self.jumps.waiting) {
            self.jump_to(room, event, answer);
        }
    }

    /// The messages of the jumps about to be answered, which show each in its own row: a run of
    /// deleted messages one is in unfolds.
    pub(super) fn unfold_landed(&mut self) {
        let landed = self.jumps.landed.iter().map(|(id, _)| id.clone());
        self.unfolded.deleted.extend(landed);
    }

    /// Answers the jumps whose messages show now, with the rows that show them.
    pub(super) fn answer_landed(&mut self) {
        for (id, answer) in mem::take(&mut self.jumps.landed) {
            let row = self.row_of(&id).unwrap_or(id);
            answer.send(Ok(Jumped::Here(row))).other_end_may_be_gone("the caller");
        }
    }

    /// The jump's rows show instead of the live ones.
    pub(super) fn is_detached(&self) -> bool {
        self.jumps.detached.is_some()
    }
}
