//! What agents may do with the account, on the Mac.
//!
//! The app serves its account to agents over a Unix socket in its own container ([`bind`],
//! [`serve`]); the
//! `lux` binary (the app's own executable, run as `Lux agent …`) reaches it as a CLI or as an MCP
//! server over stdio ([`run_client`]). Both fronts call the same [`tools`].
//!
//! Each connection is a session the user approves in the app, with a match code the client
//! shows too ([`Approver`]); the session's [`Grant`] says what it may do (read, write drafts, ask
//! to send). The [`Agent`] applies the rest of the policy to every call: the chats kept from AI
//! are not there, a call over the session's grant is refused, the calls are limited, the text
//! given back is plain and capped, and every call is logged.
//!
//! The account is a port ([`AgentBackend`]): the app's index and chats in the app, a fake in the
//! tests.

mod agent;
mod backend;
mod client;
mod protocol;
mod server;
mod text;
mod tools;

pub use agent::{Agent, Session};
pub use backend::{AgentBackend, BackendError, ChatSummary, LogEntry, MessageHit, SendOutcome};
pub use client::{run_client, skill};
pub use protocol::{ClientHello, ClientKind, Grant};
pub use server::{Approval, ApprovalAnswer, Approver, bind, serve};
pub use tools::{ToolError, ToolErrorCode, ToolSpec, tools};
