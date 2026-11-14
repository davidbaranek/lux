//! The server's bridges for the apps: the networks it offers, the account's logins on them,
//! signing in step by step, and the networks whose history is arriving (see
//! [`lux_core::bridges`]).

use std::collections::HashMap;
use std::sync::Arc;

use futures_util::StreamExt;
use lux_core::bridges::{
    BridgeAccount, BridgeOffer, CatchUp, FieldKind, LoginState, LoginStep, Offers, Shown, StepId, WebsiteSource,
};
use lux_core::network::Network;
use lux_core::ports::{Bridges, StepAnswer};

use crate::account::{CoreAccount, CoreAccountError, CoreListenerHandle, with_account};
use crate::runtime;

/// What the server says of its bridges.
#[derive(uniffi::Enum)]
pub enum CoreBridgeOffers {
    /// The server names none the app can find: its well-known has no list of bridges.
    NotSet,
    /// The bridges it offers.
    Offered {
        /// In the apps' order.
        offers: Vec<CoreBridgeOffer>,
    },
}

/// A bridge the server offers.
#[derive(uniffi::Record, Clone)]
pub struct CoreBridgeOffer {
    /// The network's id (`"messenger"`).
    pub network: String,
    /// The bridge's provisioning API.
    pub provisioning: String,
}

/// The account on a bridge.
#[derive(uniffi::Record)]
pub struct CoreBridgeAccount {
    /// The network's id.
    pub network: String,
    /// Its logins there.
    pub logins: Vec<CoreNetworkLogin>,
    /// The ways to sign in, the bridge's preferred first.
    pub flows: Vec<CoreLoginFlow>,
    /// Whether the user has to sign in (none yet, or one let go).
    pub needs_sign_in: bool,
}

/// A login on a network.
#[derive(uniffi::Record)]
pub struct CoreNetworkLogin {
    /// The bridge's id of it.
    pub id: String,
    /// Its name there.
    pub name: String,
    /// How it is.
    pub state: CoreLoginState,
}

/// How a login is.
#[derive(uniffi::Enum)]
pub enum CoreLoginState {
    /// Connected.
    Connected,
    /// Connecting.
    Connecting,
    /// Bringing the history.
    Backfilling,
    /// The network refuses it: sign in again.
    BadCredentials,
    /// Signed out on the network.
    LoggedOut,
    /// Another problem.
    Error {
        /// The bridge's reason.
        reason: Option<String>,
    },
}

/// A way to sign in.
#[derive(uniffi::Record)]
pub struct CoreLoginFlow {
    /// The bridge's id.
    pub id: String,
    /// Its name.
    pub name: String,
    /// What it does.
    pub description: String,
}

/// A sign-in's step.
#[derive(uniffi::Record, Clone)]
pub struct CoreLoginStepId {
    /// The sign-in at the bridge.
    pub process: String,
    /// The step.
    pub step: String,
    /// Its kind.
    pub kind: String,
    /// What the bridge tells the user.
    pub instructions: String,
}

/// What a step asks for.
#[derive(uniffi::Enum)]
pub enum CoreLoginStep {
    /// Sign in on a website; the app reads the fields from it.
    Website {
        /// The step.
        id: CoreLoginStepId,
        /// The page.
        url: String,
        /// The browser to act as.
        user_agent: Option<String>,
        /// What to read from it.
        fields: Vec<CoreWebsiteField>,
        /// A script resolving to some fields.
        extract_js: Option<String>,
        /// The page's address once signed in (a regular expression).
        done_url_pattern: Option<String>,
        /// Whether the page runs unseen.
        hidden: bool,
    },
    /// A form.
    Form {
        /// The step.
        id: CoreLoginStepId,
        /// Its fields.
        fields: Vec<CoreFormField>,
    },
    /// Something to show while the bridge waits for the phone.
    Show {
        /// The step.
        id: CoreLoginStepId,
        /// What.
        shown: CoreShown,
    },
    /// Signed in.
    Done {
        /// What the bridge says.
        instructions: String,
    },
    /// A step the app cannot take.
    Unsupported {
        /// Its kind.
        kind: String,
    },
}

/// A value read from a website.
#[derive(uniffi::Record)]
pub struct CoreWebsiteField {
    /// Its id.
    pub id: String,
    /// Whether the sign-in needs it.
    pub required: bool,
    /// Where it is, the first that has it wins.
    pub sources: Vec<CoreWebsiteSource>,
}

/// Where a website's value is.
#[derive(uniffi::Enum)]
pub enum CoreWebsiteSource {
    /// A cookie.
    Cookie {
        /// Its name.
        name: String,
        /// Its domain; any when none.
        domain: Option<String>,
    },
    /// A key of the page's local storage.
    LocalStorage {
        /// The key.
        name: String,
    },
    /// A key of what the page's script resolves to.
    Script {
        /// The key.
        name: String,
    },
    /// Somewhere the app cannot read.
    Unreadable,
}

/// A form's field.
#[derive(uniffi::Record)]
pub struct CoreFormField {
    /// Its id.
    pub id: String,
    /// What it holds.
    pub kind: CoreFieldKind,
    /// Its name.
    pub name: String,
    /// What it is for.
    pub description: String,
    /// Its value to begin with.
    pub default: String,
    /// Whether it may stay empty.
    pub optional: bool,
    /// A pattern a valid value matches.
    pub pattern: Option<String>,
    /// The choices of a choice.
    pub choices: Vec<String>,
}

/// What a form's field holds.
#[derive(uniffi::Enum)]
pub enum CoreFieldKind {
    /// A user name.
    Username,
    /// A password or PIN.
    Password,
    /// A phone number.
    PhoneNumber,
    /// An email address.
    Email,
    /// A code sent to the user.
    Code,
    /// Plain text.
    Text,
    /// One of the choices.
    Choice,
}

/// What a waiting step shows.
#[derive(uniffi::Enum)]
pub enum CoreShown {
    /// A QR code of `data`.
    QrCode {
        /// The code's text.
        data: String,
    },
    /// A code to type on the phone.
    Code {
        /// The code.
        code: String,
    },
    /// Emoji to compare.
    Emoji {
        /// The emoji.
        text: String,
        /// An image of them.
        image_url: Option<String>,
    },
    /// Only the instructions.
    Nothing,
}

/// A network whose history is arriving.
#[derive(uniffi::Record)]
pub struct CoreCatchUp {
    /// The network's id.
    pub network: String,
    /// The chats its history came to so far.
    pub chats: u32,
    /// The messages that came.
    pub messages: u32,
}

/// Hears the networks whose history is arriving.
#[uniffi::export(with_foreign)]
pub trait CoreCatchUpListener: Send + Sync {
    /// The networks catching up now, on the core's thread; empty when none is.
    fn on_change(&self, networks: Vec<CoreCatchUp>);
}

#[uniffi::export(async_runtime = "tokio")]
impl CoreAccount {
    /// The bridges the account's server offers.
    ///
    /// # Errors
    /// When the server cannot be reached.
    pub async fn bridge_offers(&self) -> Result<CoreBridgeOffers, CoreAccountError> {
        let offers = with_account!(self.backend(), account => account.bridge_offers().await)?;
        Ok(match offers {
            Offers::NotSet => CoreBridgeOffers::NotSet,
            Offers::Offered(offers) => CoreBridgeOffers::Offered {
                offers: offers.into_iter().map(Into::into).collect(),
            },
        })
    }

    /// The account on `offer`'s bridge.
    ///
    /// # Errors
    /// When the bridge cannot be reached or refuses.
    pub async fn bridge_account(&self, offer: CoreBridgeOffer) -> Result<CoreBridgeAccount, CoreAccountError> {
        let offer = offer.into();
        let account = with_account!(self.backend(), account => account.bridge_account(&offer).await)?;
        Ok(account.into())
    }

    /// Starts signing in to `offer`'s network the way `flow` names.
    ///
    /// # Errors
    /// When the bridge cannot be reached or refuses.
    pub async fn start_network_login(
        &self,
        offer: CoreBridgeOffer,
        flow: String,
    ) -> Result<CoreLoginStep, CoreAccountError> {
        let offer = offer.into();
        let step = with_account!(self.backend(), account => account.start_login(&offer, &flow).await)?;
        Ok(step.into())
    }

    /// Answers a step with the values the user gave (a form's, a website's).
    ///
    /// # Errors
    /// When the bridge cannot be reached, or refuses the values (its message says why).
    pub async fn answer_network_login(
        &self,
        offer: CoreBridgeOffer,
        step: CoreLoginStepId,
        values: HashMap<String, String>,
    ) -> Result<CoreLoginStep, CoreAccountError> {
        self.answer(offer, step, StepAnswer::Values(values)).await
    }

    /// Waits on a step that shows something until the bridge moves on (the phone scanned it).
    ///
    /// # Errors
    /// When the bridge cannot be reached, or the wait ran out.
    pub async fn wait_network_login(
        &self,
        offer: CoreBridgeOffer,
        step: CoreLoginStepId,
    ) -> Result<CoreLoginStep, CoreAccountError> {
        self.answer(offer, step, StepAnswer::Wait).await
    }

    /// The user gave up signing in.
    pub async fn cancel_network_login(&self, offer: CoreBridgeOffer, step: CoreLoginStepId) {
        let (offer, step) = (offer.into(), step.into());
        with_account!(self.backend(), account => account.cancel_login(&offer, &step).await);
    }

    /// Signs `login` out of `offer`'s network.
    ///
    /// # Errors
    /// When the bridge cannot be reached or refuses.
    pub async fn log_out_of_network(&self, offer: CoreBridgeOffer, login: String) -> Result<(), CoreAccountError> {
        let offer = offer.into();
        with_account!(self.backend(), account => account.log_out_of_network(&offer, &login).await)?;
        Ok(())
    }

    /// Tells `listener` the networks whose history is arriving, now and as they change, until
    /// the handle is cancelled or let go.
    pub fn follow_catching_up(&self, listener: Arc<dyn CoreCatchUpListener>) -> Arc<CoreListenerHandle> {
        let changes = with_account!(self.backend(), account => account.catching_up());
        let task = runtime::handle().spawn(changes.for_each(move |networks| {
            listener.on_change(networks.into_iter().map(Into::into).collect());
            async {}
        }));
        Arc::new(CoreListenerHandle { tasks: vec![task] })
    }
}

impl CoreAccount {
    async fn answer(
        &self,
        offer: CoreBridgeOffer,
        step: CoreLoginStepId,
        answer: StepAnswer,
    ) -> Result<CoreLoginStep, CoreAccountError> {
        let (offer, step) = (offer.into(), step.into());
        let next = with_account!(self.backend(), account => account.answer_login(&offer, &step, answer).await)?;
        Ok(next.into())
    }
}

impl From<BridgeOffer> for CoreBridgeOffer {
    fn from(offer: BridgeOffer) -> Self {
        Self {
            network: offer.network.as_str().to_owned(),
            provisioning: offer.provisioning,
        }
    }
}

impl From<CoreBridgeOffer> for BridgeOffer {
    fn from(offer: CoreBridgeOffer) -> Self {
        Self {
            network: Network::from_id(&offer.network),
            provisioning: offer.provisioning,
        }
    }
}

impl From<BridgeAccount> for CoreBridgeAccount {
    fn from(account: BridgeAccount) -> Self {
        let needs_sign_in = account.needs_sign_in();
        Self {
            network: account.network.as_str().to_owned(),
            logins: account
                .logins
                .into_iter()
                .map(|login| CoreNetworkLogin {
                    id: login.id,
                    name: login.name,
                    state: login.state.into(),
                })
                .collect(),
            flows: account
                .flows
                .into_iter()
                .map(|flow| CoreLoginFlow {
                    id: flow.id,
                    name: flow.name,
                    description: flow.description,
                })
                .collect(),
            needs_sign_in,
        }
    }
}

impl From<LoginState> for CoreLoginState {
    fn from(state: LoginState) -> Self {
        match state {
            LoginState::Connected => Self::Connected,
            LoginState::Connecting => Self::Connecting,
            LoginState::Backfilling => Self::Backfilling,
            LoginState::BadCredentials => Self::BadCredentials,
            LoginState::LoggedOut => Self::LoggedOut,
            LoginState::Error(reason) => Self::Error { reason },
        }
    }
}

impl From<StepId> for CoreLoginStepId {
    fn from(id: StepId) -> Self {
        Self {
            process: id.process,
            step: id.step,
            kind: id.kind,
            instructions: id.instructions,
        }
    }
}

impl From<CoreLoginStepId> for StepId {
    fn from(id: CoreLoginStepId) -> Self {
        Self {
            process: id.process,
            step: id.step,
            kind: id.kind,
            instructions: id.instructions,
        }
    }
}

impl From<LoginStep> for CoreLoginStep {
    fn from(step: LoginStep) -> Self {
        match step {
            LoginStep::Website(website) => Self::Website {
                id: website.id.into(),
                url: website.url,
                user_agent: website.user_agent,
                fields: website
                    .fields
                    .into_iter()
                    .map(|field| CoreWebsiteField {
                        id: field.id,
                        required: field.required,
                        sources: field
                            .sources
                            .into_iter()
                            .map(|source| match source {
                                WebsiteSource::Cookie { name, domain } => CoreWebsiteSource::Cookie { name, domain },
                                WebsiteSource::LocalStorage { name } => CoreWebsiteSource::LocalStorage { name },
                                WebsiteSource::Script { name } => CoreWebsiteSource::Script { name },
                                WebsiteSource::Unreadable => CoreWebsiteSource::Unreadable,
                            })
                            .collect(),
                    })
                    .collect(),
                extract_js: website.extract_js,
                done_url_pattern: website.done_url_pattern,
                hidden: website.hidden,
            },
            LoginStep::Form(form) => Self::Form {
                id: form.id.into(),
                fields: form
                    .fields
                    .into_iter()
                    .map(|field| CoreFormField {
                        id: field.id,
                        kind: match field.kind {
                            FieldKind::Username => CoreFieldKind::Username,
                            FieldKind::Password => CoreFieldKind::Password,
                            FieldKind::PhoneNumber => CoreFieldKind::PhoneNumber,
                            FieldKind::Email => CoreFieldKind::Email,
                            FieldKind::Code => CoreFieldKind::Code,
                            FieldKind::Text => CoreFieldKind::Text,
                            FieldKind::Choice => CoreFieldKind::Choice,
                        },
                        name: field.name,
                        description: field.description,
                        default: field.default,
                        optional: field.optional,
                        pattern: field.pattern,
                        choices: field.choices,
                    })
                    .collect(),
            },
            LoginStep::Show(show) => Self::Show {
                id: show.id.into(),
                shown: match show.shown {
                    Shown::QrCode(data) => CoreShown::QrCode { data },
                    Shown::Code(code) => CoreShown::Code { code },
                    Shown::Emoji { text, image_url } => CoreShown::Emoji { text, image_url },
                    Shown::Nothing => CoreShown::Nothing,
                },
            },
            LoginStep::Done(done) => Self::Done {
                instructions: done.instructions,
            },
            LoginStep::Unsupported { kind } => Self::Unsupported { kind },
        }
    }
}

impl From<CatchUp> for CoreCatchUp {
    fn from(catch_up: CatchUp) -> Self {
        Self {
            network: catch_up.network.as_str().to_owned(),
            chats: u32::try_from(catch_up.chats).unwrap_or(u32::MAX),
            messages: u32::try_from(catch_up.messages).unwrap_or(u32::MAX),
        }
    }
}
