//! An action over the composer's text, as data.

use std::collections::BTreeSet;

use minijinja::Environment;
use serde::{Deserialize, Serialize};

use crate::context::Variable;
use crate::intelligence::IntelligenceError;

/// What an action's answer is, and how it applies to the text. Each has its answer's shape and
/// its checks, shared by every action that gives it.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Output {
    /// Corrections to exact spans of the text, each taken or left (Proofread). They never touch
    /// links, code or Markdown marks.
    Corrections,
    /// A new text in place of the old, shown as a preview of what changed before it is applied
    /// (Format, a rewrite, a translation).
    Replacement {
        /// It keeps the text's links: none added, none dropped.
        #[serde(default = "yes")]
        keep_links: bool,
        /// It keeps the text's code.
        #[serde(default = "yes")]
        keep_code: bool,
    },
    /// Something to read, not applied to the text (an explanation, a summary of the chat).
    Note,
}

fn yes() -> bool {
    true
}

/// How much of the chat an action reads, when its templates ask for it.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ActionContext {
    /// How many of the chat's last messages `messages` holds.
    #[serde(default = "ActionContext::default_messages")]
    pub recent_messages: u32,
}

impl ActionContext {
    /// The most `messages` may hold: a model's context is small.
    pub const MAX_MESSAGES: u32 = 50;

    fn default_messages() -> u32 {
        20
    }
}

impl Default for ActionContext {
    fn default() -> Self {
        Self {
            recent_messages: Self::default_messages(),
        }
    }
}

/// An action over the composer's text: built in, or one the user wrote.
///
/// `instructions` and `prompt` are templates (Jinja's syntax, by minijinja) over the
/// [`Variable`]s: `{{ text }}`, `{{ chat.name }}`, `{% for m in messages %}…{% endfor %}`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct TextAction {
    /// Stable: `proofread`, `format`, or a user action's own.
    pub id: String,
    /// What the user sees; the apps word the built-in ones by their id.
    pub name: String,
    /// How the model behaves.
    pub instructions: String,
    /// What it answers.
    pub prompt: String,
    /// What the answer is.
    pub output: Output,
    /// How much of the chat it may read.
    #[serde(default)]
    pub context: ActionContext,
}

impl TextAction {
    /// Finds the text's spelling, grammar and punctuation mistakes. It never rewrites the
    /// message: each correction replaces an exact span the user may take or leave.
    #[must_use]
    pub fn proofread() -> Self {
        Self {
            id: "proofread".to_owned(),
            name: "Proofread".to_owned(),
            instructions: "You proofread a chat message the user is about to send. Find its \
                spelling, grammar and punctuation mistakes, in the message's own language. \
                Correct only mistakes: keep the words chosen, the style, the tone, slang, names, \
                emoji, Markdown, links and code as they are. For each mistake give the exact text \
                as written in the message (a word or a few) and the same text corrected. If there \
                are no mistakes, give no corrections."
                .to_owned(),
            prompt: "The message:\n\n{{ text }}".to_owned(),
            output: Output::Corrections,
            context: ActionContext::default(),
        }
    }

    /// Lays the text out with lists, paragraphs, bold and quotes, changing words only where the
    /// layout asks for it; the app shows what changed before it applies.
    #[must_use]
    pub fn format() -> Self {
        Self {
            id: "format".to_owned(),
            name: "Format".to_owned(),
            instructions: "You format a chat message the user is about to send, in Markdown. The \
                user asked for it, so the message always comes back formatted, never as it was: \
                put the words that matter most in bold (in every message, even a short one), \
                make an enumeration or steps a list, split separate thoughts into paragraphs, \
                quote quoted text, and start sentences with a capital letter and end them with a \
                full stop. Keep its meaning, language and tone, and change words only where the \
                layout needs it. Keep every link, code, name and emoji. Use only bold, italic, \
                strikethrough, code, quotes and lists: no headings, tables or images. For \
                example, \"this is very important\" becomes \"This is **very important**.\" Give \
                the whole message."
                .to_owned(),
            prompt: "The message:\n\n{{ text }}".to_owned(),
            output: Output::Replacement {
                keep_links: true,
                keep_code: true,
            },
            context: ActionContext::default(),
        }
    }

    /// The actions the app offers before the user adds any, in their order.
    #[must_use]
    pub fn built_in() -> Vec<Self> {
        vec![Self::proofread(), Self::format()]
    }

    /// The variables its templates use.
    ///
    /// # Errors
    /// When a template does not parse or names a variable there is not.
    pub fn variables(&self) -> Result<BTreeSet<Variable>, IntelligenceError> {
        let environment = Environment::new();
        let mut variables = BTreeSet::new();
        for source in [&self.instructions, &self.prompt] {
            let template = environment
                .template_from_str(source)
                .map_err(|error| IntelligenceError::Action {
                    reason: error.to_string(),
                })?;
            for name in template.undeclared_variables(false) {
                let variable = Variable::named(&name).ok_or_else(|| IntelligenceError::Action {
                    reason: format!("no variable `{name}`"),
                })?;
                variables.insert(variable);
            }
        }
        Ok(variables)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn built_in_actions_read_only_the_text() {
        for action in TextAction::built_in() {
            assert_eq!(
                action.variables(),
                Ok(BTreeSet::from([Variable::Text])),
                "{}",
                action.id
            );
        }
    }

    #[test]
    fn an_action_round_trips_as_json() -> Result<(), serde_json::Error> {
        let action = TextAction::format();
        let json = serde_json::to_string(&action)?;
        assert_eq!(serde_json::from_str::<TextAction>(&json)?, action);
        Ok(())
    }

    #[test]
    fn a_user_action_names_its_variables() {
        let action = TextAction {
            id: "reply".to_owned(),
            name: "Reply in kind".to_owned(),
            instructions: "Answer as {{ me.name }} in {{ chat.name }}.".to_owned(),
            prompt: "{% for message in messages %}{{ message.sender }}: {{ message.text }}\n{% endfor %}{{ text }}"
                .to_owned(),
            output: Output::Replacement {
                keep_links: false,
                keep_code: false,
            },
            context: ActionContext { recent_messages: 10 },
        };
        assert_eq!(
            action.variables(),
            Ok(BTreeSet::from([
                Variable::Me,
                Variable::Chat,
                Variable::Messages,
                Variable::Text
            ]))
        );
    }

    #[test]
    fn an_unknown_variable_is_refused() {
        let action = TextAction {
            prompt: "{{ password }}".to_owned(),
            ..TextAction::proofread()
        };
        assert!(matches!(action.variables(), Err(IntelligenceError::Action { .. })));
    }
}
