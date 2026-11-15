//! What a room's messages shared, read back from the server a page at a time (decrypted by the
//! SDK, so an encrypted room's too: a server cannot filter those by their content), and the
//! media of one such message, which the live timeline may not hold.

use std::collections::{HashMap, HashSet};

use lux_core::ids::{EventId, RoomId};
use lux_core::message;
use lux_core::ports::{BackendError, SharedContent, SharedItem, SharedPage};
use lux_core::timeline::Media;
use matrix_sdk::Room;
use matrix_sdk::room::MessagesOptions;
use matrix_sdk::ruma::events::room::message::{MessageType, Relation};
use matrix_sdk::ruma::events::{AnySyncMessageLikeEvent, AnySyncTimelineEvent, SyncMessageLikeEvent};
use matrix_sdk::ruma::{EventId as SdkEventId, OwnedUserId, UInt};

use super::items::{MediaOf, message_media, message_shown};
use crate::convert::{member_name, system_time};
use crate::errors::from_sdk;

/// How many events a page of the shared history asks the server for.
const PAGE: u32 = 100;

/// One page of `room`'s history back from `from`, with what its messages shared. An edit shares
/// nothing new: its message did, when it was sent.
pub(crate) async fn page(room: &Room, from: Option<&str>) -> Result<SharedPage, BackendError> {
    let mut options = MessagesOptions::backward().from(from);
    options.limit = UInt::from(PAGE);
    let page = room.messages(options).await.map_err(from_sdk)?;
    let room_id = RoomId::from(room.room_id().as_str());
    let mut names = HashMap::<OwnedUserId, String>::new();
    let mut items = Vec::new();
    for event in &page.chunk {
        let Ok(AnySyncTimelineEvent::MessageLike(AnySyncMessageLikeEvent::RoomMessage(
            SyncMessageLikeEvent::Original(event),
        ))) = event.raw().deserialize()
        else {
            continue;
        };
        if matches!(event.content.relates_to, Some(Relation::Replacement(_))) {
            continue;
        }
        let contents = shared(&event.content.msgtype);
        if contents.is_empty() {
            continue;
        }
        if !names.contains_key(&event.sender) {
            let name = member_name(room, &event.sender).await;
            names.insert(event.sender.clone(), name);
        }
        let sender_name = names[&event.sender].clone();
        let event_id = EventId::from(event.event_id.as_str());
        let date = system_time(event.origin_server_ts);
        items.extend(contents.into_iter().map(|content| SharedItem {
            event: event_id.clone(),
            room: room_id.clone(),
            sender_name: sender_name.clone(),
            date,
            content,
        }));
    }
    let next = match page.end {
        Some(end) if !page.chunk.is_empty() => Some(end),
        _ => None,
    };
    Ok(SharedPage { items, next })
}

/// What a message shares: its photo, video or file, and each web address in its text, once
/// (a bridged post's text holds its address twice, as the link and as the caption).
fn shared(message: &MessageType) -> Vec<SharedContent> {
    let shown = message_shown(message);
    let mut shared: Vec<SharedContent> = match shown.media {
        Some(Media::Photo { picture, .. }) => vec![SharedContent::Photo {
            picture,
            caption: shown.body.clone(),
        }],
        Some(Media::Video { poster, duration }) => vec![SharedContent::Video {
            poster,
            duration,
            caption: shown.body.clone(),
        }],
        Some(Media::File {
            name, size, mimetype, ..
        }) => vec![SharedContent::File { name, size, mimetype }],
        None => Vec::new(),
    };
    let mut seen = HashSet::new();
    shared.extend(
        message::links(&shown.body, &shown.styles)
            .into_iter()
            .filter(|link| seen.insert(link.url.clone()))
            .map(|link| SharedContent::Link {
                url: link.url,
                text: shown.body.clone(),
            }),
    );
    shared
}

/// The media of the message of `event` in `room`, from the SDK's event cache or the server.
pub(super) async fn event_media(room: &Room, event: &EventId) -> Result<Option<MediaOf>, BackendError> {
    let id = <&SdkEventId>::try_from(event.as_str()).map_err(|_| BackendError::UnknownMessage)?;
    let event = room.load_or_fetch_event(id, None).await.map_err(from_sdk)?;
    let Ok(AnySyncTimelineEvent::MessageLike(AnySyncMessageLikeEvent::RoomMessage(SyncMessageLikeEvent::Original(
        message,
    )))) = event.raw().deserialize()
    else {
        return Ok(None);
    };
    Ok(message_media(&message.content.msgtype))
}

#[cfg(test)]
mod tests {
    use matrix_sdk::ruma::events::room::message::RoomMessageEventContent;

    use super::*;

    #[test]
    fn a_message_shares_an_address_once_however_often_its_text_holds_it() {
        let url = "https://www.instagram.com/p/abc/";
        let text = RoomMessageEventContent::text_plain(format!("{url}\n\n{url}"));
        assert_eq!(shared(&text.msgtype).len(), 1);
    }

    #[test]
    fn a_text_shares_each_of_its_links_and_a_plain_text_nothing() {
        let text = RoomMessageEventContent::text_plain("see https://example.org and https://lux.chat/a");
        let shared = shared(&text.msgtype);
        let urls: Vec<&str> = shared
            .iter()
            .filter_map(|content| match content {
                SharedContent::Link { url, .. } => Some(url.as_str()),
                _ => None,
            })
            .collect();
        assert_eq!(urls, ["https://example.org", "https://lux.chat/a"]);
        assert!(super::shared(&RoomMessageEventContent::text_plain("hello").msgtype).is_empty());
    }
}
