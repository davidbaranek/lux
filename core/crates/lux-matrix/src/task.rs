//! The account's tasks: each one has an owner, and ends when its owner drops, so nothing the
//! account started outlives it.
//!
//! `tokio::spawn` is disallowed in the workspace (`clippy.toml`): a task starts here, or in a
//! `JoinSet` its owner holds.

use std::future::Future;

use tokio_util::task::AbortOnDropHandle;

/// A started task, ended when this drops.
pub(crate) type Owned<T = ()> = AbortOnDropHandle<T>;

/// Starts `future` on the runtime; it runs until it ends or the returned handle drops.
#[must_use = "the task ends as soon as its handle drops"]
pub(crate) fn spawn<F>(future: F) -> Owned<F::Output>
where
    F: Future + Send + 'static,
    F::Output: Send + 'static,
{
    #[expect(
        clippy::disallowed_methods,
        reason = "the one start of an owned task: its handle ends it"
    )]
    AbortOnDropHandle::new(tokio::spawn(future))
}
