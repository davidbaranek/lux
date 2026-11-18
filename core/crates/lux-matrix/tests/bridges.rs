//! A bridge's provisioning API, called as the account: the `OpenID` token it is called with, kept
//! until it expires, and what a bridge's refusal or absence reads as at the port.

// the sdk's futures nest deeply.
#![recursion_limit = "256"]
// a test crate: a failed step is the test failing.
#![allow(
    clippy::unwrap_used,
    clippy::expect_used,
    clippy::panic,
    clippy::indexing_slicing,
    reason = "a test's helpers fail it as its asserts do"
)]

use std::collections::HashMap;
use std::sync::atomic::{AtomicUsize, Ordering};

use lux_core::bridges::{BridgeOffer, LoginStep, StepId};
use lux_core::network::Network;
use lux_core::ports::{BackendError, Bridges, ChatAccount, NetworkFailure, StepAnswer};
use lux_matrix::MatrixAccount;
use matrix_sdk::test_utils::mocks::MatrixMockServer;
use serde_json::{Value, json};
use wiremock::matchers::{method, path, path_regex};
use wiremock::{Mock, MockServer, Request, Respond, ResponseTemplate};

mod support;
use support::{server, signed_in};

/// The homeserver's `OpenID` tokens: `token-1`, `token-2`, … each valid for `expires_in` seconds.
struct Tokens {
    issued: AtomicUsize,
    expires_in: u64,
}

impl Respond for Tokens {
    fn respond(&self, _: &Request) -> ResponseTemplate {
        let n = self.issued.fetch_add(1, Ordering::SeqCst) + 1;
        ResponseTemplate::new(200).set_body_json(json!({
            "access_token": format!("token-{n}"),
            "token_type": "Bearer",
            "matrix_server_name": "example.org",
            "expires_in": self.expires_in,
        }))
    }
}

/// The homeserver gives `OpenID` tokens that last `expires_in` seconds.
async fn openid_tokens(server: &MatrixMockServer, expires_in: u64) {
    Mock::given(method("POST"))
        .and(path_regex(r"^/_matrix/client/v3/user/[^/]+/openid/request_token$"))
        .respond_with(Tokens {
            issued: AtomicUsize::new(0),
            expires_in,
        })
        .mount(server.server())
        .await;
}

/// A bridge whose provisioning API is `bridge`'s.
fn offer(bridge: &MockServer) -> BridgeOffer {
    BridgeOffer {
        network: Network::Messenger,
        provisioning: bridge.uri(),
    }
}

/// The bridge answers `whoami` with an account without logins.
async fn whoami(bridge: &MockServer) {
    Mock::given(method("GET"))
        .and(path("/_matrix/provision/v3/whoami"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({"login_flows": [], "logins": []})))
        .mount(bridge)
        .await;
}

/// The credentials each request the bridge had came with, in order.
async fn credentials(bridge: &MockServer) -> Vec<String> {
    bridge
        .received_requests()
        .await
        .unwrap()
        .iter()
        .map(|request| request.headers["authorization"].to_str().unwrap().to_owned())
        .collect()
}

/// A signed-in account whose server gives tokens lasting `expires_in` seconds, and a bridge.
async fn account_and_bridge(expires_in: u64) -> (MatrixMockServer, MatrixAccount, tempfile::TempDir, MockServer) {
    let server = server().await;
    openid_tokens(&server, expires_in).await;
    let (account, folder) = signed_in(&server).await;
    (server, account, folder, MockServer::start().await)
}

#[tokio::test(flavor = "multi_thread")]
async fn a_bridge_is_called_as_the_account_with_one_openid_token_until_it_expires() {
    let (_server, account, _folder, bridge) = account_and_bridge(3600).await;
    whoami(&bridge).await;

    account.bridge_account(&offer(&bridge)).await.unwrap();
    account.bridge_account(&offer(&bridge)).await.unwrap();

    assert_eq!(
        credentials(&bridge).await,
        ["Bearer openid:token-1", "Bearer openid:token-1"]
    );
    let requests = bridge.received_requests().await.unwrap();
    let user = requests[0]
        .url
        .query_pairs()
        .find(|(key, _)| key == "user_id")
        .unwrap()
        .1;
    assert_eq!(user, account.own_user_id().as_str());
}

#[tokio::test(flavor = "multi_thread")]
async fn a_token_about_to_expire_is_not_used_but_asked_for_again() {
    // a minute: within the margin a token is kept short of its end.
    let (_server, account, _folder, bridge) = account_and_bridge(60).await;
    whoami(&bridge).await;

    account.bridge_account(&offer(&bridge)).await.unwrap();
    account.bridge_account(&offer(&bridge)).await.unwrap();

    assert_eq!(
        credentials(&bridge).await,
        ["Bearer openid:token-1", "Bearer openid:token-2"]
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn a_token_the_bridge_refuses_is_replaced_on_the_next_call() {
    let (_server, account, _folder, bridge) = account_and_bridge(3600).await;
    Mock::given(method("GET"))
        .and(path("/_matrix/provision/v3/whoami"))
        .respond_with(
            ResponseTemplate::new(401).set_body_json(json!({"errcode": "M_UNKNOWN_TOKEN", "error": "expired"})),
        )
        .up_to_n_times(1)
        .with_priority(1)
        .mount(&bridge)
        .await;
    whoami(&bridge).await;

    let refused = account.bridge_account(&offer(&bridge)).await.unwrap_err();
    assert!(
        matches!(&refused, BackendError::Server { status: Some(401), errcode: Some(errcode), .. } if errcode == "M_UNKNOWN_TOKEN"),
        "{refused:?}"
    );
    account.bridge_account(&offer(&bridge)).await.unwrap();

    assert_eq!(
        credentials(&bridge).await,
        ["Bearer openid:token-1", "Bearer openid:token-2"]
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn a_bridges_refusal_reaches_the_port_with_its_status_code_and_words() {
    let (_server, account, _folder, bridge) = account_and_bridge(3600).await;
    Mock::given(method("POST"))
        .and(path("/_matrix/provision/v3/login/start/facebook"))
        .respond_with(ResponseTemplate::new(400).set_body_json(json!({
            "errcode": "FI.MAU.BRIDGE.UNKNOWN_FLOW", "error": "No such login flow"
        })))
        .mount(&bridge)
        .await;

    let refused = account.start_login(&offer(&bridge), "facebook").await.unwrap_err();

    let BackendError::Server {
        status,
        errcode,
        source,
    } = &refused
    else {
        panic!("{refused:?}")
    };
    assert_eq!(*status, Some(400));
    assert_eq!(errcode.as_deref(), Some("FI.MAU.BRIDGE.UNKNOWN_FLOW"));
    assert_eq!(source.to_string(), "No such login flow");
}

#[tokio::test(flavor = "multi_thread")]
async fn a_bridge_that_answers_without_json_is_refused_by_its_status_code_alone() {
    let (_server, account, _folder, bridge) = account_and_bridge(3600).await;
    Mock::given(method("GET"))
        .and(path("/_matrix/provision/v3/whoami"))
        .respond_with(ResponseTemplate::new(502).set_body_string("<html>Bad Gateway</html>"))
        .mount(&bridge)
        .await;

    let refused = account.bridge_account(&offer(&bridge)).await.unwrap_err();

    assert!(
        matches!(
            refused,
            BackendError::Server {
                status: Some(502),
                errcode: None,
                ..
            }
        ),
        "{refused:?}"
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn a_bridge_nobody_answers_at_is_a_network_failure() {
    let (_server, account, _folder, _bridge) = account_and_bridge(3600).await;
    // an address nothing listens at any more.
    let closed = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let gone = BridgeOffer {
        network: Network::Messenger,
        provisioning: format!("http://{}", closed.local_addr().unwrap()),
    };
    drop(closed);

    let failed = account.bridge_account(&gone).await.unwrap_err();

    assert!(
        matches!(
            failed,
            BackendError::Network {
                kind: NetworkFailure::Offline,
                ..
            }
        ),
        "{failed:?}"
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn a_token_the_server_does_not_give_fails_the_call_before_the_bridge_is_asked() {
    let server = server().await;
    Mock::given(method("POST"))
        .and(path_regex(r"/openid/request_token$"))
        .respond_with(ResponseTemplate::new(400).set_body_json(json!({
            "errcode": "M_UNKNOWN", "error": "No tokens today"
        })))
        .mount(server.server())
        .await;
    let (account, _folder) = signed_in(&server).await;
    let bridge = MockServer::start().await;
    whoami(&bridge).await;

    let refused = account.bridge_account(&offer(&bridge)).await.unwrap_err();

    assert!(
        matches!(&refused, BackendError::Server { status: Some(400), errcode: Some(errcode), .. } if errcode == "M_UNKNOWN"),
        "{refused:?}"
    );
    assert!(bridge.received_requests().await.unwrap().is_empty());
}

#[tokio::test(flavor = "multi_thread")]
async fn a_form_answered_goes_to_its_step_and_the_bridge_says_the_sign_in_is_done() {
    let (_server, account, _folder, bridge) = account_and_bridge(3600).await;
    Mock::given(method("POST"))
        .and(path("/_matrix/provision/v3/login/start/phone%20number"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "login_id": "p/1", "type": "user_input", "step_id": "fi.mau.phone", "instructions": "Your number",
            "user_input": {"fields": [{"type": "phone_number", "id": "phone", "name": "Phone"}]}
        })))
        .mount(&bridge)
        .await;
    Mock::given(method("POST"))
        .and(path("/_matrix/provision/v3/login/step/p%2F1/fi.mau.phone/user_input"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "login_id": "p/1", "type": "complete", "step_id": "fi.mau.complete", "instructions": "Signed in",
            "complete": {"user_login_id": "4912345"}
        })))
        .mount(&bridge)
        .await;

    let LoginStep::Form(form) = account.start_login(&offer(&bridge), "phone number").await.unwrap() else {
        panic!("not a form")
    };
    let answer = StepAnswer::Values(HashMap::from([("phone".to_owned(), "+4912345".to_owned())]));
    let done = account.answer_login(&offer(&bridge), &form.id, answer).await.unwrap();

    let LoginStep::Done(done) = done else {
        panic!("{done:?}")
    };
    assert_eq!(done.login_id.as_deref(), Some("4912345"));
    let requests = bridge.received_requests().await.unwrap();
    let sent: Value = serde_json::from_slice(&requests[1].body).unwrap();
    assert_eq!(sent, json!({"phone": "+4912345"}));
}

#[tokio::test(flavor = "multi_thread")]
async fn a_cancelled_sign_in_is_cancelled_at_the_bridge() {
    let (_server, account, _folder, bridge) = account_and_bridge(3600).await;
    Mock::given(method("POST"))
        .and(path("/_matrix/provision/v3/login/cancel/p1"))
        .respond_with(ResponseTemplate::new(404).set_body_json(json!({"errcode": "M_NOT_FOUND", "error": "gone"})))
        .expect(1)
        .mount(&bridge)
        .await;
    let step = StepId {
        process: "p1".to_owned(),
        step: "fi.mau.qr".to_owned(),
        kind: "display_and_wait".to_owned(),
        instructions: String::new(),
    };

    account.cancel_login(&offer(&bridge), &step).await;

    bridge.verify().await;
}
