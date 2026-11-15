//! The core's identifiers. Cheap to clone (`Arc<str>`), compared by value, distinct types so a
//! room cannot be passed where a chat is meant: a merged chat's id names no room.
//!
//! They are the text the server or the account data gave, not checked again: the adapters
//! check what they hand to the SDK.

use std::borrow::Borrow;
use std::fmt;
use std::sync::Arc;

macro_rules! id {
    ($(#[$doc:meta])* $name:ident) => {
        $(#[$doc])*
        #[derive(Clone, PartialEq, Eq, Hash, PartialOrd, Ord)]
        pub struct $name(Arc<str>);

        impl $name {
            /// The id as text.
            #[must_use]
            pub fn as_str(&self) -> &str {
                &self.0
            }
        }

        // ids hash as their text, so a set of ids answers for a `&str`.
        impl Borrow<str> for $name {
            fn borrow(&self) -> &str {
                &self.0
            }
        }

        impl From<&str> for $name {
            fn from(id: &str) -> Self {
                Self(id.into())
            }
        }

        impl From<String> for $name {
            fn from(id: String) -> Self {
                Self(id.into())
            }
        }

        impl fmt::Display for $name {
            fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
                formatter.write_str(&self.0)
            }
        }

        impl fmt::Debug for $name {
            fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
                write!(formatter, "{}({})", stringify!($name), self.0)
            }
        }
    };
}

id!(
    /// A Matrix room (`!abc:server`).
    RoomId
);
id!(
    /// A Matrix user (`@anna:server`).
    UserId
);

impl UserId {
    /// The part before the server (`anna` of `@anna:server`).
    #[must_use]
    pub fn localpart(&self) -> &str {
        let id = self.0.strip_prefix('@').unwrap_or(&self.0);
        id.split_once(':').map_or(id, |(localpart, _)| localpart)
    }
}

id!(
    /// A message as the timeline knows it, the same from local echo to sent; unique among all
    /// rooms' messages, since a merged chat's thread holds several rooms' as one list.
    MessageId
);
id!(
    /// A Matrix event (`$abc`), the id other devices and the server know.
    EventId
);
id!(
    /// Media the core can load (a `mxc://` URL, or a demo picture's name).
    MediaId
);
id!(
    /// A device of a Matrix account (`ABCDEFGHIJ`): with the user id, it names one session.
    DeviceId
);
id!(
    /// A merged chat, as the account data names it.
    MergeId
);
id!(
    /// A label, as the account data names it.
    LabelId
);
id!(
    /// A message the server sends later (its delayed event).
    ScheduledId
);

/// One of a room's timelines: the room's own (its main thread, where a thread's replies do not
/// show), or the Matrix thread of one of its messages (the root, then its replies).
#[derive(Clone, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct TimelineId {
    /// The room.
    pub room: RoomId,
    /// The thread's root message; `None`: the room's own timeline.
    pub thread: Option<EventId>,
}

impl TimelineId {
    /// The thread of the message `started_by` in `room`.
    #[must_use]
    pub fn thread(room: RoomId, started_by: EventId) -> Self {
        Self {
            room,
            thread: Some(started_by),
        }
    }
}

/// The room's own timeline.
impl From<RoomId> for TimelineId {
    fn from(room: RoomId) -> Self {
        Self { room, thread: None }
    }
}

impl From<&RoomId> for TimelineId {
    fn from(room: &RoomId) -> Self {
        Self::from(room.clone())
    }
}

/// A row of the chat list: a room, or a merged chat (which names no room).
#[derive(Clone, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum ChatId {
    /// A room's own chat.
    Room(RoomId),
    /// A merged chat: several rooms shown as one.
    Merge(MergeId),
}

impl ChatId {
    /// What starts a merged chat's id in its text form.
    const MERGE: &str = "merge:";

    /// The room, for a room's own chat.
    #[must_use]
    pub fn room(&self) -> Option<&RoomId> {
        match self {
            Self::Room(room) => Some(room),
            Self::Merge(_) => None,
        }
    }

    /// The merge, for a merged chat.
    #[must_use]
    pub fn merge(&self) -> Option<&MergeId> {
        match self {
            Self::Merge(merge) => Some(merge),
            Self::Room(_) => None,
        }
    }
}

impl From<RoomId> for ChatId {
    fn from(room: RoomId) -> Self {
        Self::Room(room)
    }
}

impl From<MergeId> for ChatId {
    fn from(merge: MergeId) -> Self {
        Self::Merge(merge)
    }
}

/// The text form (as [`Display`](fmt::Display) writes it, for the apps and the kept list): a
/// room's id, or `merge:` and the merge's.
impl From<&str> for ChatId {
    fn from(text: &str) -> Self {
        match text.strip_prefix(Self::MERGE) {
            Some(merge) => Self::Merge(merge.into()),
            None => Self::Room(text.into()),
        }
    }
}

impl From<String> for ChatId {
    fn from(text: String) -> Self {
        match text.strip_prefix(Self::MERGE) {
            Some(merge) => Self::Merge(merge.into()),
            None => Self::Room(text.into()),
        }
    }
}

impl fmt::Display for ChatId {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Room(room) => formatter.write_str(room.as_str()),
            Self::Merge(merge) => write!(formatter, "{}{merge}", Self::MERGE),
        }
    }
}

impl fmt::Debug for ChatId {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "ChatId({self})")
    }
}

/// A message, as the thread names one: by the timeline's id, or by its event id where only that
/// is known (a kept draft's answer, a quote).
#[derive(Clone, PartialEq, Eq, Hash)]
pub enum MessageRef {
    /// The timeline's id of a message it holds.
    Local(MessageId),
    /// The Matrix event, which the timeline may not hold yet.
    Event(EventId),
}

impl From<MessageId> for MessageRef {
    fn from(message: MessageId) -> Self {
        Self::Local(message)
    }
}

impl From<EventId> for MessageRef {
    fn from(event: EventId) -> Self {
        Self::Event(event)
    }
}

/// The text form, for the apps: an event id starts with `$` (the Matrix sigil), which no
/// timeline's id does.
impl From<&str> for MessageRef {
    fn from(text: &str) -> Self {
        if text.starts_with('$') {
            Self::Event(text.into())
        } else {
            Self::Local(text.into())
        }
    }
}

impl From<String> for MessageRef {
    fn from(text: String) -> Self {
        Self::from(text.as_str())
    }
}

impl fmt::Display for MessageRef {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Local(message) => formatter.write_str(message.as_str()),
            Self::Event(event) => formatter.write_str(event.as_str()),
        }
    }
}

impl fmt::Debug for MessageRef {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Local(message) => write!(formatter, "{message:?}"),
            Self::Event(event) => write!(formatter, "{event:?}"),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_user_ids_localpart_is_before_the_server() {
        assert_eq!(UserId::from("@anna:server.org").localpart(), "anna");
        assert_eq!(UserId::from("@anna").localpart(), "anna");
    }

    #[test]
    fn a_chat_id_reads_back_from_its_text() {
        for chat in [ChatId::Room("!a:server".into()), ChatId::Merge("M1".into())] {
            assert_eq!(ChatId::from(chat.to_string()), chat);
        }
        assert_eq!(ChatId::Merge("M1".into()).to_string(), "merge:M1");
    }

    #[test]
    fn a_message_ref_reads_back_from_its_text() {
        for message in [
            MessageRef::Local("!a:server/17".into()),
            MessageRef::Event("$event".into()),
        ] {
            assert_eq!(MessageRef::from(message.to_string()), message);
        }
    }
}
