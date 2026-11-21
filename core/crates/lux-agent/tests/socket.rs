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
    sent: Mutex<Vec<(String, String)>>,
    /// Messages Lux asked the user about (the fake user cancels each).
    asked: Mutex<Vec<(String, String)>>,
    log: Mutex<Vec<LogEntry>>,
}

/// The account, shared with the test.
struct Shared(Arc<Account>);

impl AgentBackend for Shared {
    async fn hidden(&self) -> Result<HashSet<String>, BackendError> {
        Ok(HashSet::from(["!secret".to_owned()]))
    }

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

    async fn send(&self, chat: String, text: String) -> Result<(), BackendError> {
        self.0.sent.lock().unwrap().push((chat, text));
        Ok(())
    }

    async fn confirm_send(&self, chat: String, text: String, _client: String) -> Result<SendOutcome, BackendError> {
        self.0.asked.lock().unwrap().push((chat, text));
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
    /// An approval stopped waiting (its client left).
    dropped: Arc<std::sync::atomic::AtomicBool>,
}

fn user(first: Grant, more: Option<Grant>) -> User {
    User {
        first,
        more,
        asked: Mutex::default(),
        dropped: Arc::default(),
    }
}

/// Notes, when dropped, that the approval stopped waiting.
struct Waiting(Arc<std::sync::atomic::AtomicBool>);

impl Drop for Waiting {
    fn drop(&mut self) {
        self.0.store(true, std::sync::atomic::Ordering::SeqCst);
    }
}

impl Approver for User {
    async fn approve(&self, approval: Approval) -> ApprovalAnswer {
        if approval.hello.client == "never answered" {
            let _waiting = Waiting(Arc::clone(&self.dropped));
            std::future::pending::<()>().await;
        }
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

/// The app's side, serving a made-up account to the approvals of `user`.
struct App {
    account: Arc<Account>,
    user: Arc<User>,
    path: std::path::PathBuf,
    _folder: tempfile::TempDir,
    _server: tokio::task::JoinSet<()>,
}

impl App {
    fn new(user: User) -> Self {
        let folder = tempfile::tempdir().unwrap();
        let path = folder.path().join("agents.sock");
        let account = Arc::new(Account::default());
        let agent = Arc::new(Agent::new(Shared(Arc::clone(&account))));
        let user = Arc::new(user);
        let mut server = tokio::task::JoinSet::new();
        server.spawn(serve(bind(&path).unwrap(), agent, Arc::clone(&user)));
        Self {
            account,
            user,
            path,
            _folder: folder,
            _server: server,
        }
    }

    /// A session of `client`, approved; `previews` when it draws MCP Apps.
    async fn connect(&self, client: &str, previews: bool) -> Client {
        let mut connection = Client::connect(&self.path).await;
        let hello = json!({ "hello": { "kind": "mcp", "client": client, "command": null, "folder": null, "previews": previews } });
        let waiting = connection.send(hello).await;
        assert_eq!(waiting["waiting"]["code"].as_str().unwrap().len(), 5);
        assert_eq!(connection.receive().await["granted"]["grant"], json!(self.user.first));
        connection
    }
}

async fn session(user: User) -> (Arc<Account>, Arc<User>, Client, App) {
    let app = App::new(user);
    let client = app.connect("claude-ai", false).await;
    (Arc::clone(&app.account), Arc::clone(&app.user), client, app)
}

#[tokio::test]
async fn a_session_reads_what_it_may_and_never_a_hidden_chat() {
    let (account, user, mut client, app) = session(user(Grant::Read, None)).await;
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
    drop(app);
}

#[tokio::test]
async fn more_asked_for_and_granted_lets_a_session_draft_and_ask_to_send() {
    let (account, user, mut client, app) = session(user(Grant::Read, Some(Grant::Send))).await;
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
    drop(app);
}

#[tokio::test]
async fn a_session_that_sends_on_its_own_does_so_only_in_a_chat_it_read() {
    let (account, _user, mut client, app) = session(user(Grant::AutoSend, None)).await;
    // not read yet: asked in Lux (the fake user cancels).
    let asked = client
        .call(1, "send_message", json!({ "chat_id": "family", "text": "Hi" }))
        .await;
    assert_eq!(asked["result"]["value"]["status"], "cancelled");
    assert!(account.sent.lock().unwrap().is_empty());

    client.call(2, "read_chat", json!({ "chat_id": "family" })).await;
    let sent = client
        .call(3, "send_message", json!({ "chat_id": "family", "text": "Hi" }))
        .await;
    assert_eq!(sent["result"]["value"]["status"], "sent");
    assert_eq!(account.sent.lock().unwrap()[0], ("family".to_owned(), "Hi".to_owned()));
    drop(app);
}

#[tokio::test]
async fn a_preview_is_only_for_a_session_that_shows_one() {
    let app = App::new(user(Grant::AutoSend, None));
    let mut client = app.connect("claude-ai", false).await;
    let prepared = client
        .call(1, "prepare_send", json!({ "chat_id": "work", "text": "Done" }))
        .await;
    assert_eq!(prepared["error"]["code"], "invalid_arguments");
    let confirmed = client.call(2, "confirm_send", json!({ "token": "0".repeat(32) })).await;
    assert_eq!(confirmed["error"]["code"], "invalid_arguments");
    assert!(app.account.sent.lock().unwrap().is_empty());
}

#[tokio::test]
async fn a_previews_token_is_no_click_lux_asks_a_session_that_may_not_send_on_its_own() {
    let app = App::new(user(Grant::Send, None));
    let mut client = app.connect("claude-ai", true).await;
    let prepared = client
        .call(1, "prepare_send", json!({ "chat_id": "work", "text": "Done" }))
        .await;
    assert_eq!(prepared["result"]["value"]["status"], "awaiting_user");
    assert_eq!(prepared["result"]["value"]["chat"], "Work");
    let token = prepared["result"]["value"]["token"].as_str().unwrap().to_owned();
    assert_eq!(token.len(), 32);

    let wrong = client.call(2, "confirm_send", json!({ "token": "nope" })).await;
    assert_eq!(wrong["error"]["code"], "not_found");
    // the agent itself confirms with the token it read: Lux asks, the user cancels.
    let confirmed = client.call(3, "confirm_send", json!({ "token": token })).await;
    assert_eq!(confirmed["result"]["value"]["status"], "cancelled");
    assert!(app.account.sent.lock().unwrap().is_empty());
    assert_eq!(
        app.account.asked.lock().unwrap()[0],
        ("work".to_owned(), "Done".to_owned())
    );
    let again = client.call(4, "confirm_send", json!({ "token": token })).await;
    assert_eq!(again["error"]["code"], "not_found");
}

#[tokio::test]
async fn a_previews_send_counts_against_the_hours_limits() {
    let app = App::new(user(Grant::AutoSend, None));
    let mut client = app.connect("claude-ai", true).await;
    let mut statuses = Vec::new();
    for id in 0..4 {
        let prepared = client
            .call(id * 2, "prepare_send", json!({ "chat_id": "work", "text": "Done" }))
            .await;
        let token = prepared["result"]["value"]["token"].as_str().unwrap().to_owned();
        let confirmed = client.call(id * 2 + 1, "confirm_send", json!({ "token": token })).await;
        statuses.push(confirmed["result"]["value"]["status"].as_str().unwrap().to_owned());
    }
    // three in a chat an hour without asking; the fourth is asked in Lux.
    assert_eq!(statuses, ["sent", "sent", "sent", "cancelled"]);
    assert_eq!(app.account.sent.lock().unwrap().len(), 3);
}

#[tokio::test]
async fn the_limits_and_the_chats_read_are_the_clients_across_its_sessions() {
    let app = App::new(user(Grant::AutoSend, None));
    let mut first = app.connect("claude-ai", false).await;
    first.call(1, "read_chat", json!({ "chat_id": "family" })).await;
    drop(first);

    // a new session of the same client (a CLI command, or Lux restarted) still read the chat.
    let mut second = app.connect("claude-ai", false).await;
    let sent = second
        .call(1, "send_message", json!({ "chat_id": "family", "text": "Hi" }))
        .await;
    assert_eq!(sent["result"]["value"]["status"], "sent");
    for id in 2..4 {
        second
            .call(id, "send_message", json!({ "chat_id": "family", "text": "Hi" }))
            .await;
    }
    drop(second);

    // the chat's three an hour are spent, whichever session asks.
    let mut third = app.connect("claude-ai", false).await;
    let asked = third
        .call(1, "send_message", json!({ "chat_id": "family", "text": "Hi" }))
        .await;
    assert_eq!(asked["result"]["value"]["status"], "cancelled");
    assert_eq!(app.account.sent.lock().unwrap().len(), 3);

    // another client read nothing.
    let mut other = app.connect("codex", false).await;
    let asked = other
        .call(1, "send_message", json!({ "chat_id": "family", "text": "Hi" }))
        .await;
    assert_eq!(asked["result"]["value"]["status"], "cancelled");
}

#[tokio::test]
async fn calls_a_minute_are_the_clients_across_its_sessions() {
    let app = App::new(user(Grant::Read, None));
    let mut first = app.connect("claude-ai", false).await;
    for id in 0..60 {
        let chats = first.call(id, "list_chats", json!({})).await;
        assert!(chats["result"].is_object());
    }
    drop(first);
    let mut second = app.connect("claude-ai", false).await;
    let refused = second.call(1, "list_chats", json!({})).await;
    assert_eq!(refused["error"]["code"], "rate_limited");
}

#[tokio::test]
async fn a_text_longer_than_a_message_is_refused() {
    let app = App::new(user(Grant::Drafts, None));
    let mut client = app.connect("claude-ai", false).await;
    let long = "a".repeat(10_001);
    let draft = client
        .call(1, "draft_reply", json!({ "chat_id": "work", "text": long }))
        .await;
    assert_eq!(draft["error"]["code"], "invalid_arguments");
    let query = client
        .call(2, "search_messages", json!({ "query": "a".repeat(1_001) }))
        .await;
    assert_eq!(query["error"]["code"], "invalid_arguments");
    assert!(app.account.drafts.lock().unwrap().is_empty());
}

#[tokio::test]
async fn a_line_longer_than_the_most_ends_the_connection_unread() {
    let app = App::new(user(Grant::Read, None));
    let mut client = Client::connect(&app.path).await;
    // a quarter of a megabyte and more, with no newline: the app stops reading and closes.
    let chunk = vec![b'a'; 64 * 1024];
    for _ in 0..5 {
        if client.write.write_all(&chunk).await.is_err() {
            break;
        }
    }
    let closed = tokio::time::timeout(Duration::from_secs(5), client.lines.next_line()).await;
    assert!(matches!(closed, Ok(Ok(None) | Err(_))));
    assert!(app.user.asked.lock().unwrap().is_empty());
}

#[tokio::test]
async fn an_approval_stops_waiting_when_its_client_leaves() {
    let app = App::new(user(Grant::Read, None));
    let mut client = Client::connect(&app.path).await;
    let hello = json!({ "hello": { "kind": "mcp", "client": "never answered", "command": null, "folder": null } });
    let waiting = client.send(hello).await;
    assert!(waiting["waiting"].is_object());
    drop(client);
    for _ in 0..50 {
        if app.user.dropped.load(std::sync::atomic::Ordering::SeqCst) {
            return;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    panic!("the approval still waits for a client that left");
}
