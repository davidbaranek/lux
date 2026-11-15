//! The chat list's view model (`lux_core::list`), as the apps see it: an object they forward
//! intents to, and a listener that receives one batch of changes per frame.

use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::time::SystemTime;

use eyeball_im::VectorDiff;
use lux_core::ids::{ChatId, EventId, RoomId};
use lux_core::list::{self, DueReminder, ListListener, ListRow, ListSetup, ListUpdate, LoadState, Loading};
use lux_core::places::{ChatFilter, PlaceId};
use lux_core::ports::BackendError;
use lux_matrix::{KeptList, MatrixAccount};
use tokio::sync::oneshot;

use crate::account::{Backend, CoreAccount, CoreAccountError, CoreChat, CoreRequest, list_diff, with_account};
use crate::chat::{CoreLabel, CoreSavedMessage, CoreScheduledMessage};
use crate::organizing::CoreChatChange;
use crate::places::{
    CoreChatFilter, CoreChatOrder, CoreListedPlace, CorePlace, CoreSectionId, CoreSectionStyle, CoreTheme,
};
use crate::runtime;
use crate::store::CoreStore;

/// One row of a section.
#[derive(uniffi::Enum)]
pub enum CoreListRow {
    /// A chat.
    Chat {
        /// The chat.
        chat: CoreChat,
    },
    /// An invitation.
    Request {
        /// The invitation.
        request: CoreRequest,
    },
    /// A saved message, with its chat when the list has it.
    Saved {
        /// The message.
        message: CoreSavedMessage,
        /// Its chat.
        chat: Option<CoreChat>,
    },
    /// A message waiting to go, with its chat when the list has it.
    Scheduled {
        /// The message.
        message: CoreScheduledMessage,
        /// Its chat.
        chat: Option<CoreChat>,
    },
}

impl From<&ListRow> for CoreListRow {
    fn from(row: &ListRow) -> Self {
        let chat = |chat: &Option<Arc<lux_core::chat::Chat>>| chat.as_deref().map(CoreChat::from);
        match row {
            ListRow::Chat(chat) => Self::Chat {
                chat: CoreChat::from(chat.as_ref()),
            },
            ListRow::Request(request) => Self::Request {
                request: CoreRequest::from(request.as_ref()),
            },
            ListRow::Saved { message, chat: shown } => Self::Saved {
                message: CoreSavedMessage::from(message.as_ref().clone()),
                chat: chat(shown),
            },
            ListRow::Scheduled { message, chat: shown } => Self::Scheduled {
                message: CoreScheduledMessage::from(message.as_ref().clone()),
                chat: chat(shown),
            },
        }
    }
}

list_diff!(
    /// One change to a section's rows.
    CoreListRowDiff of CoreListRow from ListRow, |row: &ListRow| CoreListRow::from(row)
);

/// A section, without its rows.
#[derive(uniffi::Record)]
pub struct CoreSectionHeader {
    /// What it is.
    pub id: CoreSectionId,
    /// Its heading.
    pub title: Option<String>,
    /// How it draws.
    pub style: CoreSectionStyle,
}

/// The rows of a section that changed.
#[derive(uniffi::Record)]
pub struct CoreSectionRows {
    /// Which section.
    pub section: CoreSectionId,
    /// Its changes, in order; a new section starts from no rows.
    pub diffs: Vec<CoreListRowDiff>,
}

/// Where loading the list is.
#[derive(Clone, Copy, uniffi::Enum)]
pub enum CoreLoadState {
    /// No chats from the account yet.
    Connecting,
    /// The account's chats show while the server's first answer comes.
    Syncing {
        /// Chats that came after the first ones.
        new_chats: u32,
    },
    /// Up to date.
    Done,
}

/// How far the list is loaded.
#[derive(Clone, Copy, uniffi::Record)]
pub struct CoreLoading {
    /// Where loading is.
    pub state: CoreLoadState,
    /// The server answered the first sync.
    pub answered: bool,
}

impl From<Loading> for CoreLoading {
    fn from(loading: Loading) -> Self {
        Self {
            state: match loading.state {
                LoadState::Connecting => CoreLoadState::Connecting,
                LoadState::Syncing { new_chats } => CoreLoadState::Syncing { new_chats },
                LoadState::Done => CoreLoadState::Done,
            },
            answered: loading.answered,
        }
    }
}

/// A chat with a reminder.
#[derive(uniffi::Record)]
pub struct CoreDueReminder {
    /// The chat.
    pub chat: String,
    /// Its name.
    pub name: String,
    /// When to answer it.
    pub at: SystemTime,
}

impl From<DueReminder> for CoreDueReminder {
    fn from(reminder: DueReminder) -> Self {
        Self {
            chat: reminder.chat.to_string(),
            name: reminder.name,
            at: reminder.at,
        }
    }
}

/// One frame's changes to the chat list; what did not change is none or empty.
#[derive(uniffi::Record)]
pub struct CoreListUpdate {
    /// The place shown.
    pub place: CorePlace,
    /// The places, when any changed.
    pub places: Option<Vec<CoreListedPlace>>,
    /// The colour of the places without one of their own, when it changed.
    pub theme: Option<CoreTheme>,
    /// The sections in order, when they changed.
    pub sections: Option<Vec<CoreSectionHeader>>,
    /// The sections whose rows changed.
    pub rows: Vec<CoreSectionRows>,
    /// The labels, when they changed.
    pub labels: Option<Vec<CoreLabel>>,
    /// The chats with a reminder, when they changed.
    pub reminders: Option<Vec<CoreDueReminder>>,
    /// How far the list is loaded, when that changed.
    pub loading: Option<CoreLoading>,
}

impl From<ListUpdate> for CoreListUpdate {
    fn from(update: ListUpdate) -> Self {
        Self {
            place: update.place.into(),
            places: update
                .places
                .map(|places| places.into_iter().map(CoreListedPlace::from).collect()),
            theme: update.theme.map(CoreTheme::from),
            sections: update.sections.map(|sections| {
                sections
                    .into_iter()
                    .map(|header| CoreSectionHeader {
                        id: header.id.into(),
                        title: header.title,
                        style: header.style.into(),
                    })
                    .collect()
            }),
            rows: update
                .rows
                .into_iter()
                .map(|rows| CoreSectionRows {
                    section: rows.section.into(),
                    diffs: rows.diffs.into_iter().map(CoreListRowDiff::from).collect(),
                })
                .collect(),
            labels: update
                .labels
                .map(|labels| labels.into_iter().map(CoreLabel::from).collect()),
            reminders: update
                .reminders
                .map(|reminders| reminders.into_iter().map(CoreDueReminder::from).collect()),
            loading: update.loading.map(CoreLoading::from),
        }
    }
}

/// Receives the chat list's batches, from the list's task.
#[uniffi::export(with_foreign)]
pub trait CoreListListener: Send + Sync {
    /// One frame's changes; the first holds the whole list.
    fn on_update(&self, update: CoreListUpdate);
    /// An intent's action failed.
    fn on_error(&self, error: CoreAccountError);
}

/// The apps' listener as the view model's.
pub(crate) struct Relay(pub(crate) Arc<dyn CoreListListener>);

impl ListListener for Relay {
    fn on_update(&self, update: ListUpdate) {
        self.0.on_update(update.into());
    }

    fn on_error(&self, error: BackendError) {
        self.0.on_error(error.into());
    }
}

/// How a list starts.
#[derive(uniffi::Record)]
pub struct CoreListSetup {
    /// The place shown.
    pub place: CorePlace,
    /// Which of its chats show.
    pub filter: Option<CoreChatFilter>,
    /// In which order.
    pub order: CoreChatOrder,
    /// The chats with a draft on this device.
    pub drafts: Vec<String>,
}

impl From<CoreListSetup> for ListSetup {
    fn from(setup: CoreListSetup) -> Self {
        Self {
            place: setup.place.into(),
            filter: setup.filter.map(ChatFilter::from),
            order: setup.order.into(),
            drafts: setup.drafts.into_iter().map(ChatId::from).collect(),
        }
    }
}

/// What a list made before its account opened waits for: the device's kept list, then the
/// account.
struct Opening {
    kept: Option<oneshot::Sender<Option<Arc<CoreStore>>>>,
    account: Option<oneshot::Sender<Arc<MatrixAccount>>>,
}

/// A chat list: the apps forward the user's intents (at once, even before the list has its
/// chats: they wait in order); the batches go to its listener. Let go, it stops.
#[derive(uniffi::Object)]
pub struct CoreChatList {
    list: list::ChatListViewModel,
    opening: Mutex<Opening>,
}

#[uniffi::export]
impl CoreAccount {
    /// The account's chat list, sending its batches to `listener`.
    pub fn chat_list(&self, setup: CoreListSetup, listener: Arc<dyn CoreListListener>) -> Arc<CoreChatList> {
        let relay = Arc::new(Relay(listener));
        let list = with_account!(self.backend(), account => {
            let account = Arc::clone(account);
            list::ChatListViewModel::start(&runtime::handle(), async { Vec::new() }, async move { Some(account) }, setup.into(), relay)
        });
        Arc::new(CoreChatList {
            list,
            opening: Mutex::new(Opening {
                kept: None,
                account: None,
            }),
        })
    }
}

#[uniffi::export]
impl CoreChatList {
    /// A chat list before its account opens: it shows the list kept on the device once
    /// [`show_kept`](Self::show_kept) gives the store, then the account
    /// [`attach`](Self::attach) gives.
    #[uniffi::constructor]
    #[must_use]
    pub fn opening(setup: CoreListSetup, listener: Arc<dyn CoreListListener>) -> Arc<Self> {
        let (keep, kept) = oneshot::channel::<Option<Arc<CoreStore>>>();
        let (attach, opened) = oneshot::channel::<Arc<MatrixAccount>>();
        let list = list::ChatListViewModel::start(
            &runtime::handle(),
            async move {
                match kept.await {
                    Ok(Some(store)) => KeptList::new(Arc::clone(&store.store)).read().await,
                    _ => Vec::new(),
                }
            },
            async move { opened.await.ok() },
            setup.into(),
            Arc::new(Relay(listener)),
        );
        Arc::new(Self {
            list,
            opening: Mutex::new(Opening {
                kept: Some(keep),
                account: Some(attach),
            }),
        })
    }

    /// The account's encrypted store opened (none: it has none): the list it kept shows until
    /// the account attaches. Once; a list made for an open account has its chats already.
    pub fn show_kept(&self, store: Option<Arc<CoreStore>>) {
        let waiting = self.lock().kept.take();
        if let Some(waiting) = waiting {
            let _ = waiting.send(store);
        }
    }

    /// The account opened: the list follows it from now on. Once; a list made for an open
    /// account has it already, and the demo's lists are made open.
    pub fn attach(&self, account: &CoreAccount) {
        let mut opening = self.lock();
        // the kept list, if it has not come, is not waited for.
        if let Some(kept) = opening.kept.take() {
            let _ = kept.send(None);
        }
        if let (Some(waiting), Backend::Matrix(account)) = (opening.account.take(), account.backend()) {
            let _ = waiting.send(Arc::clone(account));
        }
    }

    /// Shows `place`.
    pub fn select_place(&self, place: CorePlace) {
        self.list.select_place(PlaceId::from(place));
    }

    /// Shows only the chats `filter` admits; none shows them all.
    pub fn set_filter(&self, filter: Option<CoreChatFilter>) {
        self.list.set_filter(filter.map(ChatFilter::from));
    }

    /// Puts the place's chats in `order`.
    pub fn set_order(&self, order: CoreChatOrder) {
        self.list.set_order(order.into());
    }

    /// The chats with a draft on this device.
    pub fn set_drafts(&self, drafts: Vec<String>) {
        self.list.set_drafts(drafts.into_iter().map(ChatId::from).collect());
    }

    /// Reads the waiting messages again.
    pub fn refresh(&self) {
        self.list.refresh();
    }

    /// Does one of a chat's menu actions.
    pub fn change(&self, chat_id: String, change: CoreChatChange) {
        self.list.change(ChatId::from(chat_id), change.into());
    }

    /// Answers an invitation.
    pub fn answer_request(&self, room_id: String, accept: bool) {
        self.list.answer_request(RoomId::from(room_id), accept);
    }

    /// Makes a label, and puts `with` in it.
    pub fn make_label(&self, name: String, with: Option<String>) {
        self.list.make_label(name, with.map(ChatId::from));
    }

    /// Deletes a label.
    pub fn remove_label(&self, id: String) {
        self.list.remove_label(id.into());
    }

    /// Puts a chat in a label, or takes it out.
    pub fn set_in_label(&self, chat_id: String, label_id: String, included: bool) {
        self.list.set_in_label(ChatId::from(chat_id), label_id.into(), included);
    }

    /// Reminds the user to answer a chat at `at`; none takes the reminder away.
    pub fn set_reminder(&self, chat_id: String, at: Option<SystemTime>) {
        self.list.set_reminder(ChatId::from(chat_id), at);
    }

    /// Takes a message out of the saved ones.
    pub fn unsave(&self, room_id: String, event_id: String) {
        self.list.unsave(RoomId::from(room_id), EventId::from(event_id));
    }

    /// Cancels a waiting message.
    pub fn cancel_scheduled(&self, id: String) {
        self.list.cancel_scheduled(id.into());
    }

    /// Shows chats as one, named `name`, writing to `default_room`.
    pub fn merge(&self, chat_ids: Vec<String>, name: String, default_room: String) {
        self.list.merge(
            chat_ids.into_iter().map(ChatId::from).collect(),
            name,
            RoomId::from(default_room),
        );
    }

    /// Takes a merged chat apart.
    pub fn unmerge(&self, chat_id: String) {
        self.list.unmerge(ChatId::from(chat_id));
    }

    /// Puts the places in this order.
    pub fn reorder(&self, places: Vec<CorePlace>) {
        self.list.reorder(places.into_iter().map(PlaceId::from).collect());
    }

    /// Hides a place, or shows it again.
    pub fn set_hidden(&self, place: CorePlace, hidden: bool) {
        self.list.set_hidden(place.into(), hidden);
    }

    /// Shows every hidden place again.
    pub fn show_all_places(&self) {
        self.list.show_all_places();
    }

    /// Gives a place its own colour, or (`None`) the one for every place.
    pub fn set_theme(&self, place: CorePlace, theme: Option<CoreTheme>) {
        self.list.set_theme(place.into(), theme.map(Into::into));
    }

    /// Sets the colour of the places without one of their own.
    pub fn set_default_theme(&self, theme: CoreTheme) {
        self.list.set_default_theme(theme.into());
    }
}

impl CoreChatList {
    fn lock(&self) -> MutexGuard<'_, Opening> {
        self.opening.lock().unwrap_or_else(PoisonError::into_inner)
    }
}
