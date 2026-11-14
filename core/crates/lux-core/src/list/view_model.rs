//! The chat list's view model: one task owns the list's state, follows the account's streams,
//! runs the user's intents against the ports, and sends its listener one batch per frame.

use std::collections::HashSet;
use std::future::Future;
use std::mem;
use std::sync::Arc;
use std::time::{Duration, SystemTime};

use eyeball_im::VectorDiff;
use futures_util::StreamExt;
use futures_util::stream::{self, BoxStream, SelectAll};
use tokio::runtime::Handle;
use tokio::sync::mpsc;
use tokio::task::JoinHandle;
use tokio::time::{Instant, sleep_until};

use super::ListUpdate;
use super::loading::LoadTracker;
use super::state::ListState;
use crate::FRAME;
use crate::actions::Actions;
use crate::chat::{Chat, Request, ScheduledMessage, Space};
use crate::ids::{ChatId, EventId, LabelId, RoomId, ScheduledId};
use crate::organizer::Organized;
use crate::places::{Arrangement, ChatFilter, ChatOrder, PlaceId};
use crate::ports::{
    BackendError, ChatAccount, ChatActions, ChatChange, Diffs, Organizing, SavedMessages, Scheduling, Spaces,
};

/// Once the server has answered, the list is done when this passes with no new chats.
const SETTLE: Duration = Duration::from_millis(500);

/// Receives the list's batches, from the view model's task.
pub trait ListListener: Send + Sync {
    /// One frame's changes; the first batch holds the whole list.
    fn on_update(&self, update: ListUpdate);
    /// An intent's action failed.
    fn on_error(&self, error: BackendError);
}

/// The ports a chat list needs.
pub trait ChatListBackend:
    ChatAccount + ChatActions + Organizing + SavedMessages + Spaces + Scheduling + 'static
{
}

impl<T: ChatAccount + ChatActions + Organizing + SavedMessages + Spaces + Scheduling + 'static> ChatListBackend for T {}

/// How a list starts.
#[derive(Clone, Debug)]
pub struct ListSetup {
    /// The place shown.
    pub place: PlaceId,
    /// Which of its chats show.
    pub filter: Option<ChatFilter>,
    /// In which order.
    pub order: ChatOrder,
    /// The chats with a draft on this device (for [`ChatFilter::Drafts`]).
    pub drafts: HashSet<ChatId>,
}

impl Default for ListSetup {
    fn default() -> Self {
        Self {
            place: PlaceId::INBOX,
            filter: None,
            order: ChatOrder::default(),
            drafts: HashSet::new(),
        }
    }
}

/// What the apps ask of the list, and what its own actions report back.
enum Intent {
    Place(PlaceId),
    Filter(Option<ChatFilter>),
    Order(ChatOrder),
    Drafts(HashSet<ChatId>),
    Refresh,
    Reorder(Vec<PlaceId>),
    Hide(PlaceId, bool),
    ShowAllPlaces,
    Act(Action),
    /// The waiting messages, read.
    Scheduled(Vec<ScheduledMessage>),
    /// An arrangement's write ended.
    Arranged,
}

/// What an intent does through the ports.
enum Action {
    Change(ChatId, ChatChange),
    Answer(RoomId, bool),
    MakeLabel {
        name: String,
        with: Option<ChatId>,
    },
    RemoveLabel(LabelId),
    SetInLabel {
        chat: ChatId,
        label: LabelId,
        included: bool,
    },
    SetReminder(ChatId, Option<SystemTime>),
    Unsave(RoomId, EventId),
    CancelScheduled(ScheduledId),
    Merge {
        chats: Vec<ChatId>,
        name: String,
        default_room: RoomId,
    },
    Unmerge(ChatId),
    Arrange(Arrangement),
    ReadScheduled,
}

/// A chat list: the handle on its task. Dropped, the task stops.
pub struct ChatListViewModel {
    intents: mpsc::UnboundedSender<Intent>,
    task: JoinHandle<()>,
}

impl ChatListViewModel {
    /// Starts the list on `runtime`: from the device's last list `kept` gives, then from the
    /// account `backend` gives (`None`: there is none, the kept list stays). Batches go to
    /// `listener`. The handle takes intents at once: they wait in order until the kept list is in.
    pub fn start<B, K, F>(
        runtime: &Handle,
        kept: K,
        backend: F,
        setup: ListSetup,
        listener: Arc<dyn ListListener>,
    ) -> Self
    where
        B: ChatListBackend,
        K: Future<Output = Vec<Chat>> + Send + 'static,
        F: Future<Output = Option<Arc<B>>> + Send + 'static,
    {
        let (intents, inbox) = mpsc::unbounded_channel();
        let task = runtime.spawn(run(kept, backend, setup, inbox, intents.clone(), listener));
        Self { intents, task }
    }

    fn send(&self, intent: Intent) {
        // the task ends only when this handle goes.
        let _ = self.intents.send(intent);
    }

    /// Shows `place`.
    pub fn select_place(&self, place: PlaceId) {
        self.send(Intent::Place(place));
    }

    /// Shows only the chats `filter` admits; `None` shows them all.
    pub fn set_filter(&self, filter: Option<ChatFilter>) {
        self.send(Intent::Filter(filter));
    }

    /// Puts the place's chats in `order`.
    pub fn set_order(&self, order: ChatOrder) {
        self.send(Intent::Order(order));
    }

    /// The chats with a draft on this device changed.
    pub fn set_drafts(&self, drafts: HashSet<ChatId>) {
        self.send(Intent::Drafts(drafts));
    }

    /// Reads the waiting messages again (one was scheduled in a chat), and sends what changed.
    pub fn refresh(&self) {
        self.send(Intent::Refresh);
    }

    /// Does one of a chat's menu actions (to each room of a merged chat).
    pub fn change(&self, chat: ChatId, change: ChatChange) {
        self.send(Intent::Act(Action::Change(chat, change)));
    }

    /// Accepts or declines an invitation.
    pub fn answer_request(&self, room: RoomId, accept: bool) {
        self.send(Intent::Act(Action::Answer(room, accept)));
    }

    /// Makes a label, and puts `with` in it.
    pub fn make_label(&self, name: String, with: Option<ChatId>) {
        self.send(Intent::Act(Action::MakeLabel { name, with }));
    }

    /// Deletes a label.
    pub fn remove_label(&self, id: LabelId) {
        self.send(Intent::Act(Action::RemoveLabel(id)));
    }

    /// Puts a chat in a label, or takes it out.
    pub fn set_in_label(&self, chat: ChatId, label: LabelId, included: bool) {
        self.send(Intent::Act(Action::SetInLabel { chat, label, included }));
    }

    /// Reminds the user to answer `chat` at `at`; `None` takes the reminder away.
    pub fn set_reminder(&self, chat: ChatId, at: Option<SystemTime>) {
        self.send(Intent::Act(Action::SetReminder(chat, at)));
    }

    /// Takes a message out of the saved ones.
    pub fn unsave(&self, room: RoomId, event: EventId) {
        self.send(Intent::Act(Action::Unsave(room, event)));
    }

    /// Cancels a waiting message.
    pub fn cancel_scheduled(&self, id: ScheduledId) {
        self.send(Intent::Act(Action::CancelScheduled(id)));
    }

    /// Shows `chats` as one, named `name`, writing to `default_room`.
    pub fn merge(&self, chats: Vec<ChatId>, name: String, default_room: RoomId) {
        self.send(Intent::Act(Action::Merge {
            chats,
            name,
            default_room,
        }));
    }

    /// Takes a merged chat apart.
    pub fn unmerge(&self, chat: ChatId) {
        self.send(Intent::Act(Action::Unmerge(chat)));
    }

    /// Puts the places in this order (the folders keep theirs).
    pub fn reorder(&self, places: Vec<PlaceId>) {
        self.send(Intent::Reorder(places));
    }

    /// Hides a place, or shows it again; the inbox always shows.
    pub fn set_hidden(&self, place: PlaceId, hidden: bool) {
        self.send(Intent::Hide(place, hidden));
    }

    /// Shows every hidden place again.
    pub fn show_all_places(&self) {
        self.send(Intent::ShowAllPlaces);
    }
}

impl Drop for ChatListViewModel {
    fn drop(&mut self) {
        self.task.abort();
    }
}

/// What the account's streams bring.
enum Feed {
    Chats(Diffs<Arc<Chat>>),
    Requests(Diffs<Request>),
    Organized(Arc<Organized>),
    Spaces(Arc<[Space]>),
    FirstSync,
}

fn feeds<B: ChatListBackend>(account: &Arc<B>) -> SelectAll<BoxStream<'static, Feed>> {
    let first_sync = {
        let account = Arc::clone(account);
        stream::once(async move {
            account.wait_for_first_sync().await;
            Feed::FirstSync
        })
    };
    stream::select_all([
        account.chats().map(Feed::Chats).boxed(),
        account.requests().map(Feed::Requests).boxed(),
        account.organized().map(Feed::Organized).boxed(),
        account.spaces().map(Feed::Spaces).boxed(),
        first_sync.boxed(),
    ])
}

/// Runs actions against the account once it is open; those asked before wait for it.
struct Actor<B> {
    account: Option<(Arc<B>, Actions<Target>)>,
    waiting: Vec<Action>,
    outbox: mpsc::UnboundedSender<Intent>,
    listener: Arc<dyn ListListener>,
}

/// What an action changes: those on one target reach the server in the order asked.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
enum Target {
    /// A chat's marks, reminder and organizing (Archive then Unarchive).
    Chat(ChatId),
    /// An invitation.
    Invitation(RoomId),
    /// A label: its name, its chats, its removal.
    Label(LabelId),
    /// A saved message.
    Saved(EventId),
    /// A message waiting to be sent.
    Scheduled(ScheduledId),
    /// The merged chats.
    Merges,
    /// The order and the hidden of the places.
    Arrangement,
}

impl Action {
    /// What the action changes; `None` for one that only reads or makes something new.
    fn target(&self) -> Option<Target> {
        Some(match self {
            Self::Change(chat, _) | Self::SetReminder(chat, _) => Target::Chat(chat.clone()),
            Self::Answer(room, _) => Target::Invitation(room.clone()),
            Self::MakeLabel { .. } | Self::ReadScheduled => return None,
            Self::RemoveLabel(id) => Target::Label(id.clone()),
            Self::SetInLabel { label, .. } => Target::Label(label.clone()),
            Self::Unsave(_, event) => Target::Saved(event.clone()),
            Self::CancelScheduled(id) => Target::Scheduled(id.clone()),
            Self::Merge { .. } | Self::Unmerge(_) => Target::Merges,
            Self::Arrange(_) => Target::Arrangement,
        })
    }
}

impl<B: ChatListBackend> Actor<B> {
    fn open(&mut self, account: Arc<B>) {
        self.account = Some((account, Actions::new()));
        for action in mem::take(&mut self.waiting) {
            self.act(action);
        }
        self.act(Action::ReadScheduled);
    }

    /// Runs `action` beside the list's task, which goes on: after those asked for before it on
    /// its target, else at once. A failure goes to the listener.
    fn act(&mut self, action: Action) {
        let Some((account, actions)) = &mut self.account else {
            self.waiting.push(action);
            return;
        };
        let target = action.target();
        let (account, outbox, listener) = (Arc::clone(account), self.outbox.clone(), Arc::clone(&self.listener));
        let job = async move {
            if let Err(error) = perform(account.as_ref(), action, &outbox).await {
                listener.on_error(error);
            }
        };
        match target {
            Some(target) => actions.push(target, job),
            None => {
                tokio::spawn(job);
            }
        }
    }
}

async fn perform<B: ChatListBackend>(
    account: &B,
    action: Action,
    outbox: &mpsc::UnboundedSender<Intent>,
) -> Result<(), BackendError> {
    match action {
        Action::Change(chat, change) => account.change(&chat, change).await,
        Action::Answer(room, accept) => account.answer_request(&room, accept).await,
        Action::MakeLabel { name, with } => {
            let label = account.make_label(&name).await?;
            match with {
                Some(chat) => account.set_in_label(&chat, &label.id, true).await,
                None => Ok(()),
            }
        }
        Action::RemoveLabel(id) => account.remove_label(&id).await,
        Action::SetInLabel { chat, label, included } => account.set_in_label(&chat, &label, included).await,
        Action::SetReminder(chat, at) => account.set_reminder(&chat, at).await,
        Action::Unsave(room, event) => account.unsave_message(&room, &event).await,
        Action::CancelScheduled(id) => {
            account.cancel_scheduled(&id).await?;
            read_scheduled(account, outbox).await;
            Ok(())
        }
        Action::Merge {
            chats,
            name,
            default_room,
        } => account.merge(&chats, &name, &default_room).await.map(|_| ()),
        Action::Unmerge(chat) => account.unmerge(&chat).await,
        Action::Arrange(arrangement) => {
            let written = account.set_arrangement(&arrangement).await;
            let _ = outbox.send(Intent::Arranged);
            written
        }
        Action::ReadScheduled => {
            read_scheduled(account, outbox).await;
            Ok(())
        }
    }
}

/// Reads the waiting messages for the list. They cost a request to the server, so they are
/// read when they may have changed, not with every change; a failed read (offline) keeps the
/// ones shown.
async fn read_scheduled<B: ChatListBackend>(account: &B, outbox: &mpsc::UnboundedSender<Intent>) {
    if let Ok(scheduled) = account.scheduled().await {
        let _ = outbox.send(Intent::Scheduled(scheduled));
    }
}

/// An intent's change to the list; true when the list must be composed again.
fn handle<B: ChatListBackend>(intent: Intent, state: &mut ListState, actor: &mut Actor<B>) -> bool {
    match intent {
        Intent::Place(place) => {
            let opens_scheduled = place == PlaceId::Scheduled;
            if state.select(place) && opens_scheduled {
                actor.act(Action::ReadScheduled);
            }
        }
        Intent::Filter(filter) => state.set_filter(filter),
        Intent::Order(order) => state.set_order(order),
        Intent::Drafts(drafts) => state.set_drafts(drafts),
        Intent::Refresh => actor.act(Action::ReadScheduled),
        Intent::Reorder(places) => {
            let mut arrangement = state.arrangement().clone();
            arrangement.order = places
                .iter()
                .filter(|place| !matches!(place, PlaceId::Folder(_)))
                .map(PlaceId::key)
                .collect();
            return arrange(state, actor, arrangement);
        }
        Intent::Hide(place, hidden) => {
            let arrangement = state.arrangement().clone().with_hidden(place.key(), hidden);
            return arrange(state, actor, arrangement);
        }
        Intent::ShowAllPlaces => {
            let mut arrangement = state.arrangement().clone();
            arrangement.hidden.clear();
            return arrange(state, actor, arrangement);
        }
        Intent::Act(action) => {
            actor.act(action);
            return false;
        }
        Intent::Scheduled(scheduled) => state.set_scheduled(scheduled),
        Intent::Arranged => state.arranged(),
    }
    true
}

/// A new arrangement: shown at once, then kept with the account so the other devices follow.
fn arrange<B: ChatListBackend>(state: &mut ListState, actor: &mut Actor<B>, arrangement: Arrangement) -> bool {
    if arrangement == *state.arrangement() {
        return false;
    }
    state.arrange(arrangement.clone());
    actor.act(Action::Arrange(arrangement));
    true
}

/// Whether a batch only says the list is empty: the account's first list before its rooms came.
fn is_empty_reset(diffs: &[VectorDiff<Arc<Chat>>]) -> bool {
    matches!(diffs, [VectorDiff::Reset { values }] if values.is_empty())
}

async fn run<B, K, F>(
    kept: K,
    backend: F,
    setup: ListSetup,
    mut inbox: mpsc::UnboundedReceiver<Intent>,
    outbox: mpsc::UnboundedSender<Intent>,
    listener: Arc<dyn ListListener>,
) where
    B: ChatListBackend,
    K: Future<Output = Vec<Chat>> + Send,
    F: Future<Output = Option<Arc<B>>> + Send,
{
    let ListSetup {
        place,
        filter,
        order,
        drafts,
    } = setup;
    let mut state = ListState::new(place, filter, order, drafts, kept.await);
    let mut tracker = LoadTracker::new();
    let mut actor = Actor {
        account: None,
        waiting: Vec::new(),
        outbox,
        listener: Arc::clone(&listener),
    };
    let mut feeds: SelectAll<BoxStream<'static, Feed>> = SelectAll::new();
    let mut opening = std::pin::pin!(backend);
    let mut opened = false;
    // the account sent its chats: an empty list from it is the list, not the start of one.
    let mut account_chats = false;
    // when the list first changed since the last batch; the first batch goes at once.
    let mut dirty: Option<Instant> = Some(Instant::now());
    let mut sent: Option<Instant> = None;
    let mut settle: Option<Instant> = None;
    let publish = |state: &mut ListState, tracker: &LoadTracker| {
        let update = state.compose(SystemTime::now(), tracker.loading());
        if !update.is_empty() {
            listener.on_update(update);
        }
    };
    loop {
        let due = sent.map_or_else(Instant::now, |at| at + FRAME);
        // changes keep coming (a sync's burst): a batch goes once a frame all the same.
        if let Some(since) = dirty
            && since.elapsed() >= FRAME
            && Instant::now() >= due
        {
            publish(&mut state, &tracker);
            dirty = None;
            sent = Some(Instant::now());
        }
        tokio::select! {
            biased;
            account = &mut opening, if !opened => {
                opened = true;
                if let Some(account) = account {
                    feeds = self::feeds(&account);
                    actor.open(account);
                }
            }
            Some(intent) = inbox.recv() => {
                if handle(intent, &mut state, &mut actor) {
                    dirty.get_or_insert_with(Instant::now);
                }
            }
            Some(feed) = feeds.next(), if !feeds.is_empty() => {
                match feed {
                    Feed::Chats(diffs) => {
                        // the account's list before its rooms came: the kept one stays.
                        if !account_chats && state.has_chats() && is_empty_reset(&diffs) {
                            continue;
                        }
                        account_chats = true;
                        state.apply_chats(diffs);
                        if tracker.counted(state.chat_count()) {
                            settle = Some(Instant::now() + SETTLE);
                        }
                    }
                    Feed::Requests(diffs) => state.apply_requests(diffs),
                    Feed::Organized(organized) => state.set_organized(organized),
                    Feed::Spaces(spaces) => state.set_spaces(&spaces),
                    Feed::FirstSync => {
                        if tracker.answered() {
                            settle = Some(Instant::now() + SETTLE);
                        }
                    }
                }
                dirty.get_or_insert_with(Instant::now);
            }
            () = sleep_until(settle.unwrap_or_else(Instant::now)), if settle.is_some() => {
                settle = None;
                tracker.settled();
                dirty.get_or_insert_with(Instant::now);
            }
            () = sleep_until(due), if dirty.is_some() => {
                publish(&mut state, &tracker);
                dirty = None;
                sent = Some(Instant::now());
            }
            else => break,
        }
    }
}

#[cfg(test)]
mod tests {
    use std::collections::HashMap;
    use std::sync::Arc;
    use std::time::{Duration, SystemTime};

    use eyeball_im::{Vector, VectorDiff};
    use tokio::runtime::Handle;
    use tokio::sync::{mpsc, oneshot};
    use tokio::time::timeout;

    use super::{ChatListViewModel, ListListener, ListSetup};
    use crate::chat::{Chat, Folder};
    use crate::demo::{DemoAccount, DemoConfig};
    use crate::list::{ListRow, ListUpdate, LoadState};
    use crate::network::Network;
    use crate::places::{PlaceId, SectionId};
    use crate::ports::{BackendError, ChatChange};

    struct Relay(mpsc::UnboundedSender<ListUpdate>);

    impl ListListener for Relay {
        fn on_update(&self, update: ListUpdate) {
            let _ = self.0.send(update);
        }

        fn on_error(&self, error: BackendError) {
            panic!("an action failed: {error}");
        }
    }

    fn demo() -> Arc<DemoAccount> {
        Arc::new(DemoAccount::new(DemoConfig {
            rooms: 40,
            start: SystemTime::UNIX_EPOCH + Duration::from_hours(500_000),
            ..DemoConfig::new(0)
        }))
    }

    /// A list over the demo, and its batches.
    fn list(demo: &Arc<DemoAccount>) -> (ChatListViewModel, mpsc::UnboundedReceiver<ListUpdate>) {
        let (sender, batches) = mpsc::unbounded_channel();
        let demo = Arc::clone(demo);
        let list = ChatListViewModel::start(
            &Handle::current(),
            async { Vec::new() },
            async move { Some(demo) },
            ListSetup::default(),
            Arc::new(Relay(sender)),
        );
        (list, batches)
    }

    /// The sections' rows as the listener builds them from the batches.
    #[derive(Default)]
    struct Shown(HashMap<SectionId, Vector<ListRow>>);

    impl Shown {
        fn apply(&mut self, update: &ListUpdate) {
            if let Some(headers) = &update.sections {
                self.0.retain(|id, _| headers.iter().any(|header| header.id == *id));
            }
            for section in &update.rows {
                let rows = self.0.entry(section.section.clone()).or_default();
                for diff in section.diffs.clone() {
                    diff.apply(rows);
                }
            }
        }

        fn ids(&self, section: &SectionId) -> Vec<String> {
            self.0
                .get(section)
                .map(|rows| rows.iter().map(|row| row.key().to_string()).collect())
                .unwrap_or_default()
        }
    }

    async fn next(batches: &mut mpsc::UnboundedReceiver<ListUpdate>) -> ListUpdate {
        timeout(Duration::from_secs(5), batches.recv()).await.unwrap().unwrap()
    }

    async fn nothing_more(batches: &mut mpsc::UnboundedReceiver<ListUpdate>) {
        assert!(timeout(Duration::from_millis(200), batches.recv()).await.is_err());
    }

    #[tokio::test(start_paused = true)]
    async fn the_first_batch_holds_the_whole_list() {
        let demo = demo();
        let (_list, mut batches) = list(&demo);
        let first = next(&mut batches).await;
        let headers = first.sections.clone().unwrap();
        assert_eq!(
            headers.iter().map(|header| header.id.clone()).collect::<Vec<_>>(),
            [SectionId::Pinned, SectionId::All]
        );
        let places = first.places.clone().unwrap();
        assert!(
            places
                .iter()
                .any(|place| place.id == PlaceId::Network(Network::from_id("whatsapp")))
        );
        assert!(places.iter().any(|place| place.name.as_deref() == Some("Family")));
        assert_eq!(first.labels.as_ref().map(Vec::len), Some(1));
        let mut shown = Shown::default();
        shown.apply(&first);
        assert_eq!(
            shown.ids(&SectionId::Pinned),
            ["!room0:demo", "!room1:demo", "!room2:demo"]
        );
        assert!(shown.ids(&SectionId::All).contains(&"merge:demo-jana".to_owned()));
    }

    #[tokio::test(start_paused = true)]
    async fn changes_within_a_frame_go_in_one_batch() {
        let demo = demo();
        let (list, mut batches) = list(&demo);
        let mut shown = Shown::default();
        shown.apply(&next(&mut batches).await);
        // the load state settles on its own: past it, only the changes.
        while next(&mut batches)
            .await
            .loading
            .is_none_or(|loading| loading.state != LoadState::Done)
        {}
        for room in ["!room5:demo", "!room6:demo", "!room9:demo"] {
            // none unread: the places' counts stay.
            list.change(room.into(), ChatChange::Archive);
        }
        let batch = next(&mut batches).await;
        assert!(batch.places.is_none());
        assert_eq!(batch.rows.len(), 1);
        let removed = batch.rows[0]
            .diffs
            .iter()
            .filter(|diff| matches!(diff, VectorDiff::Remove { .. }))
            .count();
        assert_eq!(removed, 3);
        shown.apply(&batch);
        assert!(!shown.ids(&SectionId::All).contains(&"!room6:demo".to_owned()));
        nothing_more(&mut batches).await;
    }

    #[tokio::test(start_paused = true)]
    async fn a_pinned_chat_moves_by_its_id_and_rows_keep_theirs() {
        let demo = demo();
        let (list, mut batches) = list(&demo);
        let mut shown = Shown::default();
        shown.apply(&next(&mut batches).await);
        let before = shown.ids(&SectionId::All);
        list.change("!room8:demo".into(), ChatChange::Pin);
        let mut batch = next(&mut batches).await;
        while batch.rows.is_empty() {
            batch = next(&mut batches).await;
        }
        let pinned = batch
            .rows
            .iter()
            .find(|rows| rows.section == SectionId::Pinned)
            .unwrap();
        assert!(matches!(pinned.diffs.as_slice(), [VectorDiff::Insert { index: 3, .. }]));
        let all = batch.rows.iter().find(|rows| rows.section == SectionId::All).unwrap();
        assert!(matches!(all.diffs.as_slice(), [VectorDiff::Remove { .. }]));
        shown.apply(&batch);
        let after: Vec<String> = before.into_iter().filter(|id| id != "!room8:demo").collect();
        assert_eq!(shown.ids(&SectionId::All), after);
    }

    #[tokio::test(start_paused = true)]
    async fn a_place_that_goes_away_shows_the_inbox() {
        let demo = demo();
        let (list, mut batches) = list(&demo);
        next(&mut batches).await;
        list.select_place(PlaceId::Label("demo-work".into()));
        let label = next(&mut batches).await;
        assert_eq!(label.place, PlaceId::Label("demo-work".into()));
        assert!(label.sections.is_some());
        list.remove_label("demo-work".into());
        let mut batch = next(&mut batches).await;
        while batch.place != PlaceId::INBOX {
            batch = next(&mut batches).await;
        }
        assert!(
            batch
                .places
                .unwrap()
                .iter()
                .all(|place| !matches!(place.id, PlaceId::Label(_)))
        );
    }

    #[tokio::test(start_paused = true)]
    async fn a_hidden_place_shows_at_once() {
        let demo = demo();
        let (list, mut batches) = list(&demo);
        next(&mut batches).await;
        let signal = PlaceId::Network(Network::from_id("signal"));
        list.set_hidden(signal.clone(), true);
        let batch = next(&mut batches).await;
        let places = batch.places.unwrap();
        assert!(places.iter().any(|place| place.id == signal && place.is_hidden));
        list.set_hidden(PlaceId::INBOX, true);
        list.show_all_places();
        let mut batch = next(&mut batches).await;
        while batch.places.is_none() {
            batch = next(&mut batches).await;
        }
        assert!(batch.places.unwrap().iter().all(|place| !place.is_hidden));
    }

    #[tokio::test(start_paused = true)]
    async fn the_kept_list_shows_until_the_account_opens() {
        let demo = demo();
        let kept = vec![demo.snapshot().chats[5].as_ref().clone()];
        let (sender, mut batches) = mpsc::unbounded_channel();
        let (open, opened) = oneshot::channel::<Arc<DemoAccount>>();
        let _list = ChatListViewModel::start(
            &Handle::current(),
            async { kept },
            async move { opened.await.ok() },
            ListSetup::default(),
            Arc::new(Relay(sender)),
        );
        let mut shown = Shown::default();
        let first = next(&mut batches).await;
        assert_eq!(first.loading.unwrap().state, LoadState::Connecting);
        shown.apply(&first);
        assert_eq!(shown.ids(&SectionId::All), ["!room5:demo"]);
        nothing_more(&mut batches).await;
        let _ = open.send(Arc::clone(&demo));
        let batch = next(&mut batches).await;
        assert!(matches!(batch.loading.unwrap().state, LoadState::Syncing { .. }));
        shown.apply(&batch);
        assert!(shown.ids(&SectionId::All).len() > 20);
    }

    #[tokio::test(start_paused = true)]
    async fn a_place_chosen_while_the_kept_list_is_read_is_the_first_shown() {
        let demo = demo();
        let (sender, mut batches) = mpsc::unbounded_channel();
        let (keep, kept) = oneshot::channel::<Vec<Chat>>();
        let list = ChatListViewModel::start(
            &Handle::current(),
            async move { kept.await.unwrap_or_default() },
            async move { Some(demo) },
            ListSetup::default(),
            Arc::new(Relay(sender)),
        );
        let archive = PlaceId::Folder(Folder::Archive);
        list.select_place(archive.clone());
        let _ = keep.send(Vec::new());
        assert_eq!(next(&mut batches).await.place, archive);
    }
}
