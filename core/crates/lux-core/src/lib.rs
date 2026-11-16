//! Lux's chat app logic, shared by every app: everything but the UI.
//!
//! Plain Rust, with no knowledge of how the apps call it: `lux-ffi` maps these types to the
//! apps' languages.

#![forbid(unsafe_code)]

mod actions;
pub mod bridged_space;
pub mod bridges;
pub mod chat;
pub mod demo;
pub mod details;
pub mod diff;
pub mod gone;
pub mod hex;
pub mod ids;
pub mod list;
pub mod markdown;
pub mod merge;
pub mod message;
pub mod network;
pub mod organizer;
pub mod places;
pub mod ports;
pub mod preview;
pub mod push;
pub mod search;
pub mod thread;
pub mod timeline;

/// The view models send their changes once a frame: those within one go in one batch.
pub(crate) const FRAME: std::time::Duration = std::time::Duration::from_millis(16);
