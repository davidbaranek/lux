//! The chat list as a view model: a task that follows the account's lists (the chats, the
//! requests, the organizing, the spaces), composes the shown place with [`places::compose`],
//! and sends its listener what changed, at most once per frame.
//!
//! - [`ChatListViewModel`] is the handle the apps hold: it forwards their intents (a place, a
//!   filter, a chat's actions) to the task, which owns all of the list's state.
//! - [`ListUpdate`] is one frame's batch: the places when they changed, each section's rows as
//!   [`VectorDiff`](eyeball_im::VectorDiff)s by their stable ids, and the load state.
//!
//! [`places::compose`]: crate::places::compose

mod loading;
mod rows;
mod state;
mod update;
mod view_model;

pub use loading::{LoadState, Loading};
pub use rows::{ListRow, RowKey, SectionHeader};
pub use update::{DueReminder, ListUpdate, SectionRows};
pub use view_model::{ChatListBackend, ChatListViewModel, ListListener, ListSetup};
