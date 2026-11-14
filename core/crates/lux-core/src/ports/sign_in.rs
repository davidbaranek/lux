//! Opening an account: the kept session at launch, or a new sign-in.

use std::future::Future;

use super::{BackendError, ChatAccount};

/// How a server lets the app sign in.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct LoginMethods {
    /// With a user name and password, in the app.
    pub password: bool,
    /// On the server's own page, in a browser (OAuth 2.0, MSC3861).
    pub oauth: bool,
}

/// How the app introduces itself to a server's account service.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct OAuthClient {
    /// Its name, shown on the server's page.
    pub name: String,
    /// Where the page sends the browser back to: a custom scheme whose name is the reversed host
    /// of `client_uri` (`com.example.app:/callback`).
    pub redirect_uri: String,
    /// The app's web page.
    pub client_uri: String,
}

/// Opens one account's session: the one kept on this device, or a new one.
pub trait SignIn: Send + Sync {
    /// The account it opens.
    type Account: ChatAccount;
    /// A sign-in on the server's page, between showing it and its callback.
    type OAuth: OAuthSignIn<Account = Self::Account>;

    /// How `server` (a server name, `matrix.org`, or a URL) lets the app sign in.
    fn login_methods(&self, server: &str) -> impl Future<Output = Result<LoginMethods, BackendError>> + Send;

    /// Opens the kept session; `None` when none is kept.
    fn restore(&self) -> impl Future<Output = Result<Option<Self::Account>, BackendError>> + Send;

    /// Signs in with a user name (`anna`, `@anna:server`) and password; the platform keeps the
    /// new session.
    fn sign_in_with_password(
        &self,
        server: &str,
        user: &str,
        password: &str,
        device_name: &str,
    ) -> impl Future<Output = Result<Self::Account, BackendError>> + Send;

    /// Starts a sign-in on the server's page.
    fn begin_oauth(
        &self,
        server: &str,
        client: &OAuthClient,
    ) -> impl Future<Output = Result<Self::OAuth, BackendError>> + Send;
}

/// A sign-in on the server's page: the platform shows `url` in a browser, and hands back the URL
/// the page called back.
pub trait OAuthSignIn: Send + Sync {
    /// The account it opens.
    type Account: ChatAccount;

    /// The page to show.
    fn url(&self) -> &str;

    /// Finishes with the callback URL and opens the account; the platform keeps the session.
    fn finish(&self, callback_url: &str) -> impl Future<Output = Result<Self::Account, BackendError>> + Send;

    /// The user closed the page: the server forgets the attempt.
    fn cancel(&self) -> impl Future<Output = ()> + Send;
}
