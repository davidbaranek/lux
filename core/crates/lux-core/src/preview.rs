//! A chat's newest message, as the chat list's one line needs it: who wrote it (when the line
//! names them) and what it is; a quote's message too. The apps word and localize it
//! ("Anna: see you", "You: Photo").

/// What the newest message is.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum PreviewKind {
    /// Text (a message, a notice, an emote), on one line.
    Text(String),
    /// A photo.
    Image,
    /// A video.
    Video,
    /// A sound file.
    Audio,
    /// A voice message.
    Voice,
    /// A file, by its name if it has one.
    File(Option<String>),
    /// A shared location.
    Location,
    /// A sticker.
    Sticker,
    /// A poll, by its question.
    Poll(String),
    /// A message this device cannot read (yet): its key has not come.
    Encrypted,
    /// A message deleted by its sender or a moderator.
    Deleted,
    /// A reaction to a message, by its key (an emoji).
    Reaction(String),
    /// A call (started, or ringing).
    Call,
    /// Someone joined the chat, was invited to it, or asks to join it.
    Membership(Membership),
    /// Anything else the list shows as a message.
    Other,
}

/// A change to who is in a chat, as a preview names it.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Membership {
    /// Joined.
    Joined,
    /// Was invited.
    Invited,
    /// Asks to join.
    Knocked,
}

impl From<PreviewSource<'_>> for PreviewKind {
    /// What a message is, its texts on one line: a preview's, or a quote's.
    fn from(kind: PreviewSource<'_>) -> Self {
        match kind {
            PreviewSource::Text(text) => Self::Text(one_line(text)),
            PreviewSource::Image => Self::Image,
            PreviewSource::Video => Self::Video,
            PreviewSource::Audio => Self::Audio,
            PreviewSource::Voice => Self::Voice,
            PreviewSource::File(name) => Self::File(name.map(one_line)),
            PreviewSource::Location => Self::Location,
            PreviewSource::Sticker => Self::Sticker,
            PreviewSource::Poll(question) => Self::Poll(one_line(question)),
            PreviewSource::Encrypted => Self::Encrypted,
            PreviewSource::Deleted => Self::Deleted,
            PreviewSource::Reaction(key) => Self::Reaction(one_line(key)),
            PreviewSource::Call => Self::Call,
            PreviewSource::Membership(membership) => Self::Membership(membership),
            PreviewSource::Other => Self::Other,
        }
    }
}

/// What the newest message is, as the mapping reads it: its texts borrowed from the event.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PreviewSource<'a> {
    /// Text, as it was sent.
    Text(&'a str),
    /// A photo.
    Image,
    /// A video.
    Video,
    /// A sound file.
    Audio,
    /// A voice message.
    Voice,
    /// A file, by its name if it has one.
    File(Option<&'a str>),
    /// A shared location.
    Location,
    /// A sticker.
    Sticker,
    /// A poll, by its question.
    Poll(&'a str),
    /// A message this device cannot read (yet).
    Encrypted,
    /// A deleted message.
    Deleted,
    /// A reaction, by its key.
    Reaction(&'a str),
    /// A call.
    Call,
    /// A change to who is in the chat.
    Membership(Membership),
    /// Anything else.
    Other,
}

/// Who the line names before the message.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Author {
    /// The account itself ("You: …").
    Own,
    /// Someone else, by the name the chat shows ("Anna: …").
    Named(String),
}

/// Who sent the newest message, as the mapping knows it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Sender<'a> {
    /// The account itself.
    Own,
    /// Someone else, by the name the chat shows (empty when not known).
    Other(&'a str),
}

/// A chat's newest message in one line.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Preview {
    /// Whom the line names: always the account itself, others only in a group.
    pub author: Option<Author>,
    /// What the message is.
    pub kind: PreviewKind,
}

/// The most a line keeps: the list shows one line, and the rest would only cross the boundary.
const MAX_CHARACTERS: usize = 160;

impl Preview {
    /// The line of a message of `kind` from `sender`: its texts on one line, the account always
    /// named, someone else only in a group, or when what happened is theirs to word (a reaction,
    /// a join: "Anna reacted ❤️").
    #[must_use]
    pub fn new(kind: PreviewSource<'_>, sender: Sender<'_>, is_group: bool) -> Self {
        let names_anyone = is_group || matches!(kind, PreviewSource::Reaction(_) | PreviewSource::Membership(_));
        let kind = PreviewKind::from(kind);
        let author = match sender {
            Sender::Own => Some(Author::Own),
            Sender::Other(name) if names_anyone && !name.is_empty() => Some(Author::Named(name.to_owned())),
            Sender::Other(_) => None,
        };
        Self { author, kind }
    }

    /// A line that is only text, named by nobody: what an app hands back of a line it worded.
    #[must_use]
    pub fn text(line: impl Into<String>) -> Self {
        Self {
            author: None,
            kind: PreviewKind::Text(line.into()),
        }
    }

    /// The account wrote the message.
    #[must_use]
    pub fn is_own(&self) -> bool {
        self.author == Some(Author::Own)
    }
}

/// Text on one line: runs of white space (new lines too) as one space, and no more than
/// `MAX_CHARACTERS`.
fn one_line(text: &str) -> String {
    let mut line = String::with_capacity(text.len().min(MAX_CHARACTERS * 4));
    for (count, word) in text.split_whitespace().enumerate() {
        if count > 0 {
            line.push(' ');
        }
        line.push_str(word);
        if line.len() >= MAX_CHARACTERS {
            break;
        }
    }
    match line.char_indices().nth(MAX_CHARACTERS) {
        Some((end, _)) => {
            line.truncate(end);
            line.push('…');
            line
        }
        None => line,
    }
}

#[cfg(test)]
mod tests {
    use super::{Author, Preview, PreviewKind, PreviewSource, Sender};

    fn text(text: &str) -> PreviewKind {
        PreviewKind::Text(text.to_owned())
    }

    fn sent(text: &str) -> PreviewSource<'_> {
        PreviewSource::Text(text)
    }

    #[test]
    fn a_group_names_the_sender() {
        let preview = Preview::new(sent("hi"), Sender::Other("Anna"), true);
        assert_eq!(preview.author, Some(Author::Named("Anna".to_owned())));
        assert_eq!(preview.kind, text("hi"));
    }

    #[test]
    fn a_direct_chat_does_not() {
        assert_eq!(Preview::new(sent("hi"), Sender::Other("Anna"), false).author, None);
        assert_eq!(Preview::new(sent("hi"), Sender::Other(""), true).author, None);
    }

    #[test]
    fn own_messages_are_named_everywhere() {
        let preview = Preview::new(PreviewSource::Image, Sender::Own, false);
        assert!(preview.is_own());
        assert_eq!(preview.kind, PreviewKind::Image);
    }

    #[test]
    fn text_shows_on_one_line() {
        let preview = Preview::new(sent("first line\n\n  second\tline "), Sender::Other("Bob"), false);
        assert_eq!(preview.kind, text("first line second line"));
        let file = Preview::new(PreviewSource::File(Some("a\nb.pdf")), Sender::Own, false);
        assert_eq!(file.kind, PreviewKind::File(Some("a b.pdf".to_owned())));
    }

    #[test]
    fn long_text_is_cut() {
        let preview = Preview::new(sent(&"ž".repeat(500)), Sender::Other(""), false);
        let PreviewKind::Text(shown) = preview.kind else {
            panic!("not text")
        };
        assert_eq!(shown.chars().count(), super::MAX_CHARACTERS + 1);
        assert!(shown.ends_with('…'));
    }

    #[test]
    fn a_quote_is_its_kind_on_one_line() {
        assert_eq!(PreviewKind::from(sent("a\nb")), text("a b"));
        assert_eq!(PreviewKind::from(PreviewSource::Image), PreviewKind::Image);
    }

    #[test]
    fn reactions_and_joins_name_their_author_in_a_direct_chat_too() {
        let reaction = Preview::new(PreviewSource::Reaction("❤️"), Sender::Other("Anna"), false);
        assert_eq!(reaction.author, Some(Author::Named("Anna".to_owned())));
        assert_eq!(reaction.kind, PreviewKind::Reaction("❤️".to_owned()));
        let joined = Preview::new(PreviewSource::Membership(super::Membership::Joined), Sender::Own, false);
        assert!(joined.is_own());
    }

    #[test]
    fn a_worded_line_is_text_by_nobody() {
        let line = Preview::text("Anna: hi");
        assert_eq!((line.author, line.kind), (None, text("Anna: hi")));
    }
}
