//! The demo's made-up account: its chats, spaces, invitations, labels and merges, as the Swift
//! demo made them (the same names, networks and patterns), from the room's number.

use std::collections::HashSet;
use std::time::{Duration, SystemTime};

use super::seeded::text;
use super::timeline::OWN_USER;
use crate::chat::{Chat, Folder, Label, Request, Space};
use crate::ids::{ChatId, MediaId, RoomId, UserId};
use crate::merge::Merge;
use crate::network::Network;
use crate::ports::{Member, NotificationMode, Role, RoomDetails, RoomPermissions};
use crate::preview::{Preview, PreviewSource, Sender};

const NAMES: [&str; 12] = [
    "Anna Nováková",
    "Petr Svoboda",
    "Family",
    "Climbing crew",
    "Jana Dvořáková",
    "Tomáš Černý",
    "Work",
    "Lucie Veselá",
    "Martin Horák",
    "Book club",
    "Eva Marková",
    "Ondřej Pokorný",
];

const NETWORKS: [Network; 6] = [
    Network::WhatsApp,
    Network::Signal,
    Network::Instagram,
    Network::Messenger,
    Network::Telegram,
    Network::Matrix,
];

/// The pictures' version: the demo draws each room's picture from its id.
const PICTURE: &str = "1";

/// The demo's room `index`.
pub(crate) fn room_id(index: usize) -> RoomId {
    RoomId::from(format!("!room{index}:demo"))
}

/// The number of a demo room (`!room12:demo` is 12).
pub(crate) fn room_index(room: &str) -> Option<usize> {
    room.strip_prefix("!room")?.strip_suffix(":demo")?.parse().ok()
}

/// What the user changed of a chat from its menu.
#[derive(Clone, Debug, Default, PartialEq)]
pub(crate) struct ChatState {
    pub(crate) low_priority: Option<bool>,
    pub(crate) archived: Option<bool>,
    pub(crate) muted: Option<bool>,
    pub(crate) unread: Option<bool>,
    pub(crate) pinned: Option<f64>,
    pub(crate) deleted: bool,
    /// Renamed from its details.
    pub(crate) name: Option<String>,
    /// Its picture changed from its details.
    pub(crate) avatar: Option<PictureChange>,
    /// Its topic changed from its details (empty removed it).
    pub(crate) topic: Option<String>,
    /// Its notifications set from its details; `None` follows `muted`.
    pub(crate) notifications: Option<NotificationMode>,
}

/// A room's picture as the user changed it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum PictureChange {
    /// A new one.
    Set(MediaId),
    /// None.
    Removed,
}

/// Room `index`'s picture, as made up or as the user changed it.
fn avatar(index: usize, changed: &ChatState) -> Option<MediaId> {
    match &changed.avatar {
        Some(PictureChange::Set(avatar)) => Some(avatar.clone()),
        Some(PictureChange::Removed) => None,
        None => (index % 4 != 3).then(|| MediaId::from(PICTURE)),
    }
}

/// Room `index`'s chat as made up, with what the user changed (`state`, `None` when nothing):
/// `None` once deleted. Its newest message came `index` half hours before `start`.
pub(crate) fn chat(index: usize, start: SystemTime, state: Option<&ChatState>) -> Option<Chat> {
    let default = ChatState::default();
    let changed = state.unwrap_or(&default);
    if changed.deleted {
        return None;
    }
    let name = changed.name.clone().unwrap_or_else(|| made_name(index));
    let is_group = is_group(index);
    let avatar = avatar(index, changed);
    let folder_by_default = if index % 11 == 10 {
        Folder::Archive
    } else if index % 13 == 12 {
        Folder::LowPriority
    } else {
        Folder::Inbox
    };
    let folder = match (changed.archived, changed.low_priority) {
        (Some(true), _) => Folder::Archive,
        (None, Some(true)) => Folder::LowPriority,
        (Some(false), _) | (None, Some(false)) => Folder::Inbox,
        (None, None) => folder_by_default,
    };
    let mut unread_count = if index.is_multiple_of(7) {
        u32::try_from(index % 5).unwrap_or(0) + 1
    } else {
        0
    };
    let mut is_marked_unread = false;
    if let Some(unread) = changed.unread {
        is_marked_unread = unread;
        if !unread {
            unread_count = 0;
        }
    }
    // the first three are pinned until the user changes them.
    let pinned = match state {
        Some(changed) => changed.pinned,
        None => (index < 3).then(|| f64::from(u32::try_from(index).unwrap_or(0))),
    };
    let ago = Duration::from_secs(u64::try_from(index).unwrap_or(0) * 1_800);
    let preview_text = text(u64::try_from(index).unwrap_or(0));
    Some(Chat {
        id: ChatId::Room(room_id(index)),
        name,
        preview: Some(Preview::new(
            PreviewSource::Text(&preview_text),
            Sender::Other(""),
            false,
        )),
        date: Some(start.checked_sub(ago).unwrap_or(start)),
        unread_count,
        // some unread groups mention the user.
        unread_mentions: u32::from(is_group && unread_count > 0 && index.is_multiple_of(3)),
        is_marked_unread,
        is_muted: notifications(index, changed).is_quiet(),
        notifications: Some(notifications(index, changed)),
        network: NETWORKS[index % NETWORKS.len()].clone(),
        // a group with no picture shows two members' pictures.
        member_avatars: if is_group && avatar.is_none() {
            vec![MediaId::from("demo-@friend0:demo"), MediaId::from("demo-@friend1:demo")]
        } else {
            Vec::new()
        },
        avatar,
        reminder: None,
        is_group,
        folder,
        pinned,
        rooms: Vec::new(),
        default_room: None,
    })
}

fn made_name(index: usize) -> String {
    if index < NAMES.len() {
        NAMES[index].to_owned()
    } else {
        format!("{} {index}", NAMES[index % NAMES.len()])
    }
}

fn is_group(index: usize) -> bool {
    [2, 3, 6, 9].contains(&(index % NAMES.len()))
}

/// How many have joined room `index`: two in a conversation; a work group has hundreds, to search.
fn member_count(index: usize) -> usize {
    match index % NAMES.len() {
        2 => 6,
        3 => 18,
        6 => 240,
        9 => 9,
        _ => 2,
    }
}

/// Whether the user is an admin of room `index`: of the family and the climbing crew, not of work
/// or the book club, which others run.
fn is_own_admin(index: usize) -> bool {
    matches!(index % NAMES.len(), 2 | 3)
}

const FIRST_NAMES: [&str; 16] = [
    "Adam", "Barbora", "Cyril", "Dana", "Emil", "Filip", "Gabriela", "Hana", "Ivan", "Jitka", "Karel", "Lenka",
    "Marek", "Nikola", "Oskar", "Pavla",
];

const LAST_NAMES: [&str; 15] = [
    "Novák",
    "Kučera",
    "Veselý",
    "Horáková",
    "Němec",
    "Marek",
    "Pospíšilová",
    "Hájek",
    "Jelínek",
    "Král",
    "Růžička",
    "Beneš",
    "Fiala",
    "Sedláčková",
    "Doležal",
];

/// Room `index`'s details, with what the user changed (`state`).
pub(crate) fn details(index: usize, state: Option<&ChatState>) -> RoomDetails {
    let default = ChatState::default();
    let changed = state.unwrap_or(&default);
    let group = is_group(index);
    let admin = group && is_own_admin(index);
    let made_topic = group.then(|| match index % NAMES.len() {
        2 => "Sunday lunches, birthdays and photos of the kids".to_owned(),
        3 => "Wednesdays at the wall, weekends on the rock. Bring your own chalk.".to_owned(),
        6 => "Announcements and questions for the whole company".to_owned(),
        _ => "One book a month; we meet on the last Thursday".to_owned(),
    });
    let topic = match &changed.topic {
        Some(topic) if topic.is_empty() => None,
        Some(topic) => Some(topic.clone()),
        None => made_topic,
    };
    RoomDetails {
        id: room_id(index),
        name: changed.name.clone().unwrap_or_else(|| made_name(index)),
        topic,
        avatar: avatar(index, changed),
        address: (group && index % NAMES.len() == 3).then(|| "#climbing:demo".to_owned()),
        is_encrypted: index % 5 != 4,
        is_direct: !group,
        joined_members: u64::try_from(member_count(index)).unwrap_or(u64::MAX),
        notifications: notifications(index, changed),
        may: RoomPermissions {
            rename: admin,
            change_topic: admin,
            change_avatar: admin,
        },
    }
}

/// Room `index`'s members, the user first: the person of a conversation, a group's made-up people.
pub(crate) fn members(index: usize, state: Option<&ChatState>) -> Vec<Member> {
    let own = Member {
        user: UserId::from(OWN_USER),
        name: "Me".to_owned(),
        avatar: None,
        role: if is_group(index) && is_own_admin(index) {
            Role::Admin
        } else {
            Role::Member
        },
        is_own: true,
    };
    if !is_group(index) {
        let name = state
            .and_then(|state| state.name.clone())
            .unwrap_or_else(|| made_name(index));
        let user = format!("@friend{index}:demo");
        return vec![
            own,
            Member {
                avatar: (index % 4 != 3).then(|| MediaId::from(format!("demo-{user}"))),
                user: UserId::from(user),
                name,
                role: Role::Member,
                is_own: false,
            },
        ];
    }
    let mut members = vec![own];
    members.extend((1..member_count(index)).map(|number| {
        let user = format!("@member{number}-{index}:demo");
        Member {
            name: format!(
                "{} {}",
                FIRST_NAMES[(number * 7 + index) % FIRST_NAMES.len()],
                LAST_NAMES[(number * 11 + index / 2) % LAST_NAMES.len()]
            ),
            avatar: (number % 3 != 0).then(|| MediaId::from(format!("demo-{user}"))),
            user: UserId::from(user),
            // the groups others run have one admin and a few moderators.
            role: match (number, is_own_admin(index)) {
                (1, false) => Role::Admin,
                (2..=3, _) => Role::Moderator,
                _ => Role::Member,
            },
            is_own: false,
        }
    }));
    members
}

/// Jana's chats on two networks, merged.
pub(crate) fn merges() -> Vec<Merge> {
    vec![Merge {
        id: "demo-jana".into(),
        name: "Jana Dvořáková".to_owned(),
        rooms: vec![room_id(4), room_id(18)],
        default_room: room_id(4),
    }]
}

/// The spaces: a family's, and work with a space for design inside.
pub(crate) fn spaces(rooms: usize) -> Vec<Space> {
    let chats = |admits: &dyn Fn(usize) -> bool| -> HashSet<ChatId> {
        (0..rooms)
            .filter(|&index| admits(index))
            .map(|index| ChatId::Room(room_id(index)))
            .collect()
    };
    vec![
        Space {
            id: RoomId::from("!space-family:demo"),
            name: "Family".to_owned(),
            avatar: Some(MediaId::from(PICTURE)),
            chats: chats(&|index| index.is_multiple_of(5)),
            parents: Vec::new(),
        },
        Space {
            id: RoomId::from("!space-work:demo"),
            name: "Work".to_owned(),
            avatar: None,
            chats: chats(&|index| index % 7 == 1 || index % 9 == 2),
            parents: Vec::new(),
        },
        Space {
            id: RoomId::from("!space-work-design:demo"),
            name: "design".to_owned(),
            avatar: None,
            chats: chats(&|index| index % 9 == 2),
            parents: vec![RoomId::from("!space-work:demo")],
        },
    ]
}

/// The invitations, until answered.
pub(crate) fn requests() -> Vec<Request> {
    vec![
        Request {
            id: RoomId::from("!invite-1:demo"),
            name: "Lucie Veselá".to_owned(),
            avatar: None,
            inviter_name: "Lucie Veselá".to_owned(),
            is_direct: true,
        },
        Request {
            id: RoomId::from("!invite-2:demo"),
            name: "Board games".to_owned(),
            avatar: None,
            inviter_name: "Petr Svoboda".to_owned(),
            is_direct: false,
        },
    ]
}

/// The user's label for work.
pub(crate) fn labels() -> Vec<Label> {
    vec![Label {
        id: "demo-work".into(),
        name: "Work".to_owned(),
        chats: [1, 6, 9]
            .into_iter()
            .map(|index| ChatId::Room(room_id(index)))
            .collect(),
    }]
}

/// A made-up message's text and sender, from its id (`<room>/<number>`, as the demo's threads
/// number them): what a saved message keeps.
pub(crate) fn message(event: &str) -> Option<(String, bool, &'static str)> {
    const PEOPLE: [&str; 3] = ["Anna Nováková", "Petr Svoboda", "Jana Dvořáková"];
    let (room, number) = event.rsplit_once('/')?;
    let number: u64 = number.parse().ok()?;
    let is_own = (number / 3).is_multiple_of(2);
    let seed = stable(room) % 97;
    let index = usize::try_from(number % 3).unwrap_or(0);
    Some((text(number * 31 + 7 + seed), is_own, PEOPLE[index]))
}

/// A hash that is the same in every run (FNV-1a), as the Swift demo seeded each chat's words.
pub(crate) fn stable(text: &str) -> u64 {
    text.bytes().fold(0xcbf2_9ce4_8422_2325_u64, |hash, byte| {
        (hash ^ u64::from(byte)).wrapping_mul(0x100_0000_01b3)
    }) >> 1
}

/// When room `index`'s messages notify: as the user set them, else one in seventeen muted.
fn notifications(index: usize, changed: &ChatState) -> NotificationMode {
    changed
        .notifications
        .unwrap_or(if changed.muted.unwrap_or(index % 17 == 16) {
            NotificationMode::Off
        } else {
            NotificationMode::Default
        })
}

#[cfg(test)]
mod tests {
    use std::time::SystemTime;

    use super::{ChatState, chat, room_index};
    use crate::chat::Folder;

    #[test]
    fn rooms_are_made_up_by_their_number() {
        let start = SystemTime::UNIX_EPOCH + std::time::Duration::from_hours(500_000);
        let first = chat(0, start, None).unwrap();
        assert_eq!(first.name, "Anna Nováková");
        assert_eq!(first.pinned, Some(0.0));
        assert_eq!(first.unread_count, 1);
        let later = chat(22, start, None).unwrap();
        assert_eq!(later.name, "Eva Marková 22");
        assert_eq!(later.folder, Folder::Inbox);
        assert_eq!(chat(10, start, None).unwrap().folder, Folder::Archive);
        assert_eq!(chat(3, start, None).unwrap().member_avatars.len(), 2);
        let deleted = ChatState {
            deleted: true,
            ..ChatState::default()
        };
        assert!(chat(5, start, Some(&deleted)).is_none());
        assert_eq!(room_index("!room42:demo"), Some(42));
        assert_eq!(room_index("!invite-1:demo"), None);
    }
}
