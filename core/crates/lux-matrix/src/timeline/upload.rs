//! One upload followed through its room's send queue: the SDK's updates for its transaction
//! (`RoomSendQueueUpdate`), as the states the apps show.

use futures_util::stream;
use lux_core::message::SendState;
use lux_core::ports::UploadStream;
use matrix_sdk::ruma::OwnedTransactionId;
use matrix_sdk::send_queue::{LocalEchoContent, RoomSendQueue, RoomSendQueueUpdate};
use tokio::sync::broadcast::Receiver;
use tokio::sync::broadcast::error::RecvError;

use super::items::fraction;

/// The upload of the event `transaction` in `queue`, from `updates` (subscribed before it was
/// queued): how much of its media has gone, then sent or failed. It ends there, when the event
/// is discarded, or when the queue closes.
pub(crate) fn states(
    queue: RoomSendQueue,
    transaction: OwnedTransactionId,
    updates: Receiver<RoomSendQueueUpdate>,
) -> UploadStream {
    Box::pin(stream::unfold(Some(updates), move |updates| {
        let (queue, transaction) = (queue.clone(), transaction.clone());
        async move {
            let mut updates = updates?;
            loop {
                let state = match updates.recv().await {
                    Ok(update) => match of(&update, &transaction) {
                        Some(Next::State(state)) => state,
                        Some(Next::Last(state)) => return Some((state, None)),
                        Some(Next::Gone) => return None,
                        None => continue,
                    },
                    // updates went by unseen: the queue says where the event is now.
                    Err(RecvError::Lagged(_)) => {
                        let (echoes, newer) = queue.subscribe().await.ok()?;
                        updates = newer;
                        let echo = echoes.iter().find(|echo| echo.transaction_id == transaction);
                        match echo.map(|echo| &echo.content) {
                            // no longer queued: it went.
                            None => return Some((SendState::Sent, None)),
                            Some(LocalEchoContent::Event {
                                send_error: Some(_), ..
                            }) => {
                                return Some((SendState::Failed, None));
                            }
                            // a passing failure turned the queue off: it waits for a retry.
                            Some(_) if !queue.is_enabled() => return Some((SendState::Failed, None)),
                            Some(_) => continue,
                        }
                    }
                    Err(RecvError::Closed) => return None,
                };
                return Some((state, Some(updates)));
            }
        }
    }))
}

/// What an update means for the upload.
#[derive(Debug, PartialEq)]
enum Next {
    /// It goes on.
    State(SendState),
    /// It ended so.
    Last(SendState),
    /// It was discarded.
    Gone,
}

/// What `update` means for the upload of `transaction`; `None` when it is another's.
fn of(update: &RoomSendQueueUpdate, transaction: &OwnedTransactionId) -> Option<Next> {
    match update {
        RoomSendQueueUpdate::MediaUpload {
            related_to, progress, ..
        } if related_to == transaction => Some(Next::State(SendState::Sending {
            upload: Some(fraction(progress.current, progress.total)),
        })),
        RoomSendQueueUpdate::SentEvent { transaction_id, .. } if transaction_id == transaction => {
            Some(Next::Last(SendState::Sent))
        }
        RoomSendQueueUpdate::SendError { transaction_id, .. } if transaction_id == transaction => {
            Some(Next::Last(SendState::Failed))
        }
        RoomSendQueueUpdate::CancelledLocalEvent { transaction_id } if transaction_id == transaction => {
            Some(Next::Gone)
        }
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use matrix_sdk::ruma::{TransactionId, event_id};
    use matrix_sdk::send_queue::AbstractProgress;

    use super::*;

    #[test]
    fn only_its_own_transactions_updates_count() {
        let own = TransactionId::new();
        let other = TransactionId::new();
        let media = |related_to: &OwnedTransactionId| RoomSendQueueUpdate::MediaUpload {
            related_to: related_to.clone(),
            file: None,
            index: 0,
            progress: AbstractProgress {
                current: 25,
                total: 100,
            },
        };
        assert_eq!(
            of(&media(&own), &own),
            Some(Next::State(SendState::Sending { upload: Some(0.25) }))
        );
        assert_eq!(of(&media(&other), &own), None);
        let sent = RoomSendQueueUpdate::SentEvent {
            transaction_id: own.clone(),
            event_id: event_id!("$sent").to_owned(),
        };
        assert_eq!(of(&sent, &own), Some(Next::Last(SendState::Sent)));
        assert_eq!(of(&sent, &other), None);
        let cancelled = RoomSendQueueUpdate::CancelledLocalEvent {
            transaction_id: own.clone(),
        };
        assert_eq!(of(&cancelled, &own), Some(Next::Gone));
    }
}
