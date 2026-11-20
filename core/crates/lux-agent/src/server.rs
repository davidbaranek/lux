//! The app's side of the socket: each connection a session the user approves.

use std::future::Future;
use std::path::Path;
use std::sync::Arc;

use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::{UnixListener, UnixStream};
use tokio::task::JoinSet;

use crate::agent::{Agent, Session};
use crate::backend::AgentBackend;
use crate::protocol::{ClientHello, ClientMessage, Grant, ServerMessage};
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
                Err(error) => {
                    tracing::warn!("agent socket: {error}");
                    return;
                }
            },
            // an ended connection's task goes.
            Some(_) = connections.join_next(), if !connections.is_empty() => {}
        }
    }
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
    let mut lines = BufReader::new(read).lines();
    let Some(first) = lines.next_line().await? else {
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
    let grant = match approver.approve(approval).await {
        ApprovalAnswer::Granted(grant) => grant,
        ApprovalAnswer::Refused(reason) => return send(&mut write, &ServerMessage::Refused { reason }).await,
    };
    send(&mut write, &ServerMessage::Granted { grant }).await?;
    let session = Session::new(hello.client.clone(), grant);
    let mut refusals = 0;
    while let Some(line) = lines.next_line().await? {
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
                let approval = Approval {
                    hello: hello.clone(),
                    code: code.clone(),
                    grant: Some(grant),
                    reason: Some(reason),
                };
                match approver.approve(approval).await {
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

async fn send(write: &mut tokio::net::unix::OwnedWriteHalf, message: &ServerMessage) -> std::io::Result<()> {
    let mut line = serde_json::to_vec(message).map_err(std::io::Error::other)?;
    line.push(b'\n');
    write.write_all(&line).await
}
