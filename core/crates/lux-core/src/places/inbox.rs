//! Which chats the inbox shows, and so which are of low priority: low priority is every chat of
//! the inbox and archive's sides that the inbox does not show. A chat is of low priority by its
//! own `m.lowpriority` tag, or because one of its places keeps it out: a network or a space can
//! let all its chats in, only those that call for the user (conversations of two, groups that
//! mention them), or none. A pinned chat stays in the inbox, whatever its places say. A chat kept
//! out stays in its places, where the user goes to read it.

use std::collections::HashMap;

use super::{Arrangement, PlaceId, PlaceKey};
use crate::chat::{Chat, Folder, Space};
use crate::ids::ChatId;

/// How much of a place's chats the inbox shows.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum InboxRule {
    /// Nothing: its chats are read in their places, and in low priority.
    Never,
    /// Conversations of two, and groups while they mention the user.
    Mentions,
    /// Everything, as the inbox always did.
    #[default]
    All,
}

impl InboxRule {
    /// Every rule, in the order the apps offer them: the most first.
    pub const ALL: [Self; 3] = [Self::All, Self::Mentions, Self::Never];

    /// Its key, as the account keeps it.
    #[must_use]
    pub fn as_str(self) -> &'static str {
        match self {
            Self::All => "all",
            Self::Mentions => "mentions",
            Self::Never => "never",
        }
    }

    /// The rule a key names; `None` for one this version does not know.
    #[must_use]
    pub fn from_key(key: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|rule| rule.as_str() == key)
    }

    /// Whether the inbox shows `chat` by this rule.
    #[must_use]
    pub fn admits(self, chat: &Chat) -> bool {
        match self {
            Self::All => true,
            Self::Mentions => !chat.is_group || chat.unread_mentions > 0,
            Self::Never => false,
        }
    }
}

/// The inbox's rules, read once for a list: the networks' from the arrangement, and for each
/// chat in a space with a rule, the strictest of those spaces.
pub(crate) struct InboxRules<'a> {
    arrangement: &'a Arrangement,
    /// The strictest space rule over each chat in a space with one, and that space.
    spaces: HashMap<&'a ChatId, (InboxRule, &'a Space)>,
}

impl<'a> InboxRules<'a> {
    pub(crate) fn new(arrangement: &'a Arrangement, spaces: &'a [Space]) -> Self {
        let mut by_chat: HashMap<&'a ChatId, (InboxRule, &'a Space)> = HashMap::new();
        if !arrangement.inbox.is_empty() {
            for space in spaces {
                let Some(&rule) = arrangement.inbox.get(&PlaceKey::space(space)) else {
                    continue;
                };
                // a space's chats are those of the spaces inside it too: its rule reaches them.
                for chat in &space.chats {
                    by_chat
                        .entry(chat)
                        .and_modify(|stricter| {
                            if rule < stricter.0 {
                                *stricter = (rule, space);
                            }
                        })
                        .or_insert((rule, space));
                }
            }
        }
        Self {
            arrangement,
            spaces: by_chat,
        }
    }

    /// The strictest rule of `chat`'s places, and the place that has it (its network when its
    /// network's is as strict as its spaces'); `None` when no place of it has one.
    fn strictest(&self, chat: &Chat) -> Option<(InboxRule, PlaceId)> {
        let network = (self.arrangement.inbox.get(&PlaceKey::network(&chat.network)))
            .map(|&rule| (rule, PlaceId::Network(chat.network.clone())));
        let space = (self.spaces.get(&chat.id)).map(|&(rule, space)| (rule, PlaceId::Space(space.id.clone())));
        match (network, space) {
            (Some(network), Some(space)) if space.0 < network.0 => Some(space),
            (network, space) => network.or(space),
        }
    }

    /// The place whose rule keeps `chat` out of the inbox, and so in low priority: `None` for a
    /// chat its places let in, a pinned one, or one out of the inbox's folder already.
    pub(crate) fn keeping_out(&self, chat: &Chat) -> Option<PlaceId> {
        if chat.folder != Folder::Inbox || chat.pinned.is_some() {
            return None;
        }
        self.strictest(chat)
            .filter(|(rule, _)| !rule.admits(chat))
            .map(|(_, place)| place)
    }

    /// The folder `chat` shows in: its own, unless a place keeps it out of the inbox, into low
    /// priority.
    pub(crate) fn folder_of(&self, chat: &Chat) -> Folder {
        if chat.folder == Folder::Inbox && self.keeping_out(chat).is_some() {
            Folder::LowPriority
        } else {
            chat.folder
        }
    }

    /// Every chat of `chats` a place keeps out of the inbox, with that place.
    pub(crate) fn kept_out<'c>(&self, chats: impl IntoIterator<Item = &'c Chat>) -> HashMap<ChatId, PlaceId> {
        chats
            .into_iter()
            .filter_map(|chat| Some((chat.id.clone(), self.keeping_out(chat)?)))
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::network::Network;
    use crate::places::list::tests::chat;

    fn space(id: &str, chats: &[&str], parents: &[&str]) -> Space {
        Space {
            id: id.into(),
            name: id.to_owned(),
            avatar: None,
            chats: chats.iter().map(|&chat| chat.into()).collect(),
            parents: parents.iter().map(|&parent| parent.into()).collect(),
        }
    }

    fn group(id: &str, network: &str, mentions: u32) -> Chat {
        Chat {
            is_group: true,
            unread_mentions: mentions,
            ..chat(id, network)
        }
    }

    #[test]
    fn every_rule_reads_back_from_its_key() {
        for rule in InboxRule::ALL {
            assert_eq!(InboxRule::from_key(rule.as_str()), Some(rule));
        }
        assert_eq!(InboxRule::from_key("sometimes"), None);
        assert_eq!(InboxRule::default(), InboxRule::All);
    }

    #[test]
    fn mentions_lets_in_conversations_of_two_and_groups_that_mention_the_user() {
        assert!(InboxRule::Mentions.admits(&chat("dm", "discord")));
        assert!(InboxRule::Mentions.admits(&group("pinged", "discord", 1)));
        assert!(!InboxRule::Mentions.admits(&group("chatter", "discord", 0)));
        assert!(!InboxRule::Never.admits(&chat("dm", "discord")));
    }

    #[test]
    fn a_chat_is_kept_out_by_the_strictest_of_its_places() {
        let spaces = [
            space("!guild", &["general", "inner"], &[]),
            space("!room", &["inner"], &["!guild"]),
            space("!friends", &["general"], &[]),
        ];
        let arrangement = Arrangement::default()
            .with_inbox(PlaceId::Space("!guild".into()).key(), InboxRule::Mentions)
            .with_inbox(PlaceId::Space("!friends".into()).key(), InboxRule::Never);
        let rules = InboxRules::new(&arrangement, &spaces);
        // in both spaces: the stricter keeps it out.
        assert_eq!(
            rules.keeping_out(&group("general", "discord", 1)),
            Some(PlaceId::Space("!friends".into()))
        );
        // inside a space inside the guild: the guild's rule reaches it, and a mention lets it in.
        assert_eq!(
            rules.keeping_out(&group("inner", "discord", 0)),
            Some(PlaceId::Space("!guild".into()))
        );
        assert_eq!(rules.keeping_out(&group("inner", "discord", 2)), None);
        assert_eq!(rules.keeping_out(&chat("elsewhere", "discord")), None);
        let discord = Network::from_id("discord");
        let arrangement = arrangement.with_inbox(PlaceId::Network(discord.clone()).key(), InboxRule::Mentions);
        let rules = InboxRules::new(&arrangement, &spaces);
        // as strict as the guild: the network says so.
        assert_eq!(
            rules.keeping_out(&group("inner", "discord", 0)),
            Some(PlaceId::Network(discord))
        );
        assert_eq!(rules.keeping_out(&group("elsewhere", "signal", 0)), None);
    }

    #[test]
    fn what_a_place_keeps_out_is_of_low_priority_but_a_pinned_chat_stays() {
        let arrangement =
            Arrangement::default().with_inbox(PlaceId::Network(Network::from_id("discord")).key(), InboxRule::Never);
        let rules = InboxRules::new(&arrangement, &[]);
        assert_eq!(rules.folder_of(&chat("a", "discord")), Folder::LowPriority);
        let pinned = Chat {
            pinned: Some(1.0),
            ..chat("a", "discord")
        };
        assert_eq!(rules.folder_of(&pinned), Folder::Inbox);
        let archived = Chat {
            folder: Folder::Archive,
            ..chat("b", "discord")
        };
        assert_eq!(rules.folder_of(&archived), Folder::Archive);
        assert_eq!(rules.folder_of(&chat("c", "signal")), Folder::Inbox);
        let kept = rules.kept_out([&chat("a", "discord"), &pinned, &archived, &chat("c", "signal")]);
        assert_eq!(kept.len(), 1);
        assert_eq!(kept[&ChatId::from("a")], PlaceId::Network(Network::from_id("discord")));
    }
}
