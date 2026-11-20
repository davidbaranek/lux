//! The demo's chats' timelines: each room's long made-up history (texts, photos, videos, files,
//! albums, reactions, quotes, formatted bodies, readers, Matrix threads), made on first use and
//! the same every run, and what the user does to it (sending, editing, reacting, replying in a
//! thread…), live as diffs. A merged chat's rooms are two of them; a thread is a timeline of its
//! own, its root's summary in the room's following its replies.
//!
//! [`DemoTimelines`] implements [`ChatTimelines`] and [`ChatSending`]; the made-up account holds
//! them as a thread's backend.

use crate::gone::OtherEndGone;
use std::collections::HashMap;
use std::num::NonZeroU32;
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::time::{Duration, SystemTime};

use eyeball_im::{ObservableVector, Vector};
use futures_util::{StreamExt, stream};
use tokio::sync::{broadcast, watch};

use super::SentMessages;
use super::data::stable;
use super::seeded::{self, text};
use crate::ids::{ChatId, EventId, MediaId, MessageId, MessageRef, RoomId, TimelineId, UserId};
use crate::mention::{ComposedText, MentionTarget};
use crate::message::{self, Attachment, Message, SendState};
use crate::ports::{
    BackendError, ChatSending, ChatTimelines, DiffStream, PinsStream, RoomChanges, SharedContent, SharedItem,
    SharedPage, TimelineHold, TypingStream, UploadStream,
};
use crate::preview::{PreviewKind, PreviewSource as Kind};
use crate::timeline::{
    Draft, FileKind, Focused, IndexHistory, IndexedFile, IndexedImage, IndexedMessage, Media, MessageKind,
    OutgoingAttachment, OutgoingKind, Participant, Picture, PinnedMessage, Pins, Quote, Reaction, Reader, Receipt,
    SharedPost, StyleKind, TextStyle, ThreadReply, ThreadSummary, TimelineMessage, Typist, Unread, html,
};

/// The demo account's user.
pub const OWN_USER: &str = "@me:demo";

const PEOPLE: [&str; 3] = ["Anna Nováková", "Petr Svoboda", "Jana Dvořáková"];

const FORMATTED: [&str; 5] = [
    "<b>Heads up:</b> the meeting moved to <i>Thursday</i>, room <code>4.12</code>.",
    "<blockquote>Can you bring the cables?</blockquote>Sure, <b>both</b> of them.",
    "Shopping list:<ul><li>milk</li><li><s>bread</s> got it</li><li>coffee</li></ul>",
    "Run this:<pre><code>swift test --parallel\nswift build -c release</code></pre>",
    "Details on <a href=\"https://example.org/plan\">the plan page</a>, thanks <a href=\"https://matrix.to/#/@anna:demo\">Anna</a>!",
];

/// The newest message from others in each chat: it mentions the account, with a pill.
const MENTIONS_ME: &str =
    "<a href=\"https://matrix.to/#/@me:demo\">Me</a>, can you look at the <b>budget</b> before Friday?";

/// The one before it: a pill of someone else.
const MENTIONS_PETR: &str = "Thanks <a href=\"https://matrix.to/#/@friend1:demo\">Petr Svoboda</a>, see you at 5!";

/// How many room changes wait for a slow listener.
const CHANGES_BUFFER: usize = 256;

/// How many messages a timeline opened around one holds on each side of it at first, as the
/// server's context of a message gives them.
const CONTEXT_SIDE: usize = 50;

/// The demo's chats' timelines, as a backend serves them.
pub struct DemoTimelines {
    messages_per_room: usize,
    /// The newest made-up message's time: this launch's minute.
    start: SystemTime,
    state: Mutex<State>,
    changes: broadcast::Sender<RoomId>,
    next_id: AtomicU64,
    /// The account, told what the user sends; none for timelines on their own.
    sent: Option<SentMessages>,
    /// Tests: how long finding the first unread message and forwarding take, in milliseconds,
    /// as on a slow connection.
    #[cfg(test)]
    pub(crate) unread_millis: AtomicU64,
    #[cfg(test)]
    pub(crate) forward_millis: AtomicU64,
    /// Tests: how long a page back takes, in milliseconds, and whether it fails, as when the
    /// server refuses it.
    #[cfg(test)]
    pub(crate) page_millis: AtomicU64,
    #[cfg(test)]
    pub(crate) pages_fail: std::sync::atomic::AtomicBool,
    /// Tests: a page back answers before its messages come, as the SDK's timeline applies a page
    /// after it answered; they come with [`land_pages`](Self::land_pages).
    #[cfg(test)]
    pub(crate) pages_land_later: std::sync::atomic::AtomicBool,
    #[cfg(test)]
    landing: Mutex<Vec<(TimelineId, usize)>>,
    /// How many of a room's newest messages its live timeline holds at first (0: all), as a
    /// device holds only the latest of a long chat: paging back brings the rest, and an older
    /// message is a jump away.
    pub(crate) live_tail: std::sync::atomic::AtomicUsize,
}

#[derive(Default)]
struct State {
    /// The rooms' own timelines and their threads', each made on first use.
    timelines: HashMap<TimelineId, ObservableVector<Arc<TimelineMessage>>>,
    /// Which of the room's history each timeline holds, when not all of it: one opened around a
    /// message, or (tests) a live one holding only the newest.
    windows: HashMap<TimelineId, std::ops::Range<usize>>,
    /// The rooms' whole histories, kept apart from live timelines holding only their newest.
    histories: HashMap<TimelineId, Vec<Arc<TimelineMessage>>>,
    drafts: HashMap<TimelineId, Draft>,
    /// Each room's pinned messages, by their events, once the room's pins were asked for.
    pins: HashMap<RoomId, (Vec<EventId>, watch::Sender<Pins>)>,
    /// Each room's pinned events the user has seen.
    seen_pins: HashMap<RoomId, Vec<EventId>>,
}

impl std::fmt::Debug for DemoTimelines {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("DemoTimelines")
            .field("messages_per_room", &self.messages_per_room)
            .finish_non_exhaustive()
    }
}

impl DemoTimelines {
    /// Rooms of `messages_per_room` made-up messages each, the newest at this minute.
    #[must_use]
    pub fn new(messages_per_room: usize) -> Self {
        let now = SystemTime::now()
            .duration_since(SystemTime::UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs();
        Self {
            messages_per_room,
            start: SystemTime::UNIX_EPOCH + Duration::from_secs(now / 60 * 60),
            state: Mutex::new(State::default()),
            changes: broadcast::channel(CHANGES_BUFFER).0,
            next_id: AtomicU64::new(0),
            sent: None,
            #[cfg(test)]
            unread_millis: AtomicU64::new(0),
            #[cfg(test)]
            forward_millis: AtomicU64::new(0),
            #[cfg(test)]
            page_millis: AtomicU64::new(0),
            #[cfg(test)]
            pages_fail: std::sync::atomic::AtomicBool::new(false),
            #[cfg(test)]
            pages_land_later: std::sync::atomic::AtomicBool::new(false),
            #[cfg(test)]
            landing: Mutex::new(Vec::new()),
            live_tail: std::sync::atomic::AtomicUsize::new(0),
        }
    }

    /// These timelines tell `account` what the user sends.
    pub(crate) fn sending_to(mut self, account: SentMessages) -> Self {
        self.sent = Some(account);
        self
    }

    fn state(&self) -> MutexGuard<'_, State> {
        // the state is whole after each change: nothing awaits while it is held.
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Tests: a limited sync resets the live timeline to its newest `kept` messages and a new one
    /// saying `body`, as one batch (a clear, then those); paging back brings the others again.
    #[cfg(test)]
    pub(crate) fn reset_to_newest(&self, timeline: &TimelineId, kept: usize, body: &str) {
        let message = Arc::new(self.own_message(&timeline.room, body));
        {
            let mut state = self.state();
            let mut whole = self.history(&mut state, timeline);
            whole.push(message);
            let start = whole.len().saturating_sub(kept + 1);
            let newest: Vector<_> = whole.iter().skip(start).cloned().collect();
            let messages = self.timeline(&mut state, timeline);
            let mut reset = messages.transaction();
            reset.clear();
            reset.append(newest);
            reset.commit();
            state.windows.insert(timeline.clone(), start..whole.len());
            state.histories.insert(timeline.clone(), whole);
        }
        self.changes
            .send(timeline.room.clone())
            .other_end_may_be_gone("the room's change listeners");
    }

    /// Tests: the pages answered before their messages came bring them now.
    #[cfg(test)]
    pub(crate) fn land_pages(&self) {
        let landing = std::mem::take(&mut *self.landing.lock().unwrap_or_else(PoisonError::into_inner));
        for (timeline, count) in landing {
            self.widen(&timeline, count, true);
            self.changes
                .send(timeline.room.clone())
                .other_end_may_be_gone("the room's change listeners");
        }
    }

    /// Changes the timeline's messages (made first if new) and tells the listeners.
    fn change<T>(
        &self,
        timeline: &TimelineId,
        change: impl FnOnce(&mut ObservableVector<Arc<TimelineMessage>>) -> T,
    ) -> T {
        let answer = {
            let mut state = self.state();
            change(self.timeline(&mut state, timeline))
        };
        // nobody listening is no error.
        self.changes
            .send(timeline.room.clone())
            .other_end_may_be_gone("the room's change listeners");
        answer
    }

    /// The timeline's messages, made on first use: a room's history, or a thread's root and its
    /// replies (none for a message that has no thread).
    fn timeline<'a>(
        &self,
        state: &'a mut State,
        timeline: &TimelineId,
    ) -> &'a mut ObservableVector<Arc<TimelineMessage>> {
        if let Some(event) = &timeline.at
            && !state.timelines.contains_key(timeline)
        {
            let live = self.history(state, &timeline.clone().live());
            let window = live
                .iter()
                .position(|message| message.event_id.as_ref() == Some(event))
                .map_or(0..0, |index| {
                    index.saturating_sub(CONTEXT_SIDE)..(index + CONTEXT_SIDE + 1).min(live.len())
                });
            let copies: Vec<_> = live.iter().skip(window.start).take(window.len()).cloned().collect();
            state.windows.insert(timeline.clone(), window);
            state.timelines.insert(
                timeline.clone(),
                ObservableVector::from(copies.into_iter().collect::<Vector<_>>()),
            );
        }
        let made = (!state.timelines.contains_key(timeline)).then(|| match &timeline.thread {
            None => {
                let whole = history(&timeline.room, self.messages_per_room, self.start);
                let tail = self.live_tail.load(Ordering::Relaxed);
                if tail > 0 && tail < whole.len() {
                    let window = whole.len() - tail..whole.len();
                    state.windows.insert(timeline.clone(), window.clone());
                    state
                        .histories
                        .insert(timeline.clone(), whole.iter().cloned().collect());
                    return whole.iter().skip(window.start).cloned().collect();
                }
                whole
            }
            Some(root) => {
                let main = self.timeline(state, &TimelineId::from(&timeline.room));
                let root = main
                    .iter()
                    .find(|message| message.event_id.as_ref() == Some(root))
                    .cloned();
                root.map(|root| thread_history(&root)).unwrap_or_default()
            }
        });
        state
            .timelines
            .entry(timeline.clone())
            .or_insert_with(|| ObservableVector::from(made.unwrap_or_default()))
    }

    /// A message's timeline (of those of its room made so far), position and value.
    fn find(&self, room: &RoomId, id: &MessageId) -> Result<(TimelineId, usize, Arc<TimelineMessage>), BackendError> {
        let mut state = self.state();
        // the room's own timeline is made first: a message there is found before any is opened.
        self.timeline(&mut state, &TimelineId::from(room));
        state
            .timelines
            .iter()
            .filter(|(timeline, _)| &timeline.room == room)
            .find_map(|(timeline, messages)| {
                let index = messages.iter().position(|found| found.message.id == *id)?;
                Some((timeline.clone(), index, Arc::clone(&messages[index])))
            })
            .ok_or(BackendError::UnknownMessage)
    }

    /// A message of the timeline, by its id or its event.
    fn find_ref(
        &self,
        timeline: &TimelineId,
        message: &MessageRef,
    ) -> Result<(usize, Arc<TimelineMessage>), BackendError> {
        let mut state = self.state();
        let messages = self.timeline(&mut state, timeline);
        messages
            .iter()
            .position(|found| match message {
                MessageRef::Local(id) => found.message.id == *id,
                MessageRef::Event(event) => found.event_id.as_ref() == Some(event),
            })
            .map(|index| (index, Arc::clone(&messages[index])))
            .ok_or(BackendError::UnknownMessage)
    }

    /// Replaces a message with what `edit` makes of it.
    fn edit_message(
        &self,
        room: &RoomId,
        id: &MessageId,
        edit: impl FnOnce(&mut TimelineMessage),
    ) -> Result<(), BackendError> {
        let (_, _, message) = self.find(room, id)?;
        let mut changed = (*message).clone();
        edit(&mut changed);
        let changed = Arc::new(changed);
        // a message has the same id in each timeline of its room that holds it (a jump's too).
        let holding: Vec<TimelineId> = self
            .state()
            .timelines
            .iter()
            .filter(|(timeline, messages)| {
                &timeline.room == room && messages.iter().any(|found| found.message.id == *id)
            })
            .map(|(timeline, _)| timeline.clone())
            .collect();
        for timeline in holding {
            self.change(&timeline, |messages| {
                if let Some(index) = messages.iter().position(|found| found.message.id == *id) {
                    messages.set(index, Arc::clone(&changed));
                }
            });
        }
        Ok(())
    }

    fn new_id(&self) -> MessageId {
        MessageId::from(format!("demo-sent-{}", self.next_id.fetch_add(1, Ordering::Relaxed)))
    }

    /// The account's new message in `room`.
    fn own_message(&self, room: &RoomId, body: &str) -> TimelineMessage {
        let id = self.new_id();
        TimelineMessage {
            message: Message {
                id: id.clone(),
                sender: OWN_USER.into(),
                room: Some(room.clone()),
                date: SystemTime::now(),
                state: SendState::Sent,
                is_edited: false,
                body: body.to_owned(),
                attachment: None,
                is_reply: false,
                has_reactions: false,
                links: message::links(body, &[]),
            },
            event_id: Some(EventId::from(id.as_str())),
            sender_name: "Me".to_owned(),
            sender_avatar: None,
            is_own: true,
            is_editable: true,
            mentions_me: false,
            kind: MessageKind::Message,
            media: None,
            styles: Vec::new(),
            reactions: Vec::new(),
            reply: None,
            readers: Vec::new(),
            shared: None,
            thread: None,
        }
    }

    /// The room's pinned messages, `events` in the order they were pinned.
    fn pinned(&self, state: &mut State, room: &RoomId, events: &[EventId]) -> Pins {
        let messages = self.timeline(state, &TimelineId::from(room));
        Pins {
            messages: events
                .iter()
                .filter_map(|event| messages.iter().find(|found| found.event_id.as_ref() == Some(event)))
                .map(|found| PinnedMessage {
                    room: room.clone(),
                    event: found
                        .event_id
                        .clone()
                        .unwrap_or_else(|| EventId::from(found.message.id.as_str())),
                    sender: Participant {
                        user: found.message.sender.clone(),
                        name: found.sender_name.clone(),
                        avatar: found.sender_avatar.clone(),
                    },
                    kind: PreviewKind::from(Kind::Text(&found.message.body)),
                    date: found.message.date,
                })
                .collect(),
            may_pin: true,
            seen: state.seen_pins.get(room).cloned().unwrap_or_default(),
        }
    }

    /// The quote of the message `reply` names, for an answer to it.
    fn quote(&self, timeline: &TimelineId, reply: &MessageRef) -> Option<Quote> {
        let (_, message) = self.find_ref(timeline, reply).ok()?;
        Some(Quote {
            event_id: message.event_id.clone()?,
            sender_name: message.sender_name.clone(),
            sender_avatar: message.sender_avatar.clone(),
            kind: Some(PreviewKind::from(Kind::Text(&message.message.body))),
        })
    }

    /// Adds the account's new message to the timeline; in a thread, its root's summary in the
    /// room's own timeline counts it.
    fn append(&self, timeline: &TimelineId, message: TimelineMessage) {
        let reply = ThreadReply {
            sender: Participant {
                user: message.message.sender.clone(),
                name: message.sender_name.clone(),
                avatar: message.sender_avatar.clone(),
            },
            kind: PreviewKind::from(Kind::Text(&message.message.body)),
            date: message.message.date,
        };
        self.change(timeline, |messages| messages.push_back(Arc::new(message)));
        if let Some(root) = &timeline.thread {
            let main = TimelineId::from(&timeline.room);
            if let Ok((index, root)) = self.find_ref(&main, &MessageRef::Event(root.clone())) {
                let mut changed = (*root).clone();
                let summary = changed.thread.get_or_insert_with(ThreadSummary::default);
                summary.replies += 1;
                summary
                    .participants
                    .retain(|participant| participant.user != reply.sender.user);
                summary.participants.insert(0, reply.sender.clone());
                summary.latest = Some(reply);
                self.change(&main, |messages| messages.set(index, Arc::new(changed)));
            }
        }
    }

    /// The room's threads, as the server lists them: newest activity first, a page from `from`.
    pub(crate) fn threads(&self, room: &RoomId, from: Option<&str>) -> crate::ports::ThreadPage {
        let mut state = self.state();
        let messages = self.timeline(&mut state, &TimelineId::from(room));
        let mut threads: Vec<crate::ports::ListedThread> = messages
            .iter()
            .filter_map(|message| {
                let summary = message.thread.clone()?;
                Some(crate::ports::ListedThread {
                    root: message.event_id.clone()?,
                    sender: Participant {
                        user: message.message.sender.clone(),
                        name: message.sender_name.clone(),
                        avatar: message.sender_avatar.clone(),
                    },
                    kind: PreviewKind::from(Kind::Text(&message.message.body)),
                    date: message.message.date,
                    summary,
                })
            })
            .collect();
        threads.sort_by_key(|thread| {
            std::cmp::Reverse(thread.summary.latest.as_ref().map_or(thread.date, |latest| latest.date))
        });
        let skip: usize = from.and_then(|from| from.parse().ok()).unwrap_or(0);
        let end = skip.saturating_add(THREADS_PAGE).min(threads.len());
        crate::ports::ThreadPage {
            next: (end < threads.len()).then(|| end.to_string()),
            threads: threads.drain(skip.min(end)..end).collect(),
        }
    }

    /// What the room's messages shared, a page of [`SHARED_PAGE`] messages back from `from` (a
    /// place in the history, from its newest end).
    pub(crate) fn shared(&self, room: &RoomId, from: Option<&str>) -> SharedPage {
        let mut state = self.state();
        let messages = self.timeline(&mut state, &TimelineId::from(room));
        let skip: usize = from.and_then(|from| from.parse().ok()).unwrap_or(0);
        let end = (skip + SHARED_PAGE).min(messages.len());
        let items = messages
            .iter()
            .rev()
            .skip(skip)
            .take(end.saturating_sub(skip))
            .flat_map(|message| shared_items(room, message))
            .collect();
        SharedPage {
            items,
            next: (end < messages.len()).then(|| end.to_string()),
        }
    }
}

/// How many messages a page of the shared history reads.
const SHARED_PAGE: usize = 50;

/// How many threads a page of a room's threads lists.
const THREADS_PAGE: usize = 20;

/// What a message shared: its photo, video or file, and each link in its text.
fn shared_items(room: &RoomId, message: &TimelineMessage) -> Vec<SharedItem> {
    let Some(event) = message.event_id.clone() else {
        return Vec::new();
    };
    let item = |content| SharedItem {
        event: event.clone(),
        room: room.clone(),
        sender_name: message.sender_name.clone(),
        date: message.message.date,
        content,
    };
    let mut items: Vec<SharedItem> = match &message.media {
        Some(Media::Photo { picture, .. }) => vec![item(SharedContent::Photo {
            picture: picture.clone(),
            caption: message.message.body.clone(),
        })],
        Some(Media::Video { poster, duration }) => vec![item(SharedContent::Video {
            poster: poster.clone(),
            duration: *duration,
            caption: message.message.body.clone(),
        })],
        Some(Media::File {
            name, size, mimetype, ..
        }) => vec![item(SharedContent::File {
            name: name.clone(),
            size: *size,
            mimetype: mimetype.clone(),
        })],
        None => Vec::new(),
    };
    items.extend(message.message.links.iter().map(|link| {
        item(SharedContent::Link {
            url: link.url.clone(),
            text: message.message.body.clone(),
        })
    }));
    items
}

impl DemoTimelines {
    /// The whole history of a live timeline (made first if new).
    fn history(&self, state: &mut State, live: &TimelineId) -> Vec<Arc<TimelineMessage>> {
        let shown: Vec<_> = self.timeline(state, live).iter().cloned().collect();
        state.histories.get(live).cloned().unwrap_or(shown)
    }

    /// Grows the window of a timeline holding part of its history by up to `count` messages,
    /// older or newer; `true` once it reaches that end (a timeline holding all of it is there).
    fn widen(&self, timeline: &TimelineId, count: usize, older: bool) -> bool {
        let mut state = self.state();
        let whole = self.history(&mut state, &timeline.clone().live());
        let Some(window) = state.windows.get(timeline).cloned() else {
            return true;
        };
        let (added, window) = if older {
            let start = window.start.saturating_sub(count);
            (start..window.start, start..window.end)
        } else {
            let end = (window.end + count).min(whole.len());
            (window.end..end, window.start..end)
        };
        let reached = if older {
            window.start == 0
        } else {
            window.end == whole.len()
        };
        state.windows.insert(timeline.clone(), window);
        let messages = self.timeline(&mut state, timeline);
        for (offset, index) in added.enumerate() {
            let Some(message) = whole.get(index) else { continue };
            if older {
                messages.insert(offset, Arc::clone(message));
            } else {
                messages.push_back(Arc::clone(message));
            }
        }
        reached
    }
}

impl ChatTimelines for DemoTimelines {
    fn changes(&self) -> RoomChanges {
        Box::pin(stream::unfold(self.changes.subscribe(), |mut changes| async move {
            loop {
                match changes.recv().await {
                    Ok(room) => return Some((room, changes)),
                    Err(broadcast::error::RecvError::Lagged(_)) => {}
                    Err(broadcast::error::RecvError::Closed) => return None,
                }
            }
        }))
    }

    /// The whole made-up history is there at once: nothing closes.
    fn hold(&self, _timeline: &TimelineId) -> TimelineHold {
        TimelineHold::new(|| {})
    }

    async fn messages(&self, timeline: &TimelineId) -> Result<DiffStream<Arc<TimelineMessage>>, BackendError> {
        let (values, batches) = {
            let mut state = self.state();
            if let Some(event) = &timeline.at {
                let live = self.history(&mut state, &timeline.clone().live());
                if !live.iter().any(|message| message.event_id.as_ref() == Some(event)) {
                    return Err(BackendError::UnknownMessage);
                }
            }
            self.timeline(&mut state, timeline)
                .subscribe()
                .into_values_and_batched_stream()
        };
        let first = stream::once(async move { vec![eyeball_im::VectorDiff::Reset { values }] });
        Ok(Box::pin(first.chain(batches)))
    }

    async fn prefetch(&self, timeline: &TimelineId) -> Result<(), BackendError> {
        let mut state = self.state();
        self.timeline(&mut state, timeline);
        Ok(())
    }

    async fn load_older(&self, timeline: &TimelineId, count: usize) -> Result<bool, BackendError> {
        #[cfg(test)]
        {
            tokio::time::sleep(Duration::from_millis(self.page_millis.load(Ordering::Relaxed))).await;
            if self.pages_fail.load(Ordering::Relaxed) {
                return Err(BackendError::NotAllowed);
            }
            if self.pages_land_later.load(Ordering::Relaxed) {
                self.landing
                    .lock()
                    .unwrap_or_else(PoisonError::into_inner)
                    .push((timeline.clone(), count));
                return Ok(false);
            }
        }
        Ok(self.widen(timeline, count, true))
    }

    async fn load_newer(&self, timeline: &TimelineId, count: usize) -> Result<bool, BackendError> {
        Ok(self.widen(timeline, count, false))
    }

    async fn focused(&self, timeline: &TimelineId) -> Result<Focused, BackendError> {
        let event = timeline.at.clone().ok_or(BackendError::UnknownMessage)?;
        let (_, message) = self.find_ref(timeline, &MessageRef::Event(event))?;
        Ok(Focused {
            message: message.message.id.clone(),
            thread: timeline.thread.clone(),
        })
    }

    /// The demo's chats have their last five messages unread; their threads are read.
    async fn first_unread(&self, timeline: &TimelineId) -> Result<Unread, BackendError> {
        #[cfg(test)]
        tokio::time::sleep(Duration::from_millis(self.unread_millis.load(Ordering::Relaxed))).await;
        let first = self
            .messages_per_room
            .checked_sub(5)
            .filter(|_| timeline.thread.is_none())
            .map(|index| MessageId::from(format!("{}/{index}", timeline.room)));
        Ok(Unread { first, complete: true })
    }

    async fn index_history(
        &self,
        room: &RoomId,
        since: SystemTime,
        // the demo's chats are short: every read starts at the newest.
        _from: Option<String>,
        max_pages: u32,
    ) -> Result<IndexHistory, BackendError> {
        // pages of 50 messages, as a server gives them.
        let most = max_pages as usize * 50;
        let mut history = IndexHistory::default();
        let mut state = self.state();
        let shown = self.timeline(&mut state, &TimelineId::from(room));
        let newest = shown.iter().rev().filter(|message| message.message.date >= since);
        for message in newest.clone().take(most) {
            let event_id = EventId::from(message.message.id.as_str());
            if matches!(message.media, Some(Media::Photo { .. })) {
                history.images.push(IndexedImage {
                    event_id,
                    room: room.clone(),
                    sender_name: message.sender_name.clone(),
                    caption: message.message.body.clone(),
                    date: message.message.date,
                    is_own: message.is_own,
                });
            } else if let Some(Media::File {
                name, size, mimetype, ..
            }) = &message.media
            {
                history.files.push(IndexedFile {
                    event_id,
                    room: room.clone(),
                    sender_name: message.sender_name.clone(),
                    name: name.clone(),
                    size: *size,
                    mimetype: Some(mimetype.clone()).filter(|mimetype| !mimetype.is_empty()),
                    date: message.message.date,
                    is_own: message.is_own,
                });
            } else if !message.message.body.is_empty() {
                let mut links: Vec<String> = Vec::new();
                for link in message::links(&message.message.body, &message.styles) {
                    if !links.contains(&link.url) {
                        links.push(link.url);
                    }
                }
                history.messages.push(IndexedMessage {
                    event_id,
                    room: room.clone(),
                    sender_name: message.sender_name.clone(),
                    body: message.message.body.clone(),
                    links,
                    thread: None,
                    date: message.message.date,
                    is_own: message.is_own,
                });
            }
        }
        history.reached_start = newest.count() <= most;
        history.reached_since = history.reached_start && shown.iter().any(|message| message.message.date < since);
        Ok(history)
    }

    /// A room's pins: at first a message a while back, in every third room, so the bar shows.
    fn pins(&self, room: &RoomId) -> Result<PinsStream, BackendError> {
        let mut state = self.state();
        if !state.pins.contains_key(room) {
            let first = super::data::room_index(room.as_str()).is_some_and(|index| index % 3 == 0);
            let events: Vec<EventId> = if first {
                let messages = self.timeline(&mut state, &TimelineId::from(room));
                messages
                    .len()
                    .checked_sub(15)
                    .and_then(|index| messages.get(index))
                    .and_then(|message| message.event_id.clone())
                    .into_iter()
                    .collect()
            } else {
                Vec::new()
            };
            let pins = self.pinned(&mut state, room, &events);
            state.pins.insert(room.clone(), (events, watch::Sender::new(pins)));
        }
        let receiver = state
            .pins
            .get(room)
            .map(|(_, sender)| sender.subscribe())
            .ok_or_else(|| BackendError::UnknownChat(ChatId::Room(room.clone())))?;
        Ok(Box::pin(stream::unfold(
            (receiver, true),
            |(mut receiver, first)| async move {
                if !first {
                    receiver.changed().await.ok()?;
                }
                let pins = receiver.borrow_and_update().clone();
                Some((pins, (receiver, false)))
            },
        )))
    }

    async fn mark_pins_seen(&self, room: &RoomId, events: &[EventId]) -> Result<(), BackendError> {
        let mut state = self.state();
        state.seen_pins.insert(room.clone(), events.to_vec());
        let pinned = state
            .pins
            .get(room)
            .map(|(events, _)| events.clone())
            .unwrap_or_default();
        let pins = self.pinned(&mut state, room, &pinned);
        if let Some((_, sender)) = state.pins.get(room) {
            sender.send_replace(pins);
        }
        Ok(())
    }

    async fn set_pinned(&self, room: &RoomId, event: &EventId, pinned: bool) -> Result<(), BackendError> {
        let mut state = self.state();
        let mut events = state
            .pins
            .get(room)
            .map(|(events, _)| events.clone())
            .unwrap_or_default();
        events.retain(|known| known != event);
        if pinned {
            events.push(event.clone());
        }
        let pins = self.pinned(&mut state, room, &events);
        match state.pins.get_mut(room) {
            Some((known, sender)) => {
                *known = events;
                sender.send_replace(pins);
            }
            None => {
                state.pins.insert(room.clone(), (events, watch::Sender::new(pins)));
            }
        }
        Ok(())
    }

    /// Someone types for a few seconds now and then, so the indicator shows.
    fn typing(&self, _room: &RoomId) -> Result<TypingStream, BackendError> {
        let anna = Typist {
            user: UserId::from("@friend0:demo"),
            name: PEOPLE[0].to_owned(),
            avatar: Some(MediaId::from("demo-@friend0:demo")),
        };
        // 3 s quiet, 5 s typing, 10 s quiet, and again.
        Ok(Box::pin(stream::unfold(None, move |typing: Option<bool>| {
            let anna = anna.clone();
            async move {
                let (wait, now) = match typing {
                    None => (3, vec![anna]),
                    Some(true) => (5, Vec::new()),
                    Some(false) => (13, vec![anna]),
                };
                tokio::time::sleep(Duration::from_secs(wait)).await;
                let typing = !now.is_empty();
                Some((now, Some(typing)))
            }
        })))
    }
}

impl ChatSending for DemoTimelines {
    /// Shows the message sending, as a server's local echo, then sent at once; a message with
    /// "fail" in it fails, to show the retry and discard actions.
    async fn send_text(
        &self,
        timeline: &TimelineId,
        composed: &ComposedText,
        reply: Option<&MessageRef>,
    ) -> Result<(), BackendError> {
        let room = &timeline.room;
        let text = composed.text.as_str();
        let mut message = self.own_message(room, text);
        message.styles = pill_styles(composed);
        message.message.state = SendState::Sending { upload: None };
        if let Some(reply) = reply {
            message.reply = self.quote(timeline, reply);
            message.message.is_reply = message.reply.is_some();
        }
        self.state().drafts.remove(timeline);
        let (id, date) = (message.message.id.clone(), message.message.date);
        self.append(timeline, message);
        let answer = if text.contains("fail") {
            SendState::Failed
        } else {
            SendState::Sent
        };
        self.edit_message(room, &id, |message| message.message.state = answer)?;
        // a thread's reply is not the chat's newest message in the list.
        if let Some(account) = &self.sent
            && timeline.thread.is_none()
        {
            account.sent(room, text, date);
        }
        Ok(())
    }

    /// Only the account's own text messages can be edited, as on a server.
    async fn edit(&self, room: &RoomId, message: &MessageId, text: &ComposedText) -> Result<(), BackendError> {
        let (_, _, found) = self.find(room, message)?;
        if !found.is_editable {
            return Err(BackendError::NotAllowed);
        }
        self.edit_message(room, message, |message| {
            text.text.clone_into(&mut message.message.body);
            message.message.is_edited = true;
            message.message.links = message::links(&text.text, &[]);
            message.styles = pill_styles(text);
        })
    }

    async fn delete(&self, room: &RoomId, message: &MessageId) -> Result<(), BackendError> {
        self.edit_message(room, message, |message| {
            message.kind = MessageKind::Deleted;
            message.message.body.clear();
            message.message.attachment = None;
            message.message.has_reactions = false;
            message.message.links.clear();
            message.media = None;
            message.styles.clear();
            message.reactions.clear();
            message.is_editable = false;
        })
    }

    async fn retry(&self, room: &RoomId, message: &MessageId) -> Result<(), BackendError> {
        self.edit_message(room, message, |message| message.message.state = SendState::Sent)
    }

    async fn discard(&self, room: &RoomId, message: &MessageId) -> Result<(), BackendError> {
        let (timeline, index, _) = self.find(room, message)?;
        self.change(&timeline, |messages| {
            if index < messages.len() {
                messages.remove(index);
            }
        });
        Ok(())
    }

    /// Reacting "join thread" to a bridge's thread notice joins the thread: the bridge brings its
    /// replies from the other network, as mautrix-discord does.
    async fn toggle_reaction(&self, room: &RoomId, message: &MessageId, key: &str) -> Result<(), BackendError> {
        let mut joined = false;
        self.edit_message(room, message, |message| {
            toggle(&mut message.reactions, key);
            message.message.has_reactions = !message.reactions.is_empty();
            joined = key == JOIN_THREAD
                && message.message.body.starts_with(THREAD_NOTICE)
                && message
                    .reactions
                    .iter()
                    .any(|reaction| reaction.key == key && reaction.is_mine);
        })?;
        if joined && let Ok((timeline, _, _)) = self.find(room, message) {
            for (index, body) in JOINED_REPLIES.iter().enumerate() {
                let mut reply = self.own_message(room, body);
                reply.message.sender = UserId::from(format!("@friend{index}:demo"));
                seeded::round_name(&PEOPLE, index).clone_into(&mut reply.sender_name);
                reply.sender_avatar = Some(MediaId::from(format!("demo-@friend{index}:demo")));
                reply.is_own = false;
                reply.is_editable = false;
                self.append(&timeline, reply);
            }
        }
        Ok(())
    }

    /// Shows the attachment at once, sent; its upload goes on for a second a megabyte, at most
    /// five (`upload`). Its picture is the file on the device.
    async fn send_attachment(
        &self,
        timeline: &TimelineId,
        attachment: &OutgoingAttachment,
        caption: Option<&str>,
        reply: Option<&MessageRef>,
    ) -> Result<UploadStream, BackendError> {
        let mut message = self.own_message(&timeline.room, caption.unwrap_or_default());
        let picture = |file: &Path, width, height| Picture {
            source: MediaId::from(file.to_string_lossy().into_owned()),
            width,
            height,
        };
        let thumbnail = attachment.thumbnail.as_ref().map(|thumbnail| thumbnail.file.as_path());
        message.media = Some(match attachment.kind {
            OutgoingKind::Photo { width, height } => Media::Photo {
                picture: picture(thumbnail.unwrap_or(&attachment.file), width, height),
                is_animated: attachment.mimetype == "image/gif",
            },
            OutgoingKind::Video {
                width,
                height,
                duration,
            } => Media::Video {
                poster: thumbnail.map(|file| picture(file, width, height)),
                duration: Some(duration),
            },
            OutgoingKind::File => Media::File {
                name: attachment.name.clone(),
                size: Some(attachment.size),
                mimetype: attachment.mimetype.clone(),
                kind: FileKind::Document,
                duration: None,
            },
        });
        message.message.attachment = attachment_of(message.media.as_ref());
        message.is_editable = false;
        if let Some(reply) = reply {
            message.reply = self.quote(timeline, reply);
            message.message.is_reply = message.reply.is_some();
        }
        self.append(timeline, message);
        Ok(upload(attachment.size))
    }

    async fn forward(&self, room: &RoomId, message: &MessageId, target: &ChatId) -> Result<(), BackendError> {
        #[cfg(test)]
        tokio::time::sleep(Duration::from_millis(self.forward_millis.load(Ordering::Relaxed))).await;
        let (_, _, message) = self.find(room, message)?;
        let target = match &self.sent {
            Some(account) => account.send_room(target),
            None => target.room().cloned(),
        }
        .ok_or_else(|| BackendError::UnknownChat(target.clone()))?;
        self.send_text(&TimelineId::from(target), &message.message.body.as_str().into(), None)
            .await
    }

    async fn draft(&self, timeline: &TimelineId) -> Result<Option<Draft>, BackendError> {
        Ok(self.state().drafts.get(timeline).cloned())
    }

    async fn save_draft(
        &self,
        timeline: &TimelineId,
        text: &ComposedText,
        reply: Option<&MessageRef>,
    ) -> Result<(), BackendError> {
        let reply = reply.and_then(|reply| self.quote(timeline, reply));
        let mut state = self.state();
        if text.text.is_empty() && reply.is_none() {
            state.drafts.remove(timeline);
        } else {
            state.drafts.insert(
                timeline.clone(),
                Draft {
                    text: text.clone(),
                    reply,
                },
            );
        }
        Ok(())
    }

    async fn mark_read(&self, _timeline: &TimelineId, _receipt: Receipt) -> Result<(), BackendError> {
        Ok(())
    }

    async fn set_typing(&self, _room: &RoomId, _typing: bool) -> Result<(), BackendError> {
        Ok(())
    }
}

/// Adds the account's reaction `key`, or takes it away.
fn toggle(reactions: &mut Vec<Reaction>, key: &str) {
    match reactions.iter().position(|reaction| reaction.key == key) {
        Some(index) => {
            let Some(reaction) = reactions.get_mut(index) else {
                return;
            };
            if reaction.is_mine {
                reaction.is_mine = false;
                reaction.count = reaction.count.saturating_sub(1);
                if reaction.count == 0 {
                    reactions.remove(index);
                }
            } else {
                reaction.is_mine = true;
                reaction.count = reaction.count.saturating_add(1);
            }
        }
        None => reactions.push(Reaction {
            key: key.to_owned(),
            count: 1,
            is_mine: true,
        }),
    }
}

/// How many steps a made-up upload reports.
const UPLOAD_STEPS: u32 = 20;

/// A made-up upload of `size` bytes: a second a megabyte, at most five, in even steps, then sent.
fn upload(size: u64) -> UploadStream {
    let megabytes = f64::from(u32::try_from(size / 1_000).unwrap_or(u32::MAX)) / 1_000.0;
    let step = Duration::from_secs_f64(megabytes.clamp(1.0, 5.0)) / UPLOAD_STEPS;
    Box::pin(stream::unfold(0, move |done| async move {
        if done > UPLOAD_STEPS {
            return None;
        }
        if done > 0 {
            tokio::time::sleep(step).await;
        }
        let state = if done == UPLOAD_STEPS {
            SendState::Sent
        } else {
            SendState::Sending {
                upload: Some(f64::from(done) / f64::from(UPLOAD_STEPS)),
            }
        };
        Some((state, done + 1))
    }))
}

fn attachment_of(media: Option<&Media>) -> Option<Attachment> {
    match media? {
        Media::Photo { .. } => Some(Attachment::Pictures(NonZeroU32::MIN)),
        Media::Video { poster, .. } => poster.as_ref().map(|_| Attachment::Pictures(NonZeroU32::MIN)),
        Media::File { .. } => Some(Attachment::File),
    }
}

// MARK: the made-up history

/// A room's made-up history, oldest first: a message every 15 minutes or so, three of the user's
/// in turn with three of the others', photos (some without words, sent together into albums),
/// now and then a video, a file, a reaction, an answer to the message ten before, a link, a
/// formatted text; the user's last messages read by two.
#[allow(clippy::too_many_lines)]
fn history(room: &RoomId, count: usize, start: SystemTime) -> Vector<Arc<TimelineMessage>> {
    let seed = stable(room.as_str()) % 97;
    // the two newest messages from others (not the shared reel's) have pills, the newest
    // mentioning the account.
    let mut from_others = (0..count)
        .rev()
        .filter(|index| (index / 3) % 2 != 0 && index + 6 != count);
    let (mentions_me, mentions_petr) = (from_others.next(), from_others.next());
    (0..count)
        .map(|index| {
            let i = index as u64;
            let is_own = (index / 3) % 2 == 0;
            let sender = if is_own {
                OWN_USER.to_owned()
            } else {
                format!("@friend{}:demo", index % 3)
            };
            let id = MessageId::from(format!("{room}/{index}"));
            let mut body = text(i * 31 + 7 + seed);
            let mut media = None;
            if index % 15 == 4 {
                let (width, height) = if index % 2 == 0 { (1200, 900) } else { (900, 1200) };
                media = Some(Media::Photo {
                    picture: Picture {
                        source: MediaId::from(format!("demo-photo-{}.jpg", index % 6)),
                        width,
                        height,
                    },
                    is_animated: false,
                });
                if index % 30 == 4 {
                    body.clear();
                }
            }
            // a reel shared from another network, its caption long enough to fold.
            let shared = (index % 90 == 19 || index + 6 == count).then(|| SharedPost {
                url: format!("https://www.instagram.com/reel/demo{index}/"),
                title: Some(format!("{} on Instagram", seeded::round_name(&PEOPLE, index))),
                description: Some(REEL_CAPTION.to_owned()),
            });
            if index % 45 == 19 || shared.is_some() {
                media = Some(Media::Video {
                    poster: Some(Picture {
                        source: MediaId::from(format!("demo-poster-{}.jpg", index % 4)),
                        width: 1280,
                        height: 720,
                    }),
                    duration: Some(Duration::from_secs(17 + i % 90)),
                });
                body.clear();
            } else if index % 45 == 34 {
                media = Some(Media::File {
                    name: format!("Trip plan {}.pdf", index % 7),
                    size: Some(180_000 + i * 977),
                    mimetype: "application/pdf".to_owned(),
                    kind: FileKind::Document,
                    duration: None,
                });
                body.clear();
            }
            let reactions = if index % 9 == 2 {
                vec![Reaction {
                    key: "❤️".to_owned(),
                    count: 1 + u32::try_from(index % 3).unwrap_or_default(),
                    is_mine: false,
                }]
            } else {
                Vec::new()
            };
            let reply = (index % 12 == 5 && index >= 10).then(|| Quote {
                event_id: EventId::from(format!("{room}/{}", index - 10)),
                sender_name: seeded::round_name(&PEOPLE, index.saturating_sub(10)).to_owned(),
                sender_avatar: ((index - 10) % 3 != 2)
                    .then(|| MediaId::from(format!("demo-@friend{}:demo", (index - 10) % 3))),
                kind: Some(PreviewKind::Text(text((i - 10) * 31 + 7))),
            });
            let readers = if index + 4 == count {
                PEOPLE[..2]
                    .iter()
                    .enumerate()
                    .map(|(friend, name)| Reader {
                        user: UserId::from(format!("@friend{friend}:demo")),
                        name: (*name).to_owned(),
                    })
                    .collect()
            } else {
                Vec::new()
            };
            if index % 20 == 7 {
                body.push_str(" https://example.org/page");
                body.push_str(&index.to_string());
            }
            let mut styles = Vec::new();
            if index % 11 == 3 {
                (body, styles) = html::parse(seeded::round_name(&FORMATTED, index));
            }
            if Some(index) == mentions_me || Some(index) == mentions_petr {
                let html = if Some(index) == mentions_me {
                    MENTIONS_ME
                } else {
                    MENTIONS_PETR
                };
                (body, styles) = html::parse(html);
                media = None;
            }
            let mentions_me = !is_own && mentions(&styles, OWN_USER);
            let links = message::links(&body, &styles);
            // the history covers several days.
            let back = Duration::from_secs((count - index) as u64 * 97 * 9);
            let sender_avatar = (!is_own && index % 3 != 2).then(|| MediaId::from(format!("demo-{sender}")));
            Arc::new(TimelineMessage {
                message: Message {
                    id: id.clone(),
                    sender: UserId::from(sender),
                    room: Some(room.clone()),
                    date: start.checked_sub(back).unwrap_or(SystemTime::UNIX_EPOCH),
                    state: SendState::Sent,
                    is_edited: false,
                    attachment: attachment_of(media.as_ref()),
                    is_reply: reply.is_some(),
                    has_reactions: !reactions.is_empty(),
                    links,
                    body,
                },
                event_id: Some(EventId::from(id.as_str())),
                sender_name: if is_own {
                    "Me".to_owned()
                } else {
                    seeded::round_name(&PEOPLE, index).to_owned()
                },
                sender_avatar,
                is_own,
                is_editable: is_own && !matches!(media, Some(Media::Photo { .. } | Media::Video { .. })),
                mentions_me,
                kind: MessageKind::Message,
                media,
                styles,
                reactions,
                reply,
                readers,
                shared,
                thread: None,
            })
        })
        .map(|message| {
            if !is_thread_root(&message, count) {
                return message;
            }
            let mut started = (*message).clone();
            started.thread = Some(summary_of(&thread_replies(&started)));
            Arc::new(started)
        })
        .collect()
}

/// The pills of a message the account sends, as its own HTML would show them.
fn pill_styles(composed: &ComposedText) -> Vec<TextStyle> {
    let mut styles: Vec<TextStyle> = composed
        .mentions
        .iter()
        .map(|mention| TextStyle {
            kind: StyleKind::Mention(mention.target.clone()),
            range: mention.range.clone(),
        })
        .collect();
    styles.sort_by_key(|style| style.range.start);
    styles
}

/// Whether `styles` have a pill of `user`.
fn mentions(styles: &[TextStyle], user: &str) -> bool {
    styles
        .iter()
        .any(|style| matches!(&style.kind, StyleKind::Mention(MentionTarget::User(found)) if found.as_str() == user))
}

/// What a bridge says in a thread it made from another network's (mautrix-discord's notice);
/// reacting with [`JOIN_THREAD`] joins it there.
const THREAD_NOTICE: &str = "Thread created.";

/// The reaction that joins a bridged thread, the bridge's own already on its notice.
const JOIN_THREAD: &str = "join thread";

/// What the others wrote in a bridged thread before the user joined it.
const JOINED_REPLIES: [&str; 2] = ["Welcome! We were just picking the date.", "Saturday works for me."];

/// The made-up messages that start a thread: a text now and then, the newest a little before
/// the end, so a thread shows on the first screen.
fn is_thread_root(message: &TimelineMessage, count: usize) -> bool {
    let index: usize = message
        .message
        .id
        .as_str()
        .rsplit('/')
        .next()
        .and_then(|index| index.parse().ok())
        .unwrap_or(0);
    message.media.is_none()
        && message.shared.is_none()
        && message.reply.is_none()
        && (index % 25 == 11 || index + 8 == count)
}

/// A thread's made-up replies, oldest first, after its root: the others answering, the user
/// among them now and then; the newest root's first reply is a bridge's notice, its join
/// reaction waiting.
fn thread_replies(root: &TimelineMessage) -> Vec<Arc<TimelineMessage>> {
    let root_event = root
        .event_id
        .clone()
        .unwrap_or_else(|| EventId::from(root.message.id.as_str()));
    let seed = stable(root_event.as_str());
    let count = 2 + usize::try_from(seed % 4).unwrap_or(0);
    let bridged = seed.is_multiple_of(3);
    (0..count)
        .map(|index| {
            let i = index as u64;
            let id = MessageId::from(format!("{}/thread/{index}", root.message.id));
            let notice = bridged && index == 0;
            let is_own = !notice && (seed + i) % 4 == 3;
            let friend = usize::try_from((seed + i) % 3).unwrap_or(0);
            let sender = if notice {
                "@discordbot:demo".to_owned()
            } else if is_own {
                OWN_USER.to_owned()
            } else {
                format!("@friend{friend}:demo")
            };
            let body = if notice {
                format!("{THREAD_NOTICE} React to this message with \"{JOIN_THREAD}\" to join the thread on Discord.")
            } else {
                text(seed + i * 13)
            };
            let reactions = if notice {
                vec![Reaction {
                    key: JOIN_THREAD.to_owned(),
                    count: 1,
                    is_mine: false,
                }]
            } else {
                Vec::new()
            };
            Arc::new(TimelineMessage {
                message: Message {
                    id: id.clone(),
                    sender: UserId::from(sender.as_str()),
                    room: root.message.room.clone(),
                    date: root.message.date + Duration::from_secs(120 * (i + 1)),
                    state: SendState::Sent,
                    is_edited: false,
                    attachment: None,
                    is_reply: false,
                    has_reactions: !reactions.is_empty(),
                    links: message::links(&body, &[]),
                    body,
                },
                event_id: Some(EventId::from(id.as_str())),
                sender_name: if notice {
                    "Discord bridge bot".to_owned()
                } else if is_own {
                    "Me".to_owned()
                } else {
                    seeded::round_name(&PEOPLE, friend).to_owned()
                },
                sender_avatar: (!notice && !is_own).then(|| MediaId::from(format!("demo-{sender}"))),
                is_own,
                is_editable: is_own,
                mentions_me: false,
                kind: MessageKind::Message,
                media: None,
                styles: Vec::new(),
                reactions,
                reply: None,
                readers: Vec::new(),
                shared: None,
                thread: None,
            })
        })
        .collect()
}

/// A thread's summary, from its replies.
fn summary_of(replies: &[Arc<TimelineMessage>]) -> ThreadSummary {
    let participant = |message: &TimelineMessage| Participant {
        user: message.message.sender.clone(),
        name: message.sender_name.clone(),
        avatar: message.sender_avatar.clone(),
    };
    let mut participants: Vec<Participant> = Vec::new();
    for reply in replies.iter().rev() {
        if !participants.iter().any(|known| known.user == reply.message.sender) {
            participants.push(participant(reply));
        }
    }
    ThreadSummary {
        replies: u32::try_from(replies.len()).unwrap_or(u32::MAX),
        latest: replies.last().map(|latest| ThreadReply {
            sender: participant(latest),
            kind: PreviewKind::from(Kind::Text(&latest.message.body)),
            date: latest.message.date,
        }),
        participants,
        unread: 0,
    }
}

/// A thread's own timeline: its root (as the thread shows it, with an id of its own), then its
/// replies.
fn thread_history(root: &TimelineMessage) -> Vector<Arc<TimelineMessage>> {
    let mut first = root.clone();
    first.message.id = MessageId::from(format!("{}/thread", root.message.id));
    first.thread = None;
    first.readers.clear();
    let mut messages = Vector::new();
    messages.push_back(Arc::new(first));
    messages.extend(thread_replies(root));
    messages
}

/// A shared reel's caption, as long as such captions run.
const REEL_CAPTION: &str = "The double slit experiment, explained in under a minute: a single particle passes \
    through both slits at once and interferes with itself, until you look. We filmed it with a laser pointer, \
    a hair and a dark room. Follow for part two, where the detector changes everything. #physics #quantum #science";

#[cfg(test)]
mod tests {
    use futures_util::StreamExt;

    use super::*;

    fn room() -> RoomId {
        RoomId::from("!room1:demo")
    }

    #[test]
    fn the_history_is_the_same_every_run_and_has_all_kinds() {
        let start = SystemTime::UNIX_EPOCH + Duration::from_hours(500_000);
        let first: Vec<_> = history(&room(), 100, start).into_iter().collect();
        assert_eq!(first, history(&room(), 100, start).into_iter().collect::<Vec<_>>());
        assert_eq!(first.len(), 100);
        assert!(first.windows(2).all(|pair| pair[0].message.date < pair[1].message.date));
        assert!(
            first
                .iter()
                .any(|message| matches!(message.media, Some(Media::Photo { .. })))
        );
        assert!(
            first
                .iter()
                .any(|message| matches!(message.media, Some(Media::Video { .. })))
        );
        assert!(
            first
                .iter()
                .any(|message| matches!(message.media, Some(Media::File { .. })))
        );
        assert!(first.iter().any(|message| !message.styles.is_empty()));
        assert!(first.iter().any(|message| message.reply.is_some()));
        assert_eq!(first[96].readers.len(), 2);
        // a photo without words and its neighbours make albums with others' photos only if
        // sent together; the made-up ones are far apart.
        assert_ne!(text(1), text(2));
    }

    #[tokio::test]
    async fn a_reply_quotes_its_message_and_a_deleted_message_shows_as_deleted() {
        let demo = DemoTimelines::new(20);
        let mut messages = demo.messages(&room().into()).await.expect("opens");
        let first = messages.next().await.expect("a reset");
        assert!(matches!(first.as_slice(), [eyeball_im::VectorDiff::Reset { values }] if values.len() == 20));
        demo.send_text(
            &room().into(),
            &"hi".into(),
            Some(&MessageRef::Local("!room1:demo/15".into())),
        )
        .await
        .expect("sends");
        let sent = messages.next().await.expect("a batch");
        let eyeball_im::VectorDiff::PushBack { value } = &sent[0] else {
            panic!("an append");
        };
        assert!(value.reply.is_some());
        let id = value.message.id.clone();
        demo.delete(&room(), &id).await.expect("deletes");
        let (_, _, deleted) = demo.find(&room(), &id).expect("there");
        assert_eq!(deleted.kind, MessageKind::Deleted);
    }

    #[tokio::test]
    async fn a_failing_message_retries_and_the_first_unread_is_five_back() {
        let demo = DemoTimelines::new(20);
        demo.send_text(&room().into(), &"this will fail".into(), None)
            .await
            .expect("queued");
        let (_, _, failed) = demo.find(&room(), &MessageId::from("demo-sent-0")).expect("there");
        assert_eq!(failed.message.state, SendState::Failed);
        demo.retry(&room(), &failed.message.id).await.expect("retries");
        let (_, _, sent) = demo.find(&room(), &failed.message.id).expect("there");
        assert_eq!(sent.message.state, SendState::Sent);
        assert_eq!(
            demo.first_unread(&room().into()).await.expect("known").first,
            Some(MessageId::from("!room1:demo/15"))
        );
    }
}
