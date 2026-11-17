//! The app's badge: the inbox's chats with unread messages, and what a notification needs to keep
//! the count while the app is not running (the extension cannot compose the list).

use std::collections::HashSet;

use super::list::counts;
use super::{Arrangement, InboxRules};
use crate::chat::{Chat, Folder, Snapshot};
use crate::ids::{ChatId, RoomId};

/// The inbox's count, with the chats it counts and the rooms it never counts.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Badge {
    /// The inbox's chats with unread messages that are not muted: the inbox's own badge.
    pub count: u32,
    /// The chats counted, by their ids and, for a merged chat, its rooms' too: a message in any
    /// of them leaves the count as it is.
    pub counted: HashSet<ChatId>,
    /// The rooms whose messages the inbox does not count: those of the archive, of low priority
    /// (a place's rule keeping them out of the inbox too) and of muted chats.
    pub uncounted: HashSet<RoomId>,
}

/// The badge of `snapshot` as the user arranged it. A read chat of the inbox that is not muted is
/// in neither set: its next message counts.
#[must_use]
pub(crate) fn badge(snapshot: &Snapshot, arrangement: &Arrangement) -> Badge {
    let rules = InboxRules::new(arrangement, &snapshot.spaces);
    let mut badge = Badge::default();
    for chat in &snapshot.chats {
        if rules.folder_of(chat) != Folder::Inbox || chat.is_muted {
            badge.uncounted.extend(rooms(chat).cloned());
        } else if counts(chat) {
            badge.count = badge.count.saturating_add(1);
            badge.counted.insert(chat.id.clone());
            badge
                .counted
                .extend(chat.rooms.iter().map(|room| ChatId::Room(room.id.clone())));
        }
    }
    badge
}

/// A chat's rooms: a merged chat's, else its own.
fn rooms(chat: &Chat) -> impl Iterator<Item = &RoomId> {
    chat.id.room().into_iter().chain(chat.rooms.iter().map(|room| &room.id))
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;
    use std::time::SystemTime;

    use super::*;
    use crate::chat::{ChatRoom, NotificationMode};
    use crate::network::Network;
    use crate::places::list::places;
    use crate::places::list::tests::chat;
    use crate::places::{InboxRule, PlaceId};

    fn snapshot(chats: Vec<Chat>) -> Snapshot {
        Snapshot {
            chats: chats.into_iter().map(Arc::new).collect(),
            ..Snapshot::default()
        }
    }

    fn unread(chat: Chat) -> Chat {
        Chat {
            unread_count: 1,
            ..chat
        }
    }

    fn ids(ids: &[&str]) -> HashSet<ChatId> {
        ids.iter().map(|&id| id.into()).collect()
    }

    fn rooms(ids: &[&str]) -> HashSet<RoomId> {
        ids.iter().map(|&id| id.into()).collect()
    }

    #[test]
    fn the_badge_counts_what_the_inbox_counts() {
        let snapshot = snapshot(vec![
            unread(chat("a", "whatsapp")),
            Chat {
                is_marked_unread: true,
                ..chat("b", "signal")
            },
            chat("c", "whatsapp"),
            Chat {
                is_muted: true,
                notifications: Some(NotificationMode::Off),
                ..unread(chat("d", "signal"))
            },
            Chat {
                folder: Folder::Archive,
                ..unread(chat("e", "signal"))
            },
        ]);
        let arrangement = Arrangement::default();
        let inbox = places(&snapshot, &arrangement, SystemTime::UNIX_EPOCH)
            .into_iter()
            .find(|place| place.id == PlaceId::INBOX)
            .map(|place| place.unread);
        let badge = badge(&snapshot, &arrangement);
        assert_eq!(Some(badge.count), inbox);
        assert_eq!(badge.count, 2);
        assert_eq!(badge.counted, ids(&["a", "b"]));
    }

    #[test]
    fn a_read_chat_of_the_inbox_is_neither_counted_nor_left_out() {
        let badge = badge(&snapshot(vec![chat("a", "whatsapp")]), &Arrangement::default());
        assert_eq!(badge, Badge::default());
    }

    #[test]
    fn archived_low_priority_and_muted_chats_are_not_counted() {
        let snapshot = snapshot(vec![
            Chat {
                folder: Folder::Archive,
                ..chat("a", "whatsapp")
            },
            Chat {
                folder: Folder::LowPriority,
                ..unread(chat("b", "whatsapp"))
            },
            Chat {
                is_muted: true,
                ..chat("c", "whatsapp")
            },
        ]);
        let badge = badge(&snapshot, &Arrangement::default());
        assert_eq!(badge.count, 0);
        assert_eq!(badge.uncounted, rooms(&["a", "b", "c"]));
    }

    #[test]
    fn a_chat_a_place_keeps_out_of_the_inbox_is_not_counted() {
        let arrangement =
            Arrangement::default().with_inbox(PlaceId::Network(Network::from_id("discord")).key(), InboxRule::Never);
        let snapshot = snapshot(vec![unread(chat("a", "discord")), unread(chat("b", "signal"))]);
        let badge = badge(&snapshot, &arrangement);
        assert_eq!(badge.count, 1);
        assert_eq!(badge.counted, ids(&["b"]));
        assert_eq!(badge.uncounted, rooms(&["a"]));
    }

    #[test]
    fn a_merged_chat_counts_once_and_knows_its_rooms() {
        let merged = |id: &str, folder| Chat {
            id: ChatId::Merge(id.into()),
            folder,
            rooms: [("!w", "whatsapp"), ("!s", "signal")]
                .iter()
                .map(|&(room, network)| ChatRoom {
                    id: format!("{room}{id}").as_str().into(),
                    network: Network::from_id(network),
                })
                .collect(),
            ..unread(chat("x", "whatsapp"))
        };
        let snapshot = snapshot(vec![merged("1", Folder::Inbox), merged("2", Folder::Archive)]);
        let badge = badge(&snapshot, &Arrangement::default());
        assert_eq!(badge.count, 1);
        assert_eq!(
            badge.counted,
            [ChatId::Merge("1".into()), "!w1".into(), "!s1".into()]
                .into_iter()
                .collect()
        );
        assert_eq!(badge.uncounted, rooms(&["!w2", "!s2"]));
    }
}
