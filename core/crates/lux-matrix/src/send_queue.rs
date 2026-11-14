//! Keeps the rooms' send queues sending.
//!
//! A request that fails for a passing reason (no network, a server error) turns its room's queue
//! off, and the SDK leaves it off: every later message in that room would wait for a relaunch.
//! [`QueueKeeper`] turns such a queue on again when the sync runs again, or a moment later when
//! the sync never stopped (only the send failed).

use std::collections::HashSet;
use std::time::Duration;

use eyeball::Subscriber;
use matrix_sdk::Client;
use matrix_sdk::ruma::OwnedRoomId;
use matrix_sdk_ui::sync_service::State;
use tokio::sync::broadcast::error::RecvError;
use tokio::task::JoinHandle;
use tokio::time::{Instant, sleep_until};
use tracing::debug;

/// How long a room's queue stays off after a passing failure while the sync runs.
const RETRY_AFTER: Duration = Duration::from_secs(5);

/// The task that turns the rooms' send queues on again; it ends when this goes.
pub(crate) struct QueueKeeper {
    task: JoinHandle<()>,
}

impl QueueKeeper {
    /// Starts keeping `client`'s queues sending, by the sync's `states`.
    pub(crate) fn start(client: Client, states: Subscriber<State>) -> Self {
        Self {
            task: tokio::spawn(keep_sending(client, states)),
        }
    }
}

impl Drop for QueueKeeper {
    fn drop(&mut self) {
        self.task.abort();
    }
}

async fn keep_sending(client: Client, mut states: Subscriber<State>) {
    let queue = client.send_queue();
    let mut errors = queue.subscribe_errors();
    // the rooms whose queue a passing failure turned off, and when to try them again.
    let mut stopped = HashSet::<OwnedRoomId>::new();
    let mut retry: Option<Instant> = None;
    // errors were missed: which rooms stopped is unknown, so all are turned on.
    let mut missed = false;
    loop {
        let due = tokio::select! {
            error = errors.recv() => {
                match error {
                    Ok(error) if error.is_recoverable => {
                        stopped.insert(error.room_id);
                    }
                    Ok(_) => continue,
                    Err(RecvError::Lagged(_)) => missed = true,
                    Err(RecvError::Closed) => return,
                }
                retry.get_or_insert_with(|| Instant::now() + RETRY_AFTER);
                false
            }
            state = states.next() => match state {
                Some(State::Running) => true,
                Some(_) => false,
                None => return,
            },
            () = sleep_until(retry.unwrap_or_else(Instant::now)), if retry.is_some() => {
                retry = None;
                // offline, the queues wait for the sync to run again.
                matches!(states.get(), State::Running)
            }
        };
        if !due || (stopped.is_empty() && !missed) {
            continue;
        }
        retry = None;
        if std::mem::take(&mut missed) {
            stopped.clear();
            queue.set_enabled(true).await;
        } else {
            for room in stopped.drain().filter_map(|id| client.get_room(&id)) {
                debug!(room = %room.room_id(), "sending again");
                room.send_queue().set_enabled(true);
            }
        }
    }
}
