//! Agents on the Mac (`lux-agent`): the app serves its chats and its index on a socket, and asks
//! the user through the app (the approval, the embedding of a search's words, a draft shown, a
//! message to send).

use std::collections::HashSet;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::SystemTime;

use futures_util::StreamExt;
use lux_agent::{
    Agent, AgentBackend, Approval, ApprovalAnswer, Approver, BackendError, ChatStyle, ChatSummary, ClientKind,
    Folder as AgentFolder, Grant, LogEntry, MessageHit, Notifications, Organize, Place, SendOutcome, Setting,
};
use lux_core::chat::{Chat, Folder, NotificationMode};
use lux_core::ids::{ChatId, RoomId};
use lux_core::ports::{ChatActions, ChatChange, ChatDetails, Organizing, Spaces};
use lux_store::TextSearch;
use tokio::sync::oneshot;
use tokio::task::JoinHandle;

use crate::account::{CoreAccount, CoreAccountError, CoreChat, with_account};
use crate::runtime;
use crate::store::CoreStore;

/// What an agent's session may do.
#[derive(Clone, Copy, Debug, uniffi::Enum)]
pub enum CoreAgentGrant {
    /// Read chats and messages.
    Read,
    /// Also write drafts.
    Drafts,
    /// Also organize the chats and change the app's settings an agent may.
    Organize,
    /// Also ask to send, each message after the user's click.
    Send,
    /// Also send on its own, in a chat it read, a few an hour.
    AutoSend,
}

impl From<Grant> for CoreAgentGrant {
    fn from(grant: Grant) -> Self {
        match grant {
            Grant::Read => Self::Read,
            Grant::Drafts => Self::Drafts,
            Grant::Organize => Self::Organize,
            Grant::Send => Self::Send,
            Grant::AutoSend => Self::AutoSend,
        }
    }
}

impl From<CoreAgentGrant> for Grant {
    fn from(grant: CoreAgentGrant) -> Self {
        match grant {
            CoreAgentGrant::Read => Self::Read,
            CoreAgentGrant::Drafts => Self::Drafts,
            CoreAgentGrant::Organize => Self::Organize,
            CoreAgentGrant::Send => Self::Send,
            CoreAgentGrant::AutoSend => Self::AutoSend,
        }
    }
}

/// An approval the app shows: who asks, the match code, what for.
#[derive(uniffi::Record)]
pub struct CoreAgentApproval {
    /// The client's name, as it says.
    pub client: String,
    /// It is the CLI (else an MCP client).
    pub is_cli: bool,
    /// The command line, for the CLI.
    pub command: Option<String>,
    /// The folder it runs in.
    pub folder: Option<String>,
    /// The match code the client shows too.
    pub code: String,
    /// What it asks for; none for the app's default.
    pub grant: Option<CoreAgentGrant>,
    /// Why, for a request for more.
    pub reason: Option<String>,
}

/// One answer, once, from any thread.
pub struct Reply<T> {
    sender: Mutex<Option<oneshot::Sender<T>>>,
}

impl<T> Reply<T> {
    fn new() -> (Self, oneshot::Receiver<T>) {
        let (sender, receiver) = oneshot::channel();
        (
            Self {
                sender: Mutex::new(Some(sender)),
            },
            receiver,
        )
    }

    fn send(&self, value: T) {
        let sender = self.sender.lock().ok().and_then(|mut sender| sender.take());
        if let Some(sender) = sender
            && sender.send(value).is_err()
        {
            tracing::debug!("an agent's answer came after the core stopped waiting");
        }
    }
}

/// Where the user's answer to an approval goes.
#[derive(uniffi::Object)]
pub struct CoreAgentApprovalReply(Reply<ApprovalAnswer>);

#[uniffi::export]
impl CoreAgentApprovalReply {
    /// Approved: the session may do `grant`.
    pub fn grant(&self, grant: CoreAgentGrant) {
        self.0.send(ApprovalAnswer::Granted(grant.into()));
    }

    /// Refused, with why in the user's words.
    pub fn refuse(&self, reason: String) {
        self.0.send(ApprovalAnswer::Refused(reason));
    }
}

/// Where a search's words' embedding goes: none to search by words only.
#[derive(uniffi::Object)]
pub struct CoreAgentEmbeddingReply(Reply<Option<(Vec<f32>, f32)>>);

#[uniffi::export]
impl CoreAgentEmbeddingReply {
    /// The words' embedding in the messages' space, and the least cosine a message found by its
    /// meaning has.
    pub fn embedding(&self, embedding: Vec<f32>, min_similarity: f32) {
        self.0.send(Some((embedding, min_similarity)));
    }

    /// No embedding: by words only.
    pub fn none(&self) {
        self.0.send(None);
    }
}

/// Where the user's answer to a message an agent asked to send goes: the core sends it.
#[derive(uniffi::Object)]
pub struct CoreAgentSendReply(Reply<bool>);

#[uniffi::export]
impl CoreAgentSendReply {
    /// The user allowed it to be sent, or not.
    pub fn answer(&self, allowed: bool) {
        self.0.send(allowed);
    }
}

/// One of the app's settings an agent may read and change.
#[derive(uniffi::Record)]
pub struct CoreAgentSetting {
    /// Its name, for the tools (`chat_style`).
    pub name: String,
    /// What it is, for the model.
    pub description: String,
    /// Its value now.
    pub value: String,
    /// The values it takes.
    pub choices: Vec<String>,
}

/// Where the app gives its settings.
#[derive(uniffi::Object)]
pub struct CoreAgentSettingsReply(Reply<Vec<CoreAgentSetting>>);

#[uniffi::export]
impl CoreAgentSettingsReply {
    /// The settings as they are now.
    pub fn settings(&self, settings: Vec<CoreAgentSetting>) {
        self.0.send(settings);
    }
}

/// Where the app says whether a change it was asked for is done.
#[derive(uniffi::Object)]
pub struct CoreAgentChangeReply(Reply<Result<(), String>>);

#[uniffi::export]
impl CoreAgentChangeReply {
    /// Done.
    pub fn done(&self) {
        self.0.send(Ok(()));
    }

    /// Not done, and why.
    pub fn failed(&self, reason: String) {
        self.0.send(Err(reason));
    }
}

/// Where the app says whether it showed a draft.
#[derive(uniffi::Object)]
pub struct CoreAgentDraftReply(Reply<Result<(), String>>);

#[uniffi::export]
impl CoreAgentDraftReply {
    /// The draft is in the chat's composer.
    pub fn shown(&self) {
        self.0.send(Ok(()));
    }

    /// It could not be shown, and why.
    pub fn failed(&self, reason: String) {
        self.0.send(Err(reason));
    }
}

/// One call, for the activity log.
#[derive(uniffi::Record)]
pub struct CoreAgentLogEntry {
    /// The client.
    pub client: String,
    /// The tool.
    pub tool: String,
    /// The chats it touched.
    pub chats: Vec<String>,
    /// How many messages it gave back.
    pub messages: u32,
    /// Why it was refused, if it was.
    pub refused: Option<String>,
}

/// The app's side of the agents: the user's answers, and what only the app can do.
#[uniffi::export(with_foreign)]
pub trait CoreAgentHost: Send + Sync {
    /// Asks the user to approve `approval` (or answers at once: a client approved for always),
    /// through `reply`.
    fn approve(&self, approval: CoreAgentApproval, reply: Arc<CoreAgentApprovalReply>);

    /// The embedding of a search's `words`, through `reply`.
    fn embed(&self, words: String, reply: Arc<CoreAgentEmbeddingReply>);

    /// A network's name as the app shows it (`WhatsApp`).
    fn network_name(&self, network: String) -> String;

    /// Opens the chat of `room_id` with `text` in its composer; whether it did through `reply`.
    fn show_draft(&self, room_id: String, text: String, reply: Arc<CoreAgentDraftReply>);

    /// Opens the chat of `room_id` and shows `text` to send, asked by `client`: the user's Send
    /// or Cancel through `reply`. The core sends it, as text alone: nothing of the composer's.
    fn confirm_send(&self, room_id: String, text: String, client: String, reply: Arc<CoreAgentSendReply>);

    /// The app's settings an agent may read and change, through `reply`.
    fn settings(&self, reply: Arc<CoreAgentSettingsReply>);

    /// Sets the setting `name` to `value` (one of its choices); whether it did through `reply`.
    fn change_setting(&self, name: String, value: String, reply: Arc<CoreAgentChangeReply>);

    /// Sets how the chat `chat_id` draws its messages on this device: `bubbles`, `plain`, or none
    /// to follow the app's setting; whether it did through `reply`.
    fn set_chat_style(&self, chat_id: String, style: Option<String>, reply: Arc<CoreAgentChangeReply>);

    /// Keeps `entry` in the activity log.
    fn log(&self, entry: CoreAgentLogEntry);
}

/// The account and its index, as the agents' tools reach them.
struct AppBackend {
    account: Arc<CoreAccount>,
    store: Arc<CoreStore>,
    host: Arc<dyn CoreAgentHost>,
}

impl AppBackend {
    /// The room the app opens the chat `id` by: a merged chat's default, or its first; any
    /// other chat's own.
    async fn room(&self, id: &str) -> Result<String, BackendError> {
        let chat = self.account.chats().await.into_iter().find(|chat| chat.id == id);
        chat.and_then(|chat| chat.default_room.clone().or_else(|| rooms(&chat).into_iter().next()))
            .ok_or_else(|| BackendError {
                reason: format!("no chat `{id}`"),
            })
    }
}

/// A space or a label, as the tools give it.
fn place(id: &str, name: &str) -> Place {
    Place {
        id: id.to_owned(),
        name: name.to_owned(),
    }
}

/// The places (spaces or labels) `chat` is in: by its id, or any of a merged chat's rooms.
fn within(chat: &Chat, places: &[(Place, HashSet<ChatId>)]) -> Vec<Place> {
    places
        .iter()
        .filter(|(_, chats)| {
            chats.contains(&chat.id)
                || chat
                    .rooms
                    .iter()
                    .any(|room| chats.contains(&ChatId::from(room.id.as_str())))
        })
        .map(|(place, _)| place.clone())
        .collect()
}

/// A chat's rooms: a merged chat's, or any other chat's own (whose id is its room's).
fn rooms(chat: &CoreChat) -> Vec<String> {
    if chat.rooms.is_empty() {
        vec![chat.id.clone()]
    } else {
        chat.rooms.iter().map(|room| room.id.clone()).collect()
    }
}

fn gone(_: oneshot::error::RecvError) -> BackendError {
    BackendError {
        reason: "Lux gave no answer".to_owned(),
    }
}

fn hit(hit: lux_store::Hit) -> MessageHit {
    MessageHit {
        id: hit.event_id.to_string(),
        room: hit.room_id.to_string(),
        sender: hit.sender_name,
        text: hit.excerpt,
        sent_at: hit.date,
        mine: hit.is_own,
    }
}

impl AgentBackend for AppBackend {
    async fn hidden(&self) -> Result<HashSet<String>, BackendError> {
        Ok(hidden(&self.account)
            .await
            .ok_or_else(|| BackendError {
                reason: "the chats kept from AI cannot be read now".to_owned(),
            })?
            .into_iter()
            .map(|chat| chat.chat.to_string())
            .collect())
    }

    async fn chats(&self) -> Result<Vec<ChatSummary>, BackendError> {
        let spaces: Vec<(Place, HashSet<ChatId>)> = {
            let mut spaces = with_account!(self.account.backend(), account => account.spaces());
            spaces
                .next()
                .await
                .map(|spaces| {
                    spaces
                        .iter()
                        .map(|space| (place(space.id.as_str(), &space.name), space.chats.clone()))
                        .collect()
                })
                .unwrap_or_default()
        };
        let labels: Vec<(Place, HashSet<ChatId>)> = {
            let mut organized = with_account!(self.account.backend(), account => account.organized());
            organized
                .next()
                .await
                .map(|organized| {
                    organized
                        .labels
                        .iter()
                        .map(|label| (place(label.id.as_str(), &label.name), label.chats.clone()))
                        .collect()
                })
                .unwrap_or_default()
        };
        Ok(self
            .account
            .current_chats()
            .await
            .iter()
            .map(|chat| {
                let core = CoreChat::from(chat.as_ref());
                ChatSummary {
                    rooms: rooms(&core),
                    network: self.host.network_name(core.network),
                    spaces: within(chat, &spaces),
                    labels: within(chat, &labels),
                    folder: match chat.folder {
                        Folder::Inbox => AgentFolder::Inbox,
                        Folder::LowPriority => AgentFolder::LowPriority,
                        Folder::Archive => AgentFolder::Archive,
                    },
                    pinned: chat.pinned.is_some(),
                    notifications: chat.notifications.map(|mode| match mode {
                        NotificationMode::Default => Notifications::Default,
                        NotificationMode::All => Notifications::All,
                        NotificationMode::Mentions => Notifications::Mentions,
                        NotificationMode::Off => Notifications::Off,
                    }),
                    id: core.id,
                    name: core.name,
                    is_group: core.is_group,
                    unread: core.unread_count.max(u32::from(core.is_marked_unread)),
                    muted: core.is_muted,
                    last_activity: core.date,
                }
            })
            .collect())
    }

    /// As the chat list's menu does it: `inbox` takes a chat out of Low Priority or the archive,
    /// whichever it is in.
    async fn organize(&self, chat: String, change: Organize) -> Result<(), BackendError> {
        let id = ChatId::from(chat.as_str());
        let change = match change {
            Organize::Read => ChatChange::Read,
            Organize::Unread => ChatChange::Unread,
            Organize::LowPriority => ChatChange::LowPriority,
            Organize::Archive => ChatChange::Archive,
            Organize::Pin => ChatChange::Pin,
            Organize::Unpin => ChatChange::Unpin,
            Organize::Mute => ChatChange::Mute,
            Organize::Unmute => ChatChange::Unmute,
            Organize::Inbox => {
                let chats = self.account.current_chats().await;
                match chats.iter().find(|shown| shown.id == id).map(|shown| shown.folder) {
                    Some(Folder::Archive) => ChatChange::Unarchive,
                    Some(Folder::LowPriority) => ChatChange::Inbox,
                    Some(Folder::Inbox) => return Ok(()),
                    None => {
                        return Err(BackendError {
                            reason: format!("no chat `{chat}`"),
                        });
                    }
                }
            }
        };
        with_account!(self.account.backend(), account => account.change(&id, change).await).map_err(|error| {
            BackendError {
                reason: error.to_string(),
            }
        })
    }

    async fn set_notifications(&self, chat: String, notifications: Notifications) -> Result<(), BackendError> {
        let id = ChatId::from(chat.as_str());
        let mode = match notifications {
            Notifications::Default => NotificationMode::Default,
            Notifications::All => NotificationMode::All,
            Notifications::Mentions => NotificationMode::Mentions,
            Notifications::Off => NotificationMode::Off,
        };
        with_account!(self.account.backend(), account => account.set_notifications(&id, mode).await).map_err(|error| {
            BackendError {
                reason: error.to_string(),
            }
        })
    }

    async fn set_chat_style(&self, chat: String, style: ChatStyle) -> Result<(), BackendError> {
        let style = match style {
            ChatStyle::Bubbles => Some("bubbles".to_owned()),
            ChatStyle::Plain => Some("plain".to_owned()),
            ChatStyle::Default => None,
        };
        let (reply, done) = Reply::new();
        self.host
            .set_chat_style(chat, style, Arc::new(CoreAgentChangeReply(reply)));
        done.await.map_err(gone)?.map_err(|reason| BackendError { reason })
    }

    async fn settings(&self) -> Result<Vec<Setting>, BackendError> {
        let (reply, settings) = Reply::new();
        self.host.settings(Arc::new(CoreAgentSettingsReply(reply)));
        Ok(settings
            .await
            .map_err(gone)?
            .into_iter()
            .map(|setting| Setting {
                name: setting.name,
                description: setting.description,
                value: setting.value,
                choices: setting.choices,
            })
            .collect())
    }

    async fn change_setting(&self, name: String, value: String) -> Result<(), BackendError> {
        let (reply, done) = Reply::new();
        self.host
            .change_setting(name, value, Arc::new(CoreAgentChangeReply(reply)));
        done.await.map_err(gone)?.map_err(|reason| BackendError { reason })
    }

    async fn search(&self, query: String, rooms: Vec<String>, limit: u32) -> Result<Vec<MessageHit>, BackendError> {
        let (reply, embedding) = Reply::new();
        self.host.embed(query.clone(), Arc::new(CoreAgentEmbeddingReply(reply)));
        let (embedding, min_similarity) = match embedding.await.map_err(gone)? {
            Some((embedding, min_similarity)) => (Some(embedding), min_similarity),
            None => (None, 1.0),
        };
        let rooms: Vec<Option<RoomId>> = if rooms.is_empty() {
            vec![None]
        } else {
            rooms.into_iter().map(|room| Some(RoomId::from(room))).collect()
        };
        let mut hits = Vec::new();
        for room_id in rooms {
            let search = TextSearch {
                text: query.clone(),
                embedding: embedding.clone(),
                min_similarity,
                room_id,
                limit,
            };
            let found = self.store.store.search(search).await.map_err(|error| BackendError {
                reason: error.to_string(),
            })?;
            hits.extend(found.into_iter().map(hit));
        }
        Ok(hits)
    }

    async fn recent(
        &self,
        room: String,
        before: Option<SystemTime>,
        limit: u32,
    ) -> Result<Vec<MessageHit>, BackendError> {
        let found = self
            .store
            .store
            .recent(RoomId::from(room), before, limit)
            .await
            .map_err(|error| BackendError {
                reason: error.to_string(),
            })?;
        Ok(found.into_iter().map(hit).collect())
    }

    async fn show_draft(&self, chat: String, text: String) -> Result<(), BackendError> {
        let room = self.room(&chat).await?;
        let (reply, shown) = Reply::new();
        self.host.show_draft(room, text, Arc::new(CoreAgentDraftReply(reply)));
        shown.await.map_err(gone)?.map_err(|reason| BackendError { reason })
    }

    /// Sends `text` alone to the chat's room, returning once the server has it: nothing of the
    /// composer's (its files, a reply or an edit) goes with it.
    async fn send(&self, chat: String, text: String) -> Result<(), BackendError> {
        let room = self.room(&chat).await?;
        self.account
            .send_now(room, None, text)
            .await
            .map_err(|error| BackendError {
                reason: error.to_string(),
            })
    }

    async fn confirm_send(&self, chat: String, text: String, client: String) -> Result<SendOutcome, BackendError> {
        let room = self.room(&chat).await?;
        let (reply, allowed) = Reply::new();
        self.host
            .confirm_send(room, text.clone(), client, Arc::new(CoreAgentSendReply(reply)));
        if !allowed.await.map_err(gone)? {
            return Ok(SendOutcome::Cancelled);
        }
        self.send(chat, text).await?;
        Ok(SendOutcome::Sent)
    }

    fn log(&self, entry: LogEntry) {
        self.host.log(CoreAgentLogEntry {
            client: entry.client,
            tool: entry.tool,
            chats: entry.chats,
            messages: entry.messages,
            refused: entry.refused,
        });
    }
}

/// The user, through the app's dialog.
struct AppApprover(Arc<dyn CoreAgentHost>);

impl Approver for AppApprover {
    async fn approve(&self, approval: Approval) -> ApprovalAnswer {
        let (reply, answer) = Reply::new();
        self.0.approve(
            CoreAgentApproval {
                client: approval.hello.client,
                is_cli: approval.hello.kind == ClientKind::Cli,
                command: approval.hello.command,
                folder: approval.hello.folder,
                code: approval.code,
                grant: approval.grant.map(Into::into),
                reason: approval.reason,
            },
            Arc::new(CoreAgentApprovalReply(reply)),
        );
        answer
            .await
            .unwrap_or_else(|_| ApprovalAnswer::Refused("Lux gave no answer".to_owned()))
    }
}

/// Why the agents' socket could not open.
#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum CoreAgentsError {
    /// The socket could not be made.
    #[error("the agents' socket cannot open: {reason}")]
    Socket {
        /// Why.
        reason: String,
    },
}

/// The agents' socket, open while this lives.
#[derive(uniffi::Object)]
pub struct CoreAgents {
    task: JoinHandle<()>,
}

#[uniffi::export]
impl CoreAgents {
    /// Serves `account`'s chats and `store`'s index to agents on the socket at `socket_path`,
    /// asking the user through `host`; until it is let go.
    ///
    /// # Errors
    /// When the socket cannot be made.
    #[uniffi::constructor]
    pub fn start(
        socket_path: String,
        account: Arc<CoreAccount>,
        store: Arc<CoreStore>,
        host: Arc<dyn CoreAgentHost>,
    ) -> Result<Arc<Self>, CoreAgentsError> {
        let agent = Arc::new(Agent::new(AppBackend {
            account,
            store,
            host: Arc::clone(&host),
        }));
        let path = PathBuf::from(socket_path);
        let listener = {
            let _entered = runtime::handle().enter();
            lux_agent::bind(&path).map_err(|error| CoreAgentsError::Socket {
                reason: error.to_string(),
            })?
        };
        let task = runtime::handle().spawn(lux_agent::serve(
            listener,
            Arc::clone(&agent),
            Arc::new(AppApprover(host)),
        ));
        Ok(Arc::new(Self { task }))
    }
}

impl Drop for CoreAgents {
    fn drop(&mut self) {
        self.task.abort();
    }
}

/// A chat kept from every AI in Lux.
#[derive(uniffi::Record)]
pub struct CoreHiddenChat {
    /// The chat's id, as the list has it.
    pub chat_id: String,
    /// Its name when it was hidden.
    pub name: String,
}

#[uniffi::export(async_runtime = "tokio")]
impl CoreAccount {
    /// The chats kept from every AI in Lux, on every device.
    pub async fn hidden_from_ai(&self) -> Vec<CoreHiddenChat> {
        hidden(self)
            .await
            .unwrap_or_default()
            .into_iter()
            .map(|chat| CoreHiddenChat {
                chat_id: chat.chat.to_string(),
                name: chat.name,
            })
            .collect()
    }

    /// Keeps the chat `chat_id` (named `name`) from every AI in Lux, or shows it again.
    ///
    /// # Errors
    /// When the server does not take it.
    pub async fn set_hidden_from_ai(
        &self,
        chat_id: String,
        name: String,
        hidden: bool,
    ) -> Result<(), CoreAccountError> {
        let chat = ChatId::from(chat_id.as_str());
        with_account!(self.backend(), account => account.set_hidden_from_ai(&chat, &name, hidden).await)?;
        Ok(())
    }
}

/// The account's hidden chats now.
/// The chats kept from AI, as the account's organizer has them; none when it cannot say.
async fn hidden(account: &CoreAccount) -> Option<Vec<lux_core::organizer::HiddenChat>> {
    let mut organized = with_account!(account.backend(), account => account.organized());
    organized.next().await.map(|organized| organized.hidden_from_ai.clone())
}

/// The `lux` binary: the app's executable run as `Lux agent <arguments>`, a CLI or an MCP server
/// over stdio that reaches the app's socket at `socket_path`. Runs to its end and gives the
/// process's exit code.
#[uniffi::export]
#[must_use]
pub fn run_agent(arguments: Vec<String>, socket_path: String) -> i32 {
    let Ok(runtime) = tokio::runtime::Builder::new_current_thread().enable_all().build() else {
        return 1;
    };
    runtime.block_on(lux_agent::run_client(arguments, PathBuf::from(socket_path)))
}

/// The agent skill, a `SKILL.md`: what Lux is to an agent, and how its permissions work.
#[uniffi::export]
#[must_use]
pub fn agent_skill() -> String {
    lux_agent::skill()
}
