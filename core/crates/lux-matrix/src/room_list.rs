//! The account's lists, each kept by one task: the SDK's room list, filtered and sorted by the
//! SDK, mapped room by room to the core's rows. Subscribers take the list as it is, then its
//! batches of diffs; the task is the only writer.
//!
//! The chat list's task also applies what the user organized (archive, deletes, reminders,
//! merges) to the rooms' chats, each time either changes, and sends only the rows that changed.
//! Rows are shared: a chat nothing changed stays the same allocation from the mapping to the
//! apps' list. A keeper task writes the list to the store for the next launch.

use std::collections::{HashMap, HashSet};
use std::sync::Arc;
use std::time::Duration;

use eyeball_im::{Vector, VectorDiff};
use futures_util::{StreamExt, pin_mut};
use lux_core::chat::{Chat, NotificationMode, Request};
use lux_core::diff;
use lux_core::organizer::Organized;
use matrix_sdk::Client;
use matrix_sdk::ruma::{OwnedRoomId, OwnedUserId, RoomId};
use matrix_sdk_ui::RoomListService;
use matrix_sdk_ui::room_list_service::RoomListItem;
use matrix_sdk_ui::room_list_service::filters::{
    new_filter_all, new_filter_invite, new_filter_joined, new_filter_not, new_filter_space,
};
use tokio::sync::{broadcast, mpsc, oneshot, watch};
use tokio::task::JoinHandle;
use tokio::time::{Instant, sleep_until};
use tracing::warn;

use crate::kept::KeptList;
use crate::live_list::LiveList;
use crate::mapping::Mapper;
use crate::members::MemberLoader;
use crate::organizer::{self, Changes};
use crate::redecrypt::Redecryptor;

/// The SDK's list sends this many rooms at most: all of them, for the apps' own folders.
const PAGE_SIZE: usize = 100_000;

/// The kept list is written at most this often while the list changes.
const KEEP_INTERVAL: Duration = Duration::from_secs(5);

/// The chat list, and the keeper that writes it to the kept list.
pub(crate) struct ChatList {
    pub(crate) rows: LiveList<Arc<Chat>>,
    keeper: Option<Keeper>,
    task: JoinHandle<()>,
}

/// What the chat list's task reads besides the rooms: what the user organized.
pub(crate) struct Organizing {
    pub(crate) state: watch::Receiver<Arc<Organized>>,
    pub(crate) changes: Changes,
}

impl ChatList {
    /// Starts mapping the room list's joined rooms, from the kept list until the store's rooms
    /// come (a moment after).
    pub(crate) async fn start(
        client: Client,
        service: Arc<RoomListService>,
        own: OwnedUserId,
        kept: Option<KeptList>,
        organizing: Organizing,
    ) -> Self {
        let shown = match &kept {
            Some(kept) => kept.read().await,
            None => Vec::new(),
        };
        let rows = LiveList::new(shown.into_iter().map(Arc::new).collect());
        let (to_keep, keeper) = match kept {
            Some(kept) => {
                let (to_keep, keeper) = Keeper::start(kept, rows.clone());
                (Some(to_keep), Some(keeper))
            }
            None => (None, None),
        };
        let task = tokio::spawn(map_chats(client, service, own, rows.clone(), to_keep, organizing));
        Self { rows, keeper, task }
    }

    /// A handle that writes what the kept list misses (the app goes to the background); none
    /// when the list is not kept.
    pub(crate) fn flush(&self) -> Option<Flush> {
        self.keeper.as_ref().map(|keeper| keeper.flush.clone())
    }
}

impl Drop for ChatList {
    fn drop(&mut self) {
        self.task.abort();
        if let Some(keeper) = &self.keeper {
            keeper.task.abort();
        }
    }
}

/// The task that writes the chat list to the kept list: one write at a time, the latest list,
/// at most every [`KEEP_INTERVAL`] while the list changes and once more after the last change.
struct Keeper {
    flush: Flush,
    task: JoinHandle<()>,
}

/// Asks the keeper to write the list now.
#[derive(Clone)]
pub(crate) struct Flush(mpsc::UnboundedSender<oneshot::Sender<()>>);

impl Flush {
    /// Writes the list now if it changed since the last write; returns once it is written (at
    /// once when the list has closed).
    pub(crate) async fn run(&self) {
        let (done, written) = oneshot::channel();
        if self.0.send(done).is_ok() {
            let _ = written.await;
        }
    }
}

impl Keeper {
    /// Starts the keeper of `rows`; the list's task marks each change on the sender returned.
    fn start(kept: KeptList, rows: LiveList<Arc<Chat>>) -> (watch::Sender<()>, Self) {
        let (to_keep, list_changes) = watch::channel(());
        let (flushes, asked) = mpsc::unbounded_channel();
        let task = tokio::spawn(keep(kept, rows, list_changes, asked));
        (
            to_keep,
            Self {
                flush: Flush(flushes),
                task,
            },
        )
    }
}

async fn keep(
    kept: KeptList,
    rows: LiveList<Arc<Chat>>,
    mut list_changes: watch::Receiver<()>,
    mut asked: mpsc::UnboundedReceiver<oneshot::Sender<()>>,
) {
    let write = async |rows: &LiveList<Arc<Chat>>| {
        if let Err(error) = kept.write(rows.snapshot()).await {
            warn!(%error, "the kept list could not be written");
        }
    };
    let mut written: Option<Instant> = None;
    // a change not written yet: when it is due.
    let mut due: Option<Instant> = None;
    loop {
        tokio::select! {
            open = list_changes.changed() => {
                if open.is_err() {
                    break;
                }
                due.get_or_insert_with(|| written.map_or_else(Instant::now, |at| at + KEEP_INTERVAL));
            }
            () = sleep_until(due.unwrap_or_else(Instant::now)), if due.is_some() => {
                due = None;
                written = Some(Instant::now());
                write(&rows).await;
            }
            Some(done) = asked.recv() => {
                if due.take().is_some() {
                    written = Some(Instant::now());
                    write(&rows).await;
                }
                let _ = done.send(());
            }
        }
    }
}

/// The invitations.
pub(crate) struct RequestList {
    pub(crate) rows: LiveList<Request>,
    task: JoinHandle<()>,
}

impl RequestList {
    pub(crate) fn start(service: Arc<RoomListService>) -> Self {
        let rows = LiveList::new(Vector::new());
        let task = tokio::spawn(map_requests(service, rows.clone()));
        Self { rows, task }
    }
}

impl Drop for RequestList {
    fn drop(&mut self) {
        self.task.abort();
    }
}

async fn map_chats(
    client: Client,
    service: Arc<RoomListService>,
    own: OwnedUserId,
    rows: LiveList<Arc<Chat>>,
    to_keep: Option<watch::Sender<()>>,
    mut organizing: Organizing,
) {
    let Ok(all) = service.all_rooms().await else {
        warn!("the room list is not available");
        return;
    };
    let (batches, controller) = all.entries_with_dynamic_adapters(PAGE_SIZE);
    // joined chats; a space groups chats, it is none.
    controller.set_filter(Box::new(new_filter_all(vec![
        Box::new(new_filter_joined()),
        Box::new(new_filter_not(Box::new(new_filter_space()))),
    ])));
    pin_mut!(batches);
    let settings = client.notification_settings().await;
    let mut rules = settings.subscribe_to_changes();
    let mut rules_open = true;
    let redecryptor = Redecryptor::start(client.clone());
    let mut chat_rows = ChatRows {
        mapper: Mapper::default(),
        members: MemberLoader::start(client.clone()),
        own,
        notifications: crate::actions::room_notifications(&settings).await,
    };
    // the rooms' chats in the server's order, and the list as last sent (the kept one first).
    let mut rooms: Vector<Arc<Chat>> = Vector::new();
    let mut shown: Vec<Arc<Chat>> = rows.snapshot().into_iter().collect();
    let mut listened = HashSet::<OwnedRoomId>::new();
    let mut rooms_came = false;
    let mut organizer_open = true;
    let mut last_tidy: Option<lux_core::organizer::ChatMarks> = None;
    loop {
        tokio::select! {
            batch = batches.next() => {
                let Some(batch) = batch else { break };
                let removes = batch.iter().any(removes_rooms);
                for diff in batch {
                    if matches!(diff, VectorDiff::Reset { .. }) {
                        chat_rows.mapper.forget();
                    }
                    // the newest message of each listed chat: the sdk computes it for the rooms
                    // it is asked to, and keeps it with the room.
                    for room in diff_items(&diff) {
                        if listened.insert(room.room_id().to_owned()) {
                            follow(&client, room.room_id()).await;
                            redecryptor.listed(room.room_id());
                        }
                    }
                    map_diff(diff, &mut chat_rows).await.apply(&mut rooms);
                }
                // a room that left the list (left, or now a space) is followed no more.
                if removes {
                    forget_gone(&client, &rooms, &mut listened).await;
                }
                rooms_came = true;
            }
            changed = organizing.state.changed(), if organizer_open => {
                organizer_open = changed.is_ok();
            }
            // a chat muted or unmuted, here or on another device.
            rule = rules.recv(), if rules_open => {
                if matches!(rule, Err(broadcast::error::RecvError::Closed)) {
                    rules_open = false;
                    continue;
                }
                chat_rows.notifications = crate::actions::room_notifications(&settings).await;
                for index in 0..rooms.len() {
                    let mode = rooms[index].id.room().map(|room| chat_rows.mode_of(room.as_str()));
                    if let Some(mode) = mode.filter(|&mode| rooms[index].notifications != Some(mode)) {
                        let chat = Chat {
                            is_muted: mode.is_quiet(),
                            notifications: Some(mode),
                            ..Chat::clone(&rooms[index])
                        };
                        rooms.set(index, Arc::new(chat));
                    }
                }
            }
        }
        // the kept list stays until the store's rooms come.
        if !rooms_came {
            continue;
        }
        let organized = Arc::clone(&organizing.state.borrow());
        let next = organized.compose(&rooms);
        let changes = diff::shared_changes(&shown, &next, |chat| &chat.id);
        if !changes.is_empty() {
            rows.apply(changes);
            if let Some(to_keep) = &to_keep {
                to_keep.send_replace(());
            }
        }
        shown = next;
        // a chat a newer message brought back loses its mark, so the next one does not archive
        // it again.
        let marked = organizer::marked(&organized, rooms.iter().map(AsRef::as_ref));
        if let Some(tidied) = organized.marks.without_returned(&marked)
            && last_tidy.as_ref() != Some(&tidied)
        {
            organizing.changes.send(crate::actions::tidy_marks(marked));
            last_tidy = Some(tidied);
        }
    }
}

/// Follows the newest message of a room the list shows from now on: the SDK computes it for the
/// rooms it is asked to, and keeps it with the room.
async fn follow(client: &Client, room: &RoomId) {
    if let Some(latest) = client.latest_events().await
        && let Err(error) = latest.listen_to_room(room).await
    {
        warn!(%error, "no latest event for a room");
    }
}

async fn map_requests(service: Arc<RoomListService>, rows: LiveList<Request>) {
    let Ok(all) = service.all_rooms().await else {
        warn!("the room list is not available");
        return;
    };
    let (batches, controller) = all.entries_with_dynamic_adapters(PAGE_SIZE);
    controller.set_filter(Box::new(new_filter_invite()));
    pin_mut!(batches);
    while let Some(batch) = batches.next().await {
        let mut mapped = Vec::with_capacity(batch.len());
        for diff in batch {
            mapped.push(map_diff(diff, &mut RequestRows).await);
        }
        rows.apply(mapped);
    }
}

/// The rooms a diff brings in.
fn diff_items(diff: &VectorDiff<RoomListItem>) -> Vec<&RoomListItem> {
    match diff {
        VectorDiff::Append { values } | VectorDiff::Reset { values } => values.iter().collect(),
        VectorDiff::PushFront { value }
        | VectorDiff::PushBack { value }
        | VectorDiff::Insert { value, .. }
        | VectorDiff::Set { value, .. } => vec![value],
        VectorDiff::Clear
        | VectorDiff::PopFront
        | VectorDiff::PopBack
        | VectorDiff::Remove { .. }
        | VectorDiff::Truncate { .. } => Vec::new(),
    }
}

/// Whether a diff can take rooms out of the list.
fn removes_rooms<T: Clone>(diff: &VectorDiff<T>) -> bool {
    matches!(
        diff,
        VectorDiff::Remove { .. }
            | VectorDiff::PopBack
            | VectorDiff::PopFront
            | VectorDiff::Truncate { .. }
            | VectorDiff::Clear
            | VectorDiff::Reset { .. }
    )
}

/// Stops following the newest message of the rooms no longer in `rooms`.
async fn forget_gone(client: &Client, rooms: &Vector<Arc<Chat>>, listened: &mut HashSet<OwnedRoomId>) {
    let present: HashSet<&str> = rooms
        .iter()
        .filter_map(|chat| chat.id.room())
        .map(lux_core::ids::RoomId::as_str)
        .collect();
    let gone: Vec<OwnedRoomId> = listened
        .iter()
        .filter(|room| !present.contains(room.as_str()))
        .cloned()
        .collect();
    if gone.is_empty() {
        return;
    }
    let latest = client.latest_events().await;
    for room in gone {
        if let Some(latest) = &latest {
            latest.forget_room(&room).await;
        }
        listened.remove(&room);
    }
}

/// Maps the rooms of one list to its rows.
trait RowMapper: Send {
    type Row: Clone + Send + Sync + 'static;

    fn row(&mut self, room: RoomListItem) -> impl Future<Output = Self::Row> + Send;
}

/// The joined chats' rows.
struct ChatRows {
    mapper: Mapper,
    /// Loads the members of the groups that have no pictures to show.
    members: MemberLoader,
    own: OwnedUserId,
    /// The rooms whose notifications the user set, and how.
    notifications: HashMap<OwnedRoomId, NotificationMode>,
}

impl ChatRows {
    /// How room `room`'s messages notify.
    fn mode_of(&self, room: &str) -> NotificationMode {
        <&RoomId>::try_from(room)
            .ok()
            .and_then(|room| self.notifications.get(room).copied())
            .unwrap_or_default()
    }
}

impl RowMapper for ChatRows {
    type Row = Arc<Chat>;

    async fn row(&mut self, room: RoomListItem) -> Arc<Chat> {
        let mut chat = self.mapper.chat(&room, &self.own).await;
        let mode = self.notifications.get(room.room_id()).copied().unwrap_or_default();
        chat.is_muted = mode.is_quiet();
        chat.notifications = Some(mode);
        // a group's members load for its pictures, and for the name of its latest message's
        // sender (the store holds only the members the sync named).
        if chat.is_group
            && (chat.avatar.is_none() && chat.member_avatars.is_empty()
                || crate::mapping::latest_sender_unknown(&room, &self.own).await)
        {
            self.members.load(&room);
        }
        Arc::new(chat)
    }
}

/// The invitations' rows.
struct RequestRows;

impl RowMapper for RequestRows {
    type Row = Request;

    async fn row(&mut self, room: RoomListItem) -> Request {
        Mapper::request(&room).await
    }
}

/// `diff` with each room mapped to its row, in order.
async fn map_diff<M: RowMapper>(diff: VectorDiff<RoomListItem>, rows: &mut M) -> VectorDiff<M::Row> {
    async fn all<M: RowMapper>(values: Vector<RoomListItem>, rows: &mut M) -> Vector<M::Row> {
        let mut mapped = Vector::new();
        for value in values {
            mapped.push_back(rows.row(value).await);
        }
        mapped
    }
    match diff {
        VectorDiff::Append { values } => VectorDiff::Append {
            values: all(values, rows).await,
        },
        VectorDiff::Reset { values } => VectorDiff::Reset {
            values: all(values, rows).await,
        },
        VectorDiff::PushFront { value } => VectorDiff::PushFront {
            value: rows.row(value).await,
        },
        VectorDiff::PushBack { value } => VectorDiff::PushBack {
            value: rows.row(value).await,
        },
        VectorDiff::Insert { index, value } => VectorDiff::Insert {
            index,
            value: rows.row(value).await,
        },
        VectorDiff::Set { index, value } => VectorDiff::Set {
            index,
            value: rows.row(value).await,
        },
        VectorDiff::Clear => VectorDiff::Clear,
        VectorDiff::PopFront => VectorDiff::PopFront,
        VectorDiff::PopBack => VectorDiff::PopBack,
        VectorDiff::Remove { index } => VectorDiff::Remove { index },
        VectorDiff::Truncate { length } => VectorDiff::Truncate { length },
    }
}
