//! One pushed event, read in the notification extension: the kept session opened from the
//! shared folder without its sync, and the event fetched and decrypted by `matrix-sdk-ui`'s
//! [`NotificationClient`].
//!
//! The extension is another process over the app's store: it holds the store's locks as
//! [`Process::NotificationExtension`], so the SDK knows when the app wrote meanwhile (and the
//! other way round), and the token refresh is shared through the same lock and the platform's
//! secret store. It lives within a few megabytes: no room list, no sync service, no event cache,
//! small SQLite caches.
//!
//! What it shows beside the text comes from the same store: the merged chats from the account's
//! data as the app last synced it (`com.bardav.lux.merges`, one row), and the pictures from the
//! SDK's media cache, where the chat list put them, else from the server within a short time.

use std::sync::Arc;
use std::time::{Duration, SystemTime};

use lux_core::ids::{ChatId, EventId, MediaId, RoomId};
use lux_core::merge::{self, Merge};
use lux_core::ports::{BackendError, SecretStore};
use lux_core::preview::{Membership, PreviewKind};
use lux_core::push::{Notification, NotifiedChat, NotifiedSender, PushedEvent};
use matrix_sdk::Client;
use matrix_sdk::ruma::events::GlobalAccountDataEventType;
use matrix_sdk::ruma::{EventId as SdkEventId, RoomId as SdkRoomId};
use matrix_sdk_ui::notification_client::{
    Error as NotificationError, NotificationClient, NotificationEvent, NotificationItem, NotificationProcessSetup,
    NotificationStatus,
};

use crate::errors::from_sdk;
use crate::mapping;
use crate::organizer::formats::{self, Content};
use crate::sign_in::restored_client;
use crate::store::{Process, StoreFolder};
use crate::timeline::media;

/// How long a picture the cache does not have may take to come from the server: the extension
/// has about 30 s for everything, and a notification without a picture is fine.
const PICTURE_TIME: Duration = Duration::from_secs(3);

/// The pictures of a notification, as small image files' bytes (JPEG or PNG thumbnails).
#[derive(Debug, Default)]
pub struct NotificationPictures {
    /// The sender's.
    pub sender: Option<Vec<u8>>,
}

/// The account's pushed events, read one at a time.
pub struct MatrixNotifications {
    /// The account's client over the kept store: the chats as the app last synced them.
    client: Client,
    notifications: NotificationClient,
}

impl MatrixNotifications {
    /// Opens the session kept in `secrets` over `folder`, as the notification extension; `None`
    /// when no session is kept.
    ///
    /// # Errors
    /// When the folder does not hold the session's device, or the store cannot be opened.
    pub async fn open(folder: &StoreFolder, secrets: Arc<dyn SecretStore>) -> Result<Option<Self>, BackendError> {
        let Some(client) = restored_client(folder, &secrets, Process::NotificationExtension).await? else {
            return Ok(None);
        };
        let notifications = NotificationClient::new(client.clone(), NotificationProcessSetup::MultipleProcesses)
            .await
            .map_err(from_notification)?;
        Ok(Some(Self { client, notifications }))
    }

    /// Reads the event `event` of `room`: fetched, decrypted, and checked against the push rules.
    ///
    /// # Errors
    /// When the server cannot be reached, or the event cannot be read.
    pub async fn read(&self, room: &RoomId, event: &EventId) -> Result<PushedEvent, BackendError> {
        let unknown = || BackendError::UnknownChat(ChatId::Room(room.clone()));
        let room_id = <&SdkRoomId>::try_from(room.as_str()).map_err(|_| unknown())?;
        let event_id = <&SdkEventId>::try_from(event.as_str()).map_err(|_| BackendError::UnknownMessage)?;
        let item = match self
            .notifications
            .get_notification(room_id, event_id)
            .await
            .map_err(|error| match error {
                NotificationError::UnknownRoom | NotificationError::SlidingSyncEmptyRoom => unknown(),
                other => from_notification(other),
            })? {
            NotificationStatus::Event(item) => item,
            NotificationStatus::EventFilteredOut => return Ok(PushedEvent::FilteredOut),
            NotificationStatus::EventNotFound | NotificationStatus::EventRedacted => return Ok(PushedEvent::Gone),
        };
        // the chat as the chat list shows it: from the app's store, else from what the
        // notification's own sync just learned of a chat the app has not seen yet.
        let known = self
            .client
            .get_room(room_id)
            .or_else(|| self.notifications.get_room(room_id));
        let chat = match known {
            Some(room) => {
                let heroes = room.heroes().await;
                let looks = mapping::Looks::of(&room, &heroes).await;
                KnownChat {
                    name: mapping::display_name(&room),
                    is_group: looks.is_group,
                    picture: looks.picture.map(|url| url.to_string()),
                }
            }
            None => KnownChat::of(&item),
        };
        let merges = self.merges().await;
        let merge = merge::containing(&merges, room);
        Ok(PushedEvent::Shown(notification(room, event, &item, &chat, merge)))
    }

    /// Closes the SDK's stores (in the App Group, shared with the app), after the calls under
    /// way: the extension is suspended once it hands its work back, and iOS ends a process that
    /// holds a lock on a shared file then (`0xdead10cc`). Calls after it fail; the handle is let
    /// go after it.
    pub async fn close(&self) {
        if let Err(error) = self.client.pause().await {
            tracing::warn!(%error, "the extension's stores stay open");
        }
    }

    /// The picture `notification` names: from the media cache, else fetched; none when it cannot
    /// be had in [`PICTURE_TIME`].
    pub async fn pictures(&self, notification: &Notification) -> NotificationPictures {
        NotificationPictures {
            sender: self.picture(notification.sender_picture.as_ref()).await,
        }
    }

    async fn picture(&self, media: Option<&MediaId>) -> Option<Vec<u8>> {
        media::avatar_bytes(&self.client, media, PICTURE_TIME).await
    }

    /// The merged chats, as the account's data in the store has them (no request).
    async fn merges(&self) -> Vec<Merge> {
        let kept = self
            .client
            .account()
            .account_data_raw(GlobalAccountDataEventType::from(formats::MERGES))
            .await;
        match kept {
            Ok(Some(raw)) => raw
                .deserialize_as_unchecked::<Content>()
                .map(|content| formats::merges(&content))
                .unwrap_or_default(),
            Ok(None) => Vec::new(),
            Err(error) => {
                tracing::warn!(%error, "the merged chats cannot be read");
                Vec::new()
            }
        }
    }
}

/// What the notification needs of its chat.
struct KnownChat {
    name: String,
    is_group: bool,
    picture: Option<String>,
}

impl KnownChat {
    /// The chat as the notification's item describes it.
    fn of(item: &NotificationItem) -> Self {
        let people = item
            .joined_members_count
            .saturating_sub(item.active_service_members_count);
        let is_group = !item.is_direct_message_room && people > 2;
        Self {
            name: item.room_computed_display_name.clone(),
            is_group,
            picture: item.room_avatar_url.clone(),
        }
    }
}

/// The notification of `item` (the event `event`) in `chat`, part of `merge` if any.
fn notification(
    room: &RoomId,
    event: &EventId,
    item: &NotificationItem,
    chat: &KnownChat,
    merge: Option<&Merge>,
) -> Notification {
    let kind = match &item.event {
        NotificationEvent::Timeline(event) => mapping::event_kind(event).unwrap_or(PreviewKind::Other),
        NotificationEvent::Invite(_) => PreviewKind::Membership(Membership::Invited),
    };
    let sender = item.event.sender();
    // an invite is now; a message, when its server took it.
    let sent = match &item.event {
        NotificationEvent::Timeline(event) => crate::convert::system_time(event.origin_server_ts()),
        NotificationEvent::Invite(_) => SystemTime::now(),
    };
    Notification::new(
        NotifiedChat {
            room,
            name: &chat.name,
            is_group: chat.is_group,
            picture: chat.picture.as_deref(),
            merge,
        },
        event.clone(),
        NotifiedSender {
            id: sender.as_str(),
            name: item.sender_display_name.as_deref(),
            localpart: sender.localpart(),
            picture: item.sender_avatar_url.as_deref(),
        },
        kind,
        // the server pushed it, so a rule notifies: without its actions, it sounds.
        item.is_noisy.unwrap_or(true),
    )
    .in_thread(item.thread_id.as_ref().map(|root| EventId::from(root.as_str())))
    .arrived(sent, SystemTime::now())
}

/// A notification's error, but a room the client does not know (which its caller names).
fn from_notification(error: NotificationError) -> BackendError {
    match error {
        NotificationError::SdkError(error) => from_sdk(error),
        NotificationError::ContextMissingEvent | NotificationError::InvalidRumaEvent => BackendError::UnknownMessage,
        other => BackendError::store(other),
    }
}

#[cfg(test)]
mod tests {
    use lux_core::ids::{ChatId, EventId, MediaId, RoomId};
    use lux_core::merge::Merge;
    use lux_core::preview::{Membership, PreviewKind};
    use matrix_sdk::ruma::events::AnySyncTimelineEvent;
    use matrix_sdk::ruma::events::room::member::StrippedRoomMemberEvent;
    use matrix_sdk::ruma::serde::Raw;
    use matrix_sdk_ui::notification_client::{NotificationEvent, NotificationItem, RawNotificationEvent};
    use serde_json::{Value, json};

    use super::{KnownChat, notification};

    fn read(item: &NotificationItem, merge: Option<&Merge>) -> lux_core::push::Notification {
        let room = RoomId::from("!room:example.org");
        notification(&room, &EventId::from("$event"), item, &KnownChat::of(item), merge)
    }

    fn message(content: &Value) -> Raw<AnySyncTimelineEvent> {
        Raw::new(&json!({
            "type": "m.room.message",
            "event_id": "$event",
            "sender": "@anna:example.org",
            "origin_server_ts": 1,
            "content": content,
        }))
        .unwrap()
        .cast_unchecked()
    }

    fn item(raw: Raw<AnySyncTimelineEvent>, is_direct: bool, members: u64) -> NotificationItem {
        NotificationItem {
            event: NotificationEvent::Timeline(Box::new(raw.deserialize().unwrap())),
            raw_event: RawNotificationEvent::Timeline(raw),
            sender_display_name: Some("Anna".to_owned()),
            sender_avatar_url: Some("mxc://example.org/anna".to_owned()),
            is_sender_name_ambiguous: false,
            room_computed_display_name: "Trip".to_owned(),
            room_avatar_url: None,
            room_canonical_alias: None,
            room_topic: None,
            room_join_rule: None,
            is_room_encrypted: Some(true),
            is_direct_message_room: is_direct,
            joined_members_count: members,
            service_members: Vec::new(),
            active_service_members_count: 1,
            is_space: false,
            is_noisy: Some(false),
            has_mention: None,
            thread_id: None,
            actions: None,
            room_is_dm: is_direct,
        }
    }

    #[test]
    fn a_text_message_is_its_text_from_its_sender() {
        let item = item(message(&json!({"msgtype": "m.text", "body": "see you\nsoon"})), true, 3);
        let notification = read(&item, None);
        assert_eq!(notification.kind, PreviewKind::Text("see you soon".to_owned()));
        assert_eq!(notification.sender_name, "Anna");
        assert_eq!(notification.chat_name, "Trip");
        // a direct chat with a bridge's bot is still two people.
        assert!(!notification.is_group);
        assert!(!notification.is_noisy);
        assert_eq!(
            notification.sender_picture.as_ref().map(MediaId::as_str),
            Some("mxc://example.org/anna")
        );
        assert_eq!(notification.chat, ChatId::from("!room:example.org"));
    }

    #[test]
    fn a_threads_reply_opens_its_thread() {
        let raw = message(&json!({
            "msgtype": "m.text",
            "body": "count me in",
            "m.relates_to": { "rel_type": "m.thread", "event_id": "$root" },
        }));
        let mut threaded = item(raw, false, 5);
        threaded.thread_id = Some(matrix_sdk::ruma::owned_event_id!("$root"));
        assert_eq!(read(&threaded, None).thread, Some(EventId::from("$root")));
        let plain = item(message(&json!({ "msgtype": "m.text", "body": "hi" })), false, 5);
        assert_eq!(read(&plain, None).thread, None);
    }

    #[test]
    fn a_photo_in_a_group_names_the_group() {
        let content = json!({"msgtype": "m.image", "body": "IMG_1.jpg", "url": "mxc://example.org/photo"});
        let item = item(message(&content), false, 5);
        let notification = read(&item, None);
        assert_eq!(notification.kind, PreviewKind::Image);
        assert!(notification.is_group);
        // the sender's picture, in a group too.
        assert_eq!(
            notification.sender_picture.as_ref().map(MediaId::as_str),
            Some("mxc://example.org/anna")
        );
    }

    #[test]
    fn an_event_no_line_says_is_a_message() {
        let raw = Raw::new(&json!({
            "type": "m.room.topic",
            "state_key": "",
            "event_id": "$event",
            "sender": "@anna:example.org",
            "origin_server_ts": 1,
            "content": {"topic": "plans"},
        }))
        .unwrap()
        .cast_unchecked();
        let item = item(raw, false, 5);
        assert_eq!(read(&item, None).kind, PreviewKind::Other);
    }

    #[test]
    fn an_invite_says_so() {
        let raw: Raw<StrippedRoomMemberEvent> = Raw::new(&json!({
            "type": "m.room.member",
            "state_key": "@me:example.org",
            "sender": "@anna:example.org",
            "content": {"membership": "invite"},
        }))
        .unwrap()
        .cast_unchecked();
        let mut item = item(message(&json!({"msgtype": "m.text", "body": ""})), true, 1);
        item.event = NotificationEvent::Invite(Box::new(raw.deserialize().unwrap()));
        item.raw_event = RawNotificationEvent::Invite(raw);
        item.is_noisy = None;
        let notification = read(&item, None);
        assert_eq!(notification.kind, PreviewKind::Membership(Membership::Invited));
        assert!(notification.is_noisy);
    }

    #[test]
    fn a_merged_rooms_message_is_the_merged_chats() {
        let item = item(message(&json!({"msgtype": "m.text", "body": "hi"})), true, 2);
        let merge = Merge {
            id: "anna".into(),
            name: "Anna Novak".to_owned(),
            rooms: vec!["!other:example.org".into(), "!room:example.org".into()],
            default_room: "!other:example.org".into(),
        };
        let notification = read(&item, Some(&merge));
        assert_eq!(notification.chat, ChatId::from("merge:anna"));
        assert_eq!(notification.chat_name, "Anna Novak");
        assert_eq!(notification.room, RoomId::from("!room:example.org"));
    }
}
