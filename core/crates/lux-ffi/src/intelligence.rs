//! The AI actions over the composer's text (`lux-intelligence`), with the platform's model and
//! the open chat given by the apps.

use std::sync::Arc;

use lux_intelligence::{
    ActionContext, ActionResult, Availability, ChangeKind, ChatContext, ContextError, ContextMessage, ContextSource,
    CorrectionKind, Intelligence, IntelligenceError, LanguageModel, ModelError, ModelRequest, Output, Person,
    TextAction,
};

use crate::chat::position;

/// Whether the model can answer now.
#[derive(Clone, Debug, uniffi::Enum)]
pub enum CoreModelAvailability {
    /// It answers.
    Ready,
    /// The user turned it off in the system's settings.
    TurnedOff,
    /// This device cannot run it.
    NotEligible,
    /// It is not ready yet (its model downloading).
    NotReady,
    /// Another reason, for the log.
    Unavailable {
        /// What the platform said.
        reason: String,
    },
}

impl From<CoreModelAvailability> for Availability {
    fn from(availability: CoreModelAvailability) -> Self {
        match availability {
            CoreModelAvailability::Ready => Self::Ready,
            CoreModelAvailability::TurnedOff => Self::TurnedOff,
            CoreModelAvailability::NotEligible => Self::NotEligible,
            CoreModelAvailability::NotReady => Self::NotReady,
            CoreModelAvailability::Unavailable { reason } => Self::Unavailable { reason },
        }
    }
}

impl From<Availability> for CoreModelAvailability {
    fn from(availability: Availability) -> Self {
        match availability {
            Availability::Ready => Self::Ready,
            Availability::TurnedOff => Self::TurnedOff,
            Availability::NotEligible => Self::NotEligible,
            Availability::NotReady => Self::NotReady,
            Availability::Unavailable { reason } => Self::Unavailable { reason },
        }
    }
}

/// One question to the model.
#[derive(uniffi::Record)]
pub struct CoreModelRequest {
    /// How the model behaves.
    pub instructions: String,
    /// What it answers.
    pub prompt: String,
    /// The answer's JSON Schema, as JSON: objects, arrays, strings, string enums, numbers and
    /// booleans, every subschema inline.
    pub output_schema: String,
}

/// Why the model gave no answer.
#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum CoreModelError {
    /// It cannot answer now.
    #[error("the model is unavailable: {reason}")]
    Unavailable {
        /// What the platform said.
        reason: String,
    },
    /// It does not take the text's language.
    #[error("the model does not take this language")]
    UnsupportedLanguage,
    /// The text is more than it reads at once.
    #[error("the text is too long for the model")]
    TooLong,
    /// Its guardrails refused the text.
    #[error("the model refused: {reason}")]
    Refused {
        /// What the platform said.
        reason: String,
    },
    /// Anything else.
    #[error("the model failed: {reason}")]
    Failed {
        /// What the platform said.
        reason: String,
    },
}

impl From<uniffi::UnexpectedUniFFICallbackError> for CoreModelError {
    fn from(error: uniffi::UnexpectedUniFFICallbackError) -> Self {
        Self::Failed { reason: error.reason }
    }
}

impl From<CoreModelError> for ModelError {
    fn from(error: CoreModelError) -> Self {
        match error {
            CoreModelError::Unavailable { reason } => Self::Unavailable { reason },
            CoreModelError::UnsupportedLanguage => Self::UnsupportedLanguage,
            CoreModelError::TooLong => Self::TooLong,
            CoreModelError::Refused { reason } => Self::Refused { reason },
            CoreModelError::Failed { reason } => Self::Failed { reason },
        }
    }
}

/// A language model the platform gives: Apple Intelligence through Foundation Models, on Apple's
/// systems. It holds no rule of the app: no prompts, no checks.
#[uniffi::export(with_foreign)]
#[async_trait::async_trait]
pub trait CoreLanguageModel: Send + Sync {
    /// Whether it can answer now.
    fn availability(&self) -> CoreModelAvailability;

    /// The language of `text` as a BCP 47 tag, when the platform can tell.
    fn language_of(&self, text: String) -> Option<String>;

    /// Whether it reads and writes `language`, a BCP 47 tag.
    fn supports(&self, language: String) -> bool;

    /// Its answer to `request`: JSON in the request's schema.
    ///
    /// # Errors
    /// When it gives no answer.
    async fn respond(&self, request: CoreModelRequest) -> Result<String, CoreModelError>;
}

/// The platform's model as the actions' port.
struct ForeignModel(Arc<dyn CoreLanguageModel>);

impl LanguageModel for ForeignModel {
    fn availability(&self) -> Availability {
        self.0.availability().into()
    }

    fn language_of(&self, text: &str) -> Option<String> {
        self.0.language_of(text.to_owned())
    }

    fn supports(&self, language: &str) -> bool {
        self.0.supports(language.to_owned())
    }

    async fn respond(&self, request: ModelRequest) -> Result<serde_json::Value, ModelError> {
        let request = CoreModelRequest {
            instructions: request.instructions,
            prompt: request.prompt,
            output_schema: request.output_schema.to_string(),
        };
        let answer = self.0.respond(request).await?;
        serde_json::from_str(&answer).map_err(|error| ModelError::Failed {
            reason: error.to_string(),
        })
    }
}

/// The chat the composer writes in.
#[derive(uniffi::Record)]
pub struct CoreActionChat {
    /// Its name as the list shows it.
    pub name: String,
    /// The network it is on, none for Matrix.
    pub network: Option<String>,
    /// Whether it has more than one other person.
    pub is_group: bool,
}

/// One of the chat's messages.
#[derive(uniffi::Record)]
pub struct CoreActionMessage {
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
#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum CoreActionContextError {
    /// The user keeps this chat from AI.
    #[error("the chat is hidden from AI")]
    Hidden,
    /// It could not be read.
    #[error("the context cannot be read: {reason}")]
    Unreadable {
        /// Why.
        reason: String,
    },
}

impl From<uniffi::UnexpectedUniFFICallbackError> for CoreActionContextError {
    fn from(error: uniffi::UnexpectedUniFFICallbackError) -> Self {
        Self::Unreadable { reason: error.reason }
    }
}

impl From<CoreActionContextError> for ContextError {
    fn from(error: CoreActionContextError) -> Self {
        match error {
            CoreActionContextError::Hidden => Self::Hidden,
            CoreActionContextError::Unreadable { reason } => Self::Unreadable { reason },
        }
    }
}

/// Where an action's variables come from: the open chat. Asked only for what the action's
/// templates use.
#[uniffi::export(with_foreign)]
#[async_trait::async_trait]
pub trait CoreActionContext: Send + Sync {
    /// Today in the user's calendar and time zone, as `2026-11-20`.
    fn today(&self) -> String;

    /// The chat, none when the text is not in one.
    ///
    /// # Errors
    /// When it cannot be read, or the chat is hidden from AI.
    async fn chat(&self) -> Result<Option<CoreActionChat>, CoreActionContextError>;

    /// The user's name.
    ///
    /// # Errors
    /// When it cannot be read.
    async fn my_name(&self) -> Result<Option<String>, CoreActionContextError>;

    /// The chat's last `count` messages, oldest first.
    ///
    /// # Errors
    /// When they cannot be read, or the chat is hidden from AI.
    async fn recent_messages(&self, count: u32) -> Result<Vec<CoreActionMessage>, CoreActionContextError>;
}

/// The app's context as the actions'.
struct ForeignContext(Arc<dyn CoreActionContext>);

impl ContextSource for ForeignContext {
    fn today(&self) -> String {
        self.0.today()
    }

    async fn chat(&self) -> Result<Option<ChatContext>, ContextError> {
        let chat = self.0.chat().await?;
        Ok(chat.map(|chat| ChatContext {
            name: chat.name,
            network: chat.network,
            is_group: chat.is_group,
        }))
    }

    async fn me(&self) -> Result<Option<Person>, ContextError> {
        Ok(self.0.my_name().await?.map(|name| Person { name }))
    }

    async fn recent_messages(&self, count: u32) -> Result<Vec<ContextMessage>, ContextError> {
        let messages = self.0.recent_messages(count).await?;
        Ok(messages
            .into_iter()
            .map(|message| ContextMessage {
                sender: message.sender,
                text: message.text,
                sent_at: message.sent_at,
                mine: message.mine,
            })
            .collect())
    }
}

/// What an action's answer is.
#[derive(Clone, Copy, uniffi::Enum)]
pub enum CoreActionOutput {
    /// Corrections to spans of the text, each taken or left.
    Corrections,
    /// A new text, previewed before it replaces the old.
    Replacement {
        /// It keeps the text's links.
        keep_links: bool,
        /// It keeps the text's code.
        keep_code: bool,
    },
    /// Something to read, not applied.
    Note,
}

/// An action over the composer's text: built in, or one the user wrote.
#[derive(uniffi::Record)]
pub struct CoreTextAction {
    /// Stable: `proofread`, `format`, or a user action's own. The apps word the built-in ones by it.
    pub id: String,
    /// Its name, for a user's action.
    pub name: String,
    /// How the model behaves: a template.
    pub instructions: String,
    /// What it answers: a template.
    pub prompt: String,
    /// What the answer is.
    pub output: CoreActionOutput,
    /// How many of the chat's last messages `messages` holds.
    pub recent_messages: u32,
}

impl From<TextAction> for CoreTextAction {
    fn from(action: TextAction) -> Self {
        Self {
            id: action.id,
            name: action.name,
            instructions: action.instructions,
            prompt: action.prompt,
            output: match action.output {
                Output::Corrections => CoreActionOutput::Corrections,
                Output::Replacement { keep_links, keep_code } => {
                    CoreActionOutput::Replacement { keep_links, keep_code }
                }
                Output::Note => CoreActionOutput::Note,
            },
            recent_messages: action.context.recent_messages,
        }
    }
}

impl From<CoreTextAction> for TextAction {
    fn from(action: CoreTextAction) -> Self {
        Self {
            id: action.id,
            name: action.name,
            instructions: action.instructions,
            prompt: action.prompt,
            output: match action.output {
                CoreActionOutput::Corrections => Output::Corrections,
                CoreActionOutput::Replacement { keep_links, keep_code } => {
                    Output::Replacement { keep_links, keep_code }
                }
                CoreActionOutput::Note => Output::Note,
            },
            context: ActionContext {
                recent_messages: action.recent_messages,
            },
        }
    }
}

/// The actions the composer offers before the user adds any, in their order.
#[uniffi::export]
#[must_use]
pub fn built_in_text_actions() -> Vec<CoreTextAction> {
    TextAction::built_in().into_iter().map(CoreTextAction::from).collect()
}

/// What kind of mistake a correction mends.
#[derive(Clone, Copy, uniffi::Enum)]
pub enum CoreCorrectionKind {
    /// A word misspelled.
    Spelling,
    /// Grammar.
    Grammar,
    /// Punctuation.
    Punctuation,
}

/// One mistake in the text and its correction.
#[derive(uniffi::Record)]
pub struct CoreCorrection {
    /// Where the mistake starts, in UTF-16 code units.
    pub start: u32,
    /// How long it is, in UTF-16 code units.
    pub length: u32,
    /// The text there now.
    pub original: String,
    /// What replaces it.
    pub replacement: String,
    /// What kind of mistake it is.
    pub kind: CoreCorrectionKind,
}

/// Whether a part of a preview stayed, came or went.
#[derive(Clone, Copy, uniffi::Enum)]
pub enum CoreChangeKind {
    /// In both.
    Kept,
    /// Only in the new text.
    Added,
    /// Only in the text as it was.
    Removed,
}

/// A run of a replacement's preview.
#[derive(uniffi::Record)]
pub struct CoreTextChange {
    /// Whether it stayed, came or went.
    pub kind: CoreChangeKind,
    /// Its text.
    pub text: String,
}

/// An action's checked answer.
#[derive(uniffi::Enum)]
pub enum CoreActionResult {
    /// Corrections, in order, none overlapping; none when the text needs none.
    Corrections {
        /// The corrections.
        corrections: Vec<CoreCorrection>,
    },
    /// A new text, to preview and apply.
    Replacement {
        /// The new text, in the composer's Markdown.
        text: String,
        /// What changed, in order, for the preview.
        changes: Vec<CoreTextChange>,
    },
    /// Something to read.
    Note {
        /// The note.
        text: String,
    },
}

impl From<ActionResult> for CoreActionResult {
    fn from(result: ActionResult) -> Self {
        match result {
            ActionResult::Corrections(corrections) => Self::Corrections {
                corrections: corrections
                    .into_iter()
                    .map(|correction| CoreCorrection {
                        start: position(correction.range.start),
                        length: position(correction.range.len()),
                        original: correction.original,
                        replacement: correction.replacement,
                        kind: match correction.kind {
                            CorrectionKind::Spelling => CoreCorrectionKind::Spelling,
                            CorrectionKind::Grammar => CoreCorrectionKind::Grammar,
                            CorrectionKind::Punctuation => CoreCorrectionKind::Punctuation,
                        },
                    })
                    .collect(),
            },
            ActionResult::Replacement(replacement) => Self::Replacement {
                text: replacement.text,
                changes: replacement
                    .changes
                    .into_iter()
                    .map(|change| CoreTextChange {
                        kind: match change.kind {
                            ChangeKind::Kept => CoreChangeKind::Kept,
                            ChangeKind::Added => CoreChangeKind::Added,
                            ChangeKind::Removed => CoreChangeKind::Removed,
                        },
                        text: change.text,
                    })
                    .collect(),
            },
            ActionResult::Note(text) => Self::Note { text },
        }
    }
}

/// Why an action gave nothing. The apps word each case in the user's language; the text here is
/// for the log.
#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum CoreIntelligenceError {
    /// The model cannot answer now.
    #[error("the model is unavailable")]
    Unavailable {
        /// Why.
        availability: CoreModelAvailability,
    },
    /// There is nothing to work on.
    #[error("the text is empty")]
    Empty,
    /// The text is longer than an action takes.
    #[error("the text is too long")]
    TooLong,
    /// The model does not take the text's language.
    #[error("the model does not take {language}")]
    UnsupportedLanguage {
        /// The language, a BCP 47 tag; empty when the model said so itself.
        language: String,
    },
    /// The action's definition cannot run.
    #[error("the action cannot run: {reason}")]
    Action {
        /// Why.
        reason: String,
    },
    /// The chat is hidden from AI.
    #[error("the chat is hidden from AI")]
    Hidden,
    /// The model refused the text (its guardrails).
    #[error("the model refused: {reason}")]
    Refused {
        /// Why.
        reason: String,
    },
    /// The model, or reading the chat, failed; or the answer could not be used.
    #[error("the action failed: {reason}")]
    Failed {
        /// Why, for the log.
        reason: String,
    },
}

impl From<IntelligenceError> for CoreIntelligenceError {
    fn from(error: IntelligenceError) -> Self {
        match error {
            IntelligenceError::Unavailable { availability } => Self::Unavailable {
                availability: availability.into(),
            },
            IntelligenceError::Empty => Self::Empty,
            IntelligenceError::TooLong | IntelligenceError::Model(ModelError::TooLong) => Self::TooLong,
            IntelligenceError::UnsupportedLanguage { language } => Self::UnsupportedLanguage { language },
            IntelligenceError::Action { reason } => Self::Action { reason },
            IntelligenceError::Context(ContextError::Hidden) => Self::Hidden,
            IntelligenceError::Model(ModelError::Refused { reason }) => Self::Refused { reason },
            IntelligenceError::Model(ModelError::Unavailable { reason }) => Self::Unavailable {
                availability: CoreModelAvailability::Unavailable { reason },
            },
            IntelligenceError::Model(ModelError::UnsupportedLanguage) => Self::UnsupportedLanguage {
                language: String::new(),
            },
            error @ (IntelligenceError::Context(ContextError::Unreadable { .. })
            | IntelligenceError::Model(ModelError::Failed { .. })
            | IntelligenceError::Unusable { .. }) => Self::Failed {
                reason: error.to_string(),
            },
        }
    }
}

/// The AI actions over one model.
#[derive(uniffi::Object)]
pub struct CoreIntelligence {
    intelligence: Intelligence<ForeignModel>,
}

#[uniffi::export(async_runtime = "tokio")]
impl CoreIntelligence {
    /// Actions over the platform's `model`.
    #[uniffi::constructor]
    #[must_use]
    pub fn new(model: Arc<dyn CoreLanguageModel>) -> Arc<Self> {
        Arc::new(Self {
            intelligence: Intelligence::new(ForeignModel(model)),
        })
    }

    /// Whether the model can answer now.
    #[must_use]
    pub fn availability(&self) -> CoreModelAvailability {
        self.intelligence.availability().into()
    }

    /// Whether an action can take `text`, decided before the model is asked: the app shows an
    /// action as unavailable, with why, rather than fail on a tap.
    ///
    /// # Errors
    /// Why it cannot.
    pub fn check_text(&self, text: &str) -> Result<(), CoreIntelligenceError> {
        Ok(self.intelligence.check_text(text)?)
    }

    /// `action`'s checked answer about `text`, its variables filled from `context`.
    ///
    /// # Errors
    /// When the text cannot be taken, the action cannot run, the model gives no answer, or the
    /// answer cannot be used.
    pub async fn run(
        &self,
        action: CoreTextAction,
        text: String,
        context: Arc<dyn CoreActionContext>,
    ) -> Result<CoreActionResult, CoreIntelligenceError> {
        let action = TextAction::from(action);
        let result = self.intelligence.run(&action, &text, &ForeignContext(context)).await?;
        Ok(result.into())
    }
}
