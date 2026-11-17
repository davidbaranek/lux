//! A chat's messages, as the apps see them: the records a thread's rows carry (`thread.rs`), and
//! the account's calls beside the thread's view model: opening a chat ahead, the search index's
//! reading, uploads, media.

use std::path::{Path, PathBuf};
use std::time::SystemTime;

use lux_core::ids::{EventId, MediaId, MessageId, MessageRef, RoomId, TimelineId};
use lux_core::message::SendState;
use lux_core::ports::{ChatMedia, ChatSending, ChatTimelines, ThreadBackend};
use lux_core::timeline::{
    FileKind, ImageSource, IndexHistory, IndexedMessage, Media, MessageKind, OutgoingAttachment, OutgoingKind,
    OutgoingThumbnail, Participant, Picture, Quote, StyleKind, ThreadReply, ThreadSummary, TimelineMessage, Typist,
};

use crate::account::{Backend, CoreAccount, CoreAccountError, with_account};
use crate::chat::{CorePreviewKind, path_text, position};
use crate::message::CoreSendState;
use crate::time_span::TimeSpan;

// MARK: records

/// What a message is, besides one to show as it came.
#[derive(uniffi::Enum)]
pub enum CoreMessageKind {
    /// A message.
    Message,
    /// Deleted for everyone.
    Deleted,
    /// Its key has not come.
    Undecryptable,
}

/// A picture of a message.
#[derive(uniffi::Record)]
pub struct CorePicture {
    /// The media's key (its URL).
    pub source: String,
    /// Its width; 0 when not said.
    pub width: u32,
    /// Its height; 0 when not said.
    pub height: u32,
}

/// What kind of file.
#[derive(uniffi::Enum)]
pub enum CoreFileKind {
    /// Any file.
    Document,
    /// A sound file.
    Audio,
    /// A voice message.
    Voice,
}

/// A message's media.
#[derive(uniffi::Enum)]
pub enum CoreMedia {
    /// A photo.
    Photo {
        /// What shows.
        picture: CorePicture,
        /// It moves.
        is_animated: bool,
    },
    /// A video.
    Video {
        /// Its poster.
        poster: Option<CorePicture>,
        /// Its length.
        duration: Option<TimeSpan>,
    },
    /// A file or a sound.
    File {
        /// Its name.
        name: String,
        /// Its size in bytes.
        size: Option<u64>,
        /// Its type; empty when not said.
        mimetype: String,
        /// Which kind.
        kind: CoreFileKind,
        /// A sound's length.
        duration: Option<TimeSpan>,
    },
}

/// How a run of text is formatted.
#[derive(uniffi::Enum)]
pub enum CoreStyleKind {
    /// Bold.
    Bold,
    /// Italic.
    Italic,
    /// Underlined.
    Underline,
    /// Struck through.
    Strikethrough,
    /// Code in a line.
    Code,
    /// A block of code.
    CodeBlock,
    /// A quote.
    Quote,
    /// A link.
    Link {
        /// Where to.
        url: String,
    },
}

/// A run of formatting, in UTF-16 units.
#[derive(uniffi::Record)]
pub struct CoreTextStyle {
    /// How.
    pub kind: CoreStyleKind,
    /// Where it starts.
    pub start: u32,
    /// How long it is.
    pub length: u32,
}

/// A reaction's key and count.
#[derive(uniffi::Record)]
pub struct CoreReaction {
    /// The key.
    pub key: String,
    /// How many.
    pub count: u32,
    /// The account among them.
    pub is_mine: bool,
}

/// The message a reply answers.
#[derive(uniffi::Record)]
pub struct CoreQuote {
    /// Its event.
    pub event_id: String,
    /// Its sender's name; empty until known.
    pub sender_name: String,
    /// Its sender's picture; none without one, or until known.
    pub sender_avatar: Option<String>,
    /// What it is, for the app to word; none until known.
    pub kind: Option<CorePreviewKind>,
}

/// Someone who read up to a message.
#[derive(uniffi::Record)]
pub struct CoreReader {
    /// Who.
    pub user_id: String,
    /// Their name.
    pub name: String,
}

/// One message of a chat (`lux_core::timeline::TimelineMessage`).
#[derive(uniffi::Record)]
pub struct CoreMessage {
    /// Its id in the chat.
    pub id: String,
    /// Its event id once sent.
    pub event_id: Option<String>,
    /// Its sender.
    pub sender_id: String,
    /// Its sender's name.
    pub sender_name: String,
    /// Its sender's picture (a media URL).
    pub sender_avatar: Option<String>,
    /// When it was sent.
    pub date: SystemTime,
    /// The account sent it.
    pub is_own: bool,
    /// It can be edited.
    pub is_editable: bool,
    /// Where it is on its way.
    pub state: CoreSendState,
    /// It was edited.
    pub is_edited: bool,
    /// Its text.
    pub body: String,
    /// Deleted, undecryptable, or a message.
    pub kind: CoreMessageKind,
    /// Its media.
    pub media: Option<CoreMedia>,
    /// Its formatting.
    pub styles: Vec<CoreTextStyle>,
    /// Its reactions.
    pub reactions: Vec<CoreReaction>,
    /// The message it answers.
    pub reply: Option<CoreQuote>,
    /// Who read up to it.
    pub readers: Vec<CoreReader>,
    /// The post it shares from another network, shown as a card.
    pub shared: Option<CoreSharedPost>,
    /// The Matrix thread it starts, summed up (in the chat's own timeline).
    pub thread: Option<CoreThreadSummary>,
}

/// A Matrix thread under its root message: how many replied, the last reply, who took part.
#[derive(uniffi::Record)]
pub struct CoreThreadSummary {
    /// How many replies it has.
    pub replies: u32,
    /// The last reply, once known.
    pub latest: Option<CoreThreadReply>,
    /// Who replied, the last to reply first.
    pub participants: Vec<CoreParticipant>,
    /// How many replies are unread.
    pub unread: u32,
}

/// A Matrix thread's last reply.
#[derive(uniffi::Record)]
pub struct CoreThreadReply {
    /// Its sender.
    pub sender: CoreParticipant,
    /// What it is.
    pub kind: CorePreviewKind,
    /// When it was sent.
    pub date: SystemTime,
}

/// Someone in a Matrix thread.
#[derive(uniffi::Record)]
pub struct CoreParticipant {
    /// Their user id.
    pub user_id: String,
    /// Their name in the room.
    pub name: String,
    /// Their picture (a media URL).
    pub avatar: Option<String>,
}

impl From<Participant> for CoreParticipant {
    fn from(participant: Participant) -> Self {
        Self {
            user_id: participant.user.to_string(),
            name: participant.name,
            avatar: participant.avatar.map(|avatar| avatar.to_string()),
        }
    }
}

impl From<ThreadReply> for CoreThreadReply {
    fn from(reply: ThreadReply) -> Self {
        Self {
            sender: reply.sender.into(),
            kind: reply.kind.into(),
            date: reply.date,
        }
    }
}

impl From<ThreadSummary> for CoreThreadSummary {
    fn from(summary: ThreadSummary) -> Self {
        Self {
            replies: summary.replies,
            latest: summary.latest.map(CoreThreadReply::from),
            participants: summary.participants.into_iter().map(CoreParticipant::from).collect(),
            unread: summary.unread,
        }
    }
}

/// A post shared from another network: its address (for the menu), title and description.
#[derive(uniffi::Record)]
pub struct CoreSharedPost {
    /// Its address.
    pub url: String,
    /// Its title.
    pub title: Option<String>,
    /// Its caption.
    pub description: Option<String>,
}

/// A text message as the search index keeps it.
#[derive(uniffi::Record)]
pub struct CoreIndexedMessage {
    /// Its event.
    pub event_id: String,
    /// Its room.
    pub room_id: String,
    /// Its sender's name.
    pub sender_name: String,
    /// Its text.
    pub body: String,
    /// The web addresses in it.
    pub links: Vec<String>,
    /// The thread it replies in: its root's event id.
    pub thread: Option<String>,
    /// When it was sent.
    pub date: SystemTime,
    /// The account sent it.
    pub is_own: bool,
}

/// A file as the search index keeps it.
#[derive(uniffi::Record)]
pub struct CoreIndexedFile {
    /// Its event.
    pub event_id: String,
    /// Its room.
    pub room_id: String,
    /// Its sender's name.
    pub sender_name: String,
    /// Its name.
    pub name: String,
    /// Its size in bytes, when known.
    pub size: Option<u64>,
    /// Its type, when known.
    pub mimetype: Option<String>,
    /// When it was sent.
    pub date: SystemTime,
    /// The account sent it.
    pub is_own: bool,
}

/// A photo as the search index keeps it.
#[derive(uniffi::Record)]
pub struct CoreIndexedImage {
    /// Its event.
    pub event_id: String,
    /// Its room.
    pub room_id: String,
    /// Its sender's name.
    pub sender_name: String,
    /// The words sent with it; empty when none.
    pub caption: String,
    /// When it was sent.
    pub date: SystemTime,
    /// The account sent it.
    pub is_own: bool,
}

/// A chat's text messages, photos and files back to a date, newest first.
#[derive(uniffi::Record)]
pub struct CoreIndexHistory {
    /// The text messages.
    pub messages: Vec<CoreIndexedMessage>,
    /// The photos.
    pub images: Vec<CoreIndexedImage>,
    /// The files.
    pub files: Vec<CoreIndexedFile>,
    /// Nothing is older.
    pub reached_start: bool,
    /// The read went back to `since`.
    pub reached_since: bool,
    /// Where to read on, older, when the pages ran out first.
    pub older: Option<String>,
    /// The event ids of the messages deleted meanwhile, for the index to forget.
    pub removed: Vec<String>,
    /// The chat was deleted at this point: the index forgets its messages up to it.
    pub deleted_until: Option<SystemTime>,
}

/// Someone typing.
#[derive(uniffi::Record)]
pub struct CoreTypist {
    /// Who.
    pub user_id: String,
    /// Their name.
    pub name: String,
    /// Their picture (a media URL).
    pub avatar: Option<String>,
}

/// What kind of file is sent.
#[derive(uniffi::Enum)]
pub enum CoreOutgoingKind {
    /// A picture.
    Photo {
        /// Its width.
        width: u32,
        /// Its height.
        height: u32,
    },
    /// A video.
    Video {
        /// Its width.
        width: u32,
        /// Its height.
        height: u32,
        /// Its length.
        duration: TimeSpan,
    },
    /// Any file.
    File,
}

/// A picture's smaller copy, to send with it.
#[derive(uniffi::Record)]
pub struct CoreOutgoingThumbnail {
    /// Its path on the device.
    pub file: String,
    /// Its type.
    pub mimetype: String,
    /// Its size in bytes.
    pub size: u64,
    /// Its width.
    pub width: u32,
    /// Its height.
    pub height: u32,
}

/// A photo, video or file to send.
#[derive(uniffi::Record)]
pub struct CoreOutgoingAttachment {
    /// Its path on the device.
    pub file: String,
    /// The name other apps show.
    pub name: String,
    /// Its type.
    pub mimetype: String,
    /// Its size in bytes.
    pub size: u64,
    /// What it is.
    pub kind: CoreOutgoingKind,
    /// Its smaller copy.
    pub thumbnail: Option<CoreOutgoingThumbnail>,
}

/// A picture to load.
#[derive(uniffi::Enum)]
pub enum CoreImageSource {
    /// A room's.
    Room {
        /// The room.
        room_id: String,
    },
    /// A person's, by its media URL.
    Person {
        /// The URL.
        url: String,
    },
    /// A photo message's thumbnail.
    Photo {
        /// Its room.
        room_id: String,
        /// The message.
        message_id: String,
    },
    /// A video message's poster.
    Poster {
        /// Its room.
        room_id: String,
        /// The message.
        message_id: String,
    },
    /// A shared photo's thumbnail or video's poster, by its message's event.
    Shared {
        /// Its room.
        room_id: String,
        /// The message's event.
        event_id: String,
    },
}

// MARK: mappings

pub(crate) fn picture(picture: &Picture) -> CorePicture {
    CorePicture {
        source: picture.source.to_string(),
        width: picture.width,
        height: picture.height,
    }
}

fn quote(quote: Quote) -> CoreQuote {
    CoreQuote {
        event_id: quote.event_id.to_string(),
        sender_name: quote.sender_name,
        sender_avatar: quote.sender_avatar.as_ref().map(ToString::to_string),
        kind: quote.kind.map(CorePreviewKind::from),
    }
}

pub(crate) fn send_state(state: SendState) -> CoreSendState {
    match state {
        SendState::Sending { upload } => CoreSendState::Sending { upload },
        SendState::Sent => CoreSendState::Sent,
        SendState::Failed => CoreSendState::Failed,
    }
}

impl From<&TimelineMessage> for CoreMessage {
    fn from(message: &TimelineMessage) -> Self {
        let core = &message.message;
        Self {
            id: core.id.to_string(),
            event_id: message.event_id.as_ref().map(ToString::to_string),
            sender_id: core.sender.to_string(),
            sender_name: message.sender_name.clone(),
            sender_avatar: message.sender_avatar.as_ref().map(ToString::to_string),
            date: core.date,
            is_own: message.is_own,
            is_editable: message.is_editable,
            state: send_state(core.state),
            is_edited: core.is_edited,
            body: core.body.clone(),
            kind: match message.kind {
                MessageKind::Message => CoreMessageKind::Message,
                MessageKind::Deleted => CoreMessageKind::Deleted,
                MessageKind::Undecryptable => CoreMessageKind::Undecryptable,
            },
            media: message.media.as_ref().map(|media| match media {
                Media::Photo {
                    picture: shown,
                    is_animated,
                } => CoreMedia::Photo {
                    picture: picture(shown),
                    is_animated: *is_animated,
                },
                Media::Video { poster, duration } => CoreMedia::Video {
                    poster: poster.as_ref().map(picture),
                    duration: duration.map(TimeSpan),
                },
                Media::File {
                    name,
                    size,
                    mimetype,
                    kind,
                    duration,
                } => CoreMedia::File {
                    name: name.clone(),
                    size: *size,
                    mimetype: mimetype.clone(),
                    kind: match kind {
                        FileKind::Document => CoreFileKind::Document,
                        FileKind::Audio => CoreFileKind::Audio,
                        FileKind::Voice => CoreFileKind::Voice,
                    },
                    duration: duration.map(TimeSpan),
                },
            }),
            styles: message
                .styles
                .iter()
                .map(|style| CoreTextStyle {
                    kind: match &style.kind {
                        StyleKind::Bold => CoreStyleKind::Bold,
                        StyleKind::Italic => CoreStyleKind::Italic,
                        StyleKind::Underline => CoreStyleKind::Underline,
                        StyleKind::Strikethrough => CoreStyleKind::Strikethrough,
                        StyleKind::Code => CoreStyleKind::Code,
                        StyleKind::CodeBlock => CoreStyleKind::CodeBlock,
                        StyleKind::Quote => CoreStyleKind::Quote,
                        StyleKind::Link(url) => CoreStyleKind::Link { url: url.clone() },
                    },
                    start: position(style.range.start),
                    length: position(style.range.len()),
                })
                .collect(),
            reactions: message
                .reactions
                .iter()
                .map(|reaction| CoreReaction {
                    key: reaction.key.clone(),
                    count: reaction.count,
                    is_mine: reaction.is_mine,
                })
                .collect(),
            reply: message.reply.clone().map(quote),
            readers: message
                .readers
                .iter()
                .map(|reader| CoreReader {
                    user_id: reader.user.to_string(),
                    name: reader.name.clone(),
                })
                .collect(),
            shared: message.shared.clone().map(|post| CoreSharedPost {
                url: post.url,
                title: post.title,
                description: post.description,
            }),
            thread: message.thread.clone().map(CoreThreadSummary::from),
        }
    }
}

impl From<IndexedMessage> for CoreIndexedMessage {
    fn from(message: IndexedMessage) -> Self {
        Self {
            event_id: message.event_id.to_string(),
            room_id: message.room.to_string(),
            sender_name: message.sender_name,
            body: message.body,
            links: message.links,
            thread: message.thread.map(|thread| thread.to_string()),
            date: message.date,
            is_own: message.is_own,
        }
    }
}

impl From<IndexHistory> for CoreIndexHistory {
    fn from(history: IndexHistory) -> Self {
        Self {
            messages: history.messages.into_iter().map(Into::into).collect(),
            images: history
                .images
                .into_iter()
                .map(|image| CoreIndexedImage {
                    event_id: image.event_id.to_string(),
                    room_id: image.room.to_string(),
                    sender_name: image.sender_name,
                    caption: image.caption,
                    date: image.date,
                    is_own: image.is_own,
                })
                .collect(),
            files: history
                .files
                .into_iter()
                .map(|file| CoreIndexedFile {
                    event_id: file.event_id.to_string(),
                    room_id: file.room.to_string(),
                    sender_name: file.sender_name,
                    name: file.name,
                    size: file.size,
                    mimetype: file.mimetype,
                    date: file.date,
                    is_own: file.is_own,
                })
                .collect(),
            reached_start: history.reached_start,
            reached_since: history.reached_since,
            older: history.older,
            removed: history.removed.iter().map(ToString::to_string).collect(),
            deleted_until: history.deleted_until,
        }
    }
}

impl From<Typist> for CoreTypist {
    fn from(typist: Typist) -> Self {
        Self {
            user_id: typist.user.to_string(),
            name: typist.name,
            avatar: typist.avatar.map(|avatar| avatar.to_string()),
        }
    }
}

impl From<CoreOutgoingAttachment> for OutgoingAttachment {
    fn from(attachment: CoreOutgoingAttachment) -> Self {
        Self {
            file: PathBuf::from(attachment.file),
            name: attachment.name,
            mimetype: attachment.mimetype,
            size: attachment.size,
            kind: match attachment.kind {
                CoreOutgoingKind::Photo { width, height } => OutgoingKind::Photo { width, height },
                CoreOutgoingKind::Video {
                    width,
                    height,
                    duration,
                } => OutgoingKind::Video {
                    width,
                    height,
                    duration: duration.into(),
                },
                CoreOutgoingKind::File => OutgoingKind::File,
            },
            thumbnail: attachment.thumbnail.map(|thumbnail| OutgoingThumbnail {
                file: PathBuf::from(thumbnail.file),
                mimetype: thumbnail.mimetype,
                size: thumbnail.size,
                width: thumbnail.width,
                height: thumbnail.height,
            }),
        }
    }
}

impl From<CoreImageSource> for ImageSource {
    fn from(image: CoreImageSource) -> Self {
        match image {
            CoreImageSource::Room { room_id } => Self::Room(room_id.into()),
            CoreImageSource::Person { url } => Self::Person(MediaId::from(url)),
            CoreImageSource::Photo { room_id, message_id } => Self::Photo {
                room: room_id.into(),
                message: message_id.into(),
            },
            CoreImageSource::Poster { room_id, message_id } => Self::Poster {
                room: room_id.into(),
                message: message_id.into(),
            },
            CoreImageSource::Shared { room_id, event_id } => Self::Shared {
                room: room_id.into(),
                event: EventId::from(event_id),
            },
        }
    }
}

// MARK: the account's chats

/// The timeline of `room_id`: the Matrix thread of `thread_root`, if given.
pub(crate) fn timeline_id(room_id: String, thread_root: Option<String>) -> TimelineId {
    TimelineId {
        room: RoomId::from(room_id),
        thread: thread_root.map(EventId::from),
        at: None,
    }
}

#[uniffi::export(async_runtime = "tokio")]
impl CoreAccount {
    /// Opens the chat's timeline ahead of time (the Matrix thread of `thread_root` in it, if
    /// given).
    ///
    /// # Errors
    /// When the chat is not the account's.
    pub async fn prefetch_thread(&self, room_id: String, thread_root: Option<String>) -> Result<(), CoreAccountError> {
        let timeline = timeline_id(room_id, thread_root);
        Ok(with_account!(self.backend(), account => account.timelines().prefetch(&timeline).await)?)
    }

    /// The chat's text messages and photos back to `since`, for the search index.
    ///
    /// # Errors
    /// When the server cannot be reached.
    pub async fn index_history(
        &self,
        room_id: String,
        since: SystemTime,
        from: Option<String>,
        max_pages: u32,
    ) -> Result<CoreIndexHistory, CoreAccountError> {
        let room = RoomId::from(room_id);
        let history = with_account!(self.backend(), account => {
            account.timelines().index_history(&room, since, from, max_pages).await
        })?;
        Ok(history.into())
    }

    /// Queues a photo, video or file (in the Matrix thread of `thread_root`, if given); its
    /// message's id once the chat shows it.
    ///
    /// # Errors
    /// When the file cannot be read, or the queue refuses it.
    pub async fn send_attachment(
        &self,
        room_id: String,
        thread_root: Option<String>,
        attachment: CoreOutgoingAttachment,
        caption: Option<String>,
        reply_to: Option<String>,
    ) -> Result<Option<String>, CoreAccountError> {
        let (timeline, attachment, reply) = (
            timeline_id(room_id, thread_root),
            attachment.into(),
            reply_to.map(MessageRef::from),
        );
        let sent = with_account!(self.backend(), account => {
            account.timelines().send_attachment(&timeline, &attachment, caption.as_deref(), reply.as_ref()).await
        })?;
        Ok(sent.map(|id| id.to_string()))
    }

    /// Where a message being sent is; none once the chat no longer has it.
    ///
    /// # Errors
    /// When the chat is not the account's.
    pub async fn send_state(
        &self,
        room_id: String,
        message_id: String,
    ) -> Result<Option<CoreSendState>, CoreAccountError> {
        let (room, message) = (RoomId::from(room_id), MessageId::from(message_id));
        let state = with_account!(self.backend(), account => account.timelines().send_state(&room, &message).await)?;
        Ok(state.map(send_state))
    }

    /// The file of a picture, loaded once into `folder`; none when there is none (the demo's
    /// pictures are the app's to draw).
    ///
    /// # Errors
    /// When it cannot be loaded or written.
    pub async fn image_file(&self, image: CoreImageSource, folder: String) -> Result<Option<String>, CoreAccountError> {
        let Backend::Matrix(account) = self.backend() else {
            return Ok(None);
        };
        let file = account
            .timelines()
            .image_file(&image.into(), Path::new(&folder))
            .await?;
        Ok(file.map(|file| path_text(&file)))
    }

    /// A message's original file, loaded once into `folder`.
    ///
    /// # Errors
    /// When it has none, or it cannot be loaded or written.
    pub async fn media_file(
        &self,
        room_id: String,
        message_id: String,
        folder: String,
    ) -> Result<String, CoreAccountError> {
        let account = self.matrix_account()?;
        // the download's future is large: on the heap.
        let file = Box::pin(account.timelines().media_file(
            &RoomId::from(room_id),
            &MessageId::from(message_id),
            Path::new(&folder),
        ))
        .await?;
        Ok(path_text(&file))
    }

    /// The largest file the server takes, in bytes.
    ///
    /// # Errors
    /// When the server cannot be reached.
    pub async fn max_upload_size(&self) -> Result<u64, CoreAccountError> {
        Ok(self.matrix_account()?.timelines().max_upload_size().await?)
    }
}
