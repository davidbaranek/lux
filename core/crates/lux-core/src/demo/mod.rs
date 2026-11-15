//! A made-up account with no server, for measurements, screenshots and the UI tests (`-LuxDemo`):
//! [`DemoAccount`] implements the chat list's ports over chats made up from their number, the
//! same in every run, as many as [`DemoConfig::rooms`] asks (benchmarks take thousands).
//!
//! What the user does (a chat archived, a label made, chats merged) changes the made-up account
//! as a server would, and its lists send the diffs. Its chats' timelines are [`DemoTimelines`],
//! as many messages each as [`DemoConfig::messages_per_room`] asks; a thread runs on the account.

// the demo answers at once: it has no server to wait for.
#![allow(clippy::unused_async_trait_impl)]

mod bridges;
mod data;
mod profile;
mod security;
mod seeded;
mod timeline;

pub use security::{DEMO_RECOVERY_KEY, DemoEncryption, DemoVerification};
pub use timeline::DemoTimelines;

use std::collections::{HashMap, HashSet};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::time::{Duration, SystemTime};

use eyeball_im::{ObservableVector, VectorDiff};
use futures_util::{StreamExt, future, stream};
use tokio::sync::watch;

use self::data::ChatState;
use crate::chat::{Chat, Label, Request, SavedKind, SavedMessage, ScheduledMessage, Snapshot, Space};
use crate::diff;
use crate::ids::{ChatId, DeviceId, EventId, LabelId, MediaId, RoomId, ScheduledId, UserId};
use crate::merge::{self, Merge};
use crate::organizer::{LabelError, Organized, checked_name};
use crate::places::Arrangement;
use crate::ports::{
    AccountProfile, BackendError, ChatAccount, ChatActions, ChatChange, ChatDetails, DeviceSignOut, DiffStream,
    EncryptionSetup, MAX_NAME_LENGTH, Member, NotificationMode, Organizing, OwnDevice, Picture, Profile, RecoveryState,
    RoomDetails, SavedMessages, Scheduling, Security, SharedPage, Spaces, ThreadBackend, ValueStream,
};
use crate::preview::{Preview, PreviewSource, Sender};

/// How big the made-up account is, and when "now" is for it.
#[derive(Clone, Debug)]
pub struct DemoConfig {
    /// How many rooms it has.
    pub rooms: usize,
    /// When its newest message came; the others came before, half an hour apart.
    pub start: SystemTime,
    /// How many messages each chat's timeline holds.
    pub messages_per_room: usize,
    /// Where its encryption starts.
    pub encryption: DemoEncryption,
    /// A request to verify from another device arrives this long after the app listens.
    pub verification_request_after: Option<Duration>,
}

impl DemoConfig {
    /// `rooms` rooms of 200 messages, the newest message this minute.
    #[must_use]
    pub fn new(rooms: usize) -> Self {
        let now = SystemTime::now();
        let seconds = now
            .duration_since(SystemTime::UNIX_EPOCH)
            .map_or(0, |since| since.as_secs());
        Self {
            rooms,
            start: SystemTime::UNIX_EPOCH + Duration::from_secs(seconds - seconds % 60),
            messages_per_room: 200,
            encryption: DemoEncryption::default(),
            verification_request_after: None,
        }
    }
}

impl Default for DemoConfig {
    /// The size the apps' demo shows: 2,000 rooms.
    fn default() -> Self {
        Self::new(2_000)
    }
}

/// The made-up account.
pub struct DemoAccount {
    user: UserId,
    device: DeviceId,
    inner: Arc<Mutex<Inner>>,
    timelines: DemoTimelines,
    security: security::DemoSecurity,
    profile: profile::DemoProfile,
}

/// The account's state: what the user changed, and the lists as last sent. Each change runs
/// under the lock and publishes before it is let go; nothing awaits under it.
struct Inner {
    config: DemoConfig,
    /// Each room's chat as made up, before the user's changes.
    made: Vec<Arc<Chat>>,
    states: HashMap<usize, ChatState>,
    /// The newest message the user sent in each room since launch, and when.
    sent: HashMap<usize, (String, SystemTime)>,
    merges: Vec<Merge>,
    labels: Vec<Label>,
    reminders: HashMap<ChatId, SystemTime>,
    saved: Vec<SavedMessage>,
    scheduled: Vec<ScheduledMessage>,
    answered: HashSet<RoomId>,
    arrangement: Arrangement,
    /// For the ids of what the user makes.
    counter: u64,
    chats: ObservableVector<Arc<Chat>>,
    /// The chats as last sent.
    shown: Vec<Arc<Chat>>,
    requests: ObservableVector<Request>,
    organized: watch::Sender<Arc<Organized>>,
    spaces: watch::Sender<Arc<[Space]>>,
    /// The networks signed in to.
    networks: HashSet<crate::network::Network>,
}

impl DemoAccount {
    /// The made-up account of `config`.
    #[must_use]
    pub fn new(config: DemoConfig) -> Self {
        let made: Vec<Arc<Chat>> = (0..config.rooms)
            .filter_map(|index| data::chat(index, config.start, None).map(Arc::new))
            .collect();
        let spaces: Arc<[Space]> = data::spaces(config.rooms).into();
        let messages_per_room = config.messages_per_room;
        let security = security::DemoSecurity::new(config.encryption, config.verification_request_after);
        let mut inner = Inner {
            made,
            states: HashMap::new(),
            sent: HashMap::new(),
            merges: data::merges(),
            labels: data::labels(),
            reminders: HashMap::new(),
            saved: Vec::new(),
            scheduled: Vec::new(),
            answered: HashSet::new(),
            arrangement: Arrangement::default(),
            counter: 0,
            chats: ObservableVector::new(),
            shown: Vec::new(),
            requests: ObservableVector::new(),
            organized: watch::Sender::new(Arc::default()),
            spaces: watch::Sender::new(spaces),
            networks: HashSet::from([crate::network::Network::Messenger]),
            config,
        };
        inner.publish_chats();
        inner.publish_requests();
        inner.publish_organized();
        let inner = Arc::new(Mutex::new(inner));
        let timelines = DemoTimelines::new(messages_per_room).sending_to(SentMessages(Arc::clone(&inner)));
        Self {
            user: UserId::from("@me:demo"),
            device: DeviceId::from("DEMODEVICE"),
            inner,
            timelines,
            security,
            profile: profile::DemoProfile::new(),
        }
    }

    /// The chat list as it is now, for the apps' parts that read it whole (search, a new
    /// conversation's chats).
    #[must_use]
    pub fn snapshot(&self) -> Snapshot {
        let inner = self.lock();
        Snapshot {
            chats: inner.shown.clone(),
            spaces: inner.spaces.borrow().to_vec(),
            requests: inner.requests.iter().cloned().map(Arc::new).collect(),
            labels: inner.labels.clone(),
            saved: inner.saved.iter().cloned().map(Arc::new).collect(),
            scheduled: inner.scheduled.iter().cloned().map(Arc::new).collect(),
        }
    }

    fn lock(&self) -> MutexGuard<'_, Inner> {
        lock(&self.inner)
    }
}

fn lock(inner: &Mutex<Inner>) -> MutexGuard<'_, Inner> {
    // every change is published before the lock is let go: a panic leaves no half-change.
    inner.lock().unwrap_or_else(PoisonError::into_inner)
}

/// Where the timelines tell the account what the user sent: the chat shows it as its newest
/// message, and moves up, as a server's list does.
#[derive(Clone)]
pub(crate) struct SentMessages(Arc<Mutex<Inner>>);

impl SentMessages {
    /// The room a message to `chat` goes to (a merged chat's default room).
    pub(crate) fn send_room(&self, chat: &ChatId) -> Option<RoomId> {
        chat.send_room(&lock(&self.0).merges)
    }

    /// The user sent `body` in `room` at `at`.
    pub(crate) fn sent(&self, room: &RoomId, body: &str, at: SystemTime) {
        let mut inner = lock(&self.0);
        let Some(index) = data::room_index(room.as_str()).filter(|&index| index < inner.made.len()) else {
            return;
        };
        inner.sent.insert(index, (body.to_owned(), at));
        inner.publish_chats();
    }
}

impl Inner {
    /// The chats the list shows: the made-up ones with the user's changes, what they sent,
    /// reminders and merges, the newest first.
    fn composed(&self) -> Vec<Arc<Chat>> {
        let start = self.config.start;
        let chats: Vec<Arc<Chat>> = self
            .made
            .iter()
            .enumerate()
            .filter_map(|(index, made)| match self.states.get(&index) {
                Some(state) => data::chat(index, start, Some(state)).map(Arc::new),
                None => Some(Arc::clone(made)),
            })
            .map(|chat| self.reminded(self.with_sent(chat)))
            .collect();
        let mut chats: Vec<Arc<Chat>> = merge::fold(chats, &self.merges)
            .into_iter()
            .map(|chat| if chat.is_merged() { self.reminded(chat) } else { chat })
            .collect();
        // a stable sort: the made-up order is already the newest first.
        chats.sort_by_key(|chat| std::cmp::Reverse(chat.date));
        chats
    }

    /// `chat` with the newest message the user sent in it, if any.
    fn with_sent(&self, mut chat: Arc<Chat>) -> Arc<Chat> {
        let sent = chat
            .id
            .room()
            .and_then(|room| data::room_index(room.as_str()))
            .and_then(|index| self.sent.get(&index));
        if let Some((body, at)) = sent {
            let chat = Arc::make_mut(&mut chat);
            chat.preview = Some(Preview::new(PreviewSource::Text(body), Sender::Own, chat.is_group));
            chat.date = Some(*at);
        }
        chat
    }

    /// `chat` with the reminder the user set on it, shared when it already has it.
    fn reminded(&self, mut chat: Arc<Chat>) -> Arc<Chat> {
        let reminder = self.reminders.get(&chat.id).copied();
        if chat.reminder != reminder && (reminder.is_some() || !chat.is_merged()) {
            Arc::make_mut(&mut chat).reminder = reminder;
        }
        chat
    }

    fn publish_chats(&mut self) {
        let next = self.composed();
        let changes = diff::shared_changes(&self.shown, &next, |chat| &chat.id);
        if !changes.is_empty() {
            apply(&mut self.chats, changes);
        }
        self.shown = next;
    }

    fn publish_requests(&mut self) {
        let next: Vec<Request> = data::requests()
            .into_iter()
            .filter(|request| !self.answered.contains(&request.id))
            .collect();
        let shown: Vec<Request> = self.requests.iter().cloned().collect();
        let changes = diff::changes(&shown, &next, |request| &request.id);
        if !changes.is_empty() {
            apply(&mut self.requests, changes);
        }
    }

    fn publish_organized(&mut self) {
        self.organized.send_replace(Arc::new(Organized {
            merges: self.merges.clone(),
            labels: self.labels.clone(),
            saved: self.saved.clone(),
            arrangement: self.arrangement.clone(),
            ..Organized::default()
        }));
    }

    fn next_id<Id: From<String>>(&mut self, kind: &str) -> Id {
        self.counter += 1;
        Id::from(format!("demo-{kind}-{}", self.counter))
    }

    /// The rooms a chat of the list stands for: a merged chat's, else its own.
    fn rooms_of(&self, chat: &ChatId) -> Vec<RoomId> {
        chat.rooms(&self.merges)
    }

    fn label(&mut self, id: &LabelId) -> Result<&mut Label, BackendError> {
        self.labels
            .iter_mut()
            .find(|label| label.id == *id)
            .ok_or(BackendError::Label(LabelError::NotFound))
    }

    fn check_label_name(&self, name: &str) -> Result<String, BackendError> {
        Ok(checked_name(name, &self.labels)?)
    }
}

/// Applies diffs to a list in one batch, for the subscribers to receive as one.
fn apply<T: Clone + Send + Sync + 'static>(list: &mut ObservableVector<T>, diffs: Vec<VectorDiff<T>>) {
    let mut transaction = list.transaction();
    for diff in diffs {
        match diff {
            VectorDiff::Append { values } => transaction.append(values),
            VectorDiff::Clear => transaction.clear(),
            VectorDiff::PushFront { value } => transaction.push_front(value),
            VectorDiff::PushBack { value } => transaction.push_back(value),
            VectorDiff::PopFront => drop(transaction.pop_front()),
            VectorDiff::PopBack => drop(transaction.pop_back()),
            VectorDiff::Insert { index, value } => transaction.insert(index, value),
            VectorDiff::Set { index, value } => drop(transaction.set(index, value)),
            VectorDiff::Remove { index } => drop(transaction.remove(index)),
            VectorDiff::Truncate { length } => transaction.truncate(length),
            VectorDiff::Reset { values } => {
                transaction.clear();
                transaction.append(values);
            }
        }
    }
    transaction.commit();
}

/// The list now, as a `Reset`, then each batch.
fn subscribe<T: Clone + Send + Sync + 'static>(list: &ObservableVector<T>) -> DiffStream<T> {
    let (values, batches) = list.subscribe().into_values_and_batched_stream();
    Box::pin(stream::once(future::ready(vec![VectorDiff::Reset { values }])).chain(batches))
}

/// The value now, then each new one.
fn watched<T: Clone + Send + Sync + 'static>(receiver: watch::Receiver<T>) -> ValueStream<T> {
    Box::pin(stream::unfold((receiver, true), |(mut receiver, first)| async move {
        if !first {
            receiver.changed().await.ok()?;
        }
        let value = receiver.borrow_and_update().clone();
        Some((value, (receiver, false)))
    }))
}

impl ChatAccount for DemoAccount {
    fn own_user_id(&self) -> &UserId {
        &self.user
    }

    fn device_id(&self) -> &DeviceId {
        &self.device
    }

    fn chats(&self) -> DiffStream<Arc<Chat>> {
        subscribe(&self.lock().chats)
    }

    fn requests(&self) -> DiffStream<Request> {
        subscribe(&self.lock().requests)
    }

    async fn wait_for_first_sync(&self) {}

    fn session_end(&self) -> impl Future<Output = ()> + Send + 'static {
        std::future::pending()
    }

    async fn pause_sync(&self) {}

    async fn resume_sync(&self) {}

    async fn sign_out(&self) -> Result<(), BackendError> {
        Ok(())
    }
}

impl ChatActions for DemoAccount {
    async fn change(&self, chat: &ChatId, change: ChatChange) -> Result<(), BackendError> {
        let mut inner = self.lock();
        let rooms: Vec<usize> = inner
            .rooms_of(chat)
            .iter()
            .filter_map(|room| data::room_index(room.as_str()))
            .filter(|&index| index < inner.made.len())
            .collect();
        if rooms.is_empty() {
            return Err(BackendError::UnknownChat(chat.clone()));
        }
        let next_pin = inner.shown.iter().filter_map(|chat| chat.pinned).fold(0.0, f64::max) + 1.0;
        for index in rooms {
            let state = inner.states.entry(index).or_insert_with(|| {
                // the first change keeps what the chat was made with.
                ChatState {
                    pinned: (index < 3).then(|| f64::from(u32::try_from(index).unwrap_or(0))),
                    ..ChatState::default()
                }
            });
            match change {
                ChatChange::Read => state.unread = Some(false),
                ChatChange::Unread => state.unread = Some(true),
                ChatChange::Mute => {
                    state.muted = Some(true);
                    state.notifications = None;
                }
                ChatChange::Unmute => {
                    state.muted = Some(false);
                    state.notifications = None;
                }
                ChatChange::LowPriority => {
                    state.low_priority = Some(true);
                    state.archived = None;
                }
                ChatChange::Inbox => {
                    state.low_priority = Some(false);
                    state.archived = None;
                }
                ChatChange::Archive => state.archived = Some(true),
                ChatChange::Unarchive => state.archived = Some(false),
                ChatChange::Delete => state.deleted = true,
                ChatChange::Pin => state.pinned = Some(next_pin),
                ChatChange::Unpin => state.pinned = None,
            }
        }
        inner.publish_chats();
        Ok(())
    }

    async fn answer_request(&self, room: &RoomId, _accept: bool) -> Result<(), BackendError> {
        let mut inner = self.lock();
        inner.answered.insert(room.clone());
        inner.publish_requests();
        Ok(())
    }
}

impl Organizing for DemoAccount {
    fn organized(&self) -> ValueStream<Arc<Organized>> {
        watched(self.lock().organized.subscribe())
    }

    async fn make_label(&self, name: &str) -> Result<Label, BackendError> {
        let mut inner = self.lock();
        let name = inner.check_label_name(name)?;
        let label = Label {
            id: inner.next_id("label"),
            name,
            chats: HashSet::new(),
        };
        inner.labels.push(label.clone());
        inner.publish_organized();
        Ok(label)
    }

    async fn remove_label(&self, id: &LabelId) -> Result<(), BackendError> {
        let mut inner = self.lock();
        inner.labels.retain(|label| label.id != *id);
        inner.publish_organized();
        Ok(())
    }

    async fn set_in_label(&self, chat: &ChatId, id: &LabelId, included: bool) -> Result<(), BackendError> {
        let mut inner = self.lock();
        let label = inner.label(id)?;
        if included {
            label.chats.insert(chat.clone());
        } else {
            label.chats.remove(chat);
        }
        inner.publish_organized();
        Ok(())
    }

    async fn set_reminder(&self, chat: &ChatId, at: Option<SystemTime>) -> Result<(), BackendError> {
        let mut inner = self.lock();
        match at {
            Some(at) => inner.reminders.insert(chat.clone(), at),
            None => inner.reminders.remove(chat),
        };
        inner.publish_chats();
        Ok(())
    }

    async fn merge(&self, chats: &[ChatId], name: &str, default_room: &RoomId) -> Result<ChatId, BackendError> {
        let mut inner = self.lock();
        let rooms: Vec<RoomId> = chats.iter().flat_map(|chat| inner.rooms_of(chat)).collect();
        let id = inner.next_id("merge");
        let organized = Organized {
            merges: inner.merges.clone(),
            ..Organized::default()
        };
        let (merges, chat) = organized.merging(&rooms, name, default_room, id);
        inner.merges = merges;
        inner.publish_chats();
        inner.publish_organized();
        Ok(chat)
    }

    async fn unmerge(&self, chat: &ChatId) -> Result<(), BackendError> {
        let mut inner = self.lock();
        inner.merges.retain(|merge| merge.chat_id() != *chat);
        inner.publish_chats();
        inner.publish_organized();
        Ok(())
    }

    async fn set_arrangement(&self, arrangement: &Arrangement) -> Result<(), BackendError> {
        let mut inner = self.lock();
        inner.arrangement = arrangement.clone();
        inner.publish_organized();
        Ok(())
    }
}

impl ThreadBackend for DemoAccount {
    type Timelines = DemoTimelines;

    fn timelines(&self) -> &DemoTimelines {
        &self.timelines
    }
}

impl SavedMessages for DemoAccount {
    async fn save_message(&self, room: &RoomId, event: &EventId) -> Result<(), BackendError> {
        let mut inner = self.lock();
        let (body, is_own, sender) = data::message(event.as_str()).unwrap_or_default();
        let now = SystemTime::now();
        inner.saved.retain(|saved| saved.event != *event);
        inner.saved.insert(
            0,
            SavedMessage {
                event: event.clone(),
                room: room.clone(),
                sender_name: if is_own { "Me" } else { sender }.to_owned(),
                is_own,
                body,
                kind: SavedKind::Text,
                file_name: String::new(),
                date: now,
                saved_at: now,
            },
        );
        inner.publish_organized();
        Ok(())
    }

    async fn unsave_message(&self, _room: &RoomId, event: &EventId) -> Result<(), BackendError> {
        let mut inner = self.lock();
        inner.saved.retain(|saved| saved.event != *event);
        inner.publish_organized();
        Ok(())
    }
}

impl DemoAccount {
    /// The number of a room the account has.
    fn room_number(inner: &Inner, room: &RoomId) -> Result<usize, BackendError> {
        data::room_index(room.as_str())
            .filter(|&index| index < inner.made.len())
            .ok_or_else(|| BackendError::UnknownChat(ChatId::Room(room.clone())))
    }

    /// Changes what the user changed of `room` from its details, and shows it in the list.
    fn change_room(&self, room: &RoomId, change: impl FnOnce(&mut ChatState)) -> Result<(), BackendError> {
        let mut inner = self.lock();
        let index = Self::room_number(&inner, room)?;
        change(inner.states.entry(index).or_insert_with(|| ChatState {
            pinned: (index < 3).then(|| f64::from(u32::try_from(index).unwrap_or(0))),
            ..ChatState::default()
        }));
        inner.publish_chats();
        Ok(())
    }
}

impl ChatDetails for DemoAccount {
    async fn room_details(&self, room: &RoomId) -> Result<RoomDetails, BackendError> {
        let inner = self.lock();
        let index = Self::room_number(&inner, room)?;
        Ok(data::details(index, inner.states.get(&index)))
    }

    async fn members(&self, room: &RoomId) -> Result<Vec<Member>, BackendError> {
        let inner = self.lock();
        let index = Self::room_number(&inner, room)?;
        Ok(data::members(index, inner.states.get(&index)))
    }

    async fn shared(&self, room: &RoomId, from: Option<&str>) -> Result<SharedPage, BackendError> {
        Self::room_number(&self.lock(), room)?;
        Ok(self.timelines.shared(room, from))
    }

    async fn set_notifications(&self, chat: &ChatId, mode: NotificationMode) -> Result<(), BackendError> {
        let rooms = self.lock().rooms_of(chat);
        if rooms.is_empty() {
            return Err(BackendError::UnknownChat(chat.clone()));
        }
        for room in &rooms {
            self.change_room(room, |state| {
                state.notifications = Some(mode);
                state.muted = Some(matches!(mode, NotificationMode::Off | NotificationMode::Mentions));
            })?;
        }
        Ok(())
    }

    async fn rename_room(&self, room: &RoomId, name: &str) -> Result<(), BackendError> {
        let name = name.trim();
        if name.chars().count() > MAX_NAME_LENGTH {
            return Err(BackendError::NameTooLong);
        }
        let name = name.to_owned();
        self.change_room(room, |state| state.name = (!name.is_empty()).then_some(name))
    }

    async fn set_topic(&self, room: &RoomId, topic: &str) -> Result<(), BackendError> {
        let topic = topic.trim().to_owned();
        self.change_room(room, |state| state.topic = Some(topic))
    }

    async fn set_room_avatar(&self, room: &RoomId, picture: Picture) -> Result<(), BackendError> {
        if picture.data.is_empty() {
            return Err(BackendError::file("the picture is empty"));
        }
        let avatar = {
            let mut inner = self.lock();
            inner.next_id::<MediaId>("room-picture")
        };
        self.change_room(room, |state| state.avatar = Some(data::PictureChange::Set(avatar)))
    }

    async fn remove_room_avatar(&self, room: &RoomId) -> Result<(), BackendError> {
        self.change_room(room, |state| state.avatar = Some(data::PictureChange::Removed))
    }

    async fn leave(&self, chat: &ChatId) -> Result<(), BackendError> {
        self.change(chat, ChatChange::Delete).await
    }
}

impl Spaces for DemoAccount {
    fn spaces(&self) -> ValueStream<Arc<[Space]>> {
        watched(self.lock().spaces.subscribe())
    }
}

impl AccountProfile for DemoAccount {
    async fn profile(&self) -> Result<Profile, BackendError> {
        Ok(self.profile.profile(&self.user))
    }

    async fn set_name(&self, name: &str) -> Result<(), BackendError> {
        self.profile.set_name(name)
    }

    async fn set_avatar(&self, picture: Picture) -> Result<MediaId, BackendError> {
        self.profile.set_avatar(&picture)
    }

    async fn remove_avatar(&self) -> Result<(), BackendError> {
        self.profile.remove_avatar();
        Ok(())
    }
}

impl Security for DemoAccount {
    type Verification = DemoVerification;

    async fn is_device_verified(&self) -> bool {
        self.security.is_device_verified().await
    }

    fn encryption_setup(&self) -> ValueStream<EncryptionSetup> {
        self.security.encryption_setup()
    }

    async fn verify_this_device(&self) -> Result<DemoVerification, BackendError> {
        self.security.verify_this_device().await
    }

    async fn own_devices(&self) -> Result<Vec<OwnDevice>, BackendError> {
        self.security.own_devices().await
    }

    async fn verify_device(&self, device: &str) -> Result<DemoVerification, BackendError> {
        self.security.verify_device(device).await
    }

    async fn device_sign_out(&self, device: &str) -> Result<DeviceSignOut, BackendError> {
        self.security.device_sign_out(device).await
    }

    async fn sign_out_device(&self, device: &str, password: &str) -> Result<(), BackendError> {
        self.security.sign_out_device(device, password).await
    }

    fn verification_requests(&self) -> ValueStream<Arc<DemoVerification>> {
        self.security.verification_requests()
    }

    fn recovery_state(&self) -> RecoveryState {
        self.security.recovery_state()
    }

    async fn recover(&self, key: &str) -> Result<(), BackendError> {
        self.security.recover(key).await
    }

    async fn set_up_recovery(&self) -> Result<String, BackendError> {
        self.security.set_up_recovery().await
    }
}

impl Scheduling for DemoAccount {
    async fn can_send_later(&self, _room: &RoomId) -> bool {
        true
    }

    async fn send_later(
        &self,
        room: &RoomId,
        text: &str,
        _reply_to: Option<&EventId>,
        at: SystemTime,
    ) -> Result<ScheduledId, BackendError> {
        if at <= SystemTime::now() {
            return Err(BackendError::TimePassed);
        }
        let mut inner = self.lock();
        let id: ScheduledId = inner.next_id("scheduled");
        inner.scheduled.push(ScheduledMessage {
            id: id.clone(),
            room: room.clone(),
            body: text.to_owned(),
            send_at: at,
        });
        inner.scheduled.sort_by_key(|message| message.send_at);
        Ok(id)
    }

    async fn scheduled(&self) -> Result<Vec<ScheduledMessage>, BackendError> {
        Ok(self.lock().scheduled.clone())
    }

    async fn cancel_scheduled(&self, id: &ScheduledId) -> Result<(), BackendError> {
        let mut inner = self.lock();
        let before = inner.scheduled.len();
        inner.scheduled.retain(|message| message.id != *id);
        if inner.scheduled.len() == before {
            return Err(BackendError::NotWaiting);
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use std::time::{Duration, SystemTime};

    use futures_util::StreamExt;

    use super::{DemoAccount, DemoConfig};
    use crate::chat::Folder;
    use crate::ids::{ChatId, RoomId};
    use crate::ports::{ChatAccount, ChatActions, ChatChange, ChatSending, Organizing, Scheduling, ThreadBackend};
    use crate::preview::{Author, PreviewKind};

    fn demo(rooms: usize) -> DemoAccount {
        DemoAccount::new(DemoConfig {
            rooms,
            start: SystemTime::UNIX_EPOCH + Duration::from_hours(500_000),
            ..DemoConfig::new(0)
        })
    }

    #[tokio::test]
    async fn the_list_folds_janas_chats_and_follows_a_change() {
        let demo = demo(30);
        let snapshot = demo.snapshot();
        assert_eq!(snapshot.chats.len(), 29);
        let merged = snapshot.chats.iter().find(|chat| chat.is_merged()).unwrap();
        assert_eq!(merged.id, ChatId::from("merge:demo-jana"));
        assert_eq!(snapshot.requests.len(), 2);
        let mut chats = demo.chats();
        let first = chats.next().await.unwrap();
        assert_eq!(first.len(), 1);
        demo.change(&ChatId::from("!room1:demo"), ChatChange::Archive)
            .await
            .unwrap();
        let batch = chats.next().await.unwrap();
        assert!(!batch.is_empty());
        let archived = demo.snapshot();
        let chat = archived
            .chats
            .iter()
            .find(|chat| chat.id == ChatId::from("!room1:demo"))
            .unwrap();
        assert_eq!(chat.folder, Folder::Archive);
        assert!(demo.change(&ChatId::from("!nope"), ChatChange::Pin).await.is_err());
    }

    #[tokio::test]
    async fn a_groups_details_change_as_its_admin_changes_them_and_the_list_follows() {
        use crate::details::SharedHistory;
        use crate::ports::{ChatDetails, NotificationMode, SharedKind};

        let demo = demo(30);
        let family = RoomId::from("!room2:demo");
        let details = demo.room_details(&family).await.unwrap();
        assert!(details.may.rename && !details.is_direct);
        assert_eq!(demo.members(&family).await.unwrap().len(), 6);
        // work is run by others, and big enough to search.
        let work = RoomId::from("!room6:demo");
        assert!(!demo.room_details(&work).await.unwrap().may.rename);
        assert_eq!(demo.members(&work).await.unwrap().len(), 240);

        demo.rename_room(&family, " Nováks ").await.unwrap();
        demo.set_notifications(&ChatId::Room(family.clone()), NotificationMode::Mentions)
            .await
            .unwrap();
        let details = demo.room_details(&family).await.unwrap();
        assert_eq!(details.name, "Nováks");
        assert_eq!(details.notifications, NotificationMode::Mentions);
        let chat = demo
            .snapshot()
            .chats
            .iter()
            .find(|chat| chat.id == ChatId::Room(family.clone()))
            .cloned()
            .unwrap();
        assert_eq!(chat.name, "Nováks");
        assert!(chat.is_muted);

        let mut photos = SharedHistory::new(vec![family], SharedKind::Media);
        let first = photos.next(&demo, 5).await.unwrap();
        assert_eq!(first.len(), 5);
        assert!(first.windows(2).all(|pair| pair[0].date >= pair[1].date));
    }

    #[tokio::test]
    async fn a_message_sent_in_the_demo_shows_as_its_chats_newest_and_moves_it_up() {
        let demo = DemoAccount::new(DemoConfig::new(30));
        let room = RoomId::from("!room20:demo");
        let mut chats = demo.chats();
        let mut rows = eyeball_im::Vector::new();
        for diff in chats.next().await.unwrap() {
            diff.apply(&mut rows);
        }
        assert_ne!(rows[0].id, ChatId::Room(room.clone()));

        demo.timelines().send_text(&room, "on my way", None).await.unwrap();

        for diff in chats.next().await.unwrap() {
            diff.apply(&mut rows);
        }
        let first = &rows[0];
        assert_eq!(first.id, ChatId::Room(room));
        let preview = first.preview.as_ref().unwrap();
        assert_eq!(preview.kind, PreviewKind::Text("on my way".to_owned()));
        assert_eq!(preview.author, Some(Author::Own));
        assert!(first.date > rows[1].date);
    }

    #[tokio::test]
    async fn a_message_forwarded_to_a_merged_chat_goes_to_its_default_room() {
        // made-up messages up to now: the forwarded one, sent now, is the newest.
        let demo = DemoAccount::new(DemoConfig::new(30));
        let jana = ChatId::from("merge:demo-jana");
        demo.timelines()
            .forward(&RoomId::from("!room20:demo"), &"!room20:demo/5".into(), &jana)
            .await
            .unwrap();
        // the default room (`!room4:demo`) took it: the merged chat is the newest.
        let snapshot = demo.snapshot();
        let newest = snapshot.chats.iter().max_by_key(|chat| chat.date).unwrap();
        assert_eq!(newest.id, jana);
        let gone = ChatId::from("merge:gone");
        let refused = demo
            .timelines()
            .forward(&RoomId::from("!room20:demo"), &"!room20:demo/5".into(), &gone)
            .await;
        assert!(refused.is_err());
    }

    #[tokio::test]
    async fn labels_merges_and_waiting_messages_change_as_asked() {
        let demo = demo(30);
        let label = demo.make_label(" Trips ").await.unwrap();
        assert_eq!(label.name, "Trips");
        assert!(demo.make_label("trips").await.is_err());
        demo.set_in_label(&ChatId::from("!room2:demo"), &label.id, true)
            .await
            .unwrap();
        let organized = demo.organized().next().await.unwrap();
        assert!(
            organized
                .labels
                .iter()
                .any(|found| found.chats.contains(&ChatId::from("!room2:demo")))
        );
        let merged = demo
            .merge(
                &[ChatId::from("!room1:demo"), ChatId::from("!room2:demo")],
                "Both",
                &"!room1:demo".into(),
            )
            .await
            .unwrap();
        assert!(demo.snapshot().chats.iter().any(|chat| chat.id == merged));
        demo.unmerge(&merged).await.unwrap();
        assert!(!demo.snapshot().chats.iter().any(|chat| chat.id == merged));
        let later = SystemTime::now() + Duration::from_secs(3_600);
        let id = demo.send_later(&"!room1:demo".into(), "hi", None, later).await.unwrap();
        assert_eq!(demo.scheduled().await.unwrap().len(), 1);
        demo.cancel_scheduled(&id).await.unwrap();
        assert!(demo.cancel_scheduled(&id).await.is_err());
    }
}
