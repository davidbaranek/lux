//! The chat list composed from a snapshot: the places with their unread counts, and the chats a
//! place shows, in sections. Pure functions, so they run off the main thread and test without a
//! UI. Rows name positions in the snapshot, so nothing is copied.

use std::cmp::Reverse;
use std::collections::{BTreeMap, HashMap, HashSet};
use std::hash::BuildHasher;
use std::sync::Arc;
use std::time::SystemTime;

use super::{Arrangement, ChatFilter, PlaceId, arranged_order};
use crate::chat::{Chat, Folder, Snapshot, Space};
use crate::ids::{ChatId, MediaId, RoomId};
use crate::network::Network;

/// A place in the list of places, arranged.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ListedPlace {
    /// Which place.
    pub id: PlaceId,
    /// Its badge: chats with unread messages that are not muted; due reminders; requests.
    pub unread: u32,
    /// The user hid it; the inbox never is.
    pub is_hidden: bool,
    /// A space's or a label's name; `None` for the places the apps name.
    pub name: Option<String>,
    /// A space's picture.
    pub avatar: Option<MediaId>,
}

/// What a section is.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum SectionId {
    /// The inbox's pinned chats, drawn as a grid.
    Pinned,
    /// A place's chats.
    All,
    /// A space's own chats, or those of a space inside it.
    Space(RoomId),
}

/// How a section draws.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SectionStyle {
    /// A list of rows.
    List,
    /// A grid of pictures, as Messages pins chats.
    Grid,
}

/// One row of the list, as a position in the snapshot.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Row {
    /// A chat, in `Snapshot::chats`.
    Chat(usize),
    /// An invitation, in `Snapshot::requests`.
    Request(usize),
    /// A saved message, in `Snapshot::saved`, with its chat if the list has it.
    Saved {
        /// The message.
        message: usize,
        /// Its chat.
        chat: Option<usize>,
    },
    /// A waiting message, in `Snapshot::scheduled`, with its chat if the list has it.
    Scheduled {
        /// The message.
        message: usize,
        /// Its chat.
        chat: Option<usize>,
    },
}

/// A run of the list under one heading.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Section {
    /// What it is.
    pub id: SectionId,
    /// Its heading: the name of a space inside the one shown; `None` for the others.
    pub title: Option<String>,
    /// Its rows, in order.
    pub rows: Vec<Row>,
}

impl Section {
    fn untitled(id: SectionId, rows: Vec<Row>) -> Self {
        Self { id, title: None, rows }
    }

    /// How it draws: the pinned chats as a grid, the rest as a list.
    #[must_use]
    pub fn style(&self) -> SectionStyle {
        match self.id {
            SectionId::Pinned => SectionStyle::Grid,
            SectionId::All | SectionId::Space(_) => SectionStyle::List,
        }
    }
}

/// The whole chat list: the places, and the shown place's sections.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct ComposedList {
    /// The places, arranged.
    pub places: Vec<ListedPlace>,
    /// What `place` shows, filtered.
    pub sections: Vec<Section>,
}

/// The chat list at `place`, in one go: the places as the user arranged them, and the place's
/// sections with only what `filter` admits (`drafts`: the chats with a draft on this device).
/// Reminders due by `now` count on their place.
#[must_use]
pub(crate) fn compose<S: BuildHasher>(
    snapshot: &Snapshot,
    place: &PlaceId,
    filter: Option<ChatFilter>,
    order: ChatOrder,
    drafts: &HashSet<ChatId, S>,
    arrangement: &Arrangement,
    now: SystemTime,
) -> ComposedList {
    let sections = sections(snapshot, place, order);
    ComposedList {
        places: places(snapshot, arrangement, now),
        sections: match filter {
            Some(filter) => filter.apply(sections, snapshot, drafts),
            None => sections,
        },
    }
}

/// Counts on a badge: unread, and not muted.
fn counts(chat: &Chat) -> bool {
    chat.is_unread() && !chat.is_muted
}

fn unread<'a>(chats: impl Iterator<Item = &'a Arc<Chat>>) -> u32 {
    chats.filter(|chat| counts(chat)).count().try_into().unwrap_or(u32::MAX)
}

/// The places as the user arranged them: the folders (the app's lists among them when they
/// hold something), the networks with inbox chats, the top-level spaces, the labels.
#[must_use]
pub(crate) fn places(snapshot: &Snapshot, arrangement: &Arrangement, now: SystemTime) -> Vec<ListedPlace> {
    let chats = &snapshot.chats;
    let inbox = || chats.iter().filter(|chat| chat.folder == Folder::Inbox);
    let mut places: Vec<(PlaceId, u32)> = vec![
        (PlaceId::INBOX, unread(inbox())),
        (
            PlaceId::Folder(Folder::LowPriority),
            unread(chats.iter().filter(|chat| chat.folder == Folder::LowPriority)),
        ),
        (PlaceId::Folder(Folder::Archive), 0),
    ];
    if chats.iter().any(|chat| chat.reminder.is_some()) {
        // a count of those that are due.
        let due = chats
            .iter()
            .filter(|chat| chat.reminder.is_some_and(|reminder| reminder <= now))
            .count();
        places.push((PlaceId::Reminders, due.try_into().unwrap_or(u32::MAX)));
    }
    if !snapshot.scheduled.is_empty() {
        places.push((PlaceId::Scheduled, 0));
    }
    if !snapshot.saved.is_empty() {
        places.push((PlaceId::Saved, 0));
    }
    if !snapshot.requests.is_empty() {
        let requests = snapshot.requests.len().try_into().unwrap_or(u32::MAX);
        places.push((PlaceId::Requests, requests));
    }
    // each network with inbox chats, in the apps' order.
    let mut networks: BTreeMap<&Network, u32> = BTreeMap::new();
    for chat in inbox() {
        let count = networks.entry(&chat.network).or_default();
        *count = count.saturating_add(u32::from(counts(chat)));
    }
    places.extend(
        networks
            .into_iter()
            .map(|(network, count)| (PlaceId::Network(network.clone()), count)),
    );
    // the list of places shows the top of each tree; a space inside another is its section.
    for space in top_level_spaces(&snapshot.spaces) {
        let count = unread(inbox().filter(|chat| space.chats.contains(&chat.id)));
        places.push((PlaceId::Space(space.id.clone()), count));
    }
    for label in &snapshot.labels {
        let count = unread(
            chats
                .iter()
                .filter(|chat| chat.folder != Folder::Archive && label.chats.contains(&chat.id)),
        );
        places.push((PlaceId::Label(label.id.clone()), count));
    }
    let keys: Vec<_> = places.iter().map(|(id, _)| (id.key(), id.group())).collect();
    let order = arranged_order(keys.iter().map(|(key, group)| (key, *group)), arrangement);
    let mut places: Vec<Option<(PlaceId, u32)>> = places.into_iter().map(Some).collect();
    order
        .into_iter()
        .filter_map(|index| {
            let (id, unread) = places[index].take()?;
            let is_hidden = arrangement.hides(&keys[index].0);
            let (name, avatar) = match &id {
                PlaceId::Space(room) => snapshot
                    .spaces
                    .iter()
                    .find(|space| space.id == *room)
                    .map_or((None, None), |space| (Some(space.name.clone()), space.avatar.clone())),
                PlaceId::Label(label) => (
                    snapshot
                        .labels
                        .iter()
                        .find(|found| found.id == *label)
                        .map(|found| found.name.clone()),
                    None,
                ),
                _ => (None, None),
            };
            Some(ListedPlace {
                id,
                unread,
                is_hidden,
                name,
                avatar,
            })
        })
        .collect()
}

/// The spaces inside no other space the user is in.
fn top_level_spaces(spaces: &[Space]) -> impl Iterator<Item = &Space> {
    let known: HashSet<&RoomId> = spaces.iter().map(|space| &space.id).collect();
    spaces
        .iter()
        .filter(move |space| !space.parents.iter().any(|parent| known.contains(parent)))
}

/// The order of a place's chats, the user's choice.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub enum ChatOrder {
    /// By their last activity, as the server's room list orders them: any newest event counts
    /// (an edit, a bridge filling in a photo, the user let into an old chat).
    #[default]
    Activity,
    /// By their newest message's sending, the newest first ([`newest_message_first`]).
    NewestMessage,
}

impl ChatOrder {
    /// The indexes of `chats` (in the server's order) in this order.
    fn of(self, chats: &[Arc<Chat>]) -> Vec<usize> {
        match self {
            Self::Activity => (0..chats.len()).collect(),
            Self::NewestMessage => newest_message_first(chats),
        }
    }
}

/// The chats by their newest message, the newest first; chats with no message after those with
/// one, in the server's order. Not the server's own order: it counts any event, so a bridge
/// adding the user to an old chat would put it on top. A chat's date is its newest message's
/// sending, which an edit does not change.
fn newest_message_first(chats: &[Arc<Chat>]) -> Vec<usize> {
    let mut order: Vec<usize> = (0..chats.len()).collect();
    // `None` sorts first, so reversed it goes last; a stable sort keeps the server's order.
    order.sort_by_key(|&index| Reverse(chats[index].date));
    order
}

/// The chats a place shows, in `ordering`, in sections: one untitled section for a
/// folder or a network; for a space, its own chats, then a titled section for each space inside
/// it (their chats include those of deeper spaces). A chat shows once, in the first section
/// that has it. The inbox's pinned chats come first, as a grid, in their pin order.
#[must_use]
pub(crate) fn sections(snapshot: &Snapshot, place: &PlaceId, ordering: ChatOrder) -> Vec<Section> {
    let chats = &snapshot.chats;
    let order = ordering.of(chats);
    let rows = |admits: &dyn Fn(&Chat) -> bool| -> Vec<Row> {
        order
            .iter()
            .filter(|&&index| admits(&chats[index]))
            .map(|&index| Row::Chat(index))
            .collect()
    };
    let in_inbox = |chat: &Chat| chat.folder == Folder::Inbox;
    match place {
        PlaceId::Folder(Folder::Inbox) => {
            let mut pinned: Vec<(usize, f64)> = order
                .iter()
                .filter_map(|&index| {
                    let chat = &chats[index];
                    chat.pinned.filter(|_| in_inbox(chat)).map(|pin| (index, pin))
                })
                .collect();
            // a stable sort: equal pins keep the list's order.
            pinned.sort_by(|a, b| a.1.total_cmp(&b.1));
            let pinned = pinned.into_iter().map(|(index, _)| Row::Chat(index)).collect();
            let rest = rows(&|chat| in_inbox(chat) && chat.pinned.is_none());
            [
                Section::untitled(SectionId::Pinned, pinned),
                Section::untitled(SectionId::All, rest),
            ]
            .into_iter()
            .filter(|section| !section.rows.is_empty())
            .collect()
        }
        PlaceId::Folder(folder) => vec![Section::untitled(SectionId::All, rows(&|chat| chat.folder == *folder))],
        PlaceId::Requests => vec![Section::untitled(
            SectionId::All,
            (0..snapshot.requests.len()).map(Row::Request).collect(),
        )],
        PlaceId::Saved | PlaceId::Scheduled => {
            let by_room: HashMap<&RoomId, usize> = order
                .iter()
                .rev()
                .filter_map(|&index| Some((chats[index].id.room()?, index)))
                .collect();
            let chat = |room: &RoomId| by_room.get(room).copied();
            let rows = if *place == PlaceId::Saved {
                (snapshot.saved.iter().enumerate())
                    .map(|(message, saved)| Row::Saved {
                        message,
                        chat: chat(&saved.room),
                    })
                    .collect()
            } else {
                (snapshot.scheduled.iter().enumerate())
                    .map(|(message, scheduled)| Row::Scheduled {
                        message,
                        chat: chat(&scheduled.room),
                    })
                    .collect()
            };
            vec![Section::untitled(SectionId::All, rows)]
        }
        PlaceId::Reminders => {
            let mut reminded: Vec<(usize, SystemTime)> = order
                .iter()
                .filter_map(|&index| chats[index].reminder.map(|reminder| (index, reminder)))
                .collect();
            reminded.sort_by_key(|&(_, reminder)| reminder);
            vec![Section::untitled(
                SectionId::All,
                reminded.into_iter().map(|(index, _)| Row::Chat(index)).collect(),
            )]
        }
        PlaceId::Network(network) => vec![Section::untitled(
            SectionId::All,
            rows(&|chat| in_inbox(chat) && chat.network == *network),
        )],
        PlaceId::Label(id) => snapshot
            .labels
            .iter()
            .find(|label| label.id == *id)
            .map(|label| {
                let shown = rows(&|chat| chat.folder != Folder::Archive && label.chats.contains(&chat.id));
                vec![Section::untitled(SectionId::All, shown)]
            })
            .unwrap_or_default(),
        PlaceId::Space(id) => space_sections(snapshot, &order, id),
    }
}

/// A space's own inbox chats, then a titled section for each space inside it.
fn space_sections(snapshot: &Snapshot, order: &[usize], id: &RoomId) -> Vec<Section> {
    let Some(space) = snapshot.spaces.iter().find(|space| space.id == *id) else {
        return Vec::new();
    };
    let children: Vec<&Space> = snapshot
        .spaces
        .iter()
        .filter(|space| space.parents.contains(id))
        .collect();
    let in_children: HashSet<&ChatId> = children.iter().flat_map(|child| &child.chats).collect();
    let mut shown: HashSet<usize> = HashSet::new();
    let mut take = |admits: &dyn Fn(&ChatId) -> bool| -> Vec<Row> {
        order
            .iter()
            .filter(|&&index| {
                let chat = &snapshot.chats[index];
                chat.folder == Folder::Inbox && admits(&chat.id) && shown.insert(index)
            })
            .map(|&index| Row::Chat(index))
            .collect()
    };
    let own = take(&|chat| space.chats.contains(chat) && !in_children.contains(chat));
    let mut sections = vec![Section::untitled(SectionId::Space(space.id.clone()), own)];
    for child in children {
        sections.push(Section {
            id: SectionId::Space(child.id.clone()),
            title: Some(child.name.clone()),
            rows: take(&|chat| child.chats.contains(chat)),
        });
    }
    sections.retain(|section| !section.rows.is_empty());
    sections
}

#[cfg(test)]
pub(super) mod tests {
    use std::time::Duration;

    use super::*;
    use crate::chat::{Label, Request, SavedKind, SavedMessage};

    pub(in crate::places) fn chat(id: &str, network: &str) -> Chat {
        Chat {
            id: id.into(),
            name: id.to_uppercase(),
            preview: None,
            date: None,
            unread_count: 0,
            is_marked_unread: false,
            is_muted: false,
            network: Network::from_id(network),
            avatar: None,
            member_avatars: Vec::new(),
            reminder: None,
            is_group: false,
            folder: Folder::Inbox,
            pinned: None,
            rooms: Vec::new(),
            default_room: None,
        }
    }

    fn space(id: &str, chats: &[&str], parents: &[&str]) -> Space {
        Space {
            id: id.into(),
            name: id.to_owned(),
            avatar: None,
            chats: chats.iter().map(|&chat| chat.into()).collect(),
            parents: parents.iter().map(|&parent| parent.into()).collect(),
        }
    }

    fn at(seconds: u64) -> SystemTime {
        SystemTime::UNIX_EPOCH + Duration::from_secs(1_800_000_000 + seconds)
    }

    fn shared(chats: Vec<Chat>) -> Vec<Arc<Chat>> {
        chats.into_iter().map(Arc::new).collect()
    }

    fn snapshot() -> Snapshot {
        Snapshot {
            chats: shared(vec![
                Chat {
                    unread_count: 2,
                    ..chat("a", "whatsapp")
                },
                Chat {
                    unread_count: 1,
                    is_muted: true,
                    ..chat("b", "whatsapp")
                },
                Chat {
                    folder: Folder::Archive,
                    ..chat("c", "signal")
                },
                Chat {
                    unread_count: 1,
                    ..chat("d", "signal")
                },
            ]),
            spaces: vec![space("s", &["a", "c", "d"], &[]), space("t", &["d"], &["s"])],
            ..Snapshot::default()
        }
    }

    fn ids(places: &[ListedPlace]) -> Vec<String> {
        places.iter().map(|place| place.id.key().to_string()).collect()
    }

    fn chat_ids(snapshot: &Snapshot, sections: &[Section]) -> Vec<Vec<String>> {
        sections
            .iter()
            .map(|section| {
                section
                    .rows
                    .iter()
                    .map(|row| match row {
                        Row::Chat(index) => snapshot.chats[*index].id.to_string(),
                        other => format!("{other:?}"),
                    })
                    .collect()
            })
            .collect()
    }

    #[test]
    fn folders_networks_and_spaces_count_unmuted_unread_inbox_chats() {
        let places = places(&snapshot(), &Arrangement::default(), at(0));
        assert_eq!(
            ids(&places),
            [
                "folder:inbox",
                "folder:lowPriority",
                "folder:archive",
                "network:whatsapp",
                "network:signal",
                "space:s"
            ]
        );
        assert_eq!(
            places.iter().map(|place| place.unread).collect::<Vec<_>>(),
            [2, 0, 0, 1, 1, 2]
        );
    }

    #[test]
    fn a_place_shows_its_inbox_chats() {
        let snapshot = snapshot();
        let network = sections(
            &snapshot,
            &PlaceId::Network(Network::from_id("signal")),
            ChatOrder::NewestMessage,
        );
        assert_eq!(chat_ids(&snapshot, &network), [["d"]]);
        let archive = sections(&snapshot, &PlaceId::Folder(Folder::Archive), ChatOrder::NewestMessage);
        assert_eq!(chat_ids(&snapshot, &archive), [["c"]]);
    }

    #[test]
    fn a_space_lists_its_own_chats_then_one_section_per_space_inside() {
        let snapshot = snapshot();
        let sections = sections(&snapshot, &PlaceId::Space("s".into()), ChatOrder::NewestMessage);
        assert_eq!(
            sections
                .iter()
                .map(|section| section.title.as_deref())
                .collect::<Vec<_>>(),
            [None, Some("t")]
        );
        assert_eq!(chat_ids(&snapshot, &sections), [["a"], ["d"]]);
    }

    #[test]
    fn the_arrangement_orders_and_hides_places_but_never_the_inbox() {
        let arrangement = Arrangement {
            order: vec!["network:signal".into()],
            hidden: ["network:whatsapp".into(), "folder:inbox".into()].into(),
        };
        let places = places(&snapshot(), &arrangement, at(0));
        let networks: Vec<_> = places
            .iter()
            .filter(|place| matches!(place.id, PlaceId::Network(_)))
            .collect();
        assert_eq!(
            ids(&networks.into_iter().cloned().collect::<Vec<_>>()),
            ["network:signal", "network:whatsapp"]
        );
        let hidden: Vec<_> = places.iter().filter(|place| place.is_hidden).cloned().collect();
        assert_eq!(ids(&hidden), ["network:whatsapp"]);
    }

    #[test]
    fn chats_go_by_their_newest_message_not_the_servers_order() {
        let snapshot = Snapshot {
            chats: shared(vec![
                Chat {
                    date: Some(at(0) - Duration::from_hours(24 * 30)),
                    ..chat("joined", "matrix")
                },
                chat("empty", "matrix"),
                Chat {
                    date: Some(at(0)),
                    ..chat("fresh", "matrix")
                },
                Chat {
                    date: Some(at(0) - Duration::from_hours(1)),
                    ..chat("middle", "matrix")
                },
            ]),
            ..Snapshot::default()
        };
        assert_eq!(
            chat_ids(
                &snapshot,
                &sections(&snapshot, &PlaceId::INBOX, ChatOrder::NewestMessage)
            ),
            [["fresh", "middle", "joined", "empty"]]
        );
    }

    #[test]
    fn last_activity_keeps_the_servers_order_and_newest_message_sorts_by_date() {
        // the server's order: the old chat's photo was filled in just now (an edit).
        let snapshot = Snapshot {
            chats: shared(vec![
                Chat {
                    date: Some(at(0) - Duration::from_hours(24 * 30)),
                    ..chat("filled", "whatsapp")
                },
                Chat {
                    date: Some(at(0)),
                    ..chat("written", "whatsapp")
                },
            ]),
            ..Snapshot::default()
        };
        assert_eq!(
            chat_ids(&snapshot, &sections(&snapshot, &PlaceId::INBOX, ChatOrder::Activity)),
            [["filled", "written"]]
        );
        assert_eq!(
            chat_ids(
                &snapshot,
                &sections(&snapshot, &PlaceId::INBOX, ChatOrder::NewestMessage)
            ),
            [["written", "filled"]]
        );
        assert_eq!(ChatOrder::default(), ChatOrder::Activity);
    }

    #[test]
    fn the_inbox_puts_pinned_chats_in_a_grid_in_their_order() {
        let snapshot = Snapshot {
            chats: shared(vec![
                Chat {
                    date: Some(at(120)),
                    pinned: Some(2.0),
                    ..chat("a", "matrix")
                },
                Chat {
                    date: Some(at(60)),
                    pinned: Some(1.0),
                    ..chat("b", "matrix")
                },
                Chat {
                    date: Some(at(0)),
                    ..chat("c", "matrix")
                },
            ]),
            ..Snapshot::default()
        };
        let sections = sections(&snapshot, &PlaceId::INBOX, ChatOrder::NewestMessage);
        assert_eq!(
            sections.iter().map(Section::style).collect::<Vec<_>>(),
            [SectionStyle::Grid, SectionStyle::List]
        );
        assert_eq!(chat_ids(&snapshot, &sections), [vec!["b", "a"], vec!["c"]]);
    }

    #[test]
    fn the_apps_lists_show_when_they_hold_something() {
        let mut snapshot = snapshot();
        Arc::make_mut(&mut snapshot.chats[0]).reminder = Some(at(0));
        Arc::make_mut(&mut snapshot.chats[3]).reminder = Some(at(3_600));
        snapshot.saved = vec![Arc::new(SavedMessage {
            event: "$e".into(),
            room: "d".into(),
            sender_name: "D".to_owned(),
            is_own: false,
            body: "hi".to_owned(),
            kind: SavedKind::Text,
            file_name: String::new(),
            date: SystemTime::UNIX_EPOCH,
            saved_at: SystemTime::UNIX_EPOCH,
        })];
        snapshot.requests = vec![Arc::new(Request {
            id: "!invite".into(),
            name: "Invite".to_owned(),
            avatar: None,
            inviter_name: String::new(),
            is_direct: true,
        })];
        snapshot.labels = vec![Label {
            id: "work".into(),
            name: "Work".to_owned(),
            chats: ["a".into(), "c".into()].into(),
        }];
        let places = places(&snapshot, &Arrangement::default(), at(60));
        let listed: Vec<(String, u32)> = places
            .iter()
            .map(|place| (place.id.key().to_string(), place.unread))
            .collect();
        assert_eq!(listed[3..5], [("reminders".to_owned(), 1), ("saved".to_owned(), 0)]);
        assert_eq!(listed[5], ("requests".to_owned(), 1));
        assert_eq!(listed.last(), Some(&("label:work".to_owned(), 1)));
        assert_eq!(places.last().and_then(|place| place.name.as_deref()), Some("Work"));
        // the soonest reminder first; a saved message with its chat; the label without the archive.
        let reminders = sections(&snapshot, &PlaceId::Reminders, ChatOrder::NewestMessage);
        assert_eq!(chat_ids(&snapshot, &reminders), [["a", "d"]]);
        let saved = sections(&snapshot, &PlaceId::Saved, ChatOrder::NewestMessage);
        assert_eq!(
            saved[0].rows,
            [Row::Saved {
                message: 0,
                chat: Some(3)
            }]
        );
        let label = sections(&snapshot, &PlaceId::Label("work".into()), ChatOrder::NewestMessage);
        assert_eq!(chat_ids(&snapshot, &label), [["a"]]);
        assert!(sections(&snapshot, &PlaceId::Label("gone".into()), ChatOrder::NewestMessage).is_empty());
    }
}
