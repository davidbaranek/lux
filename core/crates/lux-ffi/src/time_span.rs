//! Spans of time across the FFI: Rust's `Duration` here, Swift's `Duration` in the apps.
//!
//! UniFFI's own `Duration` is a `TimeInterval` (a `Double`) in Swift, and its bindings trap on a
//! negative one. `TimeSpan` crosses as whole seconds and nanoseconds instead, and `uniffi.toml`
//! maps it to Swift's `Duration`, so neither side ever holds a bare number of seconds.

use std::time::Duration;

/// A span of time; Swift's `Duration` (`uniffi.toml`).
///
/// A negative Swift `Duration` has no Rust counterpart: it crosses as zero, the one place that
/// decides so.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, PartialOrd, Ord)]
pub struct TimeSpan(pub Duration);

/// How a `TimeSpan` crosses: Swift's `Duration.components`, in nanoseconds.
#[derive(uniffi::Record)]
pub struct TimeSpanParts {
    /// Whole seconds.
    pub seconds: u64,
    /// The nanoseconds past them, under a billion.
    pub nanoseconds: u32,
}

/// The parts were not a span: nanoseconds of a second or more.
#[derive(Debug, thiserror::Error)]
#[error("not a span of time: {seconds} s and {nanoseconds} ns")]
pub struct InvalidTimeSpan {
    seconds: u64,
    nanoseconds: u32,
}

impl TryFrom<TimeSpanParts> for TimeSpan {
    type Error = InvalidTimeSpan;

    fn try_from(parts: TimeSpanParts) -> Result<Self, Self::Error> {
        let TimeSpanParts { seconds, nanoseconds } = parts;
        if nanoseconds >= 1_000_000_000 {
            return Err(InvalidTimeSpan { seconds, nanoseconds });
        }
        // under a second of nanoseconds carry nothing into the seconds, so this cannot overflow.
        Ok(Self(Duration::new(seconds, nanoseconds)))
    }
}

impl From<TimeSpan> for TimeSpanParts {
    fn from(span: TimeSpan) -> Self {
        Self {
            seconds: span.0.as_secs(),
            nanoseconds: span.0.subsec_nanos(),
        }
    }
}

impl From<Duration> for TimeSpan {
    fn from(duration: Duration) -> Self {
        Self(duration)
    }
}

impl From<TimeSpan> for Duration {
    fn from(span: TimeSpan) -> Self {
        span.0
    }
}

// lowered and lifted by the `From` and `TryFrom` above.
uniffi::custom_type!(TimeSpan, TimeSpanParts);

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn crosses_whole() {
        let span = TimeSpan(Duration::new(3, 250_000_000));
        let parts = TimeSpanParts::from(span);
        assert_eq!((parts.seconds, parts.nanoseconds), (3, 250_000_000));
        assert_eq!(TimeSpan::try_from(parts).ok(), Some(span));
    }

    #[test]
    fn refuses_what_is_not_a_span() {
        let past_a_second = TimeSpanParts {
            seconds: 1,
            nanoseconds: 1_000_000_000,
        };
        assert!(TimeSpan::try_from(past_a_second).is_err());
        let longest = TimeSpanParts {
            seconds: u64::MAX,
            nanoseconds: 999_999_999,
        };
        assert_eq!(TimeSpan::try_from(longest).ok(), Some(TimeSpan(Duration::MAX)));
    }
}
