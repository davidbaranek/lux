//! Filters on a place's chats: only the unread, the read, those with a draft, the groups, the
//! conversations of two.

use std::collections::HashSet;
use std::hash::BuildHasher;

use super::list::{Row, Section};
use crate::chat::Snapshot;
use crate::ids::ChatId;

/// Which of a place's chats the list shows.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum ChatFilter {
    /// Unread, or marked unread.
    Unread,
    /// Neither.
    Read,
    /// With an unsent draft on this device.
    Drafts,
    /// More than two people.
    Groups,
    /// Conversations of two.
    Directs,
}

impl ChatFilter {
    /// Whether `row` of `snapshot` shows under this filter (`drafts`: the chats with a draft).
    /// An invitation counts as unread, a saved or waiting message as read, as their rows show.
    #[must_use]
    pub fn admits<S: BuildHasher>(self, row: Row, snapshot: &Snapshot, drafts: &HashSet<ChatId, S>) -> bool {
        let (is_unread, is_group, has_draft) = match row {
            Row::Chat(index) => snapshot.chats.get(index).map_or((false, false, false), |chat| {
                (chat.is_unread(), chat.is_group, drafts.contains(&chat.id))
            }),
            Row::Request(index) => snapshot.requests.get(index).map_or((false, false, false), |request| {
                (
                    true,
                    !request.is_direct,
                    drafts.contains(&ChatId::Room(request.id.clone())),
                )
            }),
            Row::Saved { chat, .. } | Row::Scheduled { chat, .. } => {
                let is_group = chat
                    .and_then(|index| snapshot.chats.get(index))
                    .is_some_and(|chat| chat.is_group);
                (false, is_group, false)
            }
        };
        match self {
            Self::Unread => is_unread,
            Self::Read => !is_unread,
            Self::Drafts => has_draft,
            Self::Groups => is_group,
            Self::Directs => !is_group,
        }
    }

    /// The sections with only the rows this filter admits; a section left empty goes.
    #[must_use]
    pub fn apply<S: BuildHasher>(
        self,
        sections: Vec<Section>,
        snapshot: &Snapshot,
        drafts: &HashSet<ChatId, S>,
    ) -> Vec<Section> {
        sections
            .into_iter()
            .filter_map(|mut section| {
                section.rows.retain(|&row| self.admits(row, snapshot, drafts));
                (!section.rows.is_empty()).then_some(section)
            })
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::chat::Chat;
    use crate::places::list::SectionId;
    use crate::places::list::tests::chat;

    #[test]
    fn filters_keep_only_their_kind_and_drop_empty_sections() {
        let snapshot = Snapshot {
            chats: [
                Chat {
                    unread_count: 2,
                    ..chat("a", "matrix")
                },
                Chat {
                    is_group: true,
                    ..chat("b", "matrix")
                },
                Chat {
                    is_marked_unread: true,
                    ..chat("c", "matrix")
                },
            ]
            .into_iter()
            .map(std::sync::Arc::new)
            .collect(),
            ..Snapshot::default()
        };
        let sections = vec![
            Section {
                id: SectionId::All,
                title: None,
                rows: vec![Row::Chat(0), Row::Chat(1), Row::Chat(2)],
            },
            Section {
                id: SectionId::Space("!sub".into()),
                title: Some("Sub".to_owned()),
                rows: vec![Row::Chat(1)],
            },
        ];
        let ids = |filter: ChatFilter, drafts: &[&str]| -> Vec<Vec<usize>> {
            let drafts: HashSet<ChatId> = drafts.iter().map(|&id| id.into()).collect();
            filter
                .apply(sections.clone(), &snapshot, &drafts)
                .into_iter()
                .map(|section| {
                    section
                        .rows
                        .into_iter()
                        .filter_map(|row| match row {
                            Row::Chat(index) => Some(index),
                            _ => None,
                        })
                        .collect()
                })
                .collect()
        };
        assert_eq!(ids(ChatFilter::Unread, &[]), [vec![0, 2]]);
        assert_eq!(ids(ChatFilter::Read, &[]), [[1], [1]]);
        assert_eq!(ids(ChatFilter::Groups, &[]), [[1], [1]]);
        assert_eq!(ids(ChatFilter::Directs, &[]), [vec![0, 2]]);
        assert_eq!(ids(ChatFilter::Drafts, &["c"]), [[2]]);
    }
}
