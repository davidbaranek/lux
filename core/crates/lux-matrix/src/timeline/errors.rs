//! The timeline's errors as the ports' [`BackendError`]s.

use lux_core::ports::BackendError;
use matrix_sdk::event_cache::EventCacheError;
use matrix_sdk::paginators::PaginatorError;
use matrix_sdk::ruma::api::error::ErrorKind;
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

/// The error opening a timeline around a message: the server has no such message, or will not
/// show it to the account, as the port says; any other as [`from_timeline`] has it.
pub(crate) fn from_focus(error: Error) -> BackendError {
    if let Error::EventCacheError(EventCacheError::InitialPaginationError(paginator)) = &error {
        match paginator {
            PaginatorError::EventNotFound(_) => return BackendError::UnknownMessage,
            PaginatorError::SdkError(sdk) => {
                if let matrix_sdk::Error::Http(http) = sdk.as_ref() {
                    match http.client_api_error_kind() {
                        Some(ErrorKind::NotFound) => return BackendError::UnknownMessage,
                        Some(ErrorKind::Forbidden) => return BackendError::NotAllowed,
                        Some(_) | None => {}
                    }
                }
            }
            PaginatorError::InvalidPreviousState { .. } => {}
        }
        return BackendError::refused(error);
    }
    from_timeline(error)
}

/// A room's send queue's error.
pub(crate) fn from_send_queue(error: matrix_sdk::send_queue::RoomSendQueueError) -> BackendError {
    BackendError::refused(error)
}
