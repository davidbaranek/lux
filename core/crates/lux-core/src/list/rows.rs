//! A section's rows as the list sends them: the values themselves, shared with the list they
//! came from, each with a stable id within its section.

use std::fmt;
use std::sync::Arc;

use crate::chat::{Chat, Request, SavedMessage, ScheduledMessage, Snapshot};
use crate::ids::{ChatId, EventId, RoomId, ScheduledId};
use crate::places::{Row, Section, SectionId, SectionStyle};

/// One row of a section.
#[derive(Clone, Debug)]
pub enum ListRow {
    /// A chat.
    Chat(Arc<Chat>),
    /// An invitation.
    Request(Arc<Request>),
    /// A saved message, with its chat when the list has it.
    Saved {
        /// The message.
        message: Arc<SavedMessage>,
        /// Its chat.
        chat: Option<Arc<Chat>>,
    },
    /// A message waiting to go, with its chat when the list has it.
    Scheduled {
        /// The message.
        message: Arc<ScheduledMessage>,
        /// Its chat.
        chat: Option<Arc<Chat>>,
    },
}

impl ListRow {
    /// The row of `row` in `snapshot`; `None` for a position past its lists.
    pub(crate) fn of(row: Row, snapshot: &Snapshot) -> Option<Self> {
        let chat = |index: Option<usize>| index.and_then(|index| snapshot.chats.get(index)).cloned();
        Some(match row {
            Row::Chat(index) => Self::Chat(Arc::clone(snapshot.chats.get(index)?)),
            Row::Request(index) => Self::Request(Arc::clone(snapshot.requests.get(index)?)),
            Row::Saved { message, chat: index } => Self::Saved {
                message: Arc::clone(snapshot.saved.get(message)?),
                chat: chat(index),
            },
            Row::Scheduled { message, chat: index } => Self::Scheduled {
                message: Arc::clone(snapshot.scheduled.get(message)?),
                chat: chat(index),
            },
        })
    }

    /// Its id in its section.
    #[must_use]
    pub fn key(&self) -> RowKey<'_> {
        match self {
            Self::Chat(chat) => RowKey::Chat(&chat.id),
            Self::Request(request) => RowKey::Request(&request.id),
            Self::Saved { message, .. } => RowKey::Saved(&message.event),
            Self::Scheduled { message, .. } => RowKey::Scheduled(&message.id),
        }
    }
}

/// A row's id in its section: a chat's, a request's room, a saved message's event, a waiting
/// message's id.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum RowKey<'a> {
    /// A chat.
    Chat(&'a ChatId),
    /// An invitation, by its room.
    Request(&'a RoomId),
    /// A saved message, by its event.
    Saved(&'a EventId),
    /// A message waiting to go.
    Scheduled(&'a ScheduledId),
}

impl fmt::Display for RowKey<'_> {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Chat(id) => id.fmt(formatter),
            Self::Request(id) => id.fmt(formatter),
            Self::Saved(id) => id.fmt(formatter),
            Self::Scheduled(id) => id.fmt(formatter),
        }
    }
}

/// Shared values that did not change are the same allocation: compared without reading them.
fn same<T: PartialEq>(a: &Arc<T>, b: &Arc<T>) -> bool {
    Arc::ptr_eq(a, b) || a == b
}

fn same_chat(a: Option<&Arc<Chat>>, b: Option<&Arc<Chat>>) -> bool {
    match (a, b) {
        (Some(a), Some(b)) => same(a, b),
        (None, None) => true,
        _ => false,
    }
}

impl PartialEq for ListRow {
    fn eq(&self, other: &Self) -> bool {
        match (self, other) {
            (Self::Chat(a), Self::Chat(b)) => same(a, b),
            (Self::Request(a), Self::Request(b)) => same(a, b),
            (Self::Saved { message: a, chat: c }, Self::Saved { message: b, chat: d }) => {
                same(a, b) && same_chat(c.as_ref(), d.as_ref())
            }
            (Self::Scheduled { message: a, chat: c }, Self::Scheduled { message: b, chat: d }) => {
                same(a, b) && same_chat(c.as_ref(), d.as_ref())
            }
            _ => false,
        }
    }
}

/// A section as the list shows it, without its rows: what it is, its heading, how it draws.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SectionHeader {
    /// What it is.
    pub id: SectionId,
    /// Its heading: a space inside the one shown; `None` for the others.
    pub title: Option<String>,
    /// How it draws.
    pub style: SectionStyle,
}

impl SectionHeader {
    pub(crate) fn of(section: &Section) -> Self {
        Self {
            id: section.id.clone(),
            title: section.title.clone(),
            style: section.style(),
        }
    }
}
