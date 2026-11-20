//! Mentions as the apps see them: the composer's pills, the `@` being typed, the members it
//! offers, and a message's pills. What decides is `lux_core::mention`.

use lux_core::ids::UserId;
use lux_core::mention::{
    ComposedText, Mention, MentionQuery, MentionSuggestion, MentionTarget, mention_query as query_at,
};

use crate::chat::position;
use crate::details::CoreMember;

/// Who a pill names.
#[derive(Clone, uniffi::Enum)]
pub enum CoreMentionTarget {
    /// A member.
    User {
        /// Their account.
        user_id: String,
    },
    /// Everyone in the room (`@room`).
    Room,
}

impl From<&MentionTarget> for CoreMentionTarget {
    fn from(target: &MentionTarget) -> Self {
        match target {
            MentionTarget::User(user) => Self::User {
                user_id: user.to_string(),
            },
            MentionTarget::Room => Self::Room,
        }
    }
}

impl From<CoreMentionTarget> for MentionTarget {
    fn from(target: CoreMentionTarget) -> Self {
        match target {
            CoreMentionTarget::User { user_id } => Self::User(UserId::from(user_id)),
            CoreMentionTarget::Room => Self::Room,
        }
    }
}

/// A pill in the composer's text, in UTF-16 units, over the name it shows.
#[derive(uniffi::Record)]
pub struct CoreMention {
    /// Who.
    pub target: CoreMentionTarget,
    /// Where it starts.
    pub start: u32,
    /// How long it is.
    pub length: u32,
}

/// The composer's text and its pills.
#[derive(uniffi::Record)]
pub struct CoreComposedText {
    /// The Markdown text, each pill's name in its place.
    pub text: String,
    /// The pills.
    pub mentions: Vec<CoreMention>,
}

impl From<ComposedText> for CoreComposedText {
    fn from(composed: ComposedText) -> Self {
        Self {
            text: composed.text,
            mentions: composed
                .mentions
                .iter()
                .map(|mention| CoreMention {
                    target: CoreMentionTarget::from(&mention.target),
                    start: position(mention.range.start),
                    length: position(mention.range.len()),
                })
                .collect(),
        }
    }
}

impl From<CoreComposedText> for ComposedText {
    fn from(composed: CoreComposedText) -> Self {
        Self {
            text: composed.text,
            mentions: composed
                .mentions
                .into_iter()
                .map(|mention| {
                    let start = usize::try_from(mention.start).unwrap_or(usize::MAX);
                    let length = usize::try_from(mention.length).unwrap_or(usize::MAX);
                    Mention {
                        target: mention.target.into(),
                        range: start..start.saturating_add(length),
                    }
                })
                .collect(),
        }
    }
}

/// The `@` and the word being typed before the cursor, in UTF-16 units.
#[derive(uniffi::Record)]
pub struct CoreMentionQuery {
    /// Where the `@` is: a picked pill replaces it and the word.
    pub start: u32,
    /// How long the `@` and the word are.
    pub length: u32,
    /// The word after the `@`.
    pub text: String,
}

impl From<MentionQuery> for CoreMentionQuery {
    fn from(query: MentionQuery) -> Self {
        Self {
            start: position(query.range.start),
            length: position(query.range.len()),
            text: query.text,
        }
    }
}

/// The mention typed right before `cursor` (a UTF-16 offset of the composer's `text`), if any.
#[uniffi::export]
#[must_use]
pub fn mention_query(text: &str, cursor: u32) -> Option<CoreMentionQuery> {
    query_at(text, usize::try_from(cursor).ok()?).map(CoreMentionQuery::from)
}

/// What the composer offers for a mention.
#[derive(uniffi::Enum)]
pub enum CoreMentionSuggestion {
    /// A member.
    Member {
        /// Who.
        member: CoreMember,
    },
    /// `@room`.
    Room,
}

impl From<MentionSuggestion> for CoreMentionSuggestion {
    fn from(suggestion: MentionSuggestion) -> Self {
        match suggestion {
            MentionSuggestion::Member(member) => Self::Member {
                member: CoreMember::from(&member),
            },
            MentionSuggestion::Room => Self::Room,
        }
    }
}
