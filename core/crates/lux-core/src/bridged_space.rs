//! Whether a space is one a bridge made for the user's login, which the apps leave out: the
//! network's own place already holds the same chats, under the same logo.
//!
//! The mautrix bridges make one such space per login ("Instagram (Anna)"), its bot as its creator:
//!
//! - **bridgev2** (mautrix-meta, mautrix-whatsapp, mautrix-signal… today) marks it with its bridge
//!   state event ([MSC2346]): its channel is `__personal_filtering_space__`, and Beeper's room type
//!   `personal_filtering_space`.
//! - **The bridges before bridgev2** set no bridge state on it: only who is in it tells it apart.
//!   Its creator is the bridge's bot, and the user shares it with bridges' bots alone.
//!
//! A bridge may call its bot anything: one named after its network (`@whatsappbot:server`) is
//! known by its name, any other as the `bridgebot` the bridge state of the user's chats names.
//!
//! A space a bridge brings from its network (a Discord server) carries bridge state for that
//! channel instead, and stays: no place stands for it. A space a person made stays too.
//!
//! [MSC2346]: https://github.com/matrix-org/matrix-spec-proposals/pull/2346

use crate::network::Network;

/// The channel id bridgev2 gives a login's space in its bridge state event.
const LOGIN_SPACE_CHANNEL: &str = "__personal_filtering_space__";
/// Beeper's room type (`com.beeper.room_type.v2`) bridgev2 gives a login's space.
const LOGIN_SPACE_ROOM_TYPE: &str = "personal_filtering_space";

/// What one bridge state event (`m.bridge` or `uk.half-shot.bridge`) of a room says.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct BridgeState {
    /// The network's protocol id (`protocol.id`), as [`Network::from_protocol`] reads it.
    pub protocol: Option<String>,
    /// The bridge's bot (`bridgebot`).
    pub bot: Option<String>,
    /// The id of the network's channel the room stands for (`channel.id`).
    pub channel: Option<String>,
    /// Beeper's room type (`com.beeper.room_type.v2`).
    pub room_type: Option<String>,
}

impl BridgeState {
    /// Whether it marks the space a bridge made for a login.
    fn marks_login_space(&self) -> bool {
        self.channel.as_deref() == Some(LOGIN_SPACE_CHANNEL) || self.room_type.as_deref() == Some(LOGIN_SPACE_ROOM_TYPE)
    }
}

/// What a space's room says about who made it.
#[derive(Clone, Copy, Debug)]
pub struct SpaceOrigin<'a> {
    /// The users who created it (`m.room.create`'s sender, and in room version 12 its
    /// `additional_creators`).
    pub creators: &'a [String],
    /// Who is in it but the user.
    pub members: &'a [String],
    /// Its bridge state events.
    pub bridge_states: &'a [BridgeState],
}

impl SpaceOrigin<'_> {
    /// Whether a bridge made it for a login. `bots` are the bridges' bots the user's chats name
    /// in their bridge state; a bot named after its network counts without.
    #[must_use]
    pub fn is_login_space(&self, bots: &[&str]) -> bool {
        if !self.bridge_states.is_empty() {
            return self.bridge_states.iter().any(BridgeState::marks_login_space);
        }
        self.by_its_people(|user| Network::from_bridge_bot(user).is_some() || bots.contains(&user))
    }

    /// Whether only the bridges' bots the user's chats name could decide
    /// [`SpaceOrigin::is_login_space`]: it has no bridge state, and the bots' names alone do not
    /// tell. Reading those bots costs the state of its chats, so only then.
    #[must_use]
    pub fn needs_bots(&self) -> bool {
        self.bridge_states.is_empty() && !self.by_its_people(|user| Network::from_bridge_bot(user).is_some())
    }

    /// Whether a bot, as `is_bot` knows them, created it, or only bots share it with the user.
    fn by_its_people(&self, is_bot: impl Fn(&str) -> bool) -> bool {
        self.creators.first().is_some_and(|creator| is_bot(creator))
            || (!self.members.is_empty() && self.members.iter().all(|member| is_bot(member)))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn users(ids: &[&str]) -> Vec<String> {
        ids.iter().map(|id| (*id).to_owned()).collect()
    }

    /// The space created by `creator`, shared with `members`, with no bridge state.
    fn origin<'a>(creators: &'a [String], members: &'a [String]) -> SpaceOrigin<'a> {
        SpaceOrigin {
            creators,
            members,
            bridge_states: &[],
        }
    }

    #[test]
    fn a_bridgev2_login_space_is_the_bridges() {
        let creators = users(&["@metabot:example.org"]);
        let states = [BridgeState {
            protocol: None,
            bot: Some("@metabot:example.org".into()),
            channel: Some(LOGIN_SPACE_CHANNEL.into()),
            room_type: Some(LOGIN_SPACE_ROOM_TYPE.into()),
        }];
        let origin = SpaceOrigin {
            creators: &creators,
            members: &[],
            bridge_states: &states,
        };
        assert!(origin.is_login_space(&[]));
        assert!(!origin.needs_bots());
    }

    #[test]
    fn either_mark_of_bridgev2_is_enough() {
        let creators = users(&["@bridge:example.org"]);
        let by_channel = [BridgeState {
            channel: Some(LOGIN_SPACE_CHANNEL.into()),
            ..BridgeState::default()
        }];
        let by_type = [BridgeState {
            room_type: Some(LOGIN_SPACE_ROOM_TYPE.into()),
            ..BridgeState::default()
        }];
        for states in [&by_channel, &by_type] {
            let origin = SpaceOrigin {
                creators: &creators,
                members: &[],
                bridge_states: states,
            };
            assert!(origin.is_login_space(&[]));
        }
    }

    #[test]
    fn a_space_a_bridge_brings_from_its_network_stays() {
        // a Discord server, bridged as a space by the bridge's bot, shared with it alone.
        let bot = users(&["@discordbot:example.org"]);
        let states = [BridgeState {
            protocol: None,
            bot: Some("@discordbot:example.org".into()),
            channel: Some("1234567890".into()),
            room_type: None,
        }];
        let origin = SpaceOrigin {
            creators: &bot,
            members: &bot,
            bridge_states: &states,
        };
        assert!(!origin.is_login_space(&[]));
    }

    #[test]
    fn an_older_bridges_space_is_known_by_its_bot() {
        let creators = users(&["@whatsappbot:example.org"]);
        let origin = origin(&creators, &[]);
        assert!(origin.is_login_space(&[]));
        assert!(!origin.needs_bots());
    }

    #[test]
    fn a_bot_named_otherwise_is_known_from_the_chats_bridge_state() {
        let creators = users(&["@wa:example.org"]);
        let origin = origin(&creators, &[]);
        assert!(origin.needs_bots());
        assert!(!origin.is_login_space(&["@telegrambot:example.org"]));
        assert!(origin.is_login_space(&["@telegrambot:example.org", "@wa:example.org"]));
    }

    #[test]
    fn a_space_the_user_shares_with_bridges_bots_alone_is_the_bridges() {
        // its creator is no bot (or unknown): its members tell.
        let creators = users(&["@admin:example.org"]);
        let members = users(&["@signalbot:example.org", "@wa:example.org"]);
        let space = origin(&creators, &members);
        assert!(space.needs_bots());
        assert!(!space.is_login_space(&[]));
        assert!(space.is_login_space(&["@wa:example.org"]));

        let bots = users(&["@signalbot:example.org"]);
        let space = origin(&[], &bots);
        assert!(!space.needs_bots());
        assert!(space.is_login_space(&[]));
    }

    #[test]
    fn a_persons_space_stays() {
        let anna = users(&["@anna:example.org"]);
        let members = users(&["@signalbot:example.org", "@anna:example.org"]);
        assert!(!origin(&anna, &members).is_login_space(&["@metabot:example.org"]));
        // a ghost of a bridge is no bot.
        let ghost = users(&["@whatsapp_4912345:example.org"]);
        assert!(!origin(&ghost, &ghost).is_login_space(&[]));
    }

    #[test]
    fn a_space_of_unknown_origin_stays() {
        assert!(!origin(&[], &[]).is_login_space(&[]));
        assert!(!origin(&[], &[]).is_login_space(&["@wa:example.org"]));
    }
}
