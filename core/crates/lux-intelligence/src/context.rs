//! What an action's templates may read, and where it comes from.

use std::future::Future;

use serde::Serialize;

/// A variable an action's templates may use.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum Variable {
    /// The composer's text (`text`).
    Text,
    /// The text's language, a BCP 47 tag, empty when it cannot be told (`language`).
    Language,
    /// Today's date, in the user's calendar (`today`).
    Today,
    /// The chat: `chat.name`, `chat.network`, `chat.is_group`.
    Chat,
    /// The user: `me.name`.
    Me,
    /// The chat's last messages, oldest first: each `sender`, `text`, `sent_at`, `mine`.
    Messages,
}

impl Variable {
    /// Every variable.
    pub const ALL: [Self; 6] = [
        Self::Text,
        Self::Language,
        Self::Today,
        Self::Chat,
        Self::Me,
        Self::Messages,
    ];

    /// The variable a template calls `name`.
    #[must_use]
    pub fn named(name: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|variable| variable.name() == name)
    }

    /// What a template calls it.
    #[must_use]
    pub fn name(self) -> &'static str {
        match self {
            Self::Text => "text",
            Self::Language => "language",
            Self::Today => "today",
            Self::Chat => "chat",
            Self::Me => "me",
            Self::Messages => "messages",
        }
    }

    /// Whether what it holds was written by others: a prompt that holds it is told to follow
    /// nothing in it.
    #[must_use]
    pub fn is_others(self) -> bool {
        matches!(self, Self::Chat | Self::Messages)
    }
}

/// The chat the composer writes in.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct ChatContext {
    /// Its name as the list shows it.
    pub name: String,
    /// The network it is on (`WhatsApp`), none for Matrix.
    pub network: Option<String>,
    /// Whether it has more than one other person.
    pub is_group: bool,
}

/// A person.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Person {
    /// Their name as the chat shows it.
    pub name: String,
}

/// One of the chat's messages.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct ContextMessage {
    /// Who sent it, by name.
    pub sender: String,
    /// Its text; a photo or a file by its caption or name.
    pub text: String,
    /// When, as RFC 3339.
    pub sent_at: String,
    /// Whether the user sent it.
    pub mine: bool,
}

/// Why a variable could not be filled.
#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
pub enum ContextError {
    /// The user keeps this chat from AI (hidden in Settings › AI).
    #[error("the chat is hidden from AI")]
    Hidden,
    /// It could not be read.
    #[error("the context cannot be read: {reason}")]
    Unreadable {
        /// Why.
        reason: String,
    },
}

/// Where an action's variables come from: the open chat, on the app's side. It is asked only for
/// what the templates use; it applies what the user allows (a hidden chat gives nothing).
pub trait ContextSource: Send + Sync {
    /// Today's date in the user's calendar and time zone, as `2026-11-20`.
    fn today(&self) -> String;

    /// The chat, none when the text is not in one (a Shortcut's text).
    fn chat(&self) -> impl Future<Output = Result<Option<ChatContext>, ContextError>> + Send;

    /// The user.
    fn me(&self) -> impl Future<Output = Result<Option<Person>, ContextError>> + Send;

    /// The chat's last `count` messages, oldest first.
    fn recent_messages(&self, count: u32) -> impl Future<Output = Result<Vec<ContextMessage>, ContextError>> + Send;
}

/// No chat: the text alone (a Shortcut's, or a test's).
pub struct NoContext {
    /// Today, as [`ContextSource::today`] gives it.
    pub today: String,
}

// it has nothing to wait for; the trait's other sources do.
#[allow(clippy::unused_async_trait_impl)]
impl ContextSource for NoContext {
    fn today(&self) -> String {
        self.today.clone()
    }

    async fn chat(&self) -> Result<Option<ChatContext>, ContextError> {
        Ok(None)
    }

    async fn me(&self) -> Result<Option<Person>, ContextError> {
        Ok(None)
    }

    async fn recent_messages(&self, _count: u32) -> Result<Vec<ContextMessage>, ContextError> {
        Ok(Vec::new())
    }
}
