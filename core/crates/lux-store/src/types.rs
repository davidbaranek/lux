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

/// A photo a search found.
#[derive(Clone, Debug, PartialEq)]
pub struct ImageHit {
    /// Its event.
    pub event_id: EventId,
    /// Its chat.
    pub room_id: RoomId,
    /// Its sender's name.
    pub sender_name: String,
    /// When it was sent.
    pub date: SystemTime,
    /// The user sent it.
    pub is_own: bool,
    /// Why it was found.
    pub reason: ImageReason,
}

/// Why a search found a photo.
#[derive(Clone, Debug, PartialEq)]
pub enum ImageReason {
    /// Its caption or the words in it have the searched words: those around them.
    Words {
        /// The words around the found ones.
        excerpt: String,
        /// The found words in `excerpt`, in UTF-16 code units.
        matches: Vec<Range<u32>>,
    },
    /// A message sent near it has the searched words: that message's words around them.
    Nearby {
        /// The words around the found ones.
        excerpt: String,
        /// The found words in `excerpt`, in UTF-16 code units.
        matches: Vec<Range<u32>>,
    },
    /// It looks like what the words say: how much, as the cosine of their embeddings.
    Looks {
        /// The cosine of the photo's and the words' embeddings.
        similarity: f32,
    },
}

/// A search for photos: by their words, the messages sent near them, and how they look.
#[derive(Clone, Debug, PartialEq)]
pub struct ImageSearch {
    /// The typed words.
    pub text: String,
    /// The words' embedding, in the photos' space; `None` finds by words only.
    pub embedding: Option<Vec<f32>>,
    /// The least cosine a photo found by its look has to the words'.
    pub min_similarity: f32,
    /// One chat's photos only.
    pub room_id: Option<RoomId>,
    /// At most this many.
    pub limit: u32,
}

/// What the apps read in a photo.
#[derive(Clone, Debug, PartialEq)]
pub struct ImageRead {
    /// Its event.
    pub event_id: EventId,
    /// Who read it: the readers and their versions, so a newer reader reads it again.
    pub reader: String,
    /// The words in it.
    pub words: String,
    /// Its embedding, of unit length; `None` when the reader makes none.
    pub embedding: Option<Vec<f32>>,
}

/// How many photos the index has, and how far they were read.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct ImageCounts {
    /// The photos.
    pub total: u64,
    /// The photos done for the reader asked about: read by it, or left after too many failed
    /// tries (the others wait for it).
    pub read: u64,
    /// The photos whose words were read, by any reader.
    pub with_words: u64,
    /// The photos with an embedding.
    pub with_embedding: u64,
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
