//! The account as the apps see it: one object over a Matrix account (`lux-matrix`) or the demo's
//! made-up one (`lux_core::demo`), with async methods; its chats read whole when asked; and the
//! platform's session keeper.

use std::sync::Arc;
use std::time::SystemTime;

use eyeball_im::Vector;
use futures_util::{FutureExt, StreamExt};
use lux_core::chat::{Chat, Request};
use lux_core::demo::{DemoAccount, DemoConfig, DemoEncryption};
use lux_core::ids::RoomId;
use lux_core::organizer::LabelError;
use lux_core::ports::{
    BackendError, ChatAccount, NetworkFailure, OAuthClient, OAuthSignIn, SecretStore, SecretStoreError, SessionSecrets,
    SignIn, StoreKey,
};
use lux_core::search::find_chats;
use lux_matrix::{MatrixAccount, MatrixOAuth, MatrixSignIn, StoreFolder};
use tokio::task::JoinHandle;

use crate::chat::{CoreFolder, CorePreview};
use crate::runtime;
use crate::store::CoreStore;

// MARK: the session keeper

/// A session as the platform keeps it (in the Keychain).
#[derive(Clone, uniffi::Record)]
pub struct CoreKeptSession {
    /// The account (`@anna:server`).
    pub user_id: String,
    /// This device.
    pub device_id: String,
    /// The server's client API.
    pub homeserver_url: String,
    /// The access token.
    pub access_token: String,
    /// The token that renews it.
    pub refresh_token: Option<String>,
    /// The app's registration with the server's account service, for a session signed in there
    /// (OAuth); `None` for a password sign-in.
    pub oauth_client_id: Option<String>,
    /// The server syncs with simplified sliding sync.
    pub native_sliding_sync: bool,
}

/// Why the platform could not keep or give the session.
#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum CoreSessionKeeperError {
    /// The platform's store is locked or refused.
    #[error("the session keeper is unavailable: {reason}")]
    Unavailable {
        /// What the platform said.
        reason: String,
    },
    /// What it keeps cannot be read as a session.
    #[error("the kept session cannot be read: {reason}")]
    Invalid {
        /// What was wrong.
        reason: String,
    },
}

impl From<uniffi::UnexpectedUniFFICallbackError> for CoreSessionKeeperError {
    fn from(error: uniffi::UnexpectedUniFFICallbackError) -> Self {
        Self::Unavailable { reason: error.reason }
    }
}

/// Where the platform keeps one account's session: the Keychain, on Apple's systems.
#[uniffi::export(with_foreign)]
pub trait CoreSessionKeeper: Send + Sync {
    /// The kept session, or none.
    ///
    /// # Errors
    /// When the platform's store cannot be read.
    fn load(&self) -> Result<Option<CoreKeptSession>, CoreSessionKeeperError>;

    /// Keeps `session` in place of what was kept.
    ///
    /// # Errors
    /// When the platform's store cannot be written.
    fn save(&self, session: CoreKeptSession) -> Result<(), CoreSessionKeeperError>;

    /// The key of the account's stores (32 bytes), kept beside the session; none when none is
    /// kept.
    ///
    /// # Errors
    /// When the platform's store cannot be read.
    fn load_store_key(&self) -> Result<Option<Vec<u8>>, CoreSessionKeeperError>;

    /// Keeps `key` as the key of the account's stores, in place of any other, readable wherever
    /// the session is (the notification extension).
    ///
    /// # Errors
    /// When the platform's store cannot be written.
    fn save_store_key(&self, key: Vec<u8>) -> Result<(), CoreSessionKeeperError>;

    /// Deletes the session, the store key and the account's other secrets: the account is
    /// gone from this device.
    ///
    /// # Errors
    /// When the platform's store cannot be written.
    fn delete(&self) -> Result<(), CoreSessionKeeperError>;
}

/// The platform's keeper as the core's secret store.
pub(crate) struct Keeper(pub(crate) Arc<dyn CoreSessionKeeper>);

impl SecretStore for Keeper {
    fn load(&self) -> Result<Option<SessionSecrets>, SecretStoreError> {
        let Some(kept) = self.0.load().map_err(SecretStoreError::from_keeper)? else {
            return Ok(None);
        };
        Ok(Some(SessionSecrets {
            user_id: kept.user_id.into(),
            device_id: kept.device_id.into(),
            homeserver_url: kept.homeserver_url,
            access_token: kept.access_token,
            refresh_token: kept.refresh_token,
            oauth_client_id: kept.oauth_client_id,
            native_sliding_sync: kept.native_sliding_sync,
        }))
    }

    fn save(&self, secrets: &SessionSecrets) -> Result<(), SecretStoreError> {
        self.0
            .save(CoreKeptSession {
                user_id: secrets.user_id.to_string(),
                device_id: secrets.device_id.to_string(),
                homeserver_url: secrets.homeserver_url.clone(),
                access_token: secrets.access_token.clone(),
                refresh_token: secrets.refresh_token.clone(),
                oauth_client_id: secrets.oauth_client_id.clone(),
                native_sliding_sync: secrets.native_sliding_sync,
            })
            .map_err(SecretStoreError::from_keeper)
    }

    fn store_key(&self) -> Result<Option<StoreKey>, SecretStoreError> {
        let Some(mut bytes) = self.0.load_store_key().map_err(SecretStoreError::from_keeper)? else {
            return Ok(None);
        };
        let key = StoreKey::from_bytes(&bytes);
        bytes.fill(0);
        key.map(Some)
    }

    fn save_store_key(&self, key: &StoreKey) -> Result<(), SecretStoreError> {
        self.0
            .save_store_key(key.as_bytes().to_vec())
            .map_err(SecretStoreError::from_keeper)
    }

    fn delete(&self) -> Result<(), SecretStoreError> {
        self.0.delete().map_err(SecretStoreError::from_keeper)
    }
}

trait FromKeeper {
    fn from_keeper(error: CoreSessionKeeperError) -> Self;
}

impl FromKeeper for SecretStoreError {
    fn from_keeper(error: CoreSessionKeeperError) -> Self {
        match error {
            CoreSessionKeeperError::Unavailable { reason } => Self::Unavailable { reason },
            CoreSessionKeeperError::Invalid { reason } => Self::Invalid { reason },
        }
    }
}

// MARK: errors

/// Why an account's action failed. The apps word each case in the user's language; the text
/// here, and what a case carries, are for the log.
#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum CoreAccountError {
    /// No session is kept.
    #[error("no account is signed in")]
    SignedOut,
    /// The session's store cannot be opened (missing, not encrypted, or its key missing or
    /// wrong): the session is not opened over it.
    #[error("the account's store cannot be opened: {reason}")]
    StoreUnusable {
        /// Why.
        reason: String,
    },
    /// The store holds another session.
    #[error("the account's store belongs to another session")]
    StoreMismatch,
    /// No Matrix server answers at the address.
    #[error("no Matrix server answers at this address")]
    ServerNotFound,
    /// The server does not offer this way of signing in.
    #[error("the server does not offer this way of signing in")]
    UnsupportedLogin,
    /// The user name or password is wrong.
    #[error("the user name or password is wrong")]
    WrongCredentials,
    /// The sign-in's callback is not the one it waits for.
    #[error("the sign-in's callback is not valid")]
    InvalidCallback,
    /// The server no longer knows the session.
    #[error("the session has ended")]
    SessionEnded,
    /// The chat is not in the account.
    #[error("the chat {chat} is not in the account")]
    NoSuchChat {
        /// The chat or room.
        chat: String,
    },
    /// The contact cannot be written to: no such user, or no login on its network.
    #[error("the contact {contact} cannot be reached")]
    UnknownContact {
        /// The contact.
        contact: String,
    },
    /// A label needs a name.
    #[error("enter a name for the label")]
    LabelNameEmpty,
    /// Another label has the name.
    #[error("a label with that name already exists")]
    LabelNameTaken,
    /// The label was deleted.
    #[error("that label was deleted on another device")]
    LabelGone,
    /// The message cannot be saved.
    #[error("the message cannot be saved")]
    NotSavable,
    /// An encrypted chat cannot send later.
    #[error("an encrypted chat cannot send messages later")]
    EncryptedChat,
    /// The time has passed.
    #[error("the time is past")]
    TimePassed,
    /// The waiting message is gone.
    #[error("the waiting message is gone")]
    NotWaiting,
    /// The recovery key is wrong.
    #[error("the recovery key is wrong")]
    WrongRecoveryKey,
    /// The platform could not keep or give the session.
    #[error("{message}")]
    Secrets {
        /// What went wrong.
        message: String,
    },
    /// The store failed.
    #[error("{message}")]
    Store {
        /// What went wrong.
        message: String,
    },
    /// The server could not be reached.
    #[error("the network failed ({kind:?}): {message}")]
    Network {
        /// How.
        kind: CoreNetworkFailure,
        /// What went wrong.
        message: String,
    },
    /// The server, or a bridge through it, answered with an error.
    #[error("the server refused (status {status:?}, {errcode:?}): {message}")]
    Server {
        /// The HTTP status, when it answered with one.
        status: Option<u16>,
        /// The Matrix error code (`M_FORBIDDEN`, …), when it gave one.
        errcode: Option<String>,
        /// What went wrong.
        message: String,
    },
    /// The message is not in the chat.
    #[error("the message is not in the chat")]
    UnknownMessage,
    /// That cannot be done to the message.
    #[error("this cannot be done to the message")]
    NotAllowed,
    /// A file on the device failed.
    #[error("{message}")]
    File {
        /// What went wrong.
        message: String,
    },
}

impl From<BackendError> for CoreAccountError {
    fn from(error: BackendError) -> Self {
        match error {
            BackendError::SignedOut => Self::SignedOut,
            BackendError::StoreUnusable(reason) => Self::StoreUnusable {
                reason: reason.to_string(),
            },
            BackendError::StoreMismatch => Self::StoreMismatch,
            BackendError::ServerNotFound => Self::ServerNotFound,
            BackendError::UnsupportedLogin => Self::UnsupportedLogin,
            BackendError::WrongCredentials => Self::WrongCredentials,
            BackendError::InvalidCallback => Self::InvalidCallback,
            BackendError::SessionEnded => Self::SessionEnded,
            BackendError::UnknownChat(chat) => Self::NoSuchChat { chat: chat.to_string() },
            BackendError::UnknownContact(contact) => Self::UnknownContact { contact },
            BackendError::Label(LabelError::EmptyName) => Self::LabelNameEmpty,
            BackendError::Label(LabelError::DuplicateName) => Self::LabelNameTaken,
            BackendError::Label(LabelError::NotFound) => Self::LabelGone,
            BackendError::NotSavable => Self::NotSavable,
            BackendError::EncryptedChat => Self::EncryptedChat,
            BackendError::TimePassed => Self::TimePassed,
            BackendError::NotWaiting => Self::NotWaiting,
            BackendError::WrongRecoveryKey => Self::WrongRecoveryKey,
            BackendError::Secrets(error) => Self::Secrets {
                message: error.to_string(),
            },
            BackendError::Store(cause) => Self::Store {
                message: cause.to_string(),
            },
            BackendError::Network { kind, source } => Self::Network {
                kind: kind.into(),
                message: source.to_string(),
            },
            BackendError::Server {
                status,
                errcode,
                source,
            } => Self::Server {
                status,
                errcode,
                message: source.to_string(),
            },
            BackendError::UnknownMessage => Self::UnknownMessage,
            BackendError::NotAllowed => Self::NotAllowed,
            BackendError::File(cause) => Self::File {
                message: cause.to_string(),
            },
        }
    }
}

/// How the network failed.
#[derive(Clone, Copy, Debug, uniffi::Enum)]
pub enum CoreNetworkFailure {
    /// The server did not answer in time.
    Timeout,
    /// No connection to the server could be made.
    Offline,
    /// The connection failed otherwise.
    Other,
}

impl From<NetworkFailure> for CoreNetworkFailure {
    fn from(failure: NetworkFailure) -> Self {
        match failure {
            NetworkFailure::Timeout => Self::Timeout,
            NetworkFailure::Offline => Self::Offline,
            NetworkFailure::Other => Self::Other,
        }
    }
}

// MARK: records

/// One network's room of a merged chat.
#[derive(uniffi::Record)]
pub struct CoreChatRoom {
    /// The room.
    pub id: String,
    /// Its network.
    pub network: String,
}

/// One row of the chat list (`lux_core::chat::Chat`).
#[derive(uniffi::Record)]
pub struct CoreChat {
    /// A room's id, or a merged chat's.
    pub id: String,
    /// Its name.
    pub name: String,
    /// The newest message in one line; none for a chat with none.
    pub preview: Option<CorePreview>,
    /// When the newest message came.
    pub date: Option<SystemTime>,
    /// Unread messages.
    pub unread_count: u32,
    /// Marked unread by hand.
    pub is_marked_unread: bool,
    /// Its notifications are off.
    pub is_muted: bool,
    /// Its network (`"whatsapp"`, `"matrix"`).
    pub network: String,
    /// Its picture (a media URL).
    pub avatar: Option<String>,
    /// A group with no picture: two members' pictures.
    pub member_avatars: Vec<String>,
    /// When to answer it.
    pub reminder: Option<SystemTime>,
    /// More than two people.
    pub is_group: bool,
    /// Its folder.
    pub folder: CoreFolder,
    /// Pinned, at this place among the pinned (lower first).
    pub pinned: Option<f64>,
    /// A merged chat's rooms.
    pub rooms: Vec<CoreChatRoom>,
    /// The room a merged chat writes to.
    pub default_room: Option<String>,
}

impl From<&Chat> for CoreChat {
    /// A shared row, copied for the bindings.
    fn from(chat: &Chat) -> Self {
        Self {
            id: chat.id.to_string(),
            name: chat.name.clone(),
            preview: chat.preview.clone().map(CorePreview::from),
            date: chat.date,
            unread_count: chat.unread_count,
            is_marked_unread: chat.is_marked_unread,
            is_muted: chat.is_muted,
            network: chat.network.as_str().to_owned(),
            avatar: chat.avatar.as_ref().map(ToString::to_string),
            member_avatars: chat.member_avatars.iter().map(ToString::to_string).collect(),
            reminder: chat.reminder,
            is_group: chat.is_group,
            folder: chat.folder.into(),
            pinned: chat.pinned,
            rooms: chat
                .rooms
                .iter()
                .map(|room| CoreChatRoom {
                    id: room.id.to_string(),
                    network: room.network.as_str().to_owned(),
                })
                .collect(),
            default_room: chat.default_room.as_ref().map(ToString::to_string),
        }
    }
}

/// An invitation (`lux_core::chat::Request`).
#[derive(uniffi::Record)]
pub struct CoreRequest {
    /// The room it invites to.
    pub id: String,
    /// The room's or the inviter's name.
    pub name: String,
    /// Its picture (a media URL).
    pub avatar: Option<String>,
    /// Who invited; empty when the invite does not say.
    pub inviter_name: String,
    /// A conversation of two.
    pub is_direct: bool,
}

impl From<&Request> for CoreRequest {
    fn from(request: &Request) -> Self {
        Self {
            id: request.id.to_string(),
            name: request.name.clone(),
            avatar: request.avatar.as_ref().map(ToString::to_string),
            inviter_name: request.inviter_name.clone(),
            is_direct: request.is_direct,
        }
    }
}

/// A list's diff as the bindings carry it: `$name`, of `$row`s made from `$core`s by `$map`
/// (`fn(&$core) -> $row`).
macro_rules! list_diff {
    ($(#[$doc:meta])* $name:ident of $row:ident from $core:ty, $map:expr) => {
        $(#[$doc])*
        #[derive(uniffi::Enum)]
        pub enum $name {
            /// Rows added at the end.
            Append {
                /// The rows.
                values: Vec<$row>,
            },
            /// Every row removed.
            Clear,
            /// A row added at the start.
            PushFront {
                /// The row.
                value: $row,
            },
            /// A row added at the end.
            PushBack {
                /// The row.
                value: $row,
            },
            /// The first row removed.
            PopFront,
            /// The last row removed.
            PopBack,
            /// A row added at `index`.
            Insert {
                /// Where.
                index: u32,
                /// The row.
                value: $row,
            },
            /// The row at `index` replaced.
            Set {
                /// Where.
                index: u32,
                /// The row.
                value: $row,
            },
            /// The row at `index` removed.
            Remove {
                /// Where.
                index: u32,
            },
            /// The rows from `length` on removed.
            Truncate {
                /// How many stay.
                length: u32,
            },
            /// The whole list, in place of what it was.
            Reset {
                /// The rows.
                values: Vec<$row>,
            },
        }

        impl From<VectorDiff<$core>> for $name {
            fn from(diff: VectorDiff<$core>) -> Self {
                use $crate::chat::position as index;
                let row = $map;
                match diff {
                    VectorDiff::Append { values } => Self::Append { values: values.iter().map(&row).collect() },
                    VectorDiff::Clear => Self::Clear,
                    VectorDiff::PushFront { value } => Self::PushFront { value: row(&value) },
                    VectorDiff::PushBack { value } => Self::PushBack { value: row(&value) },
                    VectorDiff::PopFront => Self::PopFront,
                    VectorDiff::PopBack => Self::PopBack,
                    VectorDiff::Insert { index: at, value } => Self::Insert { index: index(at), value: row(&value) },
                    VectorDiff::Set { index: at, value } => Self::Set { index: index(at), value: row(&value) },
                    VectorDiff::Remove { index: at } => Self::Remove { index: index(at) },
                    VectorDiff::Truncate { length } => Self::Truncate { length: index(length) },
                    VectorDiff::Reset { values } => Self::Reset { values: values.iter().map(&row).collect() },
                }
            }
        }
    };
}

pub(crate) use list_diff;

/// How a server lets the app sign in.
#[derive(uniffi::Record)]
pub struct CoreLoginMethods {
    /// With a user name and password.
    pub password: bool,
    /// On the server's page (OAuth).
    pub oauth: bool,
}

// MARK: the objects

/// Opens the account kept in a folder, or signs a new one in there.
#[derive(uniffi::Object)]
pub struct CoreAccountOpener {
    sign_in: MatrixSignIn,
}

#[uniffi::export(async_runtime = "tokio")]
impl CoreAccountOpener {
    /// The account of the folder `folder_name` in `stores` (`…/matrix`, which holds every
    /// account's folder: once this account is open, the others there are deleted), its session
    /// kept by `keeper`; its chat list kept in `store`, the account's encrypted store, when there
    /// is one.
    #[uniffi::constructor]
    #[must_use]
    pub fn new(
        stores: String,
        folder_name: String,
        keeper: Arc<dyn CoreSessionKeeper>,
        store: Option<Arc<CoreStore>>,
    ) -> Arc<Self> {
        let folder = StoreFolder::in_stores(stores, folder_name);
        let sign_in = MatrixSignIn::new(folder, Arc::new(Keeper(keeper)));
        let sign_in = match store {
            Some(store) => sign_in.with_store(Arc::clone(&store.store)),
            None => sign_in,
        };
        Arc::new(Self { sign_in })
    }

    /// Opens the kept session; none when none is kept.
    ///
    /// # Errors
    /// When the session or its store cannot be opened.
    pub async fn restore(&self) -> Result<Option<Arc<CoreAccount>>, CoreAccountError> {
        Ok(self.sign_in.restore().await?.map(CoreAccount::matrix))
    }

    /// Signs in with a user name and password.
    ///
    /// # Errors
    /// When the server refuses, or cannot be reached.
    pub async fn sign_in_with_password(
        &self,
        server: String,
        user: String,
        password: String,
        device_name: String,
    ) -> Result<Arc<CoreAccount>, CoreAccountError> {
        Ok(CoreAccount::matrix(
            self.sign_in
                .sign_in_with_password(&server, &user, &password, &device_name)
                .await?,
        ))
    }

    /// Starts a sign-in on the server's page.
    ///
    /// # Errors
    /// When the server offers none, or cannot be reached.
    pub async fn begin_oauth(
        &self,
        server: String,
        client_name: String,
        redirect_uri: String,
        client_uri: String,
    ) -> Result<Arc<CoreOAuth>, CoreAccountError> {
        let client = OAuthClient {
            name: client_name,
            redirect_uri,
            client_uri,
        };
        let oauth = self.sign_in.begin_oauth(&server, &client).await?;
        Ok(Arc::new(CoreOAuth { oauth }))
    }
}

/// How `server` lets the app sign in, before any account is opened.
///
/// # Errors
/// When no Matrix server answers there.
#[uniffi::export(async_runtime = "tokio")]
pub async fn server_login_methods(server: String) -> Result<CoreLoginMethods, CoreAccountError> {
    let methods = lux_matrix::login_methods(&server).await?;
    Ok(CoreLoginMethods {
        password: methods.password,
        oauth: methods.oauth,
    })
}

/// A sign-in on the server's page.
#[derive(uniffi::Object)]
pub struct CoreOAuth {
    oauth: MatrixOAuth,
}

#[uniffi::export(async_runtime = "tokio")]
impl CoreOAuth {
    /// The page to show.
    #[must_use]
    pub fn url(&self) -> String {
        self.oauth.url().to_owned()
    }

    /// Finishes with the URL the page called back, and opens the account.
    ///
    /// # Errors
    /// When the callback is not valid, or the server refuses.
    pub async fn finish(&self, callback_url: String) -> Result<Arc<CoreAccount>, CoreAccountError> {
        Ok(CoreAccount::matrix(self.oauth.finish(&callback_url).await?))
    }

    /// The user closed the page.
    pub async fn cancel(&self) {
        self.oauth.cancel().await;
    }
}

/// What an account runs on.
pub(crate) enum Backend {
    /// A Matrix account.
    Matrix(Arc<MatrixAccount>),
    /// The demo's made-up account (`-LuxDemo`): the chat list and the threads, no server.
    Demo(Arc<DemoAccount>),
}

/// Evaluates `$body` with `$account` bound to the backend's account, whichever it is: for the
/// ports both implement.
macro_rules! with_account {
    ($backend:expr, $account:ident => $body:expr) => {
        match $backend {
            $crate::account::Backend::Matrix($account) => $body,
            $crate::account::Backend::Demo($account) => $body,
        }
    };
}

pub(crate) use with_account;

/// A signed-in account, or the demo's: the one surface the apps talk to. What only a server
/// does (people, security, push) the demo answers as an account with none would.
#[derive(uniffi::Object)]
pub struct CoreAccount {
    backend: Backend,
}

impl CoreAccount {
    fn matrix(account: MatrixAccount) -> Arc<Self> {
        Arc::new(Self {
            backend: Backend::Matrix(Arc::new(account)),
        })
    }

    pub(crate) fn backend(&self) -> &Backend {
        &self.backend
    }

    /// The Matrix account; the demo cannot do what needs one.
    pub(crate) fn matrix_account(&self) -> Result<&Arc<MatrixAccount>, CoreAccountError> {
        match &self.backend {
            Backend::Matrix(account) => Ok(account),
            Backend::Demo(_) => Err(CoreAccountError::NotAllowed),
        }
    }

    /// The chats as they are now: the list's first batch, a `Reset` of the whole list.
    async fn current_chats(&self) -> Vector<Arc<Chat>> {
        let mut chats = Vector::new();
        let mut stream = with_account!(&self.backend, account => account.chats());
        for diff in stream.next().await.unwrap_or_default() {
            diff.apply(&mut chats);
        }
        chats
    }
}

impl Drop for CoreAccount {
    fn drop(&mut self) {
        // the last reference goes on the runtime: the SDK's client spawns tasks as it closes.
        if let Backend::Matrix(account) = &self.backend {
            let account = Arc::clone(account);
            runtime::handle().spawn(async move { drop(account) });
        }
    }
}

/// Where the demo's encryption starts.
#[derive(Clone, Copy, uniffi::Enum)]
pub enum CoreDemoEncryption {
    /// Verified, with recovery.
    Ready,
    /// A new device that must verify (`-LuxDemoUnverified`).
    Unverified,
    /// A new account without recovery (`-LuxDemoNoRecovery`).
    NoRecovery,
}

/// The demo's made-up account with `rooms` rooms, `messages_per_room` messages in each chat; its
/// encryption starting at `encryption`, and, with `verification_request_after_seconds`, another
/// device asking to verify that long after the app listens.
#[uniffi::export]
#[must_use]
pub fn open_demo(
    rooms: u32,
    messages_per_room: u32,
    encryption: CoreDemoEncryption,
    verification_request_after_seconds: Option<u32>,
) -> Arc<CoreAccount> {
    let config = DemoConfig {
        messages_per_room: usize::try_from(messages_per_room).unwrap_or(usize::MAX),
        encryption: match encryption {
            CoreDemoEncryption::Ready => DemoEncryption::Ready,
            CoreDemoEncryption::Unverified => DemoEncryption::Unverified,
            CoreDemoEncryption::NoRecovery => DemoEncryption::NoRecovery,
        },
        verification_request_after: verification_request_after_seconds
            .map(|seconds| std::time::Duration::from_secs(seconds.into())),
        ..DemoConfig::new(usize::try_from(rooms).unwrap_or(usize::MAX))
    };
    Arc::new(CoreAccount {
        backend: Backend::Demo(Arc::new(DemoAccount::new(config))),
    })
}

#[uniffi::export(async_runtime = "tokio")]
impl CoreAccount {
    /// The chats, merged ones folded, the most recent first: what the chat list shows of them
    /// before its places and filters.
    pub async fn chats(&self) -> Vec<CoreChat> {
        self.current_chats()
            .await
            .iter()
            .map(|chat| CoreChat::from(chat.as_ref()))
            .collect()
    }

    /// The chats whose name holds every word of `query` (without case or accents), the most
    /// recent first, at most `limit`.
    pub async fn find_chats(&self, query: String, limit: u32) -> Vec<CoreChat> {
        let chats = self.current_chats().await;
        let limit = usize::try_from(limit).unwrap_or(usize::MAX);
        find_chats(&chats, &query)
            .take(limit)
            .map(|chat| CoreChat::from(chat.as_ref()))
            .collect()
    }

    /// The chat that shows each room (the room's own, or the merged chat it is in), in the
    /// order of `room_ids`; none for a room the list does not show.
    pub async fn chats_of_rooms(&self, room_ids: Vec<String>) -> Vec<Option<CoreChat>> {
        let chats = self.current_chats().await;
        room_ids
            .iter()
            .map(|room| {
                let room = RoomId::from(room.as_str());
                chats
                    .iter()
                    .find(|chat| chat.id.room() == Some(&room) || chat.rooms.iter().any(|shown| shown.id == room))
                    .map(|chat| CoreChat::from(chat.as_ref()))
            })
            .collect()
    }

    /// Tells `listener` each time the account's chats change from now on (a new message, a chat
    /// read, archived or renamed), in every place, until the handle is cancelled or let go: for
    /// what follows the whole account rather than the place on screen (the search index).
    pub fn follow_chats(&self, listener: Arc<dyn CoreChatsListener>) -> Arc<CoreListenerHandle> {
        // the first batch is the list as it is now, not a change.
        let changes = with_account!(&self.backend, account => account.chats()).skip(1);
        let task = runtime::handle().spawn(changes.for_each(move |_| {
            listener.on_change();
            async {}
        }));
        Arc::new(CoreListenerHandle { tasks: vec![task] })
    }

    /// Tells `listener` once if the server ends this device's session (the platform then forgets
    /// it and signs in again), until the handle is cancelled or let go.
    pub fn follow_session_end(&self, listener: Arc<dyn CoreSessionEndListener>) -> Arc<CoreListenerHandle> {
        let end = with_account!(&self.backend, account => account.session_end().boxed());
        let task = runtime::handle().spawn(async move {
            end.await;
            listener.on_session_end();
        });
        Arc::new(CoreListenerHandle { tasks: vec![task] })
    }

    /// Stops the sync (the app goes to the background), and keeps the chat list for the next
    /// launch.
    pub async fn pause_sync(&self) {
        with_account!(&self.backend, account => account.pause_sync().await);
    }

    /// Starts the sync again.
    pub async fn resume_sync(&self) {
        with_account!(&self.backend, account => account.resume_sync().await);
    }

    /// Signs this device out on the server.
    ///
    /// # Errors
    /// When the server cannot be reached.
    pub async fn sign_out(&self) -> Result<(), CoreAccountError> {
        Ok(with_account!(&self.backend, account => account.sign_out().await)?)
    }
}

/// Hears that the account's chats changed.
#[uniffi::export(with_foreign)]
pub trait CoreChatsListener: Send + Sync {
    /// Some of the chats changed, on the core's thread.
    fn on_change(&self);
}

/// Hears that the server ended the account's session.
#[uniffi::export(with_foreign)]
pub trait CoreSessionEndListener: Send + Sync {
    /// The session ended, on the core's thread.
    fn on_session_end(&self);
}

/// Keeps a listener listening: cancelled, or let go, it stops.
#[derive(uniffi::Object)]
pub struct CoreListenerHandle {
    pub(crate) tasks: Vec<JoinHandle<()>>,
}

#[uniffi::export]
impl CoreListenerHandle {
    /// Stops the listener.
    pub fn cancel(&self) {
        for task in &self.tasks {
            task.abort();
        }
    }
}

impl Drop for CoreListenerHandle {
    fn drop(&mut self) {
        self.cancel();
    }
}
