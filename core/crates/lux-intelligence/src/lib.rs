//! The app's AI actions over a language model the platform gives.
//!
//! An action over the composer's text ([`TextAction`]) is data: its instructions and prompt are
//! templates, and its [`Output`] says what the answer is and how it applies (corrections to
//! spans, a replacement shown as a preview, a note). The code is shared by output, so a new
//! action is a definition, the built-in ones ([`TextAction::proofread`], [`TextAction::format`])
//! and, later, ones the user writes.
//!
//! A template's variables ([`Variable`]: the chat, its recent messages, the user) are filled from
//! a [`ContextSource`], asked only for what the templates use. The model is a port
//! ([`LanguageModel`]): Apple Intelligence through Foundation Models on Apple's systems, another
//! platform's model or a server provider elsewhere. Nothing here knows which.
//!
//! [`Intelligence`] runs an action: it refuses what the model cannot take (unavailable, an
//! unsupported language, too long) before asking, and returns only checked answers.

mod action;
mod context;
mod intelligence;
mod model;
mod output;
mod schema;
mod text;

pub use action::{ActionContext, Output, TextAction};
pub use context::{ChatContext, ContextError, ContextMessage, ContextSource, NoContext, Person, Variable};
pub use intelligence::{Intelligence, IntelligenceError, MAX_TEXT_CHARS};
pub use model::{Availability, LanguageModel, ModelError, ModelRequest};
pub use output::{ActionResult, ChangeKind, Correction, CorrectionKind, Replacement, TextChange};
pub use schema::schema_of;
