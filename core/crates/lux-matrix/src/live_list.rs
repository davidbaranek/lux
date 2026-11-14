//! `LiveList`: a list with one writer (a task that maps the SDK's diffs) and any number of
//! readers, each following it as a stream of diffs. The chat list, the requests and each open
//! room's messages are one.

use std::sync::{Arc, Mutex, PoisonError};

use eyeball_im::{ObservableVector, Vector, VectorDiff};
use futures_util::{StreamExt, future, stream};
use lux_core::ports::DiffStream;

/// A list the core reads: the rows as they are now, shared with the task that maps them.
pub(crate) struct LiveList<T: Clone + Send + Sync + 'static> {
    rows: Arc<Mutex<ObservableVector<T>>>,
}

impl<T: Clone + Send + Sync + 'static> Clone for LiveList<T> {
    fn clone(&self) -> Self {
        Self {
            rows: Arc::clone(&self.rows),
        }
    }
}

impl<T: Clone + Send + Sync + 'static> LiveList<T> {
    pub(crate) fn new(initial: Vector<T>) -> Self {
        let mut rows = ObservableVector::new();
        if !initial.is_empty() {
            rows.append(initial);
        }
        Self {
            rows: Arc::new(Mutex::new(rows)),
        }
    }

    /// The rows now, as a `Reset`, then each batch the task applies.
    pub(crate) fn subscribe(&self) -> DiffStream<T> {
        let (values, batches) = self.lock().subscribe().into_values_and_batched_stream();
        Box::pin(stream::once(future::ready(vec![VectorDiff::Reset { values }])).chain(batches))
    }

    /// Applies one batch, for the subscribers to receive as one.
    pub(crate) fn apply(&self, batch: Vec<VectorDiff<T>>) {
        let mut rows = self.lock();
        let mut transaction = rows.transaction();
        for diff in batch {
            match diff {
                VectorDiff::Append { values } => transaction.append(values),
                VectorDiff::Clear => transaction.clear(),
                VectorDiff::PushFront { value } => transaction.push_front(value),
                VectorDiff::PushBack { value } => transaction.push_back(value),
                VectorDiff::PopFront => drop(transaction.pop_front()),
                VectorDiff::PopBack => drop(transaction.pop_back()),
                VectorDiff::Insert { index, value } => transaction.insert(index, value),
                VectorDiff::Set { index, value } => drop(transaction.set(index, value)),
                VectorDiff::Remove { index } => drop(transaction.remove(index)),
                VectorDiff::Truncate { length } => transaction.truncate(length),
                VectorDiff::Reset { values } => {
                    transaction.clear();
                    transaction.append(values);
                }
            }
        }
        transaction.commit();
    }

    pub(crate) fn snapshot(&self) -> Vector<T> {
        self.lock().clone()
    }

    // a panic while the lock is held cannot leave the rows half-written: each batch is a
    // transaction, committed whole.
    fn lock(&self) -> std::sync::MutexGuard<'_, ObservableVector<T>> {
        self.rows.lock().unwrap_or_else(PoisonError::into_inner)
    }
}
