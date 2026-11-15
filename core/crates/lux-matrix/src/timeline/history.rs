//! What a room says besides its live timeline: its history from the server for the search index
//! (text messages and photos), and who is typing in it.

use std::collections::HashMap;
use std::time::SystemTime;

use futures_util::stream;
use lux_core::ids::{EventId, MediaId, RoomId, UserId};
use lux_core::ports::{BackendError, TypingStream};
use lux_core::timeline::{IndexHistory, IndexedImage, IndexedMessage, Typist};
use matrix_sdk::Room;
use matrix_sdk::room::MessagesOptions;
use matrix_sdk::ruma::events::room::message::{MessageType, Relation};
use matrix_sdk::ruma::events::room::redaction::SyncRoomRedactionEvent;
use matrix_sdk::ruma::events::{AnySyncMessageLikeEvent, AnySyncTimelineEvent, SyncMessageLikeEvent};
use matrix_sdk::ruma::{OwnedEventId, OwnedUserId, UInt, UserId as SdkUserId};
use tokio::sync::broadcast;

use super::items::indexed_text;
use crate::convert::system_time;
use crate::errors::from_sdk;

/// How many events one page of the history asks the server for.
const HISTORY_PAGE: u32 = 100;

/// The room's text messages and photos, newest first, back to `since`, its start, the chat's
/// delete (`deleted_until`: none older shows), or `max_pages` pages: each message with its newest
/// text (an edit's), and the messages deleted since they may have been indexed.
pub(crate) async fn index_history(
    room: &Room,
    since: SystemTime,
    deleted_until: Option<SystemTime>,
    max_pages: u32,
) -> Result<IndexHistory, BackendError> {
    let own = room.own_user_id().to_owned();
    let room_id = RoomId::from(room.room_id().as_str());
    let mut names = Names::new(room.clone());
    let mut history = IndexHistory {
        deleted_until,
        ..IndexHistory::default()
    };
    // the messages edited, by the place of their newest text in `history.messages`; the pages
    // come newest first, so an older edit, and the message itself, find their place taken.
    let mut edited = HashMap::<OwnedEventId, usize>::new();
    let mut from: Option<String> = None;
    for _ in 0..max_pages {
        let mut options = MessagesOptions::backward().from(from.as_deref());
        options.limit = UInt::from(HISTORY_PAGE);
        let page = room.messages(options).await.map_err(from_sdk)?;
        for event in &page.chunk {
            let Ok(AnySyncTimelineEvent::MessageLike(event)) = event.raw().deserialize() else {
                continue;
            };
            let date = system_time(event.origin_server_ts());
            if date < since || deleted_until.is_some_and(|cut| date <= cut) {
                return Ok(history);
            }
            let message = match event {
                AnySyncMessageLikeEvent::RoomMessage(SyncMessageLikeEvent::Original(message)) => message,
                AnySyncMessageLikeEvent::RoomMessage(SyncMessageLikeEvent::Redacted(message)) => {
                    history.removed.push(EventId::from(message.event_id.as_str()));
                    continue;
                }
                AnySyncMessageLikeEvent::RoomRedaction(SyncRoomRedactionEvent::Original(redaction)) => {
                    // the field moved into the content (room version 11); older rooms have it outside.
                    if let Some(redacted) = redaction.content.redacts.as_deref().or(redaction.redacts.as_deref()) {
                        history.removed.push(EventId::from(redacted.as_str()));
                    }
                    continue;
                }
                _ => continue,
            };
            let (event_id, content, is_edit) =
                if let Some(Relation::Replacement(replacement)) = message.content.relates_to {
                    if edited.contains_key(&replacement.event_id) {
                        continue;
                    }
                    (replacement.event_id, replacement.new_content.msgtype, true)
                } else if let Some(newest) = edited
                    .get(&message.event_id)
                    .and_then(|&at| history.messages.get_mut(at))
                {
                    // the edited message: its newest text is kept, dated as the message.
                    newest.date = date;
                    continue;
                } else {
                    (message.event_id, message.content.msgtype, false)
                };
            if let MessageType::Image(image) = &content {
                // a photo's caption edited later keeps its first: the photo is what is found.
                if !is_edit {
                    history.images.push(IndexedImage {
                        event_id: EventId::from(event_id.as_str()),
                        room: room_id.clone(),
                        sender_name: names.name(&message.sender).await,
                        caption: image.caption().unwrap_or_default().to_owned(),
                        date,
                        is_own: message.sender == own,
                    });
                }
                continue;
            }
            let Some(body) = indexed_text(&content) else {
                continue;
            };
            if is_edit {
                edited.insert(event_id.clone(), history.messages.len());
            }
            history.messages.push(IndexedMessage {
                event_id: EventId::from(event_id.as_str()),
                room: room_id.clone(),
                sender_name: names.name(&message.sender).await,
                body: body.to_owned(),
                date,
                is_own: message.sender == own,
            });
        }
        match page.end {
            Some(end) if !page.chunk.is_empty() => from = Some(end),
            _ => {
                history.reached_start = true;
                break;
            }
        }
    }
    Ok(history)
}

/// Who else is typing in the room, each time it changes.
pub(crate) fn typing(room: Room) -> TypingStream {
    let (guard, receiver) = room.subscribe_to_typing_notifications();
    let names = Names::new(room);
    Box::pin(stream::unfold(
        (guard, receiver, names),
        |(guard, mut receiver, mut names)| async move {
            loop {
                match receiver.recv().await {
                    Ok(users) => {
                        let mut typists = Vec::with_capacity(users.len());
                        for user in &users {
                            typists.push(names.typist(user).await);
                        }
                        return Some((typists, (guard, receiver, names)));
                    }
                    Err(broadcast::error::RecvError::Lagged(_)) => {}
                    Err(broadcast::error::RecvError::Closed) => return None,
                }
            }
        },
    ))
}

/// The room's members' names and pictures, looked up once each.
struct Names {
    room: Room,
    known: HashMap<OwnedUserId, (String, Option<MediaId>)>,
}

impl Names {
    fn new(room: Room) -> Self {
        Self {
            room,
            known: HashMap::new(),
        }
    }

    async fn profile(&mut self, user: &SdkUserId) -> &(String, Option<MediaId>) {
        if !self.known.contains_key(user) {
            let profile = match self.room.get_member_no_sync(user).await {
                Ok(Some(member)) => (
                    member
                        .display_name()
                        .map_or_else(|| user.localpart().to_owned(), str::to_owned),
                    member.avatar_url().map(|url| MediaId::from(url.as_str())),
                ),
                _ => (user.localpart().to_owned(), None),
            };
            self.known.insert(user.to_owned(), profile);
        }
        &self.known[user]
    }

    async fn name(&mut self, user: &SdkUserId) -> String {
        self.profile(user).await.0.clone()
    }

    async fn typist(&mut self, user: &SdkUserId) -> Typist {
        let (name, avatar) = self.profile(user).await.clone();
        Typist {
            user: UserId::from(user.as_str()),
            name,
            avatar,
        }
    }
}
