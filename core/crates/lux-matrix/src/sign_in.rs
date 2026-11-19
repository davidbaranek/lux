//! Opening an account in its folder: the kept session, a password, or the server's page.

use std::sync::Arc;

use lux_core::ports::{BackendError, LoginMethods, OAuthClient, OAuthSignIn, SecretStore, SessionSecrets, SignIn};
use lux_store::Store;
use matrix_sdk::authentication::oauth::registration::{ApplicationType, ClientMetadata, Localized, OAuthGrantType};
use matrix_sdk::authentication::oauth::{ClientRegistrationData, OAuthAuthorizationData, OAuthError};
use matrix_sdk::ruma::api::client::session::get_login_types::v3::LoginType;
use matrix_sdk::ruma::serde::Raw;
use matrix_sdk::sliding_sync::VersionBuilder;
use matrix_sdk::utils::UrlOrQuery;
use matrix_sdk::{Client, reqwest::Url};
use tracing::warn;

use crate::account::MatrixAccount;
use crate::errors::{from_build, from_http, from_sdk};
use crate::session;
use crate::store::{self, Process, StoreFolder};

/// Opens the account kept in one folder, or signs a new one in there; the platform keeps its
/// session in `secrets`.
#[derive(Clone)]
pub struct MatrixSignIn {
    folder: StoreFolder,
    secrets: Arc<dyn SecretStore>,
    store: Option<Arc<Store>>,
    /// The app is in front as the account opens: its sync starts. Opened in the background (the
    /// system launched the app for a background task), it waits for the front.
    in_front: bool,
}

impl MatrixSignIn {
    /// The account of `folder`, its session kept in `secrets`.
    #[must_use]
    pub fn new(folder: StoreFolder, secrets: Arc<dyn SecretStore>) -> Self {
        Self {
            folder,
            secrets,
            store: None,
            in_front: true,
        }
    }

    /// The account's encrypted store: the account keeps its chat list there, for the next launch
    /// to draw before the account opens, and closes it in the background with its own.
    #[must_use]
    pub fn with_store(mut self, store: Arc<Store>) -> Self {
        self.store = Some(store);
        self
    }

    /// The app is in the background as the account opens (the system launched it for a
    /// background task): the stores open, the sync waits until the app comes to the front.
    #[must_use]
    pub fn in_background(mut self) -> Self {
        self.in_front = false;
        self
    }

    /// The account over `client`, signed in or restored in the folder; the other folders beside
    /// it go, now that the live one is certain.
    async fn opened(&self, client: Client) -> Result<MatrixAccount, BackendError> {
        let account = MatrixAccount::open(client, self.store.clone(), self.in_front).await?;
        store::remove_others(&self.folder).await;
        Ok(account)
    }

    /// A client of the folder for a new sign-in at `server`, tied to the secret store.
    async fn new_client(&self, server: &str) -> Result<Client, BackendError> {
        // a new account's stores are encrypted from the start.
        let key = store::new_store_key(self.secrets.as_ref())?;
        let client = self
            .folder
            .client_builder(VersionBuilder::DiscoverNative, Process::App, &key)
            .server_name_or_homeserver_url(server)
            .build()
            .await
            .map_err(from_build)?;
        session::connect(&client, Arc::clone(&self.secrets), Process::App).await?;
        Ok(client)
    }
}

/// A client of `folder` with the session kept in `secrets`, for `process`, without the network;
/// `None` when no session is kept. A session is opened only over its own encrypted store: the
/// app forgets an account whose store cannot be opened (`None`: signed out), the notification
/// extension fails.
///
/// # Errors
/// [`BackendError::StoreUnusable`] in the extension, when the store cannot be opened; others
/// when the folder or the secret store cannot be read, or the account cannot be forgotten.
pub(crate) async fn restored_client(
    folder: &StoreFolder,
    secrets: &Arc<dyn SecretStore>,
    process: Process,
) -> Result<Option<Client>, BackendError> {
    let Some(kept) = secrets.load()? else {
        return Ok(None);
    };
    match open_kept(folder, secrets, &kept, process).await {
        Err(BackendError::StoreUnusable(reason)) if process == Process::App => {
            warn!(%reason, "the account's store cannot be opened: the account is forgotten");
            store::forget(folder, secrets.as_ref())?;
            Ok(None)
        }
        opened => opened.map(Some),
    }
}

/// A client of `folder` with the session `kept`, over its encrypted store.
async fn open_kept(
    folder: &StoreFolder,
    secrets: &Arc<dyn SecretStore>,
    kept: &SessionSecrets,
    process: Process,
) -> Result<Client, BackendError> {
    let key = store::kept_store_key(folder, secrets.as_ref())?;
    let sliding_sync = if kept.native_sliding_sync {
        VersionBuilder::Native
    } else {
        VersionBuilder::None
    };
    let client = folder
        .client_builder(sliding_sync, process, &key)
        .homeserver_url(&kept.homeserver_url)
        .build()
        .await
        .map_err(from_build)?;
    session::connect(&client, Arc::clone(secrets), process).await?;
    client
        .restore_session(session::auth_session(kept)?)
        .await
        .map_err(from_sdk)?;
    Ok(client)
}

/// How `server` (a server name, `matrix.org`, or a URL) lets the app sign in, asked by a client
/// with no store.
///
/// # Errors
/// When no Matrix server answers there.
pub async fn login_methods(server: &str) -> Result<LoginMethods, BackendError> {
    let client = Client::builder()
        .server_name_or_homeserver_url(server)
        .build()
        .await
        .map_err(from_build)?;
    let password = client
        .matrix_auth()
        .get_login_types()
        .await
        .map_err(from_http)?
        .flows
        .iter()
        .any(|flow| matches!(flow, LoginType::Password(_)));
    let oauth = client.oauth().server_metadata().await.is_ok();
    Ok(LoginMethods { password, oauth })
}

impl SignIn for MatrixSignIn {
    type Account = MatrixAccount;
    type OAuth = MatrixOAuth;

    async fn login_methods(&self, server: &str) -> Result<LoginMethods, BackendError> {
        login_methods(server).await
    }

    async fn restore(&self) -> Result<Option<MatrixAccount>, BackendError> {
        let Some(client) = restored_client(&self.folder, &self.secrets, Process::App).await? else {
            return Ok(None);
        };
        self.opened(client).await.map(Some)
    }

    async fn sign_in_with_password(
        &self,
        server: &str,
        user: &str,
        password: &str,
        device_name: &str,
    ) -> Result<MatrixAccount, BackendError> {
        let client = self.new_client(server).await?;
        client
            .matrix_auth()
            .login_username(user, password)
            .initial_device_display_name(device_name)
            .await
            .map_err(from_sdk)?;
        session::save(&client, self.secrets.as_ref())?;
        self.opened(client).await
    }

    async fn begin_oauth(&self, server: &str, app: &OAuthClient) -> Result<MatrixOAuth, BackendError> {
        let client = self.new_client(server).await?;
        let redirect = Url::parse(&app.redirect_uri).map_err(|_| BackendError::InvalidCallback)?;
        let registration = registration(app, &redirect)?;
        let authorization = client
            .oauth()
            .login(redirect, None, Some(registration), None)
            .build()
            .await
            .map_err(from_oauth)?;
        Ok(MatrixOAuth {
            sign_in: self.clone(),
            client,
            authorization,
        })
    }
}

/// The app's registration with the server's account service: a native app, signing in with an
/// authorization code sent back to its custom scheme.
fn registration(app: &OAuthClient, redirect: &Url) -> Result<ClientRegistrationData, BackendError> {
    let client_uri = Url::parse(&app.client_uri).map_err(|_| BackendError::InvalidCallback)?;
    let metadata = ClientMetadata {
        client_name: Some(Localized::new(app.name.clone(), [])),
        ..ClientMetadata::new(
            ApplicationType::Native,
            vec![OAuthGrantType::AuthorizationCode {
                redirect_uris: vec![redirect.clone()],
            }],
            Localized::new(client_uri, []),
        )
    };
    let metadata = Raw::new(&metadata).map_err(BackendError::refused)?;
    Ok(ClientRegistrationData::new(metadata))
}

fn from_oauth(error: OAuthError) -> BackendError {
    match error {
        OAuthError::Discovery(_) => BackendError::UnsupportedLogin,
        other => BackendError::refused(other),
    }
}

/// A sign-in on the server's page, between showing it and its callback.
pub struct MatrixOAuth {
    sign_in: MatrixSignIn,
    client: Client,
    authorization: OAuthAuthorizationData,
}

impl OAuthSignIn for MatrixOAuth {
    type Account = MatrixAccount;

    fn url(&self) -> &str {
        self.authorization.url.as_str()
    }

    async fn finish(&self, callback_url: &str) -> Result<MatrixAccount, BackendError> {
        let callback = Url::parse(callback_url).map_err(|_| BackendError::InvalidCallback)?;
        self.client
            .oauth()
            .finish_login(UrlOrQuery::Url(callback))
            .await
            .map_err(from_sdk)?;
        session::save(&self.client, self.sign_in.secrets.as_ref())?;
        self.sign_in.opened(self.client.clone()).await
    }

    async fn cancel(&self) {
        self.client.oauth().abort_login(&self.authorization.state).await;
    }
}
