//! One open timeline: a room's own (live, its Matrix threads' replies hidden behind their roots'
//! summaries) or a Matrix thread's (the SDK's thread focus: the root, then the replies). The
//! SDK's `Timeline`, the task that maps its items to the core's messages (the only writer of the
//! list), and the opening fill. Which of them show is the thread's choice (`lux_core::thread`).

use lux_core::gone::OtherEndGone;
use std::collections::HashSet;
use std::sync::Arc;
use std::time::{Duration, SystemTime};

use eyeball_im::{Vector, VectorDiff};
use futures_util::StreamExt;
use lux_core::ids::{MessageId, MessageRef, RoomId};
use lux_core::organizer::Organized;
use lux_core::ports::BackendError;
use lux_core::timeline::{Filtered, TimelineMessage};
use matrix_sdk::Room;
use matrix_sdk::ruma::events::receipt::{Receipt, ReceiptThread, ReceiptType};
use matrix_sdk::ruma::{EventId, MilliSecondsSinceUnixEpoch, OwnedEventId};
use matrix_sdk_ui::Timeline;
use matrix_sdk_ui::timeline::{
    EventTimelineItem, RoomExt, TimelineEventItemId, TimelineFocus, TimelineItem, TimelineReadReceiptTracking,
    VirtualTimelineItem,
};
use tokio::sync::{broadcast, mpsc, watch};
use tokio::task::JoinSet;
use tracing::warn;

use super::errors::from_timeline;
use super::items::ItemMapper;
use super::previews::LinkPreviews;
use crate::live_list::LiveList;

/// How many messages a chat's first screen holds: the opening pages back until it has them.
pub(crate) const FIRST_SCREEN: usize = 60;

/// How many events one page back asks the server for.
const PAGE: u16 = 50;
/// The most pages back a message is looked for when its time is not known: about a thousand events.
const PAGES_TO_AN_EVENT: usize = 20;
/// The most pages back a message is looked for, to its time: some twenty thousand events.
const PAGES_TO_A_TIME: usize = 400;

/// How many pages back the first unread message is looked for.
const UNREAD_PAGES: usize = 10;

/// The most a page back waits for the SDK's timeline to apply it (see [`RoomTimeline::applied`]).
const PAGE_APPLIED: Duration = Duration::from_secs(1);

/// The SDK's items as the follower has mapped them: the messages list is never behind these.
type Mapped = Vector<Arc<TimelineItem>>;

/// A room's or a Matrix thread's live timeline, open until the account closes.
pub(crate) struct RoomTimeline {
    pub(crate) room: Room,
    /// The Matrix thread's root; `None`: the room's own timeline.
    pub(crate) thread: Option<OwnedEventId>,
    pub(crate) timeline: Arc<Timeline>,
    messages: LiveList<Arc<TimelineMessage>>,
    mapped: watch::Receiver<Mapped>,
    at_start: watch::Receiver<bool>,
    filled: watch::Receiver<bool>,
    _tasks: Vec<crate::task::Owned>,
}

impl RoomTimeline {
    /// Opens the room's live timeline (the Matrix thread of `thread` instead, if given), and
    /// starts filling its first screen.
    pub(crate) async fn open(
        room: Room,
        thread: Option<OwnedEventId>,
        changes: broadcast::Sender<RoomId>,
        mut cuts: watch::Receiver<Arc<Organized>>,
        previews: LinkPreviews,
    ) -> Result<Self, BackendError> {
        let (focus, prefix) = match &thread {
            Some(started_by) => (
                TimelineFocus::Thread {
                    thread_id: started_by.clone(),
                },
                format!("{}/{started_by}/", room.room_id()),
            ),
            // a thread's replies show in its own timeline; the room's shows its root, summed up.
            None => (
                TimelineFocus::Live {
                    hide_threaded_events: true,
                },
                format!("{}/", room.room_id()),
            ),
        };
        let timeline = Arc::new(
            room.timeline_builder()
                .with_focus(focus)
                // the SDK numbers each timeline's items from 0: the room (and the thread) makes a
                // message's id unique among all timelines' (a merged chat shows several as one
                // thread, a thread's root shows in the room's and in the thread's).
                .with_internal_id_prefix(prefix)
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
        let (mapped_sender, mapped) = watch::channel(Mapped::new());
        // the first items are in once `subscribe` answers: the task maps them before anything else.
        let (items, stream) = timeline.subscribe().await;
        let (stale_roots, mut stale) = mpsc::unbounded_channel();
        let mut follower = Follower {
            follows_roots: thread.is_none(),
            followed_roots: HashSet::new(),
            root_followers: JoinSet::new(),
            stale_roots,
            timeline: Arc::clone(&timeline),
            mapper: match thread {
                Some(_) => ItemMapper::new(room.clone(), previews.clone()).in_thread(),
                None => ItemMapper::new(room.clone(), previews.clone()),
            },
            filter: Filtered::new(),
            messages: messages.clone(),
            mapped: mapped_sender,
            at_start: at_start_sender,
            changes,
            room_id,
            cut,
            items: Vector::new(),
            quotes: JoinSet::new(),
        };
        follower.follow(vec![VectorDiff::Reset { values: items }]).await;
        let mut learned = previews.follow();
        let follow = crate::task::spawn(async move {
            futures_util::pin_mut!(stream);
            let mut organizer_open = true;
            let mut previews_open = true;
            loop {
                tokio::select! {
                    batch = stream.next() => {
                        let Some(batch) = batch else { break };
                        follower.follow(batch).await;
                    }
                    // a shared post's preview came: its message says the post's title now.
                    // a thread's replies or read state changed: its root's summary shows it.
                    Some(stale_root) = stale.recv() => follower.map_root_again(&stale_root).await,
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
        let fill = crate::task::spawn(fill(Arc::clone(&timeline), filled_sender));
        // a sender's name comes with the room's members; their profiles arrive as changes.
        let members = crate::task::spawn({
            let timeline = Arc::clone(&timeline);
            async move { timeline.fetch_members().await }
        });
        Ok(Self {
            room,
            thread,
            timeline,
            messages,
            mapped,
            at_start,
            filled,
            _tasks: vec![follow, fill, members],
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
        filled
            .wait_for(|filled| *filled)
            .await
            .other_end_may_be_gone("the timeline");
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
                .page_back(u16::try_from(missing).unwrap_or(u16::MAX).max(PAGE))
                .await?;
            if reached_start {
                break;
            }
        }
        Ok(())
    }

    /// Pages back until the timeline has the message of `event`; its id, `None` when the room's
    /// start came first (or too many pages).
    pub(crate) async fn show_event(&self, event: &EventId) -> Result<Option<MessageId>, BackendError> {
        // as far back as the event was sent, which the store or the server tells: a busy room's
        // photo found by a search may be many thousands of events back. Without its time, about
        // a thousand events back, as far as a saved message or a reply is looked for.
        let sent = self
            .room
            .load_or_fetch_event(event, None)
            .await
            .ok()
            .and_then(|found| found.timestamp())
            .and_then(MilliSecondsSinceUnixEpoch::to_system_time);
        let pages = if sent.is_some() {
            PAGES_TO_A_TIME
        } else {
            PAGES_TO_AN_EVENT
        };
        for _ in 0..pages {
            let messages = self.snapshot();
            if let Some(message) = messages.iter().find(|message| {
                message
                    .event_id
                    .as_ref()
                    .is_some_and(|id| id.as_str() == event.as_str())
            }) {
                return Ok(Some(message.message.id.clone()));
            }
            // the start of the room, or past the event's time: it is not one the chat shows.
            let passed = sent
                .zip(messages.front())
                .is_some_and(|(sent, oldest)| oldest.message.date < sent);
            if *self.at_start.borrow() || passed {
                return Ok(None);
            }
            self.page_back(PAGE).await?;
        }
        Ok(None)
    }

    /// One page back of `events`, returned once the follower mapped it; whether the timeline
    /// reached the room's start.
    async fn page_back(&self, events: u16) -> Result<bool, BackendError> {
        // a live timeline first shows items it holds but did not show yet (`SkipCount`): as many
        // as asked for if it has them, and then the server is not asked. Otherwise it shows all
        // it holds and asks the server for the rest, which always brings events (the SDK pages on
        // past empty ones) unless the start was reached: then the shown items hold more events
        // than the timeline held at all before.
        let held = event_count(&self.timeline.items().await);
        let shown = self.mapped.borrow().len();
        let reached_start = self.timeline.paginate_backwards(events).await.map_err(from_timeline)?;
        self.applied(PAGE_APPLIED, |mapped| {
            event_count(mapped) > held || mapped.len() >= shown + usize::from(events)
        })
        .await;
        Ok(reached_start)
    }

    /// Waits until the follower has mapped what satisfies `done`, at most `patience`.
    ///
    /// The only bounded wait, and only for the SDK's own hop. Its `Timeline` applies a page (or a
    /// local echo) in a task of its own, after the call that made it returned: the event cache
    /// stores the page and only broadcasts it (matrix-sdk `event_cache/caches/room/pagination.rs`,
    /// `conclude_backwards_pagination_*`), and the timeline's `room_event_cache_updates_task`
    /// (matrix-sdk-ui `timeline/tasks.rs`, spawned by `TimelineBuilder::build`) applies it later.
    /// Nothing public tells when it has, and a page may change no item at all (reactions to
    /// events not loaded, thread replies the room's timeline hides), so it is not waited for
    /// without a bound. The follower's hop, from the SDK's items to the messages, needs no bound:
    /// `mapped` changes only once the messages hold a batch.
    async fn applied(&self, patience: Duration, done: impl Fn(&Mapped) -> bool) {
        let mut mapped = self.mapped.clone();
        // past the bound (or with the follower gone, which goes only with the timeline) the
        // caller reads what is mapped as it is.
        if tokio::time::timeout(patience, mapped.wait_for(|mapped| done(mapped)))
            .await
            .is_err()
        {
            tracing::debug!("the SDK's timeline did not show it within the bound: read as it is");
        }
    }

    /// When the latest of `events` was sent, of those the device holds.
    async fn latest_time_of(&self, events: impl Iterator<Item = &EventId>) -> Option<MilliSecondsSinceUnixEpoch> {
        let mut latest = None;
        for event in events {
            // the device's copy, else the server's: a receipt on an edit or a reaction, which no
            // row shows, still says when the chat was read.
            if let Ok(found) = self.room.load_or_fetch_event(event, None).await {
                latest = latest.max(found.timestamp());
            }
        }
        latest
    }

    /// The account's read receipts this timeline counts from: its own thread's as the timeline
    /// knows it (public or private), and the room's unthreaded ones.
    async fn own_receipts(&self) -> Vec<(OwnedEventId, Receipt)> {
        let own = self.room.own_user_id().to_owned();
        let mut receipts: Vec<(OwnedEventId, Receipt)> =
            self.timeline.latest_user_read_receipt(&own).await.into_iter().collect();
        for kind in [ReceiptType::Read, ReceiptType::ReadPrivate] {
            if let Ok(Some(receipt)) = self
                .room
                .load_user_receipt(kind, &ReceiptThread::Unthreaded, &own)
                .await
            {
                receipts.push(receipt);
            }
        }
        receipts
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

    /// The first message after the account's read receipt that another sent. The receipt is the
    /// latest of the timeline's own (the main thread's for the room's own timeline, the thread's
    /// for a thread) and the room's unthreaded ones, which cover every thread (what clients that
    /// know no threads send, this app's earlier versions among them), by its event's time: a
    /// receipt on an event no row shows (an edit, a reaction, a thread's reply) counts by it. The
    /// timeline pages back until it holds that time, at most `UNREAD_PAGES` pages: what came
    /// after it is unread. Then the oldest message another sent of those it holds.
    pub(crate) async fn first_unread(&self) -> Result<Option<MessageId>, BackendError> {
        let receipts = self.own_receipts().await;
        // never read.
        if receipts.is_empty() {
            return Ok(None);
        }
        let read_at = self.latest_time_of(receipts.iter().map(|(event, _)| &**event)).await;
        let mut pages = 0;
        let (items, after) = loop {
            // the items the messages hold: what is found in them is in the messages.
            let items = self.mapped.borrow().clone();
            // after the latest receipt the timeline shows, and after the latest receipt's time: an
            // older receipt it shows does not undo a newer one on an event it does not (an edit).
            let shown = receipts
                .iter()
                .filter_map(|(event, _)| {
                    items
                        .iter()
                        .position(|item| item.as_event().and_then(EventTimelineItem::event_id) == Some(&**event))
                })
                .max()
                .map(|read| read + 1);
            let since = read_at.map(|read_at| {
                items
                    .iter()
                    .position(|item| item.as_event().is_some_and(|event| event.timestamp() > read_at))
                    .unwrap_or(items.len())
            });
            let oldest = items
                .iter()
                .find_map(|item| item.as_event().map(EventTimelineItem::timestamp));
            let reached = match read_at {
                Some(read_at) => oldest.is_some_and(|oldest| oldest <= read_at),
                None => shown.is_some(),
            };
            if reached || *self.at_start.borrow() || pages >= UNREAD_PAGES {
                break (items, shown.max(since).unwrap_or(0));
            }
            // read before what the timeline holds: a page back.
            let reached_start = self.page_back(PAGE).await?;
            pages = if reached_start { UNREAD_PAGES } else { pages + 1 };
        };
        // a message the account sent read what came before it, whatever the receipts say.
        let after = items
            .iter()
            .rposition(|item| {
                item.as_event()
                    .is_some_and(|event| event.is_own() && event.content().as_msglike().is_some())
            })
            .map_or(after, |own| after.max(own + 1));
        // the messages others sent after it.
        let unread: Vec<&str> = items
            .iter()
            .skip(after)
            .filter(|item| {
                item.as_event()
                    .is_some_and(|event| !event.is_own() && event.content().as_msglike().is_some())
            })
            .map(|item| item.unique_id().0.as_str())
            .collect();
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
    /// The room's own timeline: its roots' summaries follow their threads.
    follows_roots: bool,
    /// The roots whose thread is followed.
    followed_roots: HashSet<OwnedEventId>,
    /// One task each, telling `stale_roots` when its thread changes; they end with the follower.
    root_followers: JoinSet<()>,
    stale_roots: mpsc::UnboundedSender<OwnedEventId>,
    timeline: Arc<Timeline>,
    mapper: ItemMapper,
    filter: Filtered,
    messages: LiveList<Arc<TimelineMessage>>,
    /// The SDK's items the messages hold, told after each of the SDK's batches.
    mapped: watch::Sender<Mapped>,
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
    /// Maps a batch of the SDK's, then tells that the messages hold it.
    async fn follow(&mut self, batch: Vec<VectorDiff<Arc<TimelineItem>>>) {
        self.apply(batch).await;
        self.mapped.send_replace(self.items.clone());
    }

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
        if self.follows_roots {
            self.follow_roots(&mapped);
        }
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
            self.changes
                .send(self.room_id.clone())
                .other_end_may_be_gone("the room's change listeners");
        }
    }

    /// Follows the threads of the roots among `mapped`, those not followed yet: each change of a
    /// thread's replies or read state (the device's event cache's) maps its root again.
    fn follow_roots(&mut self, mapped: &[VectorDiff<Arc<TimelineMessage>>]) {
        let mut roots = Vec::new();
        for diff in mapped {
            let mut note = |message: &Arc<TimelineMessage>| {
                if message.thread.is_some()
                    && let Some(event) = &message.event_id
                    && let Ok(root) = OwnedEventId::try_from(event.as_str())
                {
                    roots.push(root);
                }
            };
            match diff {
                VectorDiff::Append { values } | VectorDiff::Reset { values } => values.iter().for_each(&mut note),
                VectorDiff::PushFront { value }
                | VectorDiff::PushBack { value }
                | VectorDiff::Insert { value, .. }
                | VectorDiff::Set { value, .. } => note(value),
                _ => {}
            }
        }
        for root in roots {
            if !self.followed_roots.insert(root.clone()) {
                continue;
            }
            let (room, stale) = (self.timeline.room().clone(), self.stale_roots.clone());
            self.root_followers.spawn(async move {
                let Some(cache) = room.client().event_cache().cloned() else {
                    return;
                };
                // the handles keep the thread's cache while it is followed.
                let Ok((thread, _handles)) = cache.thread(room.room_id(), &root).await else {
                    return;
                };
                let Ok(mut info) = thread.subscribe_to_thread_info().await else {
                    return;
                };
                while info.next().await.is_some() {
                    if stale.send(root.clone()).is_err() {
                        break;
                    }
                }
            });
        }
    }

    /// Maps the item of `root` again: its thread changed.
    async fn map_root_again(&mut self, root: &EventId) {
        let found = self.items.iter().enumerate().find_map(|(index, item)| {
            (item.as_event().and_then(EventTimelineItem::event_id) == Some(root)).then(|| (index, Arc::clone(item)))
        });
        if let Some((index, item)) = found {
            self.apply(vec![VectorDiff::Set { index, value: item }]).await;
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

/// How many of `items` are events (not the timeline's start, a date divider or the read marker).
fn event_count(items: &Vector<Arc<TimelineItem>>) -> usize {
    items.iter().filter(|item| item.as_event().is_some()).count()
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
