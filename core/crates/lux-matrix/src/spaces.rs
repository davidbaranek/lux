//! The spaces the user is in, from `matrix-sdk-ui`'s space service's graph, as
//! [`lux_core::space_graph`] lists them: the top-level spaces and the spaces right inside them.
//!
//! The spaces a bridge made for a login are left out ([`lux_core::bridged_space`]): the
//! network's place holds their chats already.

use std::collections::{HashMap, HashSet};
use std::sync::Arc;

use eyeball_im::Vector;
use futures_util::StreamExt;
use lux_core::bridged_space::SpaceOrigin;
use lux_core::chat::Space;
use lux_core::ids::{MediaId, RoomId};
use lux_core::ports::ValueStream;
use lux_core::space_graph::{SpaceChild, SpaceGraph, SpaceNode};
use matrix_sdk::RoomState;
use matrix_sdk::deserialized_responses::SyncOrStrippedState;
use matrix_sdk::ruma::OwnedRoomId;
use matrix_sdk::ruma::events::SyncStateEvent;
use matrix_sdk::ruma::events::space::child::SpaceChildEventContent;
use matrix_sdk::{Client, Room};
use matrix_sdk_ui::spaces::{SpaceFilter, SpaceService};
use tokio::sync::watch;

use crate::account::MatrixAccount;
use crate::bridge_state::{bridge_states, bridge_states_on_server};
use crate::streams::watched;

impl lux_core::ports::Spaces for MatrixAccount {
    fn spaces(&self) -> ValueStream<Arc<[Space]>> {
        self.spaces.subscribe()
    }
}

/// The spaces, kept by one task.
pub(crate) struct SpaceList {
    spaces: watch::Receiver<Arc<[Space]>>,
    _task: crate::task::Owned,
}

impl SpaceList {
    pub(crate) fn start(client: Client) -> Self {
        let (sender, spaces) = watch::channel(Arc::from(Vec::new()));
        let task = crate::task::spawn(follow(client, sender));
        Self { spaces, _task: task }
    }

    /// The spaces now, then each time they change.
    pub(crate) fn subscribe(&self) -> ValueStream<Arc<[Space]>> {
        watched(self.spaces.clone())
    }
}

async fn follow(client: Client, sender: watch::Sender<Arc<[Space]>>) {
    let service = SpaceService::new(client.clone()).await;
    let (mut filters, mut batches) = service.subscribe_to_space_filters().await;
    // the service builds its graph as the rooms come; read it once now too.
    if filters.is_empty() {
        filters = service.space_filters().await.into_iter().collect();
    }
    let mut origins = Origins::default();
    let graph = read_graph(&client, &service, &filters).await;
    let hidden = origins.left_out(&client, &graph).await;
    sender.send_replace(graph.spaces(&hidden).into());
    while let Some(batch) = batches.next().await {
        for diff in batch {
            diff.apply(&mut filters);
        }
        let graph = read_graph(&client, &service, &filters).await;
        let hidden = origins.left_out(&client, &graph).await;
        let next: Arc<[Space]> = graph.spaces(&hidden).into();
        sender.send_if_modified(|current| {
            let changed = **current != *next;
            if changed {
                *current = Arc::clone(&next);
            }
            changed
        });
    }
}

/// The spaces the user joined and the rooms inside them, as the service's graph links them (it
/// breaks their loops). Its filters stop two levels down, at the top-level spaces of the whole
/// graph: a login space a bridge made would be one, so its servers' categories would be too deep
/// for a filter of their own. The graph is read whole, and [`SpaceGraph::spaces`] decides the
/// levels once the spaces the rail leaves out are gone.
async fn read_graph(client: &Client, service: &SpaceService, filters: &Vector<SpaceFilter>) -> SpaceGraph {
    // every room of the service's graph is in a filter: a top-level space's with its children,
    // an inner one's with all it holds.
    let mut rooms: Vec<OwnedRoomId> = Vec::new();
    for filter in filters {
        for room in std::iter::once(&filter.space_room.room_id).chain(&filter.descendants) {
            if !rooms.contains(room) {
                rooms.push(room.clone());
            }
        }
    }
    let mut parents: HashMap<OwnedRoomId, Vec<OwnedRoomId>> = HashMap::new();
    for room in &rooms {
        parents.insert(room.clone(), service.joined_parent_ids_of_child(room).await);
    }
    let mut nodes = Vec::new();
    for id in &rooms {
        let Some(room) = client
            .get_room(id)
            .filter(|room| room.is_space() && room.state() == RoomState::Joined)
        else {
            continue;
        };
        let Some(space) = service.get_space_room(id).await else {
            continue;
        };
        let placed = placed_children(&room).await;
        let children = rooms
            .iter()
            .filter(|child| parents.get(*child).is_some_and(|of| of.contains(id)))
            .map(|child| {
                let (order, added) = placed.get(child).cloned().unwrap_or_default();
                SpaceChild {
                    id: RoomId::from(child.as_str()),
                    order,
                    added,
                }
            })
            .collect();
        nodes.push(SpaceNode {
            id: RoomId::from(id.as_str()),
            name: space.display_name,
            avatar: space.avatar_url.as_ref().map(|url| MediaId::from(url.as_str())),
            children,
        });
    }
    SpaceGraph::new(nodes)
}

/// Where the space `room` places its children: each one's `order` and when it was added, by its
/// `m.space.child` event.
async fn placed_children(room: &Room) -> HashMap<OwnedRoomId, (Option<String>, Option<u64>)> {
    let events = room
        .get_state_events_static::<SpaceChildEventContent>()
        .await
        .unwrap_or_default();
    events
        .into_iter()
        .filter_map(|event| match event.deserialize() {
            Ok(SyncOrStrippedState::Sync(SyncStateEvent::Original(event))) => Some((
                event.state_key,
                (
                    event.content.order.map(|order| order.as_str().to_owned()),
                    Some(u64::from(event.origin_server_ts.get())),
                ),
            )),
            Ok(SyncOrStrippedState::Stripped(event)) => Some((
                event.state_key,
                (event.content.order.map(|order| order.as_str().to_owned()), None),
            )),
            Ok(SyncOrStrippedState::Sync(SyncStateEvent::Redacted(_))) | Err(_) => None,
        })
        .collect()
}

/// Which spaces a bridge made for a login, remembered per space: who made a space and its
/// bridge state do not change. Only a space whose creator's name says nothing is decided by the
/// bridges' bots its chats name, again when its chats change.
#[derive(Default)]
struct Origins {
    decided: HashMap<RoomId, Decision>,
}

/// Whether a space is a login's, and on which of its chats that was decided, if on any.
struct Decision {
    login_space: bool,
    by_chats: Option<Vec<RoomId>>,
}

impl Origins {
    /// The joined spaces of `graph` that a bridge made for a login, which the rail leaves out.
    async fn left_out(&mut self, client: &Client, graph: &SpaceGraph) -> HashSet<RoomId> {
        let mut hidden = HashSet::new();
        let none = HashSet::new();
        for id in graph.ids() {
            let chats = graph.descendants(id, &none);
            let known = self
                .decided
                .get(id)
                .filter(|decision| decision.by_chats.as_ref().is_none_or(|by| *by == chats));
            let login_space = if let Some(decision) = known {
                decision.login_space
            } else {
                let Some(room) = OwnedRoomId::try_from(id.as_str())
                    .ok()
                    .and_then(|id| client.get_room(&id))
                else {
                    continue;
                };
                // not known before its creation event is: decided once it is.
                let Some(decision) = decide(client, &room, chats).await else {
                    continue;
                };
                let login_space = decision.login_space;
                self.decided.insert(id.clone(), decision);
                login_space
            };
            if login_space {
                hidden.insert(id.clone());
            }
        }
        self.decided.retain(|id, _| graph.ids().any(|known| known == id));
        hidden
    }
}

/// Whether the space `room`, with the chats `chats`, is the one a bridge made for a login;
/// `None` while its creation event is unknown.
async fn decide(client: &Client, room: &Room, chats: Vec<RoomId>) -> Option<Decision> {
    let creators: Vec<String> = room.creators()?.iter().map(ToString::to_string).collect();
    let own = client.user_id();
    let once = |login_space| {
        Some(Decision {
            login_space,
            by_chats: None,
        })
    };
    if own.is_some_and(|own| creators.iter().any(|creator| creator == own.as_str())) {
        return once(false);
    }
    let members: Vec<String> = room
        .joined_user_ids()
        .await
        .unwrap_or_default()
        .iter()
        .filter(|member| Some(member.as_ref()) != own)
        .map(ToString::to_string)
        .collect();
    let mut states = bridge_states(room).await;
    if states.is_empty() {
        states = bridge_states_on_server(room).await;
    }
    let origin = SpaceOrigin {
        creators: &creators,
        members: &members,
        bridge_states: &states,
    };
    if !origin.needs_bots() {
        return once(origin.is_login_space(&[]));
    }
    // the bots its chats name.
    let mut bots = Vec::new();
    let rooms = chats
        .iter()
        .filter_map(|chat| OwnedRoomId::try_from(chat.as_str()).ok())
        .filter_map(|chat| client.get_room(&chat));
    for chat in rooms {
        bots.extend(bridge_states(&chat).await.into_iter().filter_map(|state| state.bot));
    }
    let bots: Vec<&str> = bots.iter().map(String::as_str).collect();
    Some(Decision {
        login_space: origin.is_login_space(&bots),
        by_chats: Some(chats),
    })
}
