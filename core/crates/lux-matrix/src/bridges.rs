//! The server's bridges ([`Bridges`]): the client well-known's list of them, their provisioning
//! APIs (`mautrix` bridgev2's `/_matrix/provision/v3`), and the history they bring.
//!
//! The app calls a bridge as the account, but never hands it the account's access token: it
//! sends an `OpenID` token (`openid:<token>`, which the bridge checks with the account's server),
//! asked for once an hour.

use std::collections::HashMap;
use std::time::{Duration, Instant, SystemTime};

use lux_core::bridges::{
    BridgeAccount, BridgeOffer, CatchUp, Done, FieldKind, FormField, FormStep, HistoryArrivals, LoginFlow, LoginState,
    LoginStep, NetworkLogin, Offers, ShowStep, Shown, StepId, WELL_KNOWN_KEY, WebsiteField, WebsiteSource, WebsiteStep,
};
use lux_core::ids::RoomId;
use lux_core::network::Network;
use lux_core::ports::{BackendError, Bridges, NetworkFailure, StepAnswer, ValueStream};
use matrix_sdk::reqwest::{self, Method, StatusCode, Url};
use matrix_sdk::ruma::api::client::account::request_openid_token;
use matrix_sdk::ruma::events::AnySyncTimelineEvent;
use matrix_sdk::{Client, Room};
use serde::Deserialize;
use serde_json::Value;
use tokio::sync::{mpsc, watch};
use tokio::task::JoinHandle;
use tracing::warn;

use crate::bridge_state::bridge_states;
use crate::convert::system_time;
use crate::errors::from_http;
use crate::streams::watched;

/// How long a sign-in's waiting step may wait for the phone before the request is sent again.
const WAIT: Duration = Duration::from_mins(10);

/// The account's link to its server's bridges.
pub(crate) struct BridgeLink {
    client: Client,
    openid: tokio::sync::Mutex<Option<(String, Instant)>>,
    catching_up: watch::Receiver<Vec<CatchUp>>,
    _arrivals: Arrivals,
}

impl BridgeLink {
    /// Starts following the history the sync brings, over `client`.
    pub(crate) fn start(client: &Client) -> Self {
        let (arrived, arrivals) = mpsc::unbounded_channel();
        client.add_event_handler(move |event: AnySyncTimelineEvent, room: Room| {
            let _ = arrived.send((room, system_time(event.origin_server_ts()), SystemTime::now()));
            async {}
        });
        let (sender, catching_up) = watch::channel(Vec::new());
        Self {
            client: client.clone(),
            openid: tokio::sync::Mutex::new(None),
            catching_up,
            _arrivals: Arrivals(tokio::spawn(follow_arrivals(arrivals, sender))),
        }
    }

    /// An `OpenID` token for the bridges, asked for again before the last expires.
    async fn openid(&self) -> Result<String, BackendError> {
        let mut kept = self.openid.lock().await;
        if let Some((token, until)) = kept.as_ref()
            && Instant::now() < *until
        {
            return Ok(token.clone());
        }
        let user = self.client.user_id().ok_or(BackendError::SignedOut)?.to_owned();
        let response = self
            .client
            .send(request_openid_token::v3::Request::new(user))
            .await
            .map_err(from_http)?;
        // a minute's margin, so a request does not go with a token about to expire.
        let lasts = Duration::from_secs(response.expires_in.as_secs()).saturating_sub(Duration::from_secs(60));
        *kept = Some((response.access_token.clone(), Instant::now() + lasts));
        Ok(response.access_token)
    }

    /// Calls `path` of `offer`'s provisioning API as the account.
    async fn call(
        &self,
        offer: &BridgeOffer,
        method: Method,
        path: &str,
        body: Option<Value>,
    ) -> Result<Value, BackendError> {
        let user = self.client.user_id().ok_or(BackendError::SignedOut)?;
        let token = self.openid().await?;
        let url = Url::parse_with_params(
            &format!("{}/_matrix/provision/v3/{path}", offer.provisioning),
            [("user_id", user.as_str())],
        )
        .map_err(BackendError::refused)?;
        let mut request = self
            .client
            .http_client()
            .request(method, url)
            .bearer_auth(format!("openid:{token}"))
            .timeout(WAIT);
        if let Some(body) = body {
            request = request.json(&body);
        }
        let response = request.send().await.map_err(network)?;
        let status = response.status();
        let text = response.text().await.map_err(network)?;
        let value: Value = if text.trim().is_empty() {
            Value::Null
        } else {
            serde_json::from_str(&text).unwrap_or(Value::Null)
        };
        if status.is_success() {
            return Ok(value);
        }
        if status == StatusCode::UNAUTHORIZED {
            // the token may have expired early: the next call asks for another.
            *self.openid.lock().await = None;
        }
        Err(BackendError::Server {
            status: Some(status.as_u16()),
            errcode: value.get("errcode").and_then(Value::as_str).map(str::to_owned),
            source: Refusal(
                value
                    .get("error")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_owned(),
            )
            .into(),
        })
    }
}

/// The task that turns the sync's events into the networks catching up.
struct Arrivals(JoinHandle<()>);

impl Drop for Arrivals {
    fn drop(&mut self) {
        self.0.abort();
    }
}

/// Follows the events the sync brings: each old one is history of its room's network, and the
/// networks catching up go out as they change, also when one goes quiet.
async fn follow_arrivals(
    mut arrived: mpsc::UnboundedReceiver<(Room, SystemTime, SystemTime)>,
    catching_up: watch::Sender<Vec<CatchUp>>,
) {
    let mut history = HistoryArrivals::default();
    let mut networks: HashMap<RoomId, Network> = HashMap::new();
    loop {
        let quiet = history
            .next_done()
            .map(|done| done.duration_since(SystemTime::now()).unwrap_or_default());
        let next = async {
            match quiet {
                Some(quiet) => tokio::time::timeout(quiet, arrived.recv()).await.ok(),
                None => Some(arrived.recv().await),
            }
        };
        let arrival = next.await;
        // the account is gone.
        if matches!(arrival, Some(None)) {
            return;
        }
        // none: a network went quiet.
        if let Some(Some((room, sent, now))) = arrival {
            if now.duration_since(sent).unwrap_or_default() < HistoryArrivals::OLD {
                continue;
            }
            let id = RoomId::from(room.room_id().as_str());
            let network = if let Some(network) = networks.get(&id) {
                network.clone()
            } else {
                let states = bridge_states(&room).await;
                let network = Network::detect(states.iter().filter_map(|state| state.protocol.as_deref()), []);
                networks.insert(id.clone(), network.clone());
                network
            };
            history.arrived(network, id, sent, now);
        }
        let now = history.catching_up(SystemTime::now());
        catching_up.send_if_modified(|current| {
            let changed = *current != now;
            *current = now;
            changed
        });
    }
}

impl Bridges for crate::MatrixAccount {
    async fn bridge_offers(&self) -> Result<Offers, BackendError> {
        #[derive(Deserialize)]
        struct Listed {
            network: String,
            provisioning: String,
        }
        let user = self.client.user_id().ok_or(BackendError::SignedOut)?;
        let url = format!("https://{}/.well-known/matrix/client", user.server_name());
        let response = self.client.http_client().get(&url).send().await.map_err(network)?;
        if !response.status().is_success() {
            return Ok(Offers::NotSet);
        }
        let well_known: Value = response.json().await.unwrap_or(Value::Null);
        let Some(listed) = well_known.get(WELL_KNOWN_KEY) else {
            return Ok(Offers::NotSet);
        };
        let listed: Vec<Listed> = serde_json::from_value(listed.clone()).unwrap_or_default();
        Ok(Offers::from_list(
            listed.into_iter().map(|listed| (listed.network, listed.provisioning)),
        ))
    }

    async fn bridge_account(&self, offer: &BridgeOffer) -> Result<BridgeAccount, BackendError> {
        let whoami = self.bridges.call(offer, Method::GET, "whoami", None).await?;
        Ok(account(offer, &whoami))
    }

    async fn start_login(&self, offer: &BridgeOffer, flow: &str) -> Result<LoginStep, BackendError> {
        let path = format!("login/start/{}", segment(flow));
        let step = self
            .bridges
            .call(
                offer,
                Method::POST,
                &path,
                Some(Value::Object(serde_json::Map::default())),
            )
            .await?;
        Ok(login_step(&step))
    }

    async fn answer_login(
        &self,
        offer: &BridgeOffer,
        step: &StepId,
        answer: StepAnswer,
    ) -> Result<LoginStep, BackendError> {
        let path = format!(
            "login/step/{}/{}/{}",
            segment(&step.process),
            segment(&step.step),
            segment(&step.kind)
        );
        let body = match answer {
            StepAnswer::Values(values) => serde_json::to_value(values).unwrap_or_default(),
            StepAnswer::Wait => Value::Object(serde_json::Map::default()),
        };
        let next = self.bridges.call(offer, Method::POST, &path, Some(body)).await?;
        Ok(login_step(&next))
    }

    async fn cancel_login(&self, offer: &BridgeOffer, step: &StepId) {
        let path = format!("login/cancel/{}", segment(&step.process));
        if let Err(error) = self
            .bridges
            .call(
                offer,
                Method::POST,
                &path,
                Some(Value::Object(serde_json::Map::default())),
            )
            .await
        {
            warn!(%error, "a bridge sign-in cannot be cancelled");
        }
    }

    async fn log_out_of_network(&self, offer: &BridgeOffer, login: &str) -> Result<(), BackendError> {
        let path = format!("logout/{}", segment(login));
        self.bridges
            .call(
                offer,
                Method::POST,
                &path,
                Some(Value::Object(serde_json::Map::default())),
            )
            .await?;
        Ok(())
    }

    fn catching_up(&self) -> ValueStream<Vec<CatchUp>> {
        watched(self.bridges.catching_up.clone())
    }
}

/// A bridge's refusal, in its words.
#[derive(Debug, thiserror::Error)]
#[error("{0}")]
struct Refusal(String);

/// A failure to reach a bridge.
fn network(error: reqwest::Error) -> BackendError {
    let kind = if error.is_timeout() {
        NetworkFailure::Timeout
    } else if error.is_connect() {
        NetworkFailure::Offline
    } else {
        NetworkFailure::Other
    };
    BackendError::Network {
        kind,
        source: error.into(),
    }
}

/// An id as one segment of a path.
fn segment(id: &str) -> String {
    id.bytes()
        .map(|byte| match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => char::from(byte).to_string(),
            _ => format!("%{byte:02X}"),
        })
        .collect()
}

/// A string field of `value`; empty when there is none.
fn text(value: &Value, key: &str) -> String {
    value.get(key).and_then(Value::as_str).unwrap_or_default().to_owned()
}

/// A string field of `value`, if not empty.
fn some_text(value: &Value, key: &str) -> Option<String> {
    Some(text(value, key)).filter(|text| !text.is_empty())
}

/// The account on a bridge, from its `whoami`.
fn account(offer: &BridgeOffer, whoami: &Value) -> BridgeAccount {
    let list = |key: &str| whoami.get(key).and_then(Value::as_array).cloned().unwrap_or_default();
    let logins = list("logins")
        .iter()
        .map(|login| {
            let state = login.get("state").unwrap_or(&Value::Null);
            let event = some_text(state, "state_event").or_else(|| some_text(login, "state_event"));
            NetworkLogin {
                id: text(login, "id"),
                name: some_text(login, "name").unwrap_or_else(|| text(login, "id")),
                state: LoginState::from_bridge(event.as_deref().unwrap_or_default(), some_text(state, "reason")),
            }
        })
        .collect();
    let flows = LoginFlow::ordered(
        list("login_flows")
            .iter()
            .map(|flow| LoginFlow {
                id: text(flow, "id"),
                name: text(flow, "name"),
                description: text(flow, "description"),
            })
            .collect(),
    );
    BridgeAccount {
        network: offer.network.clone(),
        logins,
        flows,
    }
}

/// A sign-in's step, from the bridge's answer.
fn login_step(answer: &Value) -> LoginStep {
    let kind = text(answer, "type");
    let id = StepId {
        process: text(answer, "login_id"),
        step: text(answer, "step_id"),
        kind: kind.clone(),
        instructions: text(answer, "instructions"),
    };
    let params = answer.get(kind.as_str()).unwrap_or(&Value::Null);
    match kind.as_str() {
        "cookies" => LoginStep::Website(WebsiteStep {
            id,
            url: text(params, "url"),
            user_agent: some_text(params, "user_agent"),
            fields: params
                .get("fields")
                .and_then(Value::as_array)
                .map(|fields| fields.iter().map(website_field).collect())
                .unwrap_or_default(),
            extract_js: some_text(params, "extract_js"),
            done_url_pattern: some_text(params, "wait_for_url_pattern"),
            hidden: params.get("hidden").and_then(Value::as_bool).unwrap_or(false),
        }),
        "user_input" => LoginStep::Form(FormStep {
            id,
            fields: params
                .get("fields")
                .and_then(Value::as_array)
                .map(|fields| fields.iter().map(form_field).collect())
                .unwrap_or_default(),
        }),
        "display_and_wait" => {
            let data = text(params, "data");
            let shown = match text(params, "type").as_str() {
                "qr" => Shown::QrCode(data),
                "code" => Shown::Code(data),
                "emoji" => Shown::Emoji {
                    text: data,
                    image_url: some_text(params, "image_url"),
                },
                _ => Shown::Nothing,
            };
            LoginStep::Show(ShowStep { id, shown })
        }
        "complete" => LoginStep::Done(Done {
            login_id: params.get("user_login_id").and_then(Value::as_str).map(str::to_owned),
            instructions: id.instructions,
        }),
        _ => LoginStep::Unsupported { kind },
    }
}

fn website_field(field: &Value) -> WebsiteField {
    WebsiteField {
        id: text(field, "id"),
        required: field.get("required").and_then(Value::as_bool).unwrap_or(false),
        sources: field
            .get("sources")
            .and_then(Value::as_array)
            .map(|sources| {
                sources
                    .iter()
                    .map(|source| {
                        let name = text(source, "name");
                        match text(source, "type").as_str() {
                            "cookie" => WebsiteSource::Cookie {
                                name,
                                domain: some_text(source, "cookie_domain"),
                            },
                            "local_storage" => WebsiteSource::LocalStorage { name },
                            "special" => WebsiteSource::Script { name },
                            _ => WebsiteSource::Unreadable,
                        }
                    })
                    .collect()
            })
            .unwrap_or_default(),
    }
}

fn form_field(field: &Value) -> FormField {
    FormField {
        id: text(field, "id"),
        kind: FieldKind::from_bridge(&text(field, "type")),
        name: text(field, "name"),
        description: text(field, "description"),
        default: text(field, "default_value"),
        optional: field.get("optional").and_then(Value::as_bool).unwrap_or(false),
        pattern: some_text(field, "pattern"),
        choices: field
            .get("options")
            .and_then(Value::as_array)
            .map(|options| options.iter().filter_map(Value::as_str).map(str::to_owned).collect())
            .unwrap_or_default(),
    }
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    #[test]
    fn a_cookie_step_asks_for_the_sites_cookies_until_its_page_is_reached() {
        let step = login_step(&json!({
            "login_id": "p1", "type": "cookies", "step_id": "fi.mau.meta.cookies",
            "instructions": "Sign in",
            "cookies": {
                "url": "https://www.facebook.com/", "user_agent": "UA",
                "wait_for_url_pattern": "^https://www\\.facebook\\.com/",
                "fields": [{"id": "xs", "required": true,
                    "sources": [{"type": "cookie", "name": "xs", "cookie_domain": "facebook.com"}]}]
            }
        }));
        let LoginStep::Website(step) = step else {
            panic!("{step:?}")
        };
        assert_eq!(step.id.process, "p1");
        assert_eq!(step.id.kind, "cookies");
        assert_eq!(step.url, "https://www.facebook.com/");
        assert_eq!(
            step.fields[0].sources,
            [WebsiteSource::Cookie {
                name: "xs".to_owned(),
                domain: Some("facebook.com".to_owned())
            }]
        );
    }

    #[test]
    fn a_pin_step_is_a_form_with_one_hidden_optional_field() {
        let step = login_step(&json!({
            "login_id": "p1", "type": "user_input", "step_id": "fi.mau.meta.history_pin",
            "instructions": "Enter your PIN",
            "user_input": {"fields": [{"type": "password", "id": "pin", "name": "PIN",
                "optional": true, "pattern": "^[0-9]{6}$"}]}
        }));
        let LoginStep::Form(form) = step else {
            panic!("{step:?}")
        };
        assert_eq!(form.fields[0].kind, FieldKind::Password);
        assert!(form.fields[0].optional);
    }

    #[test]
    fn whoami_gives_the_logins_and_their_states() {
        let offer = BridgeOffer {
            network: Network::Messenger,
            provisioning: "https://example.org/fb".to_owned(),
        };
        let account = account(
            &offer,
            &json!({
                "login_flows": [{"id": "facebook", "name": "facebook.com", "description": "Cookies"}],
                "logins": [{"id": "100", "name": "Anna", "state": {"state_event": "BAD_CREDENTIALS", "reason": "x"}}]
            }),
        );
        assert_eq!(account.flows[0].id, "facebook");
        assert_eq!(account.logins[0].state, LoginState::BadCredentials);
        assert!(account.needs_sign_in());
    }

    #[test]
    fn an_id_goes_into_a_path_as_one_segment() {
        assert_eq!(segment("fi.mau.meta/cookies x"), "fi.mau.meta%2Fcookies%20x");
    }
}
