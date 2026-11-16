//! Where the app is, for the sync and the stores: one task owns the sync service and the
//! stores' state, and takes the account's commands in turn.
//!
//! In the background (iOS) the sync stops and the stores close, the SDK's and the account's own:
//! iOS ends an app that holds a lock on a file in the App Group's container when it suspends it
//! (`0xdead10cc`). A background refresh, or a notification's action, opens them again for its
//! time. Each command runs to its end before the next, so a refresh's opening and start cannot
//! be split by a pause, and a caller that gives up waiting never leaves them half-way.

use lux_core::gone::OtherEndGone;
use std::sync::Arc;
use std::time::Duration;

use eyeball::Subscriber;
use lux_store::Store;
use matrix_sdk::Client;
use matrix_sdk_ui::room_list_service::State as ListState;
use matrix_sdk_ui::sync_service::{State as SyncState, SyncService};
use tokio::sync::{mpsc, oneshot};
use tracing::warn;

use crate::room_list::Flush;

/// What the account asks of the lifecycle's task.
enum Command {
    /// The app came to the front: the stores open, the sync runs.
    Foreground(oneshot::Sender<()>),
    /// The app went to the background: the sync stops, the lists are kept, the stores close.
    Background(oneshot::Sender<()>),
    /// Work in the background begins: the stores open, if they are closed.
    BeginWork(oneshot::Sender<()>),
    /// A background refresh begins: the stores open and the sync starts.
    BeginRefresh(oneshot::Sender<Refreshing>),
    /// Work in the background ends: as [`Command::Background`], unless the app is in front.
    EndWork(oneshot::Sender<()>),
    /// The account signs out: the sync stops.
    Stop(oneshot::Sender<()>),
}

/// A refresh's sync, from its start: whether the server answers, or the sync stops first.
struct Refreshing {
    /// The room list's state, from just before the start.
    answers: Subscriber<ListState>,
    /// The sync service's state, from just after the start.
    sync: Subscriber<SyncState>,
}

impl Refreshing {
    /// Whether the server answers before the sync fails or stops (the app went to the
    /// background meanwhile).
    async fn answered(mut self) -> bool {
        loop {
            tokio::select! {
                biased;
                // the room list's state changes only when a response came or the sync failed:
                // the first change after the start is the server's answer.
                state = self.answers.next() => {
                    return !matches!(state, Some(ListState::Error { .. } | ListState::Terminated { .. }) | None);
                }
                state = self.sync.next() => match state {
                    Some(SyncState::Running | SyncState::Offline) => {}
                    Some(SyncState::Idle | SyncState::Terminated | SyncState::Error(_)) | None => return false,
                },
            }
        }
    }
}

/// The account's handle on its lifecycle's task. The task ends once this drops, after the
/// command at hand.
pub(crate) struct Lifecycle {
    commands: mpsc::UnboundedSender<Command>,
}

impl Lifecycle {
    /// Starts the task over the started `sync`; `flush` writes the kept chat list, `store` is
    /// the account's own store.
    pub(crate) fn start(client: Client, sync: SyncService, store: Option<Arc<Store>>, flush: Option<Flush>) -> Self {
        let (commands, received) = mpsc::unbounded_channel();
        let owner = Owner {
            client,
            sync,
            store,
            flush,
            foreground: true,
            paused: false,
        };
        tokio::spawn(owner.run(received));
        Self { commands }
    }

    /// The app went to the background.
    pub(crate) async fn pause(&self) {
        self.ask(Command::Background).await;
    }

    /// The app came to the front.
    pub(crate) async fn resume(&self) {
        self.ask(Command::Foreground).await;
    }

    /// Opens the stores for work in the background (a notification's action), if they are
    /// closed. The app pauses the account again when the work is done.
    pub(crate) async fn begin_background_work(&self) {
        self.ask(Command::BeginWork).await;
    }

    /// Stops the sync (signing out).
    pub(crate) async fn stop(&self) {
        self.ask(Command::Stop).await;
    }

    /// A background refresh: syncs until the server has answered once, at most `within`, then
    /// stops as [`pause`](Self::pause) does, unless the app came to the front meanwhile. True
    /// when the server answered. Dropped before its end, it stops all the same.
    pub(crate) async fn refresh_within(&self, within: Duration) -> bool {
        let (reply, states) = oneshot::channel();
        if self.commands.send(Command::BeginRefresh(reply)).is_err() {
            return false;
        }
        // dropped before this, the task ends the refresh itself (its reply finds no one).
        let Ok(refreshing) = states.await else {
            return false;
        };
        let end = RefreshEnd {
            commands: Some(self.commands.clone()),
        };
        // only the wait is bounded: the task leaves the stores and the sync whole.
        let answered = tokio::time::timeout(within, refreshing.answered())
            .await
            .unwrap_or(false);
        end.wait().await;
        answered
    }

    /// Sends a command and waits until the task has carried it out.
    async fn ask(&self, command: impl FnOnce(oneshot::Sender<()>) -> Command) {
        let (reply, done) = oneshot::channel();
        if self.commands.send(command(reply)).is_ok() {
            done.await.other_end_may_be_gone("the caller");
        }
    }
}

/// A started refresh's end: sent when the refresh ends, or when its future is dropped first.
struct RefreshEnd {
    /// `None` once sent.
    commands: Option<mpsc::UnboundedSender<Command>>,
}

impl RefreshEnd {
    /// Ends the refresh and waits until the task has carried it out.
    async fn wait(mut self) {
        let Some(commands) = self.commands.take() else { return };
        let (reply, done) = oneshot::channel();
        if commands.send(Command::EndWork(reply)).is_ok() {
            done.await.other_end_may_be_gone("the caller");
        }
    }
}

impl Drop for RefreshEnd {
    fn drop(&mut self) {
        if let Some(commands) = self.commands.take() {
            // no one waits for it: the task carries it out all the same. The task holds the
            // stores, so with it gone there is nothing left open to close.
            let (reply, _) = oneshot::channel();
            commands
                .send(Command::EndWork(reply))
                .other_end_may_be_gone("the lifecycle's task");
        }
    }
}

/// The lifecycle's task: the only holder of the sync service and of where the app is.
struct Owner {
    client: Client,
    sync: SyncService,
    store: Option<Arc<Store>>,
    flush: Option<Flush>,
    /// The app is in front: the sync runs, whatever a background refresh does.
    foreground: bool,
    /// The stores are closed (the app in the background).
    paused: bool,
}

impl Owner {
    async fn run(mut self, mut commands: mpsc::UnboundedReceiver<Command>) {
        while let Some(command) = commands.recv().await {
            match command {
                Command::Foreground(done) => {
                    self.foreground = true;
                    // the send queues too, which the pause turned off.
                    self.open().await;
                    self.sync.start().await;
                    done.send(()).other_end_may_be_gone("the caller");
                }
                Command::Background(done) => {
                    self.foreground = false;
                    self.close().await;
                    done.send(()).other_end_may_be_gone("the caller");
                }
                Command::BeginWork(done) => {
                    self.open().await;
                    done.send(()).other_end_may_be_gone("the caller");
                }
                Command::BeginRefresh(reply) => {
                    self.open().await;
                    let answers = self.sync.room_list_service().state();
                    self.sync.start().await;
                    let sync = self.sync.state();
                    // the refresh was dropped before it began: it ends here.
                    if reply.send(Refreshing { answers, sync }).is_err() && !self.foreground {
                        self.close().await;
                    }
                }
                Command::EndWork(done) => {
                    if !self.foreground {
                        self.close().await;
                    }
                    done.send(()).other_end_may_be_gone("the caller");
                }
                Command::Stop(done) => {
                    self.sync.stop().await;
                    done.send(()).other_end_may_be_gone("the caller");
                }
            }
        }
    }

    /// Opens the stores again, if they are closed.
    async fn open(&mut self) {
        if !self.paused {
            return;
        }
        if let Err(error) = self.client.resume().await {
            warn!(%error, "the stores did not open again");
        }
        self.paused = false;
    }

    /// Stops the sync, keeps the lists, and closes the stores.
    async fn close(&mut self) {
        if self.paused {
            return;
        }
        self.sync.stop().await;
        if let Some(flush) = &self.flush {
            flush.run().await;
        }
        if let Err(error) = self.client.pause().await {
            warn!(%error, "the stores stay open");
        }
        if let Some(store) = &self.store
            && let Err(error) = store.release().await
        {
            warn!(%error, "the account's store stays open");
        }
        self.paused = true;
    }
}
