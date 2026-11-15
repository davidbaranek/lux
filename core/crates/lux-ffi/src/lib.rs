//! The apps' boundary: the Rust core's API (`lux-core`, `lux-matrix`, `lux-store`) in one library,
//! through UniFFI.
//!
//! Only thin mappings live here: records and enums the bindings copy, and functions that call
//! straight into `lux-core`. Anything that decides something belongs in `lux-core`.

// the sdk's futures nest deeply.
#![recursion_limit = "256"]
// UniFFI's generated scaffolding is the only unsafe code, and it is generated.
#![allow(unsafe_code)]

mod account;
mod bridges;
mod chat;
mod details;
mod list;
mod markdown;
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
mod timeline;

uniffi::setup_scaffolding!();
