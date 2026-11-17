//! One frame's batch of changes to the chat list.

use std::collections::HashMap;
use std::time::SystemTime;

use eyeball_im::VectorDiff;

use super::{ListRow, Loading, SectionHeader};
use crate::chat::Label;
use crate::ids::ChatId;
use crate::places::{Badge, ListedPlace, PlaceId, SectionId, Theme};

/// The rows of one section that changed, as diffs to apply in order.
#[derive(Clone, Debug, PartialEq)]
pub struct SectionRows {
    /// Which section.
    pub section: SectionId,
    /// Its changes; a section new in this batch starts from no rows.
    pub diffs: Vec<VectorDiff<ListRow>>,
}

/// A chat with a reminder: the apps schedule a notification for it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DueReminder {
    /// The chat.
    pub chat: ChatId,
    /// Its name, for the notification.
    pub name: String,
    /// When to answer it.
    pub at: SystemTime,
}

/// What changed in the chat list since the last batch; what did not change is `None` or empty.
#[derive(Clone, Debug, PartialEq)]
pub struct ListUpdate {
    /// The place shown: the one asked for, or the inbox when that place went away.
    pub place: PlaceId,
    /// The places, arranged, when any changed.
    pub places: Option<Vec<ListedPlace>>,
    /// The colour of the places without one of their own, when it changed.
    pub theme: Option<Theme>,
    /// The shown place's sections in order, when they changed (one came or went, or a heading
    /// changed). A section that stays keeps its rows.
    pub sections: Option<Vec<SectionHeader>>,
    /// The sections whose rows changed.
    pub rows: Vec<SectionRows>,
    /// The user's labels, when they changed.
    pub labels: Option<Vec<Label>>,
    /// The chats with a reminder, when they changed.
    pub reminders: Option<Vec<DueReminder>>,
    /// How far the list is loaded, when that changed.
    pub loading: Option<Loading>,
    /// The chats a place's rule keeps out of the inbox, into low priority, with that place, when
    /// they changed: what a chat's details tell.
    pub kept_out: Option<HashMap<ChatId, PlaceId>>,
    /// The app's badge, with what a notification needs to keep it while the app is not running,
    /// when it changed.
    pub badge: Option<Badge>,
}

impl ListUpdate {
    /// Nothing changed: the batch is not sent.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.places.is_none()
            && self.theme.is_none()
            && self.sections.is_none()
            && self.rows.is_empty()
            && self.labels.is_none()
            && self.reminders.is_none()
            && self.loading.is_none()
            && self.kept_out.is_none()
            && self.badge.is_none()
    }
}
