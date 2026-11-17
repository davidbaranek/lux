//! The thread's rows: the shown messages of its rooms as one conversation, presented (albums,
//! runs, separators, links, footers), each with its room and whether its details show.

use std::collections::HashSet;
use std::sync::Arc;

use eyeball_im::VectorDiff;
use jiff::tz::TimeZone;

use crate::chat::ChatRoom;
use crate::diff;
use crate::ids::{EventId, MessageId, MessageRef, RoomId};
use crate::message::{self, Footer, Link, Separator};
use crate::network::Network;
use crate::timeline::{TimelineMessage, Window};

/// How many messages a chat shows when it opens: its last screenful.
pub(crate) const FIRST_SCREEN: usize = 60;

/// How many older messages one page back shows: a large page, so a fling up meets few of them.
/// Each insert above the reader costs the apps a layout of the rows on screen (the table views
/// configure them again for their new positions), so fewer, larger pages scroll smoother.
pub(crate) const OLDER: usize = 240;

/// One row of the thread: a message, or an album of several, as the app draws it.
#[derive(Clone, Debug)]
pub struct ThreadRow {
    /// The message it shows (an album's first).
    pub message: Arc<TimelineMessage>,
    /// An album's messages, this one first; empty for anything else.
    pub album: Vec<Arc<TimelineMessage>>,
    /// The room it is in: one of a merged chat's.
    pub room: RoomId,
    /// Its room's network, in a merged chat (where it shows on asking); `None` elsewhere.
    pub network: Option<Network>,
    /// The first of a run of one sender's messages: it shows the sender's name in a group.
    pub starts_run: bool,
    /// The last of the run: its bubble gets the tail.
    pub ends_run: bool,
    /// What shows above it.
    pub separator: Option<Separator>,
    /// The web addresses in its text.
    pub links: Vec<Link>,
    /// What shows under it.
    pub footer: Option<Footer>,
    /// What the user unfolded of it.
    pub shows: RowShows,
}

/// What a row shows besides itself, as the user asked.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct RowShows {
    /// Its full time (and network).
    pub detail: bool,
    /// Its shared post's whole caption.
    pub whole_post: bool,
}

impl ThreadRow {
    /// Its id: its message's, stable from local echo to sent.
    #[must_use]
    pub fn id(&self) -> &MessageId {
        &self.message.message.id
    }
}

impl PartialEq for ThreadRow {
    /// The same row: the same messages (the backend gives a changed message a new `Arc`), placed
    /// and decorated alike.
    fn eq(&self, other: &Self) -> bool {
        Arc::ptr_eq(&self.message, &other.message)
            && self.album.len() == other.album.len()
            && self.album.iter().zip(&other.album).all(|(a, b)| Arc::ptr_eq(a, b))
            && self.room == other.room
            && self.network == other.network
            && self.starts_run == other.starts_run
            && self.ends_run == other.ends_run
            && self.separator == other.separator
            && self.links == other.links
            && self.footer == other.footer
            && self.shows == other.shows
    }
}

/// One room of the thread: its messages as the backend sends them, and which of them show.
#[derive(Debug)]
pub(crate) struct RoomMessages {
    pub(crate) room: ChatRoom,
    pub(crate) messages: Vec<Arc<TimelineMessage>>,
    window: Window,
    /// The backend's first list came (or the room could not be read).
    pub(crate) loaded: bool,
    /// The timeline holds the room's first message.
    pub(crate) at_start: bool,
    /// Older messages asked for and not shown yet: they show as the timeline has them.
    pub(crate) older_due: usize,
    /// A page back of the room is on the server's way.
    pub(crate) paging: bool,
}

impl RoomMessages {
    pub(crate) fn new(room: ChatRoom) -> Self {
        Self {
            room,
            messages: Vec::new(),
            window: Window::new(),
            loaded: false,
            at_start: false,
            older_due: 0,
            paging: false,
        }
    }

    /// Applies a batch of the backend's diffs.
    pub(crate) fn apply(&mut self, diffs: Vec<VectorDiff<Arc<TimelineMessage>>>) {
        for diff in diffs {
            // the timeline was reset to its newest messages (a limited sync): it no longer holds
            // the room's first, until a page back says it does again.
            if matches!(diff, VectorDiff::Clear) {
                self.at_start = false;
            }
            diff::apply(&mut self.messages, diff);
        }
        self.loaded = true;
    }

    /// The messages shown, oldest first.
    pub(crate) fn shown(&mut self) -> &[Arc<TimelineMessage>] {
        let start = self.window.start(&self.messages, FIRST_SCREEN);
        self.messages.get(start..).unwrap_or_default()
    }

    /// How many messages the timeline holds before the shown ones.
    pub(crate) fn held_before(&mut self) -> usize {
        self.window.start(&self.messages, FIRST_SCREEN)
    }

    /// Shows the older messages due that the timeline holds. Those it lacks wait for a page
    /// under way (its messages show as they come), else are not waited for.
    pub(crate) fn reveal_older(&mut self) {
        if self.older_due == 0 {
            return;
        }
        let missing = self.window.extend(&self.messages, FIRST_SCREEN, self.older_due);
        self.older_due = if self.paging { missing } else { 0 };
    }

    /// Nothing is older than what shows: the room's first message shows.
    pub(crate) fn shows_start(&mut self) -> bool {
        self.at_start && self.window.shows_first(&self.messages, FIRST_SCREEN)
    }

    /// The message `id`.
    pub(crate) fn message(&self, id: &MessageId) -> Option<&Arc<TimelineMessage>> {
        self.messages.iter().find(|message| message.message.id == *id)
    }

    /// The message `message` names, by its id or its event.
    pub(crate) fn find(&self, message: &MessageRef) -> Option<&Arc<TimelineMessage>> {
        match message {
            MessageRef::Local(id) => self.message(id),
            MessageRef::Event(event) => self
                .messages
                .iter()
                .find(|message| message.event_id.as_ref() == Some(event)),
        }
    }

    /// The message of `event`'s id.
    pub(crate) fn find_event(&self, event: &EventId) -> Option<MessageId> {
        self.messages
            .iter()
            .find(|message| message.event_id.as_ref() == Some(event))
            .map(|message| message.message.id.clone())
    }

    /// Shows the message `id`, moving the window's start back to it; whether the room has it.
    pub(crate) fn reveal(&mut self, id: &MessageId) -> bool {
        let Some(index) = self.messages.iter().position(|message| &message.message.id == id) else {
            return false;
        };
        let start = self.window.start(&self.messages, FIRST_SCREEN);
        if index < start {
            self.window.extend(&self.messages, FIRST_SCREEN, start - index);
        }
        true
    }
}

/// What the user unfolded, by message: its details, its shared post's whole caption.
#[derive(Debug, Default)]
pub(crate) struct Unfolded {
    pub(crate) details: HashSet<MessageId>,
    pub(crate) posts: HashSet<MessageId>,
}

impl Unfolded {
    /// Unfolds `message` in `set`, or folds it again.
    pub(crate) fn toggle(set: &mut HashSet<MessageId>, message: MessageId) {
        if !set.remove(&message) {
            set.insert(message);
        }
    }
}

/// The rows of the rooms' shown messages (`shown`: one room alone), as one conversation in time
/// order: a stable sort, so one room's messages keep their order at equal times. `merged`: the
/// chat merges rooms, so each row tells its network.
pub(crate) fn present(
    rooms: &mut [RoomMessages],
    shown: Option<usize>,
    merged: bool,
    unfolded: &Unfolded,
    zone: &TimeZone,
) -> Vec<Arc<ThreadRow>> {
    let mut tagged: Vec<(usize, Arc<TimelineMessage>)> = Vec::new();
    let mut sources = 0;
    for (index, room) in rooms.iter_mut().enumerate() {
        if shown.is_some_and(|shown| shown != index) {
            continue;
        }
        sources += 1;
        tagged.extend(room.shown().iter().map(|message| (index, Arc::clone(message))));
    }
    if sources > 1 {
        tagged.sort_by_key(|(_, message)| message.message.date);
    }
    let (origins, messages): (Vec<usize>, Vec<Arc<TimelineMessage>>) = tagged.into_iter().unzip();
    debug_assert!(
        unique(messages.iter().map(|message| &message.message.id)),
        "two shown messages share an id: the apps' lists need each row's id once"
    );
    message::present(&messages, zone)
        .into_iter()
        .filter_map(|row| {
            let room = &rooms.get(*origins.get(row.message)?)?.room;
            let lead = messages.get(row.message)?;
            Some(Arc::new(ThreadRow {
                shows: RowShows {
                    detail: unfolded.details.contains(&lead.message.id),
                    whole_post: unfolded.posts.contains(&lead.message.id),
                },
                message: Arc::clone(lead),
                album: row
                    .album
                    .iter()
                    .filter_map(|&index| messages.get(index))
                    .map(Arc::clone)
                    .collect(),
                room: room.id.clone(),
                network: merged.then(|| room.network.clone()),
                starts_run: row.starts_run,
                ends_run: row.ends_run,
                separator: row.separator,
                links: row.links,
                footer: row.footer,
            }))
        })
        .collect()
}

/// Whether no id shows twice.
fn unique<'a>(mut ids: impl Iterator<Item = &'a MessageId>) -> bool {
    let mut seen = HashSet::new();
    ids.all(|id| seen.insert(id))
}

#[cfg(test)]
pub(crate) mod tests {
    use std::time::{Duration, SystemTime};

    use super::*;
    use crate::message::{Message, SendState};
    use crate::timeline::MessageKind;

    pub(crate) fn message(id: &str, room: &str, seconds: u64, own: bool) -> Arc<TimelineMessage> {
        Arc::new(TimelineMessage {
            message: Message {
                id: id.into(),
                sender: if own { "@me".into() } else { "@anna".into() },
                room: Some(room.into()),
                date: SystemTime::UNIX_EPOCH + Duration::from_secs(1_800_000_000 + seconds),
                state: SendState::Sent,
                is_edited: false,
                body: format!("text {id}"),
                attachment: None,
                is_reply: false,
                has_reactions: false,
                links: Vec::new(),
            },
            event_id: Some(format!("${id}").into()),
            sender_name: if own { "Me".to_owned() } else { "Anna".to_owned() },
            sender_avatar: None,
            is_own: own,
            is_editable: own,
            kind: MessageKind::Message,
            media: None,
            styles: Vec::new(),
            reactions: Vec::new(),
            reply: None,
            readers: Vec::new(),
            thread: None,
            shared: None,
        })
    }

    pub(crate) fn room(id: &str, messages: Vec<Arc<TimelineMessage>>) -> RoomMessages {
        let mut room = RoomMessages::new(ChatRoom {
            id: id.into(),
            network: Network::Other(format!("net{id}")),
        });
        room.apply(vec![VectorDiff::Reset {
            values: messages.into_iter().collect(),
        }]);
        room
    }

    fn ids(rows: &[Arc<ThreadRow>]) -> Vec<&str> {
        rows.iter().map(|row| row.id().as_str()).collect()
    }

    #[test]
    fn a_reset_timeline_no_longer_holds_the_rooms_start() {
        let mut room = room(
            "!a",
            vec![message("a1", "!a", 0, false), message("a2", "!a", 10, false)],
        );
        room.at_start = true;
        assert!(room.shows_start());
        room.apply(vec![
            VectorDiff::Clear,
            VectorDiff::PushBack {
                value: message("a5", "!a", 40, false),
            },
        ]);
        assert!(!room.shows_start());
        assert_eq!(room.messages.len(), 1);
    }

    #[test]
    fn a_merged_chat_is_one_conversation_in_time_order() {
        let mut rooms = [
            room(
                "!a",
                vec![message("a1", "!a", 0, false), message("a2", "!a", 20, false)],
            ),
            room("!b", vec![message("b1", "!b", 10, true), message("b2", "!b", 20, true)]),
        ];
        let rows = present(&mut rooms, None, true, &Unfolded::default(), &TimeZone::UTC);
        // equal times keep the rooms' order.
        assert_eq!(ids(&rows), ["a1", "b1", "a2", "b2"]);
        assert_eq!(rows[1].room.as_str(), "!b");
        assert_eq!(rows[1].network.as_ref().map(Network::as_str), Some("net!b"));
        let alone = present(&mut rooms, Some(1), true, &Unfolded::default(), &TimeZone::UTC);
        assert_eq!(ids(&alone), ["b1", "b2"]);
    }

    #[test]
    #[cfg(debug_assertions)]
    #[should_panic(expected = "two shown messages share an id")]
    fn rooms_whose_messages_share_an_id_are_caught() {
        // what each room's timeline numbering its items from 0 gave a merged chat.
        let mut rooms = [
            room("!a", vec![message("0", "!a", 0, false)]),
            room("!b", vec![message("0", "!b", 10, false)]),
        ];
        present(&mut rooms, None, true, &Unfolded::default(), &TimeZone::UTC);
    }

    #[test]
    fn one_room_has_no_network_and_details_show_where_asked() {
        let mut rooms = [room(
            "!a",
            vec![message("a1", "!a", 0, false), message("a2", "!a", 5, false)],
        )];
        let unfolded = Unfolded {
            details: HashSet::from([MessageId::from("a2")]),
            ..Unfolded::default()
        };
        let rows = present(&mut rooms, None, false, &unfolded, &TimeZone::UTC);
        assert_eq!(rows[0].network, None);
        assert_eq!(
            rows.iter().map(|row| row.shows.detail).collect::<Vec<_>>(),
            [false, true]
        );
    }

    #[test]
    fn rows_of_the_same_messages_are_equal_and_a_new_message_is_not() {
        let mut rooms = [room("!a", vec![message("a1", "!a", 0, false)])];
        let before = present(&mut rooms, None, false, &Unfolded::default(), &TimeZone::UTC);
        let again = present(&mut rooms, None, false, &Unfolded::default(), &TimeZone::UTC);
        assert_eq!(before, again);
        rooms[0].apply(vec![VectorDiff::Set {
            index: 0,
            value: message("a1", "!a", 0, false),
        }]);
        assert_ne!(
            before,
            present(&mut rooms, None, false, &Unfolded::default(), &TimeZone::UTC)
        );
    }

    #[test]
    fn older_ones_show_as_the_timeline_has_them() {
        let all: Vec<_> = (0..100)
            .map(|index| message(&index.to_string(), "!a", index, false))
            .collect();
        let mut one = room("!a", all[20..].to_vec());
        assert_eq!(one.shown().len(), FIRST_SCREEN);
        assert_eq!(one.held_before(), 20);
        // 20 held, 30 asked for: those 20 now, the rest once the page is in.
        one.older_due = 30;
        one.paging = true;
        one.reveal_older();
        assert_eq!(one.shown().len(), FIRST_SCREEN + 20);
        assert_eq!(one.older_due, 10);
        one.apply(vec![VectorDiff::Reset {
            values: all.iter().cloned().collect(),
        }]);
        one.reveal_older();
        assert_eq!(one.older_due, 0);
        assert_eq!(one.shown().len(), FIRST_SCREEN + 30);
        // no page under way: what the timeline lacks is not waited for.
        one.older_due = 50;
        one.paging = false;
        one.reveal_older();
        assert_eq!(one.older_due, 0);
        assert_eq!(one.shown().len(), 100);
        assert!(one.reveal(&"5".into()));
        assert!(!one.reveal(&"gone".into()));
    }
}
