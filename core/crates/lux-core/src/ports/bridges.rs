//! The server's bridges: which networks it offers, the account's logins on them, and signing in
//! to one step by step (see [`crate::bridges`]).

use std::collections::HashMap;
use std::future::Future;

use crate::bridges::{BridgeAccount, BridgeOffer, CatchUp, LoginStep, Offers, StepId};

use super::{BackendError, ValueStream};

/// What the user gives a step.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum StepAnswer {
    /// A form's or a website's values, by field id.
    Values(HashMap<String, String>),
    /// Nothing: a waiting step is waited on.
    Wait,
}

/// The account's side of the server's bridges.
pub trait Bridges: Send + Sync {
    /// The bridges the server offers, as its well-known lists them.
    fn bridge_offers(&self) -> impl Future<Output = Result<Offers, BackendError>> + Send;

    /// The account on `offer`'s bridge: its logins there and the ways to sign in.
    fn bridge_account(&self, offer: &BridgeOffer) -> impl Future<Output = Result<BridgeAccount, BackendError>> + Send;

    /// Starts signing in to `offer`'s network the way `flow` names; its first step.
    fn start_login(
        &self,
        offer: &BridgeOffer,
        flow: &str,
    ) -> impl Future<Output = Result<LoginStep, BackendError>> + Send;

    /// Answers `step`; the next step. A waiting step's answer returns once the bridge stops
    /// waiting (the phone scanned the code).
    fn answer_login(
        &self,
        offer: &BridgeOffer,
        step: &StepId,
        answer: StepAnswer,
    ) -> impl Future<Output = Result<LoginStep, BackendError>> + Send;

    /// The user gave up signing in.
    fn cancel_login(&self, offer: &BridgeOffer, step: &StepId) -> impl Future<Output = ()> + Send;

    /// Signs the login `login` out of `offer`'s network.
    fn log_out_of_network(
        &self,
        offer: &BridgeOffer,
        login: &str,
    ) -> impl Future<Output = Result<(), BackendError>> + Send;

    /// The networks whose history is arriving, as it changes.
    fn catching_up(&self) -> ValueStream<Vec<CatchUp>>;
}
