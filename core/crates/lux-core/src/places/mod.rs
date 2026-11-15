//! Places: where the chat list gathers chats (the inbox and the other folders, the networks,
//! the spaces, the labels), and how the user arranged them.
//!
//! The user's arrangement is kept with the account, so every device shows the places alike:
//! the order of the networks, spaces and labels, the places hidden from view, and the places'
//! colours (one each, and one for those without), and how much of each network and space the
//! inbox shows, and of single chats. The folders keep the app's order, and the inbox is never
//! hidden.

use std::collections::{HashMap, HashSet};
use std::fmt;

use crate::chat::{Folder, Space};
use crate::ids::{LabelId, RoomId};
use crate::network::Network;

mod filter;
mod inbox;
mod list;
mod theme;

pub use filter::ChatFilter;
pub use inbox::InboxRule;
pub(crate) use inbox::InboxRules;
pub use list::{ChatOrder, ListedPlace, Row, Section, SectionId, SectionStyle};
pub(crate) use list::{compose, kept_out, notified_rooms};
pub use theme::Theme;

/// A place's key, stable across launches and devices: `"network:whatsapp"`, `"space:!id"`.
#[derive(Clone, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct PlaceKey(String);

impl PlaceKey {
    /// The inbox's key, as the account keeps it.
    pub const INBOX: &str = "folder:inbox";

    /// The key as it is kept.
    #[must_use]
    pub fn as_str(&self) -> &str {
        &self.0
    }

    /// A network's key.
    #[must_use]
    pub fn network(network: &Network) -> Self {
        Self(format!("network:{}", network.as_str()))
    }

    /// A space's key.
    #[must_use]
    pub fn space(space: &Space) -> Self {
        Self(format!("space:{}", space.id))
    }

    /// Whether this is the inbox, which is never hidden.
    #[must_use]
    pub fn is_inbox(&self) -> bool {
        self.0 == Self::INBOX
    }
}

impl From<String> for PlaceKey {
    fn from(key: String) -> Self {
        Self(key)
    }
}

impl From<&str> for PlaceKey {
    fn from(key: &str) -> Self {
        Self(key.to_owned())
    }
}

impl fmt::Display for PlaceKey {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.0)
    }
}

/// The kinds of places, in the order the apps show them.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum PlaceGroup {
    /// The inbox, low priority, archive, and the app's other lists, in the app's order.
    Folders,
    /// One per chat network (WhatsApp, Signal…).
    Networks,
    /// The Matrix spaces the user is in.
    Spaces,
    /// The user's own labels.
    Labels,
}

impl PlaceGroup {
    /// Whether the user may reorder this group's places.
    #[must_use]
    pub fn is_reorderable(self) -> bool {
        self != Self::Folders
    }
}

/// How the user arranged the places: an order for the reorderable ones, the hidden ones, their
/// colours, and how much of them the inbox shows.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Arrangement {
    /// Places in the user's order; a place not named comes after those that are.
    pub order: Vec<PlaceKey>,
    /// Places hidden from view (the inbox is shown all the same).
    pub hidden: HashSet<PlaceKey>,
    /// The colour of each place the user gave one (neutral among them); the others take `theme`.
    pub themes: HashMap<PlaceKey, Theme>,
    /// The colour of the places without one of their own.
    pub theme: Theme,
    /// How much of each network and space the inbox shows, for those that do not show all; what
    /// it keeps out is of low priority.
    pub inbox: HashMap<PlaceKey, InboxRule>,
}

impl Arrangement {
    /// Whether `key` is hidden: named so, and not the inbox.
    #[must_use]
    pub fn hides(&self, key: &PlaceKey) -> bool {
        !key.is_inbox() && self.hidden.contains(key)
    }

    /// A copy with `key` hidden or shown again; the inbox stays shown.
    #[must_use]
    pub fn with_hidden(mut self, key: PlaceKey, hidden: bool) -> Self {
        if hidden && !key.is_inbox() {
            self.hidden.insert(key);
        } else {
            self.hidden.remove(&key);
        }
        self
    }

    /// The colour `key` shows in: its own, else the one for every place.
    #[must_use]
    pub fn theme_of(&self, key: &PlaceKey) -> Theme {
        self.themes.get(key).copied().unwrap_or(self.theme)
    }

    /// A copy with `key`'s own colour `theme`, or (`None`) the one for every place.
    #[must_use]
    pub fn with_theme(mut self, key: PlaceKey, theme: Option<Theme>) -> Self {
        match theme {
            Some(theme) => self.themes.insert(key, theme),
            None => self.themes.remove(&key),
        };
        self
    }

    /// How much of `key` the inbox shows: all, unless the user said less.
    #[must_use]
    pub fn inbox_of(&self, key: &PlaceKey) -> InboxRule {
        self.inbox.get(key).copied().unwrap_or_default()
    }

    /// A copy where the inbox shows `rule` of `key`'s chats; all is what it shows unasked.
    #[must_use]
    pub fn with_inbox(mut self, key: PlaceKey, rule: InboxRule) -> Self {
        if rule == InboxRule::All {
            self.inbox.remove(&key);
        } else {
            self.inbox.insert(key, rule);
        }
        self
    }
}

/// The positions of `places` (each a key and its group) in the arranged order: grouped in the
/// apps' order of groups; within a group, the folders as they came and the others in the
/// user's order, those it does not name after the named ones, as they came.
pub(crate) fn arranged_order<'a>(
    places: impl Iterator<Item = (&'a PlaceKey, PlaceGroup)>,
    arrangement: &Arrangement,
) -> Vec<usize> {
    let rank: HashMap<&PlaceKey, usize> = arrangement
        .order
        .iter()
        .enumerate()
        .map(|(index, key)| (key, index))
        .rev()
        .collect();
    let mut arranged: Vec<(PlaceGroup, usize, usize)> = places
        .enumerate()
        .map(|(arrival, (key, group))| {
            let rank = if group.is_reorderable() {
                rank.get(key).copied()
            } else {
                None
            };
            (group, rank.unwrap_or(usize::MAX), arrival)
        })
        .collect();
    // (group, rank, arrival) is unique: ties keep the order they came in.
    arranged.sort_unstable();
    arranged.into_iter().map(|(_, _, arrival)| arrival).collect()
}

/// Where the chat list looks: a folder, one of the app's lists, a network's chats, a space's,
/// or a label's.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum PlaceId {
    /// A folder: the inbox, low priority, the archive.
    Folder(Folder),
    /// The invitations not answered.
    Requests,
    /// Saved messages, across chats.
    Saved,
    /// Chats with a reminder, the soonest first.
    Reminders,
    /// Messages waiting to go.
    Scheduled,
    /// One network's chats out of the archive.
    Network(Network),
    /// A space's chats out of the archive, with a section for each space inside it.
    Space(RoomId),
    /// A label's chats, but those archived.
    Label(LabelId),
}

impl PlaceId {
    /// The inbox.
    pub const INBOX: Self = Self::Folder(Folder::Inbox);

    /// The group it shows in.
    #[must_use]
    pub fn group(&self) -> PlaceGroup {
        match self {
            Self::Folder(_) | Self::Requests | Self::Saved | Self::Reminders | Self::Scheduled => PlaceGroup::Folders,
            Self::Network(_) => PlaceGroup::Networks,
            Self::Space(_) => PlaceGroup::Spaces,
            Self::Label(_) => PlaceGroup::Labels,
        }
    }

    /// Whether the user may say how much of it the inbox shows: a network's or a space's
    /// chats; the folders and lists are not the inbox's, and a label gathers by hand.
    #[must_use]
    pub fn has_inbox_rule(&self) -> bool {
        matches!(self, Self::Network(_) | Self::Space(_))
    }

    /// Its key, as the user's arrangement keeps it.
    #[must_use]
    pub fn key(&self) -> PlaceKey {
        PlaceKey(match self {
            Self::Folder(Folder::Inbox) => PlaceKey::INBOX.to_owned(),
            Self::Folder(Folder::LowPriority) => "folder:lowPriority".to_owned(),
            Self::Folder(Folder::Archive) => "folder:archive".to_owned(),
            Self::Requests => "requests".to_owned(),
            Self::Saved => "saved".to_owned(),
            Self::Reminders => "reminders".to_owned(),
            Self::Scheduled => "scheduled".to_owned(),
            Self::Network(network) => return PlaceKey::network(network),
            Self::Space(id) => format!("space:{id}"),
            Self::Label(id) => format!("label:{id}"),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn place(key: &str, group: PlaceGroup) -> (PlaceKey, PlaceGroup) {
        (key.into(), group)
    }

    /// The keys in the arranged order.
    fn arrange<'a>(places: &'a [(PlaceKey, PlaceGroup)], arrangement: &Arrangement) -> Vec<&'a str> {
        arranged_order(places.iter().map(|(key, group)| (key, *group)), arrangement)
            .into_iter()
            .map(|index| places[index].0.as_str())
            .collect()
    }

    #[test]
    fn groups_come_in_the_apps_order_and_folders_keep_theirs() {
        let places = [
            place("network:signal", PlaceGroup::Networks),
            place("folder:inbox", PlaceGroup::Folders),
            place("label:work", PlaceGroup::Labels),
            place("folder:archive", PlaceGroup::Folders),
            place("space:!a", PlaceGroup::Spaces),
        ];
        let arrangement = Arrangement {
            order: vec!["folder:archive".into()],
            ..Arrangement::default()
        };
        assert_eq!(
            arrange(&places, &arrangement),
            [
                "folder:inbox",
                "folder:archive",
                "network:signal",
                "space:!a",
                "label:work"
            ]
        );
    }

    #[test]
    fn the_users_order_comes_first_and_new_places_follow_as_they_came() {
        let places = [
            place("network:whatsapp", PlaceGroup::Networks),
            place("network:signal", PlaceGroup::Networks),
            place("network:telegram", PlaceGroup::Networks),
            place("network:matrix", PlaceGroup::Networks),
        ];
        let arrangement = Arrangement {
            order: vec![
                "network:telegram".into(),
                "network:signal".into(),
                "network:telegram".into(),
            ],
            ..Arrangement::default()
        };
        assert_eq!(
            arrange(&places, &arrangement),
            [
                "network:telegram",
                "network:signal",
                "network:whatsapp",
                "network:matrix"
            ]
        );
    }

    #[test]
    fn place_ids_have_the_keys_the_account_keeps() {
        assert_eq!(PlaceId::INBOX.key().as_str(), PlaceKey::INBOX);
        assert_eq!(
            PlaceId::Folder(Folder::LowPriority).key().as_str(),
            "folder:lowPriority"
        );
        assert_eq!(PlaceId::Space("!s:x".into()).key().as_str(), "space:!s:x");
        assert_eq!(PlaceId::Label("work".into()).group(), PlaceGroup::Labels);
    }

    #[test]
    fn hidden_places_say_so_but_never_the_inbox() {
        let places = [
            place("folder:inbox", PlaceGroup::Folders),
            place("network:signal", PlaceGroup::Networks),
        ];
        let arrangement = Arrangement::default()
            .with_hidden("folder:inbox".into(), true)
            .with_hidden("network:signal".into(), true);
        assert!(!arrangement.hides(&places[0].0));
        assert!(arrangement.hides(&places[1].0));
        assert!(
            !arrangement
                .with_hidden("network:signal".into(), false)
                .hides(&"network:signal".into())
        );
    }

    #[test]
    fn a_place_takes_its_own_colour_else_the_one_for_every_place() {
        let space: PlaceKey = "space:!a".into();
        let other: PlaceKey = "space:!b".into();
        let arrangement = Arrangement {
            theme: Theme::Blue,
            ..Arrangement::default()
        }
        .with_theme(space.clone(), Some(Theme::Neutral));
        assert_eq!(arrangement.theme_of(&space), Theme::Neutral);
        assert_eq!(arrangement.theme_of(&other), Theme::Blue);
        let arrangement = arrangement.with_theme(space.clone(), None);
        assert_eq!(arrangement.theme_of(&space), Theme::Blue);
        assert!(arrangement.themes.is_empty());
        assert_eq!(Arrangement::default().theme_of(&space), Theme::Neutral);
    }
}
