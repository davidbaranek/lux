//! A session over the real socket, with a made-up account and an approver that answers as the
//! test says: approval and its code, the grant's limits, more asked for, chats kept from AI.

#![allow(
    clippy::unwrap_used,
    clippy::indexing_slicing,
    clippy::unused_async_trait_impl,
    reason = "a test's fakes"
)]

use std::collections::HashSet;
use std::path::Path;
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime};

use lux_agent::{
    Agent, AgentBackend, Approval, ApprovalAnswer, Approver, BackendError, ChatSummary, Grant, LogEntry, MessageHit,
    SendOutcome, bind, serve,
};
use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader, Lines};
use tokio::net::UnixStream;
use tokio::net::unix::{OwnedReadHalf, OwnedWriteHalf};

fn at(seconds: u64) -> SystemTime {
    SystemTime::UNIX_EPOCH + Duration::from_secs(1_700_000_000 + seconds)
}

fn chat(id: &str, rooms: &[&str], name: &str, unread: u32, seconds: u64) -> ChatSummary {
    ChatSummary {
        id: id.to_owned(),
        rooms: rooms.iter().map(|room| (*room).to_owned()).collect(),
        name: name.to_owned(),
        network: "WhatsApp".to_owned(),
        is_group: false,
        unread,
        muted: false,
        last_activity: Some(at(seconds)),
    }
}

fn message(id: &str, room: &str, text: &str, seconds: u64) -> MessageHit {
    MessageHit {
        id: id.to_owned(),
        room: room.to_owned(),
        sender: "Mum".to_owned(),
        text: text.to_owned(),
        sent_at: at(seconds),
        mine: false,
    }
}

#[derive(Default)]
struct Account {
    drafts: Mutex<Vec<(String, String)>>,
    log: Mutex<Vec<LogEntry>>,
}

/// The account, shared with the test.
struct Shared(Arc<Account>);

impl AgentBackend for Shared {
    async fn chats(&self) -> Result<Vec<ChatSummary>, BackendError> {
        Ok(vec![
            chat("family", &["!a", "!b"], "Family", 2, 5),
            chat("bank", &["!secret"], "Bank", 1, 9),
            chat("work", &["!w"], "Work", 0, 1),
        ])
    }

    async fn search(&self, _query: String, _rooms: Vec<String>, _limit: u32) -> Result<Vec<MessageHit>, BackendError> {
        Ok(vec![
            message("$s", "!secret", "your code is 1234", 9),
            message("$f", "!a", "dinner at 7", 4),
        ])
    }

    async fn recent(
        &self,
        room: String,
        _before: Option<SystemTime>,
        _limit: u32,
    ) -> Result<Vec<MessageHit>, BackendError> {
        Ok(match room.as_str() {
            "!a" => vec![message("$1", "!a", "first", 1), message("$3", "!a", "third", 3)],
            "!b" => vec![message("$2", "!b", "second\u{202E}", 2)],
            _ => Vec::new(),
        })
    }

    async fn show_draft(&self, chat: String, text: String) -> Result<(), BackendError> {
        self.0.drafts.lock().unwrap().push((chat, text));
        Ok(())
    }

    async fn confirm_send(&self, _chat: String, _text: String, _client: String) -> Result<SendOutcome, BackendError> {
        Ok(SendOutcome::Cancelled)
    }

    fn log(&self, entry: LogEntry) {
        self.0.log.lock().unwrap().push(entry);
    }
}

/// Grants `first` to a new session, and `more` to a request for more.
struct User {
    first: Grant,
    more: Option<Grant>,
    asked: Mutex<Vec<Approval>>,
}

impl Approver for User {
    async fn approve(&self, approval: Approval) -> ApprovalAnswer {
        let more = approval.grant.is_some() && approval.reason.is_some();
        self.asked.lock().unwrap().push(approval);
        match (more, self.more) {
            (false, _) => ApprovalAnswer::Granted(self.first),
            (true, Some(grant)) => ApprovalAnswer::Granted(grant),
            (true, None) => ApprovalAnswer::Refused("No".to_owned()),
        }
    }
}

struct Client {
    lines: Lines<BufReader<OwnedReadHalf>>,
    write: OwnedWriteHalf,
}

impl Client {
    async fn connect(path: &Path) -> Self {
        let (read, write) = UnixStream::connect(path).await.unwrap().into_split();
        Self {
            lines: BufReader::new(read).lines(),
            write,
        }
    }

    async fn send(&mut self, message: Value) -> Value {
        let mut line = serde_json::to_vec(&message).unwrap();
        line.push(b'\n');
        self.write.write_all(&line).await.unwrap();
        self.receive().await
    }

    async fn receive(&mut self) -> Value {
        serde_json::from_str(&self.lines.next_line().await.unwrap().unwrap()).unwrap()
    }

    async fn call(&mut self, id: u64, tool: &str, arguments: Value) -> Value {
        self.send(json!({ "call": { "id": id, "tool": tool, "arguments": arguments } }))
            .await
    }
}

async fn session(
    user: User,
) -> (
    Arc<Account>,
    Arc<User>,
    Client,
    tempfile::TempDir,
    tokio::task::JoinSet<()>,
) {
    let folder = tempfile::tempdir().unwrap();
    let path = folder.path().join("agents.sock");
    let account = Arc::new(Account::default());
    let agent = Arc::new(Agent::new(Shared(Arc::clone(&account))));
    agent.set_hidden(HashSet::from(["!secret".to_owned()]));
    let user = Arc::new(user);
    let mut server = tokio::task::JoinSet::new();
    server.spawn(serve(bind(&path).unwrap(), agent, Arc::clone(&user)));
    let mut client = Client::connect(&path).await;
    let hello = json!({ "hello": { "kind": "mcp", "client": "claude-ai", "command": null, "folder": null } });
    let waiting = client.send(hello).await;
    assert_eq!(waiting["waiting"]["code"].as_str().unwrap().len(), 5);
    assert_eq!(client.receive().await["granted"]["grant"], json!(user.first));
    (account, user, client, folder, server)
}

#[tokio::test]
async fn a_session_reads_what_it_may_and_never_a_hidden_chat() {
    let (account, user, mut client, _folder, server) = session(User {
        first: Grant::Read,
        more: None,
        asked: Mutex::default(),
    })
    .await;
    assert_eq!(user.asked.lock().unwrap()[0].hello.client, "claude-ai");

    let chats = client.call(1, "list_chats", json!({})).await;
    let names: Vec<&str> = chats["result"]["value"]["chats"]
        .as_array()
        .unwrap()
        .iter()
        .map(|chat| chat["name"].as_str().unwrap())
        .collect();
    assert_eq!(names, ["Family", "Work"]);

    let found = client.call(2, "search_messages", json!({ "query": "code" })).await;
    let texts: Vec<&str> = found["result"]["value"]["messages"]
        .as_array()
        .unwrap()
        .iter()
        .map(|message| message["text"].as_str().unwrap())
        .collect();
    assert_eq!(texts, ["dinner at 7"]);

    // a merged chat's rooms together, the oldest first, hidden characters gone.
    let read = client
        .call(3, "read_chat", json!({ "chat_id": "family", "limit": 2 }))
        .await;
    let texts: Vec<&str> = read["result"]["value"]["messages"]
        .as_array()
        .unwrap()
        .iter()
        .map(|message| message["text"].as_str().unwrap())
        .collect();
    assert_eq!(texts, ["second", "third"]);

    let hidden = client.call(4, "read_chat", json!({ "chat_id": "!secret" })).await;
    assert_eq!(hidden["error"]["code"], "not_found");

    let draft = client
        .call(5, "draft_reply", json!({ "chat_id": "family", "text": "On my way" }))
        .await;
    assert_eq!(draft["error"]["code"], "insufficient_grant");
    assert!(account.drafts.lock().unwrap().is_empty());

    let more = client
        .send(json!({ "request_access": { "id": 6, "grant": "drafts", "reason": "to answer Mum" } }))
        .await;
    assert_eq!(more["error"]["code"], "insufficient_grant");

    let log = account.log.lock().unwrap();
    assert_eq!(log.len(), 5);
    assert!(log.iter().all(|entry| entry.client == "claude-ai"));
    assert!(log[4].refused.is_some());
    drop(log);
    drop(server);
}

#[tokio::test]
async fn more_asked_for_and_granted_lets_a_session_draft_and_ask_to_send() {
    let (account, user, mut client, _folder, server) = session(User {
        first: Grant::Read,
        more: Some(Grant::Send),
        asked: Mutex::default(),
    })
    .await;
    let more = client
        .send(json!({ "request_access": { "id": 1, "grant": "send", "reason": "to answer Mum" } }))
        .await;
    assert_eq!(more["result"]["value"]["grant"], "send");
    assert_eq!(user.asked.lock().unwrap()[1].reason.as_deref(), Some("to answer Mum"));

    let draft = client
        .call(2, "draft_reply", json!({ "chat_id": "!b", "text": "On my way" }))
        .await;
    assert_eq!(draft["result"]["value"]["status"], "drafted");
    assert_eq!(
        account.drafts.lock().unwrap()[0],
        ("family".to_owned(), "On my way".to_owned())
    );

    let sent = client
        .call(3, "send_message", json!({ "chat_id": "family", "text": "On my way" }))
        .await;
    assert_eq!(sent["result"]["value"]["status"], "cancelled");
    drop(server);
}
