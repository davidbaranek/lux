//! Places, as the apps see them.

use lux_core::network::Network;
use lux_core::places::{ChatFilter, ChatOrder, ListedPlace, PlaceId, SectionId, SectionStyle, Theme};

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

/// A place's colour: neutral (the apps' look) or one of the system's.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, uniffi::Enum)]
pub enum CoreTheme {
    /// The apps' look.
    #[default]
    Neutral,
    /// Red.
    Red,
    /// Orange.
    Orange,
    /// Yellow.
    Yellow,
    /// Green.
    Green,
    /// Mint.
    Mint,
    /// Teal.
    Teal,
    /// Cyan.
    Cyan,
    /// Blue.
    Blue,
    /// Indigo.
    Indigo,
    /// Purple.
    Purple,
    /// Pink.
    Pink,
    /// Brown.
    Brown,
}

impl From<CoreTheme> for Theme {
    fn from(theme: CoreTheme) -> Self {
        match theme {
            CoreTheme::Neutral => Self::Neutral,
            CoreTheme::Red => Self::Red,
            CoreTheme::Orange => Self::Orange,
            CoreTheme::Yellow => Self::Yellow,
            CoreTheme::Green => Self::Green,
            CoreTheme::Mint => Self::Mint,
            CoreTheme::Teal => Self::Teal,
            CoreTheme::Cyan => Self::Cyan,
            CoreTheme::Blue => Self::Blue,
            CoreTheme::Indigo => Self::Indigo,
            CoreTheme::Purple => Self::Purple,
            CoreTheme::Pink => Self::Pink,
            CoreTheme::Brown => Self::Brown,
        }
    }
}

impl From<Theme> for CoreTheme {
    fn from(theme: Theme) -> Self {
        match theme {
            Theme::Neutral => Self::Neutral,
            Theme::Red => Self::Red,
            Theme::Orange => Self::Orange,
            Theme::Yellow => Self::Yellow,
            Theme::Green => Self::Green,
            Theme::Mint => Self::Mint,
            Theme::Teal => Self::Teal,
            Theme::Cyan => Self::Cyan,
            Theme::Blue => Self::Blue,
            Theme::Indigo => Self::Indigo,
            Theme::Purple => Self::Purple,
            Theme::Pink => Self::Pink,
            Theme::Brown => Self::Brown,
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

/// The order of a place's chats.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, uniffi::Enum)]
pub enum CoreChatOrder {
    /// By their last activity, as the server orders them.
    #[default]
    Activity,
    /// By their newest message.
    NewestMessage,
}

impl From<CoreChatOrder> for ChatOrder {
    fn from(order: CoreChatOrder) -> Self {
        match order {
            CoreChatOrder::Activity => Self::Activity,
            CoreChatOrder::NewestMessage => Self::NewestMessage,
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
    /// The colour it shows in: its own, else the one for every place.
    pub theme: CoreTheme,
    /// The colour the user gave it; `None` takes the one for every place.
    pub own_theme: Option<CoreTheme>,
}

impl From<ListedPlace> for CoreListedPlace {
    fn from(listed: ListedPlace) -> Self {
        Self {
            place: listed.id.into(),
            unread: listed.unread,
            is_hidden: listed.is_hidden,
            name: listed.name,
            avatar: listed.avatar.map(|avatar| avatar.to_string()),
            theme: listed.theme.into(),
            own_theme: listed.own_theme.map(CoreTheme::from),
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
