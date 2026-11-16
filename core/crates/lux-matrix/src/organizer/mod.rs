//! The organizing kept in the account's data, owned by one task: it reads the documents from
//! the store at launch, takes each new version the sync brings (from any device), writes the
//! user's changes one after the other, and publishes what they add up to as one [`Organized`].
//!
//! A change is read, changed and written from the newest version the task has, so two changes in
//! a row both stay; the task takes its own write in as soon as the server accepted it, before
//! the sync brings it back.

pub(crate) mod formats;

use lux_core::gone::OtherEndGone;
use std::collections::{HashMap, HashSet};
use std::sync::Arc;
use std::time::Duration;

use lux_core::chat::Chat;
use lux_core::ids::UserId;
use lux_core::organizer::{LabelRecords, Organized};
use lux_core::ports::BackendError;
use matrix_sdk::Client;
use matrix_sdk::event_handler::EventHandlerHandle;
use matrix_sdk::ruma::api::client::filter::FilterDefinition;
use matrix_sdk::ruma::api::client::sync::sync_events::v3::{Filter, Request as SyncRequest};
use matrix_sdk::ruma::events::{
    AnyGlobalAccountDataEvent, AnyGlobalAccountDataEventContent, GlobalAccountDataEventType,
};
use matrix_sdk::ruma::serde::Raw;
use serde::Deserialize;
use serde_json::Value;
use tokio::sync::{mpsc, oneshot, watch};
use tracing::warn;

use crate::errors::{from_http, from_sdk};
use formats::Content;

/// One account data event to write: its type and content.
pub(crate) struct Write {
    pub(crate) event_type: String,
    pub(crate) content: Content,
}

impl Write {
    pub(crate) fn new(event_type: &str, content: Content) -> Self {
        Self {
            event_type: event_type.to_owned(),
            content,
        }
    }
}

/// A change: the writes it makes from the documents as they are when its turn comes.
pub(crate) type Change = Box<dyn FnOnce(&Documents) -> Result<Vec<Write>, BackendError> + Send>;

enum Command {
    /// Documents from the sync, or from the first read of the labels' records.
    Received { events: Vec<(String, Content)>, live: bool },
    /// A change of the user's.
    Change {
        change: Change,
        reply: Option<oneshot::Sender<Result<(), BackendError>>>,
    },
}

/// The documents the task holds, as the server last had them.
pub(crate) struct Documents {
    own: UserId,
    contents: HashMap<String, Content>,
    labels: LabelRecords,
    /// The types the sync brought since launch: newer than the labels' first read.
    live: HashSet<String>,
}

/// An empty document, for a type the account never wrote.
static EMPTY: std::sync::LazyLock<Content> = std::sync::LazyLock::new(Content::new);

impl Documents {
    /// The document of `event_type`; empty for none.
    pub(crate) fn content(&self, event_type: &str) -> &Content {
        self.contents.get(event_type).unwrap_or(&EMPTY)
    }

    /// The labels' records.
    pub(crate) fn labels(&self) -> &LabelRecords {
        &self.labels
    }

    /// Everything organized, read from the documents.
    pub(crate) fn organized(&self) -> Organized {
        let merges = formats::merges(self.content(formats::MERGES));
        Organized {
            marks: formats::chat_marks(self.content(formats::CHATS)),
            reminders: formats::reminders(self.content(formats::REMINDERS)),
            labels: lux_core::merge::label_merges(self.labels.labels(), &merges),
            merges,
            saved: formats::bookmarks(self.content(formats::BOOKMARKS), &self.own),
            arrangement: formats::arrangement(self.content(formats::PLACE_ORDER)),
        }
    }

    fn receive(&mut self, event_type: String, content: Content, live: bool) {
        if !live && self.live.contains(&event_type) {
            return;
        }
        if live {
            self.live.insert(event_type.clone());
        }
        if event_type == formats::LABELS {
            self.labels.whole = formats::whole_labels(&content);
        } else if event_type.starts_with(formats::LABEL_RECORD_PREFIX) {
            match formats::label_record(&event_type, &content) {
                Some(record) => {
                    self.labels.records.insert(event_type.clone(), record);
                }
                None => {
                    self.labels.records.remove(&event_type);
                }
            }
        }
        self.contents.insert(event_type, content);
    }
}

/// The organizer: its task, and what the account's parts hold of it.
pub(crate) struct Organizer {
    commands: mpsc::UnboundedSender<Command>,
    state: watch::Receiver<Arc<Organized>>,
    client: Client,
    handler: EventHandlerHandle,
    _tasks: [crate::task::Owned; 2],
}

/// A handle that sends changes to the organizer's task; the chat list's task holds one.
#[derive(Clone)]
pub(crate) struct Changes(mpsc::UnboundedSender<Command>);

impl Changes {
    /// Sends a change without waiting for it (the chat list's tidying). The task reports its
    /// failure; with the task gone (the account closing), the change is not made.
    pub(crate) fn send(&self, change: Change) {
        if self.0.send(Command::Change { change, reply: None }).is_err() {
            warn!("a change of the account data is not made: the account has closed");
        }
    }
}

impl Organizer {
    /// Reads the documents from the store, starts the task, listens to the sync, and reads the
    /// labels' records from the server in the background.
    pub(crate) async fn start(client: Client, own: UserId) -> Self {
        let mut documents = Documents {
            own,
            contents: HashMap::new(),
            labels: LabelRecords::default(),
            live: HashSet::new(),
        };
        let account = client.account();
        for event_type in formats::KNOWN {
            match account
                .account_data_raw(GlobalAccountDataEventType::from(event_type))
                .await
            {
                Ok(Some(raw)) => match raw.deserialize_as_unchecked::<Content>() {
                    Ok(content) => documents.receive(event_type.to_owned(), content, false),
                    Err(error) => warn!(%error, event_type, "an account data event cannot be read"),
                },
                Ok(None) => {}
                Err(error) => warn!(%error, event_type, "the store's account data cannot be read"),
            }
        }
        let (state_sender, state) = watch::channel(Arc::new(documents.organized()));
        let (commands, receiver) = mpsc::unbounded_channel();
        let handler = client.add_event_handler({
            let commands = commands.clone();
            move |event: Raw<AnyGlobalAccountDataEvent>| {
                let commands = commands.clone();
                async move {
                    if let Some(event) = own_event(&event) {
                        commands
                            .send(Command::Received {
                                events: vec![event],
                                live: true,
                            })
                            .other_end_may_be_gone("the organizer's task");
                    }
                }
            }
        });
        let run = crate::task::spawn(run(client.clone(), documents, receiver, state_sender));
        let discover = crate::task::spawn(discover_records(client.clone(), commands.clone()));
        Self {
            commands,
            state,
            client,
            handler,
            _tasks: [run, discover],
        }
    }

    /// What is organized now.
    pub(crate) fn now(&self) -> Arc<Organized> {
        Arc::clone(&self.state.borrow())
    }

    /// What is organized, each time it changes.
    pub(crate) fn subscribe(&self) -> watch::Receiver<Arc<Organized>> {
        self.state.clone()
    }

    /// A handle for sending changes.
    pub(crate) fn changes(&self) -> Changes {
        Changes(self.commands.clone())
    }

    /// Makes `change` once the changes before it are done; returns when the server has it.
    pub(crate) async fn change(&self, change: Change) -> Result<(), BackendError> {
        let (reply, answer) = oneshot::channel();
        self.commands
            .send(Command::Change {
                change,
                reply: Some(reply),
            })
            .map_err(|_| BackendError::SignedOut)?;
        answer.await.map_err(|_| BackendError::SignedOut)?
    }
}

impl Drop for Organizer {
    fn drop(&mut self) {
        self.client.remove_event_handler(self.handler.clone());
    }
}

/// The task: the only writer of the documents.
async fn run(
    client: Client,
    mut documents: Documents,
    mut commands: mpsc::UnboundedReceiver<Command>,
    state: watch::Sender<Arc<Organized>>,
) {
    while let Some(command) = commands.recv().await {
        let reply = match command {
            Command::Received { events, live } => {
                for (event_type, content) in events {
                    documents.receive(event_type, content, live);
                }
                None
            }
            Command::Change { change, reply } => {
                let result = match change(&documents) {
                    Ok(writes) => write_all(&client, &mut documents, writes).await,
                    Err(error) => Err(error),
                };
                Some((reply, result))
            }
        };
        // published before the answer: the caller reads what it changed.
        let organized = documents.organized();
        state.send_if_modified(|current| {
            let changed = **current != organized;
            if changed {
                *current = Arc::new(organized);
            }
            changed
        });
        match reply {
            // the caller stopped waiting: its failure is reported here instead.
            Some((Some(reply), result)) => {
                if let Err(Err(error)) = reply.send(result) {
                    warn!(?error, "a change of the account data failed");
                }
            }
            Some((None, Err(error))) => warn!(?error, "a change of the account data failed"),
            Some((None, Ok(()))) | None => {}
        }
    }
}

/// Writes each event in turn, taking in each the server accepted.
async fn write_all(client: &Client, documents: &mut Documents, writes: Vec<Write>) -> Result<(), BackendError> {
    let account = client.account();
    for write in writes {
        let raw = serde_json::value::to_raw_value(&write.content).map_err(BackendError::store)?;
        account
            .set_account_data_raw(
                GlobalAccountDataEventType::from(write.event_type.as_str()),
                Raw::<AnyGlobalAccountDataEventContent>::from_json(raw),
            )
            .await
            .map_err(from_sdk)?;
        documents.receive(write.event_type, write.content, true);
    }
    Ok(())
}

/// One of the app's own events, as its type and content.
fn own_event(event: &Raw<AnyGlobalAccountDataEvent>) -> Option<(String, Content)> {
    #[derive(Deserialize)]
    struct Event {
        #[serde(rename = "type")]
        event_type: String,
        content: Value,
    }
    let event = event.deserialize_as_unchecked::<Event>().ok()?;
    if !event.event_type.starts_with(formats::PREFIX) {
        return None;
    }
    match event.content {
        Value::Object(content) => Some((event.event_type, content)),
        _ => None,
    }
}

/// Reads the labels' records from the server: the store keeps account data by type, and a
/// record's type is not known before it is read. One filtered sync from the start, with no
/// position, so the SDK's own sync is untouched; tried again until it answers.
async fn discover_records(client: Client, commands: mpsc::UnboundedSender<Command>) {
    let mut wait = Duration::from_secs(2);
    loop {
        match read_records(&client).await {
            Ok(events) => {
                commands
                    .send(Command::Received { events, live: false })
                    .other_end_may_be_gone("the organizer's task");
                return;
            }
            Err(error) => warn!(?error, "the labels could not be read from the server"),
        }
        tokio::time::sleep(wait).await;
        wait = (wait * 2).min(Duration::from_secs(300));
    }
}

async fn read_records(client: &Client) -> Result<Vec<(String, Content)>, BackendError> {
    let mut filter = FilterDefinition::default();
    // a type no event has, new each time: a server that caches identical syncs answers afresh.
    let fresh = format!("{}discovery.{}", formats::LABEL_RECORD_PREFIX, uuid::Uuid::new_v4());
    filter.account_data.types = Some(vec![
        formats::LABELS.to_owned(),
        format!("{}*", formats::LABEL_RECORD_PREFIX),
        fresh,
    ]);
    filter.presence.types = Some(Vec::new());
    filter.room.rooms = Some(Vec::new());
    let mut request = SyncRequest::new();
    request.filter = Some(Filter::FilterDefinition(filter));
    request.timeout = Some(Duration::ZERO);
    let response = client.send(request).await.map_err(from_http)?;
    Ok(response.account_data.events.iter().filter_map(own_event).collect())
}

/// The chats whose marks may have to go: those archived or deleted.
pub(crate) fn marked<'a>(organized: &Organized, rooms: impl IntoIterator<Item = &'a Chat>) -> Vec<Chat> {
    rooms
        .into_iter()
        .filter(|chat| {
            chat.id.room().is_some_and(|room| {
                organized.marks.archived.contains_key(room) || organized.marks.hidden.contains_key(room)
            })
        })
        .cloned()
        .collect()
}
