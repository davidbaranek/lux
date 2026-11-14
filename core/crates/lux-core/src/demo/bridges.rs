//! The demo's bridges: Messenger signed in, WhatsApp, Instagram and Signal to sign in to (a QR
//! code, a website, a form), and Messenger's history arriving.

use std::time::Duration;

use futures_util::{StreamExt, stream};

use super::DemoAccount;
use crate::bridges::{
    BridgeAccount, BridgeOffer, CatchUp, Done, FieldKind, FormField, FormStep, LoginFlow, LoginState, LoginStep,
    NetworkLogin, Offers, ShowStep, Shown, StepId, WebsiteField, WebsiteSource, WebsiteStep,
};
use crate::network::Network;
use crate::ports::{BackendError, Bridges, StepAnswer, ValueStream};

const NETWORKS: [Network; 4] = [
    Network::WhatsApp,
    Network::Signal,
    Network::Messenger,
    Network::Instagram,
];

fn step(process: &Network, step: &str, kind: &str, instructions: &str) -> StepId {
    StepId {
        process: process.as_str().to_owned(),
        step: step.to_owned(),
        kind: kind.to_owned(),
        instructions: instructions.to_owned(),
    }
}

impl Bridges for DemoAccount {
    async fn bridge_offers(&self) -> Result<Offers, BackendError> {
        Ok(Offers::Offered(
            NETWORKS
                .iter()
                .map(|network| BridgeOffer {
                    network: network.clone(),
                    provisioning: format!("https://demo.invalid/{}", network.as_str()),
                })
                .collect(),
        ))
    }

    async fn bridge_account(&self, offer: &BridgeOffer) -> Result<BridgeAccount, BackendError> {
        let signed_in = self.lock().networks.contains(&offer.network);
        Ok(BridgeAccount {
            network: offer.network.clone(),
            logins: if signed_in {
                vec![NetworkLogin {
                    id: "demo".to_owned(),
                    name: "Anna Nováková".to_owned(),
                    state: LoginState::Connected,
                }]
            } else {
                Vec::new()
            },
            flows: vec![LoginFlow {
                id: "demo".to_owned(),
                name: offer.network.as_str().to_owned(),
                description: String::new(),
            }],
        })
    }

    async fn start_login(&self, offer: &BridgeOffer, _flow: &str) -> Result<LoginStep, BackendError> {
        let network = &offer.network;
        Ok(match network {
            Network::WhatsApp | Network::Signal => LoginStep::Show(ShowStep {
                id: step(
                    network,
                    "qr",
                    "display_and_wait",
                    "Scan the QR code with the app on your phone.",
                ),
                shown: Shown::QrCode(format!("demo:{}", network.as_str())),
            }),
            Network::Instagram => LoginStep::Website(WebsiteStep {
                id: step(network, "cookies", "cookies", "Sign in to Instagram."),
                url: "https://www.instagram.com/".to_owned(),
                user_agent: None,
                fields: vec![WebsiteField {
                    id: "sessionid".to_owned(),
                    required: true,
                    sources: vec![WebsiteSource::Cookie {
                        name: "sessionid".to_owned(),
                        domain: Some("instagram.com".to_owned()),
                    }],
                }],
                extract_js: None,
                done_url_pattern: None,
                hidden: false,
            }),
            _ => LoginStep::Form(FormStep {
                id: step(
                    network,
                    "pin",
                    "user_input",
                    "Enter your secure storage PIN to restore your chat history.",
                ),
                fields: vec![FormField {
                    id: "pin".to_owned(),
                    kind: FieldKind::Password,
                    name: "PIN".to_owned(),
                    description: String::new(),
                    default: String::new(),
                    optional: true,
                    pattern: Some("^[0-9]{6}$".to_owned()),
                    choices: Vec::new(),
                }],
            }),
        })
    }

    async fn answer_login(
        &self,
        offer: &BridgeOffer,
        _step: &StepId,
        answer: StepAnswer,
    ) -> Result<LoginStep, BackendError> {
        if answer == StepAnswer::Wait {
            // the phone takes a moment to scan.
            tokio::time::sleep(Duration::from_secs(3)).await;
        } else if let StepAnswer::Values(values) = &answer
            && values.values().all(String::is_empty)
            && values.contains_key("sessionid")
        {
            return Err(BackendError::NotAllowed);
        }
        self.lock().networks.insert(offer.network.clone());
        Ok(LoginStep::Done(Done {
            login_id: Some("demo".to_owned()),
            instructions: format!("Signed in to {}.", offer.network.as_str()),
        }))
    }

    async fn cancel_login(&self, _offer: &BridgeOffer, _step: &StepId) {}

    async fn log_out_of_network(&self, offer: &BridgeOffer, _login: &str) -> Result<(), BackendError> {
        self.lock().networks.remove(&offer.network);
        Ok(())
    }

    fn catching_up(&self) -> ValueStream<Vec<CatchUp>> {
        // Messenger's history arrives for half a minute after launch.
        let catching_up = vec![CatchUp {
            network: Network::Messenger,
            chats: 12,
            messages: 840,
        }];
        stream::iter([catching_up])
            .chain(stream::once(async {
                tokio::time::sleep(Duration::from_secs(30)).await;
                Vec::new()
            }))
            .chain(stream::pending())
            .boxed()
    }
}
