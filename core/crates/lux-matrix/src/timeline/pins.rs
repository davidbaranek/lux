//! A room's pinned messages (`m.room.pinned_events`), as the SDK keeps them: their events,
//! read from the event cache or the server once each, and whether the user's power level lets
//! them pin.

use futures_util::{StreamExt, stream};
use lux_core::ids::{EventId, RoomId};
use lux_core::ports::PinsStream;
use lux_core::preview::PreviewKind;
use lux_core::timeline::{PinnedMessage, Pins};
use matrix_sdk::Room;
use matrix_sdk::ruma::OwnedEventId;
use matrix_sdk::ruma::events::StateEventType;

use super::threads::participant;
use crate::convert::system_time;
use crate::mapping::event_kind;

/// The room's pins, now and each time they change (the pinned events, or who may pin). The
/// room's info changes with every message: only a change of the events or the right reads them.
pub(super) fn pins(room: Room) -> PinsStream {
    let updates = room.pinned_event_ids_stream();
    let now = room.pinned_event_ids().unwrap_or_default();
    let asked = room.clone();
    Box::pin(
        stream::once(std::future::ready(now))
            .chain(updates)
            .then(move |events| {
                let room = asked.clone();
                async move { (events, may_pin(&room).await) }
            })
            .scan(None, |last: &mut Option<(Vec<OwnedEventId>, bool)>, next| {
                let new = last.as_ref() != Some(&next);
                *last = Some(next.clone());
                std::future::ready(Some(new.then_some(next)))
            })
            .filter_map(std::future::ready)
            .then(move |(events, may_pin)| {
                let room = room.clone();
                async move {
                    Pins {
                        messages: messages(&room, &events).await,
                        may_pin,
                    }
                }
            }),
    )
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
