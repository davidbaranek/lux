//! A chat's messages as the backend gives them: each with what the thread shows of it (its
//! sender, its media, its formatting, its reactions, the message it answers, who read it), and
//! what goes the other way (a draft, an attachment to send).
//!
//! The presentation's part of a message is [`Message`]; a [`TimelineMessage`] carries one, so
//! [`present`](crate::message::present) runs over a page of them as it is.

mod filtered;
pub mod html;
mod window;

use std::borrow::Borrow;
use std::ops::Range;
use std::path::PathBuf;
use std::time::{Duration, SystemTime};

pub use filtered::Filtered;
pub(crate) use window::Window;

use crate::ids::{EventId, MediaId, MessageId, RoomId, UserId};
use crate::message::Message;
use crate::preview::PreviewKind;

/// One message of a chat's timeline.
#[derive(Clone, Debug, PartialEq)]
pub struct TimelineMessage {
    /// What the presentation needs of it: its id, sender, date, state, text, attachment.
    pub message: Message,
    /// Its event id once the server has it.
    pub event_id: Option<EventId>,
    /// Its sender's name in the room; the user id's local part when the room does not say.
    pub sender_name: String,
    /// Its sender's picture.
    pub sender_avatar: Option<MediaId>,
    /// The account sent it.
    pub is_own: bool,
    /// The account's own text message: it can be edited.
    pub is_editable: bool,
    /// What it is, besides a message to show as it came.
    pub kind: MessageKind,
    /// Its photo, video, file or sound.
    pub media: Option<Media>,
    /// The formatting of its text (bold, links…), in UTF-16 offsets of `message.body`.
    pub styles: Vec<TextStyle>,
    /// Its reactions, by key, in the order they came.
    pub reactions: Vec<Reaction>,
    /// The message it answers.
    pub reply: Option<Quote>,
    /// Who read the chat up to it (others, not its sender), the earliest first.
    pub readers: Vec<Reader>,
    /// The post it shares from another network (a reel, a post), shown as a card under its
    /// media instead of its address.
    pub shared: Option<SharedPost>,
    /// The Matrix thread it is the root of, as the room's own timeline sums it up (a thread's
    /// own timeline shows the replies instead: its root has none).
    pub thread: Option<ThreadSummary>,
}

/// A Matrix thread under its root message: how many replied, the last reply, who took part.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ThreadSummary {
    /// How many replies it has (the root not counted).
    pub replies: u32,
    /// The last reply, once it is known.
    pub latest: Option<ThreadReply>,
    /// Who replied, as far as the device knows the replies, the last to reply first; the last
    /// reply's sender always.
    pub participants: Vec<Participant>,
    /// How many replies others sent after the account's read receipt in the thread.
    pub unread: u32,
}

/// The last reply of a Matrix thread, as its summary shows it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ThreadReply {
    /// Its sender.
    pub sender: Participant,
    /// What it is (its text in one line, a photo), for the apps to word.
    pub kind: PreviewKind,
    /// When it was sent.
    pub date: SystemTime,
}

/// Someone who replied in a Matrix thread.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Participant {
    /// Who.
    pub user: UserId,
    /// Their name in the room; the user id's local part when the room does not say.
    pub name: String,
    /// Their picture.
    pub avatar: Option<MediaId>,
}

/// A post shared from another network: its address, which the message's menu shows and copies,
/// and what the post says of itself (none while the server has not read its page).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct SharedPost {
    /// Its address.
    pub url: String,
    /// Its title (the author and network, or the post's own).
    pub title: Option<String>,
    /// Its caption.
    pub description: Option<String>,
}

impl Borrow<Message> for TimelineMessage {
    fn borrow(&self) -> &Message {
        &self.message
    }
}

impl Borrow<Message> for std::sync::Arc<TimelineMessage> {
    fn borrow(&self) -> &Message {
        &self.message
    }
}

/// What a message is, when it is not one to show as it came.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum MessageKind {
    /// A message, its text and media as sent.
    #[default]
    Message,
    /// Deleted by its sender or a moderator: the app says so.
    Deleted,
    /// Encrypted, and its key has not come (yet): the app says it waits for it.
    Undecryptable,
}

/// A picture the thread can show: a photo's thumbnail, a video's poster.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Picture {
    /// The media, to load by.
    pub source: MediaId,
    /// Its width in pixels; 0 when the sender did not say.
    pub width: u32,
    /// Its height in pixels; 0 when the sender did not say.
    pub height: u32,
}

/// What kind of file a file message is.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FileKind {
    /// Any file.
    Document,
    /// A sound file.
    Audio,
    /// A voice message.
    Voice,
}

/// A message's media.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Media {
    /// A photo.
    Photo {
        /// What shows in the thread.
        picture: Picture,
        /// It moves (a GIF).
        is_animated: bool,
    },
    /// A video.
    Video {
        /// Its poster, when the sender sent one.
        poster: Option<Picture>,
        /// Its length, when the sender said.
        duration: Option<Duration>,
    },
    /// A file or a sound, drawn as a row with its name.
    File {
        /// Its name ("Trip plan.pdf").
        name: String,
        /// Its size in bytes, when the sender said.
        size: Option<u64>,
        /// Its type (`application/pdf`); empty when the sender did not say.
        mimetype: String,
        /// A document, a sound, a voice message.
        kind: FileKind,
        /// A sound's length, when the sender said.
        duration: Option<Duration>,
    },
}

/// How a run of a message's text is formatted.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum StyleKind {
    /// Bold (a mention too).
    Bold,
    /// Italic.
    Italic,
    /// Underlined.
    Underline,
    /// Struck through.
    Strikethrough,
    /// Code inside a line.
    Code,
    /// A block of code: its own lines, spaces kept.
    CodeBlock,
    /// A quote.
    Quote,
    /// A link, to this address.
    Link(String),
}

/// A run of formatting in a text, in UTF-16 offsets (as the apps' text views count).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TextStyle {
    /// How it is formatted.
    pub kind: StyleKind,
    /// Where it is.
    pub range: Range<usize>,
}

/// One reaction's key, and who reacted with it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Reaction {
    /// The emoji (or text) reacted with.
    pub key: String,
    /// How many reacted with it.
    pub count: u32,
    /// The account is among them.
    pub is_mine: bool,
}

/// The message a reply answers, as its quote shows it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Quote {
    /// The message answered.
    pub event_id: EventId,
    /// Its sender's name; empty until it is known.
    pub sender_name: String,
    /// Its sender's picture, beside a quote drawn above its answer; `None` without one, or until
    /// it is known.
    pub sender_avatar: Option<MediaId>,
    /// What it is (its text in one line, a photo), for the apps to word; `None` until it is known.
    pub kind: Option<PreviewKind>,
}

/// Someone who read the chat up to a message.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Reader {
    /// Who.
    pub user: UserId,
    /// Their name in the room; the user id's local part when the room does not say.
    pub name: String,
}

/// Someone typing in a chat.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Typist {
    /// Who.
    pub user: UserId,
    /// Their name in the room.
    pub name: String,
    /// Their picture.
    pub avatar: Option<MediaId>,
}

/// What the composer holds for a chat between visits.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Draft {
    /// Its text.
    pub text: String,
    /// The message it answers.
    pub reply: Option<Quote>,
}

/// What kind of file is sent, and what other apps show of it.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum OutgoingKind {
    /// A picture, its size in pixels.
    Photo {
        /// Its width.
        width: u32,
        /// Its height.
        height: u32,
    },
    /// A video, its size in pixels and its length; the thumbnail is its poster.
    Video {
        /// Its width.
        width: u32,
        /// Its height.
        height: u32,
        /// Its length.
        duration: Duration,
    },
    /// Any other file.
    File,
}

/// A smaller copy of a picture, which other apps show until they need the picture.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct OutgoingThumbnail {
    /// Where it is on the device.
    pub file: PathBuf,
    /// Its type (`image/jpeg`).
    pub mimetype: String,
    /// Its size in bytes.
    pub size: u64,
    /// Its width.
    pub width: u32,
    /// Its height.
    pub height: u32,
}

/// A photo, video or file to send, prepared on the device.
#[derive(Clone, Debug, PartialEq)]
pub struct OutgoingAttachment {
    /// Where it is on the device.
    pub file: PathBuf,
    /// The name other apps show.
    pub name: String,
    /// Its type.
    pub mimetype: String,
    /// Its size in bytes.
    pub size: u64,
    /// What it is.
    pub kind: OutgoingKind,
    /// Its smaller copy (a video's poster).
    pub thumbnail: Option<OutgoingThumbnail>,
}

/// A text message, as the search index keeps it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct IndexedMessage {
    /// Its event.
    pub event_id: EventId,
    /// Its room.
    pub room: RoomId,
    /// Its sender's name.
    pub sender_name: String,
    /// Its text.
    pub body: String,
    /// The web addresses in it (a formatted link's too, whose text may differ), each once.
    pub links: Vec<String>,
    /// The thread it replies in: its root's event.
    pub thread: Option<EventId>,
    /// When it was sent.
    pub date: SystemTime,
    /// The account sent it.
    pub is_own: bool,
}

/// A file, as the search index keeps it: its name, to find it by, and where it is.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct IndexedFile {
    /// Its event.
    pub event_id: EventId,
    /// Its room.
    pub room: RoomId,
    /// Its sender's name.
    pub sender_name: String,
    /// Its name.
    pub name: String,
    /// Its size in bytes, when its message says.
    pub size: Option<u64>,
    /// Its type, when its message says.
    pub mimetype: Option<String>,
    /// When it was sent.
    pub date: SystemTime,
    /// The account sent it.
    pub is_own: bool,
}

/// A photo, as the search index keeps it: where it is and who sent it; what it shows is the
/// apps' to read (its words; its embedding, when the user turns search by look on).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct IndexedImage {
    /// Its event.
    pub event_id: EventId,
    /// Its room.
    pub room: RoomId,
    /// Its sender's name.
    pub sender_name: String,
    /// The words sent with it; empty when none.
    pub caption: String,
    /// When it was sent.
    pub date: SystemTime,
    /// The account sent it.
    pub is_own: bool,
}

/// Where a timeline's unread messages start, as far as it holds them.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Unread {
    /// The first message another sent after the account's read receipt, of those the timeline
    /// holds; `None` when it holds none.
    pub first: Option<MessageId>,
    /// The timeline holds the receipt's place (or the room's first message): no older message is
    /// unread. `false`: older ones may be, and a page back tells.
    pub complete: bool,
}

/// The message a timeline was opened around, as that timeline shows it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Focused {
    /// Its id, the same in every timeline of the room.
    pub message: MessageId,
    /// The Matrix thread it is a reply in, by its root; `None`: the room's own timeline.
    pub thread: Option<EventId>,
}

/// A chat's messages for the search index back to a date, newest first: its text messages (with
/// their links and threads), its photos and its files.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct IndexHistory {
    /// The text messages, newest first.
    pub messages: Vec<IndexedMessage>,
    /// The photos, newest first.
    pub images: Vec<IndexedImage>,
    /// The files, newest first.
    pub files: Vec<IndexedFile>,
    /// The chat's first message is among them: there is nothing older.
    pub reached_start: bool,
    /// The read went back to `since`: what is older was not asked for.
    pub reached_since: bool,
    /// Where to read on, older: the pages ran out before `since` or the start. Kept, a later read
    /// goes on from there instead of reading the newer history again.
    pub older: Option<String>,
    /// The messages deleted in that time, which the index may hold from before.
    pub removed: Vec<EventId>,
    /// The chat was deleted when its newest message was this one's: nothing up to it shows any
    /// more (none of it is among `messages`), and the index forgets what it holds of it.
    pub deleted_until: Option<SystemTime>,
}

/// A picture the apps show, to load as a file.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum ImageSource {
    /// A room's picture.
    Room(RoomId),
    /// A person's picture, by its media.
    Person(MediaId),
    /// A photo message's thumbnail.
    Photo {
        /// Its room.
        room: RoomId,
        /// The message.
        message: MessageId,
    },
    /// A video message's poster.
    Poster {
        /// Its room.
        room: RoomId,
        /// The message.
        message: MessageId,
    },
    /// A shared photo's thumbnail or video's poster, by its event, which the timeline may not hold.
    Shared {
        /// Its room.
        room: RoomId,
        /// The message's event.
        event: EventId,
    },
}

/// Who sees that the account read a chat.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Receipt {
    /// Everyone in it (and, through a bridge, the other network).
    Public,
    /// Only the account's own devices.
    Private,
}

/// A message pinned in a room (`m.room.pinned_events`), as the chat's pinned bar shows it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PinnedMessage {
    /// Its room.
    pub room: RoomId,
    /// Its event: a jump goes there.
    pub event: EventId,
    /// Who wrote it.
    pub sender: Participant,
    /// What it is (its text in one line, a photo), for the apps to word.
    pub kind: PreviewKind,
    /// When it was sent.
    pub date: SystemTime,
}

/// A room's pinned messages, in the order they were pinned (the newest last), and whether the
/// user may pin and unpin there (`m.room.pinned_events` by the room's power levels).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Pins {
    /// The messages, those the account cannot read left out.
    pub messages: Vec<PinnedMessage>,
    /// The user may pin and unpin.
    pub may_pin: bool,
    /// The pinned events the user has seen (Element's `im.vector.room.read_pins` room account
    /// data, so every client of the account agrees): a pinned one not among them is new.
    pub seen: Vec<EventId>,
}

impl Pins {
    /// The newest pinned message the user has not seen yet.
    #[must_use]
    pub fn newest_unseen(&self) -> Option<&PinnedMessage> {
        self.messages.iter().rev().find(|pin| !self.seen.contains(&pin.event))
    }
}
