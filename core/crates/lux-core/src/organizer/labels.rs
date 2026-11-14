//! Labels as the account keeps them: a first document of whole labels, then one record per
//! name, per deletion and per chat put in or taken out, so two devices' changes to different
//! parts never replace each other (the server orders writes to the same record). The labels are
//! what the records add up to.

use std::collections::{BTreeSet, HashMap, HashSet};

use crate::chat::Label;
use crate::ids::{ChatId, LabelId, RoomId};

/// A label as the first document keeps it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct WholeLabel {
    /// Its id, kept when renamed.
    pub id: LabelId,
    /// Its name.
    pub name: String,
    /// Its rooms.
    pub rooms: Vec<RoomId>,
}

/// One record of a label.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum LabelRecord {
    /// The label is named so (made, or renamed).
    Name {
        /// The label.
        id: LabelId,
        /// Its name.
        name: String,
    },
    /// A room is in the label, or not.
    Room {
        /// The label.
        id: LabelId,
        /// The room.
        room: RoomId,
        /// In, or taken out.
        included: bool,
    },
    /// The label is deleted, for good.
    Deleted {
        /// The label.
        id: LabelId,
    },
}

impl LabelRecord {
    /// The label it is of.
    #[must_use]
    pub fn label(&self) -> &LabelId {
        match self {
            Self::Name { id, .. } | Self::Room { id, .. } | Self::Deleted { id } => id,
        }
    }
}

/// Why a change to the labels is refused.
#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
pub enum LabelError {
    /// A label needs a name.
    #[error("enter a name for the label")]
    EmptyName,
    /// Another label has that name.
    #[error("a label with that name already exists")]
    DuplicateName,
    /// The label was deleted (on another device).
    #[error("that label was deleted on another device")]
    NotFound,
}

/// Everything the account keeps of its labels.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct LabelRecords {
    /// The first document's labels, in its order.
    pub whole: Vec<WholeLabel>,
    /// The records, by the account data type each is kept as.
    pub records: HashMap<String, LabelRecord>,
}

impl LabelRecords {
    /// The labels: the first document's in its order, then the others by id; each named by its
    /// name record, with its rooms put in or taken out, and none that was deleted.
    #[must_use]
    pub fn labels(&self) -> Vec<Label> {
        let mut order: Vec<&LabelId> = Vec::new();
        let mut names: HashMap<&LabelId, &str> = HashMap::new();
        let mut rooms: HashMap<&LabelId, HashSet<ChatId>> = HashMap::new();
        for label in &self.whole {
            if !names.contains_key(&label.id) {
                order.push(&label.id);
            }
            names.insert(&label.id, &label.name);
            rooms.insert(&label.id, label.rooms.iter().cloned().map(ChatId::Room).collect());
        }
        let mut deleted: HashSet<&LabelId> = HashSet::new();
        // records by label, sorted, so the result does not depend on the map's order.
        let mut later: BTreeSet<&LabelId> = BTreeSet::new();
        for record in self.records.values() {
            match record {
                LabelRecord::Name { id, name } => {
                    if !names.contains_key(id) {
                        later.insert(id);
                    }
                    names.insert(id, name);
                }
                LabelRecord::Deleted { id } => {
                    deleted.insert(id);
                }
                LabelRecord::Room { .. } => {}
            }
        }
        order.extend(later);
        for record in self.records.values() {
            if let LabelRecord::Room { id, room, included } = record
                && names.contains_key(id)
            {
                let chats = rooms.entry(id).or_default();
                let chat = ChatId::Room(room.clone());
                if *included {
                    chats.insert(chat);
                } else {
                    chats.remove(&chat);
                }
            }
        }
        order
            .into_iter()
            .filter(|id| !deleted.contains(id))
            .map(|id| Label {
                name: names.get(id).map_or_else(String::new, |name| (*name).to_owned()),
                chats: rooms.remove(id).unwrap_or_default(),
                id: id.clone(),
            })
            .collect()
    }

    /// The record that makes a label named `name` (trimmed) with the new id `id`.
    ///
    /// # Errors
    /// When the name is empty, or another label has it (case aside).
    pub fn create(&self, id: LabelId, name: &str) -> Result<LabelRecord, LabelError> {
        let name = checked_name(name, &self.labels())?;
        Ok(LabelRecord::Name { id, name })
    }

    /// The records that put `rooms` in label `id`, or take them out. Each is written even when
    /// the labels already agree: another device's opposite change is then ordered against it.
    ///
    /// # Errors
    /// When the label is gone.
    pub fn assign(&self, id: &LabelId, rooms: &[RoomId], included: bool) -> Result<Vec<LabelRecord>, LabelError> {
        if !self.labels().iter().any(|label| label.id == *id) {
            return Err(LabelError::NotFound);
        }
        let mut rooms: Vec<&RoomId> = rooms.iter().collect();
        rooms.sort();
        rooms.dedup();
        Ok(rooms
            .into_iter()
            .map(|room| LabelRecord::Room {
                id: id.clone(),
                room: room.clone(),
                included,
            })
            .collect())
    }
}

/// `name` trimmed, if no label has it, whatever the case.
pub(crate) fn checked_name(name: &str, labels: &[Label]) -> Result<String, LabelError> {
    let name = name.trim();
    if name.is_empty() {
        return Err(LabelError::EmptyName);
    }
    let taken = labels
        .iter()
        .any(|label| label.name.to_lowercase() == name.to_lowercase());
    if taken {
        return Err(LabelError::DuplicateName);
    }
    Ok(name.to_owned())
}

#[cfg(test)]
mod tests {
    use super::{LabelError, LabelRecord, LabelRecords, WholeLabel};
    use crate::ids::ChatId;

    fn records(records: Vec<LabelRecord>) -> LabelRecords {
        LabelRecords {
            whole: vec![WholeLabel {
                id: "work".into(),
                name: "Work".to_owned(),
                rooms: vec!["!a".into()],
            }],
            records: records
                .into_iter()
                .enumerate()
                .map(|(index, record)| (format!("type{index}"), record))
                .collect(),
        }
    }

    fn room(id: &str, room: &str, included: bool) -> LabelRecord {
        LabelRecord::Room {
            id: id.into(),
            room: room.into(),
            included,
        }
    }

    #[test]
    fn records_add_up_to_labels() {
        let labels = records(vec![
            LabelRecord::Name {
                id: "family".into(),
                name: "Family".to_owned(),
            },
            room("family", "!b", true),
            room("work", "!a", false),
            room("work", "!c", true),
            LabelRecord::Name {
                id: "work".into(),
                name: "Job".to_owned(),
            },
        ])
        .labels();
        let names: Vec<_> = labels.iter().map(|label| label.name.as_str()).collect();
        assert_eq!(names, ["Job", "Family"]);
        assert_eq!(labels[0].chats, [ChatId::from("!c")].into_iter().collect());
        assert_eq!(labels[1].chats, [ChatId::from("!b")].into_iter().collect());
    }

    #[test]
    fn a_deleted_label_stays_deleted() {
        let labels = records(vec![
            LabelRecord::Deleted { id: "work".into() },
            room("work", "!c", true),
        ])
        .labels();
        assert!(labels.is_empty());
    }

    #[test]
    fn records_of_an_unknown_label_make_none() {
        assert_eq!(records(vec![room("ghost", "!c", true)]).labels().len(), 1);
    }

    #[test]
    fn names_are_checked() {
        let all = records(Vec::new());
        assert_eq!(all.create("new".into(), "  "), Err(LabelError::EmptyName));
        assert_eq!(all.create("new".into(), "work"), Err(LabelError::DuplicateName));
        assert_eq!(
            all.create("new".into(), " Home "),
            Ok(LabelRecord::Name {
                id: "new".into(),
                name: "Home".to_owned()
            })
        );
        assert_eq!(
            all.assign(&"gone".into(), &["!a".into()], true),
            Err(LabelError::NotFound)
        );
        assert_eq!(
            all.assign(&"work".into(), &["!b".into(), "!b".into()], true)
                .unwrap()
                .len(),
            1
        );
    }
}
