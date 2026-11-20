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
    /// The chats kept from AI, by chat id or room: the user's, on every device.
    fn hidden(&self) -> impl Future<Output = HashSet<String>> + Send;

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

    /// Keeps `entry` in the activity log.
    fn log(&self, entry: LogEntry);
}
