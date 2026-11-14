//! Places, as the apps see them.

use lux_core::network::Network;
use lux_core::places::{ChatFilter, ListedPlace, PlaceId, SectionId, SectionStyle};

use crate::chat::CoreFolder;

/// Where the chat list looks.
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum CorePlace {
    /// A folder.
    Folder {
        /// Which.
        folder: CoreFolder,
    },
    /// The invitations.
    Requests,
    /// Saved messages.
    Saved,
    /// Chats with a reminder.
    Reminders,
    /// Messages waiting to go.
    Scheduled,
    /// One network's chats.
    Network {
        /// Its id (`"whatsapp"`).
        network: String,
    },
    /// A space's chats.
    Space {
        /// Its room.
        id: String,
    },
    /// A label's chats.
    Label {
        /// Its id.
        id: String,
    },
}

impl From<CorePlace> for PlaceId {
    fn from(place: CorePlace) -> Self {
        match place {
            CorePlace::Folder { folder } => Self::Folder(folder.into()),
            CorePlace::Requests => Self::Requests,
            CorePlace::Saved => Self::Saved,
            CorePlace::Reminders => Self::Reminders,
            CorePlace::Scheduled => Self::Scheduled,
            CorePlace::Network { network } => Self::Network(Network::from_id(&network)),
            CorePlace::Space { id } => Self::Space(id.into()),
            CorePlace::Label { id } => Self::Label(id.into()),
        }
    }
}

impl From<PlaceId> for CorePlace {
    fn from(place: PlaceId) -> Self {
        match place {
            PlaceId::Folder(folder) => Self::Folder { folder: folder.into() },
            PlaceId::Requests => Self::Requests,
            PlaceId::Saved => Self::Saved,
            PlaceId::Reminders => Self::Reminders,
            PlaceId::Scheduled => Self::Scheduled,
            PlaceId::Network(network) => Self::Network {
                network: network.as_str().to_owned(),
            },
            PlaceId::Space(id) => Self::Space { id: id.to_string() },
            PlaceId::Label(id) => Self::Label { id: id.to_string() },
        }
    }
}

/// Which of a place's chats the list shows.
#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum CoreChatFilter {
    /// Unread.
    Unread,
    /// Read.
    Read,
    /// With a draft.
    Drafts,
    /// Groups.
    Groups,
    /// Conversations of two.
    Directs,
}

impl From<CoreChatFilter> for ChatFilter {
    fn from(filter: CoreChatFilter) -> Self {
        match filter {
            CoreChatFilter::Unread => Self::Unread,
            CoreChatFilter::Read => Self::Read,
            CoreChatFilter::Drafts => Self::Drafts,
            CoreChatFilter::Groups => Self::Groups,
            CoreChatFilter::Directs => Self::Directs,
        }
    }
}

/// A place in the list of places.
#[derive(uniffi::Record)]
pub struct CoreListedPlace {
    /// Which.
    pub place: CorePlace,
    /// Its badge.
    pub unread: u32,
    /// The user hid it.
    pub is_hidden: bool,
    /// A space's or a label's name.
    pub name: Option<String>,
    /// A space's picture (a media URL).
    pub avatar: Option<String>,
}

impl From<ListedPlace> for CoreListedPlace {
    fn from(listed: ListedPlace) -> Self {
        Self {
            place: listed.id.into(),
            unread: listed.unread,
            is_hidden: listed.is_hidden,
            name: listed.name,
            avatar: listed.avatar.map(|avatar| avatar.to_string()),
        }
    }
}

/// What a section is.
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum CoreSectionId {
    /// The inbox's pinned chats.
    Pinned,
    /// A place's chats.
    All,
    /// A space's chats.
    Space {
        /// Its room.
        id: String,
    },
}

impl From<SectionId> for CoreSectionId {
    fn from(id: SectionId) -> Self {
        match id {
            SectionId::Pinned => Self::Pinned,
            SectionId::All => Self::All,
            SectionId::Space(id) => Self::Space { id: id.to_string() },
        }
    }
}

/// How a section draws.
#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum CoreSectionStyle {
    /// Rows.
    List,
    /// Pictures in a grid.
    Grid,
}

impl From<SectionStyle> for CoreSectionStyle {
    fn from(style: SectionStyle) -> Self {
        match style {
            SectionStyle::List => Self::List,
            SectionStyle::Grid => Self::Grid,
        }
    }
}
