//! The chats' timelines over `matrix-sdk-ui`'s [`Timeline`](matrix_sdk_ui::Timeline): one live
//! timeline per room or Matrix thread opened, its items mapped to the core's messages by one task
//! each; those held and the few used last stay open ([`opened`]). A room's own timeline hides its
//! threads' replies; each root carries its thread's summary.
//!
//! [`MatrixTimelines`] implements the ports [`ChatTimelines`], [`ChatSending`] and
//! [`ChatMedia`](lux_core::ports::ChatMedia).

pub(crate) mod errors;
mod history;
mod items;
pub(crate) mod media;
mod opened;
mod pins;
mod previews;
mod room;
pub(crate) mod send;
pub(crate) mod shared;
pub(crate) mod threads;
mod upload;

use std::sync::Arc;
use std::time::SystemTime;

use futures_util::stream;
use lux_core::ids::{EventId, MessageId, RoomId, TimelineId};
use lux_core::organizer::Organized;
use lux_core::ports::{BackendError, ChatTimelines, DiffStream, PinsStream, RoomChanges, TimelineHold, TypingStream};
use lux_core::timeline::{Focused, IndexHistory, TimelineMessage, Unread};
use matrix_sdk::ruma::{OwnedEventId, OwnedRoomId};
use matrix_sdk::{Client, Room};
use matrix_sdk_ui::RoomListService;
use matrix_sdk_ui::timeline::EventTimelineItem;
use tokio::sync::{broadcast, watch};

use self::opened::{Key, Opened};
use self::previews::LinkPreviews;
use self::room::RoomTimeline;

/// How many room changes wait for a slow listener before it skips to the newest.
const CHANGES_BUFFER: usize = 256;

/// The account's chats' timelines.
pub struct MatrixTimelines {
    client: Client,
    /// What the user organized: a deleted chat's thread starts after its delete.
    cuts: watch::Receiver<Arc<Organized>>,
    /// The rooms' open timelines, each opened by the first read of it.
    opened: Opened,
    changes: broadcast::Sender<RoomId>,
    /// What shared posts' addresses say about them, from the server.
    previews: LinkPreviews,
}

impl MatrixTimelines {
    /// The timelines of `client`'s rooms; none is open yet. Starts the task that keeps the open
    /// ones, on the current Tokio runtime, and subscribes the sync of `room_list` to the rooms of
    /// those held (none without it). The account makes its own; this is public for the
    /// integration tests, which drive the timelines over a bare client.
    #[doc(hidden)]
    #[must_use]
    pub fn new(client: Client, room_list: Option<Arc<RoomListService>>) -> Self {
        // an upload's progress shows on its message.
        client.send_queue().enable_upload_progress(true);
        Self {
            previews: LinkPreviews::start(client.clone()),
            client,
            // none deleted, for timelines without an organizer.
            cuts: watch::channel(Arc::new(Organized::default())).1,
            opened: Opened::new(opened::KEPT, room_list),
            changes: broadcast::channel(CHANGES_BUFFER).0,
        }
    }

    /// Each room's thread starts after its delete, as `cuts` says, now and when it changes.
    #[must_use]
    pub(crate) fn cutting_history(mut self, cuts: watch::Receiver<Arc<Organized>>) -> Self {
        self.cuts = cuts;
        self
    }

    /// The timeline, if it is open.
    pub(crate) async fn opened(&self, timeline: &TimelineId) -> Option<Arc<RoomTimeline>> {
        self.opened.timeline(key(timeline).ok()?).await
    }

    /// The open timeline: what is done to one nobody opened does not open it.
    pub(crate) async fn held(&self, timeline: &TimelineId) -> Result<Arc<RoomTimeline>, BackendError> {
        self.opened(timeline)
            .await
            .ok_or_else(|| BackendError::UnknownChat(lux_core::ids::ChatId::Room(timeline.room.clone())))
    }

    /// The joined room `room`.
    fn room(&self, room: &RoomId) -> Result<Room, BackendError> {
        crate::convert::room(&self.client, room)
    }

    /// The timeline, opened the first time: only its reads ([`ChatTimelines::messages`],
    /// [`ChatTimelines::prefetch`]) open it.
    async fn open(&self, timeline: &TimelineId) -> Result<Arc<RoomTimeline>, BackendError> {
        let sdk_room = self.room(&timeline.room)?;
        let key = key(timeline)?;
        let (thread, around) = (key.thread.clone(), key.around.clone());
        let cell = self.opened.use_room(key).await.ok_or(BackendError::SignedOut)?;
        let (changes, cuts, previews) = (self.changes.clone(), self.cuts.clone(), self.previews.clone());
        // opening builds the SDK's timeline, a large future: on the heap, not in each caller's.
        cell.get_or_try_init(|| async move {
            Box::pin(RoomTimeline::open(sdk_room, thread, around, changes, cuts, previews))
                .await
                .map(Arc::new)
        })
        .await
        .cloned()
    }

    /// One page of the room's Matrix threads from `from`, the latest active first (the chat's
    /// details list them).
    ///
    /// # Errors
    /// When the room is not the account's, or the server does not answer.
    pub async fn threads(
        &self,
        room: &RoomId,
        from: Option<&str>,
    ) -> Result<lux_core::ports::ThreadPage, BackendError> {
        threads::page(&self.room(room)?, from).await
    }

    /// The open timeline of `room` that holds `message` (its own, a thread's, a jump's: a message
    /// has the same id in each), with its item.
    pub(crate) async fn holding(
        &self,
        room: &RoomId,
        message: &MessageId,
    ) -> Result<(Arc<RoomTimeline>, EventTimelineItem), BackendError> {
        let id = OwnedRoomId::try_from(room.as_str())
            .map_err(|_| BackendError::UnknownChat(lux_core::ids::ChatId::Room(room.clone())))?;
        for timeline in self.opened.of_room(id).await {
            if let Some(item) = timeline.item(message).await {
                return Ok((timeline, item));
            }
        }
        Err(BackendError::UnknownMessage)
    }
}

/// The SDK's ids of a timeline.
fn key(timeline: &TimelineId) -> Result<Key, BackendError> {
    let room = OwnedRoomId::try_from(timeline.room.as_str())
        .map_err(|_| BackendError::UnknownChat(lux_core::ids::ChatId::Room(timeline.room.clone())))?;
    let event = |event: &EventId| OwnedEventId::try_from(event.as_str()).map_err(|_| BackendError::UnknownMessage);
    Ok(Key {
        room,
        thread: timeline.thread.as_ref().map(event).transpose()?,
        around: timeline.at.as_ref().map(event).transpose()?,
    })
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

    fn hold(&self, timeline: &TimelineId) -> TimelineHold {
        match key(timeline) {
            Ok(key) => self.opened.hold(key),
            // no room or event has that id: nothing to keep open.
            Err(_) => TimelineHold::new(|| {}),
        }
    }

    async fn messages(&self, timeline: &TimelineId) -> Result<DiffStream<Arc<TimelineMessage>>, BackendError> {
        Ok(self.open(timeline).await?.list().subscribe())
    }

    async fn prefetch(&self, timeline: &TimelineId) -> Result<(), BackendError> {
        if self.opened(timeline).await.is_some() {
            return Ok(());
        }
        // only a head start: the chat pages for itself once open.
        if let Err(error) = self.open(timeline).await?.page_back(usize::from(room::PAGE)).await {
            tracing::warn!(%error, "the chat's first page could not be fetched ahead");
        }
        Ok(())
    }

    async fn load_older(&self, timeline: &TimelineId, count: usize) -> Result<bool, BackendError> {
        self.held(timeline).await?.page_back(count).await
    }

    async fn load_newer(&self, timeline: &TimelineId, count: usize) -> Result<bool, BackendError> {
        self.held(timeline).await?.page_forward(count).await
    }

    async fn focused(&self, timeline: &TimelineId) -> Result<Focused, BackendError> {
        self.held(timeline).await?.focused().await
    }

    async fn first_unread(&self, timeline: &TimelineId) -> Result<Unread, BackendError> {
        Ok(self.held(timeline).await?.first_unread().await)
    }

    async fn index_history(
        &self,
        room: &RoomId,
        since: SystemTime,
        from: Option<String>,
        max_pages: u32,
    ) -> Result<IndexHistory, BackendError> {
        let deleted_until = self.cuts.borrow().marks.cleared.get(room.as_str()).copied();
        history::index_history(&self.room(room)?, since, deleted_until, from, max_pages).await
    }

    fn typing(&self, room: &RoomId) -> Result<TypingStream, BackendError> {
        Ok(history::typing(self.room(room)?))
    }

    fn pins(&self, room: &RoomId) -> Result<PinsStream, BackendError> {
        Ok(pins::pins(self.room(room)?))
    }

    async fn mark_pins_seen(&self, room: &RoomId, events: &[EventId]) -> Result<(), BackendError> {
        pins::mark_seen(&self.room(room)?, events).await
    }

    async fn set_pinned(&self, room: &RoomId, event: &EventId, pinned: bool) -> Result<(), BackendError> {
        let room = self.room(room)?;
        let event = OwnedEventId::try_from(event.as_str()).map_err(|_| BackendError::UnknownMessage)?;
        if pinned {
            room.pin_event(&event).await.map_err(crate::errors::from_sdk)?;
        } else {
            room.unpin_event(&event).await.map_err(crate::errors::from_sdk)?;
        }
        Ok(())
    }
}
