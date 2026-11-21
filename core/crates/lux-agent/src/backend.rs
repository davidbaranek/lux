//! The account, as the tools reach it.

use std::collections::HashSet;
use std::future::Future;
use std::time::SystemTime;

/// A chat as the list shows it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ChatSummary {
    /// The chat's id, stable.
    pub id: String,
    /// Its rooms: one, or a merged chat's.
    pub rooms: Vec<String>,
    /// Its name.
    pub name: String,
    /// Its network, by name (`WhatsApp`); `Matrix` for Matrix's own.
    pub network: String,
    /// More than one other person.
    pub is_group: bool,
    /// Unread messages.
    pub unread: u32,
    /// Muted.
    pub muted: bool,
    /// Its last message's time.
    pub last_activity: Option<SystemTime>,
    /// The folder it is in.
    pub folder: Folder,
    /// Pinned on top of the inbox.
    pub pinned: bool,
    /// When its messages notify; none when a merged chat's rooms are set apart.
    pub notifications: Option<Notifications>,
    /// The spaces it is in (theirs, and those around them).
    pub spaces: Vec<Place>,
    /// The labels it is in.
    pub labels: Vec<Place>,
}

/// A space or a label, as a chat is in it.
#[derive(Clone, Debug, PartialEq, Eq, serde::Serialize, schemars::JsonSchema)]
pub struct Place {
    /// Its id.
    pub id: String,
    /// Its name.
    pub name: String,
}

/// Where a chat is.
#[derive(Clone, Copy, Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum Folder {
    /// The inbox.
    Inbox,
    /// Low Priority.
    LowPriority,
    /// The archive.
    Archive,
}

/// When a chat's messages notify.
#[derive(Clone, Copy, Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum Notifications {
    /// As the account's settings say for a chat of its kind.
    Default,
    /// Every message.
    All,
    /// Only mentions of the user and their keywords.
    Mentions,
    /// Nothing (a mention still shows in the list).
    Off,
}

/// One of a chat's organizing actions, as the chat list's menu has them.
#[derive(Clone, Copy, Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum Organize {
    /// Read up to its newest message (a read receipt goes, as the user's settings say), and not
    /// marked unread.
    Read,
    /// Marked unread.
    Unread,
    /// Into Low Priority.
    LowPriority,
    /// Back to the inbox (out of Low Priority or the archive).
    Inbox,
    /// Into the archive, until a newer message.
    Archive,
    /// Pinned on top of the inbox.
    Pin,
    /// Unpinned.
    Unpin,
    /// Its messages notify nothing.
    Mute,
    /// Its messages notify as before muting.
    Unmute,
}

/// How a chat draws its messages.
#[derive(Clone, Copy, Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum ChatStyle {
    /// In bubbles.
    Bubbles,
    /// As plain rows.
    Plain,
    /// As the app's setting says (`chat_style`).
    Default,
}

/// One of the app's settings an agent may read and change: its name, value and the values it
/// takes.
#[derive(Clone, Debug, PartialEq, Eq, serde::Serialize, schemars::JsonSchema)]
pub struct Setting {
    /// Its name, for `change_setting`.
    pub name: String,
    /// What it is, for the model.
    pub description: String,
    /// Its value now.
    pub value: String,
    /// The values it takes.
    pub choices: Vec<String>,
}

/// A message from the index on this device.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MessageHit {
    /// Its event.
    pub id: String,
    /// Its room.
    pub room: String,
    /// Its sender's name.
    pub sender: String,
    /// Its text (around the found words, for a search).
    pub text: String,
    /// When it was sent.
    pub sent_at: SystemTime,
    /// The user sent it.
    pub mine: bool,
}

/// What the user did with a message an agent asked to send.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SendOutcome {
    /// Sent, as it was or as the user edited it.
    Sent,
    /// Not sent.
    Cancelled,
}

/// One call, for the activity log: what was touched, never the messages' text.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LogEntry {
    /// The session's client.
    pub client: String,
    /// The tool.
    pub tool: String,
    /// The chats it touched, by id.
    pub chats: Vec<String>,
    /// How many messages it gave back.
    pub messages: u32,
    /// Whether it was refused, and why.
    pub refused: Option<String>,
}

/// Why the account could not answer.
#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
#[error("{reason}")]
pub struct BackendError {
    /// For the agent.
    pub reason: String,
}

/// The account as the tools reach it: in the app, its chats and its index on this device.
pub trait AgentBackend: Send + Sync + 'static {
    /// The chats kept from AI, by chat id or room: the user's, on every device. An error when
    /// they cannot be known: no chat is shown then.
    fn hidden(&self) -> impl Future<Output = Result<HashSet<String>, BackendError>> + Send;

    /// Every chat, as the list has them.
    fn chats(&self) -> impl Future<Output = Result<Vec<ChatSummary>, BackendError>> + Send;

    /// The messages with the words of `query`, or near their meaning, in `rooms` (all when
    /// empty), at most `limit`.
    fn search(
        &self,
        query: String,
        rooms: Vec<String>,
        limit: u32,
    ) -> impl Future<Output = Result<Vec<MessageHit>, BackendError>> + Send;

    /// `room`'s messages before `before` (the newest when none), the oldest first, at most
    /// `limit`.
    fn recent(
        &self,
        room: String,
        before: Option<SystemTime>,
        limit: u32,
    ) -> impl Future<Output = Result<Vec<MessageHit>, BackendError>> + Send;

    /// Puts `text` in the chat's composer, where the user sees it.
    fn show_draft(&self, chat: String, text: String) -> impl Future<Output = Result<(), BackendError>> + Send;

    /// Sends `text` in the chat: the user allowed it (their click on a preview, or a session
    /// that sends on its own).
    fn send(&self, chat: String, text: String) -> impl Future<Output = Result<(), BackendError>> + Send;

    /// Shows `text` to send in the chat, and waits for the user's Send or Cancel.
    fn confirm_send(
        &self,
        chat: String,
        text: String,
        client: String,
    ) -> impl Future<Output = Result<SendOutcome, BackendError>> + Send;

    /// Does `change` to the chat (to each of a merged chat's rooms), as the chat list's menu
    /// does.
    fn organize(&self, chat: String, change: Organize) -> impl Future<Output = Result<(), BackendError>> + Send;

    /// Sets when the chat's messages notify.
    fn set_notifications(
        &self,
        chat: String,
        notifications: Notifications,
    ) -> impl Future<Output = Result<(), BackendError>> + Send;

    /// Sets how the chat draws its messages on this device.
    fn set_chat_style(&self, chat: String, style: ChatStyle) -> impl Future<Output = Result<(), BackendError>> + Send;

    /// The app's settings an agent may read and change, as they are now.
    fn settings(&self) -> impl Future<Output = Result<Vec<Setting>, BackendError>> + Send;

    /// Sets the setting `name` to `value`, one of its choices.
    fn change_setting(&self, name: String, value: String) -> impl Future<Output = Result<(), BackendError>> + Send;

    /// Keeps `entry` in the activity log.
    fn log(&self, entry: LogEntry);
}
