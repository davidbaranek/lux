//! The rooms the sync follows in full while a chat shows them: the room list's sliding sync asks
//! each room of the list for the little state a row needs, and only a room subscription
//! (`RoomListService::set_room_subscriptions`, as Element X makes one for the open room) asks for
//! the rest, its pinned events (`m.room.pinned_events`) among it. The SDK reads a room's state
//! from what the sync asked for, never from its timeline: without the subscription, a pin the
//! user or anyone else makes never reaches the room.

use std::collections::HashMap;
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use matrix_sdk::ruma::{OwnedRoomId, RoomId};
use matrix_sdk_ui::RoomListService;

/// The account's room subscriptions: each room subscribed while something holds it.
#[derive(Clone)]
pub(crate) struct RoomSubscriptions {
    inner: Arc<Inner>,
}

struct Inner {
    service: Arc<RoomListService>,
    /// How many hold each room.
    held: Mutex<HashMap<OwnedRoomId, usize>>,
    /// One change of the subscriptions at a time: each sets those held when it runs.
    setting: tokio::sync::Mutex<()>,
}

/// A room kept subscribed until this is dropped.
pub(crate) struct Subscribed {
    inner: Arc<Inner>,
    room: OwnedRoomId,
}

impl RoomSubscriptions {
    pub(crate) fn new(service: Arc<RoomListService>) -> Self {
        Self {
            inner: Arc::new(Inner {
                service,
                held: Mutex::new(HashMap::new()),
                setting: tokio::sync::Mutex::new(()),
            }),
        }
    }

    /// Subscribes to `room` until the answer is dropped; the sync's next answer brings its state.
    pub(crate) async fn hold(&self, room: &RoomId) -> Subscribed {
        *self.inner.held().entry(room.to_owned()).or_default() += 1;
        // made before the wait: a caller dropped meanwhile lets the room go.
        let subscribed = Subscribed {
            inner: Arc::clone(&self.inner),
            room: room.to_owned(),
        };
        self.inner.apply().await;
        subscribed
    }
}

impl Inner {
    fn held(&self) -> MutexGuard<'_, HashMap<OwnedRoomId, usize>> {
        // the map stays whole whatever a panicking holder did: it only counts.
        self.held.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Sets the subscriptions to the rooms held.
    async fn apply(&self) {
        let _one = self.setting.lock().await;
        let rooms: Vec<OwnedRoomId> = self.held().keys().cloned().collect();
        let ids: Vec<&RoomId> = rooms.iter().map(AsRef::as_ref).collect();
        self.service.set_room_subscriptions(&ids).await;
        // a room let go while the subscriptions were set goes now (its drop found it not yet set).
        let held = self.held();
        let gone: Vec<&RoomId> = ids.into_iter().filter(|room| !held.contains_key(*room)).collect();
        drop(held);
        if !gone.is_empty() {
            self.service.remove_room_subscriptions(&gone);
        }
    }
}

impl Drop for Subscribed {
    fn drop(&mut self) {
        let mut held = self.inner.held();
        let Some(count) = held.get_mut(&self.room) else {
            return;
        };
        *count = count.saturating_sub(1);
        if *count == 0 {
            held.remove(&self.room);
            drop(held);
            self.inner.service.remove_room_subscriptions(&[&self.room]);
        }
    }
}
