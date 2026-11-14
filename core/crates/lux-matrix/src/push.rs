//! The device's pusher on the server, and a notification's actions.
//!
//! The server keys pushers by app id and push key, so a new token (or a build of the other APNs
//! environment) makes a new pusher beside the old one. The pusher this device registered last is
//! kept in the account's store, and goes once the new one is in place.

use lux_core::ids::{EventId, RoomId};
use lux_core::ports::{BackendError, NotificationStream, Push};
use lux_core::push::Pusher;
use matrix_sdk::Client;
use matrix_sdk::ruma::EventId as SdkEventId;
use matrix_sdk::ruma::api::client::push::{PusherIds, PusherInit, PusherKind};
use matrix_sdk::ruma::api::client::receipt::create_receipt::v3::ReceiptType;
use matrix_sdk::ruma::events::receipt::ReceiptThread;
use matrix_sdk::ruma::events::room::message::RoomMessageEventContent;
use matrix_sdk::ruma::push::{HttpPusherData, PushFormat};
use serde::{Deserialize, Serialize};
use serde_json::json;
use tracing::warn;

use crate::account::MatrixAccount;
use crate::errors::from_sdk;

/// Where the account's store keeps the pusher this device registered last.
pub(crate) const KEPT_PUSHER: &[u8] = b"lux.pusher";

/// The ids of the pusher this device registered last.
#[derive(Debug, Serialize, Deserialize, PartialEq, Eq)]
struct KeptPusher {
    app_id: String,
    push_key: String,
}

/// The pusher's request: the gateway gets only the event's id (`event_id_only`), and a payload
/// that wakes the app's notification extension (`mutable-content`) with the pusher's neutral
/// text, shown as it is when the extension cannot read the event.
fn http_pusher(pusher: &Pusher) -> matrix_sdk::ruma::api::client::push::Pusher {
    let mut data = HttpPusherData::new(pusher.gateway_url.clone());
    data.format = Some(PushFormat::EventIdOnly);
    data.data.insert(
        "default_payload".to_owned(),
        json!({
            "aps": {
                "mutable-content": 1,
                "alert": { "body": pusher.fallback_text },
                "sound": "default",
            }
        }),
    );
    PusherInit {
        ids: PusherIds::new(pusher.push_key.as_str().to_owned(), pusher.app_id.clone()),
        kind: PusherKind::Http(data),
        app_display_name: pusher.app_name.clone(),
        device_display_name: pusher.device_name.clone(),
        profile_tag: None,
        lang: pusher.language.clone(),
    }
    .into()
}

async fn kept_pusher(client: &Client) -> Option<KeptPusher> {
    let value = client.state_store().get_custom_value(KEPT_PUSHER).await.ok()??;
    serde_json::from_slice(&value).ok()
}

async fn keep_pusher(client: &Client, pusher: Option<&KeptPusher>) -> Result<(), BackendError> {
    let store = client.state_store();
    let result = match pusher {
        Some(pusher) => {
            let value = serde_json::to_vec(pusher).map_err(BackendError::store)?;
            store.set_custom_value(KEPT_PUSHER, value).await
        }
        None => store.remove_custom_value(KEPT_PUSHER).await,
    };
    result.map(|_| ()).map_err(BackendError::store)
}

impl Push for MatrixAccount {
    async fn set_pusher(&self, pusher: &Pusher) -> Result<(), BackendError> {
        let before = kept_pusher(&self.client).await;
        self.client
            .pusher()
            .set(http_pusher(pusher), false)
            .await
            .map_err(from_sdk)?;
        if let Some(old) = before.filter(|old| pusher.replaces(&old.app_id, &old.push_key)) {
            // the new one is in place: an old one left behind only pushes to a dead token.
            if let Err(error) = self
                .client
                .pusher()
                .delete(PusherIds::new(old.push_key, old.app_id))
                .await
            {
                warn!(%error, "the device's old pusher stays");
            }
        }
        keep_pusher(
            &self.client,
            Some(&KeptPusher {
                app_id: pusher.app_id.clone(),
                push_key: pusher.push_key.as_str().to_owned(),
            }),
        )
        .await
    }

    async fn remove_pusher(&self) -> Result<(), BackendError> {
        let Some(kept) = kept_pusher(&self.client).await else {
            return Ok(());
        };
        self.client
            .pusher()
            .delete(PusherIds::new(kept.push_key, kept.app_id))
            .await
            .map_err(from_sdk)?;
        keep_pusher(&self.client, None).await
    }

    async fn send_now(&self, room: &RoomId, text: &str) -> Result<(), BackendError> {
        self.begin_background_work().await;
        // not through the send queue, which returns before the server has the message.
        self.room(room)?
            .send(RoomMessageEventContent::text_markdown(text))
            .await
            .map(|_| ())
            .map_err(from_sdk)
    }

    async fn mark_read_up_to(&self, room: &RoomId, event: &EventId) -> Result<(), BackendError> {
        let event = <&SdkEventId>::try_from(event.as_str()).map_err(|_| BackendError::UnknownMessage)?;
        self.begin_background_work().await;
        self.room(room)?
            .send_single_receipt(ReceiptType::Read, ReceiptThread::Unthreaded, event.to_owned())
            .await
            .map_err(from_sdk)
    }

    fn live_notifications(&self) -> NotificationStream {
        self.live.follow()
    }
}

#[cfg(test)]
mod tests {
    use lux_core::push::{PushKey, Pusher};
    use matrix_sdk::ruma::api::client::push::PusherKind;
    use serde_json::json;

    use super::http_pusher;

    #[test]
    fn the_pusher_sends_only_event_ids_and_wakes_the_extension() {
        let pusher = http_pusher(&Pusher {
            app_id: "com.example.ios".to_owned(),
            push_key: PushKey::from_token(&[0xab, 0x01]),
            gateway_url: "https://push.example.com/_matrix/push/v1/notify".to_owned(),
            app_name: "Lux".to_owned(),
            device_name: "Lux (iPhone)".to_owned(),
            language: "en".to_owned(),
            fallback_text: "Nová zpráva".to_owned(),
        });
        assert_eq!(pusher.ids.pushkey, "ab01");
        assert_eq!(pusher.ids.app_id, "com.example.ios");
        let PusherKind::Http(data) = pusher.kind else {
            panic!("not an http pusher");
        };
        let data = serde_json::to_value(data).unwrap();
        assert_eq!(data["format"], "event_id_only");
        assert_eq!(data["url"], "https://push.example.com/_matrix/push/v1/notify");
        assert_eq!(data["default_payload"]["aps"]["mutable-content"], json!(1));
        assert_eq!(data["default_payload"]["aps"]["alert"]["body"], "Nová zpráva");
    }
}
