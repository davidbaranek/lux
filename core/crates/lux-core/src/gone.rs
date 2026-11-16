//! The other end of a channel, a task or a thread that may be gone: the one place that says a
//! failure to deliver is no loss.

/// A send to, or a wait on, another end that may legitimately have gone first: a listener that
/// stopped listening, a caller that stopped waiting, a task that ended with its account.
///
/// Only for that: a failure that loses something (a user's change, an error no one else
/// reports) is handled where it happens.
pub trait OtherEndGone {
    /// Notes at `debug` that `other_end` was gone; nothing else happens.
    fn other_end_may_be_gone(self, other_end: &'static str);
}

impl<T, E> OtherEndGone for Result<T, E> {
    fn other_end_may_be_gone(self, other_end: &'static str) {
        if self.is_err() {
            tracing::debug!(other_end, "the other end is gone");
        }
    }
}
