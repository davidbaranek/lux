//! The chats' timelines over `matrix-sdk-ui`'s [`Timeline`](matrix_sdk_ui::Timeline): one live
//! timeline per room opened, its items mapped to the core's messages by one task each; those
//! held and the few used last stay open ([`opened`]).
//!
//! [`MatrixTimelines`] implements the ports [`ChatTimelines`], [`ChatSending`] and
//! [`ChatMedia`](lux_core::ports::ChatMedia).

pub(crate) mod errors;
mod history;
mod items;
pub(crate) mod media;
mod opened;
mod previews;
mod room;
pub(crate) mod send;

use std::sync::Arc;
use std::time::SystemTime;

use futures_util::stream;
use lux_core::ids::{EventId, MessageId, RoomId};
use lux_core::organizer::Organized;
use lux_core::ports::{BackendError, ChatTimelines, DiffStream, RoomChanges, TimelineHold, TypingStream};
use lux_core::timeline::{TextHistory, TimelineMessage};
use matrix_sdk::ruma::OwnedRoomId;
use matrix_sdk::{Client, Room};
use tokio::sync::{broadcast, watch};

use self::opened::Opened;
use self::previews::LinkPreviews;
use self::room::RoomTimeline;

/// How many room changes wait for a slow listener before it skips to the newest.
const CHANGES_BUFFER: usize = 256;

/// The account's chats' timelines.
pub struct MatrixTimelines {
    client: Client,
    /// What the user organized: a deleted chat's thread starts after its delete.
    cuts: watch::Receiver<Arc<Organized>>,
    /// The rooms' open timelines, each opened by the first call that names it.
    opened: Opened,
    changes: broadcast::Sender<RoomId>,
    /// What shared posts' addresses say about them, from the server.
    previews: LinkPreviews,
}

impl MatrixTimelines {
    /// The timelines of `client`'s rooms; none is open yet. Starts the task that keeps the open
    /// ones, on the current Tokio runtime. The account makes its own; this is public for the
    /// integration tests, which drive the timelines over a bare client.
    #[doc(hidden)]
    #[must_use]
    pub fn new(client: Client) -> Self {
        // an upload's progress shows on its message.
        client.send_queue().enable_upload_progress(true);
        Self {
            previews: LinkPreviews::start(client.clone()),
            client,
            // none deleted, for timelines without an organizer.
            cuts: watch::channel(Arc::new(Organized::default())).1,
            opened: Opened::new(opened::KEPT),
            changes: broadcast::channel(CHANGES_BUFFER).0,
        }
    }

    /// Each room's thread starts after its delete, as `cuts` says, now and when it changes.
    #[must_use]
    pub(crate) fn cutting_history(mut self, cuts: watch::Receiver<Arc<Organized>>) -> Self {
        self.cuts = cuts;
        self
    }

    /// The room's timeline, if it is open.
    pub(crate) async fn opened(&self, room: &RoomId) -> Option<Arc<RoomTimeline>> {
        let id = OwnedRoomId::try_from(room.as_str()).ok()?;
        self.opened.timeline(id).await
    }

    /// The joined room `room`.
    fn room(&self, room: &RoomId) -> Result<Room, BackendError> {
        crate::convert::room(&self.client, room)
    }

    /// The room's live timeline, opened the first time.
    async fn open(&self, room: &RoomId) -> Result<Arc<RoomTimeline>, BackendError> {
        let sdk_room = self.room(room)?;
        let cell = self
            .opened
            .use_room(sdk_room.room_id().to_owned())
            .await
            .ok_or(BackendError::SignedOut)?;
        let (changes, cuts, previews) = (self.changes.clone(), self.cuts.clone(), self.previews.clone());
        cell.get_or_try_init(|| async move {
            RoomTimeline::open(sdk_room, changes, cuts, previews)
                .await
                .map(Arc::new)
        })
        .await
        .cloned()
    }
}

impl ChatTimelines for MatrixTimelines {
    fn changes(&self) -> RoomChanges {
        Box::pin(stream::unfold(self.changes.subscribe(), |mut changes| async move {
            loop {
                match changes.recv().await {
                    Ok(room) => return Some((room, changes)),
                    // a listener that fell behind takes the changes from here on.
                    Err(broadcast::error::RecvError::Lagged(_)) => {}
                    Err(broadcast::error::RecvError::Closed) => return None,
                }
            }
        }))
    }

    fn hold(&self, room: &RoomId) -> TimelineHold {
        match OwnedRoomId::try_from(room.as_str()) {
            Ok(id) => self.opened.hold(id),
            // no room has that id: nothing to keep open.
            Err(_) => TimelineHold::new(|| {}),
        }
    }

    async fn messages(&self, room: &RoomId) -> Result<DiffStream<Arc<TimelineMessage>>, BackendError> {
        Ok(self.open(room).await?.list().subscribe())
    }

    async fn prefetch(&self, room: &RoomId) -> Result<(), BackendError> {
        self.open(room).await.map(drop)
    }

    async fn wait_until_filled(&self, room: &RoomId) {
        if let Ok(timeline) = self.open(room).await {
            timeline.wait_until_filled().await;
        }
    }

    async fn load_older(&self, room: &RoomId, count: usize) -> Result<(), BackendError> {
        self.open(room).await?.load_older(count).await
    }

    async fn is_at_start(&self, room: &RoomId) -> Result<bool, BackendError> {
        let timeline = self.open(room).await?;
        timeline.wait_until_filled().await;
        Ok(timeline.is_at_start())
    }

    async fn show_event(&self, room: &RoomId, event: &EventId) -> Result<Option<MessageId>, BackendError> {
        let event =
            matrix_sdk::ruma::OwnedEventId::try_from(event.as_str()).map_err(|_| BackendError::UnknownMessage)?;
        self.open(room).await?.show_event(&event).await
    }

    async fn first_unread(&self, room: &RoomId) -> Result<Option<MessageId>, BackendError> {
        self.open(room).await?.first_unread().await
    }

    async fn text_history(
        &self,
        room: &RoomId,
        since: SystemTime,
        max_pages: u32,
    ) -> Result<TextHistory, BackendError> {
        let deleted_until = self.cuts.borrow().marks.cleared.get(room.as_str()).copied();
        history::text_history(&self.room(room)?, since, deleted_until, max_pages).await
    }

    fn typing(&self, room: &RoomId) -> Result<TypingStream, BackendError> {
        Ok(history::typing(self.room(room)?))
    }
}
