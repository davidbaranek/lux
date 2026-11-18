//! What the tests share: the Keychain in memory, a mock server that signs an account in, and the
//! requests a mock answered, counted as they arrive, so a test awaits the next one instead of
//! polling the server.

// each test crate uses only part of it.
#![allow(dead_code)]

use std::collections::{BTreeMap, BTreeSet};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use lux_core::ports::{SecretStore, SecretStoreError, SessionSecrets, SignIn, StoreKey};
use lux_matrix::{MatrixAccount, MatrixSignIn, StoreFolder};
use matrix_sdk::test_utils::mocks::MatrixMockServer;
use tokio::sync::watch;
use wiremock::{Request, Respond, ResponseTemplate};

/// The platform's Keychain, in memory.
#[derive(Default)]
pub struct MemorySecrets(Mutex<Option<SessionSecrets>>, Mutex<Option<StoreKey>>);

impl SecretStore for MemorySecrets {
    fn load(&self) -> Result<Option<SessionSecrets>, SecretStoreError> {
        Ok(self.0.lock().unwrap().clone())
    }

    fn save(&self, secrets: &SessionSecrets) -> Result<(), SecretStoreError> {
        *self.0.lock().unwrap() = Some(secrets.clone());
        Ok(())
    }

    fn store_key(&self) -> Result<Option<StoreKey>, SecretStoreError> {
        Ok(self.1.lock().unwrap().clone())
    }

    fn save_store_key(&self, key: &StoreKey) -> Result<(), SecretStoreError> {
        *self.1.lock().unwrap() = Some(key.clone());
        Ok(())
    }

    fn delete(&self) -> Result<(), SecretStoreError> {
        *self.0.lock().unwrap() = None;
        *self.1.lock().unwrap() = None;
        Ok(())
    }
}

/// A mock server with sliding sync that signs any password in; a test mounts the rest.
pub async fn server() -> MatrixMockServer {
    let server = MatrixMockServer::new().await;
    server.mock_versions().with_simplified_sliding_sync().ok().mount().await;
    server.mock_login().ok().mount().await;
    server
}

/// A signed-in account of `server`, in a new folder (kept with it).
pub async fn signed_in(server: &MatrixMockServer) -> (MatrixAccount, tempfile::TempDir) {
    let folder = tempfile::tempdir().unwrap();
    let sign_in = MatrixSignIn::new(StoreFolder::new(folder.path()), Arc::new(MemorySecrets::default()));
    let account = sign_in
        .sign_in_with_password(&server.uri(), "cheeky_monkey", "secret", "Lux (Test)")
        .await
        .unwrap();
    (account, folder)
}

/// How many requests a mock answered, per sliding sync connection (`conn_id`; empty for
/// a request without one).
pub type Counts = BTreeMap<String, usize>;

/// How long a held request waits for its answer: longer than any test, so the client gives up
/// on it first.
const HELD: Duration = Duration::from_secs(3600);

/// The requests that reached a mock mounted with [`Requests::answering`].
#[derive(Clone)]
pub struct Requests {
    counts: Arc<watch::Sender<Counts>>,
    /// The connections whose requests the mock leaves unanswered.
    held: Arc<Mutex<BTreeSet<String>>>,
}

impl Default for Requests {
    fn default() -> Self {
        Self {
            counts: Arc::new(watch::channel(Counts::new()).0),
            held: Arc::default(),
        }
    }
}

impl Requests {
    /// Answers each request with `template`, counting it here first.
    pub fn answering(&self, template: ResponseTemplate) -> impl Respond + use<> {
        Counting {
            counts: self.counts.clone(),
            held: self.held.clone(),
            template,
        }
    }

    /// From now on the mock leaves the requests of `connection` that arrive unanswered, until
    /// [`release`](Self::release): a test acts while the client waits, not at a point in time.
    pub fn hold(&self, connection: &str) {
        self.held.lock().unwrap().insert(connection.to_owned());
    }

    /// From now on the mock answers every request that arrives (the held ones stay unanswered:
    /// their client has given up on them).
    pub fn release(&self) {
        self.held.lock().unwrap().clear();
    }

    /// The counts so far.
    pub fn counts(&self) -> Counts {
        self.counts.borrow().clone()
    }

    /// Waits until the counts satisfy `done`, for at most ten seconds.
    pub async fn until(&self, done: impl FnMut(&Counts) -> bool) {
        let mut counts = self.counts.subscribe();
        tokio::time::timeout(Duration::from_secs(10), counts.wait_for(done))
            .await
            .expect("the requests did not come in time")
            .expect("the counts are kept here");
    }

    /// Waits for another request, for at most ten seconds.
    pub async fn another(&self) {
        let before: usize = self.counts().values().sum();
        self.until(|counts| counts.values().sum::<usize>() > before).await;
    }

    /// Whether another request arrives within `window`: for a check that none does, as waiting
    /// for one is [`another`](Self::another).
    pub async fn more_within(&self, window: Duration) -> bool {
        let mut counts = self.counts.subscribe();
        matches!(tokio::time::timeout(window, counts.changed()).await, Ok(Ok(())))
    }
}

struct Counting {
    counts: Arc<watch::Sender<Counts>>,
    held: Arc<Mutex<BTreeSet<String>>>,
    template: ResponseTemplate,
}

impl Respond for Counting {
    fn respond(&self, request: &Request) -> ResponseTemplate {
        let connection = serde_json::from_slice::<serde_json::Value>(&request.body)
            .ok()
            .and_then(|body| body["conn_id"].as_str().map(str::to_owned))
            .unwrap_or_default();
        let held = self.held.lock().unwrap().contains(&connection);
        self.counts
            .send_modify(|counts| *counts.entry(connection).or_default() += 1);
        if held {
            self.template.clone().set_delay(HELD)
        } else {
            self.template.clone()
        }
    }
}
