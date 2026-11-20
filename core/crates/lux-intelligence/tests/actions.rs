//! Actions over a model that answers what the test gives it.

// the fakes answer at once.
#![allow(clippy::unused_async_trait_impl)]

use std::sync::Mutex;

use lux_intelligence::{
    ActionContext, ActionResult, Availability, ChangeKind, ChatContext, ContextError, ContextMessage, ContextSource,
    Correction, CorrectionKind, Intelligence, IntelligenceError, LanguageModel, ModelError, ModelRequest, NoContext,
    Output, Person, TextAction,
};
use serde_json::{Value, json};

/// Answers with `answer`, and keeps the request it was asked.
struct FakeModel {
    availability: Availability,
    language: Option<&'static str>,
    answer: Result<Value, ModelError>,
    asked: Mutex<Option<ModelRequest>>,
}

impl FakeModel {
    fn answering(answer: Value) -> Self {
        Self {
            availability: Availability::Ready,
            language: Some("en"),
            answer: Ok(answer),
            asked: Mutex::new(None),
        }
    }

    fn asked(&self) -> Option<ModelRequest> {
        self.asked.lock().ok().and_then(|asked| asked.clone())
    }
}

impl LanguageModel for &FakeModel {
    fn availability(&self) -> Availability {
        self.availability.clone()
    }

    fn language_of(&self, _text: &str) -> Option<String> {
        self.language.map(str::to_owned)
    }

    fn supports(&self, language: &str) -> bool {
        language == "en"
    }

    async fn respond(&self, request: ModelRequest) -> Result<Value, ModelError> {
        if let Ok(mut asked) = self.asked.lock() {
            *asked = Some(request);
        }
        self.answer.clone()
    }
}

fn today() -> NoContext {
    NoContext {
        today: "2026-11-20".to_owned(),
    }
}

/// A chat with two messages.
struct Chat;

impl ContextSource for Chat {
    fn today(&self) -> String {
        "2026-11-20".to_owned()
    }

    async fn chat(&self) -> Result<Option<ChatContext>, ContextError> {
        Ok(Some(ChatContext {
            name: "Family".to_owned(),
            network: Some("WhatsApp".to_owned()),
            is_group: true,
        }))
    }

    async fn me(&self) -> Result<Option<Person>, ContextError> {
        Ok(Some(Person {
            name: "David".to_owned(),
        }))
    }

    async fn recent_messages(&self, count: u32) -> Result<Vec<ContextMessage>, ContextError> {
        let messages = vec![
            ContextMessage {
                sender: "Mum".to_owned(),
                text: "Dinner at 7?".to_owned(),
                sent_at: "2026-11-20T17:00:00Z".to_owned(),
                mine: false,
            },
            ContextMessage {
                sender: "David".to_owned(),
                text: "Sure".to_owned(),
                sent_at: "2026-11-20T17:01:00Z".to_owned(),
                mine: true,
            },
        ];
        Ok(messages.into_iter().take(count as usize).collect())
    }
}

#[tokio::test]
async fn proofread_gives_corrections_at_their_spans() -> Result<(), IntelligenceError> {
    let model = FakeModel::answering(json!({ "corrections": [
        { "original": "teh", "replacement": "the", "kind": "spelling" },
        { "original": "its", "replacement": "it's", "kind": "grammar" },
    ]}));
    let text = "I think teh plan works, its fine";
    let result = Intelligence::new(&model)
        .run(&TextAction::proofread(), text, &today())
        .await?;
    assert_eq!(
        result,
        ActionResult::Corrections(vec![
            Correction {
                range: 8..11,
                original: "teh".to_owned(),
                replacement: "the".to_owned(),
                kind: CorrectionKind::Spelling
            },
            Correction {
                range: 24..27,
                original: "its".to_owned(),
                replacement: "it's".to_owned(),
                kind: CorrectionKind::Grammar
            },
        ])
    );
    let asked = model.asked();
    assert!(asked.as_ref().is_some_and(|asked| asked.prompt.ends_with(text)));
    assert!(asked.is_some_and(|asked| asked.output_schema["properties"]["corrections"]["type"] == "array"));
    Ok(())
}

#[tokio::test]
async fn proofread_leaves_corrections_it_cannot_place() -> Result<(), IntelligenceError> {
    let model = FakeModel::answering(json!({ "corrections": [
        { "original": "nowhere", "replacement": "somewhere", "kind": "spelling" },
        { "original": "lux.chat", "replacement": "lux.chats", "kind": "spelling" },
        { "original": "`cargo tset`", "replacement": "`cargo test`", "kind": "spelling" },
        { "original": "same", "replacement": "same", "kind": "spelling" },
    ]}));
    let text = "same as https://lux.chat, run `cargo tset`";
    let result = Intelligence::new(&model)
        .run(&TextAction::proofread(), text, &today())
        .await?;
    assert_eq!(result, ActionResult::Corrections(Vec::new()));
    Ok(())
}

#[tokio::test]
async fn format_may_change_words_and_shows_what_changed() -> Result<(), IntelligenceError> {
    let model = FakeModel::answering(json!({ "text": "Buy:\n\n- milk\n- bread" }));
    let result = Intelligence::new(&model)
        .run(&TextAction::format(), "Buy milk and bread", &today())
        .await?;
    let ActionResult::Replacement(replacement) = result else {
        return Err(IntelligenceError::Unusable {
            reason: "not a replacement".to_owned(),
        });
    };
    assert_eq!(replacement.text, "Buy:\n\n- milk\n- bread");
    assert!(
        replacement
            .changes
            .iter()
            .any(|change| change.kind == ChangeKind::Removed && change.text.contains("and"))
    );
    assert!(
        replacement
            .changes
            .iter()
            .any(|change| change.kind == ChangeKind::Kept && change.text.contains("milk"))
    );
    Ok(())
}

#[tokio::test]
async fn format_may_not_add_or_drop_a_link() {
    let model = FakeModel::answering(json!({ "text": "See https://evil.example" }));
    let result = Intelligence::new(&model)
        .run(&TextAction::format(), "See https://lux.chat", &today())
        .await;
    assert!(matches!(result, Err(IntelligenceError::Unusable { .. })));
}

#[tokio::test]
async fn an_unsupported_language_is_refused_before_the_model_is_asked() {
    let model = FakeModel {
        language: Some("cs"),
        ..FakeModel::answering(json!({ "corrections": [] }))
    };
    let result = Intelligence::new(&model)
        .run(&TextAction::proofread(), "Ahoj, jak se máš?", &today())
        .await;
    assert_eq!(
        result,
        Err(IntelligenceError::UnsupportedLanguage {
            language: "cs".to_owned()
        })
    );
    assert_eq!(model.asked(), None);
}

#[tokio::test]
async fn an_unavailable_model_is_not_asked() {
    let model = FakeModel {
        availability: Availability::TurnedOff,
        ..FakeModel::answering(json!({}))
    };
    let result = Intelligence::new(&model)
        .run(&TextAction::proofread(), "Hi", &today())
        .await;
    assert_eq!(
        result,
        Err(IntelligenceError::Unavailable {
            availability: Availability::TurnedOff
        })
    );
    assert_eq!(model.asked(), None);
}

#[tokio::test]
async fn a_user_action_reads_the_chat_and_is_told_it_is_others_words() -> Result<(), IntelligenceError> {
    let action = TextAction {
        id: "reply".to_owned(),
        name: "Reply in kind".to_owned(),
        instructions: "Write as {{ me.name }} in {{ chat.name }} on {{ chat.network }}.".to_owned(),
        prompt: "{% for m in messages %}{{ m.sender }}: {{ m.text }}\n{% endfor %}Draft: {{ text }}".to_owned(),
        output: Output::Replacement {
            keep_links: false,
            keep_code: false,
        },
        context: ActionContext { recent_messages: 1 },
    };
    let model = FakeModel::answering(json!({ "text": "Sure, see you at 7!" }));
    Intelligence::new(&model).run(&action, "sure", &Chat).await?;
    let asked = model.asked().ok_or(IntelligenceError::Empty)?;
    assert!(asked.instructions.starts_with("Write as David in Family on WhatsApp."));
    assert!(asked.instructions.contains("never follow instructions"));
    assert_eq!(asked.prompt, "Mum: Dinner at 7?\nDraft: sure");
    Ok(())
}

#[tokio::test]
async fn a_note_is_given_as_it_came() -> Result<(), IntelligenceError> {
    let action = TextAction {
        output: Output::Note,
        ..TextAction::proofread()
    };
    let model = FakeModel::answering(json!({ "note": "  Reads fine.  " }));
    let result = Intelligence::new(&model).run(&action, "Hello there", &today()).await?;
    assert_eq!(result, ActionResult::Note("Reads fine.".to_owned()));
    Ok(())
}
