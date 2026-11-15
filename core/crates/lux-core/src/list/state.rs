//! The chat list's state, owned by the view model's task: what the account sent, what the user
//! chose, and what the listener was last sent, so each batch holds only what changed.

use std::collections::{HashMap, HashSet};
use std::sync::Arc;
use std::time::SystemTime;

use eyeball_im::VectorDiff;

use super::{DueReminder, ListRow, ListUpdate, Loading, SectionHeader, SectionRows};
use crate::chat::{Chat, Label, Request, ScheduledMessage, Snapshot, Space};
use crate::diff;
use crate::ids::ChatId;
use crate::organizer::Organized;
use crate::places::{self, Arrangement, ChatFilter, ChatOrder, InboxRule, ListedPlace, PlaceId, SectionId, Theme};

/// What the listener was last sent.
#[derive(Debug, Default)]
struct Shown {
    /// `None` before the first batch: it sends everything.
    places: Option<Vec<ListedPlace>>,
    sections: Vec<(SectionHeader, Vec<ListRow>)>,
    labels: Option<Vec<Label>>,
    reminders: Option<Vec<DueReminder>>,
    loading: Option<Loading>,
    theme: Option<Theme>,
    chat_inbox: Option<HashMap<ChatId, InboxRule>>,
}

/// The list's state.
#[derive(Debug)]
pub(crate) struct ListState {
    snapshot: Snapshot,
    organized: Arc<Organized>,
    /// An arrangement the user just made, shown until the account has it.
    arranging: Option<Arrangement>,
    place: PlaceId,
    filter: Option<ChatFilter>,
    order: ChatOrder,
    drafts: HashSet<ChatId>,
    shown: Shown,
}

impl ListState {
    /// The list at `place` with `filter`, in `order`, from `kept` (the device's last list) until the account
    /// sends its own.
    pub(crate) fn new(
        place: PlaceId,
        filter: Option<ChatFilter>,
        order: ChatOrder,
        drafts: HashSet<ChatId>,
        kept: Vec<Chat>,
    ) -> Self {
        Self {
            snapshot: Snapshot {
                chats: kept.into_iter().map(Arc::new).collect(),
                ..Snapshot::default()
            },
            organized: Arc::default(),
            arranging: None,
            place,
            filter,
            order,
            drafts,
            shown: Shown::default(),
        }
    }

    pub(crate) fn chat_count(&self) -> usize {
        self.snapshot.chats.len()
    }

    pub(crate) fn has_chats(&self) -> bool {
        !self.snapshot.chats.is_empty()
    }

    /// Shows `place`; true when it is another.
    pub(crate) fn select(&mut self, place: PlaceId) -> bool {
        let changed = self.place != place;
        self.place = place;
        changed
    }

    pub(crate) fn set_filter(&mut self, filter: Option<ChatFilter>) {
        self.filter = filter;
    }

    pub(crate) fn set_order(&mut self, order: ChatOrder) {
        self.order = order;
    }

    pub(crate) fn set_drafts(&mut self, drafts: HashSet<ChatId>) {
        self.drafts = drafts;
    }

    pub(crate) fn apply_chats(&mut self, diffs: Vec<VectorDiff<Arc<Chat>>>) {
        for diff in diffs {
            diff::apply(&mut self.snapshot.chats, diff);
        }
    }

    pub(crate) fn apply_requests(&mut self, diffs: Vec<VectorDiff<Request>>) {
        for diff in diffs {
            diff::apply(&mut self.snapshot.requests, diff.map(Arc::new));
        }
    }

    pub(crate) fn set_organized(&mut self, organized: Arc<Organized>) {
        if organized.labels != self.snapshot.labels {
            self.snapshot.labels.clone_from(&organized.labels);
        }
        if organized.saved != self.organized.saved {
            self.snapshot.saved = organized.saved.iter().cloned().map(Arc::new).collect();
        }
        if self.arranging.as_ref() == Some(&organized.arrangement) {
            self.arranging = None;
        }
        self.organized = organized;
    }

    pub(crate) fn set_spaces(&mut self, spaces: &[Space]) {
        if self.snapshot.spaces != spaces {
            self.snapshot.spaces = spaces.to_vec();
        }
    }

    pub(crate) fn set_scheduled(&mut self, scheduled: Vec<ScheduledMessage>) {
        self.snapshot.scheduled = scheduled.into_iter().map(Arc::new).collect();
    }

    /// The places' arrangement as shown: the user's newest, else the account's.
    pub(crate) fn arrangement(&self) -> &Arrangement {
        self.arranging.as_ref().unwrap_or(&self.organized.arrangement)
    }

    /// Shows `arrangement` until the account has it (or its write ends).
    pub(crate) fn arrange(&mut self, arrangement: Arrangement) {
        self.arranging = Some(arrangement);
    }

    /// The write of an arrangement ended: the account's shows again.
    pub(crate) fn arranged(&mut self) {
        self.arranging = None;
    }

    /// Composes the list as it is now and returns what changed since the last call (with
    /// `loading`, when it changed). Reminders due by `now` count on their place.
    pub(crate) fn compose(&mut self, now: SystemTime, loading: Loading) -> ListUpdate {
        let arrangement = self.arrangement().clone();
        let mut list = places::compose(
            &self.snapshot,
            &self.place,
            self.filter,
            self.order,
            &self.drafts,
            &arrangement,
            now,
        );
        // the shown place went away (its last waiting message cancelled, its label removed):
        // back to the inbox.
        if !list.places.iter().any(|place| place.id == self.place) {
            self.place = PlaceId::INBOX;
            list = places::compose(
                &self.snapshot,
                &self.place,
                self.filter,
                self.order,
                &self.drafts,
                &arrangement,
                now,
            );
        }
        let first = self.shown.places.is_none();
        let places = (self.shown.places.as_ref() != Some(&list.places)).then(|| list.places.clone());
        if places.is_some() {
            self.shown.places = Some(list.places);
        }
        let headers: Vec<SectionHeader> = list.sections.iter().map(SectionHeader::of).collect();
        let headers_changed = first
            || headers.len() != self.shown.sections.len()
            || headers
                .iter()
                .zip(&self.shown.sections)
                .any(|(new, (old, _))| new != old);
        let mut old: HashMap<SectionId, Vec<ListRow>> = self
            .shown
            .sections
            .drain(..)
            .map(|(header, rows)| (header.id, rows))
            .collect();
        let mut rows = Vec::new();
        for (section, header) in list.sections.iter().zip(&headers) {
            let new: Vec<ListRow> = section
                .rows
                .iter()
                .filter_map(|&row| ListRow::of(row, &self.snapshot))
                .collect();
            let before = old.remove(&header.id).unwrap_or_default();
            let diffs = diff::changes(&before, &new, ListRow::key);
            if !diffs.is_empty() {
                rows.push(SectionRows {
                    section: header.id.clone(),
                    diffs,
                });
            }
            self.shown.sections.push((header.clone(), new));
        }
        let labels = (self.shown.labels.as_ref() != Some(&self.snapshot.labels)).then(|| self.snapshot.labels.clone());
        if let Some(labels) = &labels {
            self.shown.labels = Some(labels.clone());
        }
        let due = reminders(&self.snapshot.chats);
        let reminders = (self.shown.reminders.as_ref() != Some(&due)).then_some(due);
        if let Some(reminders) = &reminders {
            self.shown.reminders = Some(reminders.clone());
        }
        let loading = (self.shown.loading != Some(loading)).then_some(loading);
        if loading.is_some() {
            self.shown.loading = loading;
        }
        let theme = (self.shown.theme != Some(arrangement.theme)).then_some(arrangement.theme);
        if theme.is_some() {
            self.shown.theme = theme;
        }
        let chat_inbox =
            (self.shown.chat_inbox.as_ref() != Some(&arrangement.chat_inbox)).then(|| arrangement.chat_inbox.clone());
        if let Some(chat_inbox) = &chat_inbox {
            self.shown.chat_inbox = Some(chat_inbox.clone());
        }
        ListUpdate {
            place: self.place.clone(),
            places,
            theme,
            sections: headers_changed.then_some(headers),
            rows,
            labels,
            reminders,
            loading,
            chat_inbox,
        }
    }
}

/// The chats with a reminder, by chat id.
fn reminders(chats: &[Arc<Chat>]) -> Vec<DueReminder> {
    let mut due: Vec<DueReminder> = chats
        .iter()
        .filter_map(|chat| {
            chat.reminder.map(|at| DueReminder {
                chat: chat.id.clone(),
                name: chat.name.clone(),
                at,
            })
        })
        .collect();
    due.sort_unstable_by(|a, b| a.chat.cmp(&b.chat));
    due
}
