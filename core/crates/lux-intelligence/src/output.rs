//! Each output's answer, as the model gives it, and its checks: shared by every action with
//! that output.

use std::ops::Range;

use schemars::JsonSchema;
use serde::Deserialize;
use similar::{ChangeTag, TextDiff};

use crate::action::Output;
use crate::intelligence::IntelligenceError;
use crate::schema::schema_of;
use crate::text::{code, links, protected, utf16};

/// What kind of mistake a correction mends.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum CorrectionKind {
    /// A word misspelled.
    Spelling,
    /// Grammar: agreement, case, word order.
    Grammar,
    /// Punctuation.
    Punctuation,
}

/// One mistake in the text and its correction.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Correction {
    /// Where the mistake is, in UTF-16 code units, as text views count.
    pub range: Range<usize>,
    /// The text there now.
    pub original: String,
    /// What replaces it.
    pub replacement: String,
    /// What kind of mistake it is.
    pub kind: CorrectionKind,
}

/// Whether a part of a replacement's preview stayed, came or went.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ChangeKind {
    /// In both.
    Kept,
    /// Only in the new text.
    Added,
    /// Only in the text as it was.
    Removed,
}

/// A run of a replacement's preview.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TextChange {
    /// Whether it stayed, came or went.
    pub kind: ChangeKind,
    /// Its text.
    pub text: String,
}

/// A new text in place of the old.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Replacement {
    /// The new text, in the composer's Markdown.
    pub text: String,
    /// The words kept, added and removed, in order, for the preview.
    pub changes: Vec<TextChange>,
}

/// An action's checked answer.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ActionResult {
    /// Corrections, in order, none overlapping; none when the text needs none.
    Corrections(Vec<Correction>),
    /// A new text, to preview and apply.
    Replacement(Replacement),
    /// Something to read.
    Note(String),
}

/// Corrections, as the model gives them.
#[derive(Debug, Deserialize, JsonSchema)]
struct CorrectionsAnswer {
    /// The mistakes, in the order they come in the text; none when there are none.
    corrections: Vec<AnsweredCorrection>,
}

/// One mistake, as the model gives it.
#[derive(Debug, Deserialize, JsonSchema)]
struct AnsweredCorrection {
    /// The exact text with the mistake, copied from the message: a word or a few.
    original: String,
    /// The same text corrected.
    replacement: String,
    /// What kind of mistake it is.
    kind: CorrectionKind,
}

/// A replacement, as the model gives it.
#[derive(Debug, Deserialize, JsonSchema)]
struct ReplacementAnswer {
    /// The whole new text, in Markdown.
    text: String,
}

/// A note, as the model gives it.
#[derive(Debug, Deserialize, JsonSchema)]
struct NoteAnswer {
    /// The note, in the user's language, short.
    note: String,
}

/// The longest note kept, in characters.
const MAX_NOTE_CHARS: usize = 2000;

impl Output {
    /// The JSON Schema the model's answer is held to.
    pub(crate) fn schema(self) -> serde_json::Value {
        match self {
            Self::Corrections => schema_of::<CorrectionsAnswer>(),
            Self::Replacement { .. } => schema_of::<ReplacementAnswer>(),
            Self::Note => schema_of::<NoteAnswer>(),
        }
    }

    /// The model's `answer` about `text`, read and checked: what the output does not allow is
    /// refused or left out here, never trusted as it came.
    pub(crate) fn check(self, answer: serde_json::Value, text: &str) -> Result<ActionResult, IntelligenceError> {
        let unusable = |reason: String| IntelligenceError::Unusable { reason };
        match self {
            Self::Corrections => {
                let answer: CorrectionsAnswer =
                    serde_json::from_value(answer).map_err(|error| unusable(error.to_string()))?;
                Ok(ActionResult::Corrections(corrections(answer, text)))
            }
            Self::Replacement { keep_links, keep_code } => {
                let answer: ReplacementAnswer =
                    serde_json::from_value(answer).map_err(|error| unusable(error.to_string()))?;
                let new = answer.text.trim().to_owned();
                if new.is_empty() {
                    return Err(unusable("the new text is empty".to_owned()));
                }
                if new.chars().count() > 2 * text.chars().count() + 200 {
                    return Err(unusable("the new text is much longer".to_owned()));
                }
                if keep_links && links(&new) != links(text) {
                    return Err(unusable("the new text's links are not the text's".to_owned()));
                }
                if keep_code && code(&new) != code(text) {
                    return Err(unusable("the new text's code is not the text's".to_owned()));
                }
                let changes = changes(text, &new);
                Ok(ActionResult::Replacement(Replacement { text: new, changes }))
            }
            Self::Note => {
                let answer: NoteAnswer = serde_json::from_value(answer).map_err(|error| unusable(error.to_string()))?;
                let note = answer.note.trim();
                if note.is_empty() {
                    return Err(unusable("the note is empty".to_owned()));
                }
                Ok(ActionResult::Note(note.chars().take(MAX_NOTE_CHARS).collect()))
            }
        }
    }
}

/// The answer's corrections that can be applied: found in order, each after the one before (so
/// none overlaps another), none touching links, code or marks, none that changes nothing.
fn corrections(answer: CorrectionsAnswer, text: &str) -> Vec<Correction> {
    let protected = protected(text);
    let mut corrections = Vec::new();
    let mut from = 0;
    for answered in answer.corrections {
        if answered.original.is_empty() || answered.original == answered.replacement {
            continue;
        }
        let Some(start) = text
            .get(from..)
            .and_then(|rest| rest.find(&answered.original))
            .map(|at| from + at)
        else {
            tracing::debug!("a correction's text is not in the message after the last one");
            continue;
        };
        let range = start..start + answered.original.len();
        if protected
            .iter()
            .any(|kept| kept.start < range.end && range.start < kept.end)
        {
            continue;
        }
        from = range.end;
        corrections.push(Correction {
            range: utf16(text, range),
            original: answered.original,
            replacement: answered.replacement,
            kind: answered.kind,
        });
    }
    corrections
}

/// The word runs that stayed, came and went from `before` to `after`.
fn changes(before: &str, after: &str) -> Vec<TextChange> {
    let mut changes: Vec<TextChange> = Vec::new();
    for change in TextDiff::from_words(before, after).iter_all_changes() {
        let kind = match change.tag() {
            ChangeTag::Equal => ChangeKind::Kept,
            ChangeTag::Insert => ChangeKind::Added,
            ChangeTag::Delete => ChangeKind::Removed,
        };
        match changes.last_mut() {
            Some(last) if last.kind == kind => last.text.push_str(change.value()),
            _ => changes.push(TextChange {
                kind,
                text: change.value().to_owned(),
            }),
        }
    }
    changes
}
