//! The model port: what a platform gives the features.

use std::future::Future;

use serde_json::Value;

/// Whether the model can answer now.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Availability {
    /// It answers.
    Ready,
    /// The user turned it off in the system's settings (Apple Intelligence off).
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

/// One question to the model: how to behave, what to answer, and the answer's shape.
#[derive(Clone, Debug, PartialEq)]
pub struct ModelRequest {
    /// How the model behaves (its system instructions).
    pub instructions: String,
    /// What it answers.
    pub prompt: String,
    /// The answer's JSON Schema: objects, arrays, strings, string enums, numbers and booleans,
    /// with every subschema inline ([`schema_of`](crate::schema_of)). The model's answer is held
    /// to it where the model can (Foundation Models constrains its decoding to it).
    pub output_schema: Value,
}

/// Why the model gave no answer.
#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
pub enum ModelError {
    /// It cannot answer now.
    #[error("the model is unavailable: {reason}")]
    Unavailable {
        /// What the platform said.
        reason: String,
    },
    /// It does not read or write the text's language.
    #[error("the model does not take this language")]
    UnsupportedLanguage,
    /// The text is more than it can read at once.
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

/// A language model the platform gives. Only the platform's adapter implements it; it holds no
/// rule of the app (no prompts, no checks).
pub trait LanguageModel: Send + Sync {
    /// Whether it can answer now.
    fn availability(&self) -> Availability;

    /// The language of `text` as a BCP 47 tag (`cs`, `en`), when the platform can tell.
    fn language_of(&self, text: &str) -> Option<String>;

    /// Whether it reads and writes `language` (a BCP 47 tag).
    fn supports(&self, language: &str) -> bool;

    /// Its answer to `request`, as JSON in the request's schema.
    fn respond(&self, request: ModelRequest) -> impl Future<Output = Result<Value, ModelError>> + Send;
}
