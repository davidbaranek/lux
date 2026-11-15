//! Merged chats: one person's chats on several networks, shown as one chat that writes where
//! the conversation is.

use std::collections::HashMap;
use std::sync::Arc;

use crate::chat::{Chat, ChatRoom, Label};
use crate::ids::{ChatId, MergeId, RoomId};

/// One person's chats on several networks, to show as one, as the user merged them.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Merge {
    /// The merge's own id; its chat's is [`Merge::chat_id`].
    pub id: MergeId,
    /// The merged chat's name.
    pub name: String,
    /// Its rooms, in the user's order.
    pub rooms: Vec<RoomId>,
    /// Where it writes when the conversation gives no other room.
    pub default_room: RoomId,
}

impl Merge {
    /// The merged chat's id in the list, which names no room.
    #[must_use]
    pub fn chat_id(&self) -> ChatId {
        ChatId::Merge(self.id.clone())
    }
}

impl ChatId {
    /// The rooms the chat stands for: a merged chat's (none when `merges` has it no more), else
    /// its own.
    #[must_use]
    pub fn rooms(&self, merges: &[Merge]) -> Vec<RoomId> {
        match self {
            Self::Room(room) => vec![room.clone()],
            Self::Merge(id) => merges
                .iter()
                .find(|merge| merge.id == *id)
                .map(|merge| merge.rooms.clone())
                .unwrap_or_default(),
        }
    }

    /// The room a message to the chat goes to: a merged chat's default room (none when `merges`
    /// has it no more), else its own.
    #[must_use]
    pub fn send_room(&self, merges: &[Merge]) -> Option<RoomId> {
        match self {
            Self::Room(room) => Some(room.clone()),
            Self::Merge(id) => merges
                .iter()
                .find(|merge| merge.id == *id)
                .map(|merge| merge.default_room.clone()),
        }
    }
}

/// The labels with each merged chat in those that hold any of its rooms (a label keeps rooms):
/// the list shows the merged chat, and its menu ticks the label. The rooms stay in too, for a
/// merge the list does not fold (fewer than two of its rooms there).
#[must_use]
pub fn label_merges(mut labels: Vec<Label>, merges: &[Merge]) -> Vec<Label> {
    for label in &mut labels {
        for merge in merges {
            if merge
                .rooms
                .iter()
                .any(|room| label.chats.contains(&ChatId::Room(room.clone())))
            {
                label.chats.insert(merge.chat_id());
            }
        }
    }
    labels
}

/// The chats with each merge's rooms (two or more of them there) folded into one, where the
/// first of them was: the merge's name, the newest message, the unread counts added, muted only
/// if all are, pinned if any is (at the first pin's place), the soonest reminder, the rooms in
/// the merge's order. A merge with fewer than two rooms there folds
/// nothing.
#[must_use]
pub fn fold(mut chats: Vec<Arc<Chat>>, merges: &[Merge]) -> Vec<Arc<Chat>> {
    if merges.is_empty() {
        return chats;
    }
    let at: HashMap<&RoomId, usize> = chats
        .iter()
        .enumerate()
        .filter_map(|(index, chat)| Some((chat.id.room()?, index)))
        .rev()
        .collect();
    // the chats a merge took (folded in, or replaced by its own): no later merge takes them.
    let mut taken = vec![false; chats.len()];
    let mut folds: Vec<(usize, Chat)> = Vec::new();
    for merge in merges {
        // the rooms there, by their chat's position.
        let mut members: Vec<usize> = Vec::with_capacity(merge.rooms.len());
        let mut rooms: Vec<ChatRoom> = Vec::with_capacity(merge.rooms.len());
        for room in &merge.rooms {
            if let Some(&index) = at.get(room)
                && !taken[index]
                && !members.contains(&index)
            {
                members.push(index);
                rooms.push(ChatRoom {
                    id: room.clone(),
                    network: chats[index].network.clone(),
                });
            }
        }
        let Some(&first) = members.iter().min() else { continue };
        if members.len() < 2 {
            continue;
        }
        // the newest; the first of them in the merge's order on equal dates.
        let newest = members
            .iter()
            .copied()
            // `None` (no message) sorts before any date.
            .reduce(|newest, index| {
                if chats[index].date > chats[newest].date {
                    index
                } else {
                    newest
                }
            })
            .unwrap_or(first);
        let unread_count = members.iter().map(|&index| chats[index].unread_count).sum();
        let unread_mentions = members.iter().map(|&index| chats[index].unread_mentions).sum();
        let is_marked_unread = members.iter().any(|&index| chats[index].is_marked_unread);
        let is_muted = members.iter().all(|&index| chats[index].is_muted);
        let pinned = members.iter().filter_map(|&index| chats[index].pinned).reduce(f64::min);
        let reminder = members.iter().filter_map(|&index| chats[index].reminder).min();
        let mut folded = Chat::clone(&chats[newest]);
        folded.id = merge.chat_id();
        folded.name.clone_from(&merge.name);
        folded.unread_count = unread_count;
        folded.unread_mentions = unread_mentions;
        folded.is_marked_unread = is_marked_unread;
        folded.is_muted = is_muted;
        folded.pinned = pinned;
        folded.reminder = reminder;
        folded.is_group = false;
        folded.rooms = rooms;
        folded.default_room = Some(merge.default_room.clone());
        for &index in &members {
            taken[index] = true;
        }
        folds.push((first, folded));
    }
    if folds.is_empty() {
        return chats;
    }
    let mut keep: Vec<bool> = taken.iter().map(|taken| !taken).collect();
    for (first, folded) in folds {
        chats[first] = Arc::new(folded);
        keep[first] = true;
    }
    let mut kept = keep.into_iter();
    chats.retain(|_| kept.next().unwrap_or(true));
    chats
}

/// The merge `room` is part of, if any (a notification's chat).
#[must_use]
pub fn containing<'a>(merges: &'a [Merge], room: &RoomId) -> Option<&'a Merge> {
    merges.iter().find(|merge| merge.rooms.contains(room))
}

/// The room a new message of a merged chat goes to: the one shown alone, else the room of the
/// conversation's last message (where the other person last wrote, or the user), else the
/// merge's default. `rooms` are the messages' rooms, oldest first, `None` where not known.
#[must_use]
pub fn send_room<'a>(
    shown: Option<&'a RoomId>,
    rooms: impl DoubleEndedIterator<Item = Option<&'a RoomId>>,
    default: &'a RoomId,
) -> &'a RoomId {
    shown.or_else(|| rooms.rev().flatten().next()).unwrap_or(default)
}

#[cfg(test)]
mod tests {
    use std::time::{Duration, SystemTime};

    use super::*;
    use crate::chat::Folder;
    use crate::network::Network;
    use crate::preview::Preview;

    fn chat(id: &str, network: &str, minutes: Option<u64>, unread: u32) -> Chat {
        Chat {
            id: id.into(),
            name: id.to_owned(),
            preview: Some(Preview::text(format!("{id} says hi"))),
            date: minutes.map(|minutes| SystemTime::UNIX_EPOCH + Duration::from_secs(minutes * 60)),
            unread_count: unread,
            unread_mentions: 0,
            is_marked_unread: false,
            is_muted: true,
            network: Network::from_id(network),
            avatar: None,
            member_avatars: Vec::new(),
            reminder: None,
            is_group: true,
            folder: Folder::Inbox,
            pinned: None,
            rooms: Vec::new(),
            default_room: None,
        }
    }

    fn merge(rooms: &[&str]) -> Merge {
        Merge {
            id: "jana".into(),
            name: "Jana".to_owned(),
            rooms: rooms.iter().map(|&room| room.into()).collect(),
            default_room: rooms[0].into(),
        }
    }

    #[test]
    fn a_merge_folds_its_rooms_into_one_chat_where_the_first_was() {
        let chats = vec![
            Arc::new(chat("!a", "whatsapp", Some(1), 1)),
            Arc::new(chat("!b", "matrix", Some(9), 0)),
            Arc::new(chat("!c", "telegram", Some(5), 2)),
        ];
        let folded = fold(chats, &[merge(&["!c", "!a"])]);
        assert_eq!(folded.len(), 2);
        let merged = &folded[0];
        assert_eq!(merged.id, ChatId::Merge("jana".into()));
        assert_eq!(merged.name, "Jana");
        // the newest message's: telegram's.
        assert_eq!(merged.preview, Some(Preview::text("!c says hi")));
        assert_eq!(merged.network, Network::Telegram);
        assert_eq!(merged.unread_count, 3);
        assert!(merged.is_muted && !merged.is_group);
        assert_eq!(
            merged.rooms.iter().map(|room| room.id.as_str()).collect::<Vec<_>>(),
            ["!c", "!a"]
        );
        assert_eq!(merged.default_room, Some("!c".into()));
        assert_eq!(folded[1].id, ChatId::from("!b"));
    }

    #[test]
    fn a_merge_with_one_room_there_folds_nothing() {
        let chats = vec![
            Arc::new(chat("!a", "whatsapp", Some(1), 0)),
            Arc::new(chat("!b", "matrix", None, 0)),
        ];
        assert_eq!(fold(chats.clone(), &[merge(&["!a", "!gone"])]), chats);
    }

    #[test]
    fn a_new_message_goes_where_the_conversation_is() {
        let (shown, a, b, default): (RoomId, RoomId, RoomId, RoomId) =
            ("!shown".into(), "!a".into(), "!b".into(), "!default".into());
        let rooms = [Some(&a), Some(&b), None];
        assert_eq!(send_room(Some(&shown), rooms.into_iter(), &default), &shown);
        assert_eq!(send_room(None, rooms.into_iter(), &default), &b);
        assert_eq!(send_room(None, [None].into_iter(), &default), &default);
    }

    #[test]
    fn a_label_holding_a_merged_chats_room_holds_the_merged_chat() {
        let jana = merge(&["!wa", "!sig"]);
        let label = |rooms: &[&str]| Label {
            id: "work".into(),
            name: "Work".to_owned(),
            chats: rooms.iter().map(|&room| ChatId::from(room)).collect(),
        };
        let labels = label_merges(
            vec![label(&["!sig", "!other"]), label(&["!other"])],
            std::slice::from_ref(&jana),
        );
        assert!(labels[0].chats.contains(&jana.chat_id()));
        assert!(
            labels[0].chats.contains(&ChatId::from("!sig")),
            "the room stays for an unfolded merge"
        );
        assert!(!labels[1].chats.contains(&jana.chat_id()));
    }
}
