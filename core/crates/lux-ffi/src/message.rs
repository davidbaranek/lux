//! The timeline's presentation, as a thread's rows carry it to the apps.

use jiff::tz::TimeZone;
use lux_core::message::{Footer, Link, Status};

use crate::chat::position;

/// Where a message is on its way to the server.
#[derive(uniffi::Enum)]
pub enum CoreSendState {
    /// Not sent yet.
    Sending {
        /// An upload's progress, 0 to 1.
        upload: Option<f64>,
    },
    /// Sent.
    Sent,
    /// Failed.
    Failed,
}

/// A web address in a text, in UTF-16 code units.
#[derive(uniffi::Record)]
pub struct CoreLink {
    /// Where it starts.
    pub start: u32,
    /// How long it is.
    pub length: u32,
    /// Where it leads.
    pub url: String,
}

impl From<Link> for CoreLink {
    fn from(link: Link) -> Self {
        Self {
            start: position(link.range.start),
            length: position(link.range.len()),
            url: link.url,
        }
    }
}

/// What separates a message from the one before.
#[derive(uniffi::Enum)]
pub enum CoreSeparator {
    /// A new day.
    Day,
    /// Two hours or more.
    Pause,
}

/// How far a message being sent has got.
#[derive(uniffi::Enum)]
pub enum CoreStatus {
    /// On its way.
    Sending,
    /// Uploading.
    Uploading {
        /// How far, 0 to 1.
        progress: f64,
    },
    /// Failed.
    Failed,
}

/// What shows under a message that is not plain.
#[derive(uniffi::Record)]
pub struct CoreFooter {
    /// It was edited.
    pub is_edited: bool,
    /// Not sent yet, or failed.
    pub status: Option<CoreStatus>,
}

impl From<Footer> for CoreFooter {
    fn from(footer: Footer) -> Self {
        Self {
            is_edited: footer.is_edited,
            status: footer.status.map(|status| match status {
                Status::Sending => CoreStatus::Sending,
                Status::Uploading(progress) => CoreStatus::Uploading { progress },
                Status::Failed => CoreStatus::Failed,
            }),
        }
    }
}

/// The time zone named `name` (IANA); the system's if unknown.
pub(crate) fn zone(name: &str) -> TimeZone {
    TimeZone::get(name).unwrap_or_else(|_| TimeZone::system())
}
