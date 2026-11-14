//! A list's diffs, with only the items that map to something: a timeline's messages from the
//! SDK's items, which include day dividers and other rows the thread does not take.

use eyeball_im::{Vector, VectorDiff};

/// Turns the diffs of a list whose items may map to nothing into the diffs of the items that do.
/// Remembers which of the source's items were kept, to translate the source's positions.
#[derive(Clone, Debug, Default)]
pub struct Filtered {
    kept: Vec<bool>,
}

impl Filtered {
    /// A filter over an empty source.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// How many kept items are before the source's position `index`.
    fn position(&self, index: usize) -> usize {
        self.kept[..index.min(self.kept.len())]
            .iter()
            .filter(|kept| **kept)
            .count()
    }

    /// The diff of the kept items for one diff of the source, its items already mapped (`None`
    /// for one that maps to nothing); `None` when the kept items do not change. A position
    /// beyond the source's end (which a well-formed source never sends) changes nothing.
    pub fn apply<T: Clone>(&mut self, diff: VectorDiff<Option<T>>) -> Option<VectorDiff<T>> {
        match diff {
            VectorDiff::Append { values } => {
                self.kept.extend(values.iter().map(Option::is_some));
                let values: Vector<T> = values.into_iter().flatten().collect();
                (!values.is_empty()).then_some(VectorDiff::Append { values })
            }
            VectorDiff::Reset { values } => {
                self.kept = values.iter().map(Option::is_some).collect();
                Some(VectorDiff::Reset {
                    values: values.into_iter().flatten().collect(),
                })
            }
            VectorDiff::Clear => {
                let had = self.kept.iter().any(|kept| *kept);
                self.kept.clear();
                had.then_some(VectorDiff::Clear)
            }
            VectorDiff::PushFront { value } => {
                self.kept.insert(0, value.is_some());
                value.map(|value| VectorDiff::PushFront { value })
            }
            VectorDiff::PushBack { value } => {
                self.kept.push(value.is_some());
                value.map(|value| VectorDiff::PushBack { value })
            }
            VectorDiff::PopFront => {
                if self.kept.is_empty() {
                    return None;
                }
                self.kept.remove(0).then_some(VectorDiff::PopFront)
            }
            VectorDiff::PopBack => self.kept.pop()?.then_some(VectorDiff::PopBack),
            VectorDiff::Insert { index, value } => {
                if index > self.kept.len() {
                    return None;
                }
                let position = self.position(index);
                self.kept.insert(index, value.is_some());
                value.map(|value| VectorDiff::Insert { index: position, value })
            }
            VectorDiff::Set { index, value } => {
                let position = self.position(index);
                let was = std::mem::replace(self.kept.get_mut(index)?, value.is_some());
                match (was, value) {
                    (true, Some(value)) => Some(VectorDiff::Set { index: position, value }),
                    (false, Some(value)) => Some(VectorDiff::Insert { index: position, value }),
                    (true, None) => Some(VectorDiff::Remove { index: position }),
                    (false, None) => None,
                }
            }
            VectorDiff::Remove { index } => {
                if index >= self.kept.len() {
                    return None;
                }
                let position = self.position(index);
                self.kept
                    .remove(index)
                    .then_some(VectorDiff::Remove { index: position })
            }
            VectorDiff::Truncate { length } => {
                if length >= self.kept.len() {
                    return None;
                }
                let (before, after) = (self.position(self.kept.len()), self.position(length));
                self.kept.truncate(length);
                (after < before).then_some(VectorDiff::Truncate { length: after })
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The source and its kept items, applied side by side.
    struct Both {
        source: Vector<Option<char>>,
        kept: Vector<char>,
        filter: Filtered,
    }

    impl Both {
        fn new() -> Self {
            Self {
                source: Vector::new(),
                kept: Vector::new(),
                filter: Filtered::new(),
            }
        }

        fn apply(&mut self, diff: VectorDiff<Option<char>>) {
            diff.clone().apply(&mut self.source);
            if let Some(kept) = self.filter.apply(diff) {
                kept.apply(&mut self.kept);
            }
            let expected: Vector<char> = self.source.iter().copied().flatten().collect();
            assert_eq!(self.kept, expected);
        }
    }

    #[test]
    fn the_kept_items_follow_every_kind_of_diff() {
        let mut both = Both::new();
        both.apply(VectorDiff::Reset {
            values: [None, Some('a'), Some('b'), None, Some('c')].into_iter().collect(),
        });
        both.apply(VectorDiff::Insert {
            index: 1,
            value: Some('x'),
        });
        both.apply(VectorDiff::Insert { index: 4, value: None });
        both.apply(VectorDiff::Set {
            index: 0,
            value: Some('y'),
        });
        both.apply(VectorDiff::Set { index: 2, value: None });
        both.apply(VectorDiff::Set {
            index: 2,
            value: Some('z'),
        });
        both.apply(VectorDiff::Set { index: 4, value: None });
        both.apply(VectorDiff::Remove { index: 1 });
        both.apply(VectorDiff::PushFront { value: None });
        both.apply(VectorDiff::PushBack { value: Some('d') });
        both.apply(VectorDiff::Append {
            values: [Some('e'), None].into_iter().collect(),
        });
        both.apply(VectorDiff::PopFront);
        both.apply(VectorDiff::PopBack);
        both.apply(VectorDiff::Truncate { length: 3 });
        both.apply(VectorDiff::Clear);
        both.apply(VectorDiff::PushBack { value: Some('f') });
    }

    /// A diff a well-formed source of `len` items can send; `None` when there is none.
    fn diff_for(
        len: usize,
        kind: u8,
        at: usize,
        value: Option<char>,
        more: Vec<Option<char>>,
    ) -> Option<VectorDiff<Option<char>>> {
        let index = at % (len + 1);
        Some(match kind % 11 {
            0 => VectorDiff::Append {
                values: more.into_iter().collect(),
            },
            1 => VectorDiff::Clear,
            2 => VectorDiff::PushFront { value },
            3 => VectorDiff::PushBack { value },
            4 if len > 0 => VectorDiff::PopFront,
            5 if len > 0 => VectorDiff::PopBack,
            6 => VectorDiff::Insert { index, value },
            7 if index < len => VectorDiff::Set { index, value },
            8 if index < len => VectorDiff::Remove { index },
            9 => VectorDiff::Truncate { length: index },
            10 => VectorDiff::Reset {
                values: more.into_iter().collect(),
            },
            _ => return None,
        })
    }

    proptest::proptest! {
        /// Any run of diffs leaves the kept items equal to filtering the source's, every
        /// item once: each diff lands at its translated position.
        #[test]
        fn the_kept_items_are_always_the_source_filtered(
            steps in proptest::collection::vec(
                (
                    proptest::prelude::any::<u8>(),
                    proptest::prelude::any::<usize>(),
                    proptest::option::of(proptest::char::range('a', 'z')),
                    proptest::collection::vec(proptest::option::of(proptest::char::range('a', 'z')), 0..4),
                ),
                0..60,
            ),
        ) {
            let mut both = Both::new();
            for (kind, at, value, more) in steps {
                if let Some(diff) = diff_for(both.source.len(), kind, at, value, more) {
                    both.apply(diff);
                }
            }
        }
    }

    #[test]
    fn an_item_that_maps_to_nothing_sends_nothing() {
        let mut filter = Filtered::new();
        assert!(filter.apply::<char>(VectorDiff::PushBack { value: None }).is_none());
        assert!(
            filter
                .apply::<char>(VectorDiff::Set { index: 0, value: None })
                .is_none()
        );
        assert!(filter.apply::<char>(VectorDiff::Remove { index: 0 }).is_none());
    }

    #[test]
    fn positions_past_the_end_change_nothing() {
        let mut filter = Filtered::new();
        assert!(
            filter
                .apply(VectorDiff::Set {
                    index: 3,
                    value: Some('a')
                })
                .is_none()
        );
        assert!(filter.apply::<char>(VectorDiff::Remove { index: 3 }).is_none());
        assert!(
            filter
                .apply(VectorDiff::Insert {
                    index: 3,
                    value: Some('a')
                })
                .is_none()
        );
        assert!(filter.apply::<char>(VectorDiff::PopFront).is_none());
        assert!(filter.apply::<char>(VectorDiff::PopBack).is_none());
    }
}
