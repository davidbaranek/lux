//! Sending to a room through its send queue: text, replies, edits, deletions, reactions,
//! attachments, forwards; the composer's draft, read receipts and typing notices. What goes to a
//! Matrix thread goes through its timeline, which makes it the thread's reply; a message is acted
//! on in the open timeline that shows it.

use std::path::Path;

use lux_core::ids::{ChatId, MessageId, MessageRef, RoomId, TimelineId};
use lux_core::message::SendState;
use lux_core::ports::{BackendError, ChatSending};
use lux_core::timeline::{Draft, OutgoingAttachment, OutgoingKind, Quote, Receipt};
use matrix_sdk::attachment::{AttachmentConfig, AttachmentInfo, BaseFileInfo, BaseImageInfo, BaseVideoInfo, Thumbnail};
use matrix_sdk::Room;
use matrix_sdk::deserialized_responses::TimelineEvent;
use matrix_sdk::room::MessagesOptions;
use matrix_sdk::ruma::OwnedEventId;
use matrix_sdk::serde_helpers::extract_thread_root;
use matrix_sdk::room::edit::EditedContent;
use matrix_sdk::room::reply::Reply;
use matrix_sdk::ruma::api::client::receipt::create_receipt::v3::ReceiptType;
use matrix_sdk::ruma::events::receipt::ReceiptThread;
use matrix_sdk::ruma::events::room::message::{
    RoomMessageEventContent, RoomMessageEventContentWithoutRelation, TextMessageEventContent,
};
use matrix_sdk::ruma::{EventId as SdkEventId, OwnedTransactionId, TransactionId, UInt};
use matrix_sdk::store::{ComposerDraft, ComposerDraftType};
use matrix_sdk_ui::timeline::SendTarget;

use super::MatrixTimelines;
use super::errors::{from_send_queue, from_timeline};
use super::items::{profile_avatar, profile_name, quoted_kind, send_state};
use crate::errors::from_sdk;

impl ChatSending for MatrixTimelines {
    async fn send_text(&self, to: &TimelineId, text: &str, reply: Option<&MessageRef>) -> Result<(), BackendError> {
        let timeline = self.open(to).await?;
        match reply {
            Some(reply) => {
                let event = timeline.event_id(reply).await?;
                timeline
                    .timeline
                    .send_reply(RoomMessageEventContentWithoutRelation::text_markdown(text), event)
                    .await
                    .map_err(from_timeline)?;
            }
            None => {
                timeline
                    .timeline
                    .send(RoomMessageEventContent::text_markdown(text).into())
                    .await
                    .map_err(from_timeline)?;
            }
        }
        // the text went: a relaunch does not offer it again.
        timeline
            .room
            .clear_composer_draft(timeline.thread.as_deref())
            .await
            .map_err(from_sdk)
    }

    async fn edit(&self, room: &RoomId, message: &MessageId, text: &str) -> Result<(), BackendError> {
        let timeline = self.holding(room, message).await?;
        let item = timeline.item(message).await.ok_or(BackendError::UnknownMessage)?;
        if !item.is_editable() {
            return Err(BackendError::NotAllowed);
        }
        timeline
            .timeline
            .edit(
                &item.identifier(),
                EditedContent::RoomMessage(RoomMessageEventContentWithoutRelation::text_markdown(text)),
            )
            .await
            .map_err(from_timeline)
    }

    async fn delete(&self, room: &RoomId, message: &MessageId) -> Result<(), BackendError> {
        let timeline = self.holding(room, message).await?;
        let item = timeline.identifier(message).await?;
        timeline.timeline.redact(&item, None).await.map_err(from_timeline)
    }

    async fn retry(&self, room: &RoomId, message: &MessageId) -> Result<(), BackendError> {
        let timeline = self.holding(room, message).await?;
        let item = timeline.identifier(message).await?;
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
        let timeline = self.holding(room, message).await?;
        let item = timeline.identifier(message).await?;
        timeline
            .timeline
            .abort_send(&item, SendTarget::Event)
            .await
            .map(drop)
            .map_err(from_timeline)
    }

    async fn toggle_reaction(&self, room: &RoomId, message: &MessageId, key: &str) -> Result<(), BackendError> {
        let timeline = self.holding(room, message).await?;
        let item = timeline.identifier(message).await?;
        timeline
            .timeline
            .toggle_reaction(&item, key)
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
    ) -> Result<Option<MessageId>, BackendError> {
        let timeline = self.open(to).await?;
        let reply = match reply {
            Some(reply) => Some(timeline.event_id(reply).await?),
            None => None,
        };
        let (request, transaction) = AttachmentRequest::of(attachment, caption, None).await?;
        // the timeline makes it an answer to `reply`, and a thread's reply in a thread.
        request.send_in(&timeline.timeline, reply).await?;
        Ok(timeline.message_of_transaction(&transaction).await)
    }

    async fn send_state(&self, room: &RoomId, message: &MessageId) -> Result<Option<SendState>, BackendError> {
        let timeline = self.holding(room, message).await?;
        Ok(timeline.item(message).await.map(|item| send_state(&item)))
    }

    async fn forward(&self, room: &RoomId, message: &MessageId, target: &ChatId) -> Result<(), BackendError> {
        let target = target
            .send_room(&self.cuts.borrow().merges)
            .ok_or_else(|| BackendError::UnknownChat(target.clone()))?;
        let timeline = self.holding(room, message).await?;
        let item = timeline.item(message).await.ok_or(BackendError::UnknownMessage)?;
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
            text: draft.plain_text,
            reply,
        }))
    }

    async fn save_draft(&self, of: &TimelineId, text: &str, reply: Option<&MessageRef>) -> Result<(), BackendError> {
        let sdk_room = self.room(&of.room)?;
        let thread = thread_root(of)?;
        let draft_type = match reply {
            Some(reply) => ComposerDraftType::Reply {
                event_id: self.open(of).await?.event_id(reply).await?,
            },
            None if text.is_empty() => {
                return sdk_room.clear_composer_draft(thread.as_deref()).await.map_err(from_sdk);
            }
            None => ComposerDraftType::NewMessage,
        };
        sdk_room
            .save_composer_draft(
                ComposerDraft {
                    plain_text: text.to_owned(),
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
    /// it. Either takes the unread mark away.
    async fn mark_read(&self, of: &TimelineId, receipt: Receipt) -> Result<(), BackendError> {
        let receipt = match receipt {
            Receipt::Public => ReceiptType::Read,
            Receipt::Private => ReceiptType::ReadPrivate,
        };
        if let Some(timeline) = self.opened(of).await {
            return timeline
                .timeline
                .mark_as_read(receipt)
                .await
                .map(drop)
                .map_err(from_sdk);
        }
        let room = self.room(&of.room)?;
        let newest = newest_outside_threads(&room).await?;
        match newest {
            Some(event) => {
                room.send_single_receipt(receipt, ReceiptThread::Unthreaded, event)
                    .await
            }
            None => room.set_unread_flag(false).await,
        }
        .map_err(from_sdk)
    }

    async fn set_typing(&self, room: &RoomId, typing: bool) -> Result<(), BackendError> {
        self.room(room)?.typing_notice(typing).await.map_err(from_sdk)
    }
}

/// The newest event of a room's own timeline, out of its threads: where a receipt for the whole
/// room goes. The SDK counts a room's unread messages outside its threads, and a receipt on a
/// thread's reply (often the room's newest event) is one it cannot place: the room would stay
/// unread. The event cache's newest, else the server's (a room not shown lately has none in
/// memory).
async fn newest_outside_threads(room: &Room) -> Result<Option<OwnedEventId>, BackendError> {
    let outside = |event: &TimelineEvent| {
        extract_thread_root(event.raw()).is_none().then(|| event.event_id().map(ToOwned::to_owned)).flatten()
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

impl MatrixTimelines {
    /// The quote of a message a draft answers: from the timeline, else from the server.
    async fn quote(&self, room: &TimelineId, event: &SdkEventId) -> Quote {
        let mut quote = Quote {
            event_id: lux_core::ids::EventId::from(event.as_str()),
            sender_name: String::new(),
            sender_avatar: None,
            kind: None,
        };
        if let Ok(timeline) = self.open(room).await
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

    /// Puts it in the send queue of `timeline`'s room, as the timeline sends: an answer to
    /// `in_reply_to` if given, a Matrix thread's reply when the timeline is a thread's.
    ///
    /// # Errors
    /// When the queue does not take it.
    pub(crate) async fn send_in(
        self,
        timeline: &matrix_sdk_ui::Timeline,
        in_reply_to: Option<OwnedEventId>,
    ) -> Result<(), BackendError> {
        let config = matrix_sdk_ui::timeline::AttachmentConfig {
            txn_id: self.config.txn_id,
            info: self.config.info,
            thumbnail: self.config.thumbnail,
            caption: self.config.caption,
            mentions: self.config.mentions,
            in_reply_to,
            extra_content: self.config.extra_content,
        };
        timeline
            .send_attachment(
                matrix_sdk_ui::timeline::AttachmentSource::Data {
                    bytes: self.data,
                    filename: self.name,
                },
                self.mimetype,
                config,
            )
            // its local echo shows at once, uploading, as the room's send queue does.
            .use_send_queue()
            .await
            .map(drop)
            .map_err(from_timeline)
    }
}
