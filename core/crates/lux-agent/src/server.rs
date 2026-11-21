//! The app's side of the socket: each connection a session the user approves.

use std::future::Future;
use std::path::Path;
use std::sync::Arc;

use tokio::io::{AsyncBufRead, AsyncWriteExt, BufReader};
use tokio::net::{UnixListener, UnixStream};
use tokio::task::JoinSet;

use crate::agent::{Agent, Session, check_lengths};
use crate::backend::AgentBackend;
use crate::protocol::{ClientHello, ClientMessage, Grant, ServerMessage, read_line};
use crate::tools::{GrantOut, ToolErrorCode};

/// A request for the user's approval, as the dialog shows it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Approval {
    /// Who asks, as the client says.
    pub hello: ClientHello,
    /// The match code the client shows too.
    pub code: String,
    /// What it asks for: a new session's command's need, or none (the app's default); a request
    /// for more names what it wants.
    pub grant: Option<Grant>,
    /// Why, for a request for more, in the agent's words.
    pub reason: Option<String>,
}

/// The user's answer.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ApprovalAnswer {
    /// Approved, with what the session may do.
    Granted(Grant),
    /// Refused, with why, in the user's words.
    Refused(String),
}

/// Asks the user, in the app: the dialog with the match code. An answer may come at once (a
/// client the user approved for always, AI off).
pub trait Approver: Send + Sync + 'static {
    /// The user's answer to `approval`.
    fn approve(&self, approval: Approval) -> impl Future<Output = ApprovalAnswer> + Send;
}

/// The socket at `path`, made anew (a stale file from before is replaced).
///
/// # Errors
/// When the socket cannot be made.
pub fn bind(path: &Path) -> std::io::Result<UnixListener> {
    if path.exists() {
        std::fs::remove_file(path)?;
    }
    UnixListener::bind(path)
}

/// Serves `agent` on `listener` until the future is dropped, with every connection: each says
/// who it is, waits for the user's approval through `approver`, then calls tools.
pub async fn serve<B: AgentBackend, A: Approver>(listener: UnixListener, agent: Arc<Agent<B>>, approver: Arc<A>) {
    let mut connections = JoinSet::new();
    loop {
        tokio::select! {
            accepted = listener.accept() => match accepted {
                Ok((stream, _)) => {
                    let agent = Arc::clone(&agent);
                    let approver = Arc::clone(&approver);
                    connections.spawn(async move {
                        if let Err(error) = connection(stream, &agent, &*approver).await {
                            tracing::debug!("agent connection ended: {error}");
                        }
                    });
                }
                // one connection failed (too many files open, say): the socket goes on.
                Err(error) => {
                    tracing::warn!("agent socket: {error}");
                    tokio::time::sleep(std::time::Duration::from_millis(100)).await;
                }
            },
            // an ended connection's task goes.
            Some(_) = connections.join_next(), if !connections.is_empty() => {}
        }
    }
}

/// A one-time token: 16 random bytes in hex.
pub(crate) fn token() -> String {
    let mut bytes = [0_u8; 16];
    if getrandom::fill(&mut bytes).is_err() {
        // no randomness: a token nobody can guess is none at all.
        return String::new();
    }
    bytes
        .iter()
        .flat_map(|byte| [byte >> 4, byte & 0x0f])
        .filter_map(|nibble| char::from_digit(u32::from(nibble), 16))
        .collect()
}

/// A four-character match code from a set without look-alikes (no 0/O, 1/I), as `K7-Q2`.
fn code() -> String {
    const LETTERS: &[u8] = b"ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
    let mut bytes = [0_u8; 4];
    if getrandom::fill(&mut bytes).is_err() {
        bytes = [7, 11, 13, 17];
    }
    let pick = |byte: u8| char::from(LETTERS.get(usize::from(byte) % LETTERS.len()).copied().unwrap_or(b'X'));
    format!(
        "{}{}-{}{}",
        pick(bytes[0]),
        pick(bytes[1]),
        pick(bytes[2]),
        pick(bytes[3])
    )
}

async fn connection<B: AgentBackend, A: Approver>(
    stream: UnixStream,
    agent: &Agent<B>,
    approver: &A,
) -> std::io::Result<()> {
    let (read, mut write) = stream.into_split();
    let mut lines = BufReader::new(read);
    let Some(first) = read_line(&mut lines).await? else {
        return Ok(());
    };
    let Ok(ClientMessage::Hello(hello)) = serde_json::from_str(&first) else {
        return send(
            &mut write,
            &ServerMessage::Refused {
                reason: "a session starts with hello".to_owned(),
            },
        )
        .await;
    };
    let code = code();
    send(&mut write, &ServerMessage::Waiting { code: code.clone() }).await?;
    let approval = Approval {
        hello: hello.clone(),
        code: code.clone(),
        grant: hello.wants,
        reason: None,
    };
    let grant = match while_open(approver.approve(approval), &mut lines).await {
        Some(ApprovalAnswer::Granted(grant)) => grant,
        Some(ApprovalAnswer::Refused(reason)) => return send(&mut write, &ServerMessage::Refused { reason }).await,
        None => return Ok(()),
    };
    send(&mut write, &ServerMessage::Granted { grant }).await?;
    let session = Session::new(hello.client.clone(), grant, hello.previews);
    let mut refusals = 0;
    while let Some(line) = read_line(&mut lines).await? {
        let answer = match serde_json::from_str::<ClientMessage>(&line) {
            Ok(ClientMessage::Call { id, tool, arguments }) => match agent.call(&session, &tool, arguments).await {
                Ok(value) => ServerMessage::Result { id, value },
                Err(error) => ServerMessage::Error {
                    id,
                    code: error.code,
                    message: error.message,
                },
            },
            Ok(ClientMessage::RequestAccess { id, grant, reason }) => {
                // asked again and again: the session ends.
                if refusals >= 3 {
                    return send(
                        &mut write,
                        &ServerMessage::Refused {
                            reason: "refused three times".to_owned(),
                        },
                    )
                    .await;
                }
                if let Err(error) = check_lengths(&serde_json::json!({ "reason": reason })) {
                    send(
                        &mut write,
                        &ServerMessage::Error {
                            id,
                            code: error.code,
                            message: error.message,
                        },
                    )
                    .await?;
                    continue;
                }
                let approval = Approval {
                    hello: hello.clone(),
                    code: code.clone(),
                    grant: Some(grant),
                    reason: Some(reason),
                };
                let Some(answer) = while_open(approver.approve(approval), &mut lines).await else {
                    return Ok(());
                };
                match answer {
                    ApprovalAnswer::Granted(grant) => {
                        session.set_grant(grant);
                        ServerMessage::Result {
                            id,
                            value: serde_json::to_value(GrantOut { grant }).unwrap_or_default(),
                        }
                    }
                    ApprovalAnswer::Refused(message) => {
                        refusals += 1;
                        ServerMessage::Error {
                            id,
                            code: ToolErrorCode::InsufficientGrant,
                            message,
                        }
                    }
                }
            }
            Ok(ClientMessage::Hello(_)) | Err(_) => ServerMessage::Error {
                id: 0,
                code: ToolErrorCode::InvalidArguments,
                message: "not a call".to_owned(),
            },
        };
        send(&mut write, &answer).await?;
    }
    Ok(())
}

/// `approval`'s answer, or none when the client goes first: the approval stops waiting.
async fn while_open<R: AsyncBufRead + Unpin>(
    approval: impl Future<Output = ApprovalAnswer>,
    lines: &mut R,
) -> Option<ApprovalAnswer> {
    tokio::select! {
        answer = approval => Some(answer),
        () = gone(lines) => None,
    }
}

/// Returns when the client closes the connection: nothing it says while it waits is a call.
async fn gone<R: AsyncBufRead + Unpin>(lines: &mut R) {
    while let Ok(Some(_)) = read_line(lines).await {}
}

async fn send(write: &mut tokio::net::unix::OwnedWriteHalf, message: &ServerMessage) -> std::io::Result<()> {
    let mut line = serde_json::to_vec(message).map_err(std::io::Error::other)?;
    line.push(b'\n');
    write.write_all(&line).await
}
