//! What the store keeps and finds.

use std::ops::Range;
use std::time::{Duration, SystemTime};

use lux_core::ids::{EventId, RoomId};

/// How far the index has read one chat.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct IndexedChat {
    /// The newest message indexed.
    pub newest: SystemTime,
    /// Its history is indexed as far back as the index goes (or to its start).
    pub complete: bool,
}

/// A message a search found.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Hit {
    /// Its event.
    pub event_id: EventId,
    /// Its chat.
    pub room_id: RoomId,
    /// Its sender's name.
    pub sender_name: String,
    /// Its text around the found words.
    pub excerpt: String,
    /// The found words in `excerpt`, in UTF-16 code units.
    pub matches: Vec<Range<u32>>,
    /// When it was sent.
    pub date: SystemTime,
    /// The user sent it.
    pub is_own: bool,
}

/// A time as the store keeps it: milliseconds since 1970 (before it, negative).
pub(crate) fn to_millis(time: SystemTime) -> i64 {
    match time.duration_since(SystemTime::UNIX_EPOCH) {
        Ok(after) => i64::try_from(after.as_millis()).unwrap_or(i64::MAX),
        Err(before) => i64::try_from(before.duration().as_millis()).map_or(i64::MIN, |millis| -millis),
    }
}

/// The time kept as `millis`.
pub(crate) fn from_millis(millis: i64) -> SystemTime {
    let distance = Duration::from_millis(millis.unsigned_abs());
    if millis >= 0 {
        SystemTime::UNIX_EPOCH + distance
    } else {
        SystemTime::UNIX_EPOCH - distance
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn times_round_trip_in_millis_before_and_after_1970() {
        for millis in [0, 1_700_000_000_123, -62_135_769_600_000] {
            assert_eq!(to_millis(from_millis(millis)), millis);
        }
    }
}
