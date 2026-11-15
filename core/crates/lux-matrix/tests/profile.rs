//! The account's own profile against a mock homeserver that keeps it: reading it, changing the
//! display name, uploading a picture and removing it, and a server that does not let the name
//! change.

// the sdk's futures nest deeply.
#![recursion_limit = "256"]
// a test crate: a failed step is the test failing.
#![allow(clippy::unwrap_used, clippy::expect_used)]

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use lux_core::ports::{
    AccountProfile, BackendError, Picture, PictureFormat, SecretStore, SecretStoreError, SessionSecrets, SignIn,
    StoreKey,
};
use lux_matrix::{MatrixAccount, MatrixSignIn, StoreFolder};
use matrix_sdk::ruma::mxc_uri;
use matrix_sdk::test_utils::mocks::MatrixMockServer;
use serde_json::{Value, json};
use wiremock::matchers::{method, path, path_regex};
use wiremock::{Mock, Request, Respond, ResponseTemplate};

/// The whole profile, or one of its fields.
const PROFILE: &str = r"^/_matrix/client/v3/profile/[^/]+(/(displayname|avatar_url))?$";

/// The platform's Keychain, in memory.
#[derive(Default)]
struct MemorySecrets(Mutex<Option<SessionSecrets>>, Mutex<Option<StoreKey>>);

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

/// The profile's fields as the server keeps them.
#[derive(Clone, Default)]
struct Fields(Arc<Mutex<HashMap<String, Value>>>);

impl Fields {
    fn get(&self, field: &str) -> Option<Value> {
        self.0.lock().unwrap().get(field).cloned()
    }
}

impl Respond for Fields {
    fn respond(&self, request: &Request) -> ResponseTemplate {
        let field = request.url.path().rsplit('/').next().unwrap().to_owned();
        let mut fields = self.0.lock().unwrap();
        match request.method.as_str() {
            "GET" if field.starts_with('@') => ResponseTemplate::new(200).set_body_json(Value::Object(
                fields.iter().map(|(key, value)| (key.clone(), value.clone())).collect(),
            )),
            "GET" => match fields.get(&field) {
                Some(value) => ResponseTemplate::new(200).set_body_json(json!({ field: value })),
                None => ResponseTemplate::new(404)
                    .set_body_json(json!({ "errcode": "M_NOT_FOUND", "error": "no such field" })),
            },
            "PUT" => {
                let body: Value = serde_json::from_slice(&request.body).unwrap();
                match body.get(&field) {
                    // the legacy endpoints remove a field set to null or, as Synapse takes it, "".
                    Some(Value::Null) | None => fields.remove(&field),
                    Some(Value::String(value)) if value.is_empty() => fields.remove(&field),
                    Some(value) => fields.insert(field, value.clone()),
                };
                ResponseTemplate::new(200).set_body_json(json!({}))
            }
            "DELETE" => {
                fields.remove(&field);
                ResponseTemplate::new(200).set_body_json(json!({}))
            }
            _ => ResponseTemplate::new(405),
        }
    }
}

/// A server keeping a profile named `name`, whose `capabilities` are as given.
async fn server(name: &str, capabilities: Value) -> (MatrixMockServer, Fields) {
    let server = MatrixMockServer::new().await;
    server.mock_versions().with_simplified_sliding_sync().ok().mount().await;
    server.mock_login().ok().mount().await;
    Mock::given(method("GET"))
        .and(path("/_matrix/client/v3/capabilities"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({ "capabilities": capabilities })))
        .mount(server.server())
        .await;
    let fields = Fields::default();
    fields.0.lock().unwrap().insert("displayname".to_owned(), json!(name));
    Mock::given(path_regex(PROFILE))
        .respond_with(fields.clone())
        .mount(server.server())
        .await;
    (server, fields)
}

/// A signed-in account of `server`, in a new folder (kept with it).
async fn signed_in(server: &MatrixMockServer) -> (MatrixAccount, tempfile::TempDir) {
    let folder = tempfile::tempdir().unwrap();
    let sign_in = MatrixSignIn::new(StoreFolder::new(folder.path()), Arc::new(MemorySecrets::default()));
    let account = sign_in
        .sign_in_with_password(&server.uri(), "cheeky_monkey", "secret", "Lux (Test)")
        .await
        .unwrap();
    (account, folder)
}

#[tokio::test(flavor = "multi_thread")]
async fn the_name_changes_trimmed_and_an_empty_one_removes_it() {
    let (server, fields) = server("Cheeky", json!({})).await;
    let (account, _folder) = signed_in(&server).await;

    let profile = account.profile().await.unwrap();
    assert_eq!(profile.user_id.as_str(), "@cheeky_monkey:matrix.org");
    assert_eq!(profile.name.as_deref(), Some("Cheeky"));
    assert_eq!(profile.avatar, None);
    assert!(profile.can_change_name && profile.can_change_avatar);

    account.set_name("  Monkey  ").await.unwrap();
    assert_eq!(fields.get("displayname"), Some(json!("Monkey")));
    assert_eq!(account.profile().await.unwrap().name.as_deref(), Some("Monkey"));

    account.set_name("   ").await.unwrap();
    assert_eq!(fields.get("displayname"), None);
    assert_eq!(account.profile().await.unwrap().name, None);
}

#[tokio::test(flavor = "multi_thread")]
async fn a_name_too_long_is_not_sent() {
    let (server, fields) = server("Cheeky", json!({})).await;
    let (account, _folder) = signed_in(&server).await;

    let error = account.set_name(&"x".repeat(257)).await.unwrap_err();
    assert!(matches!(error, BackendError::NameTooLong));
    assert_eq!(fields.get("displayname"), Some(json!("Cheeky")));
}

#[tokio::test(flavor = "multi_thread")]
async fn a_picture_is_uploaded_set_and_removed() {
    let (server, fields) = server("Cheeky", json!({})).await;
    let (account, _folder) = signed_in(&server).await;
    let url = mxc_uri!("mxc://matrix.org/picture");
    server.mock_authenticated_media_config().ok_default().mount().await;
    let (upload, mock) = server.mock_upload().expect_mime_type("image/jpeg").ok_with_capture(url);
    mock.mock_once().mount().await;

    let picture = Picture {
        data: b"a jpeg".to_vec(),
        format: PictureFormat::Jpeg,
    };
    let avatar = account.set_avatar(picture).await.unwrap();
    assert_eq!(avatar.as_str(), url.as_str());
    assert_eq!(upload.await.unwrap(), b"a jpeg");
    assert_eq!(fields.get("avatar_url"), Some(json!(url.as_str())));
    assert_eq!(account.profile().await.unwrap().avatar, Some(avatar));

    account.remove_avatar().await.unwrap();
    assert_eq!(fields.get("avatar_url"), None);
    assert_eq!(account.profile().await.unwrap().avatar, None);
}

#[tokio::test(flavor = "multi_thread")]
async fn a_server_that_keeps_the_name_says_so() {
    let capabilities = json!({ "m.set_displayname": { "enabled": false } });
    let (server, _fields) = server("Cheeky", capabilities).await;
    let (account, _folder) = signed_in(&server).await;

    let profile = account.profile().await.unwrap();
    assert!(!profile.can_change_name);
    assert!(profile.can_change_avatar);
}
