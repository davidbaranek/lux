//! The policy every call goes through, then the tool.

use std::collections::{HashMap, HashSet, VecDeque};
use std::sync::Mutex;
use std::time::{Duration, Instant, SystemTime};

use serde::de::DeserializeOwned;
use serde_json::Value;

use crate::backend::{AgentBackend, ChatSummary, LogEntry, MessageHit, SendOutcome};
use crate::protocol::Grant;
use crate::text::plain;
use crate::tools::{
    ChatOut, Chats, Compose, Confirm, ListChats, MessageOut, Messages, Prepared, ReadChat, SearchMessages, Status,
    ToolError, ToolErrorCode, tools,
};

/// Calls a session may make in a minute.
const CALLS_PER_MINUTE: usize = 60;

/// Messages a session that sends on its own may send in an hour; more are asked.
const SENT_PER_HOUR: usize = 10;

/// How long a preview's Send stays good.
const PREPARED_FOR: Duration = Duration::from_mins(10);

/// A message waiting for the preview's Send.
struct Pending {
    chat: String,
    text: String,
    at: Instant,
}

/// An approved connection: who, and what it may do.
pub struct Session {
    /// The client, as the approval showed it.
    pub client: String,
    grant: Mutex<Grant>,
    calls: Mutex<VecDeque<Instant>>,
    /// The chats it read (`read_chat`): the only ones it may send in on its own.
    read: Mutex<HashSet<String>>,
    /// When it sent on its own, the last hour's.
    sent: Mutex<VecDeque<Instant>>,
    /// Messages waiting for the preview's Send, by token.
    pending: Mutex<HashMap<String, Pending>>,
}

impl Session {
    /// `client`'s session, granted `grant`.
    #[must_use]
    pub fn new(client: String, grant: Grant) -> Self {
        Self {
            client,
            grant: Mutex::new(grant),
            calls: Mutex::new(VecDeque::new()),
            read: Mutex::new(HashSet::new()),
            sent: Mutex::new(VecDeque::new()),
            pending: Mutex::new(HashMap::new()),
        }
    }

    /// Whether it may send in `chat` on its own now, and counts it if so: allowed to, the chat
    /// read in this session, and fewer than [`SENT_PER_HOUR`] in the last hour.
    fn take_auto_send(&self, chat: &str) -> bool {
        if self.grant() < Grant::AutoSend || !self.read.lock().is_ok_and(|read| read.contains(chat)) {
            return false;
        }
        let Ok(mut sent) = self.sent.lock() else { return false };
        let now = Instant::now();
        while sent
            .front()
            .is_some_and(|&at| now.duration_since(at) > Duration::from_secs(3600))
        {
            sent.pop_front();
        }
        if sent.len() >= SENT_PER_HOUR {
            return false;
        }
        sent.push_back(now);
        true
    }

    /// What it may do now.
    #[must_use]
    pub fn grant(&self) -> Grant {
        self.grant.lock().map_or(Grant::Read, |grant| *grant)
    }

    /// What it may do from now on (the user approved more, or less).
    pub fn set_grant(&self, grant: Grant) {
        if let Ok(mut current) = self.grant.lock() {
            *current = grant;
        }
    }

    /// Whether one more call fits in the last minute's.
    fn take_call(&self) -> bool {
        let Ok(mut calls) = self.calls.lock() else { return false };
        let now = Instant::now();
        while calls
            .front()
            .is_some_and(|&call| now.duration_since(call) > Duration::from_secs(60))
        {
            calls.pop_front();
        }
        if calls.len() >= CALLS_PER_MINUTE {
            return false;
        }
        calls.push_back(now);
        true
    }
}

/// The tools over the account, with the policy every call goes through.
/// The chats kept from AI are as if they were not there: the backend says which, on each call.
pub struct Agent<B> {
    backend: B,
}

impl<B: AgentBackend> Agent<B> {
    /// The tools over `backend`.
    pub fn new(backend: B) -> Self {
        Self { backend }
    }

    /// `tool`'s answer to `arguments` for `session`: refused over the session's grant or its
    /// calls a minute; the chats kept from AI not there; every call logged.
    ///
    /// # Errors
    /// Why the call failed.
    pub async fn call(&self, session: &Session, tool: &str, arguments: Value) -> Result<Value, ToolError> {
        let mut entry = LogEntry {
            client: session.client.clone(),
            tool: tool.to_owned(),
            chats: Vec::new(),
            messages: 0,
            refused: None,
        };
        let result = self.run(session, tool, arguments, &mut entry).await;
        if let Err(error) = &result {
            entry.refused = Some(error.message.clone());
        }
        self.backend.log(entry);
        result
    }

    async fn run(
        &self,
        session: &Session,
        tool: &str,
        arguments: Value,
        entry: &mut LogEntry,
    ) -> Result<Value, ToolError> {
        // the MCP front's own two, for its preview: asking to send.
        let grant = match tool {
            "prepare_send" | "confirm_send" => Grant::Send,
            tool => {
                tools()
                    .into_iter()
                    .find(|spec| spec.name == tool)
                    .ok_or_else(|| ToolError::new(ToolErrorCode::InvalidArguments, format!("no tool `{tool}`")))?
                    .grant
            }
        };
        if session.grant() < grant {
            return Err(ToolError::new(
                ToolErrorCode::InsufficientGrant,
                format!(
                    "this session may not {}: call request_access to ask the user",
                    tool.replace('_', " ")
                ),
            ));
        }
        if !session.take_call() {
            return Err(ToolError::new(
                ToolErrorCode::RateLimited,
                "too many calls: wait a minute",
            ));
        }
        let value = match tool {
            "list_chats" => serde_json::to_value(self.list_chats(parse(arguments)?).await?),
            "search_messages" => {
                let messages = self.search(parse(arguments)?, entry).await?;
                serde_json::to_value(messages)
            }
            "read_chat" => serde_json::to_value(self.read(session, parse(arguments)?, entry).await?),
            "draft_reply" => {
                let compose: Compose = parse(arguments)?;
                let chat = self.chat(&compose.chat_id).await?;
                entry.chats.push(chat.id.clone());
                self.backend.show_draft(chat.id, compose.text).await.map_err(failed)?;
                serde_json::to_value(Status { status: "drafted" })
            }
            "send_message" => serde_json::to_value(self.send_message(session, parse(arguments)?, entry).await?),
            "prepare_send" => serde_json::to_value(self.prepare_send(session, parse(arguments)?, entry).await?),
            "confirm_send" => serde_json::to_value(self.confirm_send(session, parse(arguments)?, entry).await?),
            _ => {
                return Err(ToolError::new(
                    ToolErrorCode::InvalidArguments,
                    format!("no tool `{tool}`"),
                ));
            }
        };
        value.map_err(|error| ToolError::new(ToolErrorCode::Failed, error.to_string()))
    }

    /// Sends on its own where the session may, else asks the user in Lux.
    async fn send_message(
        &self,
        session: &Session,
        compose: Compose,
        entry: &mut LogEntry,
    ) -> Result<Status, ToolError> {
        let chat = self.chat(&compose.chat_id).await?;
        entry.chats.push(chat.id.clone());
        if session.take_auto_send(&chat.id) {
            self.backend.send(chat.id, compose.text).await.map_err(failed)?;
            return Ok(Status { status: "sent" });
        }
        let outcome = self
            .backend
            .confirm_send(chat.id, compose.text, session.client.clone())
            .await
            .map_err(failed)?;
        Ok(Status {
            status: match outcome {
                SendOutcome::Sent => "sent",
                SendOutcome::Cancelled => "cancelled",
            },
        })
    }

    /// The MCP preview's message: sent on its own where the session may, else kept for the
    /// preview's Send, with a one-time token.
    async fn prepare_send(
        &self,
        session: &Session,
        compose: Compose,
        entry: &mut LogEntry,
    ) -> Result<Prepared, ToolError> {
        let chat = self.chat(&compose.chat_id).await?;
        entry.chats.push(chat.id.clone());
        if session.take_auto_send(&chat.id) {
            self.backend.send(chat.id, compose.text.clone()).await.map_err(failed)?;
            return Ok(Prepared {
                status: "sent",
                token: None,
                chat: chat.name,
                text: compose.text,
            });
        }
        let token = crate::server::token();
        if token.is_empty() {
            return Err(ToolError::new(ToolErrorCode::Failed, "no token could be made"));
        }
        if let Ok(mut pending) = session.pending.lock() {
            pending.retain(|_, waiting| waiting.at.elapsed() < PREPARED_FOR);
            pending.insert(
                token.clone(),
                Pending {
                    chat: chat.id,
                    text: compose.text.clone(),
                    at: Instant::now(),
                },
            );
        }
        Ok(Prepared {
            status: "awaiting_user",
            token: Some(token),
            chat: chat.name,
            text: compose.text,
        })
    }

    /// The preview's Send: its message, once, while it is good.
    async fn confirm_send(
        &self,
        session: &Session,
        confirm: Confirm,
        entry: &mut LogEntry,
    ) -> Result<Status, ToolError> {
        let waiting = session
            .pending
            .lock()
            .ok()
            .and_then(|mut pending| pending.remove(&confirm.token));
        let waiting = waiting
            .filter(|waiting| waiting.at.elapsed() < PREPARED_FOR)
            .ok_or_else(|| ToolError::new(ToolErrorCode::NotFound, "this message is no longer waiting to be sent"))?;
        entry.chats.push(waiting.chat.clone());
        self.backend.send(waiting.chat, waiting.text).await.map_err(failed)?;
        Ok(Status { status: "sent" })
    }

    /// The chats AI may see.
    async fn chats(&self) -> Result<Vec<ChatSummary>, ToolError> {
        let hidden = self.backend.hidden().await;
        let chats = self.backend.chats().await.map_err(unavailable)?;
        Ok(chats
            .into_iter()
            .filter(|chat| !hidden.contains(&chat.id) && !chat.rooms.iter().any(|room| hidden.contains(room)))
            .collect())
    }

    /// The chat of `id` (a chat's id or one of its rooms), unless it is hidden.
    async fn chat(&self, id: &str) -> Result<ChatSummary, ToolError> {
        self.chats()
            .await?
            .into_iter()
            .find(|chat| chat.id == id || chat.rooms.iter().any(|room| room == id))
            .ok_or_else(|| ToolError::new(ToolErrorCode::NotFound, format!("no chat `{id}`")))
    }

    async fn list_chats(&self, list: ListChats) -> Result<Chats, ToolError> {
        let mut chats = self.chats().await?;
        chats.retain(|chat| {
            (!list.unread_only || chat.unread > 0)
                && list
                    .network
                    .as_ref()
                    .is_none_or(|network| chat.network.eq_ignore_ascii_case(network))
        });
        chats.sort_by_key(|chat| std::cmp::Reverse(chat.last_activity));
        chats.truncate(limit(list.limit, 30, 100));
        Ok(Chats {
            chats: chats.into_iter().map(chat_out).collect(),
        })
    }

    async fn search(&self, search: SearchMessages, entry: &mut LogEntry) -> Result<Messages, ToolError> {
        let chats = self.chats().await?;
        let rooms = match &search.chat_id {
            Some(id) => self.chat(id).await?.rooms,
            None => Vec::new(),
        };
        let limit = limit(search.limit, 20, 50);
        // the hidden chats' messages are left out after the search: ask for more to give `limit`.
        let hits = self
            .backend
            .search(search.query, rooms, u32::try_from(limit * 2).unwrap_or(u32::MAX))
            .await
            .map_err(unavailable)?;
        let messages: Vec<MessageOut> = hits
            .into_iter()
            .filter_map(|hit| message_out(hit, &chats))
            .take(limit)
            .collect();
        entry.messages = u32::try_from(messages.len()).unwrap_or(u32::MAX);
        entry.chats = messages
            .iter()
            .map(|message| message.chat_id.clone())
            .collect::<HashSet<_>>()
            .into_iter()
            .collect();
        Ok(Messages { messages })
    }

    async fn read(&self, session: &Session, read: ReadChat, entry: &mut LogEntry) -> Result<Messages, ToolError> {
        let chat = self.chat(&read.chat_id).await?;
        let before = read
            .before
            .map(|before| {
                before
                    .parse::<jiff::Timestamp>()
                    .map(SystemTime::from)
                    .map_err(|error| ToolError::new(ToolErrorCode::InvalidArguments, format!("`before`: {error}")))
            })
            .transpose()?;
        let limit = limit(read.limit, 30, 100);
        let wanted = u32::try_from(limit).unwrap_or(u32::MAX);
        let mut hits = Vec::new();
        for room in &chat.rooms {
            hits.extend(
                self.backend
                    .recent(room.clone(), before, wanted)
                    .await
                    .map_err(unavailable)?,
            );
        }
        // a merged chat's rooms together, the newest `limit`, the oldest first.
        hits.sort_by_key(|hit| hit.sent_at);
        let start = hits.len().saturating_sub(limit);
        let chats = [chat];
        let messages: Vec<MessageOut> = hits
            .into_iter()
            .skip(start)
            .filter_map(|hit| message_out(hit, &chats))
            .collect();
        entry.chats = chats.iter().map(|chat| chat.id.clone()).collect();
        if let Ok(mut read) = session.read.lock() {
            read.extend(entry.chats.iter().cloned());
        }
        entry.messages = u32::try_from(messages.len()).unwrap_or(u32::MAX);
        Ok(Messages { messages })
    }
}

fn parse<T: DeserializeOwned>(arguments: Value) -> Result<T, ToolError> {
    let arguments = if arguments.is_null() {
        Value::Object(serde_json::Map::new())
    } else {
        arguments
    };
    serde_json::from_value(arguments)
        .map_err(|error| ToolError::new(ToolErrorCode::InvalidArguments, error.to_string()))
}

fn limit(asked: Option<u32>, default: usize, most: usize) -> usize {
    asked
        .map_or(default, |asked| usize::try_from(asked).unwrap_or(most))
        .clamp(1, most)
}

fn unavailable(error: crate::backend::BackendError) -> ToolError {
    ToolError::new(ToolErrorCode::Unavailable, error.reason)
}

fn failed(error: crate::backend::BackendError) -> ToolError {
    ToolError::new(ToolErrorCode::Failed, error.reason)
}

fn time(at: SystemTime) -> String {
    jiff::Timestamp::try_from(at)
        .map(|at| at.to_string())
        .unwrap_or_default()
}

fn chat_out(chat: ChatSummary) -> ChatOut {
    ChatOut {
        chat_id: chat.id,
        name: plain(&chat.name),
        network: chat.network,
        is_group: chat.is_group,
        unread: chat.unread,
        muted: chat.muted,
        last_activity: chat.last_activity.map(time),
    }
}

/// `hit` as the tools give it, with its chat; none when its chat is not among `chats` (hidden).
fn message_out(hit: MessageHit, chats: &[ChatSummary]) -> Option<MessageOut> {
    let chat = chats.iter().find(|chat| chat.rooms.contains(&hit.room))?;
    Some(MessageOut {
        message_id: hit.id,
        chat_id: chat.id.clone(),
        chat: plain(&chat.name),
        sender: plain(&hit.sender),
        text: plain(&hit.text),
        sent_at: time(hit.sent_at),
        mine: hit.mine,
    })
}
