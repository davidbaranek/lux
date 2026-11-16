//! What a room says besides its live timeline: its history from the server for the search index
//! (text messages with their links and threads, photos and files), and who is typing in it.

use std::collections::HashMap;
use std::time::SystemTime;

use futures_util::stream;
use lux_core::ids::{EventId, MediaId, RoomId, UserId};
use lux_core::message;
use lux_core::ports::{BackendError, TypingStream};
use lux_core::timeline::{FileKind, IndexHistory, IndexedFile, IndexedImage, IndexedMessage, Media, Typist};
use matrix_sdk::Room;
use matrix_sdk::room::MessagesOptions;
use matrix_sdk::ruma::events::room::message::{MessageType, OriginalSyncRoomMessageEvent, Relation};
use matrix_sdk::ruma::events::room::redaction::SyncRoomRedactionEvent;
use matrix_sdk::ruma::events::{AnySyncMessageLikeEvent, AnySyncTimelineEvent, SyncMessageLikeEvent};
use matrix_sdk::ruma::{OwnedEventId, OwnedUserId, UInt, UserId as SdkUserId};
use tokio::sync::broadcast;

use super::items::{indexed_text, message_shown};
use crate::convert::system_time;
use crate::errors::from_sdk;

/// How many events one page of the history asks the server for.
const HISTORY_PAGE: u32 = 100;

/// The room's text messages, photos and files, newest first, back to `since`, its start, the chat's
/// delete (`deleted_until`: none older shows), or `max_pages` pages: each message with its newest
/// text (an edit's), and the messages deleted since they may have been indexed.
pub(crate) async fn index_history(
    room: &Room,
    since: SystemTime,
    deleted_until: Option<SystemTime>,
    mut from: Option<String>,
    max_pages: u32,
) -> Result<IndexHistory, BackendError> {
    let mut reading = Reading {
        own: room.own_user_id().to_owned(),
        room_id: RoomId::from(room.room_id().as_str()),
        names: Names::new(room.clone()),
        history: IndexHistory {
            deleted_until,
            ..IndexHistory::default()
        },
        edited: HashMap::new(),
    };
    for _ in 0..max_pages {
        let page_start = from.clone();
        let mut options = MessagesOptions::backward().from(from.as_deref());
        options.limit = UInt::from(HISTORY_PAGE);
        let page = room.messages(options).await.map_err(from_sdk)?;
        for event in &page.chunk {
            let Ok(AnySyncTimelineEvent::MessageLike(event)) = event.raw().deserialize() else {
                continue;
            };
            let date = system_time(event.origin_server_ts());
            if deleted_until.is_some_and(|cut| date <= cut) {
                return Ok(reading.history);
            }
            if date < since {
                // the page goes on older than asked: a read further back starts at it again.
                reading.history.reached_since = true;
                reading.history.older = page_start;
                return Ok(reading.history);
            }
            match event {
                AnySyncMessageLikeEvent::RoomMessage(SyncMessageLikeEvent::Original(message)) => {
                    reading.take(message, date).await;
                }
                AnySyncMessageLikeEvent::RoomMessage(SyncMessageLikeEvent::Redacted(message)) => {
                    reading.history.removed.push(EventId::from(message.event_id.as_str()));
                }
                AnySyncMessageLikeEvent::RoomRedaction(SyncRoomRedactionEvent::Original(redaction)) => {
                    // the field moved into the content (room version 11); older rooms have it outside.
                    if let Some(redacted) = redaction.content.redacts.as_deref().or(redaction.redacts.as_deref()) {
                        reading.history.removed.push(EventId::from(redacted.as_str()));
                    }
                }
                _ => {}
            }
        }
        match page.end {
            Some(end) if !page.chunk.is_empty() => from = Some(end),
            _ => {
                reading.history.reached_start = true;
                return Ok(reading.history);
            }
        }
    }
    reading.history.older = from;
    Ok(reading.history)
}

/// A history being read for the index: what it found so far.
struct Reading {
    own: OwnedUserId,
    room_id: RoomId,
    names: Names,
    history: IndexHistory,
    /// The messages edited, by the place of their newest text in `history.messages`; the pages
    /// come newest first, so an older edit, and the message itself, find their place taken.
    edited: HashMap<OwnedEventId, usize>,
}

impl Reading {
    /// A message of the history, sent at `date`: a text (with its links and thread), a photo, a
    /// file, or an edit of one.
    async fn take(&mut self, message: OriginalSyncRoomMessageEvent, date: SystemTime) {
        let thread = match &message.content.relates_to {
            Some(Relation::Thread(thread)) => Some(EventId::from(thread.event_id.as_str())),
            _ => None,
        };
        let (event_id, content, is_edit) = if let Some(Relation::Replacement(replacement)) = message.content.relates_to
        {
            if self.edited.contains_key(&replacement.event_id) {
                return;
            }
            (replacement.event_id, replacement.new_content.msgtype, true)
        } else if let Some(newest) = self
            .edited
            .get(&message.event_id)
            .and_then(|&at| self.history.messages.get_mut(at))
        {
            // the edited message: its newest text is kept, dated as the message, in its
            // thread (an edit's relation is the edit's, not the thread's).
            newest.date = date;
            newest.thread = thread;
            return;
        } else {
            (message.event_id, message.content.msgtype, false)
        };
        if let MessageType::Image(image) = &content {
            // a photo's caption edited later keeps its first: the photo is what is found.
            if !is_edit {
                self.history.images.push(IndexedImage {
                    event_id: EventId::from(event_id.as_str()),
                    room: self.room_id.clone(),
                    sender_name: self.names.name(&message.sender).await,
                    caption: image.caption().unwrap_or_default().to_owned(),
                    date,
                    is_own: message.sender == self.own,
                });
            }
            return;
        }
        if let Some((name, size, mimetype)) = file_of(&content) {
            if !is_edit {
                self.history.files.push(IndexedFile {
                    event_id: EventId::from(event_id.as_str()),
                    room: self.room_id.clone(),
                    sender_name: self.names.name(&message.sender).await,
                    name,
                    size,
                    mimetype,
                    date,
                    is_own: message.sender == self.own,
                });
            }
            return;
        }
        let Some(body) = indexed_text(&content) else {
            return;
        };
        if is_edit {
            self.edited.insert(event_id.clone(), self.history.messages.len());
        }
        self.history.messages.push(IndexedMessage {
            event_id: EventId::from(event_id.as_str()),
            room: self.room_id.clone(),
            sender_name: self.names.name(&message.sender).await,
            body: body.to_owned(),
            links: links_of(&content),
            thread,
            date,
            is_own: message.sender == self.own,
        });
    }
}

/// A file's name, size and type, for a file, a sound or a video a message sent (not a voice
/// message: it is heard, not looked for).
fn file_of(content: &MessageType) -> Option<(String, Option<u64>, Option<String>)> {
    if !matches!(
        content,
        MessageType::File(_) | MessageType::Audio(_) | MessageType::Video(_)
    ) {
        return None;
    }
    match message_shown(content).media {
        Some(Media::File {
            name,
            size,
            mimetype,
            kind,
            ..
        }) if kind != FileKind::Voice => Some((name, size, Some(mimetype).filter(|mimetype| !mimetype.is_empty()))),
        _ => None,
    }
}

/// The web addresses a text message sent, each once: a formatted link's too.
fn links_of(content: &MessageType) -> Vec<String> {
    let shown = message_shown(content);
    let mut links: Vec<String> = Vec::new();
    for link in message::links(&shown.body, &shown.styles) {
        if !links.contains(&link.url) {
            links.push(link.url);
        }
    }
    links
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

    async fn profile(&mut self, user: &SdkUserId) -> (String, Option<MediaId>) {
        if let Some(profile) = self.known.get(user) {
            return profile.clone();
        }
        let profile = match self.room.get_member_no_sync(user).await {
            Ok(Some(member)) => (
                member
                    .display_name()
                    .map_or_else(|| user.localpart().to_owned(), str::to_owned),
                member.avatar_url().map(|url| MediaId::from(url.as_str())),
            ),
            _ => (user.localpart().to_owned(), None),
        };
        self.known.insert(user.to_owned(), profile.clone());
        profile
    }

    async fn name(&mut self, user: &SdkUserId) -> String {
        self.profile(user).await.0
    }

    async fn typist(&mut self, user: &SdkUserId) -> Typist {
        let (name, avatar) = self.profile(user).await;
        Typist {
            user: UserId::from(user.as_str()),
            name,
            avatar,
        }
    }
}
