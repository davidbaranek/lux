//! The chats the user archived or deleted, and the reminders to answer them: each kept with the
//! time it was made, which a newer message measures against.

use std::collections::HashMap;
use std::time::SystemTime;

use crate::chat::Chat;
use crate::ids::RoomId;

/// The chats archived or deleted, each with the time of its newest message then.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ChatMarks {
    /// Out of the inbox until a newer message (a muted chat's only by the account itself).
    pub archived: HashMap<RoomId, SystemTime>,
    /// In no list until a newer message.
    pub hidden: HashMap<RoomId, SystemTime>,
    /// Each deleted chat's newest message at its delete, kept after it comes back: its thread
    /// shows only the messages after it.
    pub cleared: HashMap<RoomId, SystemTime>,
}

impl ChatMarks {
    /// Whether `chat` (one room's) is archived now: no newer message came, or the chat is muted
    /// and the newer one is not the account's own.
    #[must_use]
    pub fn is_archived(&self, chat: &Chat) -> bool {
        chat.id
            .room()
            .and_then(|room| self.archived.get(room))
            .is_some_and(|&mark| !is_newer(chat, mark) || (chat.is_muted && !is_own(chat)))
    }

    /// Whether `chat` (one room's) is deleted now: no newer message came.
    #[must_use]
    pub fn is_hidden(&self, chat: &Chat) -> bool {
        chat.id
            .room()
            .and_then(|room| self.hidden.get(room))
            .is_some_and(|&mark| !is_newer(chat, mark))
    }

    /// The marks without those of the chats in `chats` a newer message brought back, `None`
    /// when none came back. A muted chat comes back only by the account's own message; a
    /// delete's cut stays.
    #[must_use]
    pub fn without_returned<'a>(&self, chats: impl IntoIterator<Item = &'a Chat>) -> Option<Self> {
        let mut tidied = self.clone();
        for chat in chats {
            let Some(room) = chat.id.room() else { continue };
            if let Some(&mark) = self.archived.get(room)
                && is_newer(chat, mark)
                && (!chat.is_muted || is_own(chat))
            {
                tidied.archived.remove(room);
            }
            if let Some(&mark) = self.hidden.get(room)
                && is_newer(chat, mark)
            {
                tidied.hidden.remove(room);
            }
        }
        (tidied != *self).then_some(tidied)
    }
}

/// A reminder to answer a chat.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Reminder {
    /// When it is due.
    pub at: SystemTime,
    /// When the user asked for it.
    pub set_at: SystemTime,
}

impl Reminder {
    /// Answered: the chat's newest message is the account's own, sent after the reminder was
    /// asked for.
    #[must_use]
    pub fn is_answered_by(&self, chat: &Chat) -> bool {
        is_own(chat) && chat.date.is_some_and(|date| date > self.set_at)
    }
}

/// The reminders, by room.
pub type Reminders = HashMap<RoomId, Reminder>;

fn is_newer(chat: &Chat, mark: SystemTime) -> bool {
    chat.date.is_some_and(|date| date > mark)
}

fn is_own(chat: &Chat) -> bool {
    chat.preview.as_ref().is_some_and(crate::preview::Preview::is_own)
}

#[cfg(test)]
mod tests {
    use std::time::{Duration, SystemTime};

    use super::{ChatMarks, Reminder};
    use crate::chat::{Chat, Folder};
    use crate::preview::{Preview, PreviewSource, Sender};

    pub(crate) fn at(minutes: u64) -> SystemTime {
        SystemTime::UNIX_EPOCH + Duration::from_secs(minutes * 60)
    }

    pub(crate) fn chat(id: &str, minutes: u64, own: bool) -> Chat {
        let sender = if own { Sender::Own } else { Sender::Other("Anna") };
        Chat {
            id: id.into(),
            name: id.to_owned(),
            preview: Some(Preview::new(PreviewSource::Text("hi"), sender, false)),
            date: Some(at(minutes)),
            unread_count: 0,
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

    fn marks(archived: &[(&str, u64)], hidden: &[(&str, u64)]) -> ChatMarks {
        ChatMarks {
            archived: archived
                .iter()
                .map(|&(room, minutes)| (room.into(), at(minutes)))
                .collect(),
            hidden: hidden
                .iter()
                .map(|&(room, minutes)| (room.into(), at(minutes)))
                .collect(),
            cleared: hidden
                .iter()
                .map(|&(room, minutes)| (room.into(), at(minutes)))
                .collect(),
        }
    }

    #[test]
    fn an_archived_chat_comes_back_with_a_newer_message() {
        let marks = marks(&[("!a", 5)], &[]);
        assert!(marks.is_archived(&chat("!a", 5, false)));
        assert!(!marks.is_archived(&chat("!a", 6, false)));
        assert!(!marks.is_archived(&chat("!b", 1, false)));
    }

    #[test]
    fn a_muted_chat_comes_back_only_by_an_own_message() {
        let marks = marks(&[("!a", 5)], &[]);
        let mut muted = chat("!a", 6, false);
        muted.is_muted = true;
        assert!(marks.is_archived(&muted));
        assert_eq!(marks.without_returned([&muted]), None);
        let mut answered = chat("!a", 6, true);
        answered.is_muted = true;
        assert!(!marks.is_archived(&answered));
        assert!(marks.without_returned([&answered]).unwrap().archived.is_empty());
    }

    #[test]
    fn a_deleted_chat_comes_back_with_a_newer_message_and_keeps_its_cut() {
        let marks = marks(&[], &[("!a", 5)]);
        assert!(marks.is_hidden(&chat("!a", 5, false)));
        assert!(!marks.is_hidden(&chat("!a", 7, false)));
        let tidied = marks.without_returned([&chat("!a", 7, false)]).unwrap();
        assert!(tidied.hidden.is_empty());
        assert_eq!(tidied.cleared.len(), 1);
    }

    #[test]
    fn a_reminder_is_answered_by_an_own_message_after_it() {
        let reminder = Reminder {
            at: at(100),
            set_at: at(10),
        };
        assert!(reminder.is_answered_by(&chat("!a", 11, true)));
        assert!(!reminder.is_answered_by(&chat("!a", 9, true)));
        assert!(!reminder.is_answered_by(&chat("!a", 11, false)));
    }
}
