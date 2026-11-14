//! Which of a timeline's messages a chat shows: its last screenful when it opens, then every
//! message since, so a new message never pushes one the reader has loaded out; paging back moves
//! its start earlier.

use std::borrow::Borrow;

use crate::ids::MessageId;
use crate::message::Message;

/// Where the shown messages start in a timeline, kept across its changes.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(crate) struct Window {
    /// The first shown message, once the timeline has more than a screenful.
    first: Option<MessageId>,
    /// How many were shown from there, for when that message goes.
    shown: usize,
}

impl Window {
    /// A window on a timeline not shown yet.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Where the shown messages start in `messages` (oldest first), showing at least the last
    /// `limit`. While the timeline holds no more than that, it shows them all (older ones still
    /// coming in from the server show too); once it holds more, the start stays at its message.
    pub fn start<M: Borrow<Message>>(&mut self, messages: &[M], limit: usize) -> usize {
        let at_least = messages.len().saturating_sub(limit);
        let start = match &self.first {
            None => at_least,
            Some(first) => match messages.iter().position(|message| &message.borrow().id == first) {
                Some(index) => index.min(at_least),
                // the first shown message went (deleted, or the timeline was cleared).
                None => messages.len().saturating_sub(self.shown.max(limit)),
            },
        };
        self.anchor(messages, start);
        start
    }

    /// Shows `count` more messages before the start, of those `messages` holds; returns how
    /// many fewer it holds than that (older messages to load first).
    pub fn extend<M: Borrow<Message>>(&mut self, messages: &[M], limit: usize, count: usize) -> usize {
        let start = self.start(messages, limit);
        let earlier = start.saturating_sub(count);
        self.first = messages.get(earlier).map(|message| message.borrow().id.clone());
        self.shown = messages.len() - earlier;
        count - (start - earlier)
    }

    /// Whether the window shows the first message `messages` holds.
    pub fn shows_first<M: Borrow<Message>>(&mut self, messages: &[M], limit: usize) -> bool {
        self.start(messages, limit) == 0
    }

    fn anchor<M: Borrow<Message>>(&mut self, messages: &[M], start: usize) {
        // all of the timeline shows: no anchor yet, so what pages in before shows too.
        if start > 0 || self.first.is_some() {
            self.first = messages.get(start).map(|message| message.borrow().id.clone());
        }
        self.shown = messages.len() - start;
    }
}

#[cfg(test)]
mod tests {
    use std::time::SystemTime;

    use super::*;
    use crate::message::SendState;

    fn messages(ids: impl IntoIterator<Item = u32>) -> Vec<Message> {
        ids.into_iter()
            .map(|id| Message {
                id: id.to_string().into(),
                sender: "@a".into(),
                room: None,
                date: SystemTime::UNIX_EPOCH,
                state: SendState::Sent,
                is_edited: false,
                body: String::new(),
                attachment: None,
                is_reply: false,
                has_reactions: false,
                links: Vec::new(),
            })
            .collect()
    }

    #[test]
    fn it_opens_on_the_last_screenful_and_keeps_its_start() {
        let mut window = Window::new();
        assert_eq!(window.start(&messages(0..10), 4), 6);
        // new messages come: the start stays at the same message.
        assert_eq!(window.start(&messages(0..12), 4), 6);
    }

    #[test]
    fn older_messages_paging_in_show_while_the_screen_is_not_full() {
        let mut window = Window::new();
        assert_eq!(window.start(&messages(5..8), 4), 0);
        assert_eq!(window.start(&messages(2..8), 4), 2);
        // full now: more pages in before stay hidden until the user pages back.
        assert_eq!(window.start(&messages(0..8), 4), 4);
    }

    #[test]
    fn paging_back_moves_the_start() {
        let mut window = Window::new();
        let all = messages(0..10);
        assert_eq!(window.start(&all, 4), 6);
        assert_eq!(window.extend(&all, 4, 3), 0);
        assert_eq!(window.start(&all, 4), 3);
        // fewer than asked: the rest is to load.
        assert_eq!(window.extend(&all, 4, 5), 2);
        assert!(window.shows_first(&all, 4));
    }

    #[test]
    fn a_start_that_went_keeps_as_many_shown() {
        let mut window = Window::new();
        assert_eq!(window.start(&messages(0..10), 4), 6);
        assert_eq!(window.extend(&messages(0..10), 4, 2), 0);
        let without: Vec<Message> = messages((0..4).chain(5..10));
        assert_eq!(window.start(&without, 4), 3);
    }
}
