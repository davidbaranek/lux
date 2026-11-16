//! How the user organized the account's chats, kept with the account so every device shows the
//! same: archived and deleted chats, reminders, merged chats, labels, saved messages, the
//! places' arrangement. And the chat list with all of it applied to the rooms.

mod labels;
mod marks;
pub mod pins;

use std::collections::HashSet;
use std::sync::Arc;

pub(crate) use labels::checked_name;
pub use labels::{LabelError, LabelRecord, LabelRecords, WholeLabel};
pub use marks::{ChatMarks, Reminder, Reminders};

use crate::chat::{Chat, Folder, Label, SavedMessage};
use crate::ids::{ChatId, MergeId, RoomId};
use crate::merge::{self, Merge};
use crate::places::Arrangement;

/// Everything the account keeps of how its chats are organized, read together.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Organized {
    /// The archived and deleted chats.
    pub marks: ChatMarks,
    /// The reminders, by room.
    pub reminders: Reminders,
    /// The merged chats.
    pub merges: Vec<Merge>,
    /// The labels.
    pub labels: Vec<Label>,
    /// The saved messages, the last saved first.
    pub saved: Vec<SavedMessage>,
    /// How the places are arranged.
    pub arrangement: Arrangement,
}

impl Organized {
    /// The chat list from the rooms' chats (in the server's order): deleted chats left out,
    /// archived ones in the archive, each with its reminder until answered, and each merge's
    /// rooms folded into one chat. A chat none of it changes is the room's own, shared.
    #[must_use]
    pub fn compose<'a>(&self, rooms: impl IntoIterator<Item = &'a Arc<Chat>>) -> Vec<Arc<Chat>> {
        let chats = rooms
            .into_iter()
            .filter(|chat| !self.marks.is_hidden(chat))
            .map(|chat| {
                let folder = if self.marks.is_archived(chat) {
                    Folder::Archive
                } else {
                    chat.folder
                };
                let reminder = chat
                    .id
                    .room()
                    .and_then(|room| self.reminders.get(room))
                    .filter(|reminder| !reminder.is_answered_by(chat))
                    .map(|reminder| reminder.at);
                if folder == chat.folder && reminder == chat.reminder {
                    return Arc::clone(chat);
                }
                Arc::new(Chat {
                    reminder,
                    folder,
                    ..Chat::clone(chat)
                })
            })
            .collect();
        merge::fold(chats, &self.merges)
    }

    /// The merges with `rooms` merged as one chat named `name`, writing to `default_room`
    /// (the first room when it is none of them): a merge that holds any of the rooms takes the
    /// others in, keeping its id; else a new one with the id `new_id`. The merged chat's id.
    #[must_use]
    pub fn merging(
        &self,
        rooms: &[RoomId],
        name: &str,
        default_room: &RoomId,
        new_id: MergeId,
    ) -> (Vec<Merge>, ChatId) {
        let mut rooms: Vec<RoomId> = rooms.to_vec();
        let mut seen = HashSet::new();
        rooms.retain(|room| seen.insert(room.clone()));
        let mut merges = self.merges.clone();
        let existing = merges
            .iter()
            .position(|merge| merge.rooms.iter().any(|room| rooms.contains(room)));
        let default_room = if rooms.contains(default_room) {
            default_room.clone()
        } else {
            rooms.first().cloned().unwrap_or_else(|| default_room.clone())
        };
        // a room is in one merge only.
        let id = existing
            .and_then(|index| merges.get(index))
            .map_or(new_id, |merge| merge.id.clone());
        merges.retain(|merge| merge.id == id || !merge.rooms.iter().any(|room| rooms.contains(room)));
        let merge = Merge {
            id: id.clone(),
            name: name.trim().to_owned(),
            rooms,
            default_room,
        };
        let chat = merge.chat_id();
        match merges.iter_mut().find(|merge| merge.id == id) {
            Some(slot) => *slot = merge,
            None => merges.push(merge),
        }
        (merges, chat)
    }

    /// The merges without the merged chat `chat`.
    #[must_use]
    pub fn unmerging(&self, chat: &ChatId) -> Vec<Merge> {
        let mut merges = self.merges.clone();
        merges.retain(|merge| merge.chat_id() != *chat);
        merges
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;
    use std::time::{Duration, SystemTime};

    use super::{ChatMarks, Organized, Reminder};
    use crate::chat::{Chat, Folder};
    use crate::ids::{ChatId, RoomId};
    use crate::merge::Merge;
    use crate::preview::{Preview, PreviewSource, Sender};

    fn at(minutes: u64) -> SystemTime {
        SystemTime::UNIX_EPOCH + Duration::from_secs(minutes * 60)
    }

    fn chat(id: &str, minutes: u64, own: bool) -> Chat {
        let sender = if own { Sender::Own } else { Sender::Other("Anna") };
        Chat {
            id: id.into(),
            name: id.to_owned(),
            preview: Some(Preview::new(PreviewSource::Text("hi"), sender, false)),
            date: Some(at(minutes)),
            unread_count: 1,
            unread_mentions: 0,
            is_marked_unread: false,
            is_muted: false,
            notifications: None,
            network: crate::network::Network::Matrix,
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

    fn merge(id: &str, rooms: &[&str]) -> Merge {
        Merge {
            id: id.into(),
            name: id.to_uppercase(),
            rooms: rooms.iter().map(|&room| room.into()).collect(),
            default_room: rooms[0].into(),
        }
    }

    #[test]
    fn the_list_applies_marks_reminders_and_merges() {
        let organized = Organized {
            marks: ChatMarks {
                archived: [("!archived".into(), at(5))].into_iter().collect(),
                hidden: [("!deleted".into(), at(5))].into_iter().collect(),
                cleared: [("!deleted".into(), at(5))].into_iter().collect(),
            },
            reminders: [
                (
                    "!a".into(),
                    Reminder {
                        at: at(100),
                        set_at: at(1),
                    },
                ),
                (
                    "!answered".into(),
                    Reminder {
                        at: at(100),
                        set_at: at(1),
                    },
                ),
            ]
            .into_iter()
            .collect(),
            merges: vec![merge("jana", &["!a", "!b"])],
            ..Organized::default()
        };
        let rooms = [
            chat("!archived", 5, false),
            chat("!deleted", 4, false),
            chat("!answered", 3, true),
            chat("!a", 2, false),
            chat("!b", 9, false),
        ]
        .map(Arc::new);
        let list = organized.compose(&rooms);
        let ids: Vec<_> = list.iter().map(|chat| chat.id.to_string()).collect();
        assert_eq!(ids, ["!archived", "!answered", "merge:jana"]);
        assert_eq!(list[0].folder, Folder::Archive);
        assert_eq!(list[1].reminder, None);
        assert_eq!(list[2].reminder, Some(at(100)));
        assert_eq!(list[2].unread_count, 2);
        // a chat none of it changes is the room's own.
        let plain = Organized::default().compose(&rooms);
        assert!(Arc::ptr_eq(&plain[0], &rooms[0]));
    }

    #[test]
    fn a_merged_chat_stands_for_its_rooms() {
        let organized = Organized {
            merges: vec![merge("jana", &["!a", "!b"])],
            ..Organized::default()
        };
        let rooms: Vec<RoomId> = vec!["!a".into(), "!b".into()];
        assert_eq!(ChatId::from("merge:jana").rooms(&organized.merges), rooms);
        assert_eq!(ChatId::from("!c").rooms(&organized.merges), [RoomId::from("!c")]);
        assert!(ChatId::from("merge:gone").rooms(&organized.merges).is_empty());
    }

    #[test]
    fn merging_again_changes_the_merge() {
        let organized = Organized {
            merges: vec![merge("jana", &["!a", "!b"]), merge("other", &["!c", "!d"])],
            ..Organized::default()
        };
        let rooms: Vec<RoomId> = vec!["!a".into(), "!b".into(), "!c".into()];
        let (merges, chat) = organized.merging(&rooms, " Jana ", &"!x".into(), "new".into());
        assert_eq!(chat, ChatId::from("merge:jana"));
        assert_eq!(merges.len(), 1);
        assert_eq!(merges[0].name, "Jana");
        assert_eq!(merges[0].default_room, RoomId::from("!a"));
        assert!(
            organized
                .unmerging(&ChatId::from("merge:other"))
                .iter()
                .all(|merge| merge.id == "jana".into())
        );
    }
}
