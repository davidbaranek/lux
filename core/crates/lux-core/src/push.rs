//! Push notifications: the pusher a device registers with its server, and the notification a
//! pushed event becomes on the device.
//!
//! The server sends only an event's id through the push gateway (`event_id_only`): the device
//! itself fetches and decrypts the event, so no message text crosses the gateway or Apple's
//! servers. What it fetched becomes a [`Notification`], structured; the apps word it.

use std::collections::VecDeque;
use std::fmt::Write as _;
use std::time::{Duration, SystemTime};

use crate::ids::{ChatId, EventId, MediaId, RoomId, UserId};
use crate::merge::Merge;
use crate::preview::PreviewKind;

/// Which of Apple's push services a build's token belongs to: development builds get tokens of
/// the sandbox, the others of production, and the gateway must send each to its own.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum PushEnvironment {
    /// Apple's production service (builds for testers and the App Store).
    Production,
    /// Apple's sandbox (builds signed for development).
    Sandbox,
}

impl PushEnvironment {
    /// The gateway's app id for this environment: `app_id` for production, `app_id.dev` for the
    /// sandbox (the gateway configures one APNs connection per app id).
    #[must_use]
    pub fn app_id(self, app_id: &str) -> String {
        match self {
            Self::Production => app_id.to_owned(),
            Self::Sandbox => format!("{app_id}.dev"),
        }
    }
}

/// A device's push token as the gateway takes it: the token's bytes in lowercase hex.
#[derive(Clone, PartialEq, Eq, Hash)]
pub struct PushKey(String);

impl PushKey {
    /// The key of the token `bytes` (what the system hands the app).
    #[must_use]
    pub fn from_token(bytes: &[u8]) -> Self {
        let mut hex = String::with_capacity(bytes.len() * 2);
        for byte in bytes {
            // writing to a `String` cannot fail.
            let _ = write!(hex, "{byte:02x}");
        }
        Self(hex)
    }

    /// The key as text.
    #[must_use]
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl std::fmt::Debug for PushKey {
    // a token addresses the device: only its start goes to a log.
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let start = self.0.get(..8).unwrap_or(&self.0);
        write!(formatter, "PushKey({start}…)")
    }
}

/// The pusher this device asks its server for: where the server sends the ids of the events
/// that notify, and how the gateway addresses the device.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Pusher {
    /// The gateway's app id ([`PushEnvironment::app_id`]).
    pub app_id: String,
    /// The device's token.
    pub push_key: PushKey,
    /// The gateway's notify URL (`https://…/_matrix/push/v1/notify`).
    pub gateway_url: String,
    /// The app's name, as the account's pushers list it.
    pub app_name: String,
    /// The device's name, as the account's pushers list it.
    pub device_name: String,
    /// The language of what the server words (an IETF tag, `en`).
    pub language: String,
    /// What a notification says when the notification extension cannot read its event ("New
    /// message", in the user's language).
    pub fallback_text: String,
}

impl Pusher {
    /// Whether this pusher stands where `other` was: the server keys a pusher by its app id and
    /// key, so a new token, or a build of the other environment, is another pusher.
    #[must_use]
    pub fn replaces(&self, app_id: &str, push_key: &str) -> bool {
        self.app_id != app_id || self.push_key.as_str() != push_key
    }
}

/// A pushed event, as the device read it.
#[derive(Clone, Debug, PartialEq)]
pub enum PushedEvent {
    /// Something to show.
    Shown(Notification),
    /// The account's push rules or ignored users say it does not notify.
    FilteredOut,
    /// It was deleted, or could not be found.
    Gone,
}

/// One notification: who wrote what, in which chat. The apps word it ("Anna", "Photo").
#[derive(Clone, Debug, PartialEq)]
pub struct Notification {
    /// The room it came in.
    pub room: RoomId,
    /// The message it shows.
    pub event: EventId,
    /// The chat it belongs with: the merged chat the room is part of, else the room's own. The
    /// apps group a chat's notifications by it.
    pub chat: ChatId,
    /// The chat's name (the merged chat's, in a merge).
    pub chat_name: String,
    /// The sender: the person the system groups and filters by (two people can share a name).
    pub sender: UserId,
    /// The sender's name in the chat.
    pub sender_name: String,
    /// The chat has more than two people: the notification names the chat and the sender.
    pub is_group: bool,
    /// What the message is; a text on one line.
    pub kind: PreviewKind,
    /// It makes a sound (the push rules say so, and it did not come late).
    pub is_noisy: bool,
    /// It was sent long before it arrived ([`Notification::arrived`]): history a bridge brings in
    /// (keeping each message's own time), or a push held back while the device was away. It shows
    /// without a sound and without lighting the screen.
    pub is_late: bool,
    /// The sender's picture: theirs, else, in a chat of two, the chat's (the other person's).
    /// The notification shows it, in a group too: who wrote, not the group.
    pub sender_picture: Option<MediaId>,
    /// The Matrix thread the message replies in, by its root: opening the notification opens the
    /// thread, where the message shows (the chat's own timeline does not show it).
    pub thread: Option<EventId>,
}

impl Notification {
    /// How much older than its arrival a message may be and still notify as new.
    pub const LATE: Duration = Duration::from_mins(15);

    /// The notification of a reply in the Matrix thread of `root`, if it is one.
    #[must_use]
    pub fn in_thread(mut self, root: Option<EventId>) -> Self {
        self.thread = root;
        self
    }

    /// The notification of a message sent at `sent` that arrived `now`: one that came
    /// [late](Self::LATE) is quiet.
    #[must_use]
    pub fn arrived(mut self, sent: SystemTime, now: SystemTime) -> Self {
        self.is_late = now.duration_since(sent).is_ok_and(|age| age > Self::LATE);
        if self.is_late {
            self.is_noisy = false;
        }
        self
    }
}

/// What [`Notification::new`] needs of a chat and the event's sender.
#[derive(Clone, Copy, Debug)]
pub struct NotifiedChat<'a> {
    /// The chat.
    pub room: &'a RoomId,
    /// Its name.
    pub name: &'a str,
    /// More than two people.
    pub is_group: bool,
    /// Its picture.
    pub picture: Option<&'a str>,
    /// The merged chat the room is part of, if any ([`crate::merge::containing`]).
    pub merge: Option<&'a Merge>,
}

/// Who sent the notified event.
#[derive(Clone, Copy, Debug)]
pub struct NotifiedSender<'a> {
    /// Their user id.
    pub id: &'a str,
    /// The name the chat shows for them; `None` when it has none.
    pub name: Option<&'a str>,
    /// Their user id's local part, for a sender with no name.
    pub localpart: &'a str,
    /// Their picture.
    pub picture: Option<&'a str>,
}

impl Notification {
    /// The notification of the message `event` of `kind` in `chat` from `sender`.
    #[must_use]
    pub fn new(
        chat: NotifiedChat<'_>,
        event: EventId,
        sender: NotifiedSender<'_>,
        kind: PreviewKind,
        is_noisy: bool,
    ) -> Self {
        let sender_name = sender
            .name
            .filter(|name| !name.trim().is_empty())
            .unwrap_or(sender.localpart)
            .to_owned();
        let sender_picture = if chat.is_group {
            sender.picture
        } else {
            sender.picture.or(chat.picture)
        };
        let room_name = if chat.name.trim().is_empty() {
            &sender_name
        } else {
            chat.name
        };
        let (id, chat_name) = match chat.merge {
            Some(merge) if !merge.name.trim().is_empty() => (merge.chat_id(), merge.name.clone()),
            Some(merge) => (merge.chat_id(), room_name.to_owned()),
            None => (ChatId::Room(chat.room.clone()), room_name.to_owned()),
        };
        Self {
            room: chat.room.clone(),
            event,
            chat: id,
            chat_name,
            sender: UserId::from(sender.id),
            sender_name,
            is_group: chat.is_group,
            kind,
            is_noisy,
            is_late: false,
            sender_picture: sender_picture.map(MediaId::from),
            thread: None,
        }
    }
}

/// What the sync brought that may notify while the app runs (the Mac's notifications, where no
/// push wakes an extension): the event's facts the decision needs.
#[derive(Clone, Copy, Debug)]
pub struct SyncedEvent<'a> {
    /// The event.
    pub event: &'a EventId,
    /// When its server received it.
    pub sent: SystemTime,
    /// The account sent it (from another device).
    pub is_own: bool,
    /// The push rules give it a sound.
    pub is_noisy: bool,
    /// Its room has no unread notifications any more: read on another device by now.
    pub is_read: bool,
}

/// Which events the sync brings become notifications while the app runs: only noisy ones from
/// others, not yet read, sent since the app started following (a launch's first sync and a
/// restarted one bring older messages again), each once.
#[derive(Debug)]
pub struct LiveNotifications {
    since: SystemTime,
    /// The events shown last, the oldest first: a sync that starts over brings them again.
    shown: VecDeque<EventId>,
}

impl LiveNotifications {
    /// How many of the events shown last are remembered.
    const REMEMBERED: usize = 256;
    /// A message's server clock may be behind the device's by this much.
    const SKEW: Duration = Duration::from_secs(60);

    /// Notifications for what was sent from `now` on.
    #[must_use]
    pub fn new(now: SystemTime) -> Self {
        Self {
            since: now.checked_sub(Self::SKEW).unwrap_or(SystemTime::UNIX_EPOCH),
            shown: VecDeque::with_capacity(Self::REMEMBERED),
        }
    }

    /// Whether `event` notifies; a notifying one is remembered, so it notifies once.
    pub fn admits(&mut self, event: &SyncedEvent<'_>) -> bool {
        if event.is_own || !event.is_noisy || event.is_read || event.sent < self.since {
            return false;
        }
        if self.shown.contains(event.event) {
            return false;
        }
        if self.shown.len() == Self::REMEMBERED {
            self.shown.pop_front();
        }
        self.shown.push_back(event.event.clone());
        true
    }
}

#[cfg(test)]
mod tests {
    use std::time::{Duration, SystemTime};

    use super::{
        LiveNotifications, Notification, NotifiedChat, NotifiedSender, PushEnvironment, PushKey, Pusher, SyncedEvent,
    };
    use crate::ids::{ChatId, EventId, MediaId, RoomId};
    use crate::merge::{self, Merge};
    use crate::preview::{PreviewKind, PreviewSource};

    fn chat<'a>(room: &'a RoomId, name: &'a str, is_group: bool) -> NotifiedChat<'a> {
        NotifiedChat {
            room,
            name,
            is_group,
            picture: Some("mxc://server/room"),
            merge: None,
        }
    }

    const ANNA: NotifiedSender<'static> = NotifiedSender {
        id: "@anna:server",
        name: Some("Anna"),
        localpart: "anna",
        picture: Some("mxc://server/anna"),
    };

    fn event() -> EventId {
        EventId::from("$event")
    }

    #[test]
    fn a_token_is_its_lowercase_hex() {
        let key = PushKey::from_token(&[0x00, 0x0f, 0xab, 0xff]);
        assert_eq!(key.as_str(), "000fabff");
        assert_eq!(format!("{key:?}"), "PushKey(000fabff…)");
    }

    #[test]
    fn the_sandbox_has_its_own_app_id() {
        assert_eq!(PushEnvironment::Production.app_id("com.example.ios"), "com.example.ios");
        assert_eq!(
            PushEnvironment::Sandbox.app_id("com.example.ios"),
            "com.example.ios.dev"
        );
    }

    #[test]
    fn a_new_token_or_app_id_is_another_pusher() {
        let pusher = Pusher {
            app_id: "app".to_owned(),
            push_key: PushKey::from_token(&[1]),
            gateway_url: "https://gateway".to_owned(),
            app_name: "Lux".to_owned(),
            device_name: "Lux (iPhone)".to_owned(),
            language: "en".to_owned(),
            fallback_text: "New message".to_owned(),
        };
        assert!(!pusher.replaces("app", "01"));
        assert!(pusher.replaces("app", "02"));
        assert!(pusher.replaces("app.dev", "01"));
    }

    #[test]
    fn a_direct_chat_shows_the_senders_picture() {
        let room = RoomId::from("!a:server");
        let notification = Notification::new(
            chat(&room, "Anna", false),
            event(),
            ANNA,
            PreviewSource::Text("hi\nthere").into(),
            true,
        );
        assert_eq!(notification.sender_name, "Anna");
        assert_eq!(notification.sender.as_str(), "@anna:server");
        assert_eq!(notification.chat, ChatId::from("!a:server"));
        assert_eq!(notification.event, event());
        assert_eq!(notification.kind, PreviewKind::Text("hi there".to_owned()));
        assert_eq!(notification.sender_picture, Some(MediaId::from("mxc://server/anna")));
        assert!(notification.is_noisy);
    }

    #[test]
    fn a_group_shows_the_senders_picture_not_its_own() {
        let room = RoomId::from("!a:server");
        let notification = Notification::new(chat(&room, "Trip", true), event(), ANNA, PreviewKind::Image, false);
        assert_eq!(notification.chat_name, "Trip");
        assert_eq!(notification.kind, PreviewKind::Image);
        assert_eq!(notification.sender_picture, Some(MediaId::from("mxc://server/anna")));
        let pictureless = NotifiedSender { picture: None, ..ANNA };
        let notification = Notification::new(
            chat(&room, "Trip", true),
            event(),
            pictureless,
            PreviewKind::Image,
            false,
        );
        assert_eq!(notification.sender_picture, None);
    }

    #[test]
    fn a_sender_with_no_name_goes_by_their_id() {
        let room = RoomId::from("!a:server");
        let nameless = NotifiedSender {
            id: "@anna:server",
            name: Some(" "),
            localpart: "anna",
            picture: None,
        };
        let notification = Notification::new(chat(&room, "", false), event(), nameless, PreviewKind::Voice, true);
        assert_eq!(notification.sender_name, "anna");
        // a chat with no name is named after its sender.
        assert_eq!(notification.chat_name, "anna");
        // in a chat of two, the chat's picture is the other person's.
        assert_eq!(notification.sender_picture, Some(MediaId::from("mxc://server/room")));
    }

    #[test]
    fn a_merged_rooms_notification_goes_with_the_merged_chat() {
        let merges = [Merge {
            id: "jana".into(),
            name: "Jana".to_owned(),
            rooms: vec!["!a:server".into(), "!b:server".into()],
            default_room: "!a:server".into(),
        }];
        let room = RoomId::from("!b:server");
        let mut notified = chat(&room, "Jana (WhatsApp)", false);
        notified.merge = merge::containing(&merges, &room);
        let notification = Notification::new(notified, event(), ANNA, PreviewKind::Image, true);
        assert_eq!(notification.chat, ChatId::from("merge:jana"));
        assert_eq!(notification.chat_name, "Jana");
        assert_eq!(notification.room, room);
        assert!(merge::containing(&merges, &RoomId::from("!c:server")).is_none());
    }

    fn synced(event: &EventId, sent: SystemTime) -> SyncedEvent<'_> {
        SyncedEvent {
            event,
            sent,
            is_own: false,
            is_noisy: true,
            is_read: false,
        }
    }

    #[test]
    fn the_running_app_notifies_new_noisy_unread_messages_from_others_once() {
        let start = SystemTime::UNIX_EPOCH + Duration::from_secs(1_000_000);
        let mut live = LiveNotifications::new(start);
        let new = EventId::from("$new");
        let later = start + Duration::from_secs(5);
        assert!(live.admits(&synced(&new, later)));
        // a sync that starts over brings it again.
        assert!(!live.admits(&synced(&new, later)));
        // before the app followed: the launch's catching up.
        let old = EventId::from("$old");
        assert!(!live.admits(&synced(&old, start - Duration::from_secs(3_600))));
        // a server clock a little behind still counts.
        let skewed = EventId::from("$skewed");
        assert!(live.admits(&synced(&skewed, start - Duration::from_secs(30))));
        let other = EventId::from("$other");
        assert!(!live.admits(&SyncedEvent {
            is_noisy: false,
            ..synced(&other, later)
        }));
        assert!(!live.admits(&SyncedEvent {
            is_own: true,
            ..synced(&other, later)
        }));
        assert!(!live.admits(&SyncedEvent {
            is_read: true,
            ..synced(&other, later)
        }));
    }

    #[test]
    fn only_the_last_shown_events_are_remembered() {
        let start = SystemTime::UNIX_EPOCH + Duration::from_secs(1_000_000);
        let mut live = LiveNotifications::new(start);
        let events: Vec<EventId> = (0..=LiveNotifications::REMEMBERED)
            .map(|index| EventId::from(format!("${index}")))
            .collect();
        for event in &events {
            assert!(live.admits(&synced(event, start)));
        }
        assert_eq!(live.shown.len(), LiveNotifications::REMEMBERED);
        // the first was forgotten, the last is still known.
        assert!(live.admits(&synced(&events[0], start)));
        assert!(!live.admits(&synced(&events[LiveNotifications::REMEMBERED], start)));
    }

    #[test]
    fn a_message_that_arrives_long_after_it_was_sent_is_quiet() {
        let room = RoomId::from("!r:server");
        let sent = SystemTime::UNIX_EPOCH + Duration::from_secs(1_000_000);
        let new = |now: SystemTime| {
            Notification::new(chat(&room, "Trip", true), event(), ANNA, PreviewKind::Image, true).arrived(sent, now)
        };
        let fresh = new(sent + Duration::from_secs(30));
        assert!(fresh.is_noisy && !fresh.is_late);
        let late = new(sent + Duration::from_hours(1));
        assert!(!late.is_noisy && late.is_late);
        // a server clock ahead of the device's is not late.
        assert!(!new(sent - Duration::from_secs(30)).is_late);
    }
}
