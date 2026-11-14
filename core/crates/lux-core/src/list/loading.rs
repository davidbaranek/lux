//! How far the chat list is: what the loading bubble says while the app connects and syncs.

/// Where loading the list is.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum LoadState {
    /// No chats from the account yet (the device's kept list may show).
    Connecting,
    /// The account's chats show while the server's first answer comes; `new_chats` arrived
    /// since the first ones (on a first sign-in, the chats as they come).
    Syncing {
        /// Chats that came after the first ones.
        new_chats: u32,
    },
    /// The server answered and no more chats arrived for a moment.
    Done,
}

/// The load state and whether the server has answered this launch's first sync.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct Loading {
    /// Where loading is.
    pub state: LoadState,
    /// The server answered the first sync.
    pub answered: bool,
}

/// Follows the account's chat count and the first sync, as a pure state machine: the view
/// model's task runs its timer (`settle`).
#[derive(Debug)]
pub(crate) struct LoadTracker {
    loading: Loading,
    /// The chats there were when the account's list first had some: those after it are new.
    first: Option<usize>,
    previous: Option<usize>,
}

impl LoadTracker {
    pub(crate) fn new() -> Self {
        Self {
            loading: Loading {
                state: LoadState::Connecting,
                answered: false,
            },
            first: None,
            previous: None,
        }
    }

    pub(crate) fn loading(&self) -> Loading {
        self.loading
    }

    /// The account's list has `count` chats. True when the wait to settle starts (again): the
    /// server has answered and the count changed.
    pub(crate) fn counted(&mut self, count: usize) -> bool {
        let previous = self.previous.replace(count);
        if self.loading.state == LoadState::Done || count == 0 {
            return false;
        }
        let first = *self.first.get_or_insert(count);
        self.loading.state = LoadState::Syncing {
            new_chats: u32::try_from(count.saturating_sub(first)).unwrap_or(u32::MAX),
        };
        self.loading.answered && previous != Some(count)
    }

    /// The server answered the first sync: the wait to settle starts.
    pub(crate) fn answered(&mut self) -> bool {
        self.loading.answered = true;
        self.loading.state != LoadState::Done
    }

    /// No chat arrived for a moment since the server answered: done.
    pub(crate) fn settled(&mut self) {
        if self.loading.answered {
            self.loading.state = LoadState::Done;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{LoadState, LoadTracker};

    #[test]
    fn connecting_then_syncing_with_the_new_chats_then_done() {
        let mut tracker = LoadTracker::new();
        assert_eq!(tracker.loading().state, LoadState::Connecting);
        assert!(!tracker.counted(0));
        assert_eq!(tracker.loading().state, LoadState::Connecting);
        // chats before the server answered: syncing, no wait yet.
        assert!(!tracker.counted(10));
        assert_eq!(tracker.loading().state, LoadState::Syncing { new_chats: 0 });
        assert!(tracker.answered());
        assert!(tracker.counted(14));
        assert_eq!(tracker.loading().state, LoadState::Syncing { new_chats: 4 });
        // the same count again does not wait again.
        assert!(!tracker.counted(14));
        tracker.settled();
        assert_eq!(tracker.loading().state, LoadState::Done);
        assert!(!tracker.counted(20));
        assert_eq!(tracker.loading().state, LoadState::Done);
    }

    #[test]
    fn it_is_not_done_before_the_server_answers() {
        let mut tracker = LoadTracker::new();
        tracker.counted(3);
        tracker.settled();
        assert_eq!(tracker.loading().state, LoadState::Syncing { new_chats: 0 });
    }
}
