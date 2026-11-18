//! Verification and recovery between two devices of one account, both Lux, against a mock
//! homeserver that keeps what a real one keeps for them: keys, account data, the key backup, and
//! the to-device messages one device sends the other.

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

use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::future::Future;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use futures_util::StreamExt;
use lux_core::ports::{
    BackendError, DeviceSignOut, EncryptionSetup, Security, SignIn, ValueStream, Verification, VerificationEmoji,
    VerificationStep,
};
use lux_matrix::{MatrixAccount, MatrixSignIn, StoreFolder};
use matrix_sdk::ruma::user_id;
use matrix_sdk::test_utils::mocks::MatrixMockServer;
use serde_json::{Value, json};
use tokio::sync::watch;
use wiremock::matchers::{method, path, path_regex};
use wiremock::{Mock, Request, ResponseTemplate};

mod support;
use support::MemorySecrets;

const USER: &str = "@ada:example.org";

/// What the homeserver keeps between requests.
#[derive(Default)]
struct Kept {
    /// Each signed-in device, by its access token.
    devices: HashMap<String, String>,
    /// The devices still to sign in: their tokens and ids, in order.
    logins: Vec<(String, String)>,
    /// The to-device messages waiting for each device.
    to_device: HashMap<String, Vec<Value>>,
    /// The account's global account data, in the order it was written.
    account_data: Vec<(String, Value)>,
    /// How much of it each device has had.
    account_data_seen: HashMap<String, usize>,
    /// The key backup's version, once made.
    backup: Option<Value>,
    /// Each sliding sync connection's position.
    positions: BTreeMap<String, u64>,
    /// A device whose keys do not reach the server yet: it refuses their upload.
    held_uploads: Option<String>,
}

/// What the server saw of the devices' keys, as it happens: a test awaits it.
#[derive(Default)]
struct Seen {
    /// The devices whose keys the server took.
    keys: BTreeSet<String>,
    /// The device whose upload is refused asked the server for its own keys, and heard there are
    /// none.
    held_keys_asked: bool,
}

/// A homeserver for one account and its devices.
struct Homeserver {
    mock: MatrixMockServer,
    kept: Arc<Mutex<Kept>>,
    seen: Arc<watch::Sender<Seen>>,
    /// The devices' folders, kept until the end of the test.
    folders: Vec<tempfile::TempDir>,
}

impl Homeserver {
    async fn start() -> Self {
        let mock = MatrixMockServer::new().await;
        mock.mock_versions().with_simplified_sliding_sync().ok().mount().await;
        // keys, cross-signing, signatures and one-time keys, kept per device.
        mock.mock_crypto_endpoints_preset().await;
        let kept = Arc::new(Mutex::new(Kept::default()));
        let server = Self {
            mock,
            kept,
            seen: Arc::new(watch::channel(Seen::default()).0),
            folders: Vec::new(),
        };
        server.mount().await;
        server
    }

    fn kept(&self) -> std::sync::MutexGuard<'_, Kept> {
        self.kept.lock().unwrap()
    }

    /// Waits until the server has `device`'s keys.
    async fn has_keys_of(&self, device: &str) {
        let mut seen = self.seen.subscribe();
        within(
            &format!("{device}'s keys"),
            seen.wait_for(|seen| seen.keys.contains(device)),
        )
        .await
        .unwrap();
    }

    /// Waits until the device whose upload is refused asks for its own keys, and hears there are
    /// none: it waits for them.
    async fn held_keys_asked(&self) {
        let mut seen = self.seen.subscribe();
        within("a look for the held keys", seen.wait_for(|seen| seen.held_keys_asked))
            .await
            .unwrap();
    }

    async fn mount(&self) {
        self.mount_keys().await;
        let server = self.mock.server();
        let kept = Arc::clone(&self.kept);
        Mock::given(method("POST"))
            .and(path("/_matrix/client/v3/login"))
            .respond_with(move |_: &Request| {
                let mut kept = kept.lock().unwrap();
                let (token, device) = kept.logins.remove(0);
                kept.devices.insert(format!("Bearer {token}"), device.clone());
                ResponseTemplate::new(200).set_body_json(json!({
                    "access_token": token, "device_id": device, "user_id": USER,
                }))
            })
            .mount(server)
            .await;

        let kept = Arc::clone(&self.kept);
        Mock::given(method("PUT"))
            .and(path_regex(r"^/_matrix/client/v3/sendToDevice/([^/]+)/[^/]+$"))
            .respond_with(move |request: &Request| {
                let event_type = request.url.path().split('/').nth(5).unwrap().to_owned();
                let event_type = urlencoding_decode(&event_type);
                let body: Value = serde_json::from_slice(&request.body).unwrap();
                let mut kept = kept.lock().unwrap();
                let sender = device_of(&kept, request);
                let all: Vec<String> = kept.devices.values().cloned().collect();
                for (target, content) in body["messages"][USER].as_object().into_iter().flatten() {
                    let targets: Vec<String> = if target == "*" {
                        all.iter().filter(|device| **device != sender).cloned().collect()
                    } else {
                        vec![target.clone()]
                    };
                    for device in targets {
                        kept.to_device.entry(device).or_default().push(json!({
                            "sender": USER, "type": event_type, "content": content,
                        }));
                    }
                }
                ResponseTemplate::new(200).set_body_json(json!({}))
            })
            .mount(server)
            .await;

        let kept = Arc::clone(&self.kept);
        Mock::given(method("PUT"))
            .and(path_regex(r"^/_matrix/client/v3/user/[^/]+/account_data/[^/]+$"))
            .respond_with(move |request: &Request| {
                let event_type = urlencoding_decode(request.url.path().rsplit('/').next().unwrap());
                let content: Value = serde_json::from_slice(&request.body).unwrap();
                let mut kept = kept.lock().unwrap();
                kept.account_data.retain(|(kind, _)| *kind != event_type);
                kept.account_data.push((event_type, content));
                // each device gets all of it again: what it had may have changed.
                kept.account_data_seen.clear();
                ResponseTemplate::new(200).set_body_json(json!({}))
            })
            .mount(server)
            .await;

        let kept = Arc::clone(&self.kept);
        Mock::given(method("GET"))
            .and(path_regex(r"^/_matrix/client/v3/user/[^/]+/account_data/[^/]+$"))
            .respond_with(move |request: &Request| {
                let event_type = urlencoding_decode(request.url.path().rsplit('/').next().unwrap());
                let kept = kept.lock().unwrap();
                match kept.account_data.iter().find(|(kind, _)| *kind == event_type) {
                    Some((_, content)) => ResponseTemplate::new(200).set_body_json(content),
                    None => not_found(),
                }
            })
            .mount(server)
            .await;

        self.mount_backup().await;

        let kept = Arc::clone(&self.kept);
        Mock::given(method("POST"))
            .and(path("/_matrix/client/unstable/org.matrix.simplified_msc3575/sync"))
            .respond_with(move |request: &Request| sliding_sync(&kept, request))
            .mount(server)
            .await;
    }

    /// The devices' keys: the preset keeps them, refused for the held device, and what the
    /// server saw of them goes to [`Seen`].
    async fn mount_keys(&self) {
        let server = self.mock.server();
        let kept = Arc::clone(&self.kept);
        let seen = Arc::clone(&self.seen);
        Mock::given(method("POST"))
            .and(path("/_matrix/client/v3/keys/upload"))
            .and(move |request: &Request| {
                let kept = kept.lock().unwrap();
                let device = device_of(&kept, request);
                let held = kept.held_uploads.as_ref() == Some(&device);
                let body: Value = serde_json::from_slice(&request.body).unwrap_or_default();
                // the preset's mock answers and keeps them. Wiremock answers a request before it
                // reads the next, so a test that sees them here finds them kept.
                if !held && body.get("device_keys").is_some() {
                    seen.send_if_modified(|seen| seen.keys.insert(device));
                }
                held
            })
            .respond_with(ResponseTemplate::new(400).set_body_json(json!({ "errcode": "M_UNKNOWN" })))
            // before the preset's, which keeps them.
            .with_priority(1)
            .mount(server)
            .await;

        // the held device asks for its own keys: the server has none of them yet.
        let kept = Arc::clone(&self.kept);
        let seen = Arc::clone(&self.seen);
        Mock::given(method("POST"))
            .and(path("/_matrix/client/v3/keys/query"))
            .and(move |request: &Request| {
                let kept = kept.lock().unwrap();
                let Some(held) = kept.held_uploads.as_ref() else {
                    return false;
                };
                let body: Value = serde_json::from_slice(&request.body).unwrap_or_default();
                device_of(&kept, request) == *held
                    && body["device_keys"][USER]
                        .as_array()
                        .is_some_and(|devices| devices.iter().any(|device| device == held))
            })
            .respond_with(move |_: &Request| {
                seen.send_modify(|seen| seen.held_keys_asked = true);
                ResponseTemplate::new(200).set_body_json(json!({ "device_keys": { USER: {} }, "failures": {} }))
            })
            // before the preset's.
            .with_priority(1)
            .mount(server)
            .await;
    }

    /// The key backup: none until a device makes one.
    async fn mount_backup(&self) {
        let server = self.mock.server();
        let kept = Arc::clone(&self.kept);
        Mock::given(method("GET"))
            .and(path_regex(r"^/_matrix/client/v3/room_keys/version$"))
            .respond_with(move |_: &Request| match &kept.lock().unwrap().backup {
                Some(backup) => ResponseTemplate::new(200).set_body_json(backup),
                None => not_found(),
            })
            .mount(server)
            .await;

        let kept = Arc::clone(&self.kept);
        Mock::given(method("POST"))
            .and(path_regex(r"^/_matrix/client/v3/room_keys/version$"))
            .respond_with(move |request: &Request| {
                let mut body: Value = serde_json::from_slice(&request.body).unwrap();
                body["version"] = json!("1");
                body["count"] = json!(0);
                body["etag"] = json!("0");
                kept.lock().unwrap().backup = Some(body);
                ResponseTemplate::new(200).set_body_json(json!({ "version": "1" }))
            })
            .mount(server)
            .await;

        Mock::given(method("PUT"))
            .and(path_regex(r"^/_matrix/client/v3/room_keys/keys"))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({ "count": 0, "etag": "0" })))
            .mount(server)
            .await;
    }

    /// Signs a new device in, in its own folder.
    async fn sign_in(&mut self, device: &str) -> MatrixAccount {
        // the crypto endpoints know a device by its token: one they made.
        let index = {
            let kept = self.kept();
            kept.devices.len() + kept.logins.len()
        };
        drop(
            self.mock
                .client_builder_for_crypto_end_to_end(user_id!("@ada:example.org"), device.into()),
        );
        self.kept().logins.push((format!("TOKEN_{index}"), device.to_owned()));
        let folder = tempfile::tempdir().unwrap();
        let sign_in = MatrixSignIn::new(StoreFolder::new(folder.path()), Arc::new(MemorySecrets::default()));
        self.folders.push(folder);
        let uri = self.mock.uri();
        let signing_in = sign_in.sign_in_with_password(&uri, "ada", "secret", device);
        within("the sign-in", Box::pin(signing_in)).await.unwrap()
    }
}

fn not_found() -> ResponseTemplate {
    ResponseTemplate::new(404).set_body_json(json!({ "errcode": "M_NOT_FOUND", "error": "not found" }))
}

fn urlencoding_decode(text: &str) -> String {
    url::form_urlencoded::parse(format!("x={text}").as_bytes())
        .next()
        .map(|(_, value)| value.into_owned())
        .unwrap()
}

fn device_of(kept: &Kept, request: &Request) -> String {
    let token = request.headers.get("authorization").unwrap().to_str().unwrap();
    kept.devices.get(token).cloned().unwrap()
}

/// A sliding sync answer: the device's to-device messages and the account's keys changed on the
/// encryption connection, the account data it has not had on the others; no rooms.
fn sliding_sync(kept: &Mutex<Kept>, request: &Request) -> ResponseTemplate {
    let body: Value = serde_json::from_slice(&request.body).unwrap_or_default();
    let connection = body["conn_id"].as_str().unwrap_or_default().to_owned();
    let mut kept = kept.lock().unwrap();
    let device = device_of(&kept, request);
    let position = {
        let position = kept.positions.entry(format!("{device}/{connection}")).or_default();
        *position += 1;
        *position
    };
    let mut answer = json!({ "pos": position.to_string(), "lists": {}, "rooms": {} });
    let mut news = false;
    if connection == "encryption" {
        let events = kept.to_device.remove(&device).unwrap_or_default();
        news = !events.is_empty();
        answer["extensions"] = json!({
            "to_device": { "next_batch": position.to_string(), "events": events },
            // the account's devices may have changed: each device asks again.
            "e2ee": { "device_lists": { "changed": [USER], "left": [] } },
        });
    } else {
        answer["lists"] = json!({ "all_rooms": { "count": 0 } });
        let seen = kept.account_data_seen.get(&device).copied().unwrap_or_default();
        let events: Vec<Value> = kept.account_data[seen..]
            .iter()
            .map(|(kind, content)| json!({ "type": kind, "content": content }))
            .collect();
        news = news || !events.is_empty();
        let all = kept.account_data.len();
        kept.account_data_seen.insert(device, all);
        answer["extensions"] = json!({ "account_data": { "global": events } });
    }
    let template = ResponseTemplate::new(200).set_body_json(answer);
    // nothing new: the server holds the request a moment, as a long poll does.
    if news {
        template
    } else {
        template.set_delay(Duration::from_millis(150))
    }
}

async fn within<T>(what: &str, future: impl Future<Output = T>) -> T {
    tokio::time::timeout(Duration::from_secs(30), future)
        .await
        .unwrap_or_else(|_| panic!("{what} did not happen in time"))
}

/// Waits for `setup` to say `wanted`.
async fn setup_becomes(setup: &mut ValueStream<EncryptionSetup>, wanted: EncryptionSetup) {
    within(&format!("{wanted:?}"), async {
        while let Some(now) = setup.next().await {
            if now == wanted {
                return;
            }
        }
        panic!("the setups ended before {wanted:?}");
    })
    .await;
}

/// Waits for the emojis to compare.
async fn emojis(steps: &mut ValueStream<VerificationStep>) -> Vec<VerificationEmoji> {
    within("the emojis", async {
        while let Some(step) = steps.next().await {
            match step {
                VerificationStep::Compare(emojis) => return emojis,
                VerificationStep::Done | VerificationStep::Cancelled | VerificationStep::Failed => {
                    panic!("the verification ended at {step:?}")
                }
                _ => {}
            }
        }
        panic!("the steps ended");
    })
    .await
}

async fn done(steps: &mut ValueStream<VerificationStep>) {
    within("the end of the verification", async {
        while let Some(step) = steps.next().await {
            match step {
                VerificationStep::Done => return,
                VerificationStep::Cancelled | VerificationStep::Failed => panic!("the verification ended at {step:?}"),
                _ => {}
            }
        }
    })
    .await;
}

/// A new account, set up with recovery on its first device: the key, and the device.
async fn account_with_recovery(server: &mut Homeserver) -> (MatrixAccount, String) {
    let first = server.sign_in("FIRSTDEVICE").await;
    let mut setup = first.encryption_setup();
    setup_becomes(&mut setup, EncryptionSetup::SetUpRecovery).await;
    let key = within("the recovery's setup", first.set_up_recovery()).await.unwrap();
    setup_becomes(&mut setup, EncryptionSetup::Ready).await;
    (first, key)
}

#[tokio::test(flavor = "multi_thread")]
async fn a_new_account_sets_up_recovery_and_its_key_verifies_the_next_device() {
    let mut server = Homeserver::start().await;
    let (first, key) = account_with_recovery(&mut server).await;
    assert!(first.is_device_verified().await);
    assert!(server.kept().backup.is_some(), "a key backup was made");
    // once set up, it is not set up again.
    assert!(first.set_up_recovery().await.is_err());

    let second = server.sign_in("SECONDDEVICE").await;
    let mut setup = second.encryption_setup();
    setup_becomes(
        &mut setup,
        EncryptionSetup::VerifyThisDevice {
            with_recovery_key: true,
        },
    )
    .await;
    assert!(second.recover("EsTx not the key").await.is_err());
    within("the recovery", second.recover(&key)).await.unwrap();
    setup_becomes(&mut setup, EncryptionSetup::Ready).await;
    assert!(second.is_device_verified().await);
}

#[tokio::test(flavor = "multi_thread")]
async fn the_recovery_key_waits_for_the_device_keys_to_reach_the_server() {
    let mut server = Homeserver::start().await;
    let (_first, key) = account_with_recovery(&mut server).await;
    server.kept().held_uploads = Some("SECONDDEVICE".to_owned());
    let second = server.sign_in("SECONDDEVICE").await;
    let mut setup = second.encryption_setup();
    setup_becomes(
        &mut setup,
        EncryptionSetup::VerifyThisDevice {
            with_recovery_key: true,
        },
    )
    .await;
    // the key, entered while the device's keys are still on their way: they arrive once the
    // device has found them missing.
    let arrive = async {
        server.held_keys_asked().await;
        server.kept().held_uploads = None;
    };
    let (recovered, ()) = tokio::join!(within("the recovery", second.recover(&key)), arrive);
    recovered.unwrap();
    setup_becomes(&mut setup, EncryptionSetup::Ready).await;
}

#[tokio::test(flavor = "multi_thread")]
async fn a_new_device_is_verified_by_accepting_its_request_on_another() {
    let mut server = Homeserver::start().await;
    let (first, _) = account_with_recovery(&mut server).await;
    let mut requests = first.verification_requests();

    let second = server.sign_in("SECONDDEVICE").await;
    let mut setup = second.encryption_setup();
    setup_becomes(
        &mut setup,
        EncryptionSetup::VerifyThisDevice {
            with_recovery_key: true,
        },
    )
    .await;
    let asking = second.verify_this_device().await.unwrap();
    let mut asking_steps = asking.steps();

    let asked = within("the request", requests.next()).await.unwrap();
    assert_eq!(
        asked.other_device().map(|device| device.id),
        Some("SECONDDEVICE".to_owned())
    );
    let mut asked_steps = asked.steps();
    assert_eq!(asked_steps.next().await, Some(VerificationStep::Requested));
    asked.accept().await.unwrap();

    let (here, there) = tokio::join!(emojis(&mut asked_steps), emojis(&mut asking_steps));
    assert_eq!(here, there, "both devices show the same emojis");
    assert_eq!(here.len(), 7);
    asked.confirm().await.unwrap();
    asking.confirm().await.unwrap();
    tokio::join!(done(&mut asked_steps), done(&mut asking_steps));

    setup_becomes(&mut setup, EncryptionSetup::Ready).await;
    assert!(second.is_device_verified().await);
}

#[tokio::test(flavor = "multi_thread")]
async fn a_verified_device_verifies_another_of_the_account() {
    let mut server = Homeserver::start().await;
    let (first, _) = account_with_recovery(&mut server).await;
    let second = server.sign_in("SECONDDEVICE").await;
    let mut requests = second.verification_requests();
    let mut setup = second.encryption_setup();
    setup_becomes(
        &mut setup,
        EncryptionSetup::VerifyThisDevice {
            with_recovery_key: true,
        },
    )
    .await;

    // the account's devices, as the server has them once the second's keys are there.
    server.has_keys_of("SECONDDEVICE").await;
    let devices = first.own_devices().await.unwrap();
    assert_eq!(devices.len(), 2, "{devices:?}");
    assert!(devices[0].is_this_device && devices[0].is_verified, "this device first");
    assert_eq!(devices[1].id, "SECONDDEVICE");
    assert!(!devices[1].is_verified);
    assert!(first.verify_device("FIRSTDEVICE").await.is_err(), "not this device");

    let asking = first.verify_device("SECONDDEVICE").await.unwrap();
    assert_eq!(
        asking.other_device().map(|device| device.id),
        Some("SECONDDEVICE".to_owned())
    );
    let mut asking_steps = asking.steps();
    assert_eq!(asking_steps.next().await, Some(VerificationStep::Waiting));
    let asked = within("the request", requests.next()).await.unwrap();
    assert_eq!(
        asked.other_device().map(|device| device.id),
        Some("FIRSTDEVICE".to_owned())
    );
    let mut asked_steps = asked.steps();
    asked.accept().await.unwrap();
    let (here, there) = tokio::join!(emojis(&mut asking_steps), emojis(&mut asked_steps));
    assert_eq!(here, there);
    asking.confirm().await.unwrap();
    asked.confirm().await.unwrap();
    tokio::join!(done(&mut asking_steps), done(&mut asked_steps));

    setup_becomes(&mut setup, EncryptionSetup::Ready).await;
}

#[tokio::test(flavor = "multi_thread")]
async fn emojis_that_do_not_match_fail_on_both_devices() {
    let mut server = Homeserver::start().await;
    let (first, _) = account_with_recovery(&mut server).await;
    let mut requests = first.verification_requests();
    let second = server.sign_in("SECONDDEVICE").await;
    let mut setup = second.encryption_setup();
    setup_becomes(
        &mut setup,
        EncryptionSetup::VerifyThisDevice {
            with_recovery_key: true,
        },
    )
    .await;
    let asking = second.verify_this_device().await.unwrap();
    let mut asking_steps = asking.steps();
    let asked = within("the request", requests.next()).await.unwrap();
    let mut asked_steps = asked.steps();
    asked.accept().await.unwrap();
    tokio::join!(emojis(&mut asked_steps), emojis(&mut asking_steps));
    asked.deny().await.unwrap();

    for steps in [&mut asked_steps, &mut asking_steps] {
        let last = within("the failure", async {
            loop {
                match steps.next().await {
                    Some(step @ (VerificationStep::Failed | VerificationStep::Cancelled | VerificationStep::Done)) => {
                        return step;
                    }
                    Some(_) => {}
                    None => panic!("the steps ended"),
                }
            }
        })
        .await;
        assert_eq!(last, VerificationStep::Failed);
    }
    assert!(!second.is_device_verified().await);
}

#[tokio::test(flavor = "multi_thread")]
async fn on_a_server_with_an_account_service_another_device_signs_out_on_its_page() {
    let mut server = Homeserver::start().await;
    let first = server.sign_in("FIRSTDEVICE").await;
    server.mock.oauth().mock_server_metadata().ok().mount().await;

    let sign_out = first.device_sign_out("SECONDDEVICE").await.unwrap();
    let DeviceSignOut::InBrowser(address) = sign_out else {
        panic!("signed out with {sign_out:?}");
    };
    let address = url::Url::parse(&address).unwrap();
    assert!(address.path().ends_with("/account"), "{address}");
    let query: Vec<(String, String)> = address.query_pairs().into_owned().collect();
    assert!(
        query.contains(&("action".to_owned(), "org.matrix.session_end".to_owned())),
        "{query:?}"
    );
    assert!(
        query.contains(&("device_id".to_owned(), "SECONDDEVICE".to_owned())),
        "{query:?}"
    );
    // this device signs out on its own.
    assert!(matches!(
        first.device_sign_out("FIRSTDEVICE").await,
        Err(BackendError::NotAllowed)
    ));
}

#[tokio::test(flavor = "multi_thread")]
async fn on_a_server_without_one_another_device_signs_out_with_the_password() {
    let mut server = Homeserver::start().await;
    let first = server.sign_in("FIRSTDEVICE").await;
    Mock::given(method("GET"))
        .and(path("/_matrix/client/unstable/org.matrix.msc2965/auth_metadata"))
        .respond_with(
            ResponseTemplate::new(404)
                .set_body_json(json!({ "errcode": "M_UNRECOGNIZED", "error": "Unrecognized request" })),
        )
        .mount(server.mock.server())
        .await;
    // the server's deletion, behind the account's password.
    let deleted = Arc::new(Mutex::new(Vec::<Value>::new()));
    let kept = Arc::clone(&deleted);
    Mock::given(method("POST"))
        .and(path("/_matrix/client/v3/delete_devices"))
        .respond_with(move |request: &Request| {
            let body: Value = serde_json::from_slice(&request.body).unwrap();
            let asked = json!({ "flows": [{ "stages": ["m.login.password"] }], "params": {}, "session": "UIA" });
            let auth = &body["auth"];
            if auth.is_null() {
                return ResponseTemplate::new(401).set_body_json(asked);
            }
            let right = auth["type"] == "m.login.password"
                && auth["session"] == "UIA"
                && auth["identifier"]["user"] == USER
                && auth["password"] == "secret";
            if !right {
                let mut refused = asked;
                refused["errcode"] = json!("M_FORBIDDEN");
                refused["error"] = json!("Invalid password");
                return ResponseTemplate::new(401).set_body_json(refused);
            }
            kept.lock().unwrap().push(body["devices"].clone());
            ResponseTemplate::new(200).set_body_json(json!({}))
        })
        .mount(server.mock.server())
        .await;

    assert_eq!(
        first.device_sign_out("SECONDDEVICE").await.unwrap(),
        DeviceSignOut::WithPassword
    );
    assert!(matches!(
        first.sign_out_device("SECONDDEVICE", "not it").await,
        Err(BackendError::WrongCredentials)
    ));
    assert!(deleted.lock().unwrap().is_empty());
    first.sign_out_device("SECONDDEVICE", "secret").await.unwrap();
    assert_eq!(*deleted.lock().unwrap(), vec![json!(["SECONDDEVICE"])]);
    assert!(matches!(
        first.sign_out_device("FIRSTDEVICE", "secret").await,
        Err(BackendError::NotAllowed)
    ));
}
