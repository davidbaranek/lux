//! The signed-in account over the SDK: its sync service (offline mode, pause and resume, through
//! the [`Lifecycle`]) and its lists.

use std::sync::Arc;
use std::time::Duration;

use lux_core::chat::{Chat, Request};
use lux_core::ids::{DeviceId, UserId};
use lux_core::ports::{BackendError, ChatAccount, DiffStream, Push};
use lux_store::Store;
use matrix_sdk::Client;
use matrix_sdk_ui::room_list_service::{RoomListService, State as ListState};
use matrix_sdk_ui::sync_service::SyncService;
use tracing::warn;

use crate::bridges::BridgeLink;
use crate::errors::from_sdk;
use crate::kept::KeptList;
use crate::lifecycle::Lifecycle;
use crate::live::LiveFeed;
use crate::organizer::Organizer;
use crate::room_list::{ChatList, Organizing, RequestList};
use crate::security::IncomingVerifications;
use crate::send_queue::QueueKeeper;
use crate::session::SessionEnd;
use crate::spaces::SpaceList;
use crate::timeline::MatrixTimelines;

/// A signed-in Matrix account, its sync started.
pub struct MatrixAccount {
    pub(crate) client: Client,
    user_id: UserId,
    device_id: DeviceId,
    /// The sync's room list: whether the server has answered.
    room_list: Arc<RoomListService>,
    pub(crate) chats: ChatList,
    requests: RequestList,
    pub(crate) organizer: Organizer,
    pub(crate) spaces: SpaceList,
    pub(crate) timelines: MatrixTimelines,
    /// What the sync brings that notifies, for an app that shows it itself.
    pub(crate) live: LiveFeed,
    /// The sync and the stores, as the app comes and goes.
    lifecycle: Lifecycle,
    /// Whether the server has ended the session.
    session_end: SessionEnd,
    _sending: QueueKeeper,
    /// The server's bridges, and the history they bring.
    pub(crate) bridges: BridgeLink,
    /// The verifications the account's other devices ask for.
    pub(crate) verification_requests: IncomingVerifications,
}

impl MatrixAccount {
    /// Opens the lists over a client with a session, and starts the sync if the app is
    /// `in_front` (in the background it starts when the app comes to the front); the chat list is
    /// kept in `store`, the account's encrypted store, for the next launch.
    pub(crate) async fn open(client: Client, store: Option<Arc<Store>>, in_front: bool) -> Result<Self, BackendError> {
        let (Some(user), Some(device)) = (client.user_id(), client.device_id()) else {
            return Err(BackendError::SignedOut);
        };
        let (user_id, device_id) = (UserId::from(user.as_str()), DeviceId::from(device.as_str()));
        let own = user.to_owned();
        // offline, the sync waits for the server and starts again by itself.
        let sync = SyncService::builder(client.clone())
            .with_offline_mode()
            .build()
            .await
            .map_err(BackendError::store)?;
        let organizer = Organizer::start(client.clone(), user_id.clone()).await;
        let service = sync.room_list_service();
        let organizing = Organizing {
            state: organizer.subscribe(),
            changes: organizer.changes(),
        };
        let kept = store.as_ref().map(|store| KeptList::new(Arc::clone(store)));
        let chats = ChatList::start(client.clone(), Arc::clone(&service), own.clone(), kept, organizing).await;
        let requests = RequestList::start(service);
        let spaces = SpaceList::start(client.clone());
        let timelines = MatrixTimelines::new(client.clone()).cutting_history(organizer.subscribe());
        let live = LiveFeed::start(&client, own, organizer.subscribe()).await;
        let sending = QueueKeeper::start(client.clone(), sync.state());
        let session_end = SessionEnd::follow(&client);
        let bridges = BridgeLink::start(&client);
        let verification_requests = IncomingVerifications::start(&client);
        // in the background the sync waits: a sync started and stopped at once may miss the stop
        // (the SDK's), and nothing there needs it.
        if in_front {
            sync.start().await;
        }
        // the requests a failure, or the last launch, left unsent go out now.
        client.send_queue().set_enabled(true).await;
        let room_list = sync.room_list_service();
        let lifecycle = Lifecycle::start(client.clone(), sync, store, chats.flush(), in_front);
        Ok(Self {
            client,
            user_id,
            device_id,
            room_list,
            chats,
            requests,
            organizer,
            spaces,
            timelines,
            live,
            lifecycle,
            session_end,
            _sending: sending,
            bridges,
            verification_requests,
        })
    }

    /// A background refresh (the system's app refresh task): syncs until the server has answered
    /// once, at most `within`, then stops as [`pause_sync`](ChatAccount::pause_sync) does, unless
    /// the app came to the front meanwhile. True when the server answered.
    pub async fn refresh_within(&self, within: Duration) -> bool {
        self.lifecycle.refresh_within(within).await
    }

    /// Opens the stores for work in the background (a notification's action, reading photos for
    /// photo search), if they are closed. The app pauses the account again when the work is done.
    pub async fn begin_background_work(&self) {
        self.lifecycle.begin_background_work().await;
    }

    /// Ends work in the background: the sync stops and the stores close, unless the app came to
    /// the front meanwhile (then they stay as the front has them).
    pub async fn end_background_work(&self) {
        self.lifecycle.end_background_work().await;
    }

    /// The chats' timelines: their messages, sending to them, their media.
    #[must_use]
    pub fn timelines(&self) -> &MatrixTimelines {
        &self.timelines
    }
}

impl ChatAccount for MatrixAccount {
    fn own_user_id(&self) -> &UserId {
        &self.user_id
    }

    fn device_id(&self) -> &DeviceId {
        &self.device_id
    }

    fn chats(&self) -> DiffStream<Arc<Chat>> {
        self.chats.rows.subscribe()
    }

    fn requests(&self) -> DiffStream<Request> {
        self.requests.rows.subscribe()
    }

    async fn wait_for_first_sync(&self) {
        let mut states = self.room_list.state();
        let answered = |state: &ListState| matches!(state, ListState::SettingUp | ListState::Running);
        if answered(&states.get()) {
            return;
        }
        while let Some(state) = states.next().await {
            if answered(&state) {
                return;
            }
        }
    }

    fn session_end(&self) -> impl Future<Output = ()> + Send + 'static {
        self.session_end.ended()
    }

    async fn pause_sync(&self) {
        self.lifecycle.pause().await;
    }

    async fn resume_sync(&self) {
        self.lifecycle.resume().await;
    }

    async fn sign_out(&self) -> Result<(), BackendError> {
        self.lifecycle.stop().await;
        // the server drops a signed-out device's pushers too; this one goes first in any case.
        if let Err(error) = self.remove_pusher().await {
            warn!(%error, "the device's pusher stays");
        }
        self.client.logout().await.map_err(from_sdk)
    }
}
