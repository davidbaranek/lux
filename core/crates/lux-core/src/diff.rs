//! The changes from one list to the next, as a batch of [`VectorDiff`]s: what a list made anew
//! (the chat list with the account data applied) sends its subscribers, so the apps redraw only
//! the rows that changed.

use std::collections::{HashMap, HashSet};
use std::hash::Hash;
use std::sync::Arc;

use eyeball_im::{Vector, VectorDiff};

/// The diffs that turn `old` into `new`, rows matched by `key`: a changed row is a `Set`, a gone
/// one a `Remove`, a new one an `Insert`, a moved one a `Remove` and an `Insert`. The rows that
/// stay are the longest run of rows still in their order, so the fewest rows move. When more
/// than half the list changes, or a key shows twice, one `Reset` says it shorter. Empty when
/// nothing changed. O(n log n).
pub fn changes<'a, T, K>(old: &'a [T], new: &'a [T], key: impl Fn(&'a T) -> K) -> Vec<VectorDiff<T>>
where
    T: Clone + PartialEq,
    K: Eq + Hash,
{
    changes_by(old, new, key, PartialEq::eq)
}

/// [`changes`] of shared rows: a row still the same allocation is unchanged without a look
/// inside.
pub fn shared_changes<'a, T, K>(
    old: &'a [Arc<T>],
    new: &'a [Arc<T>],
    key: impl Fn(&'a Arc<T>) -> K,
) -> Vec<VectorDiff<Arc<T>>>
where
    T: PartialEq,
    K: Eq + Hash,
{
    changes_by(old, new, key, |old, new| Arc::ptr_eq(old, new) || old == new)
}

fn changes_by<'a, T, K>(
    old: &'a [T],
    new: &'a [T],
    key: impl Fn(&'a T) -> K,
    same: impl Fn(&T, &T) -> bool,
) -> Vec<VectorDiff<T>>
where
    T: Clone,
    K: Eq + Hash,
{
    let limit = new.len() / 2 + 4;
    let reset = || {
        vec![VectorDiff::Reset {
            values: new.iter().cloned().collect::<Vector<T>>(),
        }]
    };
    let mut at_old: HashMap<K, usize> = HashMap::with_capacity(old.len());
    for (index, row) in old.iter().enumerate() {
        if at_old.insert(key(row), index).is_some() {
            return reset();
        }
    }
    // each new row's old position, if it had one.
    let mut seen: HashSet<K> = HashSet::with_capacity(new.len());
    let mut from: Vec<Option<usize>> = Vec::with_capacity(new.len());
    for row in new {
        let wanted = key(row);
        from.push(at_old.get(&wanted).copied());
        if !seen.insert(wanted) {
            return reset();
        }
    }
    let stays = longest_increasing(&from, old.len());
    let staying = stays.iter().filter(|stays| **stays).count();
    if (old.len() - staying) + (new.len() - staying) > limit {
        return reset();
    }
    // the rows that go or move first, the last first, so each index is still the old one; then
    // the staying rows are in place, and each new row goes where it shows.
    let mut diffs: Vec<VectorDiff<T>> = (0..old.len())
        .rev()
        .filter(|index| !stays[*index])
        .map(|index| VectorDiff::Remove { index })
        .collect();
    for (index, (row, from)) in new.iter().zip(from).enumerate() {
        match from {
            Some(from) if stays[from] => {
                if !same(&old[from], row) {
                    diffs.push(VectorDiff::Set {
                        index,
                        value: row.clone(),
                    });
                }
            }
            _ => diffs.push(VectorDiff::Insert {
                index,
                value: row.clone(),
            }),
        }
        if diffs.len() > limit {
            return reset();
        }
    }
    diffs
}

/// Which old positions stay: those of the longest increasing run in `from` (distinct old
/// positions, in the new order), by patience sorting. Indexed by old position, `len` of them.
fn longest_increasing(from: &[Option<usize>], len: usize) -> Vec<bool> {
    let positions: Vec<usize> = from.iter().flatten().copied().collect();
    // `tails[k]`: where in `positions` the run of length k + 1 with the lowest end ends.
    let mut tails: Vec<usize> = Vec::new();
    let mut before: Vec<Option<usize>> = Vec::with_capacity(positions.len());
    for (at, &position) in positions.iter().enumerate() {
        let length = tails.partition_point(|&tail| positions[tail] < position);
        before.push(length.checked_sub(1).map(|shorter| tails[shorter]));
        if length == tails.len() {
            tails.push(at);
        } else {
            tails[length] = at;
        }
    }
    let mut stays = vec![false; len];
    let mut next = tails.last().copied();
    while let Some(at) = next {
        stays[positions[at]] = true;
        next = before[at];
    }
    stays
}

/// Applies one diff to a plain list. A position past the end, which the sources never send, is
/// ignored rather than trapping: one policy for every list the view models keep.
pub(crate) fn apply<T: Clone>(list: &mut Vec<T>, diff: VectorDiff<T>) {
    match diff {
        VectorDiff::Append { values } => list.extend(values),
        VectorDiff::Clear => list.clear(),
        VectorDiff::PushFront { value } => list.insert(0, value),
        VectorDiff::PushBack { value } => list.push(value),
        VectorDiff::PopFront => {
            if !list.is_empty() {
                list.remove(0);
            }
        }
        VectorDiff::PopBack => {
            list.pop();
        }
        VectorDiff::Insert { index, value } => {
            if index <= list.len() {
                list.insert(index, value);
            }
        }
        VectorDiff::Set { index, value } => {
            if let Some(slot) = list.get_mut(index) {
                *slot = value;
            }
        }
        VectorDiff::Remove { index } => {
            if index < list.len() {
                list.remove(index);
            }
        }
        VectorDiff::Truncate { length } => list.truncate(length),
        VectorDiff::Reset { values } => {
            list.clear();
            list.extend(values);
        }
    }
}

#[cfg(test)]
mod tests {
    use eyeball_im::{Vector, VectorDiff};

    use proptest::prelude::*;

    use super::changes;

    type Row = (char, u32);

    fn apply(mut list: Vector<Row>, diffs: Vec<VectorDiff<Row>>) -> Vector<Row> {
        for diff in diffs {
            diff.apply(&mut list);
        }
        list
    }

    fn check(old: &[Row], new: &[Row]) -> Vec<VectorDiff<Row>> {
        let diffs = changes(old, new, |row| &row.0);
        let applied = apply(old.iter().copied().collect(), diffs.clone());
        assert_eq!(applied, new.iter().copied().collect::<Vector<_>>());
        diffs
    }

    fn rows(keys: &str) -> Vec<Row> {
        keys.chars().map(|key| (key, 0)).collect()
    }

    #[test]
    fn nothing_changed_sends_nothing() {
        assert!(check(&rows("abcdefgh"), &rows("abcdefgh")).is_empty());
    }

    #[test]
    fn a_changed_row_is_set() {
        let mut new = rows("abcdefgh");
        new[2].1 = 7;
        assert_eq!(
            check(&rows("abcdefgh"), &new),
            [VectorDiff::Set {
                index: 2,
                value: ('c', 7)
            }]
        );
    }

    #[test]
    fn a_row_moving_to_the_top_is_removed_and_inserted() {
        let diffs = check(&rows("abcdefgh"), &rows("fabcdegh"));
        assert_eq!(
            diffs,
            [
                VectorDiff::Remove { index: 5 },
                VectorDiff::Insert {
                    index: 0,
                    value: ('f', 0)
                }
            ]
        );
    }

    #[test]
    fn gone_and_new_rows() {
        let diffs = check(&rows("abcdefgh"), &rows("abxdefg"));
        assert_eq!(diffs.len(), 3);
    }

    #[test]
    fn a_new_list_is_a_reset() {
        let diffs = check(&rows("abcdefgh"), &rows("stuvwxyz"));
        assert!(matches!(diffs.as_slice(), [VectorDiff::Reset { .. }]));
        check(&[], &rows("ab"));
        check(&rows("ab"), &[]);
    }

    #[test]
    fn a_row_moving_to_the_end_moves_alone() {
        let diffs = check(&rows("abcdefgh"), &rows("bcdefgha"));
        assert_eq!(
            diffs,
            [
                VectorDiff::Remove { index: 0 },
                VectorDiff::Insert {
                    index: 7,
                    value: ('a', 0)
                }
            ]
        );
    }

    proptest! {
        /// For any lists of distinct keys, the diffs turn the old list into the new one.
        #[test]
        fn the_diffs_make_the_new_list(
            old in proptest::sample::subsequence(rows("abcdefghijklmnopqrstuvwxyz"), 0..26).prop_shuffle(),
            new in proptest::sample::subsequence(rows("abcdefghijklmnopqrstuvwxyz"), 0..26).prop_shuffle(),
            changed in proptest::collection::vec(any::<bool>(), 26),
        ) {
            let new: Vec<Row> = new
                .into_iter()
                .zip(changed)
                .map(|((key, _), changed)| (key, u32::from(changed)))
                .collect();
            check(&old, &new);
        }
    }

    #[test]
    fn repeated_keys_still_end_as_the_new_list() {
        check(&rows("aab"), &rows("ab"));
        check(&rows("ab"), &rows("abb"));
    }
}
