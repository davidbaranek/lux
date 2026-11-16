//! A group's members, for its pictures and its preview's sender in the chat list: a sync names
//! only the members of the events it brings (lazy loading), so on a new device a group shows no
//! pictures, and its newest message's sender by their id, until its chat opens. One task loads them, a room at a time, each once; the room
//! then changes and the room list maps it again.

use lux_core::gone::OtherEndGone;
use std::collections::HashSet;

use matrix_sdk::ruma::OwnedRoomId;
use matrix_sdk::{Client, Room};
use tokio::sync::mpsc;
use tokio::task::JoinHandle;
use tracing::warn;

/// Loads the members of the groups the list asks for, one room at a time, each once.
pub(crate) struct MemberLoader {
    rooms: mpsc::UnboundedSender<OwnedRoomId>,
    task: JoinHandle<()>,
}

impl MemberLoader {
    pub(crate) fn start(client: Client) -> Self {
        let (rooms, asked) = mpsc::unbounded_channel();
        let task = tokio::spawn(load_members(client, asked));
        Self { rooms, task }
    }

    /// Loads `room`'s members unless this device has them.
    pub(crate) fn load(&self, room: &Room) {
        if !room.are_members_synced() {
            self.rooms
                .send(room.room_id().to_owned())
                .other_end_may_be_gone("the members' task");
        }
    }
}

impl Drop for MemberLoader {
    fn drop(&mut self) {
        self.task.abort();
    }
}

async fn load_members(client: Client, mut asked: mpsc::UnboundedReceiver<OwnedRoomId>) {
    // a room whose members failed to load is tried again on the next launch.
    let mut loaded = HashSet::new();
    while let Some(room) = asked.recv().await {
        if !loaded.insert(room.clone()) {
            continue;
        }
        let Some(room) = client.get_room(&room) else {
            continue;
        };
        if let Err(error) = room.sync_members().await {
            warn!(%error, "a group's members could not be loaded");
        }
    }
}
