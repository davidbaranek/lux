//! What the tests share: the requests a mock answered, counted as they arrive, so a test awaits
//! the next one instead of polling the server.

// each test crate uses only part of it.
#![allow(dead_code)]

use std::collections::{BTreeMap, BTreeSet};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use tokio::sync::watch;
use wiremock::{Request, Respond, ResponseTemplate};

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

    /// Whether another request arrives within `window`.
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
