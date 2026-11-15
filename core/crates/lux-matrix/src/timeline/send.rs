//! Sending to a room through its send queue: text, replies, edits, deletions, reactions,
//! attachments, forwards; the composer's draft, read receipts and typing notices.

use std::path::Path;

use lux_core::ids::{ChatId, MessageId, MessageRef, RoomId};
use lux_core::message::SendState;
use lux_core::ports::{BackendError, ChatSending};
use lux_core::timeline::{Draft, OutgoingAttachment, OutgoingKind, Quote, Receipt};
use matrix_sdk::attachment::{AttachmentConfig, AttachmentInfo, BaseFileInfo, BaseImageInfo, BaseVideoInfo, Thumbnail};
use matrix_sdk::room::edit::EditedContent;
use matrix_sdk::room::reply::{EnforceThread, Reply};
use matrix_sdk::ruma::api::client::receipt::create_receipt::v3::ReceiptType;
use matrix_sdk::ruma::events::receipt::ReceiptThread;
use matrix_sdk::ruma::events::room::message::{
    AddMentions, RoomMessageEventContent, RoomMessageEventContentWithoutRelation, TextMessageEventContent,
};
use matrix_sdk::ruma::{EventId as SdkEventId, OwnedTransactionId, TransactionId, UInt};
use matrix_sdk::store::{ComposerDraft, ComposerDraftType};
use matrix_sdk_ui::timeline::SendTarget;

use super::MatrixTimelines;
use super::errors::{from_send_queue, from_timeline};
use super::items::{profile_avatar, profile_name, quoted_kind, send_state};
use crate::errors::from_sdk;

impl ChatSending for MatrixTimelines {
    async fn send_text(&self, room: &RoomId, text: &str, reply: Option<&MessageRef>) -> Result<(), BackendError> {
        let timeline = self.open(room).await?;
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
        timeline.room.clear_composer_draft(None).await.map_err(from_sdk)
    }

    async fn edit(&self, room: &RoomId, message: &MessageId, text: &str) -> Result<(), BackendError> {
        let timeline = self.open(room).await?;
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
        let timeline = self.open(room).await?;
        let item = timeline.identifier(message).await?;
        timeline.timeline.redact(&item, None).await.map_err(from_timeline)
    }

    async fn retry(&self, room: &RoomId, message: &MessageId) -> Result<(), BackendError> {
        let timeline = self.open(room).await?;
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
        let timeline = self.open(room).await?;
        let item = timeline.identifier(message).await?;
        timeline
            .timeline
            .abort_send(&item, SendTarget::Event)
            .await
            .map(drop)
            .map_err(from_timeline)
    }

    async fn toggle_reaction(&self, room: &RoomId, message: &MessageId, key: &str) -> Result<(), BackendError> {
        let timeline = self.open(room).await?;
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
        room: &RoomId,
        attachment: &OutgoingAttachment,
        caption: Option<&str>,
        reply: Option<&MessageRef>,
    ) -> Result<Option<MessageId>, BackendError> {
        let timeline = self.open(room).await?;
        let reply = match reply {
            Some(reply) => Some(Reply {
                event_id: timeline.event_id(reply).await?,
                enforce_thread: EnforceThread::MaybeThreaded,
                add_mentions: AddMentions::Yes,
            }),
            None => None,
        };
        let (request, transaction) = AttachmentRequest::of(attachment, caption, reply).await?;
        request.send(&timeline.room).await?;
        Ok(timeline.message_of_transaction(&transaction).await)
    }

    async fn send_state(&self, room: &RoomId, message: &MessageId) -> Result<Option<SendState>, BackendError> {
        let timeline = self.open(room).await?;
        Ok(timeline.item(message).await.map(|item| send_state(&item)))
    }

    async fn forward(&self, room: &RoomId, message: &MessageId, target: &ChatId) -> Result<(), BackendError> {
        let target = target
            .send_room(&self.cuts.borrow().merges)
            .ok_or_else(|| BackendError::UnknownChat(target.clone()))?;
        let timeline = self.open(room).await?;
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

    async fn draft(&self, room: &RoomId) -> Result<Option<Draft>, BackendError> {
        let sdk_room = self.room(room)?;
        let Some(draft) = sdk_room.load_composer_draft(None).await.map_err(from_sdk)? else {
            return Ok(None);
        };
        let reply = match draft.draft_type {
            ComposerDraftType::Reply { event_id } => Some(self.quote(room, &event_id).await),
            ComposerDraftType::NewMessage | ComposerDraftType::Edit { .. } => None,
        };
        Ok(Some(Draft {
            text: draft.plain_text,
            reply,
        }))
    }

    async fn save_draft(&self, room: &RoomId, text: &str, reply: Option<&MessageRef>) -> Result<(), BackendError> {
        let sdk_room = self.room(room)?;
        let draft_type = match reply {
            Some(reply) => ComposerDraftType::Reply {
                event_id: self.open(room).await?.event_id(reply).await?,
            },
            None if text.is_empty() => return sdk_room.clear_composer_draft(None).await.map_err(from_sdk),
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
                None,
            )
            .await
            .map_err(from_sdk)
    }

    /// The one receipt path, for an open chat and for the chat list's "read" alike: an open
    /// timeline knows its newest message best; a chat not open reads up to the room's newest event,
    /// without opening its timeline. Either takes the unread mark away.
    async fn mark_read(&self, room: &RoomId, receipt: Receipt) -> Result<(), BackendError> {
        let receipt = match receipt {
            Receipt::Public => ReceiptType::Read,
            Receipt::Private => ReceiptType::ReadPrivate,
        };
        if let Some(timeline) = self.opened(room).await {
            return timeline
                .timeline
                .mark_as_read(receipt)
                .await
                .map(drop)
                .map_err(from_sdk);
        }
        let room = self.room(room)?;
        match room.latest_event().event_id() {
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

impl MatrixTimelines {
    /// The quote of a message a draft answers: from the timeline, else from the server.
    async fn quote(&self, room: &RoomId, event: &SdkEventId) -> Quote {
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
    pub(crate) async fn send(self, room: &matrix_sdk::Room) -> Result<(), BackendError> {
        room.send_queue()
            .send_attachment(self.name, self.mimetype, self.data, self.config)
            .await
            .map(drop)
            .map_err(from_send_queue)
    }
}
