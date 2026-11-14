//! Which chat network a room belongs to: the network a bridge brings it from, or Matrix itself.
//!
//! Two signs, the stronger first:
//!
//! 1. **The bridge's state event** ([MSC2346]: `m.bridge`, or `uk.half-shot.bridge` before it): a
//!    bridge that sets one names its protocol (`"whatsapp"`, `"signal"`…).
//! 2. **The bridge's users.** A bridge stands for each remote person with a ghost user, and talks
//!    through a bot, named after the network by convention: `@whatsapp_4912345:server`,
//!    `@signalbot:server`. A room with such a member is on that network.
//!
//! [MSC2346]: https://github.com/matrix-org/matrix-spec-proposals/pull/2346

use std::fmt;

/// A chat network. Ordered as the apps list them: the bridged networks, Matrix, then the others
/// by their id.
#[derive(Clone, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum Network {
    /// WhatsApp.
    WhatsApp,
    /// Signal.
    Signal,
    /// Facebook Messenger.
    Messenger,
    /// Instagram.
    Instagram,
    /// Telegram.
    Telegram,
    /// Discord.
    Discord,
    /// `LinkedIn`.
    LinkedIn,
    /// Slack.
    Slack,
    /// Google Messages (SMS and RCS).
    GoogleMessages,
    /// Apple's iMessage.
    IMessage,
    /// Matrix itself: no bridge.
    Matrix,
    /// Another network a bridge named, by its protocol id as the bridge wrote it (lowercased).
    Other(String),
}

impl Network {
    /// The network's id, as the apps and the place keys name it (`"whatsapp"`, `"matrix"`).
    #[must_use]
    pub fn as_str(&self) -> &str {
        match self {
            Self::Matrix => "matrix",
            Self::WhatsApp => "whatsapp",
            Self::Signal => "signal",
            Self::Telegram => "telegram",
            Self::Instagram => "instagram",
            Self::Messenger => "messenger",
            Self::Discord => "discord",
            Self::LinkedIn => "linkedin",
            Self::Slack => "slack",
            Self::GoogleMessages => "gmessages",
            Self::IMessage => "imessage",
            Self::Other(id) => id,
        }
    }

    /// The network of an id [`Network::as_str`] gave.
    #[must_use]
    pub fn from_id(id: &str) -> Self {
        if id == Self::Matrix.as_str() {
            Self::Matrix
        } else {
            Self::from_protocol(id)
        }
    }

    /// The network a bridge's protocol id names (`m.bridge`'s `protocol.id`); bridges name the
    /// same network in more than one way (`"facebook"`, `"messenger"`, `"discordgo"`…).
    #[must_use]
    pub fn from_protocol(id: &str) -> Self {
        let id = id.trim().to_ascii_lowercase();
        Self::known(&id).unwrap_or(Self::Other(id))
    }

    /// The network a bridge's ghost or bot stands for, from its user id; `None` for anyone else.
    /// Only the networks the bridges are known to name their users after count, so a person
    /// called `@anna_b:server` is no bridge's.
    #[must_use]
    pub fn from_bridge_user(user_id: &str) -> Option<Self> {
        let localpart = localpart(user_id)?;
        match localpart.split_once('_') {
            Some((prefix, rest)) if !rest.is_empty() => Self::known(prefix),
            _ => Self::from_bridge_bot(user_id),
        }
    }

    /// The network a bridge's bot (`@whatsappbot:server`) talks for; `None` for anyone else, a
    /// ghost too. A bot is no person of the chat: a direct chat with its bot is still direct.
    #[must_use]
    pub fn from_bridge_bot(user_id: &str) -> Option<Self> {
        Self::known(localpart(user_id)?.strip_suffix("bot")?)
    }

    fn known(id: &str) -> Option<Self> {
        Some(match id {
            "whatsapp" => Self::WhatsApp,
            "signal" => Self::Signal,
            "telegram" => Self::Telegram,
            "instagram" => Self::Instagram,
            "facebook" | "messenger" | "meta" | "fbmessenger" => Self::Messenger,
            "discord" | "discordgo" => Self::Discord,
            "linkedin" => Self::LinkedIn,
            "slack" | "slackgo" => Self::Slack,
            "gmessages" | "googlemessages" => Self::GoogleMessages,
            "imessage" | "imessagego" => Self::IMessage,
            _ => return None,
        })
    }

    /// A room's network: the first protocol its bridge state events name, else that of the first
    /// of its members (other than the account itself) who is a bridge's, else Matrix.
    pub fn detect<'a>(
        bridge_protocols: impl IntoIterator<Item = &'a str>,
        members: impl IntoIterator<Item = &'a str>,
    ) -> Self {
        bridge_protocols
            .into_iter()
            .find(|id| !id.trim().is_empty())
            .map(Self::from_protocol)
            .or_else(|| members.into_iter().find_map(Self::from_bridge_user))
            .unwrap_or(Self::Matrix)
    }
}

/// A user id's local part (`anna` of `@anna:server`).
fn localpart(user_id: &str) -> Option<&str> {
    user_id.strip_prefix('@')?.split(':').next()
}

impl fmt::Display for Network {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(self.as_str())
    }
}

#[cfg(test)]
mod tests {
    use super::Network;

    #[test]
    fn the_bridge_state_event_wins() {
        let network = Network::detect(["WhatsApp"], ["@signal_abc:server"]);
        assert_eq!(network, Network::WhatsApp);
    }

    #[test]
    fn protocol_ids_name_networks_in_several_ways() {
        assert_eq!(Network::from_protocol("facebook"), Network::Messenger);
        assert_eq!(Network::from_protocol("discordgo"), Network::Discord);
        assert_eq!(Network::from_protocol("Bluesky"), Network::Other("bluesky".into()));
    }

    #[test]
    fn ghosts_and_bots_name_their_network() {
        assert_eq!(
            Network::from_bridge_user("@whatsapp_4912345:example.org"),
            Some(Network::WhatsApp)
        );
        assert_eq!(
            Network::from_bridge_user("@signalbot:example.org"),
            Some(Network::Signal)
        );
        assert_eq!(
            Network::from_bridge_user("@instagram_1789:beeper.local"),
            Some(Network::Instagram)
        );
        assert_eq!(
            Network::from_bridge_user("@metabot:example.org"),
            Some(Network::Messenger)
        );
        assert_eq!(
            Network::from_bridge_user("@meta_1234:example.org"),
            Some(Network::Messenger)
        );
    }

    #[test]
    fn bots_are_not_ghosts() {
        assert_eq!(
            Network::from_bridge_bot("@telegrambot:example.org"),
            Some(Network::Telegram)
        );
        assert_eq!(Network::from_bridge_bot("@telegram_123:example.org"), None);
    }

    #[test]
    fn people_are_no_bridges() {
        assert_eq!(Network::from_bridge_user("@anna_b:example.org"), None);
        assert_eq!(Network::from_bridge_user("@robot:example.org"), None);
        assert_eq!(Network::from_bridge_user("@instagramfan:example.org"), None);
        assert_eq!(Network::from_bridge_user("@whatsapp_:example.org"), None);
        assert_eq!(Network::from_bridge_user("not a user id"), None);
    }

    #[test]
    fn ids_name_their_network_again_and_networks_sort_as_the_apps_list_them() {
        let mut networks = vec![
            Network::Other("bluesky".into()),
            Network::Matrix,
            Network::Slack,
            Network::WhatsApp,
            Network::Messenger,
        ];
        for network in &networks {
            assert_eq!(&Network::from_id(network.as_str()), network);
        }
        networks.sort();
        assert_eq!(
            networks.iter().map(Network::as_str).collect::<Vec<_>>(),
            ["whatsapp", "messenger", "slack", "matrix", "bluesky"]
        );
    }

    #[test]
    fn a_room_without_bridge_signs_is_matrix() {
        let network = Network::detect([""], ["@anna:example.org", "@bob:example.org"]);
        assert_eq!(network, Network::Matrix);
        assert_eq!(network.as_str(), "matrix");
    }
}
