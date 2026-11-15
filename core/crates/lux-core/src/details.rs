//! A chat's details: its members in the order the screen lists them and found as the user types,
//! one notification setting for a merged chat's rooms, and what was shared in it, read back page by
//! page across a merged chat's rooms, the newest first.

use std::collections::VecDeque;

use crate::ids::RoomId;
use crate::ports::{BackendError, ChatDetails, Member, NotificationMode, RoomDetails, SharedItem, SharedKind};
use crate::search::{folded, words};

/// The members in the order the screen lists them: the account first, then by role (creators and
/// admins first), then by name.
pub fn sort_members(members: &mut [Member]) {
    members.sort_by_cached_key(|member| (!member.is_own, member.role, folded(&member.name)));
}

/// The members whose name or id holds every word of `query`, ignoring case and accents, in their
/// order. A query with no words finds them all.
pub fn find_members<'a>(members: &'a [Member], query: &str) -> impl Iterator<Item = &'a Member> {
    let words: Vec<String> = words(query).collect();
    members.iter().filter(move |member| {
        if words.is_empty() {
            return true;
        }
        let name = folded(&member.name);
        let id = folded(member.user.as_str());
        words
            .iter()
            .all(|word| name.contains(word.as_str()) || id.contains(word.as_str()))
    })
}

/// When a chat's messages notify: its rooms' one setting, `None` when they differ (a merged chat
/// whose rooms were set apart, here or on their networks).
#[must_use]
pub fn chat_notifications(rooms: &[RoomDetails]) -> Option<NotificationMode> {
    let first = rooms.first()?.notifications;
    rooms.iter().all(|room| room.notifications == first).then_some(first)
}

/// How many pages of history one [`SharedHistory::next`] reads at most, across the rooms: a chat
/// that shared little is read back a little at a time, as the user asks for more.
const MAX_PAGES: usize = 12;

/// What was shared in a chat, of one kind, read back from the server the newest first, across a
/// merged chat's rooms.
#[derive(Debug)]
pub struct SharedHistory {
    kind: SharedKind,
    rooms: Vec<Cursor>,
}

/// Where one room's history is read to, and what it found that is not given yet.
#[derive(Debug)]
struct Cursor {
    room: RoomId,
    /// The next older page; `None` before the first, and at the start.
    from: Option<String>,
    at_start: bool,
    found: VecDeque<SharedItem>,
}

impl SharedHistory {
    /// The `kind` of item shared in `rooms`.
    #[must_use]
    pub fn new(rooms: Vec<RoomId>, kind: SharedKind) -> Self {
        Self {
            kind,
            rooms: rooms
                .into_iter()
                .map(|room| Cursor {
                    room,
                    from: None,
                    at_start: false,
                    found: VecDeque::new(),
                })
                .collect(),
        }
    }

    /// Every room was read back to its first message, and all it shared was given.
    #[must_use]
    pub fn is_at_start(&self) -> bool {
        self.rooms.iter().all(|room| room.at_start && room.found.is_empty())
    }

    /// The next `want` items, older than those given, the newest first; fewer when the rooms'
    /// starts come first, or when [`MAX_PAGES`] pages found no more (the next call reads on).
    ///
    /// # Errors
    /// When a room's history cannot be read.
    pub async fn next<B: ChatDetails>(&mut self, backend: &B, want: usize) -> Result<Vec<SharedItem>, BackendError> {
        let mut given = Vec::with_capacity(want);
        let mut pages = 0;
        while given.len() < want {
            // an item is given only when no room still to read could have a newer one.
            if let Some(room) = self
                .rooms
                .iter_mut()
                .find(|room| room.found.is_empty() && !room.at_start)
            {
                if pages == MAX_PAGES {
                    break;
                }
                pages += 1;
                let page = backend.shared(&room.room, room.from.as_deref()).await?;
                room.found
                    .extend(page.items.into_iter().filter(|item| item.content.kind() == self.kind));
                room.at_start = page.next.is_none();
                room.from = page.next;
                continue;
            }
            let newest = self
                .rooms
                .iter_mut()
                .filter(|room| !room.found.is_empty())
                .max_by_key(|room| room.found.front().map(|item| item.date));
            match newest.and_then(|room| room.found.pop_front()) {
                Some(item) => given.push(item),
                None => break,
            }
        }
        Ok(given)
    }
}

#[cfg(test)]
mod tests {
    use std::collections::HashMap;
    use std::time::{Duration, SystemTime};

    use super::*;
    use crate::ids::{ChatId, EventId, UserId};
    use crate::ports::{Picture, Role, SharedContent, SharedPage};

    fn member(name: &str, role: Role, is_own: bool) -> Member {
        Member {
            user: UserId::from(format!("@{}:test", name.to_lowercase().replace(' ', "."))),
            name: name.to_owned(),
            avatar: None,
            role,
            is_own,
        }
    }

    #[test]
    fn the_account_comes_first_then_admins_then_by_name() {
        let mut members = vec![
            member("Zdeněk", Role::Member, false),
            member("Ája", Role::Member, false),
            member("Me", Role::Member, true),
            member("Petr", Role::Admin, false),
        ];
        sort_members(&mut members);
        let names: Vec<&str> = members.iter().map(|member| member.name.as_str()).collect();
        assert_eq!(names, ["Me", "Petr", "Ája", "Zdeněk"]);
    }

    #[test]
    fn members_are_found_by_name_or_id_without_accents() {
        let members = vec![
            member("Tomáš Černý", Role::Member, false),
            member("Anna", Role::Member, false),
        ];
        let found: Vec<&str> = find_members(&members, "cern tom").map(|m| m.name.as_str()).collect();
        assert_eq!(found, ["Tomáš Černý"]);
        assert_eq!(find_members(&members, "@anna").count(), 1);
        assert_eq!(find_members(&members, "  ").count(), 2);
    }

    fn details(notifications: NotificationMode) -> RoomDetails {
        RoomDetails {
            id: RoomId::from("!a:test"),
            name: String::new(),
            topic: None,
            avatar: None,
            address: None,
            is_encrypted: true,
            is_direct: true,
            joined_members: 2,
            notifications,
            may: crate::ports::RoomPermissions::default(),
        }
    }

    #[test]
    fn a_merged_chat_has_one_setting_only_when_its_rooms_agree() {
        let off = details(NotificationMode::Off);
        let all = details(NotificationMode::All);
        assert_eq!(
            chat_notifications(&[off.clone(), off.clone()]),
            Some(NotificationMode::Off)
        );
        assert_eq!(chat_notifications(&[off, all]), None);
        assert_eq!(chat_notifications(&[]), None);
    }

    /// Rooms whose pages are given lists of (minute, is a photo): a page of three, newest first.
    struct Pages {
        rooms: HashMap<RoomId, Vec<(u64, bool)>>,
    }

    // the pages answer at once.
    #[allow(clippy::unused_async_trait_impl)]
    impl ChatDetails for Pages {
        async fn room_details(&self, _room: &RoomId) -> Result<RoomDetails, BackendError> {
            Err(BackendError::NotAllowed)
        }

        async fn members(&self, _room: &RoomId) -> Result<Vec<Member>, BackendError> {
            Ok(Vec::new())
        }

        async fn threads(&self, _room: &RoomId, _from: Option<&str>) -> Result<crate::ports::ThreadPage, BackendError> {
            Ok(crate::ports::ThreadPage::default())
        }

        async fn shared(&self, room: &RoomId, from: Option<&str>) -> Result<SharedPage, BackendError> {
            let all = &self.rooms[room];
            let start: usize = from.map_or(0, |from| from.parse().unwrap());
            let end = (start + 3).min(all.len());
            let items = all[start..end]
                .iter()
                .map(|&(minute, is_photo)| SharedItem {
                    event: EventId::from(format!("${room}{minute}")),
                    room: room.clone(),
                    sender_name: String::new(),
                    date: SystemTime::UNIX_EPOCH + Duration::from_mins(minute),
                    content: if is_photo {
                        SharedContent::Photo {
                            picture: crate::timeline::Picture {
                                source: "mxc://p".into(),
                                width: 1,
                                height: 1,
                            },
                        }
                    } else {
                        SharedContent::Link {
                            url: "https://a.test".to_owned(),
                            text: String::new(),
                        }
                    },
                })
                .collect();
            Ok(SharedPage {
                items,
                next: (end < all.len()).then(|| end.to_string()),
            })
        }

        async fn set_notifications(&self, _chat: &ChatId, _mode: NotificationMode) -> Result<(), BackendError> {
            Ok(())
        }

        async fn rename_room(&self, _room: &RoomId, _name: &str) -> Result<(), BackendError> {
            Ok(())
        }

        async fn set_topic(&self, _room: &RoomId, _topic: &str) -> Result<(), BackendError> {
            Ok(())
        }

        async fn set_room_avatar(&self, _room: &RoomId, _picture: Picture) -> Result<(), BackendError> {
            Ok(())
        }

        async fn remove_room_avatar(&self, _room: &RoomId) -> Result<(), BackendError> {
            Ok(())
        }

        async fn leave(&self, _chat: &ChatId) -> Result<(), BackendError> {
            Ok(())
        }
    }

    #[tokio::test]
    async fn a_merged_chats_photos_come_newest_first_across_its_rooms() {
        let (a, b) = (RoomId::from("!a:test"), RoomId::from("!b:test"));
        let pages = Pages {
            rooms: HashMap::from([
                (
                    a.clone(),
                    vec![(90, true), (80, false), (70, true), (40, true), (10, true)],
                ),
                (b.clone(), vec![(85, true), (60, false), (50, true), (20, true)]),
            ]),
        };
        let mut history = SharedHistory::new(vec![a, b], SharedKind::Media);
        let minutes = |items: Vec<SharedItem>| -> Vec<u64> {
            items
                .iter()
                .map(|item| item.date.duration_since(SystemTime::UNIX_EPOCH).unwrap().as_secs() / 60)
                .collect()
        };
        assert_eq!(minutes(history.next(&pages, 3).await.unwrap()), [90, 85, 70]);
        assert!(!history.is_at_start());
        assert_eq!(minutes(history.next(&pages, 10).await.unwrap()), [50, 40, 20, 10]);
        assert!(history.is_at_start());
        assert!(history.next(&pages, 10).await.unwrap().is_empty());
    }
}
