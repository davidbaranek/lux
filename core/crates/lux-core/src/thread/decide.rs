//! The thread's decisions that need no backend: what the composer sends, when the chat needs a
//! read receipt, when the others see the user typing, and who is typing.

use std::collections::{HashMap, HashSet};
use std::time::Duration;

use tokio::time::Instant;

use crate::ids::{MessageId, MessageRef, RoomId};
use crate::preview::{PreviewKind, PreviewSource as Kind};
use crate::timeline::{FileKind, Media, MessageKind, Quote, TimelineMessage, Typist};

/// The others see the user typing again after this, while the composer keeps changing.
pub(crate) const TYPING_AGAIN: Duration = Duration::from_secs(4);

/// What sending does: a new message, an answer to one, or a new text for one of the user's.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub enum ComposerMode {
    /// A new message.
    #[default]
    Message,
    /// An answer to a message.
    Reply(ReplyTarget),
    /// A new text for the user's own message.
    Edit {
        /// The message edited.
        message: MessageId,
        /// Its text now, for the composer to start from.
        original: String,
    },
}

impl ComposerMode {
    /// The message a reply answers.
    #[must_use]
    pub fn reply(&self) -> Option<&MessageRef> {
        match self {
            Self::Reply(target) => Some(&target.message),
            Self::Message | Self::Edit { .. } => None,
        }
    }
}

/// The message a reply answers, as the reply bar shows it (the apps word it).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ReplyTarget {
    /// The message answered: by its id, or by its event (a kept draft's).
    pub message: MessageRef,
    /// Its sender's name.
    pub sender_name: String,
    /// The user sent it ("You").
    pub is_own: bool,
    /// What it is, in one line; `None` until known.
    pub kind: Option<PreviewKind>,
}

impl ReplyTarget {
    /// The reply bar of an answer to `message`.
    pub(crate) fn of(message: &TimelineMessage) -> Self {
        Self {
            message: MessageRef::Local(message.message.id.clone()),
            sender_name: message.sender_name.clone(),
            is_own: message.is_own,
            kind: Some(kind_of(message)),
        }
    }

    /// The reply bar of a kept draft's answer.
    pub(crate) fn of_quote(quote: Quote) -> Self {
        Self {
            message: MessageRef::Event(quote.event_id),
            sender_name: quote.sender_name,
            is_own: false,
            kind: quote.kind,
        }
    }
}

/// What a message is in one line: its text, else its media.
fn kind_of(message: &TimelineMessage) -> PreviewKind {
    match message.kind {
        MessageKind::Deleted => return PreviewKind::Deleted,
        MessageKind::Undecryptable => return PreviewKind::Encrypted,
        MessageKind::Message => {}
    }
    if !message.message.body.is_empty() {
        return PreviewKind::from(Kind::Text(&message.message.body));
    }
    PreviewKind::from(match &message.media {
        Some(Media::Photo { .. }) => Kind::Image,
        Some(Media::Video { .. }) => Kind::Video,
        Some(Media::File {
            kind: FileKind::Audio, ..
        }) => Kind::Audio,
        Some(Media::File {
            kind: FileKind::Voice, ..
        }) => Kind::Voice,
        Some(Media::File { name, .. }) => Kind::File(Some(name)),
        None => Kind::Other,
    })
}

/// How a chat tells the others it was read: by itself, or when the user asks.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum ReadReceipts {
    /// A receipt goes as the user reads the newest message; the others also see the user type.
    #[default]
    Automatic,
    /// Only when the user asks (the composer's eye button).
    Manual,
}

/// Whether the others' messages are covered by the user's read receipt.
#[derive(Debug, Default)]
pub(crate) struct ReadState {
    /// The newest message the receipt covers; `None` until the chat's read state is known.
    read_up_to: Option<MessageId>,
    /// The chat had unread messages when it opened; `None` until known.
    unread_when_opened: Option<bool>,
    /// Others wrote something the receipt does not cover.
    pub(crate) needs_receipt: bool,
}

impl ReadState {
    /// The chat opened unread (the list counted unread messages, or one was found).
    pub(crate) fn opened(&mut self, unread: bool) {
        self.unread_when_opened = Some(unread);
    }

    /// The thread's newest message now: its id, and whether the user sent it.
    pub(crate) fn update(&mut self, latest: Option<(&MessageId, bool)>) {
        let (Some(unread), Some((latest, is_own))) = (self.unread_when_opened, latest) else {
            return;
        };
        // read when it opened: the receipt covers what the chat had then.
        if self.read_up_to.is_none() && !unread {
            self.read_up_to = Some(latest.clone());
        }
        // one's own message counts as read by sending it.
        self.needs_receipt = !is_own && self.read_up_to.as_ref() != Some(latest);
    }

    /// The user read up to `latest`: whether a receipt is to go.
    pub(crate) fn read(&mut self, latest: Option<&MessageId>) -> bool {
        let Some(latest) = latest.filter(|_| self.needs_receipt) else {
            return false;
        };
        self.read_up_to = Some(latest.clone());
        self.needs_receipt = false;
        true
    }
}

/// When the others are told the user types: at most every few seconds, and once when it stops.
#[derive(Debug, Default)]
pub(crate) struct TypingNotice {
    sent_at: Option<Instant>,
}

impl TypingNotice {
    /// The composer changed (`typing`: it holds text, and the chat shows the user is there):
    /// what to tell the others now, if anything.
    pub(crate) fn changed(&mut self, typing: bool, now: Instant) -> Option<bool> {
        if typing && self.sent_at.is_some_and(|sent| now.duration_since(sent) < TYPING_AGAIN) {
            return None;
        }
        if !typing && self.sent_at.is_none() {
            return None;
        }
        self.sent_at = typing.then_some(now);
        Some(typing)
    }
}

/// Who is typing in the rooms shown, in their order: one person on two networks of a merged chat
/// types once.
pub(crate) fn typists(rooms: impl Iterator<Item = RoomId>, by_room: &HashMap<RoomId, Vec<Typist>>) -> Vec<Typist> {
    let mut seen = HashSet::new();
    rooms
        .filter_map(|room| by_room.get(&room))
        .flatten()
        .filter(|typist| seen.insert(typist.name.clone()))
        .cloned()
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::thread::rows::tests::message;

    #[test]
    fn a_chat_read_when_it_opened_needs_a_receipt_only_for_what_comes_after() {
        let mut state = ReadState::default();
        // not known yet: nothing to say.
        state.update(Some((&"a".into(), false)));
        assert!(!state.needs_receipt);
        state.opened(false);
        state.update(Some((&"a".into(), false)));
        assert!(!state.needs_receipt);
        state.update(Some((&"b".into(), false)));
        assert!(state.needs_receipt);
        assert!(state.read(Some(&"b".into())));
        assert!(!state.needs_receipt);
        assert!(!state.read(Some(&"b".into())));
    }

    #[test]
    fn an_unread_chat_needs_a_receipt_and_ones_own_message_reads_it() {
        let mut state = ReadState::default();
        state.opened(true);
        state.update(Some((&"a".into(), false)));
        assert!(state.needs_receipt);
        state.update(Some((&"b".into(), true)));
        assert!(!state.needs_receipt);
    }

    #[test]
    fn typing_is_told_at_most_every_few_seconds_and_once_when_it_stops() {
        let mut notice = TypingNotice::default();
        let start = Instant::now();
        assert_eq!(notice.changed(false, start), None);
        assert_eq!(notice.changed(true, start), Some(true));
        assert_eq!(notice.changed(true, start + Duration::from_secs(1)), None);
        assert_eq!(notice.changed(true, start + TYPING_AGAIN), Some(true));
        assert_eq!(notice.changed(false, start + TYPING_AGAIN), Some(false));
        assert_eq!(notice.changed(false, start + TYPING_AGAIN), None);
    }

    #[test]
    fn one_person_typing_in_two_rooms_types_once() {
        let typist = |name: &str| Typist {
            user: format!("@{name}").into(),
            name: name.to_owned(),
            avatar: None,
        };
        let by_room = HashMap::from([
            (RoomId::from("!a"), vec![typist("Jana")]),
            (RoomId::from("!b"), vec![typist("Jana"), typist("Petr")]),
        ]);
        let names: Vec<String> = typists(["!a".into(), "!b".into()].into_iter(), &by_room)
            .into_iter()
            .map(|typist| typist.name)
            .collect();
        assert_eq!(names, ["Jana", "Petr"]);
    }

    #[test]
    fn a_reply_bar_words_a_photo_without_text_as_a_photo() {
        let mut photo = (*message("p", "!a", 0, true)).clone();
        photo.message.body.clear();
        photo.media = Some(Media::Photo {
            picture: crate::timeline::Picture {
                source: "mxc://p".into(),
                width: 1,
                height: 1,
            },
            is_animated: false,
        });
        let target = ReplyTarget::of(&photo);
        assert!(target.is_own);
        assert_eq!(target.kind, Some(PreviewKind::Image));
        assert_eq!(
            ReplyTarget::of(&message("t", "!a", 0, false)).kind,
            Some(PreviewKind::Text("text t".to_owned()))
        );
    }
}
