//! Sending to a room through its send queue: text, replies, edits, deletions, reactions,
//! attachments, forwards; the composer's draft, read receipts and typing notices. Texts and
//! attachments go through the room's send queue, as the SDK's timeline sends them (a thread's as
//! its replies): they go on once the chat closes, and the open timelines show their local echoes.
//! A message is acted on in the open timeline that shows it, by the SDK's id its own id names.
//! None of it opens a timeline.

use std::path::Path;

use lux_core::ids::{ChatId, MessageId, MessageRef, RoomId, TimelineId};
use lux_core::mention::ComposedText;
use lux_core::ports::{BackendError, ChatSending, UploadStream};
use lux_core::timeline::{Draft, OutgoingAttachment, OutgoingKind, Quote, Receipt};
use matrix_sdk::Room;
use matrix_sdk::attachment::{AttachmentConfig, AttachmentInfo, BaseFileInfo, BaseImageInfo, BaseVideoInfo, Thumbnail};
use matrix_sdk::deserialized_responses::TimelineEvent;
use matrix_sdk::room::MessagesOptions;
use matrix_sdk::room::edit::EditedContent;
use matrix_sdk::room::reply::{EnforceThread, Reply, ReplyError};
use matrix_sdk::ruma::OwnedEventId;
use matrix_sdk::ruma::api::client::receipt::create_receipt::v3::ReceiptType;
use matrix_sdk::ruma::events::Mentions;
use matrix_sdk::ruma::events::receipt::ReceiptThread;
use matrix_sdk::ruma::events::room::message::{
    AddMentions, FormattedBody, ReplyWithinThread, RoomMessageEventContent, RoomMessageEventContentWithoutRelation,
    TextMessageEventContent,
};
use matrix_sdk::ruma::{
    EventId as SdkEventId, OwnedTransactionId, OwnedUserId, TransactionId, UInt, UserId as SdkUserId,
};
use matrix_sdk::serde_helpers::extract_thread_root;
use matrix_sdk::store::{ComposerDraft, ComposerDraftType};
use matrix_sdk_ui::timeline::{SendTarget, TimelineEventItemId};

use super::MatrixTimelines;
use super::errors::{from_send_queue, from_timeline};
use super::items::{item_id, profile_avatar, profile_name, quoted_kind};
use super::upload;
use crate::errors::from_sdk;

impl ChatSending for MatrixTimelines {
    async fn send_text(
        &self,
        to: &TimelineId,
        text: &ComposedText,
        reply: Option<&MessageRef>,
    ) -> Result<(), BackendError> {
        let room = self.room(&to.room)?;
        let thread = thread_root(to)?;
        let message = text_content(text, room.own_user_id());
        // a reply mentions the sender it answers too (the sdk's `AddMentions`), never the account.
        let content = match self.reply(to, thread.clone(), reply).await? {
            Some(reply) => room.make_reply_event(message, reply).await.map_err(from_reply)?,
            None => message.with_relation(None),
        };
        room.send_queue().send(content.into()).await.map_err(from_send_queue)?;
        // the text went: a relaunch does not offer it again.
        room.clear_composer_draft(thread.as_deref()).await.map_err(from_sdk)
    }

    /// The sdk's edit keeps the spec's rule for mentions: the new content mentions everyone its
    /// pills name, the edit itself notifies only those the message did not mention before.
    async fn edit(&self, room: &RoomId, message: &MessageId, text: &ComposedText) -> Result<(), BackendError> {
        let (timeline, item) = self.holding(room, message).await?;
        if !item.is_editable() {
            return Err(BackendError::NotAllowed);
        }
        let content = text_content(text, timeline.room.own_user_id());
        timeline
            .timeline
            .edit(&item.identifier(), EditedContent::RoomMessage(content))
            .await
            .map_err(from_timeline)
    }

    async fn delete(&self, room: &RoomId, message: &MessageId) -> Result<(), BackendError> {
        let (timeline, item) = self.holding(room, message).await?;
        timeline
            .timeline
            .redact(&item.identifier(), None)
            .await
            .map_err(from_timeline)
    }

    async fn retry(&self, room: &RoomId, message: &MessageId) -> Result<(), BackendError> {
        let (timeline, item) = self.holding(room, message).await?;
        let item = item.identifier();
        // a passing failure turned the room's queue off: unwedging alone would leave it waiting.
        timeline.room.send_queue().set_enabled(true);
        timeline
            .timeline
            .retry_send(&item, SendTarget::Event)
            .await
            .map(drop)
            .map_err(from_timeline)
    }

    async fn discard(&self, room: &RoomId, message: &MessageId) -> Result<(), BackendError> {
        let (timeline, item) = self.holding(room, message).await?;
        timeline
            .timeline
            .abort_send(&item.identifier(), SendTarget::Event)
            .await
            .map(drop)
            .map_err(from_timeline)
    }

    async fn toggle_reaction(&self, room: &RoomId, message: &MessageId, key: &str) -> Result<(), BackendError> {
        let (timeline, item) = self.holding(room, message).await?;
        timeline
            .timeline
            .toggle_reaction(&item.identifier(), key)
            .await
            .map(drop)
            .map_err(from_timeline)
    }

    async fn send_attachment(
        &self,
        to: &TimelineId,
        attachment: &OutgoingAttachment,
        caption: Option<&str>,
        reply: Option<&MessageRef>,
    ) -> Result<UploadStream, BackendError> {
        let room = self.room(&to.room)?;
        let reply = self.reply(to, thread_root(to)?, reply).await?;
        let (request, transaction) = AttachmentRequest::of(attachment, caption, reply).await?;
        // followed from before it is queued: none of its updates goes by unseen.
        let queue = room.send_queue();
        let (_, updates) = queue.subscribe().await.map_err(from_send_queue)?;
        request.send(&room).await?;
        Ok(upload::states(queue, transaction, updates))
    }

    async fn forward(&self, room: &RoomId, message: &MessageId, target: &ChatId) -> Result<(), BackendError> {
        let target = target
            .send_room(&self.cuts.borrow().merges)
            .ok_or_else(|| BackendError::UnknownChat(target.clone()))?;
        let (_, item) = self.holding(room, message).await?;
        // the message alone: no reply, no edit, no thread; its media keep their uploads.
        let content = item
            .content()
            .as_message()
            .map(|message| RoomMessageEventContent::new(message.msgtype().clone()))
            .ok_or(BackendError::NotAllowed)?;
        self.room(&target)?
            .send_queue()
            .send(content.into())
            .await
            .map(drop)
            .map_err(from_send_queue)
    }

    async fn draft(&self, of: &TimelineId) -> Result<Option<Draft>, BackendError> {
        let sdk_room = self.room(&of.room)?;
        let thread = thread_root(of)?;
        let Some(draft) = sdk_room
            .load_composer_draft(thread.as_deref())
            .await
            .map_err(from_sdk)?
        else {
            return Ok(None);
        };
        let reply = match draft.draft_type {
            ComposerDraftType::Reply { event_id } => Some(self.quote(of, &event_id).await),
            ComposerDraftType::NewMessage | ComposerDraftType::Edit { .. } => None,
        };
        Ok(Some(Draft {
            text: ComposedText::from_draft(&draft.plain_text),
            reply,
        }))
    }

    async fn save_draft(
        &self,
        of: &TimelineId,
        text: &ComposedText,
        reply: Option<&MessageRef>,
    ) -> Result<(), BackendError> {
        let sdk_room = self.room(&of.room)?;
        let thread = thread_root(of)?;
        let draft_type = match reply {
            Some(MessageRef::Event(event)) => ComposerDraftType::Reply {
                event_id: OwnedEventId::try_from(event.as_str()).map_err(|_| BackendError::UnknownMessage)?,
            },
            // a message on its way has no event yet unless its timeline knows it.
            Some(reply) => ComposerDraftType::Reply {
                event_id: self.held(of).await?.event_id(reply).await?,
            },
            None if text.text.is_empty() => {
                return sdk_room.clear_composer_draft(thread.as_deref()).await.map_err(from_sdk);
            }
            None => ComposerDraftType::NewMessage,
        };
        sdk_room
            .save_composer_draft(
                // its pills as their links, read back into pills (`ComposedText::from_draft`).
                ComposerDraft {
                    plain_text: text.draft_text(),
                    html_text: None,
                    draft_type,
                    attachments: Vec::new(),
                },
                thread.as_deref(),
            )
            .await
            .map_err(from_sdk)
    }

    /// The one receipt path, for an open chat and for the chat list's "read" alike: an open
    /// timeline knows its newest message best (and a thread's receipt is the thread's, the room's
    /// own the main thread's: reading one leaves the other unread); a chat not open reads up to the
    /// newest event of the room's own timeline, without opening it, its threads up to there with
    /// it. Either takes the user's unread mark away.
    async fn mark_read(&self, of: &TimelineId, receipt: Receipt) -> Result<(), BackendError> {
        let receipt = match receipt {
            Receipt::Public => ReceiptType::Read,
            Receipt::Private => ReceiptType::ReadPrivate,
        };
        let room = self.room(&of.room)?;
        if let Some(timeline) = self.opened(of).await {
            timeline.timeline.mark_as_read(receipt).await.map_err(from_sdk)?;
        } else if let Some(event) = newest_outside_threads(&room).await? {
            room.send_single_receipt(receipt, ReceiptThread::Unthreaded, event)
                .await
                .map_err(from_sdk)?;
        }
        // read is read: the user's own unread mark goes too. The SDK takes it away only with an
        // unthreaded receipt, and with threads on an open timeline's receipt is the main
        // thread's: a chat marked unread would stay so however it is read.
        room.set_unread_flag(false).await.map_err(from_sdk)
    }

    async fn set_typing(&self, room: &RoomId, typing: bool) -> Result<(), BackendError> {
        self.room(room)?.typing_notice(typing).await.map_err(from_sdk)
    }
}

/// A text message as the spec writes one with mentions: the plain body has the pills' names, the
/// HTML body (from the Markdown, as ruma's `text_markdown` reads it) a `matrix.to` link for each
/// member, and `m.mentions` those members and the room, never the account. `m.mentions` is always
/// there: a message without it falls back to the legacy push rules, which notify anyone whose name
/// it holds.
pub(crate) fn text_content(text: &ComposedText, own: &SdkUserId) -> RoomMessageEventContentWithoutRelation {
    let outgoing = text.outgoing();
    let content = match FormattedBody::markdown(&outgoing.markdown) {
        Some(html) => RoomMessageEventContentWithoutRelation::text_html(outgoing.body, html.body),
        None => RoomMessageEventContentWithoutRelation::text_plain(outgoing.body),
    };
    let mut mentions = Mentions::with_user_ids(
        outgoing
            .users
            .iter()
            .filter_map(|user| OwnedUserId::try_from(user.as_str()).ok())
            .filter(|user| user != own),
    );
    mentions.room = outgoing.room;
    content.add_mentions(mentions)
}

/// The newest event of a room's own timeline, out of its threads: where a receipt for the whole
/// room goes. The SDK counts a room's unread messages outside its threads, and a receipt on a
/// thread's reply (often the room's newest event) is one it cannot place: the room would stay
/// unread. The event cache's newest, else the server's (a room not shown lately has none in
/// memory).
async fn newest_outside_threads(room: &Room) -> Result<Option<OwnedEventId>, BackendError> {
    let outside = |event: &TimelineEvent| {
        extract_thread_root(event.raw())
            .is_none()
            .then(|| event.event_id().map(ToOwned::to_owned))
            .flatten()
    };
    if let Some(cache) = room.client().event_cache()
        && let Ok((events, _handles)) = cache.room(room.room_id()).await
        && let Ok(Some(newest)) = events.rfind_map_event_in_memory_by(outside).await
    {
        return Ok(Some(newest));
    }
    let mut options = MessagesOptions::backward();
    options.limit = UInt::from(PAGE_FOR_RECEIPT);
    let page = room.messages(options).await.map_err(from_sdk)?;
    Ok(page.chunk.iter().find_map(outside))
}

/// How many of a room's newest events are asked for to find one out of its threads.
const PAGE_FOR_RECEIPT: u32 = 20;

/// The SDK's id of the Matrix thread a timeline is, if it is one.
fn thread_root(timeline: &TimelineId) -> Result<Option<OwnedEventId>, BackendError> {
    timeline
        .thread
        .as_ref()
        .map(|root| SdkEventId::parse(root.as_str()).map_err(|_| BackendError::UnknownMessage))
        .transpose()
}

/// A reply the SDK could not make: the message it answers is not to be had.
fn from_reply(error: ReplyError) -> BackendError {
    match error {
        ReplyError::Fetch(error) => from_sdk(*error),
        ReplyError::Deserialization | ReplyError::StateEvent => BackendError::NotAllowed,
    }
}

impl MatrixTimelines {
    /// What a message sent to `to` answers, as the room's send queue takes it (its local echo
    /// shows in the open timelines that show it): `reply`, within the thread in a thread; else in
    /// a thread its root, as the thread's own timeline sends.
    async fn reply(
        &self,
        to: &TimelineId,
        thread: Option<OwnedEventId>,
        reply: Option<&MessageRef>,
    ) -> Result<Option<Reply>, BackendError> {
        let reply = match reply {
            Some(MessageRef::Event(event)) => {
                Some(OwnedEventId::try_from(event.as_str()).map_err(|_| BackendError::UnknownMessage)?)
            }
            Some(MessageRef::Local(id)) => match item_id(id)? {
                TimelineEventItemId::EventId(event) => Some(event),
                // the account's message on its way: its event once sent, which its timeline knows.
                TimelineEventItemId::TransactionId(_) => {
                    Some(self.held(to).await?.event_id(&MessageRef::Local(id.clone())).await?)
                }
            },
            None => None,
        };
        Ok(match (reply, thread) {
            (Some(event_id), thread) => Some(Reply {
                event_id,
                enforce_thread: match thread {
                    Some(_) => EnforceThread::Threaded(ReplyWithinThread::Yes),
                    None => EnforceThread::MaybeThreaded,
                },
                add_mentions: AddMentions::Yes,
            }),
            (None, Some(root)) => Some(Reply {
                event_id: root,
                enforce_thread: EnforceThread::Threaded(ReplyWithinThread::No),
                add_mentions: AddMentions::Yes,
            }),
            (None, None) => None,
        })
    }

    /// The quote of a message a draft answers: from the timeline, else from the server.
    async fn quote(&self, room: &TimelineId, event: &SdkEventId) -> Quote {
        let mut quote = Quote {
            event_id: lux_core::ids::EventId::from(event.as_str()),
            sender_name: String::new(),
            sender_avatar: None,
            kind: None,
        };
        if let Some(timeline) = self.opened(room).await
            && let Some(item) = timeline.timeline.item_by_event_id(event).await
        {
            quote.sender_name = profile_name(item.sender_profile(), item.sender().localpart());
            quote.sender_avatar = profile_avatar(item.sender_profile());
            quote.kind = Some(quoted_kind(item.content()));
        }
        quote
    }
}

/// A file's bytes, read off the async threads.
async fn read(file: &Path) -> Result<Vec<u8>, BackendError> {
    let file = file.to_owned();
    tokio::task::spawn_blocking(move || std::fs::read(file))
        .await
        .map_err(BackendError::file)?
        .map_err(BackendError::file)
}

/// An attachment as the send queue takes it: the file's bytes, its kind and sizes, its thumbnail
/// and caption, under a transaction id of its own.
pub(crate) struct AttachmentRequest {
    name: String,
    mimetype: mime::Mime,
    data: Vec<u8>,
    config: AttachmentConfig,
}

impl AttachmentRequest {
    /// The request for `attachment` (its files read), with its transaction id.
    ///
    /// # Errors
    /// When a file cannot be read.
    pub(crate) async fn of(
        attachment: &OutgoingAttachment,
        caption: Option<&str>,
        reply: Option<Reply>,
    ) -> Result<(Self, OwnedTransactionId), BackendError> {
        let mimetype: mime::Mime = attachment.mimetype.parse().unwrap_or(mime::APPLICATION_OCTET_STREAM);
        let data = read(&attachment.file).await?;
        let thumbnail = match &attachment.thumbnail {
            Some(thumbnail) => Some(Thumbnail {
                data: read(&thumbnail.file).await?,
                content_type: thumbnail.mimetype.parse().unwrap_or(mime::IMAGE_JPEG),
                height: UInt::from(thumbnail.height),
                width: UInt::from(thumbnail.width),
                size: UInt::try_from(thumbnail.size).unwrap_or(UInt::MAX),
            }),
            None => None,
        };
        let size = Some(UInt::try_from(attachment.size).unwrap_or(UInt::MAX));
        let info = match attachment.kind {
            OutgoingKind::Photo { width, height } => AttachmentInfo::Image(BaseImageInfo {
                width: Some(width.into()),
                height: Some(height.into()),
                size,
                ..BaseImageInfo::default()
            }),
            OutgoingKind::Video {
                width,
                height,
                duration,
            } => AttachmentInfo::Video(BaseVideoInfo {
                duration: Some(duration),
                width: Some(width.into()),
                height: Some(height.into()),
                size,
                ..BaseVideoInfo::default()
            }),
            OutgoingKind::File => AttachmentInfo::File(BaseFileInfo { size }),
        };
        let transaction = TransactionId::new();
        let config = AttachmentConfig {
            txn_id: Some(transaction.clone()),
            info: Some(info),
            thumbnail,
            caption: caption
                .filter(|caption| !caption.is_empty())
                .map(TextMessageEventContent::markdown),
            mentions: None,
            extra_content: None,
            reply,
        };
        let request = Self {
            name: attachment.name.clone(),
            mimetype,
            data,
            config,
        };
        Ok((request, transaction))
    }

    /// Puts it in `room`'s send queue.
    ///
    /// # Errors
    /// When the queue does not take it.
    pub(crate) async fn send(self, room: &Room) -> Result<(), BackendError> {
        room.send_queue()
            .send_attachment(self.name, self.mimetype, self.data, self.config)
            .await
            .map(drop)
            .map_err(from_send_queue)
    }
}
