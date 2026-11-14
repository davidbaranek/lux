//! What the tests share: the requests a mock answered, counted as they arrive, so a test awaits
//! the next one instead of polling the server.

// each test crate uses only part of it.
#![allow(dead_code)]

use std::collections::BTreeMap;
use std::sync::Arc;
use std::time::Duration;

use tokio::sync::watch;
use wiremock::{Request, Respond, ResponseTemplate};

/// How many requests a mock answered, per sliding sync connection (`conn_id`; empty for
/// a request without one).
pub type Counts = BTreeMap<String, usize>;

/// The requests that reached a mock mounted with [`Requests::answering`].
#[derive(Clone)]
pub struct Requests(Arc<watch::Sender<Counts>>);

impl Default for Requests {
    fn default() -> Self {
        Self(Arc::new(watch::channel(Counts::new()).0))
    }
}

impl Requests {
    /// Answers each request with `template`, counting it here first.
    pub fn answering(&self, template: ResponseTemplate) -> impl Respond + use<> {
        Counting {
            counts: self.0.clone(),
            template,
        }
    }

    /// The counts so far.
    pub fn counts(&self) -> Counts {
        self.0.borrow().clone()
    }

    /// Waits until the counts satisfy `done`, for at most ten seconds.
    pub async fn until(&self, done: impl FnMut(&Counts) -> bool) {
        let mut counts = self.0.subscribe();
        tokio::time::timeout(Duration::from_secs(10), counts.wait_for(done))
            .await
            .expect("the requests did not come in time")
            .expect("the counts are kept here");
    }

    /// Whether another request arrives within `window`.
    pub async fn more_within(&self, window: Duration) -> bool {
        let mut counts = self.0.subscribe();
        matches!(tokio::time::timeout(window, counts.changed()).await, Ok(Ok(())))
    }
}

struct Counting {
    counts: Arc<watch::Sender<Counts>>,
    template: ResponseTemplate,
}

impl Respond for Counting {
    fn respond(&self, request: &Request) -> ResponseTemplate {
        let connection = serde_json::from_slice::<serde_json::Value>(&request.body)
            .ok()
            .and_then(|body| body["conn_id"].as_str().map(str::to_owned))
            .unwrap_or_default();
        self.counts
            .send_modify(|counts| *counts.entry(connection).or_default() += 1);
        self.template.clone()
    }
}
