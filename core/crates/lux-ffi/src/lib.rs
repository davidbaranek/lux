//! The apps' boundary: the Rust core's API (`lux-agent`, `lux-core`, `lux-intelligence`,
//! `lux-matrix`, `lux-store`) in one library, through UniFFI.
//!
//! Only thin mappings live here: records and enums the bindings copy, and functions that call
//! straight into `lux-core`. Anything that decides something belongs in `lux-core`.

// the sdk's futures nest deeply.
#![recursion_limit = "256"]

mod account;
mod agents;
mod bridges;
mod chat;
mod details;
mod image_search;
mod intelligence;
mod list;
mod log;
mod markdown;
mod mention;
mod message;
mod organizing;
mod people;
mod places;
mod profile;
mod push;
mod runtime;
mod security;
mod share;
mod store;
mod thread;
mod time_span;
mod timeline;

uniffi::setup_scaffolding!();
