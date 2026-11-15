//! Which timelines are open (a room's own, a Matrix thread's): the few used last, and those the
//! apps hold (a chat or a thread on screen). One task owns the set; a timeline it lets go closes
//! once no call still uses it.

use std::collections::{HashMap, VecDeque};
use std::sync::Arc;

use lux_core::ports::TimelineHold;
use matrix_sdk::ruma::{OwnedEventId, OwnedRoomId};
use tokio::sync::{OnceCell, mpsc, oneshot};
use tokio::task::JoinHandle;

use super::room::RoomTimeline;

/// A timeline, opened by the first call that needs it.
pub(crate) type Slot = Arc<OnceCell<Arc<RoomTimeline>>>;

/// Which timeline: a room's own, or the Matrix thread of one of its messages.
#[derive(Clone, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub(crate) struct Key {
    pub(crate) room: OwnedRoomId,
    /// The thread's root; `None`: the room's own.
    pub(crate) thread: Option<OwnedEventId>,
}

/// How many timelines stay open besides those held: a chat opened again soon opens at once.
pub(crate) const KEPT: usize = 8;

enum Command {
    /// The timeline's slot, made if it has none; it is now the one used last.
    Use(Key, oneshot::Sender<Slot>),
    /// The timeline's slot if it has one, leaving the order as it is.
    Peek(Key, oneshot::Sender<Option<Slot>>),
    /// The slots of a room's timelines, its own and its threads', leaving the order as it is.
    OfRoom(OwnedRoomId, oneshot::Sender<Vec<Slot>>),
    Hold(Key),
    Release(Key),
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
                    Command::OfRoom(room, reply) => drop(reply.send(rooms.of_room(&room))),
                    Command::Hold(room) => rooms.hold(room),
                    Command::Release(room) => rooms.release(&room),
                }
            }
        });
        Self { commands, task }
    }

    /// The timeline's slot, now the one used last; `None` once the account closes.
    pub(crate) async fn use_room(&self, room: Key) -> Option<Slot> {
        let (reply, answer) = oneshot::channel();
        self.commands.send(Command::Use(room, reply)).ok()?;
        answer.await.ok()
    }

    /// The timeline, if it is open.
    pub(crate) async fn timeline(&self, room: Key) -> Option<Arc<RoomTimeline>> {
        let (reply, answer) = oneshot::channel();
        self.commands.send(Command::Peek(room, reply)).ok()?;
        answer.await.ok().flatten()?.get().cloned()
    }

    /// The room's open timelines: its own and its threads'.
    pub(crate) async fn of_room(&self, room: OwnedRoomId) -> Vec<Arc<RoomTimeline>> {
        let (reply, answer) = oneshot::channel();
        if self.commands.send(Command::OfRoom(room, reply)).is_err() {
            return Vec::new();
        }
        answer
            .await
            .unwrap_or_default()
            .iter()
            .filter_map(|slot| slot.get().cloned())
            .collect()
    }

    /// Keeps the timeline open until the hold goes.
    pub(crate) fn hold(&self, room: Key) -> TimelineHold {
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
    slots: HashMap<Key, Slot>,
    /// The timelines with a slot, the one used last at the back.
    recent: VecDeque<Key>,
    /// How many holds each held timeline has.
    holds: HashMap<Key, usize>,
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

    fn use_room(&mut self, room: Key) -> Slot {
        if let Some(index) = self.recent.iter().position(|recent| *recent == room) {
            self.recent.remove(index);
        }
        let slot = Arc::clone(self.slots.entry(room.clone()).or_default());
        self.recent.push_back(room);
        self.close_unused();
        slot
    }

    fn slot(&self, room: &Key) -> Option<Slot> {
        self.slots.get(room).cloned()
    }

    fn of_room(&self, room: &OwnedRoomId) -> Vec<Slot> {
        self.slots
            .iter()
            .filter(|(key, _)| &key.room == room)
            .map(|(_, slot)| Arc::clone(slot))
            .collect()
    }

    fn hold(&mut self, room: Key) {
        *self.holds.entry(room).or_default() += 1;
    }

    fn release(&mut self, room: &Key) {
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

    use super::{Key, Rooms};

    fn room(number: usize) -> Key {
        Key {
            room: OwnedRoomId::try_from(format!("!{number}:example.org")).unwrap(),
            thread: None,
        }
    }

    fn open(rooms: &Rooms) -> Vec<Key> {
        let mut open: Vec<Key> = rooms.slots.keys().cloned().collect();
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

#[cfg(test)]
mod thread_tests {
    use matrix_sdk::ruma::{OwnedEventId, OwnedRoomId};

    use super::{Key, Rooms};

    #[test]
    fn a_rooms_threads_are_its_open_timelines_beside_its_own() {
        let room = OwnedRoomId::try_from("!1:example.org").unwrap();
        let own = Key {
            room: room.clone(),
            thread: None,
        };
        let thread = Key {
            room: room.clone(),
            thread: Some(OwnedEventId::try_from("$root").unwrap()),
        };
        let other = Key {
            room: OwnedRoomId::try_from("!2:example.org").unwrap(),
            thread: None,
        };
        let mut rooms = Rooms::new(4);
        rooms.use_room(own);
        rooms.use_room(thread);
        rooms.use_room(other);
        assert_eq!(rooms.of_room(&room).len(), 2);
    }
}
