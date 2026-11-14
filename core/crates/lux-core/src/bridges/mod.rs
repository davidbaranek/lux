//! The networks the account's server bridges, and signing in to them from the app.
//!
//! A server tells which bridges it runs in its client well-known (`/.well-known/matrix/client`),
//! under [`WELL_KNOWN_KEY`]: each bridge's network and the address of its provisioning API (the
//! bridges' structured sign-in, mautrix bridgev2's `/_matrix/provision/v3`). A server without the
//! key offers none the app can find ([`Offers::NotSet`]), which the apps explain, with how to set it
//! up.
//!
//! A sign-in is the bridge's: it answers each step with the next ([`LoginStep`]): a website to
//! sign in on (the app reads the cookies the bridge asks for itself, in a web view), a form, a
//! code or QR code to show while the bridge waits for the phone, and at last the new login. The
//! apps only draw each step and hand back what the user gave.

mod activity;

pub use activity::{CatchUp, HistoryArrivals};

use crate::network::Network;

/// The client well-known's key that lists a server's bridges.
pub const WELL_KNOWN_KEY: &str = "com.bardav.lux.bridges";

/// One bridge a server offers: its network, and where its provisioning API is.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct BridgeOffer {
    /// The network it bridges.
    pub network: Network,
    /// The provisioning API's base address: the bridge's `/_matrix/provision/v3` is under it.
    pub provisioning: String,
}

/// What a server says of its bridges.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Offers {
    /// The server's well-known names no bridges: none it has can be signed in to from the app.
    NotSet,
    /// The bridges it offers, in the order the apps list networks.
    Offered(Vec<BridgeOffer>),
}

impl Offers {
    /// The offers, from the well-known's list: each network once, in the apps' order; those whose
    /// address is no `https` URL left out.
    #[must_use]
    pub fn from_list(list: impl IntoIterator<Item = (String, String)>) -> Self {
        let mut offers: Vec<BridgeOffer> = Vec::new();
        for (network, provisioning) in list {
            let network = Network::from_id(&network);
            let provisioning = provisioning.trim().trim_end_matches('/').to_owned();
            if network == Network::Matrix
                || !provisioning.starts_with("https://")
                || offers.iter().any(|offer| offer.network == network)
            {
                continue;
            }
            offers.push(BridgeOffer { network, provisioning });
        }
        offers.sort_by(|a, b| a.network.cmp(&b.network));
        Self::Offered(offers)
    }

    /// The offers there are; none when the server sets none.
    #[must_use]
    pub fn offered(&self) -> &[BridgeOffer] {
        match self {
            Self::NotSet => &[],
            Self::Offered(offers) => offers,
        }
    }
}

/// The account on a bridge: its logins there, and the ways to add one.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct BridgeAccount {
    /// The network.
    pub network: Network,
    /// The logins the account has on the network, through the bridge.
    pub logins: Vec<NetworkLogin>,
    /// The ways the bridge signs in, the one it prefers first.
    pub flows: Vec<LoginFlow>,
}

impl BridgeAccount {
    /// Whether the network needs the user: no login yet, or one the network let go.
    #[must_use]
    pub fn needs_sign_in(&self) -> bool {
        self.logins.is_empty() || self.logins.iter().any(|login| login.state.needs_sign_in())
    }
}

/// One login on a network.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct NetworkLogin {
    /// The bridge's id of it, for signing out.
    pub id: String,
    /// The name it has on the network (the person's name, a phone number).
    pub name: String,
    /// How it is.
    pub state: LoginState,
}

/// How a login is, as its bridge says (bridgev2's bridge states).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum LoginState {
    /// Connected.
    Connected,
    /// Connecting, or reconnecting after a moment without the network.
    Connecting,
    /// Bringing the chats' history.
    Backfilling,
    /// The network refuses the login: it must sign in again.
    BadCredentials,
    /// Signed out on the network.
    LoggedOut,
    /// Something else went wrong; the bridge's reason, when it gave one.
    Error(Option<String>),
}

impl LoginState {
    /// The state of bridgev2's state event name (`"CONNECTED"`) and reason.
    #[must_use]
    pub fn from_bridge(event: &str, reason: Option<String>) -> Self {
        match event {
            "CONNECTED" => Self::Connected,
            "CONNECTING" | "TRANSIENT_DISCONNECT" | "STARTING" | "RUNNING" => Self::Connecting,
            "BACKFILLING" => Self::Backfilling,
            "BAD_CREDENTIALS" => Self::BadCredentials,
            "LOGGED_OUT" => Self::LoggedOut,
            _ => Self::Error(reason.filter(|reason| !reason.trim().is_empty())),
        }
    }

    /// Whether the user has to sign in again.
    #[must_use]
    pub fn needs_sign_in(&self) -> bool {
        matches!(self, Self::BadCredentials | Self::LoggedOut)
    }
}

/// A way a bridge signs in (a website, an app's QR code, a phone number).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LoginFlow {
    /// The bridge's id of it.
    pub id: String,
    /// Its name (`"facebook.com"`, `"QR code"`).
    pub name: String,
    /// What it does.
    pub description: String,
}

impl LoginFlow {
    /// Whether the user signs in where the network itself asks (its website, its app's QR code):
    /// the network sees its own sign-in, with its own checks, where a password sent through a
    /// bridge's copy of the network's app API is often refused.
    #[must_use]
    pub fn is_networks_own(&self) -> bool {
        let words = format!("{} {}", self.name, self.description).to_lowercase();
        ["cookie", "qr", "website", "browser"]
            .iter()
            .any(|word| words.contains(word))
    }

    /// The flows the apps offer, the networks' own sign-ins first, each kind in the bridge's order.
    #[must_use]
    pub fn ordered(mut flows: Vec<Self>) -> Vec<Self> {
        flows.sort_by_key(|flow| !flow.is_networks_own());
        flows
    }
}

/// A step of a sign-in, as the bridge asks for it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum LoginStep {
    /// Sign in on a website: the app shows `url` and takes the cookies (and the like) the bridge
    /// asks for from it once they are there.
    Website(WebsiteStep),
    /// Fill in a form.
    Form(FormStep),
    /// Show something (a QR code, a code) while the bridge waits for the user's phone.
    Show(ShowStep),
    /// Signed in.
    Done(Done),
    /// A step the app cannot take (a security key, an HTTP request made for the bridge).
    Unsupported {
        /// The step's kind, as the bridge names it.
        kind: String,
    },
}

/// What every step has.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct StepId {
    /// The sign-in's id at the bridge.
    pub process: String,
    /// The step's id.
    pub step: String,
    /// The step's kind, as the bridge names it (`"cookies"`): its answer is sent as one.
    pub kind: String,
    /// What the bridge tells the user, if anything.
    pub instructions: String,
}

/// A website to sign in on.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct WebsiteStep {
    /// The step.
    pub id: StepId,
    /// The page to open.
    pub url: String,
    /// The browser the bridge acts as; the web view uses it, so the site sees the same.
    pub user_agent: Option<String>,
    /// What the bridge needs from the page.
    pub fields: Vec<WebsiteField>,
    /// A script that, run in the page, resolves to some of the fields.
    pub extract_js: Option<String>,
    /// The page's address once signed in: the view closes by itself only there.
    pub done_url_pattern: Option<String>,
    /// Whether the page runs without being shown (a script reads it).
    pub hidden: bool,
}

/// A value the bridge needs from a website.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct WebsiteField {
    /// The id it is handed back under.
    pub id: String,
    /// Whether the sign-in needs it.
    pub required: bool,
    /// Where it may be found, the first that has it wins.
    pub sources: Vec<WebsiteSource>,
}

/// Where a website's value is.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum WebsiteSource {
    /// A cookie, by name, of a domain (`facebook.com`, its subdomains too).
    Cookie {
        /// The cookie's name.
        name: String,
        /// The domain it belongs to; any when none.
        domain: Option<String>,
    },
    /// A key of the page's local storage.
    LocalStorage {
        /// The key.
        name: String,
    },
    /// What the page's script (`extract_js`) resolves to, by key.
    Script {
        /// The key.
        name: String,
    },
    /// A source the app cannot read (a request's header or body).
    Unreadable,
}

/// A form.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FormStep {
    /// The step.
    pub id: StepId,
    /// Its fields.
    pub fields: Vec<FormField>,
}

/// A form's field.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FormField {
    /// The id it is handed back under.
    pub id: String,
    /// What it is, for the keyboard and whether it is hidden.
    pub kind: FieldKind,
    /// Its name.
    pub name: String,
    /// What it is for.
    pub description: String,
    /// What it holds to begin with.
    pub default: String,
    /// Whether it may stay empty.
    pub optional: bool,
    /// A pattern a valid value matches.
    pub pattern: Option<String>,
    /// The choices of a [`FieldKind::Choice`].
    pub choices: Vec<String>,
}

/// What a form's field holds.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FieldKind {
    /// A user name.
    Username,
    /// A password, a PIN: hidden as typed.
    Password,
    /// A phone number, with its country's prefix.
    PhoneNumber,
    /// An email address.
    Email,
    /// A code sent to the user (two-factor, a captcha's).
    Code,
    /// A token, an address, a domain: plain text.
    Text,
    /// One of [`FormField::choices`].
    Choice,
}

impl FieldKind {
    /// The kind of bridgev2's field type.
    #[must_use]
    pub fn from_bridge(kind: &str) -> Self {
        match kind {
            "username" => Self::Username,
            "password" => Self::Password,
            "phone_number" => Self::PhoneNumber,
            "email" => Self::Email,
            "2fa_code" | "captcha_code" => Self::Code,
            "select" => Self::Choice,
            _ => Self::Text,
        }
    }
}

/// Something to show while the bridge waits.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ShowStep {
    /// The step.
    pub id: StepId,
    /// What to show.
    pub shown: Shown,
}

/// What a waiting step shows.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Shown {
    /// A QR code of this text, for the network's phone app to scan.
    QrCode(String),
    /// A code to type in on the phone.
    Code(String),
    /// Emoji to compare, or an image of them.
    Emoji {
        /// The emoji.
        text: String,
        /// An image of them, if the bridge gave one.
        image_url: Option<String>,
    },
    /// Nothing: only the instructions.
    Nothing,
}

/// A finished sign-in.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Done {
    /// The new login's id.
    pub login_id: Option<String>,
    /// What the bridge says of it.
    pub instructions: String,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_servers_list_keeps_each_bridged_network_once_in_the_apps_order() {
        let offers = Offers::from_list([
            ("instagram".to_owned(), "https://example.org/ig/".to_owned()),
            ("facebook".to_owned(), "https://example.org/fb".to_owned()),
            ("messenger".to_owned(), "https://example.org/other".to_owned()),
            ("matrix".to_owned(), "https://example.org/m".to_owned()),
            ("whatsapp".to_owned(), "http://example.org/wa".to_owned()),
        ]);
        assert_eq!(
            offers.offered(),
            [
                BridgeOffer {
                    network: Network::Messenger,
                    provisioning: "https://example.org/fb".to_owned()
                },
                BridgeOffer {
                    network: Network::Instagram,
                    provisioning: "https://example.org/ig".to_owned()
                },
            ]
        );
    }

    #[test]
    fn a_networks_own_sign_in_comes_before_a_password_through_the_bridge() {
        let flow = |id: &str, description: &str| LoginFlow {
            id: id.to_owned(),
            name: id.to_owned(),
            description: description.to_owned(),
        };
        let ordered = LoginFlow::ordered(vec![
            flow("instagram-native", "Log in with your username and password"),
            flow("instagram", "Login using cookies from instagram.com"),
            flow("qr", "Scan a QR code"),
        ]);
        assert_eq!(
            ordered.iter().map(|flow| flow.id.as_str()).collect::<Vec<_>>(),
            ["instagram", "qr", "instagram-native"]
        );
    }

    #[test]
    fn a_network_without_a_login_or_with_a_lost_one_needs_signing_in() {
        let login = |state| NetworkLogin {
            id: "1".to_owned(),
            name: "Anna".to_owned(),
            state,
        };
        let account = |logins| BridgeAccount {
            network: Network::WhatsApp,
            logins,
            flows: Vec::new(),
        };
        assert!(account(Vec::new()).needs_sign_in());
        assert!(account(vec![login(LoginState::from_bridge("BAD_CREDENTIALS", None))]).needs_sign_in());
        assert!(!account(vec![login(LoginState::from_bridge("CONNECTED", None))]).needs_sign_in());
        assert!(!account(vec![login(LoginState::from_bridge("TRANSIENT_DISCONNECT", None))]).needs_sign_in());
    }
}
