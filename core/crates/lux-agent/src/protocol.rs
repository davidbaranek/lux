//! The socket's messages: one JSON object a line, each way.

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// What a session may do, each more than the one before.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum Grant {
    /// List chats, search and read messages.
    Read,
    /// Also put a draft in a chat's composer, where the user sees it.
    Drafts,
    /// Also ask to send a message; each one waits for the user's click (in Lux, or on the MCP
    /// client's preview).
    Send,
    /// Also send on its own: only in a chat it read in this session, at most a few an hour; any
    /// other message is asked as with `Send`.
    AutoSend,
}

/// How the client reaches the tools.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ClientKind {
    /// `lux <command>`, from a shell: an agent's, a script's or the user's.
    Cli,
    /// `lux mcp`: an MCP client (Claude, Codex, Cursor) over stdio.
    Mcp,
}

/// Who asks, as the client says: shown in the approval, never trusted as identity (the match
/// code is what ties the dialog to the request).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ClientHello {
    /// How it reaches the tools.
    pub kind: ClientKind,
    /// Its name: an MCP client's own (`claude-ai`), or the program that ran `lux`.
    pub client: String,
    /// The command line, for the CLI.
    pub command: Option<String>,
    /// The folder it runs in.
    pub folder: Option<String>,
    /// What its command needs (`lux draft`: drafts), so the approval offers it.
    #[serde(default)]
    pub wants: Option<Grant>,
}

/// The longest line either side reads: a message's text and its JSON fit many times over; more
/// ends the session.
pub(crate) const MAX_LINE: usize = 256 * 1024;

/// Reads one line of at most [`MAX_LINE`] bytes, without its newline; none at the end.
///
/// # Errors
/// When reading fails, or the line is longer.
pub(crate) async fn read_line<R: tokio::io::AsyncBufRead + Unpin>(reader: &mut R) -> std::io::Result<Option<String>> {
    use tokio::io::{AsyncBufReadExt, AsyncReadExt};
    let mut line = Vec::new();
    let limit = u64::try_from(MAX_LINE).unwrap_or(u64::MAX).saturating_add(1);
    let read = (&mut *reader).take(limit).read_until(b'\n', &mut line).await?;
    if read == 0 {
        return Ok(None);
    }
    if line.last() == Some(&b'\n') {
        line.pop();
    } else if line.len() > MAX_LINE {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "a line is too long",
        ));
    }
    String::from_utf8(line)
        .map(Some)
        .map_err(|error| std::io::Error::new(std::io::ErrorKind::InvalidData, error))
}

/// From the client.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum ClientMessage {
    /// The first message: who asks.
    Hello(ClientHello),
    /// A tool's call.
    Call {
        /// Matches its answer.
        id: u64,
        /// The tool's name.
        tool: String,
        /// Its arguments.
        arguments: Value,
    },
    /// More than the session has: the approval is shown again, with this grant and reason.
    RequestAccess {
        /// Matches its answer.
        id: u64,
        /// What the agent asks for.
        grant: Grant,
        /// Why, in the agent's words, shown to the user.
        reason: String,
    },
}

/// From the app.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum ServerMessage {
    /// The approval is shown in Lux, with this code.
    Waiting {
        /// The match code, as the dialog shows it.
        code: String,
    },
    /// The session is approved.
    Granted {
        /// What it may do.
        grant: Grant,
    },
    /// The user refused, or AI is off.
    Refused {
        /// Why, in the user's words.
        reason: String,
    },
    /// A call's answer.
    Result {
        /// The call's.
        id: u64,
        /// Its JSON.
        value: Value,
    },
    /// A call's failure.
    Error {
        /// The call's.
        id: u64,
        /// What kind.
        code: crate::tools::ToolErrorCode,
        /// For the agent and the user.
        message: String,
    },
}
