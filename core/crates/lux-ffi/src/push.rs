//! Push notifications, as the apps see them: the device's pusher and a notification's actions on
//! the account, and the notification extension's reader of one pushed event.

use std::sync::Arc;
use std::time::Duration;

use futures_util::StreamExt;
use lux_core::ids::{EventId, RoomId};
use lux_core::ports::Push;
use lux_core::push::{Notification, PushEnvironment, PushKey, PushedEvent, Pusher};
use lux_matrix::{MatrixNotifications, NotificationPictures, StoreFolder};

use crate::account::{Backend, CoreAccount, CoreAccountError, CoreListenerHandle, CoreSessionKeeper, Keeper};
use crate::chat::CorePreviewKind;
use crate::runtime;

/// Which of Apple's push services the build's token is for.
#[derive(Clone, Copy, uniffi::Enum)]
pub enum CorePushEnvironment {
    /// Production (the App Store and its testers' builds).
    Production,
    /// The sandbox (builds signed for development).
    Sandbox,
}

impl From<CorePushEnvironment> for PushEnvironment {
    fn from(environment: CorePushEnvironment) -> Self {
        match environment {
            CorePushEnvironment::Production => Self::Production,
            CorePushEnvironment::Sandbox => Self::Sandbox,
        }
    }
}

/// What the device registers with the server to be pushed to.
#[derive(uniffi::Record)]
pub struct CorePusher {
    /// The token the system gave the app.
    pub token: Vec<u8>,
    /// The token's push service.
    pub environment: CorePushEnvironment,
    /// The gateway's app id for production; the sandbox's has `.dev` after it.
    pub app_id: String,
    /// The gateway's notify URL.
    pub gateway_url: String,
    /// The app's name, as the account's pushers list it.
    pub app_name: String,
    /// The device's name.
    pub device_name: String,
    /// The language of what the server words (`en`).
    pub language: String,
    /// What a notification says when the extension cannot read its event, in the user's
    /// language.
    pub fallback_text: String,
}

impl From<CorePusher> for Pusher {
    fn from(pusher: CorePusher) -> Self {
        Self {
            app_id: PushEnvironment::from(pusher.environment).app_id(&pusher.app_id),
            push_key: PushKey::from_token(&pusher.token),
            gateway_url: pusher.gateway_url,
            app_name: pusher.app_name,
            device_name: pusher.device_name,
            language: pusher.language,
            fallback_text: pusher.fallback_text,
        }
    }
}

#[uniffi::export(async_runtime = "tokio")]
impl CoreAccount {
    /// Registers the device's pusher, in place of the one it registered before (signing out
    /// removes it). The demo has no server to push.
    ///
    /// # Errors
    /// When the server refuses, or cannot be reached.
    pub async fn set_pusher(&self, pusher: CorePusher) -> Result<(), CoreAccountError> {
        let Backend::Matrix(account) = self.backend() else {
            return Ok(());
        };
        Ok(account.set_pusher(&pusher.into()).await?)
    }

    /// Sends `text` to the room, returning once the server has it (a reply from a notification).
    ///
    /// # Errors
    /// When the room is not the account's, or the server cannot be reached.
    pub async fn send_now(&self, room_id: String, text: String) -> Result<(), CoreAccountError> {
        Ok(self.matrix_account()?.send_now(&RoomId::from(room_id), &text).await?)
    }

    /// Marks the room read up to `event_id` (a notification's message).
    ///
    /// # Errors
    /// When the room is not the account's, or the server cannot be reached.
    pub async fn mark_read_up_to(&self, room_id: String, event_id: String) -> Result<(), CoreAccountError> {
        Ok(self
            .matrix_account()?
            .mark_read_up_to(&RoomId::from(room_id), &EventId::from(event_id))
            .await?)
    }

    /// Sends `listener` the notifications of what the sync brings while the app runs (the Mac,
    /// where no push wakes an extension), until the handle is cancelled or let go. The demo
    /// sends none.
    pub fn follow_notifications(&self, listener: Arc<dyn CoreNotificationListener>) -> Arc<CoreListenerHandle> {
        let Backend::Matrix(account) = self.backend() else {
            return Arc::new(CoreListenerHandle { tasks: Vec::new() });
        };
        let notifications = account.live_notifications();
        let task = runtime::handle().spawn(notifications.for_each(move |notification| {
            listener.on_notification(CoreNotification::new(notification, NotificationPictures::default()));
            async {}
        }));
        Arc::new(CoreListenerHandle { tasks: vec![task] })
    }

    /// A background refresh (the system's app refresh task): syncs until the server answered,
    /// at most `seconds`, then stops the sync as `pause_sync` does, unless the app came to the
    /// front meanwhile. True when the server answered (the demo has none to ask).
    pub async fn refresh(&self, seconds: f64) -> bool {
        let Backend::Matrix(account) = self.backend() else {
            return true;
        };
        let within = Duration::try_from_secs_f64(seconds).unwrap_or(Duration::ZERO);
        account.refresh_within(within).await
    }
}

/// Hears the notifications of what the sync brings.
#[uniffi::export(with_foreign)]
pub trait CoreNotificationListener: Send + Sync {
    /// One to show, on the core's thread.
    fn on_notification(&self, notification: CoreNotification);
}

/// One notification, structured (`lux_core::push::Notification`); the apps word it.
#[derive(uniffi::Record)]
pub struct CoreNotification {
    /// The room it came in.
    pub room_id: String,
    /// The message it shows.
    pub event_id: String,
    /// The chat it goes with: the merged chat's id (`merge:…`) or the room's.
    pub chat_id: String,
    /// The chat's name.
    pub chat_name: String,
    /// The sender's user id: who the system groups and filters by.
    pub sender_id: String,
    /// The sender's name.
    pub sender_name: String,
    /// More than two people.
    pub is_group: bool,
    /// What the message is.
    pub kind: CorePreviewKind,
    /// It makes a sound.
    pub is_noisy: bool,
    /// It came long after it was sent (history a bridge brings in): it shows quietly.
    pub is_late: bool,
    /// The sender's picture, a small image file's bytes; none when it has none or could not be
    /// had in time.
    pub sender_image: Option<Vec<u8>>,
    /// A group's picture, the same way.
    pub chat_image: Option<Vec<u8>>,
}

impl CoreNotification {
    fn new(notification: Notification, pictures: NotificationPictures) -> Self {
        Self {
            room_id: notification.room.to_string(),
            event_id: notification.event.to_string(),
            chat_id: notification.chat.to_string(),
            chat_name: notification.chat_name,
            sender_id: notification.sender.to_string(),
            sender_name: notification.sender_name,
            is_group: notification.is_group,
            kind: notification.kind.into(),
            is_noisy: notification.is_noisy,
            is_late: notification.is_late,
            sender_image: pictures.sender,
            chat_image: pictures.chat,
        }
    }
}

/// A pushed event, as the extension read it.
#[derive(uniffi::Enum)]
#[expect(clippy::large_enum_variant, reason = "crosses to Swift by value, once per push")]
pub enum CorePushedEvent {
    /// Something to show.
    Shown {
        /// What.
        notification: CoreNotification,
    },
    /// The push rules or an ignored sender say it does not notify.
    FilteredOut,
    /// Deleted, or not found.
    Gone,
}

/// The notification extension's view of the account: the kept session, without its sync.
#[derive(uniffi::Object)]
pub struct CoreNotificationReader {
    notifications: Arc<MatrixNotifications>,
}

impl Drop for CoreNotificationReader {
    fn drop(&mut self) {
        // the SDK's client closes on the runtime.
        let notifications = Arc::clone(&self.notifications);
        runtime::handle().spawn(async move { drop(notifications) });
    }
}

/// Opens the account kept in the folder at `store_folder`, its session kept by `keeper`, as the
/// notification extension; none when no session is kept.
///
/// # Errors
/// When the folder does not hold the session's device, or the store cannot be opened.
#[uniffi::export(async_runtime = "tokio")]
pub async fn open_notification_reader(
    store_folder: String,
    keeper: Arc<dyn CoreSessionKeeper>,
) -> Result<Option<Arc<CoreNotificationReader>>, CoreAccountError> {
    let opened = MatrixNotifications::open(&StoreFolder::new(store_folder), Arc::new(Keeper(keeper))).await?;
    Ok(opened.map(|notifications| {
        Arc::new(CoreNotificationReader {
            notifications: Arc::new(notifications),
        })
    }))
}

#[uniffi::export(async_runtime = "tokio")]
impl CoreNotificationReader {
    /// Reads the event `event_id` of `room_id`: fetched, decrypted, checked against the push
    /// rules; a shown one with its pictures (from the media cache, else fetched briefly).
    ///
    /// # Errors
    /// When the server cannot be reached, or the event cannot be read.
    pub async fn read(&self, room_id: String, event_id: String) -> Result<CorePushedEvent, CoreAccountError> {
        let pushed = self
            .notifications
            .read(&RoomId::from(room_id), &EventId::from(event_id))
            .await?;
        Ok(match pushed {
            PushedEvent::Shown(notification) => {
                let pictures = self.notifications.pictures(&notification).await;
                CorePushedEvent::Shown {
                    notification: CoreNotification::new(notification, pictures),
                }
            }
            PushedEvent::FilteredOut => CorePushedEvent::FilteredOut,
            PushedEvent::Gone => CorePushedEvent::Gone,
        })
    }
}
