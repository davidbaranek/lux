//! A room's pinned messages (`m.room.pinned_events`), as the SDK keeps them: their events,
//! read from the event cache or the server once each, whether the user's power level lets them
//! pin, and which the user has seen: Element's `im.vector.room.read_pins` room account data
//! (`{"event_ids": [...]}`), so every client of the account agrees on what is new.

use futures_util::{StreamExt, stream};
use lux_core::ids::{EventId, RoomId};
use lux_core::ports::{BackendError, PinsStream};
use lux_core::preview::PreviewKind;
use lux_core::timeline::{PinnedMessage, Pins};
use matrix_sdk::Room;
use matrix_sdk::ruma::OwnedEventId;
use matrix_sdk::ruma::events::{RoomAccountDataEventType, StateEventType};
use matrix_sdk::ruma::serde::Raw;
use tokio::sync::broadcast;

use super::threads::participant;
use crate::convert::system_time;
use crate::errors::from_sdk;
use crate::mapping::event_kind;

/// The room account data that holds the pinned events the user has seen.
const READ_PINS: &str = "im.vector.room.read_pins";

/// What the room's state and account data say of its pins: cheap to read, so compared first.
#[derive(Clone, PartialEq, Eq)]
struct Said {
    events: Vec<OwnedEventId>,
    may_pin: bool,
    seen: Vec<EventId>,
}

/// The room's pins, now and each time a sync brings the room a change of them (the pinned
/// events, who may pin, or what the user has seen). A sync brings the room every message: only
/// a change of what its state and account data say reads the events again.
pub(super) fn pins(room: Room) -> PinsStream {
    let updates = room.client().subscribe_to_all_room_updates();
    let asked = room.clone();
    Box::pin(
        stream::unfold((updates, true), move |(mut updates, first)| {
            let room = asked.clone();
            async move {
                if !first {
                    loop {
                        match updates.recv().await {
                            Ok(update) if update.iter_all_room_ids().any(|id| id == room.room_id()) => break,
                            Ok(_) | Err(broadcast::error::RecvError::Lagged(_)) => {}
                            Err(broadcast::error::RecvError::Closed) => return None,
                        }
                    }
                }
                Some((said(&room).await, (updates, false)))
            }
        })
        .scan(None, |last: &mut Option<Said>, next| {
            let new = last.as_ref() != Some(&next);
            *last = Some(next.clone());
            std::future::ready(Some(new.then_some(next)))
        })
        .filter_map(std::future::ready)
        .then(move |said| {
            let room = room.clone();
            async move {
                Pins {
                    messages: messages(&room, &said.events).await,
                    may_pin: said.may_pin,
                    seen: said.seen,
                }
            }
        }),
    )
}

async fn said(room: &Room) -> Said {
    Said {
        events: room.pinned_event_ids().unwrap_or_default(),
        may_pin: may_pin(room).await,
        seen: seen(room).await,
    }
}

/// The pinned events the user has seen, as the room's account data keeps them.
async fn seen(room: &Room) -> Vec<EventId> {
    let Ok(Some(raw)) = room.account_data(RoomAccountDataEventType::from(READ_PINS)).await else {
        return Vec::new();
    };
    let Ok(Some(content)) = raw.get_field::<ReadPins>("content") else {
        return Vec::new();
    };
    content.event_ids.iter().map(|id| EventId::from(id.as_str())).collect()
}

/// Keeps `events` as the pinned events the user has seen.
pub(super) async fn mark_seen(room: &Room, events: &[EventId]) -> Result<(), BackendError> {
    let content = ReadPins {
        event_ids: events.iter().map(ToString::to_string).collect(),
    };
    let raw = Raw::new(&content).map_err(BackendError::refused)?.cast_unchecked();
    room.set_account_data_raw(RoomAccountDataEventType::from(READ_PINS), raw)
        .await
        .map_err(from_sdk)?;
    Ok(())
}

/// `im.vector.room.read_pins`'s content.
#[derive(serde::Serialize, serde::Deserialize)]
struct ReadPins {
    event_ids: Vec<String>,
}

/// Whether the user's power level lets them change the room's pins.
async fn may_pin(room: &Room) -> bool {
    room.power_levels_or_default()
        .await
        .user_can_send_state(room.own_user_id(), StateEventType::RoomPinnedEvents)
}

/// The pinned messages of `events`, in their order.
async fn messages(room: &Room, events: &[OwnedEventId]) -> Vec<PinnedMessage> {
    let mut messages = Vec::with_capacity(events.len());
    for id in events {
        // one the account cannot read (gone, or before it joined) is left out.
        let Ok(event) = room.load_or_fetch_event(id, None).await else {
            continue;
        };
        let Ok(event) = event.raw().deserialize() else {
            continue;
        };
        messages.push(PinnedMessage {
            room: RoomId::from(room.room_id().as_str()),
            event: EventId::from(id.as_str()),
            sender: participant(room, event.sender()).await,
            kind: event_kind(&event).unwrap_or(PreviewKind::Other),
            date: system_time(event.origin_server_ts()),
        });
    }
    messages
}
