//! Which chats the inbox shows. Every chat of the inbox folder, unless one of its places keeps
//! it out: a network or a space can let all its chats in, only those that call for the user
//! (conversations of two, groups that mention them), or none. A chat's own rule beats its
//! places'. A chat kept out stays in its places, where the user goes to read it.

use std::collections::HashMap;

use super::{Arrangement, PlaceKey};
use crate::chat::{Chat, Folder, Space};
use crate::ids::ChatId;

/// How much of a place (or of one chat) the inbox shows.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum InboxRule {
    /// Nothing: its chats are read in their places only.
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

/// The inbox's rules, read once for a list: the arrangement's, and each chat's strictest of
/// the spaces it is in.
pub(crate) struct InboxRules<'a> {
    arrangement: &'a Arrangement,
    /// The strictest rule of the spaces each chat is in, for the chats in a space with one.
    spaces: HashMap<&'a ChatId, InboxRule>,
}

impl<'a> InboxRules<'a> {
    pub(crate) fn new(arrangement: &'a Arrangement, spaces: &'a [Space]) -> Self {
        let mut by_chat: HashMap<&'a ChatId, InboxRule> = HashMap::new();
        if !arrangement.inbox.is_empty() {
            for space in spaces {
                let Some(&rule) = arrangement.inbox.get(&PlaceKey::space(space)) else {
                    continue;
                };
                // a space's chats are those of the spaces inside it too: its rule reaches them.
                for chat in &space.chats {
                    by_chat
                        .entry(chat)
                        .and_modify(|stricter| *stricter = (*stricter).min(rule))
                        .or_insert(rule);
                }
            }
        }
        Self {
            arrangement,
            spaces: by_chat,
        }
    }

    /// The rule `chat` follows: its own, else the strictest of its network's and its spaces'.
    pub(crate) fn of(&self, chat: &Chat) -> InboxRule {
        if let Some(&own) = self.arrangement.chat_inbox.get(&chat.id) {
            return own;
        }
        let network = self.arrangement.inbox.get(&PlaceKey::network(&chat.network)).copied();
        let space = self.spaces.get(&chat.id).copied();
        network.into_iter().chain(space).min().unwrap_or_default()
    }

    /// Whether the inbox shows `chat`: in the inbox folder, and pinned there or let in by its
    /// rule.
    pub(crate) fn admits(&self, chat: &Chat) -> bool {
        chat.folder == Folder::Inbox && (chat.pinned.is_some() || self.of(chat).admits(chat))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::network::Network;
    use crate::places::PlaceId;
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
    fn a_chat_follows_the_strictest_of_its_places_and_its_own_rule_beats_them() {
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
        assert_eq!(rules.of(&group("general", "discord", 0)), InboxRule::Never);
        // inside a space inside the guild: the guild's rule reaches it.
        assert_eq!(rules.of(&group("inner", "discord", 0)), InboxRule::Mentions);
        assert_eq!(rules.of(&chat("elsewhere", "discord")), InboxRule::All);
        let arrangement = arrangement
            .with_inbox(PlaceId::Network(Network::from_id("discord")).key(), InboxRule::Never)
            .with_chat_inbox("inner".into(), Some(InboxRule::All));
        let rules = InboxRules::new(&arrangement, &spaces);
        assert_eq!(rules.of(&chat("elsewhere", "discord")), InboxRule::Never);
        assert_eq!(rules.of(&chat("elsewhere", "signal")), InboxRule::All);
        assert_eq!(rules.of(&group("inner", "discord", 0)), InboxRule::All);
    }

    #[test]
    fn the_inbox_keeps_pinned_chats_and_only_its_own_folder() {
        let arrangement =
            Arrangement::default().with_inbox(PlaceId::Network(Network::from_id("discord")).key(), InboxRule::Never);
        let rules = InboxRules::new(&arrangement, &[]);
        assert!(!rules.admits(&chat("a", "discord")));
        assert!(rules.admits(&Chat {
            pinned: Some(1.0),
            ..chat("a", "discord")
        }));
        assert!(!rules.admits(&Chat {
            folder: Folder::LowPriority,
            ..chat("b", "signal")
        }));
        assert!(rules.admits(&chat("b", "signal")));
    }
}
