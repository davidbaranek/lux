//! People to write to, and starting a conversation with one.
//!
//! - **Matrix**: the server's user directory, or a full user id as typed. A conversation with a
//!   person is an encrypted direct chat; with a bridge's bot or ghost, one without encryption (a
//!   bridge that has not set up encryption cannot read an encrypted room).
//! - **Bridges**: a server that runs mautrix bridges names them in its
//!   `/.well-known/matrix/mautrix` (`fi.mau.bridges`); each bridge's provisioning API (v3) says
//!   which logins the user has there (`whoami`), lists each login's contacts, searches its
//!   network, and opens the direct chat with one. Only a bridge on the server's own origin is
//!   asked, with the account's token.

use std::collections::HashSet;

use lux_core::ids::{MediaId, RoomId};
use lux_core::network::Network;
use lux_core::ports::{BackendError, Contact, ContactAccount, ContactListing, ContactProblem, People};
use matrix_sdk::Client;
use matrix_sdk::reqwest::{Method, StatusCode, Url};
use matrix_sdk::ruma::api::client::room::Visibility;
use matrix_sdk::ruma::api::client::room::create_room::v3::{Request as CreateRoom, RoomPreset};
use matrix_sdk::ruma::events::InitialStateEvent;
use matrix_sdk::ruma::events::room::encryption::RoomEncryptionEventContent;
use matrix_sdk::ruma::{OwnedUserId, UserId as SdkUserId};
use serde::Deserialize;
use serde::de::DeserializeOwned;
use serde_json::json;

use crate::account::MatrixAccount;
use crate::errors::from_sdk;

/// The most people the user directory answers with.
const DIRECTORY_LIMIT: u64 = 100;

impl People for MatrixAccount {
    async fn contacts(&self, query: &str) -> Result<ContactListing, BackendError> {
        let query = query.trim();
        let mut listing = ContactListing::default();
        if let Ok(user) = <&SdkUserId>::try_from(query) {
            // a full id stays selectable when the directory leaves it out.
            listing.contacts.push(matrix_contact(user, None, None));
            return Ok(listing);
        }
        if !query.is_empty() {
            match self.client.search_users(query, DIRECTORY_LIMIT).await {
                Ok(found) => listing.contacts.extend(found.results.iter().map(|user| {
                    matrix_contact(
                        &user.user_id,
                        user.display_name.as_deref(),
                        user.avatar_url.as_ref().map(|url| url.as_str()),
                    )
                })),
                Err(_) => listing.problems.push(ContactProblem::MatrixSearch),
            }
        }
        let bridges = Bridges::new(&self.client)?;
        let (sources, problem) = bridges.sources().await;
        listing.problems.extend(problem);
        for source in &sources {
            match bridges.contacts(source, query).await {
                Ok(contacts) => listing.contacts.extend(contacts),
                Err(_) => listing.problems.push(ContactProblem::Account(source.name.clone())),
            }
        }
        Ok(listing)
    }

    async fn start_conversation(&self, contact: &Contact) -> Result<RoomId, BackendError> {
        match &contact.account {
            ContactAccount::Matrix => {
                let user = OwnedUserId::try_from(contact.identifier.as_str())
                    .map_err(|_| BackendError::UnknownContact(contact.identifier.clone()))?;
                self.direct_chat(&user).await
            }
            ContactAccount::Bridge(key) => {
                let bridges = Bridges::new(&self.client)?;
                let (sources, _) = bridges.sources().await;
                let source = sources
                    .iter()
                    .find(|source| source.key == *key)
                    .ok_or_else(|| BackendError::UnknownContact(contact.identifier.clone()))?;
                bridges.start(source, &contact.identifier).await
            }
        }
    }

    async fn create_room(&self, name: &str) -> Result<RoomId, BackendError> {
        let mut request = CreateRoom::new();
        request.name = Some(name.trim().to_owned());
        request.preset = Some(RoomPreset::PrivateChat);
        request.visibility = Visibility::Private;
        request.initial_state = vec![encryption()];
        let room = self.client.create_room(request).await.map_err(from_sdk)?;
        Ok(RoomId::from(room.room_id().as_str()))
    }
}

impl MatrixAccount {
    /// The joined direct chat with `user`, else a new one: encrypted with a person, without
    /// encryption with a bridge's user.
    async fn direct_chat(&self, user: &SdkUserId) -> Result<RoomId, BackendError> {
        if let Some(room) = self.client.get_dm_rooms(user).next() {
            return Ok(RoomId::from(room.room_id().as_str()));
        }
        let is_bridge = is_bridge_user(user.as_str());
        let mut request = CreateRoom::new();
        request.is_direct = true;
        request.visibility = Visibility::Private;
        if self.client.user_id() != Some(user) {
            request.invite = vec![user.to_owned()];
        }
        if is_bridge {
            request.preset = Some(RoomPreset::PrivateChat);
        } else {
            request.preset = Some(RoomPreset::TrustedPrivateChat);
            request.initial_state = vec![encryption()];
        }
        let room = self.client.create_room(request).await.map_err(from_sdk)?;
        Ok(RoomId::from(room.room_id().as_str()))
    }
}

fn encryption() -> matrix_sdk::ruma::serde::Raw<matrix_sdk::ruma::events::AnyInitialStateEvent> {
    InitialStateEvent::with_empty_state_key(RoomEncryptionEventContent::with_recommended_defaults()).to_raw_any()
}

/// A bridge's bot or one of its ghosts: a user a bridge stands for (mautrix-meta's `@metabot`
/// and `@meta_…` too).
fn is_bridge_user(user: &str) -> bool {
    Network::from_bridge_user(user).is_some()
}

fn matrix_contact(user: &SdkUserId, name: Option<&str>, avatar: Option<&str>) -> Contact {
    Contact {
        id: format!("matrix:{user}"),
        account: ContactAccount::Matrix,
        name: name.filter(|name| !name.is_empty()).unwrap_or(user.as_str()).to_owned(),
        identifier: user.to_string(),
        network: Network::Matrix.as_str().to_owned(),
        avatar: avatar.filter(|url| !url.is_empty()).map(MediaId::from),
    }
}

/// One login a bridge holds for the user.
struct Source {
    /// The bridge's provisioning API.
    base: Url,
    /// The login's id at the bridge.
    login: String,
    /// The core's key for it: the bridge and the login, as JSON, so neither's characters clash.
    key: String,
    /// "WhatsApp: Anna (+49…)".
    name: String,
    /// The network's id (`"whatsapp"`).
    network: String,
}

/// A contact as the bridge resolves it.
#[derive(Deserialize)]
struct Resolved {
    id: String,
    name: Option<String>,
    avatar_url: Option<String>,
    identifiers: Option<Vec<String>>,
    mxid: Option<String>,
    dm_room_mxid: Option<String>,
}

/// Why a bridge's call failed.
#[derive(Debug, thiserror::Error)]
enum BridgeError {
    /// The bridge does not offer the call.
    #[error("the bridge does not offer the call")]
    Unsupported,
    /// Not found.
    #[error("the bridge found nothing")]
    NotFound,
    /// Anything else.
    #[error("the bridge's call failed")]
    Failed,
}

/// The server's bridges, asked with the account's token.
struct Bridges<'a> {
    client: &'a Client,
    home: Url,
    user: String,
    token: String,
}

impl<'a> Bridges<'a> {
    fn new(client: &'a Client) -> Result<Self, BackendError> {
        Ok(Self {
            client,
            home: client.homeserver(),
            user: client.user_id().ok_or(BackendError::SignedOut)?.to_string(),
            token: client.access_token().ok_or(BackendError::SignedOut)?,
        })
    }

    /// The logins of every bridge the server names, and what could not be read.
    async fn sources(&self) -> (Vec<Source>, Option<ContactProblem>) {
        #[derive(Deserialize)]
        struct Discovery {
            #[serde(rename = "fi.mau.bridges", default)]
            bridges: Vec<String>,
        }
        let mut discovery_url = self.home.clone();
        discovery_url.set_path("/.well-known/matrix/mautrix");
        let discovery: Discovery = match self.call(Method::GET, discovery_url, None, false).await {
            Ok(found) => found,
            Err(BridgeError::NotFound) => return (Vec::new(), None),
            Err(_) => return (Vec::new(), Some(ContactProblem::Discovery)),
        };
        let mut bases: Vec<String> = discovery.bridges;
        bases.sort();
        bases.dedup();
        let mut sources = Vec::new();
        let mut problem = None;
        for base in bases {
            match self.logins(&base).await {
                Some(found) => sources.extend(found),
                None => problem = Some(ContactProblem::SomeAccounts),
            }
        }
        (sources, problem)
    }

    async fn logins(&self, base: &str) -> Option<Vec<Source>> {
        #[derive(Deserialize)]
        struct Whoami {
            network: WhoNetwork,
            #[serde(default)]
            logins: Vec<Login>,
        }
        #[derive(Deserialize)]
        struct WhoNetwork {
            displayname: String,
            network_id: String,
        }
        #[derive(Deserialize)]
        struct Login {
            id: String,
            name: String,
            profile: Option<LoginProfile>,
        }
        #[derive(Deserialize)]
        struct LoginProfile {
            name: Option<String>,
        }
        let base = Url::parse(base).ok().filter(|base| self.trusted(base))?;
        let mut url = endpoint(&base, "whoami", None)?;
        url.query_pairs_mut().append_pair("user_id", &self.user);
        let who: Whoami = self.call(Method::GET, url, None, true).await.ok()?;
        Some(
            who.logins
                .into_iter()
                .map(|login| {
                    let labels: Vec<&str> = [
                        login.profile.as_ref().and_then(|profile| profile.name.as_deref()),
                        Some(login.name.as_str()),
                    ]
                    .into_iter()
                    .flatten()
                    .filter(|label| !label.is_empty())
                    .collect();
                    let label = match labels.as_slice() {
                        [first, second] if first != second => format!("{first} ({second})"),
                        [first, ..] => (*first).to_owned(),
                        [] => login.id.clone(),
                    };
                    Source {
                        key: json!([base.as_str(), login.id]).to_string(),
                        name: format!("{}: {label}", who.network.displayname),
                        network: who.network.network_id.clone(),
                        base: base.clone(),
                        login: login.id,
                    }
                })
                .collect(),
        )
    }

    /// A login's contacts: all of them for no query; else those that match, the network's
    /// search, else the identifier as the network resolves it.
    async fn contacts(&self, source: &Source, query: &str) -> Result<Vec<Contact>, BridgeError> {
        #[derive(Deserialize)]
        struct Contacts {
            contacts: Vec<Resolved>,
        }
        #[derive(Deserialize)]
        struct Search {
            results: Vec<Resolved>,
        }
        let mut found: Vec<Resolved> = Vec::new();
        let mut listing_unsupported = false;
        match self
            .bridge::<Contacts>(source, Method::GET, "contacts", None, None)
            .await
        {
            Ok(contacts) => found = contacts.contacts,
            Err(BridgeError::Unsupported) => listing_unsupported = true,
            Err(error) => return Err(error),
        }
        if query.is_empty() {
            if listing_unsupported {
                return Err(BridgeError::Unsupported);
            }
        } else {
            let wanted = query.to_lowercase();
            found.retain(|contact| {
                std::iter::once(&contact.id)
                    .chain(contact.name.as_ref())
                    .chain(contact.identifiers.iter().flatten())
                    .any(|text| text.to_lowercase().contains(&wanted))
            });
            let body = json!({ "query": query });
            match self
                .bridge::<Search>(source, Method::POST, "search_users", None, Some(body))
                .await
            {
                Ok(search) => found.extend(search.results),
                Err(BridgeError::Unsupported) => {}
                Err(error) => return Err(error),
            }
            if found.is_empty() {
                match self
                    .bridge::<Resolved>(source, Method::GET, "resolve_identifier", Some(query), None)
                    .await
                {
                    Ok(resolved) => found.push(resolved),
                    Err(BridgeError::NotFound) => {}
                    Err(error) => return Err(error),
                }
            }
        }
        let mut seen = HashSet::new();
        Ok(found
            .into_iter()
            .filter(|contact| seen.insert(contact.id.clone()))
            .map(|contact| Contact {
                id: format!("{}:{}", source.key, contact.id),
                account: ContactAccount::Bridge(source.key.clone()),
                name: contact
                    .name
                    .filter(|name| !name.is_empty())
                    .or_else(|| contact.identifiers.and_then(|ids| ids.into_iter().next()))
                    .unwrap_or_else(|| contact.id.clone()),
                identifier: contact.mxid.unwrap_or(contact.id),
                network: source.network.clone(),
                avatar: contact.avatar_url.filter(|url| !url.is_empty()).map(MediaId::from),
            })
            .collect())
    }

    /// The direct chat with `identifier` on the login's network: the one there is, else a new
    /// one the bridge makes.
    async fn start(&self, source: &Source, identifier: &str) -> Result<RoomId, BackendError> {
        let failed = BackendError::refused;
        let resolved: Resolved = self
            .bridge(source, Method::GET, "resolve_identifier", Some(identifier), None)
            .await
            .map_err(failed)?;
        if let Some(room) = resolved.dm_room_mxid.filter(|room| !room.is_empty()) {
            return Ok(RoomId::from(room));
        }
        let target = resolved.mxid.unwrap_or_else(|| identifier.to_owned());
        let created: Resolved = self
            .bridge(source, Method::POST, "create_dm", Some(&target), None)
            .await
            .map_err(failed)?;
        created
            .dm_room_mxid
            .filter(|room| !room.is_empty())
            .map(RoomId::from)
            .ok_or_else(|| BackendError::refused("the bridge gave no chat"))
    }

    async fn bridge<T: DeserializeOwned>(
        &self,
        source: &Source,
        method: Method,
        operation: &str,
        identifier: Option<&str>,
        body: Option<serde_json::Value>,
    ) -> Result<T, BridgeError> {
        let mut url = endpoint(&source.base, operation, identifier).ok_or(BridgeError::Failed)?;
        url.query_pairs_mut()
            .append_pair("login_id", &source.login)
            .append_pair("user_id", &self.user);
        self.call(method, url, body, true).await
    }

    /// The server's own origin (which has the token anyway), with nothing else in the address.
    fn trusted(&self, url: &Url) -> bool {
        url.scheme() == self.home.scheme()
            && url.host_str().map(str::to_lowercase) == self.home.host_str().map(str::to_lowercase)
            && url.port_or_known_default() == self.home.port_or_known_default()
            && url.username().is_empty()
            && url.password().is_none()
            && url.query().is_none()
            && url.fragment().is_none()
    }

    async fn call<T: DeserializeOwned>(
        &self,
        method: Method,
        url: Url,
        body: Option<serde_json::Value>,
        authenticated: bool,
    ) -> Result<T, BridgeError> {
        if !self.trusted(&url) {
            return Err(BridgeError::Failed);
        }
        let mut request = self.client.http_client().request(method, url);
        if authenticated {
            request = request.bearer_auth(&self.token);
        }
        if let Some(body) = body {
            request = request.json(&body);
        }
        let response = request.send().await.map_err(|_| BridgeError::Failed)?;
        match response.status() {
            status if status.is_success() => response.json::<T>().await.map_err(|_| BridgeError::Failed),
            StatusCode::NOT_IMPLEMENTED => Err(BridgeError::Unsupported),
            StatusCode::NOT_FOUND => Err(BridgeError::NotFound),
            _ => Err(BridgeError::Failed),
        }
    }
}

/// `<base>/_matrix/provision/v3/<operation>[/<identifier>]`, the identifier one path segment
/// even when it holds a slash.
fn endpoint(base: &Url, operation: &str, identifier: Option<&str>) -> Option<Url> {
    let mut url = base.clone();
    {
        let mut path = url.path_segments_mut().ok()?;
        path.pop_if_empty().extend(["_matrix", "provision", "v3", operation]);
        if let Some(identifier) = identifier {
            path.push(identifier);
        }
    }
    Some(url)
}

#[cfg(test)]
mod tests {
    use matrix_sdk::reqwest::Url;

    use super::{endpoint, is_bridge_user};

    #[test]
    fn an_identifier_is_one_segment() {
        let base = Url::parse("https://example.org/bridges/whatsapp").unwrap();
        let url = endpoint(&base, "resolve_identifier", Some("+49 1/2")).unwrap();
        assert_eq!(
            url.as_str(),
            "https://example.org/bridges/whatsapp/_matrix/provision/v3/resolve_identifier/+49%201%2F2"
        );
    }

    #[test]
    fn bridge_users_are_known() {
        assert!(is_bridge_user("@whatsappbot:example.org"));
        assert!(is_bridge_user("@instagram_123:example.org"));
        assert!(!is_bridge_user("@anna:example.org"));
    }
}
