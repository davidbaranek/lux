//! The timeline's errors as the ports' [`BackendError`]s.

use lux_core::ports::BackendError;
use matrix_sdk_ui::timeline::Error;

use crate::errors::from_sdk;

/// A timeline's error.
pub(crate) fn from_timeline(error: Error) -> BackendError {
    match error {
        Error::EventNotInTimeline(_) => BackendError::UnknownMessage,
        Error::Sdk(error) => from_sdk(error),
        Error::EditError(_) | Error::UnsupportedEvent => BackendError::NotAllowed,
        Error::InvalidAttachmentData | Error::InvalidAttachmentFileName => BackendError::file(error),
        Error::EventCacheIsDisabled | Error::EventCacheError(_) | Error::UnknownEncryptionState => {
            BackendError::store(error)
        }
        other => BackendError::refused(other),
    }
}

/// A room's send queue's error.
pub(crate) fn from_send_queue(error: matrix_sdk::send_queue::RoomSendQueueError) -> BackendError {
    BackendError::refused(error)
}
