//! The keys of the listed rooms' undecrypted messages, asked for as a timeline does.
//!
//! The SDK asks the key backup for a key only when it decrypts an event again, and the room
//! list has no timeline that asks: the messages a sync brought before the backup opened stay
//! undecrypted, and the room's latest event (its preview and its place in the list) is an
//! older one, until the chat opens. So the list asks the event cache, as a timeline does
//! ([`EventCache::request_decryption`](matrix_sdk::event_cache::EventCache::request_decryption)),
//! when a room is listed and again when the backup opens: each session found undecrypted is
//! tried again in all of the room's events, with the backup. One task asks, apart from the
//! list's, which never waits for it.

use lux_core::gone::OtherEndGone;
use std::collections::{BTreeSet, HashSet};

use futures_util::future;
use futures_util::stream::{self, BoxStream, StreamExt};
use matrix_sdk::deserialized_responses::TimelineEventKind;
use matrix_sdk::event_cache::{DecryptionRetryRequest, RedecryptorReport};
use matrix_sdk::latest_events::LatestEventValue;
use matrix_sdk::ruma::{OwnedRoomId, RoomId};
use matrix_sdk::{Client, Room};
use tokio::sync::mpsc;
use tracing::warn;

/// Asks for the keys of the rooms the list shows.
pub(crate) struct Redecryptor {
    rooms: mpsc::UnboundedSender<OwnedRoomId>,
    _task: crate::task::Owned,
}

impl Redecryptor {
    pub(crate) fn start(client: Client) -> Self {
        let (rooms, listed) = mpsc::unbounded_channel();
        let task = crate::task::spawn(ask(client, listed));
        Self { rooms, _task: task }
    }

    /// The list shows `room` from now on.
    pub(crate) fn listed(&self, room: &RoomId) {
        self.rooms
            .send(room.to_owned())
            .other_end_may_be_gone("the redecryption's task");
    }
}

async fn ask(client: Client, mut listed: mpsc::UnboundedReceiver<OwnedRoomId>) {
    let mut keys_may_be_found = keys_may_be_found(&client);
    let mut rooms = HashSet::new();
    loop {
        tokio::select! {
            room = listed.recv() => {
                let Some(room) = room else { break };
                retry(&client, &room).await;
                rooms.insert(room);
            }
            Some(()) = keys_may_be_found.next() => {
                for room in &rooms {
                    retry(&client, room).await;
                }
            }
        }
    }
}

/// How many events a room that shows no message pages back for the keys of, as a timeline
/// fills its screen.
const PAGE_BACK: u16 = 50;

/// Asks the event cache to decrypt again what it holds undecrypted of `room`. A room whose
/// newest event it can read is no message (the account's join, or nothing) pages back first, as
/// a timeline does (the store's events, then the server's): its messages are undecrypted further
/// back than memory holds.
async fn retry(client: &Client, room: &RoomId) {
    let Some(cache) = client.event_cache() else {
        return;
    };
    let room_events = match cache.room(room).await {
        Ok((room_events, _handles)) => room_events,
        Err(error) => {
            warn!(%error, "a room's events cannot be read");
            return;
        }
    };
    let mut events = match room_events.events().await {
        Ok(events) => events,
        Err(error) => {
            warn!(%error, "a room's events cannot be read");
            return;
        }
    };
    if client.get_room(room).is_some_and(|room| shows_no_message(&room)) {
        match room_events.pagination().run_backwards_until(PAGE_BACK).await {
            Ok(older) => events.extend(older.events),
            Err(error) => warn!(%error, "a room's older events cannot be read"),
        }
    }
    let sessions: BTreeSet<String> = events
        .into_iter()
        .filter_map(|event| match event.kind {
            TimelineEventKind::UnableToDecrypt { utd_info, .. } => utd_info.session_id,
            _ => None,
        })
        .collect();
    if !sessions.is_empty() {
        cache.request_decryption(DecryptionRetryRequest {
            room_id: room.to_owned(),
            utd_session_ids: sessions,
            refresh_info_session_ids: BTreeSet::new(),
        });
    }
}

/// Whether the newest event of `room` the SDK can read is no message: the account's join, or
/// none at all.
fn shows_no_message(room: &Room) -> bool {
    match room.latest_event() {
        LatestEventValue::None => true,
        LatestEventValue::Remote(event) => {
            event.raw().get_field::<String>("type").ok().flatten().as_deref() == Some("m.room.member")
        }
        _ => false,
    }
}

/// Fires when keys may be found where they were not: the key backup opened, or the event
/// cache's reports came faster than read. Never without an event cache.
fn keys_may_be_found(client: &Client) -> BoxStream<'static, ()> {
    match client.event_cache() {
        Some(cache) => cache
            .subscribe_to_decryption_reports()
            .filter_map(|report| {
                future::ready(
                    matches!(
                        report,
                        Ok(RedecryptorReport::BackupAvailable | RedecryptorReport::Lagging) | Err(_)
                    )
                    .then_some(()),
                )
            })
            .boxed(),
        None => stream::pending().boxed(),
    }
}
