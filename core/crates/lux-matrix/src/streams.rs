//! Live values as the ports' streams.

use futures_util::stream;
use lux_core::ports::ValueStream;
use tokio::sync::watch;

/// The value now, then each new one, until its sender goes.
pub(crate) fn watched<T: Clone + Send + Sync + 'static>(receiver: watch::Receiver<T>) -> ValueStream<T> {
    Box::pin(stream::unfold((receiver, true), |(mut receiver, first)| async move {
        if !first {
            receiver.changed().await.ok()?;
        }
        let value = receiver.borrow_and_update().clone();
        Some((value, (receiver, false)))
    }))
}
