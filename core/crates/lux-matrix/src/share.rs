//! What the user shares from another app, sent from the share extension: the kept session opened
//! from the shared folder without its sync, as [`Process::ShareExtension`], and the message put in
//! the room's send queue.
//!
//! The queue keeps a request in the store until it is sent: what the extension could not send
//! before the system ended it goes out when the app opens next (its queue takes up what a
//! process left unsent).

use std::collections::HashSet;
use std::sync::Arc;
use std::time::Duration;

use lux_core::ids::{ChatId, MediaId, RoomId};
use lux_core::ports::{BackendError, SecretStore};
use lux_core::timeline::OutgoingAttachment;
use matrix_sdk::Client;
use matrix_sdk::ruma::OwnedTransactionId;
use matrix_sdk::ruma::RoomId as SdkRoomId;
use matrix_sdk::ruma::events::room::message::RoomMessageEventContent;
use matrix_sdk::send_queue::RoomSendQueueUpdate;
use tokio::sync::broadcast::error::RecvError;

use crate::sign_in::restored_client;
use crate::store::{Process, StoreFolder};
use crate::timeline::errors::from_send_queue;
use crate::timeline::media;
use crate::timeline::send::AttachmentRequest;

/// How long a picture the cache does not have may take to come from the server.
const PICTURE_TIME: Duration = Duration::from_secs(3);

/// The account, opened to send what the user shares.
pub struct MatrixShare {
    client: Client,
}

impl MatrixShare {
    /// Opens the session kept in `secrets` over `folder`, as the share extension; `None` when no
    /// session is kept.
    ///
    /// # Errors
    /// When the folder does not hold the session's device, or the store cannot be opened.
    pub async fn open(folder: &StoreFolder, secrets: Arc<dyn SecretStore>) -> Result<Option<Self>, BackendError> {
        Ok(restored_client(folder, &secrets, Process::ShareExtension)
            .await?
            .map(|client| Self { client }))
    }

    /// Sends `attachments` and `text` to `room`, and returns once the server has them all. One
    /// attachment carries the text as its caption; with several, or none, the text goes first
    /// as a message of its own.
    ///
    /// # Errors
    /// When the room is not the account's, a file cannot be read, or the server refuses one of
    /// them (what was sent stays sent).
    pub async fn send(
        &self,
        room: &RoomId,
        text: &str,
        attachments: &[OutgoingAttachment],
    ) -> Result<(), BackendError> {
        let unknown = || BackendError::UnknownChat(ChatId::Room(room.clone()));
        let room_id = <&SdkRoomId>::try_from(room.as_str()).map_err(|_| unknown())?;
        let room = self.client.get_room(room_id).ok_or_else(unknown)?;
        let queue = room.send_queue();
        // a failure the app saw may have left the queue off.
        queue.set_enabled(true);
        let (_, mut updates) = queue.subscribe().await.map_err(from_send_queue)?;
        let text = text.trim();
        let caption = (attachments.len() == 1 && !text.is_empty()).then_some(text);
        let mut waiting: HashSet<OwnedTransactionId> = HashSet::new();
        if caption.is_none() && !text.is_empty() {
            let handle = queue
                .send(RoomMessageEventContent::text_markdown(text).into())
                .await
                .map_err(from_send_queue)?;
            waiting.insert(handle.transaction_id().to_owned());
        }
        for attachment in attachments {
            let (request, transaction) = AttachmentRequest::of(attachment, caption, None).await?;
            request.send(&room).await?;
            waiting.insert(transaction);
        }
        while !waiting.is_empty() {
            match updates.recv().await {
                Ok(RoomSendQueueUpdate::SentEvent { transaction_id, .. }) => {
                    waiting.remove(&transaction_id);
                }
                Ok(RoomSendQueueUpdate::SendError {
                    transaction_id, error, ..
                }) if waiting.contains(&transaction_id) => {
                    return Err(BackendError::refused(error));
                }
                Ok(_) | Err(RecvError::Lagged(_)) => {}
                Err(RecvError::Closed) => return Err(BackendError::refused("the send queue closed")),
            }
        }
        Ok(())
    }

    /// A chat's or a person's picture at `media`, as image file bytes: from the media cache, else
    /// from the server within a short time.
    pub async fn picture(&self, media: &MediaId) -> Option<Vec<u8>> {
        media::avatar_bytes(&self.client, Some(media), PICTURE_TIME).await
    }
}
