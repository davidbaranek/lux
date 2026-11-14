//! Which rooms' timelines are open: the few used last, and those the apps hold (a chat on
//! screen). One task owns the set; a timeline it lets go closes once no call still uses it.

use std::collections::{HashMap, VecDeque};
use std::sync::Arc;

use lux_core::ports::TimelineHold;
use matrix_sdk::ruma::OwnedRoomId;
use tokio::sync::{OnceCell, mpsc, oneshot};
use tokio::task::JoinHandle;

use super::room::RoomTimeline;

/// A room's timeline, opened by the first call that needs it.
pub(crate) type Slot = Arc<OnceCell<Arc<RoomTimeline>>>;

/// How many timelines stay open besides those held: a chat opened again soon opens at once.
pub(crate) const KEPT: usize = 8;

enum Command {
    /// The room's slot, made if it has none; the room is now the one used last.
    Use(OwnedRoomId, oneshot::Sender<Slot>),
    /// The room's slot if it has one, leaving the order as it is.
    Peek(OwnedRoomId, oneshot::Sender<Option<Slot>>),
    Hold(OwnedRoomId),
    Release(OwnedRoomId),
}

/// The open timelines' task: it ends, closing them all, when the timelines go (a hold kept by
/// the app then has nothing to keep).
pub(crate) struct Opened {
    commands: mpsc::UnboundedSender<Command>,
    task: JoinHandle<()>,
}

impl Drop for Opened {
    fn drop(&mut self) {
        self.task.abort();
    }
}

impl Opened {
    /// Starts the task, which keeps `kept` timelines open besides the held ones.
    pub(crate) fn new(kept: usize) -> Self {
        let (commands, mut received) = mpsc::unbounded_channel();
        let task = tokio::spawn(async move {
            let mut rooms = Rooms::new(kept);
            while let Some(command) = received.recv().await {
                match command {
                    // a caller that went away needs no answer.
                    Command::Use(room, reply) => drop(reply.send(rooms.use_room(room))),
                    Command::Peek(room, reply) => drop(reply.send(rooms.slot(&room))),
                    Command::Hold(room) => rooms.hold(room),
                    Command::Release(room) => rooms.release(&room),
                }
            }
        });
        Self { commands, task }
    }

    /// The room's slot, the room now the one used last; `None` once the account closes.
    pub(crate) async fn use_room(&self, room: OwnedRoomId) -> Option<Slot> {
        let (reply, answer) = oneshot::channel();
        self.commands.send(Command::Use(room, reply)).ok()?;
        answer.await.ok()
    }

    /// The room's timeline, if it is open.
    pub(crate) async fn timeline(&self, room: OwnedRoomId) -> Option<Arc<RoomTimeline>> {
        let (reply, answer) = oneshot::channel();
        self.commands.send(Command::Peek(room, reply)).ok()?;
        answer.await.ok().flatten()?.get().cloned()
    }

    /// Keeps the room's timeline open until the hold goes.
    pub(crate) fn hold(&self, room: OwnedRoomId) -> TimelineHold {
        // once the task is gone, nothing is open to keep.
        let _ = self.commands.send(Command::Hold(room.clone()));
        let commands = self.commands.clone();
        TimelineHold::new(move || {
            let _ = commands.send(Command::Release(room));
        })
    }
}

/// The set itself, as the task keeps it.
struct Rooms {
    kept: usize,
    slots: HashMap<OwnedRoomId, Slot>,
    /// The rooms with a slot, the one used last at the back.
    recent: VecDeque<OwnedRoomId>,
    /// How many holds each held room has.
    holds: HashMap<OwnedRoomId, usize>,
}

impl Rooms {
    fn new(kept: usize) -> Self {
        Self {
            kept,
            slots: HashMap::new(),
            recent: VecDeque::new(),
            holds: HashMap::new(),
        }
    }

    fn use_room(&mut self, room: OwnedRoomId) -> Slot {
        if let Some(index) = self.recent.iter().position(|recent| *recent == room) {
            self.recent.remove(index);
        }
        let slot = Arc::clone(self.slots.entry(room.clone()).or_default());
        self.recent.push_back(room);
        self.close_unused();
        slot
    }

    fn slot(&self, room: &OwnedRoomId) -> Option<Slot> {
        self.slots.get(room).cloned()
    }

    fn hold(&mut self, room: OwnedRoomId) {
        *self.holds.entry(room).or_default() += 1;
    }

    fn release(&mut self, room: &OwnedRoomId) {
        if let Some(count) = self.holds.get_mut(room) {
            *count -= 1;
            if *count == 0 {
                self.holds.remove(room);
                self.close_unused();
            }
        }
    }

    /// Closes the timelines used longest ago until at most `kept` are open besides the held ones.
    fn close_unused(&mut self) {
        let mut unheld = self
            .recent
            .iter()
            .filter(|room| !self.holds.contains_key(*room))
            .count();
        while unheld > self.kept {
            let Some(index) = self.recent.iter().position(|room| !self.holds.contains_key(room)) else {
                return;
            };
            if let Some(room) = self.recent.remove(index) {
                self.slots.remove(&room);
            }
            unheld -= 1;
        }
    }
}

#[cfg(test)]
mod tests {
    use matrix_sdk::ruma::OwnedRoomId;

    use super::Rooms;

    fn room(number: usize) -> OwnedRoomId {
        OwnedRoomId::try_from(format!("!{number}:example.org")).unwrap()
    }

    fn open(rooms: &Rooms) -> Vec<OwnedRoomId> {
        let mut open: Vec<OwnedRoomId> = rooms.slots.keys().cloned().collect();
        open.sort();
        open
    }

    #[test]
    fn the_rooms_used_longest_ago_close() {
        let mut rooms = Rooms::new(2);
        rooms.use_room(room(1));
        rooms.use_room(room(2));
        rooms.use_room(room(1));
        rooms.use_room(room(3));
        assert_eq!(open(&rooms), vec![room(1), room(3)]);
    }

    #[test]
    fn a_held_room_stays_open_and_counts_apart() {
        let mut rooms = Rooms::new(1);
        rooms.hold(room(1));
        rooms.use_room(room(1));
        rooms.use_room(room(2));
        rooms.use_room(room(3));
        assert_eq!(open(&rooms), vec![room(1), room(3)]);
        // let go, it is the one used longest ago.
        rooms.release(&room(1));
        assert_eq!(open(&rooms), vec![room(3)]);
    }

    #[test]
    fn a_room_held_twice_needs_both_released() {
        let mut rooms = Rooms::new(0);
        rooms.hold(room(1));
        rooms.hold(room(1));
        rooms.use_room(room(1));
        rooms.release(&room(1));
        assert_eq!(open(&rooms), vec![room(1)]);
        rooms.release(&room(1));
        assert!(open(&rooms).is_empty());
    }
}
