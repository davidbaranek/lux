//! The spaces the user is in, from `matrix-sdk-ui`'s space service: its filters are the
//! top-level spaces (with their direct children) and the spaces inside them (with all their
//! descendants). A top-level space's chats are its children's and its inner spaces'; an inner
//! space names the top-level ones it is in as its parents.
//!
//! The spaces a bridge made for a login are left out ([`lux_core::bridged_space`]): the
//! network's place holds their chats already.

use std::collections::{HashMap, HashSet};
use std::sync::Arc;

use eyeball_im::Vector;
use futures_util::StreamExt;
use lux_core::bridged_space::SpaceOrigin;
use lux_core::chat::Space;
use lux_core::ids::{ChatId, MediaId, RoomId};
use lux_core::ports::ValueStream;
use matrix_sdk::RoomState;
use matrix_sdk::ruma::OwnedRoomId;
use matrix_sdk::{Client, Room};
use matrix_sdk_ui::spaces::{SpaceFilter, SpaceService};
use tokio::sync::watch;
use tokio::task::JoinHandle;

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
    task: JoinHandle<()>,
}

impl SpaceList {
    pub(crate) fn start(client: Client) -> Self {
        let (sender, spaces) = watch::channel(Arc::from(Vec::new()));
        let task = tokio::spawn(follow(client, sender));
        Self { spaces, task }
    }

    /// The spaces now, then each time they change.
    pub(crate) fn subscribe(&self) -> ValueStream<Arc<[Space]>> {
        watched(self.spaces.clone())
    }
}

impl Drop for SpaceList {
    fn drop(&mut self) {
        self.task.abort();
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
    let hidden = origins.left_out(&client, &filters).await;
    sender.send_replace(spaces(&filters, &hidden));
    while let Some(batch) = batches.next().await {
        for diff in batch {
            diff.apply(&mut filters);
        }
        let hidden = origins.left_out(&client, &filters).await;
        let next = spaces(&filters, &hidden);
        sender.send_if_modified(|current| {
            let changed = **current != *next;
            if changed {
                *current = Arc::clone(&next);
            }
            changed
        });
    }
}

/// Which spaces a bridge made for a login, remembered per space: who made a space and its
/// bridge state do not change. Only a space whose creator's name says nothing is decided by the
/// bridges' bots its chats name, again when its chats change.
#[derive(Default)]
struct Origins {
    decided: HashMap<OwnedRoomId, Decision>,
}

/// Whether a space is a login's, and on which of its chats that was decided, if on any.
struct Decision {
    login_space: bool,
    by_chats: Option<Vec<OwnedRoomId>>,
}

impl Origins {
    /// The spaces of `filters` the rail leaves out: those the account is not in (a space lists
    /// its children whether the account joined them or left them), and those a bridge made for
    /// a login.
    async fn left_out(&mut self, client: &Client, filters: &Vector<SpaceFilter>) -> HashSet<OwnedRoomId> {
        let mut hidden = HashSet::new();
        for filter in filters {
            let id = &filter.space_room.room_id;
            if client.get_room(id).is_none_or(|room| room.state() != RoomState::Joined) {
                hidden.insert(id.clone());
                continue;
            }
            let known = self.decided.get(id).filter(|decision| {
                decision
                    .by_chats
                    .as_ref()
                    .is_none_or(|chats| *chats == filter.descendants)
            });
            let login_space = if let Some(decision) = known {
                decision.login_space
            } else {
                let Some(room) = client.get_room(id) else {
                    continue;
                };
                // not known before its creation event is: decided once it is.
                let Some(decision) = decide(client, &room, &filter.descendants).await else {
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
        self.decided
            .retain(|id, _| filters.iter().any(|filter| filter.space_room.room_id == *id));
        hidden
    }
}

/// Whether the space `room`, with the chats `chats`, is the one a bridge made for a login;
/// `None` while its creation event is unknown.
async fn decide(client: &Client, room: &Room, chats: &[OwnedRoomId]) -> Option<Decision> {
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
    for chat in chats.iter().filter_map(|chat| client.get_room(chat)) {
        bots.extend(bridge_states(&chat).await.into_iter().filter_map(|state| state.bot));
    }
    let bots: Vec<&str> = bots.iter().map(String::as_str).collect();
    Some(Decision {
        login_space: origin.is_login_space(&bots),
        by_chats: Some(chats.to_vec()),
    })
}

/// The spaces of the service's filters, but those in `hidden`.
fn spaces(filters: &Vector<SpaceFilter>, hidden: &HashSet<OwnedRoomId>) -> Arc<[Space]> {
    let id = |filter: &SpaceFilter| RoomId::from(filter.space_room.room_id.as_str());
    let shown = |filter: &&SpaceFilter| !hidden.contains(&filter.space_room.room_id);
    let inner: Vec<&SpaceFilter> = filters.iter().filter(shown).filter(|filter| filter.level > 0).collect();
    filters
        .iter()
        .filter(shown)
        .map(|filter| {
            let mut chats: HashSet<ChatId> = filter
                .descendants
                .iter()
                .map(|room| ChatId::from(room.as_str()))
                .collect();
            let parents = if filter.level == 0 {
                for space in &inner {
                    if filter.descendants.contains(&space.space_room.room_id) {
                        chats.extend(space.descendants.iter().map(|room| ChatId::from(room.as_str())));
                    }
                }
                Vec::new()
            } else {
                filters
                    .iter()
                    .filter(shown)
                    .filter(|top| top.level == 0 && top.descendants.contains(&filter.space_room.room_id))
                    .map(id)
                    .collect()
            };
            Space {
                id: id(filter),
                name: filter.space_room.display_name.clone(),
                avatar: filter
                    .space_room
                    .avatar_url
                    .as_ref()
                    .map(|url| MediaId::from(url.as_str())),
                chats,
                parents,
            }
        })
        // the service lists a space once for each place it has in the graph (under each of its
        // parents): the rail shows it once, with all its chats and parents.
        .fold(Vec::<Space>::new(), |mut spaces, space| {
            if let Some(known) = spaces.iter_mut().find(|known| known.id == space.id) {
                known.chats.extend(space.chats);
                for parent in space.parents {
                    if !known.parents.contains(&parent) {
                        known.parents.push(parent);
                    }
                }
            } else {
                spaces.push(space);
            }
            spaces
        })
        .into()
}
