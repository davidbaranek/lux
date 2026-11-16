//! A view model's backend actions. Those on one target (a message, a chat, a room's sends) reach
//! the server in the order the user asked for them: a reply and the message after it, Archive
//! then Unarchive. Actions on other targets go at once, beside them, so one slow request holds
//! back only what has to come after it.

use std::collections::HashMap;
use std::future::Future;
use std::hash::Hash;

use tokio::task::JoinHandle;

/// The actions running or waiting, by target. Each action is its own task, so those still
/// waiting run once the queue is dropped (a draft kept as the chat closes).
#[derive(Debug)]
pub(crate) struct Actions<K> {
    /// The newest action on each target that may still run: the next on it starts after it.
    last: HashMap<K, JoinHandle<()>>,
}

impl<K: Eq + Hash> Actions<K> {
    pub(crate) fn new() -> Self {
        Self { last: HashMap::new() }
    }

    /// Runs `action` on the current runtime, once the actions pushed before it on `target` ended.
    pub(crate) fn push(&mut self, target: K, action: impl Future<Output = ()> + Send + 'static) {
        self.last.retain(|_, running| !running.is_finished());
        let before = self.last.remove(&target);
        #[expect(
            clippy::disallowed_methods,
            reason = "a user's action runs to its end, even once the view that asked for it has closed"
        )]
        let running = tokio::spawn(async move {
            if let Some(before) = before {
                // one that failed or panicked does not hold back the next.
                if let Err(error) = before.await
                    && error.is_panic()
                {
                    tracing::error!(%error, "an action panicked");
                }
            }
            action.await;
        });
        self.last.insert(target, running);
    }
}

#[cfg(test)]
mod tests {
    use std::sync::{Arc, Mutex};
    use std::time::Duration;

    use super::Actions;

    type Done = Arc<Mutex<Vec<&'static str>>>;

    fn push(actions: &mut Actions<&'static str>, done: &Done, target: &'static str, name: &'static str, wait: u64) {
        let done = Arc::clone(done);
        actions.push(target, async move {
            tokio::time::sleep(Duration::from_millis(wait)).await;
            done.lock().unwrap().push(name);
        });
    }

    #[tokio::test(start_paused = true)]
    async fn actions_on_one_target_keep_their_order() {
        let done = Done::default();
        let mut actions = Actions::new();
        push(&mut actions, &done, "room", "reply", 300);
        push(&mut actions, &done, "room", "message", 10);
        push(&mut actions, &done, "room", "another", 0);
        drop(actions);
        tokio::time::sleep(Duration::from_secs(1)).await;
        assert_eq!(*done.lock().unwrap(), ["reply", "message", "another"]);
    }

    #[tokio::test(start_paused = true)]
    async fn a_slow_action_does_not_hold_back_another_target() {
        let done = Done::default();
        let mut actions = Actions::new();
        push(&mut actions, &done, "message 1", "slow forward", 10_000);
        push(&mut actions, &done, "message 2", "reaction", 10);
        tokio::time::sleep(Duration::from_millis(100)).await;
        assert_eq!(*done.lock().unwrap(), ["reaction"]);
        tokio::time::sleep(Duration::from_secs(10)).await;
        assert_eq!(*done.lock().unwrap(), ["reaction", "slow forward"]);
    }

    #[tokio::test(start_paused = true)]
    async fn a_failed_action_does_not_stop_the_next_on_its_target() {
        let done = Done::default();
        let mut actions = Actions::new();
        actions.push("chat", async { panic!("the request failed badly") });
        push(&mut actions, &done, "chat", "unarchive", 0);
        tokio::time::sleep(Duration::from_millis(10)).await;
        assert_eq!(*done.lock().unwrap(), ["unarchive"]);
    }

    #[tokio::test(start_paused = true)]
    async fn ended_actions_are_forgotten() {
        let done = Done::default();
        let mut actions = Actions::new();
        for target in ["a", "b", "c"] {
            push(&mut actions, &done, target, target, 0);
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
        push(&mut actions, &done, "d", "d", 0);
        assert_eq!(actions.last.len(), 1);
    }
}
