//! Messages the server sends later: delayed events (MSC4140). The server holds the message and
//! sends it at its time, the phone off or not; it cannot be end-to-end encrypted, so an
//! encrypted room has none.

use std::time::{Duration, SystemTime};

use lux_core::chat::ScheduledMessage;
use lux_core::ids::{EventId, RoomId, ScheduledId};
use lux_core::ports::{BackendError, Scheduling};
use matrix_sdk::HttpError;
use matrix_sdk::ruma::api::client::delayed_events::update_delayed_event::{UpdateAction, unstable_v2 as update};
use matrix_sdk::ruma::api::client::delayed_events::{DelayParameters, delayed_message_event, get_all_delayed_events};
use matrix_sdk::ruma::api::error::ErrorKind;
use matrix_sdk::ruma::events::relation::Reply;
use matrix_sdk::ruma::events::room::message::{Relation, RoomMessageEventContent};
use matrix_sdk::ruma::events::{MessageLikeEventType, TimelineEventType};
use matrix_sdk::ruma::{OwnedEventId, TransactionId};
use serde::Deserialize;

use crate::account::MatrixAccount;
use crate::errors::{from_http, from_sdk};
use crate::organizer::formats;

impl Scheduling for MatrixAccount {
    async fn can_send_later(&self, room: &RoomId) -> bool {
        let Ok(room) = self.room(room) else { return false };
        room.latest_encryption_state()
            .await
            .is_ok_and(|state| !state.is_encrypted())
    }

    async fn send_later(
        &self,
        room: &RoomId,
        text: &str,
        reply_to: Option<&EventId>,
        at: SystemTime,
    ) -> Result<ScheduledId, BackendError> {
        let target = self.room(room)?;
        if target.latest_encryption_state().await.map_err(from_sdk)?.is_encrypted() {
            return Err(BackendError::EncryptedChat);
        }
        let delay = at
            .duration_since(SystemTime::now())
            .ok()
            .filter(|delay| *delay >= Duration::from_millis(1))
            .ok_or(BackendError::TimePassed)?;
        let mut content = RoomMessageEventContent::text_plain(text);
        if let Some(event) = reply_to
            && let Ok(event) = OwnedEventId::try_from(event.as_str())
        {
            content.relates_to = Some(Relation::Reply(Reply::with_event_id(event)));
        }
        let request = delayed_message_event::unstable::Request::new(
            target.room_id().to_owned(),
            TransactionId::new(),
            DelayParameters::Timeout { timeout: delay },
            &content,
        )
        .map_err(BackendError::store)?;
        let response = self.client.send(request).await.map_err(from_http)?;
        Ok(response.delay_id.into())
    }

    async fn scheduled(&self) -> Result<Vec<ScheduledMessage>, BackendError> {
        #[derive(Deserialize)]
        struct Text {
            #[serde(default)]
            body: String,
        }
        let response = self
            .client
            .send(get_all_delayed_events::unstable::Request::new())
            .await
            .map_err(from_http)?;
        let mut waiting: Vec<ScheduledMessage> = response
            .delayed_events
            .into_iter()
            .filter(|event| {
                event.state_key.is_none()
                    && event.finalized_ts.is_none()
                    && event.event_type == TimelineEventType::from(MessageLikeEventType::RoomMessage.to_string())
            })
            .map(|event| {
                let running = formats::time(u64::from(event.running_since.get()));
                ScheduledMessage {
                    id: event.delay_id.into(),
                    room: RoomId::from(event.room_id.as_str()),
                    body: event
                        .content
                        .deserialize_as_unchecked::<Text>()
                        .map(|text| text.body)
                        .unwrap_or_default(),
                    send_at: running + event.delay,
                }
            })
            .collect();
        waiting.sort_by(|a, b| (a.send_at, &a.id).cmp(&(b.send_at, &b.id)));
        Ok(waiting)
    }

    async fn cancel_scheduled(&self, id: &ScheduledId) -> Result<(), BackendError> {
        let request = update::Request::new(id.to_string(), UpdateAction::Cancel);
        match self.client.send(request).await {
            Ok(_) => Ok(()),
            Err(error) if is_gone(&error) => Err(BackendError::NotWaiting),
            Err(error) => Err(from_http(error)),
        }
    }
}

fn is_gone(error: &HttpError) -> bool {
    matches!(error.client_api_error_kind(), Some(ErrorKind::NotFound))
}
