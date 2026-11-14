//! The SDK's errors as the ports' [`BackendError`]s, their causes kept.

use lux_core::ports::{BackendError, NetworkFailure, UnusableStore};
use matrix_sdk::ruma::api::error::ErrorKind;
use matrix_sdk::{ClientBuildError, HttpError};
use matrix_sdk_sqlite::OpenStoreError;

/// An HTTP error: the server's refusal, or the network.
pub(crate) fn from_http(error: HttpError) -> BackendError {
    match error.client_api_error_kind() {
        Some(ErrorKind::Forbidden) => return BackendError::WrongCredentials,
        Some(ErrorKind::UnknownToken(_)) => return BackendError::SessionEnded,
        Some(_) | None => {}
    }
    if let HttpError::Reqwest(reqwest) = &error {
        let kind = if reqwest.is_timeout() {
            NetworkFailure::Timeout
        } else if reqwest.is_connect() {
            NetworkFailure::Offline
        } else {
            NetworkFailure::Other
        };
        return BackendError::Network {
            kind,
            source: error.into(),
        };
    }
    let api = error.as_client_api_error();
    BackendError::Server {
        status: api.map(|api| api.status_code.as_u16()),
        errcode: api
            .and_then(|api| api.error_kind())
            .map(|kind| kind.errcode().to_string()),
        source: error.into(),
    }
}

/// Any of the SDK's errors.
pub(crate) fn from_sdk(error: matrix_sdk::Error) -> BackendError {
    match error {
        matrix_sdk::Error::Http(http) => from_http(*http),
        matrix_sdk::Error::AuthenticationRequired => BackendError::SignedOut,
        matrix_sdk::Error::CryptoStoreError(store) => from_crypto_store(*store),
        other => BackendError::store(other),
    }
}

fn from_crypto_store(error: matrix_sdk::encryption::CryptoStoreError) -> BackendError {
    match error {
        matrix_sdk::encryption::CryptoStoreError::MismatchedAccount { .. } => BackendError::StoreMismatch,
        other => BackendError::store(other),
    }
}

/// An error building the client: mostly, no server at the address, or a store its key does not
/// open (its cipher cannot be decrypted with it).
pub(crate) fn from_build(error: ClientBuildError) -> BackendError {
    match error {
        ClientBuildError::Http(http) => from_http(http),
        ClientBuildError::AutoDiscovery(_) | ClientBuildError::Url(_) | ClientBuildError::InvalidServerName => {
            BackendError::ServerNotFound
        }
        ClientBuildError::SqliteStore(OpenStoreError::InitCipher(_)) => {
            BackendError::StoreUnusable(UnusableStore::WrongKey)
        }
        other => BackendError::store(other),
    }
}
