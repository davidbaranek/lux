//! What a shared post's address says about it (its title, its description), read from the
//! homeserver's link previews (`/media/preview_url`): the server fetches the page, so the device
//! never reaches the site. One task asks, each address once; what it learns goes out as one
//! shared map, with which the open timelines map their messages again.

use lux_core::gone::OtherEndGone;
use std::collections::HashMap;
use std::sync::Arc;

use matrix_sdk::Client;
use matrix_sdk::ruma::api::client::authenticated_media::get_media_preview;
use serde::Deserialize;
use tokio::sync::{mpsc, watch};
use tokio::task::JoinHandle;
use tracing::warn;

/// What a page says about itself (its Open Graph title and description).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(crate) struct LinkPreview {
    pub(crate) title: Option<String>,
    pub(crate) description: Option<String>,
}

/// The previews learned so far, by address; `None` for an address the server could not read.
pub(crate) type Known = Arc<HashMap<String, Option<LinkPreview>>>;

/// The account's link previews: ask for an address, follow what is known.
#[derive(Clone)]
pub(crate) struct LinkPreviews {
    asks: mpsc::UnboundedSender<String>,
    known: watch::Receiver<Known>,
    _task: Arc<Task>,
}

/// The task, aborted with the last handle.
struct Task(JoinHandle<()>);

impl Drop for Task {
    fn drop(&mut self) {
        self.0.abort();
    }
}

impl LinkPreviews {
    pub(crate) fn start(client: Client) -> Self {
        let (asks, asked) = mpsc::unbounded_channel();
        let (learned, known) = watch::channel(Known::default());
        let task = tokio::spawn(read(client, asked, learned));
        Self {
            asks,
            known,
            _task: Arc::new(Task(task)),
        }
    }

    /// The preview of `url`; none while the server has not read it (which asks it to) or when
    /// it has nothing to say.
    pub(crate) fn get(&self, url: &str) -> Option<LinkPreview> {
        let known = self.known.borrow().get(url).cloned();
        if known.is_none() {
            self.asks
                .send(url.to_owned())
                .other_end_may_be_gone("the previews' task");
        }
        known.flatten()
    }

    /// The previews as they are learned.
    pub(crate) fn follow(&self) -> watch::Receiver<Known> {
        self.known.clone()
    }
}

async fn read(client: Client, mut asked: mpsc::UnboundedReceiver<String>, learned: watch::Sender<Known>) {
    while let Some(url) = asked.recv().await {
        if learned.borrow().contains_key(&url) {
            continue;
        }
        let preview = fetch(&client, &url).await;
        learned.send_modify(|known| {
            Arc::make_mut(known).insert(url, preview);
        });
    }
}

/// The server's preview of `url`, its title and description; none when it has neither.
async fn fetch(client: &Client, url: &str) -> Option<LinkPreview> {
    #[derive(Deserialize)]
    struct OpenGraph {
        #[serde(rename = "og:title")]
        title: Option<String>,
        #[serde(rename = "og:description")]
        description: Option<String>,
        #[serde(rename = "og:site_name")]
        site: Option<String>,
    }
    let response = match client.send(get_media_preview::v1::Request::new(url.to_owned())).await {
        Ok(response) => response,
        Err(error) => {
            warn!(%error, "a link's preview cannot be read");
            return None;
        }
    };
    let graph: OpenGraph = serde_json::from_str(response.data?.get()).ok()?;
    let text = |text: Option<String>| text.map(|text| text.trim().to_owned()).filter(|text| !text.is_empty());
    let site = text(graph.site);
    // a page whose title is only its site's name ("Instagram" for instagram.com) says nothing
    // of the post.
    let host = url
        .split("://")
        .nth(1)
        .and_then(|rest| rest.split('/').next())
        .unwrap_or_default();
    let brand = host.trim_start_matches("www.").split('.').next().unwrap_or_default();
    let title =
        text(graph.title).filter(|title| site.as_deref() != Some(title.as_str()) && !title.eq_ignore_ascii_case(brand));
    let description = text(graph.description);
    (title.is_some() || description.is_some()).then_some(LinkPreview { title, description })
}
