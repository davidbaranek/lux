//! People to write to, and starting a conversation with one.
//!
//! - **Matrix**: the server's user directory, or a full user id as typed. A conversation with a
//!   person is an encrypted direct chat; with a bridge's bot or ghost, one without encryption (a
//!   bridge that has not set up encryption cannot read an encrypted room).
//! - **Bridges**: the bridges the server offers (its client well-known, as for signing in to a
//!   network), asked as the account through the one link to them ([`crate::bridges`]): each
//!   bridge's provisioning API (v3) says which logins the user has there (`whoami`), lists each
//!   login's contacts, searches its network, and opens the direct chat with one.

use std::collections::HashSet;

use lux_core::bridges::{BridgeOffer, Offers};
use lux_core::ids::{MediaId, RoomId};
use lux_core::network::Network;
use lux_core::ports::{BackendError, Bridges as _, Contact, ContactAccount, ContactListing, ContactProblem, People};
use matrix_sdk::reqwest::Method;
use matrix_sdk::ruma::api::client::room::Visibility;
use matrix_sdk::ruma::api::client::room::create_room::v3::{Request as CreateRoom, RoomPreset};
use matrix_sdk::ruma::events::InitialStateEvent;
use matrix_sdk::ruma::events::room::encryption::RoomEncryptionEventContent;
use matrix_sdk::ruma::{OwnedUserId, UserId as SdkUserId};
use serde::Deserialize;
use serde::de::DeserializeOwned;
use serde_json::json;

use tracing::warn;

use crate::account::MatrixAccount;
use crate::bridges::segment;
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
        let (sources, problem) = self.sources().await;
        listing.problems.extend(problem);
        for source in &sources {
            match self.bridge_contacts(source, query).await {
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
                let (sources, _) = self.sources().await;
                let source = sources
                    .iter()
                    .find(|source| source.key == *key)
                    .ok_or_else(|| BackendError::UnknownContact(contact.identifier.clone()))?;
                self.start_bridge_chat(source, &contact.identifier).await
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
    /// The bridge.
    offer: BridgeOffer,
    /// The login's id at the bridge.
    login: String,
    /// The core's key for it: the bridge and the login, as JSON, so neither's characters clash.
    key: String,
    /// "WhatsApp: Anna (+49…)".
    name: String,
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
    #[error("the bridge's call failed: {0}")]
    Failed(String),
}

impl From<BackendError> for BridgeError {
    fn from(error: BackendError) -> Self {
        match error {
            BackendError::Server { status: Some(501), .. } => Self::Unsupported,
            BackendError::Server { status: Some(404), .. } => Self::NotFound,
            error => Self::Failed(error.to_string()),
        }
    }
}

impl MatrixAccount {
    /// The logins of every bridge the server offers, and what could not be read.
    async fn sources(&self) -> (Vec<Source>, Option<ContactProblem>) {
        let offers = match self.bridge_offers().await {
            Ok(Offers::Offered(offers)) => offers,
            Ok(Offers::NotSet) => return (Vec::new(), None),
            Err(error) => {
                warn!(%error, "the server's bridges cannot be read");
                return (Vec::new(), Some(ContactProblem::Discovery));
            }
        };
        let mut sources = Vec::new();
        let mut problem = None;
        for offer in offers {
            match self.bridges.call(&offer, Method::GET, "whoami", &[], None).await {
                Ok(whoami) => sources.extend(logins(&offer, &whoami)),
                Err(error) => {
                    warn!(%error, network = offer.network.as_str(), "a bridge's logins cannot be read");
                    problem = Some(ContactProblem::SomeAccounts);
                }
            }
        }
        (sources, problem)
    }

    /// A login's contacts: all of them for no query; else those that match, the network's
    /// search, else the identifier as the network resolves it.
    async fn bridge_contacts(&self, source: &Source, query: &str) -> Result<Vec<Contact>, BridgeError> {
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
                network: source.offer.network.as_str().to_owned(),
                avatar: contact.avatar_url.filter(|url| !url.is_empty()).map(MediaId::from),
            })
            .collect())
    }

    /// The direct chat with `identifier` on the login's network: the one there is, else a new
    /// one the bridge makes.
    async fn start_bridge_chat(&self, source: &Source, identifier: &str) -> Result<RoomId, BackendError> {
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

    /// Calls `operation` (on `identifier`, one path segment) of the login's bridge.
    async fn bridge<T: DeserializeOwned>(
        &self,
        source: &Source,
        method: Method,
        operation: &str,
        identifier: Option<&str>,
        body: Option<serde_json::Value>,
    ) -> Result<T, BridgeError> {
        let path = identifier.map_or_else(|| operation.to_owned(), |id| format!("{operation}/{}", segment(id)));
        let value = self
            .bridges
            .call(&source.offer, method, &path, &[("login_id", &source.login)], body)
            .await?;
        serde_json::from_value(value).map_err(|error| BridgeError::Failed(error.to_string()))
    }
}

/// The logins `whoami` lists at `offer`'s bridge.
fn logins(offer: &BridgeOffer, whoami: &serde_json::Value) -> Vec<Source> {
    #[derive(Deserialize)]
    struct Whoami {
        network: Option<WhoNetwork>,
        #[serde(default)]
        logins: Vec<Login>,
    }
    #[derive(Deserialize)]
    struct WhoNetwork {
        displayname: Option<String>,
    }
    #[derive(Deserialize)]
    struct Login {
        id: String,
        name: Option<String>,
        profile: Option<LoginProfile>,
    }
    #[derive(Deserialize)]
    struct LoginProfile {
        name: Option<String>,
    }
    let Ok(who) = Whoami::deserialize(whoami) else {
        return Vec::new();
    };
    let network = who
        .network
        .and_then(|network| network.displayname)
        .filter(|name| !name.is_empty())
        .unwrap_or_else(|| offer.network.as_str().to_owned());
    who.logins
        .into_iter()
        .map(|login| {
            let labels: Vec<&str> = [
                login.profile.as_ref().and_then(|profile| profile.name.as_deref()),
                login.name.as_deref(),
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
                key: json!([offer.provisioning, login.id]).to_string(),
                name: format!("{network}: {label}"),
                offer: offer.clone(),
                login: login.id,
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use lux_core::bridges::BridgeOffer;
    use lux_core::network::Network;
    use serde_json::json;

    use super::{is_bridge_user, logins};

    #[test]
    fn whoami_gives_a_source_per_login() {
        let offer = BridgeOffer {
            network: Network::WhatsApp,
            provisioning: "https://example.org/whatsapp".to_owned(),
        };
        let sources = logins(
            &offer,
            &json!({
                "network": {"displayname": "WhatsApp"},
                "logins": [{"id": "49123", "name": "+49 123", "profile": {"name": "Anna"}}, {"id": "7"}]
            }),
        );
        assert_eq!(sources[0].name, "WhatsApp: Anna (+49 123)");
        assert_eq!(sources[0].login, "49123");
        assert_eq!(sources[1].name, "WhatsApp: 7");
    }

    #[test]
    fn bridge_users_are_known() {
        assert!(is_bridge_user("@whatsappbot:example.org"));
        assert!(is_bridge_user("@instagram_123:example.org"));
        assert!(!is_bridge_user("@anna:example.org"));
    }
}
