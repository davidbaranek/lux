//! The ports' contract: what every backend of the core does the same, written once and run
//! against each, the demo here and the Matrix account in `lux-matrix`'s tests
//! ([`contract_tests!`](crate::contract_tests)). The demo stands in for the Matrix account under
//! the view models' and the apps' tests: a behaviour here is one those tests may rely on.
//!
//! A backend's own rules (the demo's made-up history, its latencies, its text that fails) stay
//! out of it: a behaviour starts from what any backend's chat has, a text message from someone
//! else, and what the test itself sends.
//!
//! Built for tests only: `cfg(test)` here, and the `test-support` feature for another crate's
//! tests. Each function here panics, failing the test that runs it, where a backend breaks the
//! contract.

#![allow(
    clippy::panic,
    clippy::expect_used,
    clippy::missing_panics_doc,
    reason = "the contract's checks fail the test that runs them"
)]

use std::sync::Arc;
use std::time::Duration;

use eyeball_im::Vector;
use futures_util::StreamExt;

use crate::ids::{RoomId, TimelineId};
use crate::message::SendState;
use crate::ports::{BackendError, ChatAccount, ChatSending, ChatTimelines, DiffStream, ThreadBackend};
use crate::timeline::{MessageKind, TimelineMessage};

/// How long a behaviour waits for what it expects: far longer than any backend takes.
const PATIENCE: Duration = Duration::from_secs(10);

/// A backend the contract runs against: an account, and a chat of it.
pub trait ContractBackend: Send + Sync {
    /// The account.
    type Account: ChatAccount + ThreadBackend;

    /// The account under the contract.
    fn account(&self) -> &Self::Account;

    /// A room the account is in, whose timeline holds a text message from someone else.
    fn room(&self) -> RoomId;
}

/// A timeline's messages as they change, applied one diff at a time: a behaviour sees each
/// state a message goes through, also those a backend sends in one batch.
pub struct Messages {
    stream: DiffStream<Arc<TimelineMessage>>,
    rows: Vector<Arc<TimelineMessage>>,
    pending: std::collections::VecDeque<eyeball_im::VectorDiff<Arc<TimelineMessage>>>,
}

impl Messages {
    /// The room's live timeline, from its first batch on.
    pub async fn of(backend: &impl ContractBackend) -> Self {
        let stream = backend
            .account()
            .timelines()
            .messages(&TimelineId::from(backend.room()))
            .await
            .expect("the room's timeline opens");
        Self {
            stream,
            rows: Vector::new(),
            pending: std::collections::VecDeque::new(),
        }
    }

    /// Applies the timeline's diffs, one at a time, until `pick` finds a message in it; that
    /// message. Fails the test when it does not come: `what` says what was waited for.
    pub async fn until(
        &mut self,
        what: &str,
        pick: impl Fn(&Vector<Arc<TimelineMessage>>) -> Option<Arc<TimelineMessage>>,
    ) -> Arc<TimelineMessage> {
        if let Some(found) = pick(&self.rows) {
            return found;
        }
        let waited = tokio::time::timeout(PATIENCE, async {
            loop {
                let Some(diff) = self.pending.pop_front() else {
                    let batch = self.stream.next().await.expect("the timeline goes on");
                    self.pending.extend(batch);
                    continue;
                };
                diff.apply(&mut self.rows);
                if let Some(found) = pick(&self.rows) {
                    return found;
                }
            }
        })
        .await;
        waited.unwrap_or_else(|_| panic!("the timeline never showed {what}"))
    }

    /// The messages now.
    #[must_use]
    pub fn rows(&self) -> &Vector<Arc<TimelineMessage>> {
        &self.rows
    }
}

/// The newest message with `body`, as `rows` show it.
#[must_use]
pub fn with_body(rows: &Vector<Arc<TimelineMessage>>, body: &str) -> Option<Arc<TimelineMessage>> {
    rows.iter().rev().find(|message| message.message.body == body).cloned()
}

/// The newest text message from someone else, as `rows` show it.
#[must_use]
pub fn anothers(rows: &Vector<Arc<TimelineMessage>>) -> Option<Arc<TimelineMessage>> {
    rows.iter()
        .rev()
        .find(|message| {
            !message.is_own
                && message.kind == MessageKind::Message
                && message.media.is_none()
                && !message.message.body.is_empty()
        })
        .cloned()
}

/// Sends `text` to the backend's room and waits until the server has it; the message then.
async fn sent(backend: &impl ContractBackend, messages: &mut Messages, text: &str) -> Arc<TimelineMessage> {
    backend
        .account()
        .timelines()
        .send_text(&TimelineId::from(backend.room()), text, None)
        .await
        .expect("the text is queued");
    messages
        .until("the text sent", |rows| {
            with_body(rows, text).filter(|message| message.message.state == SendState::Sent)
        })
        .await
}

/// A text sent shows at once, the account's own and sending, then as sent: one message
/// throughout, not a second one once the server has it.
pub async fn a_sent_text_shows_at_once_as_sending_then_sent(backend: &impl ContractBackend) {
    let mut messages = Messages::of(backend).await;
    backend
        .account()
        .timelines()
        .send_text(&TimelineId::from(backend.room()), "on my way", None)
        .await
        .expect("the text is queued");

    let echo = messages
        .until("the text's local echo", |rows| with_body(rows, "on my way"))
        .await;
    assert!(echo.is_own);
    assert_eq!(echo.message.state, SendState::Sending { upload: None });

    messages
        .until("the text sent", |rows| {
            with_body(rows, "on my way").filter(|message| message.message.state == SendState::Sent)
        })
        .await;
    let shown = messages
        .rows()
        .iter()
        .filter(|message| message.message.body == "on my way")
        .count();
    assert_eq!(shown, 1);
}

/// The account's message is edited in place and says so; another's cannot be.
pub async fn the_accounts_message_is_edited_in_place_and_anothers_is_not(backend: &impl ContractBackend) {
    let room = backend.room();
    let timelines = backend.account().timelines();
    let mut messages = Messages::of(backend).await;
    let mine = sent(backend, &mut messages, "see you at 8").await;
    assert!(mine.is_editable);

    timelines
        .edit(&room, &mine.message.id, "see you at 9")
        .await
        .expect("the account's message is edited");

    let edited = messages
        .until("the edit", |rows| {
            with_body(rows, "see you at 9").filter(|message| message.message.is_edited)
        })
        .await;
    assert!(edited.is_own);
    assert!(
        with_body(messages.rows(), "see you at 8").is_none(),
        "the old text still shows"
    );
    let theirs = anothers(messages.rows()).expect("the room holds another's message");
    assert!(!theirs.is_editable);
    let refused = timelines.edit(&room, &theirs.message.id, "not mine").await;
    assert!(matches!(refused, Err(BackendError::NotAllowed)), "{refused:?}");
}

/// A reaction to another's message shows at once as the account's, counted once, beside the
/// others' reactions.
///
/// Taking it back is not in the contract yet: on the Matrix account, a reaction toggled off
/// while its own sending is under way sometimes stays, and no redaction goes out (the SDK's send
/// queue), so the two backends differ there until that is fixed.
pub async fn a_reaction_to_anothers_message_is_the_accounts_once(backend: &impl ContractBackend) {
    let mut messages = Messages::of(backend).await;
    let theirs = messages.until("another's message", anothers).await;
    let id = theirs.message.id.clone();

    backend
        .account()
        .timelines()
        .toggle_reaction(&backend.room(), &id, "🦉")
        .await
        .expect("the reaction is sent");

    let with = messages
        .until("the reaction", |rows| {
            rows.iter()
                .find(|message| message.message.id == id)
                .filter(|message| message.reactions.iter().any(|reaction| reaction.key == "🦉"))
                .cloned()
        })
        .await;
    let owl = with
        .reactions
        .iter()
        .find(|reaction| reaction.key == "🦉")
        .expect("found above");
    assert!(owl.is_mine);
    assert_eq!(owl.count, 1);
    assert!(with.message.has_reactions);
    let others: Vec<_> = with.reactions.iter().filter(|reaction| reaction.key != "🦉").collect();
    assert_eq!(others, theirs.reactions.iter().collect::<Vec<_>>());
}

/// The contract's behaviours as tests, each with the attribute `#[$test]` (a tokio test, with
/// the runtime the backend needs) over the backend `$backend` makes (an expression, awaited
/// inside the test if it is a future).
#[macro_export]
macro_rules! contract_tests {
    (#[$test:meta] $backend:expr) => {
        #[$test]
        async fn a_sent_text_shows_at_once_as_sending_then_sent() {
            $crate::contract::a_sent_text_shows_at_once_as_sending_then_sent(&$backend).await;
        }

        #[$test]
        async fn the_accounts_message_is_edited_in_place_and_anothers_is_not() {
            $crate::contract::the_accounts_message_is_edited_in_place_and_anothers_is_not(&$backend).await;
        }

        #[$test]
        async fn a_reaction_to_anothers_message_is_the_accounts_once() {
            $crate::contract::a_reaction_to_anothers_message_is_the_accounts_once(&$backend).await;
        }
    };
}

/// The contract against the demo, in paused time: its made-up latencies pass at once.
#[cfg(test)]
mod demo {
    use super::ContractBackend;
    use crate::demo::{DemoAccount, DemoConfig};
    use crate::ids::RoomId;

    struct Demo(DemoAccount);

    impl ContractBackend for Demo {
        type Account = DemoAccount;

        fn account(&self) -> &DemoAccount {
            &self.0
        }

        fn room(&self) -> RoomId {
            RoomId::from("!room1:demo")
        }
    }

    fn demo() -> Demo {
        Demo(DemoAccount::new(DemoConfig {
            messages_per_room: 20,
            ..DemoConfig::new(30)
        }))
    }

    crate::contract_tests!(
        #[tokio::test(start_paused = true)]
        demo()
    );
}
