//! A room's bridge state events ([MSC2346]): the network a bridge brings the room from, its
//! bot, and what the room stands for there. Read by the chat list (a room's network) and the
//! spaces (the spaces a bridge made for a login).
//!
//! [MSC2346]: https://github.com/matrix-org/matrix-spec-proposals/pull/2346

use lux_core::bridged_space::BridgeState;
use matrix_sdk::Room;
use matrix_sdk::deserialized_responses::RawAnySyncOrStrippedState;
use matrix_sdk::ruma::api::client::state::get_state_events;
use matrix_sdk::ruma::events::StateEventType;
use serde::Deserialize;
use tracing::warn;

/// The bridge state events' types: the stable one, and the one bridges sent before it.
const BRIDGE_EVENT_TYPES: [&str; 2] = ["m.bridge", "uk.half-shot.bridge"];

/// What a bridge state event's content says.
#[derive(Deserialize)]
struct Content {
    protocol: Option<Id>,
    bridgebot: Option<String>,
    channel: Option<Id>,
    #[serde(rename = "com.beeper.room_type.v2")]
    room_type: Option<String>,
}

#[derive(Deserialize)]
struct Id {
    id: Option<String>,
}

#[derive(Deserialize)]
struct Event {
    content: Content,
}

impl From<Content> for BridgeState {
    fn from(content: Content) -> Self {
        Self {
            protocol: content.protocol.and_then(|protocol| protocol.id),
            bot: content.bridgebot,
            channel: content.channel.and_then(|channel| channel.id),
            room_type: content.room_type,
        }
    }
}

/// The room's bridge state events the store holds, those that read, the stable type's first.
pub(crate) async fn bridge_states(room: &Room) -> Vec<BridgeState> {
    let mut states = Vec::new();
    for event_type in BRIDGE_EVENT_TYPES {
        let Ok(events) = room.get_state_events(StateEventType::from(event_type)).await else {
            continue;
        };
        for event in events {
            let parsed = match event {
                RawAnySyncOrStrippedState::Sync(raw) => raw.deserialize_as_unchecked::<Event>(),
                RawAnySyncOrStrippedState::Stripped(raw) => raw.deserialize_as_unchecked::<Event>(),
            };
            if let Ok(Event { content }) = parsed {
                states.push(content.into());
            }
        }
    }
    states
}

/// The room's bridge state events as the server holds them: a sync brings a space's state
/// without them (the room list asks for none), and only they tell what a bridge's space is.
pub(crate) async fn bridge_states_on_server(room: &Room) -> Vec<BridgeState> {
    let request = get_state_events::v3::Request::new(room.room_id().to_owned());
    let state = match room.client().send(request).await {
        Ok(response) => response.room_state,
        Err(error) => {
            warn!(%error, "a space's state cannot be read from the server");
            return Vec::new();
        }
    };
    let mut states: Vec<(usize, BridgeState)> = state
        .iter()
        .filter_map(|event| {
            let event_type = event.get_field::<String>("type").ok().flatten()?;
            let rank = BRIDGE_EVENT_TYPES.iter().position(|bridge| *bridge == event_type)?;
            let Event { content } = event.deserialize_as_unchecked::<Event>().ok()?;
            Some((rank, content.into()))
        })
        .collect();
    states.sort_by_key(|(rank, _)| *rank);
    states.into_iter().map(|(_, state)| state).collect()
}
