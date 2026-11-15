//! A chat's actions and the organizing of the account's chats, over the SDK and the account's
//! data ([`crate::organizer`]).
//!
//! Where each is kept: pins and Low Priority in the room's tags (`m.favourite` with its order,
//! `m.lowpriority`), as every Matrix app reads them; mutes in the push rules; marked unread in the
//! room's `m.marked_unread`; archive, deletes, reminders, merges, labels, saved messages and the
//! places' arrangement in the app's own account data, which no bridge reads, so none of it reaches
//! the chat's network.

use std::collections::{HashMap, HashSet};
use std::sync::Arc;
use std::time::SystemTime;

use lux_core::chat::{Chat, Label, NotificationMode, SavedKind, SavedMessage};
use lux_core::ids::{ChatId, EventId, LabelId, MergeId, RoomId};
use lux_core::organizer::pins::{self, NewPin};
use lux_core::organizer::{ChatMarks, Organized, Reminder};
use lux_core::places::Arrangement;
use lux_core::ports::{BackendError, ChatActions, ChatChange, ChatSending, Organizing, SavedMessages, ValueStream};
use lux_core::timeline::Receipt;
use matrix_sdk::notification_settings::{IsEncrypted, IsOneToOne, NotificationSettings, RoomNotificationMode};
use matrix_sdk::ruma::events::AnySyncTimelineEvent;
use matrix_sdk::ruma::events::room::message::MessageType;
use matrix_sdk::ruma::events::tag::TagName;
use matrix_sdk::ruma::push::{
    Action, EventMatchConditionData, EventPropertyContainsConditionData, HighlightTweakValue, PushCondition, RuleKind,
    ScalarJsonValue, Tweak,
};
use matrix_sdk::ruma::{OwnedRoomId, RoomId as SdkRoomId, UserId};
use matrix_sdk::{Client, Room};

use crate::account::MatrixAccount;
use crate::errors::from_sdk;
use crate::organizer::formats::{self, Bookmark, Content};
use crate::organizer::{Change, Write};
use crate::streams::watched;

impl MatrixAccount {
    /// The joined room `room`.
    pub(crate) fn room(&self, room: &RoomId) -> Result<Room, BackendError> {
        crate::convert::room(&self.client, room)
    }

    /// The rooms of a chat of the list: a merged chat's, else its own; each must be there.
    pub(crate) fn rooms_of(&self, chat: &ChatId) -> Result<Vec<Room>, BackendError> {
        let rooms = chat.rooms(&self.organizer.now().merges);
        if rooms.is_empty() {
            return Err(BackendError::UnknownChat(chat.clone()));
        }
        rooms.iter().map(|room| self.room(room)).collect()
    }
}

impl ChatActions for MatrixAccount {
    async fn change(&self, chat: &ChatId, change: ChatChange) -> Result<(), BackendError> {
        let rooms = self.rooms_of(chat)?;
        match change {
            ChatChange::Archive => {
                let marks = newest_of(&rooms);
                self.organizer
                    .change(change_marks(move |all| all.archived.extend(marks)))
                    .await
            }
            ChatChange::Unarchive => {
                let ids = ids(&rooms);
                self.organizer
                    .change(change_marks(move |all| {
                        all.archived.retain(|room, _| !ids.contains(room));
                    }))
                    .await
            }
            ChatChange::Delete => {
                let marks = newest_of(&rooms);
                self.organizer
                    .change(change_marks(move |all| {
                        all.hidden.extend(marks.iter().cloned());
                        all.cleared.extend(marks);
                    }))
                    .await
            }
            ChatChange::Mute => {
                let settings = self.client.notification_settings().await;
                let own = self.client.user_id().ok_or(BackendError::SignedOut)?;
                for room in &rooms {
                    // the mute first: it removes the room's other rules, the mention rule too.
                    settings
                        .set_room_notification_mode(room.room_id(), RoomNotificationMode::Mute)
                        .await
                        .map_err(BackendError::refused)?;
                    let MentionRule {
                        id,
                        actions,
                        conditions,
                    } = MentionRule::new(room.room_id(), own);
                    settings
                        .create_custom_conditional_push_rule(id, RuleKind::Override, actions, conditions)
                        .await
                        .map_err(BackendError::refused)?;
                }
                Ok(())
            }
            ChatChange::Unmute => self.unmute(&rooms).await,
            ChatChange::Read => {
                for room in &rooms {
                    let id = RoomId::from(room.room_id().as_str());
                    self.timelines.mark_read(&id, Receipt::Public).await?;
                }
                Ok(())
            }
            ChatChange::Unread => each(&rooms, |room| async move { room.set_unread_flag(true).await }).await,
            ChatChange::LowPriority => {
                each(&rooms, |room| async move { room.set_is_low_priority(true, None).await }).await
            }
            ChatChange::Inbox => {
                each(
                    &rooms,
                    |room| async move { room.set_is_low_priority(false, None).await },
                )
                .await
            }
            ChatChange::Pin => {
                for room in &rooms {
                    pin(&self.client, room).await?;
                }
                Ok(())
            }
            ChatChange::Unpin => each(&rooms, |room| async move { room.set_is_favourite(false, None).await }).await,
        }
    }

    async fn answer_request(&self, room: &RoomId, accept: bool) -> Result<(), BackendError> {
        let room = self.room(room)?;
        if accept { room.join().await } else { room.leave().await }.map_err(from_sdk)
    }
}

impl MatrixAccount {
    /// Unmutes the rooms, muted here or elsewhere: each follows the account's settings again. An
    /// archived one stays archived: the messages that came while it was muted do not bring it
    /// back.
    async fn unmute(&self, rooms: &[Room]) -> Result<(), BackendError> {
        let archived: Vec<(RoomId, SystemTime)> = {
            let now = self.organizer.now();
            newest_of(rooms)
                .into_iter()
                .filter(|(room, _)| now.marks.archived.contains_key(room))
                .collect()
        };
        if !archived.is_empty() {
            self.organizer
                .change(change_marks(move |all| all.archived.extend(archived)))
                .await?;
        }
        let settings = self.client.notification_settings().await;
        for room in rooms {
            let encrypted = room.latest_encryption_state().await.map_err(from_sdk)?.is_encrypted();
            let is_one_to_one = room.active_members_count() == 2;
            settings
                .unmute_room(
                    room.room_id(),
                    IsEncrypted::from(encrypted),
                    IsOneToOne::from(is_one_to_one),
                )
                .await
                .map_err(BackendError::refused)?;
        }
        Ok(())
    }
}

/// Does `action` to each room, in order, and fails with the first failure.
async fn each<F, Fut>(rooms: &[Room], action: F) -> Result<(), BackendError>
where
    F: Fn(Room) -> Fut,
    Fut: Future<Output = matrix_sdk::Result<()>>,
{
    for room in rooms {
        action(room.clone()).await.map_err(from_sdk)?;
    }
    Ok(())
}

/// Pins `room` after the pinned rooms; when their orders are used up, spreads them out again.
async fn pin(client: &Client, room: &Room) -> Result<(), BackendError> {
    let mut pinned: Vec<(Option<f64>, Room)> = Vec::new();
    for other in client.joined_rooms() {
        if other.is_favourite() && other.room_id() != room.room_id() {
            pinned.push((favourite_order(&other).await, other));
        }
    }
    pinned.sort_by(|(a, _), (b, _)| a.unwrap_or(f64::INFINITY).total_cmp(&b.unwrap_or(f64::INFINITY)));
    let orders: Vec<Option<f64>> = pinned.iter().map(|(order, _)| *order).collect();
    let order = match pins::after(&orders) {
        NewPin::At(order) => order,
        NewPin::Spread { others, last } => {
            for ((_, other), order) in pinned.iter().zip(others) {
                other.set_is_favourite(true, Some(order)).await.map_err(from_sdk)?;
            }
            last
        }
    };
    room.set_is_favourite(true, Some(order)).await.map_err(from_sdk)
}

/// The order of the room's `m.favourite` tag, if it has one.
pub(crate) async fn favourite_order(room: &Room) -> Option<f64> {
    let tags = room.tags().await.ok().flatten()?;
    tags.get(&TagName::Favorite).and_then(|tag| tag.order)
}

/// The rule that keeps a muted room's mentions of the account highlighted, without notifying, so
/// the list can still show them; the room's own rule, so unmuting removes it with the mute. Its
/// id is the one the account's other devices know (`com.bardav.lux.mention.<room>`).
struct MentionRule {
    id: String,
    actions: Vec<Action>,
    conditions: Vec<PushCondition>,
}

impl MentionRule {
    fn new(room: &SdkRoomId, own: &UserId) -> Self {
        Self {
            id: format!("com.bardav.lux.mention.{room}"),
            actions: vec![Action::SetTweak(Tweak::Highlight(HighlightTweakValue::Yes))],
            conditions: vec![
                EventMatchConditionData::new("room_id".to_owned(), room.to_string()).into(),
                EventPropertyContainsConditionData::new(
                    r"content.m\.mentions.user_ids".to_owned(),
                    ScalarJsonValue::String(own.to_string()),
                )
                .into(),
            ],
        }
    }
}

/// The rooms whose notifications the user set, and how: the others are as the account's
/// settings say for a room of their kind.
pub(crate) async fn room_notifications(settings: &NotificationSettings) -> HashMap<OwnedRoomId, NotificationMode> {
    let mut modes = HashMap::new();
    for room in settings.get_rooms_with_user_defined_rules(Some(true)).await {
        let Ok(id) = OwnedRoomId::try_from(room) else { continue };
        let mode = notification_mode(settings.get_user_defined_room_notification_mode(&id).await);
        if mode != NotificationMode::Default {
            modes.insert(id, mode);
        }
    }
    modes
}

/// The app's mode for a room's push rules, as the SDK reads them; `None`: the user set none.
pub(crate) fn notification_mode(mode: Option<RoomNotificationMode>) -> NotificationMode {
    match mode {
        None => NotificationMode::Default,
        Some(RoomNotificationMode::AllMessages) => NotificationMode::All,
        Some(RoomNotificationMode::MentionsAndKeywordsOnly) => NotificationMode::Mentions,
        Some(RoomNotificationMode::Mute) => NotificationMode::Off,
    }
}

fn ids(rooms: &[Room]) -> HashSet<RoomId> {
    rooms.iter().map(|room| RoomId::from(room.room_id().as_str())).collect()
}

/// Each room with the time of its newest message (none: the start of time): what a later
/// message is newer than.
fn newest_of(rooms: &[Room]) -> Vec<(RoomId, SystemTime)> {
    rooms
        .iter()
        .map(|room| {
            let newest = room.latest_event().timestamp().map_or(0, |ts| u64::from(ts.get()));
            (RoomId::from(room.room_id().as_str()), formats::time(newest))
        })
        .collect()
}

/// A change of the archived and deleted chats.
fn change_marks(change: impl FnOnce(&mut ChatMarks) + Send + 'static) -> Change {
    Box::new(move |documents| {
        let content = documents.content(formats::CHATS);
        let before = formats::chat_marks(content);
        let mut marks = before.clone();
        change(&mut marks);
        Ok(if marks == before {
            Vec::new()
        } else {
            vec![Write::new(formats::CHATS, formats::with_chat_marks(content, &marks))]
        })
    })
}

/// Drops the marks of the chats among `marked` a newer message brought back.
pub(crate) fn tidy_marks(marked: Vec<Chat>) -> Change {
    Box::new(move |documents| {
        let content = documents.content(formats::CHATS);
        Ok(match formats::chat_marks(content).without_returned(&marked) {
            Some(tidied) => vec![Write::new(formats::CHATS, formats::with_chat_marks(content, &tidied))],
            None => Vec::new(),
        })
    })
}

/// A change of one document, from its content as it is.
fn change_document(event_type: &'static str, change: impl FnOnce(&Content) -> Content + Send + 'static) -> Change {
    Box::new(move |documents| {
        let content = documents.content(event_type);
        let changed = change(content);
        Ok(if changed == *content {
            Vec::new()
        } else {
            vec![Write::new(event_type, changed)]
        })
    })
}

/// The label records' writes, then the marker that tells other devices to read them again.
fn label_writes(records: &[lux_core::organizer::LabelRecord]) -> Vec<Write> {
    let mut writes: Vec<Write> = records
        .iter()
        .map(|record| {
            let (event_type, content) = formats::label_record_event(record);
            Write { event_type, content }
        })
        .collect();
    writes.push(Write::new(formats::LABELS_CHANGED, formats::labels_changed()));
    writes
}

impl Organizing for MatrixAccount {
    fn organized(&self) -> ValueStream<Arc<Organized>> {
        watched(self.organizer.subscribe())
    }

    async fn make_label(&self, name: &str) -> Result<Label, BackendError> {
        let id = LabelId::from(uuid::Uuid::new_v4().to_string().to_uppercase());
        let (made, name) = (id.clone(), name.to_owned());
        self.organizer
            .change(Box::new(move |documents| {
                let record = documents.labels().create(made, &name)?;
                Ok(label_writes(&[record]))
            }))
            .await?;
        self.organizer
            .now()
            .labels
            .iter()
            .find(|label| label.id == id)
            .cloned()
            .ok_or(BackendError::Label(lux_core::organizer::LabelError::NotFound))
    }

    async fn remove_label(&self, id: &LabelId) -> Result<(), BackendError> {
        let id = id.clone();
        self.organizer
            .change(Box::new(move |_| {
                Ok(label_writes(&[lux_core::organizer::LabelRecord::Deleted { id }]))
            }))
            .await
    }

    async fn set_in_label(&self, chat: &ChatId, id: &LabelId, included: bool) -> Result<(), BackendError> {
        let rooms: Vec<RoomId> = self
            .rooms_of(chat)?
            .iter()
            .map(|room| RoomId::from(room.room_id().as_str()))
            .collect();
        let id = id.clone();
        self.organizer
            .change(Box::new(move |documents| {
                Ok(label_writes(&documents.labels().assign(&id, &rooms, included)?))
            }))
            .await
    }

    async fn set_reminder(&self, chat: &ChatId, at: Option<SystemTime>) -> Result<(), BackendError> {
        let rooms = ids(&self.rooms_of(chat)?);
        let now = SystemTime::now();
        self.organizer
            .change(change_document(formats::REMINDERS, move |content| {
                let mut reminders = formats::reminders(content);
                for room in rooms {
                    match at {
                        Some(at) => reminders.insert(room, Reminder { at, set_at: now }),
                        None => reminders.remove(&room),
                    };
                }
                formats::with_reminders(content, &reminders)
            }))
            .await
    }

    async fn merge(&self, chats: &[ChatId], name: &str, default_room: &RoomId) -> Result<ChatId, BackendError> {
        let mut rooms: Vec<RoomId> = Vec::new();
        for chat in chats {
            rooms.extend(
                self.rooms_of(chat)?
                    .iter()
                    .map(|room| RoomId::from(room.room_id().as_str())),
            );
        }
        let (name, default_room) = (name.to_owned(), default_room.clone());
        let new_id = MergeId::from(uuid::Uuid::new_v4().to_string().to_uppercase());
        let (sender, answer) = tokio::sync::oneshot::channel();
        self.organizer
            .change(Box::new(move |documents| {
                let organized = documents.organized();
                let (merges, chat) = organized.merging(&rooms, &name, &default_room, new_id);
                let _ = sender.send(chat);
                let content = documents.content(formats::MERGES);
                Ok(vec![Write::new(
                    formats::MERGES,
                    formats::with_merges(content, &merges),
                )])
            }))
            .await?;
        answer.await.map_err(|_| BackendError::SignedOut)
    }

    async fn unmerge(&self, chat: &ChatId) -> Result<(), BackendError> {
        let chat = chat.clone();
        self.organizer
            .change(change_document(formats::MERGES, move |content| {
                let organized = Organized {
                    merges: formats::merges(content),
                    ..Organized::default()
                };
                formats::with_merges(content, &organized.unmerging(&chat))
            }))
            .await
    }

    async fn set_arrangement(&self, arrangement: &Arrangement) -> Result<(), BackendError> {
        let arrangement = arrangement.clone();
        self.organizer
            .change(change_document(formats::PLACE_ORDER, move |content| {
                formats::with_arrangement(content, &arrangement)
            }))
            .await
    }
}

impl SavedMessages for MatrixAccount {
    async fn save_message(&self, room: &RoomId, event: &EventId) -> Result<(), BackendError> {
        let target = self.room(room)?;
        let event_id =
            matrix_sdk::ruma::OwnedEventId::try_from(event.as_str()).map_err(|_| BackendError::NotSavable)?;
        let found = target.load_or_fetch_event(&event_id, None).await.map_err(from_sdk)?;
        let raw = found.raw().deserialize().map_err(|_| BackendError::NotSavable)?;
        let sender = raw.sender().to_owned();
        let sender_name = match target.get_member_no_sync(&sender).await {
            Ok(Some(member)) => member.display_name().map(str::to_owned),
            _ => None,
        }
        .unwrap_or_else(|| sender.to_string());
        let (kind, body, file_name) = saved_content(&raw).ok_or(BackendError::NotSavable)?;
        let message = SavedMessage {
            event: event.clone(),
            room: room.clone(),
            sender_name,
            is_own: sender.as_str() == self.client.user_id().map_or("", |own| own.as_str()),
            body,
            kind,
            file_name,
            date: formats::time(u64::from(raw.origin_server_ts().get())),
            saved_at: SystemTime::now(),
        };
        self.organizer
            .change(change_document(formats::BOOKMARKS, move |content| {
                let added = Bookmark {
                    message: &message,
                    sender: sender.as_str(),
                };
                formats::with_bookmark(content, Some(&added), None)
            }))
            .await
    }

    async fn unsave_message(&self, room: &RoomId, event: &EventId) -> Result<(), BackendError> {
        let (room, event) = (room.clone(), event.clone());
        self.organizer
            .change(change_document(formats::BOOKMARKS, move |content| {
                formats::with_bookmark(content, None, Some((&room, &event)))
            }))
            .await
    }
}

/// What a saved message's row shows of an event: its kind, text or caption, and file name;
/// `None` for an event that is no message (a state change, a deleted or encrypted message).
fn saved_content(event: &AnySyncTimelineEvent) -> Option<(SavedKind, String, String)> {
    use matrix_sdk::ruma::events::{AnyMessageLikeEventContent, AnySyncMessageLikeEvent};
    let AnySyncTimelineEvent::MessageLike(event) = event else {
        return None;
    };
    if matches!(event, AnySyncMessageLikeEvent::RoomEncrypted(_)) {
        return None;
    }
    let caption = |caption: Option<&str>| caption.unwrap_or_default().to_owned();
    Some(match event.original_content()? {
        AnyMessageLikeEventContent::RoomMessage(message) => match &message.msgtype {
            MessageType::Text(text) => (SavedKind::Text, text.body.clone(), String::new()),
            MessageType::Notice(notice) => (SavedKind::Text, notice.body.clone(), String::new()),
            MessageType::Emote(emote) => (SavedKind::Text, emote.body.clone(), String::new()),
            MessageType::Image(image) => (SavedKind::Image, caption(image.caption()), String::new()),
            MessageType::Video(video) => (SavedKind::Video, caption(video.caption()), String::new()),
            MessageType::Audio(audio) if audio.voice.is_some() => {
                (SavedKind::Voice, caption(audio.caption()), String::new())
            }
            MessageType::Audio(audio) => (SavedKind::Audio, caption(audio.caption()), audio.filename().to_owned()),
            MessageType::File(file) => (SavedKind::File, caption(file.caption()), file.filename().to_owned()),
            other => (SavedKind::Other, other.body().to_owned(), String::new()),
        },
        AnyMessageLikeEventContent::Sticker(_) => (SavedKind::Sticker, String::new(), String::new()),
        _ => return None,
    })
}

#[cfg(test)]
mod tests {
    use matrix_sdk::ruma::{room_id, user_id};
    use serde_json::json;

    use super::MentionRule;

    #[test]
    fn a_muted_rooms_mentions_keep_the_apps_rule() {
        let rule = MentionRule::new(room_id!("!a:example.org"), user_id!("@me:example.org"));
        assert_eq!(rule.id, "com.bardav.lux.mention.!a:example.org");
        assert_eq!(
            serde_json::to_value(&rule.conditions).unwrap(),
            json!([
                { "kind": "event_match", "key": "room_id", "pattern": "!a:example.org" },
                { "kind": "event_property_contains", "key": "content.m\\.mentions.user_ids", "value": "@me:example.org" },
            ])
        );
        assert_eq!(
            serde_json::to_value(&rule.actions).unwrap(),
            json!([{ "set_tweak": "highlight" }])
        );
    }
}
