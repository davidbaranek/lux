//! The session between the SDK and the platform's secret store: what the SDK restores from, and
//! the tokens it hands back each time it refreshes them.

use std::sync::Arc;

use lux_core::ids::{DeviceId, UserId};
use lux_core::ports::{BackendError, SecretStore, SecretStoreError, SessionSecrets};
use matrix_sdk::authentication::matrix::MatrixSession;
use matrix_sdk::authentication::oauth::{ClientId, OAuthSession, UserSession};
use matrix_sdk::sliding_sync::Version;
use matrix_sdk::{AuthSession, Client, SessionMeta, SessionTokens};

use matrix_sdk::SessionChange;
use tokio::sync::{broadcast, watch};
use tokio::task::JoinHandle;

use crate::errors::from_sdk;
use crate::store::Process;

/// The SDK's session for `secrets`.
pub(crate) fn auth_session(secrets: &SessionSecrets) -> Result<AuthSession, BackendError> {
    let user_id = secrets
        .user_id
        .as_str()
        .try_into()
        .map_err(|error| SecretStoreError::Invalid {
            reason: format!("user id: {error}"),
        })?;
    let meta = SessionMeta {
        user_id,
        device_id: secrets.device_id.as_str().into(),
    };
    let tokens = SessionTokens {
        access_token: secrets.access_token.clone(),
        refresh_token: secrets.refresh_token.clone(),
    };
    Ok(match &secrets.oauth_client_id {
        Some(client_id) => AuthSession::OAuth(Box::new(OAuthSession {
            client_id: ClientId::new(client_id.clone()),
            user: UserSession { meta, tokens },
        })),
        None => AuthSession::Matrix(MatrixSession { meta, tokens }),
    })
}

/// The client's current session, as the platform keeps it; `None` before it signed in.
pub(crate) fn secrets_of(client: &Client) -> Option<SessionSecrets> {
    let session = client.session()?;
    let oauth_client_id = match &session {
        AuthSession::OAuth(oauth) => Some(oauth.client_id.as_str().to_owned()),
        _ => None,
    };
    let meta = session.meta();
    Some(SessionSecrets {
        user_id: UserId::from(meta.user_id.as_str()),
        device_id: DeviceId::from(meta.device_id.as_str()),
        homeserver_url: client.homeserver().to_string(),
        access_token: session.access_token().to_owned(),
        refresh_token: session.get_refresh_token().map(str::to_owned),
        oauth_client_id,
        native_sliding_sync: matches!(client.sliding_sync_version(), Version::Native),
    })
}

/// Keeps the client's current session on the platform.
pub(crate) fn save(client: &Client, secrets: &dyn SecretStore) -> Result<(), BackendError> {
    let current = secrets_of(client).ok_or(BackendError::SignedOut)?;
    secrets.save(&current)?;
    Ok(())
}

/// Ties the client to the platform's secret store, before it restores or signs in: the store's
/// other process (the notification extension) may refresh the tokens too, so the client reads
/// them back from the platform under the cross-process lock, and keeps each new pair there.
pub(crate) async fn connect(
    client: &Client,
    secrets: Arc<dyn SecretStore>,
    process: Process,
) -> Result<(), BackendError> {
    client
        .oauth()
        .enable_cross_process_refresh_lock(process.lock_holder().to_owned())
        .await
        .map_err(BackendError::store)?;
    let reload = Arc::clone(&secrets);
    client
        .set_session_callbacks(
            Box::new(move |_client| {
                let kept = reload.load()?.ok_or(BackendError::SignedOut)?;
                Ok(SessionTokens {
                    access_token: kept.access_token,
                    refresh_token: kept.refresh_token,
                })
            }),
            Box::new(move |client| Ok(save(&client, secrets.as_ref())?)),
        )
        .map_err(from_sdk)
}

/// Whether the server has ended the session: the SDK says so once a refused token cannot be
/// refreshed. Followed from the account's start, so an end that comes before anyone waits for
/// it is not missed.
pub(crate) struct SessionEnd {
    ended: watch::Receiver<bool>,
    task: JoinHandle<()>,
}

impl SessionEnd {
    pub(crate) fn follow(client: &Client) -> Self {
        let mut changes = client.subscribe_to_session_changes();
        let (end, ended) = watch::channel(false);
        let task = tokio::spawn(async move {
            loop {
                match changes.recv().await {
                    Ok(SessionChange::UnknownToken(_)) => {
                        end.send_replace(true);
                        return;
                    }
                    Ok(SessionChange::TokensRefreshed) | Err(broadcast::error::RecvError::Lagged(_)) => {}
                    Err(broadcast::error::RecvError::Closed) => return,
                }
            }
        });
        Self { ended, task }
    }

    /// Completes once the session has ended; never while it lives.
    pub(crate) fn ended(&self) -> impl Future<Output = ()> + Send + 'static {
        let mut ended = self.ended.clone();
        async move {
            if ended.wait_for(|ended| *ended).await.is_err() {
                // the account closed with the session alive.
                std::future::pending::<()>().await;
            }
        }
    }
}

impl Drop for SessionEnd {
    fn drop(&mut self) {
        self.task.abort();
    }
}

#[cfg(test)]
mod tests {
    use lux_core::ports::SessionSecrets;
    use matrix_sdk::AuthSession;

    use super::auth_session;

    fn secrets(oauth_client_id: Option<&str>) -> SessionSecrets {
        SessionSecrets {
            user_id: "@anna:example.org".into(),
            device_id: "ABCDEFGHIJ".into(),
            homeserver_url: "https://example.org/".to_owned(),
            access_token: "access".to_owned(),
            refresh_token: Some("refresh".to_owned()),
            oauth_client_id: oauth_client_id.map(str::to_owned),
            native_sliding_sync: true,
        }
    }

    #[test]
    fn a_password_session_restores_as_matrix() {
        let session = auth_session(&secrets(None)).unwrap();
        assert!(matches!(session, AuthSession::Matrix(_)));
        assert_eq!(session.meta().device_id.as_str(), "ABCDEFGHIJ");
    }

    #[test]
    fn an_oauth_session_keeps_its_client() {
        let AuthSession::OAuth(session) = auth_session(&secrets(Some("01CLIENT"))).unwrap() else {
            panic!("not an oauth session");
        };
        assert_eq!(session.client_id.as_str(), "01CLIENT");
        assert_eq!(session.user.tokens.refresh_token.as_deref(), Some("refresh"));
    }

    #[test]
    fn a_bad_user_id_is_refused() {
        let mut bad = secrets(None);
        bad.user_id = "anna".into();
        assert!(auth_session(&bad).is_err());
    }
}
