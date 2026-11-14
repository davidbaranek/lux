//! One open room's live timeline: the SDK's `Timeline`, and the task that maps its items to the
//! core's messages (the only writer of the list), and the opening fill. Which of them show is
//! the thread's choice (`lux_core::thread`).

use std::sync::Arc;
use std::time::{Duration, SystemTime};

use eyeball_im::{Vector, VectorDiff};
use futures_util::StreamExt;
use lux_core::ids::{MessageId, MessageRef, RoomId};
use lux_core::organizer::Organized;
use lux_core::ports::BackendError;
use lux_core::timeline::{Filtered, TimelineMessage};
use matrix_sdk::Room;
use matrix_sdk::ruma::{EventId, OwnedEventId};
use matrix_sdk_ui::Timeline;
use matrix_sdk_ui::timeline::{
    EventTimelineItem, RoomExt, TimelineEventItemId, TimelineItem, TimelineReadReceiptTracking, VirtualTimelineItem,
};
use tokio::sync::{broadcast, watch};
use tokio::task::{JoinHandle, JoinSet};
use tracing::warn;

use super::errors::from_timeline;
use super::items::ItemMapper;
use super::previews::LinkPreviews;
use crate::live_list::LiveList;

/// How many messages a chat's first screen holds: the opening pages back until it has them.
pub(crate) const FIRST_SCREEN: usize = 60;

/// How many events one page back asks the server for.
const PAGE: u16 = 50;

/// How long an action waits for the mapped messages to catch up with the SDK's timeline.
const CATCH_UP: Duration = Duration::from_secs(5);

/// How many pages back the first unread message is looked for.
const UNREAD_PAGES: usize = 10;

/// How long a page back waits for its messages to be mapped (a page of state events brings none).
const PAGE_CATCH_UP: Duration = Duration::from_secs(1);

/// A room's live timeline, open until the account closes.
pub(crate) struct RoomTimeline {
    pub(crate) room: Room,
    pub(crate) timeline: Arc<Timeline>,
    messages: LiveList<Arc<TimelineMessage>>,
    at_start: watch::Receiver<bool>,
    filled: watch::Receiver<bool>,
    tasks: Vec<JoinHandle<()>>,
}

impl Drop for RoomTimeline {
    fn drop(&mut self) {
        for task in &self.tasks {
            task.abort();
        }
    }
}

impl RoomTimeline {
    /// Opens the room's live timeline, and starts filling its first screen.
    pub(crate) async fn open(
        room: Room,
        changes: broadcast::Sender<RoomId>,
        mut cuts: watch::Receiver<Arc<Organized>>,
        previews: LinkPreviews,
    ) -> Result<Self, BackendError> {
        let timeline = Arc::new(
            room.timeline_builder()
                // the SDK numbers each timeline's items from 0: the room makes a message's id
                // unique among all rooms' (a merged chat shows several timelines as one thread).
                .with_internal_id_prefix(format!("{}/", room.room_id()))
                .track_read_marker_and_receipts(TimelineReadReceiptTracking::MessageLikeEvents)
                .build()
                .await
                .map_err(from_timeline)?,
        );
        let room_id = RoomId::from(room.room_id().as_str());
        let cut_of = |organized: &Organized, room: &RoomId| organized.marks.cleared.get(room.as_str()).copied();
        let cut = cut_of(&cuts.borrow_and_update(), &room_id);
        let messages = LiveList::new(Vector::new());
        let (at_start_sender, at_start) = watch::channel(false);
        let (filled_sender, filled) = watch::channel(false);
        // the first items are in once `subscribe` answers: the task maps them before anything else.
        let (items, stream) = timeline.subscribe().await;
        let mut follower = Follower {
            timeline: Arc::clone(&timeline),
            mapper: ItemMapper::new(room.clone(), previews.clone()),
            filter: Filtered::new(),
            messages: messages.clone(),
            at_start: at_start_sender,
            changes,
            room_id,
            cut,
            items: Vector::new(),
            quotes: JoinSet::new(),
        };
        follower.apply(vec![VectorDiff::Reset { values: items }]).await;
        let mut learned = previews.follow();
        let follow = tokio::spawn(async move {
            futures_util::pin_mut!(stream);
            let mut organizer_open = true;
            let mut previews_open = true;
            loop {
                tokio::select! {
                    batch = stream.next() => {
                        let Some(batch) = batch else { break };
                        follower.apply(batch).await;
                    }
                    // a shared post's preview came: its message says the post's title now.
                    learned_more = learned.changed(), if previews_open => {
                        previews_open = learned_more.is_ok();
                        let items = follower.items.clone();
                        follower.apply(vec![VectorDiff::Reset { values: items }]).await;
                    }
                    cut_changed = cuts.changed(), if organizer_open => {
                        organizer_open = cut_changed.is_ok();
                        let cut = cut_of(&cuts.borrow_and_update(), &follower.room_id);
                        if cut != follower.cut {
                            // the chat was deleted (here or elsewhere): its thread starts afresh.
                            follower.cut = cut;
                            let items = follower.items.clone();
                            follower.apply(vec![VectorDiff::Reset { values: items }]).await;
                        }
                    }
                }
            }
        });
        let fill = tokio::spawn(fill(Arc::clone(&timeline), filled_sender));
        // a sender's name comes with the room's members; their profiles arrive as changes.
        let members = tokio::spawn({
            let timeline = Arc::clone(&timeline);
            async move { timeline.fetch_members().await }
        });
        Ok(Self {
            room,
            timeline,
            messages,
            at_start,
            filled,
            tasks: vec![follow, fill, members],
        })
    }

    /// The messages now, oldest first: the list's persistent vector, shared, not copied.
    pub(crate) fn snapshot(&self) -> Vector<Arc<TimelineMessage>> {
        self.messages.snapshot()
    }

    /// The live list, for its subscribers.
    pub(crate) fn list(&self) -> &LiveList<Arc<TimelineMessage>> {
        &self.messages
    }

    pub(crate) async fn wait_until_filled(&self) {
        let mut filled = self.filled.clone();
        // the sender goes only with the timeline.
        let _ = filled.wait_for(|filled| *filled).await;
    }

    /// The timeline holds the room's first message.
    pub(crate) fn is_at_start(&self) -> bool {
        *self.at_start.borrow()
    }

    /// Pages back until the timeline holds `count` more messages, or the room's first.
    pub(crate) async fn load_older(&self, count: usize) -> Result<(), BackendError> {
        let wanted = self.snapshot().len() + count;
        while !*self.at_start.borrow() {
            let before = self.snapshot().len();
            let missing = wanted.saturating_sub(before);
            if missing == 0 {
                break;
            }
            let reached_start = self
                .timeline
                .paginate_backwards(u16::try_from(missing).unwrap_or(u16::MAX).max(PAGE))
                .await
                .map_err(from_timeline)?;
            self.until(PAGE_CATCH_UP, |messages| messages.len() > before).await;
            if reached_start {
                break;
            }
        }
        Ok(())
    }

    /// Pages back until the timeline has the message of `event`; its id, `None` when the room's
    /// start came first (or too many pages).
    pub(crate) async fn show_event(&self, event: &EventId) -> Result<Option<MessageId>, BackendError> {
        // about a thousand events back, as far as a saved message or a reply is looked for.
        for _ in 0..20 {
            let messages = self.snapshot();
            if let Some(message) = messages.iter().find(|message| {
                message
                    .event_id
                    .as_ref()
                    .is_some_and(|id| id.as_str() == event.as_str())
            }) {
                return Ok(Some(message.message.id.clone()));
            }
            if *self.at_start.borrow() {
                return Ok(None);
            }
            let before = messages.len();
            self.timeline.paginate_backwards(PAGE).await.map_err(from_timeline)?;
            self.until(PAGE_CATCH_UP, |messages| messages.len() > before).await;
        }
        Ok(None)
    }

    /// Waits until the mapped messages satisfy `done`, at most `patience`; `Some` once they do.
    async fn until(&self, patience: Duration, done: impl Fn(&Vector<Arc<TimelineMessage>>) -> bool) -> Option<()> {
        let mut batches = self.messages.subscribe();
        tokio::time::timeout(patience, async {
            // the first batch is the list as it is.
            while batches.next().await.is_some() {
                if done(&self.snapshot()) {
                    return Some(());
                }
            }
            None
        })
        .await
        .ok()
        .flatten()
    }

    /// The SDK's item of a message.
    pub(crate) async fn item(&self, message: &MessageId) -> Option<EventTimelineItem> {
        self.timeline
            .items()
            .await
            .iter()
            .find(|item| item.unique_id().0 == message.as_str())
            .and_then(|item| item.as_event().cloned())
    }

    /// The SDK's id of a message, to act on it.
    pub(crate) async fn identifier(&self, message: &MessageId) -> Result<TimelineEventItemId, BackendError> {
        self.item(message)
            .await
            .map(|item| item.identifier())
            .ok_or(BackendError::UnknownMessage)
    }

    /// The event id of a message, once it is sent.
    pub(crate) async fn event_id(&self, message: &MessageRef) -> Result<OwnedEventId, BackendError> {
        match message {
            MessageRef::Local(id) => self
                .item(id)
                .await
                .ok_or(BackendError::UnknownMessage)?
                .event_id()
                .map(ToOwned::to_owned)
                .ok_or(BackendError::NotAllowed),
            MessageRef::Event(event) => EventId::parse(event.as_str()).map_err(|_| BackendError::UnknownMessage),
        }
    }

    /// The id the mapped message of a local echo has, once the timeline shows it.
    pub(crate) async fn message_of_transaction(
        &self,
        transaction: &matrix_sdk::ruma::TransactionId,
    ) -> Option<MessageId> {
        let find = |items: &Vector<Arc<TimelineItem>>| {
            items
                .iter()
                .find(|item| item.as_event().and_then(EventTimelineItem::transaction_id) == Some(transaction))
                .map(|item| MessageId::from(item.unique_id().0.as_str()))
        };
        let (items, mut stream) = self.timeline.subscribe().await;
        let id = if let Some(id) = find(&items) {
            id
        } else {
            tokio::time::timeout(CATCH_UP, async {
                while stream.next().await.is_some() {
                    if let Some(id) = find(&self.timeline.items().await) {
                        return Some(id);
                    }
                }
                None
            })
            .await
            .ok()
            .flatten()?
        };
        // and once the mapped list has it.
        self.until(CATCH_UP, |messages| {
            messages.iter().any(|message| message.message.id == id)
        })
        .await?;
        Some(id)
    }

    /// The first message after the account's read receipt that another sent. When the
    /// timeline does not hold the receipt's event, it pages back for it, at most `UNREAD_PAGES`
    /// pages; then the oldest message another sent of those it holds.
    pub(crate) async fn first_unread(&self) -> Result<Option<MessageId>, BackendError> {
        let own = self.room.own_user_id().to_owned();
        // the receipt as the room knows it, held by the timeline or not; none: never read.
        if self.timeline.latest_user_read_receipt(&own).await.is_none() {
            return Ok(None);
        }
        let mut pages = 0;
        let (items, after) = loop {
            let receipt = self.timeline.latest_user_read_receipt_timeline_event_id(&own).await;
            let items = self.timeline.items().await;
            let read = receipt.and_then(|receipt| {
                items
                    .iter()
                    .position(|item| item.as_event().and_then(EventTimelineItem::event_id) == Some(&*receipt))
            });
            if let Some(read) = read {
                break (items, read + 1);
            }
            if pages >= UNREAD_PAGES || *self.at_start.borrow() {
                break (items, 0);
            }
            // read before what the timeline holds: a page back. The SDK applies a page after the
            // call returns: it is awaited before the items are read again.
            let (_, updates) = self.timeline.subscribe().await;
            let reached_start = self.timeline.paginate_backwards(PAGE).await.map_err(from_timeline)?;
            let _ = tokio::time::timeout(PAGE_CATCH_UP, async {
                futures_util::pin_mut!(updates);
                while self.timeline.items().await.len() <= items.len() {
                    if updates.next().await.is_none() {
                        break;
                    }
                }
            })
            .await;
            pages = if reached_start { UNREAD_PAGES } else { pages + 1 };
        };
        // the messages others sent after it, as the SDK has them; the mapping may lag a page.
        let unread: Vec<&str> = items
            .iter()
            .skip(after)
            .filter(|item| {
                item.as_event()
                    .is_some_and(|event| !event.is_own() && event.content().as_msglike().is_some())
            })
            .map(|item| item.unique_id().0.as_str())
            .collect();
        let Some(&first) = unread.first() else {
            return Ok(None);
        };
        self.until(PAGE_CATCH_UP, |messages| {
            messages.iter().any(|message| message.message.id.as_str() == first)
        })
        .await;
        // the first the chat shows (a deleted chat's thread starts later).
        let messages = self.snapshot();
        Ok(unread
            .iter()
            .find_map(|id| messages.iter().find(|message| message.message.id.as_str() == *id))
            .map(|message| message.message.id.clone()))
    }
}

/// Maps the SDK's batches into the room's messages; the only writer of the list.
struct Follower {
    timeline: Arc<Timeline>,
    mapper: ItemMapper,
    filter: Filtered,
    messages: LiveList<Arc<TimelineMessage>>,
    at_start: watch::Sender<bool>,
    changes: broadcast::Sender<RoomId>,
    room_id: RoomId,
    /// The thread starts after this: the chat was deleted then.
    cut: Option<SystemTime>,
    /// The SDK's items as they are (shared), to map again when the cut changes.
    items: Vector<Arc<TimelineItem>>,
    /// The quoted messages being fetched; they end with the follower.
    quotes: JoinSet<()>,
}

impl Follower {
    async fn apply(&mut self, batch: Vec<VectorDiff<Arc<TimelineItem>>>) {
        let mut mapped = Vec::with_capacity(batch.len());
        let mut fetch = Vec::new();
        for diff in batch {
            diff.clone().apply(&mut self.items);
            let diff = self.map(diff, &mut fetch).await;
            if let Some(diff) = self.filter.apply(diff) {
                mapped.push(diff);
            }
        }
        // the start is the SDK's first item once the timeline reached it.
        let at_start = self
            .items
            .front()
            .is_some_and(|item| matches!(item.as_virtual(), Some(VirtualTimelineItem::TimelineStart)));
        self.at_start.send_replace(at_start);
        while self.quotes.try_join_next().is_some() {}
        for event in fetch {
            let timeline = Arc::clone(&self.timeline);
            self.quotes.spawn(async move {
                if let Err(error) = timeline.fetch_details_for_event(&event).await {
                    warn!(%error, "the quoted message could not be fetched");
                }
            });
        }
        if !mapped.is_empty() {
            self.messages.apply(mapped);
            // nobody listening is no error.
            let _ = self.changes.send(self.room_id.clone());
        }
    }

    async fn map(
        &mut self,
        diff: VectorDiff<Arc<TimelineItem>>,
        fetch: &mut Vec<OwnedEventId>,
    ) -> VectorDiff<Option<Arc<TimelineMessage>>> {
        let cut = self.cut;
        let mut one = async |item: Arc<TimelineItem>, fetch: &mut Vec<OwnedEventId>| {
            let mapped = self.mapper.map(&item).await;
            // a deleted chat shows only what came after the delete.
            let message = mapped
                .message
                .filter(|message| cut.is_none_or(|cut| message.message.date > cut));
            if message.is_some() {
                fetch.extend(mapped.fetch_quote_of);
            }
            message
        };
        match diff {
            VectorDiff::Append { values } => {
                let mut mapped = Vector::new();
                for value in values {
                    mapped.push_back(one(value, fetch).await);
                }
                VectorDiff::Append { values: mapped }
            }
            VectorDiff::Reset { values } => {
                let mut mapped = Vector::new();
                for value in values {
                    mapped.push_back(one(value, fetch).await);
                }
                VectorDiff::Reset { values: mapped }
            }
            VectorDiff::PushFront { value } => VectorDiff::PushFront {
                value: one(value, fetch).await,
            },
            VectorDiff::PushBack { value } => VectorDiff::PushBack {
                value: one(value, fetch).await,
            },
            VectorDiff::Insert { index, value } => VectorDiff::Insert {
                index,
                value: one(value, fetch).await,
            },
            VectorDiff::Set { index, value } => VectorDiff::Set {
                index,
                value: one(value, fetch).await,
            },
            VectorDiff::Clear => VectorDiff::Clear,
            VectorDiff::PopFront => VectorDiff::PopFront,
            VectorDiff::PopBack => VectorDiff::PopBack,
            VectorDiff::Remove { index } => VectorDiff::Remove { index },
            VectorDiff::Truncate { length } => VectorDiff::Truncate { length },
        }
    }
}

/// Pages back until the timeline holds a first screen of messages, or the room's start.
async fn fill(timeline: Arc<Timeline>, filled: watch::Sender<bool>) {
    loop {
        let shown = timeline
            .items()
            .await
            .iter()
            .filter(|item| {
                item.as_event()
                    .is_some_and(|event| event.content().as_msglike().is_some())
            })
            .count();
        if shown >= FIRST_SCREEN {
            break;
        }
        match timeline.paginate_backwards(PAGE).await {
            Ok(false) => {}
            Ok(true) => break,
            Err(error) => {
                warn!(%error, "the chat's first screen could not be filled");
                break;
            }
        }
    }
    filled.send_replace(true);
}
