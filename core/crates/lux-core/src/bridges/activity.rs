//! Whether a bridge is bringing a network's history (backfilling): bridges do not say so, but
//! their history comes as messages the server takes now with the time they were sent on the
//! network, long before. While such messages keep coming, the network is catching up; a while
//! after the last, it is done.
//!
//! When the server took a message is its age in the sync (`unsigned.age`), not when the sync
//! brings it: a sync also brings messages the server took long ago (an opened chat's latest
//! messages, a sync that starts over), which are no history arriving.

use std::collections::{BTreeMap, HashSet};
use std::time::{Duration, SystemTime};

use crate::ids::RoomId;
use crate::network::Network;

/// A network that is catching up: how much of its history has come so far.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CatchUp {
    /// The network.
    pub network: Network,
    /// The chats its history came to.
    pub chats: usize,
    /// The messages that came.
    pub messages: usize,
}

/// The history that arrives, by network, and since when none has.
#[derive(Debug, Default)]
pub struct HistoryArrivals {
    networks: BTreeMap<Network, Arrived>,
}

#[derive(Debug)]
struct Arrived {
    rooms: HashSet<RoomId>,
    messages: usize,
    last: SystemTime,
}

impl HistoryArrivals {
    /// How much older than its arrival at the server a message is history: bridges send what
    /// is new within seconds.
    pub const OLD: Duration = Duration::from_mins(15);

    /// How long after the last old message a network is done: bridges send a chat's history in
    /// batches, a few seconds apart, and the chats one after another.
    pub const QUIET: Duration = Duration::from_secs(60);

    /// Whether a message sent at `sent` that the server took at `taken` is history: it reached
    /// the server [`Self::OLD`] after it was sent.
    #[must_use]
    pub fn is_history(sent: SystemTime, taken: SystemTime) -> bool {
        taken.duration_since(sent).unwrap_or_default() >= Self::OLD
    }

    /// The sync brought, at `now`, a message of `network`'s chat `room`, sent at `sent` and taken
    /// by the server at `taken`; whether it is history ([`Self::is_history`]).
    pub fn arrived(
        &mut self,
        network: Network,
        room: RoomId,
        sent: SystemTime,
        taken: SystemTime,
        now: SystemTime,
    ) -> bool {
        if network == Network::Matrix || !Self::is_history(sent, taken) {
            return false;
        }
        let arrived = self.networks.entry(network).or_insert_with(|| Arrived {
            rooms: HashSet::new(),
            messages: 0,
            last: now,
        });
        arrived.rooms.insert(room);
        arrived.messages += 1;
        arrived.last = arrived.last.max(now);
        true
    }

    /// The networks catching up at `now`, in the apps' order; those quiet for [`Self::QUIET`]
    /// are done, and forgotten.
    pub fn catching_up(&mut self, now: SystemTime) -> Vec<CatchUp> {
        self.networks
            .retain(|_, arrived| now.duration_since(arrived.last).unwrap_or_default() < Self::QUIET);
        self.networks
            .iter()
            .map(|(network, arrived)| CatchUp {
                network: network.clone(),
                chats: arrived.rooms.len(),
                messages: arrived.messages,
            })
            .collect()
    }

    /// When the next network is done, if one is catching up.
    #[must_use]
    pub fn next_done(&self) -> Option<SystemTime> {
        self.networks.values().map(|arrived| arrived.last + Self::QUIET).min()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn room(id: &str) -> RoomId {
        RoomId::from(id)
    }

    #[test]
    fn old_messages_arriving_make_their_network_catch_up_until_a_quiet_minute() {
        let start = SystemTime::UNIX_EPOCH + Duration::from_secs(1_000_000);
        let old = start - Duration::from_secs(3600);
        let mut arrivals = HistoryArrivals::default();

        let now = |seconds| start + Duration::from_secs(seconds);
        assert!(arrivals.arrived(Network::Messenger, room("!a"), old, start, start));
        assert!(arrivals.arrived(Network::Messenger, room("!b"), old, now(5), now(5)));
        assert!(arrivals.arrived(Network::Messenger, room("!b"), old, now(6), now(6)));
        // a new message is no history; Matrix has no bridge.
        assert!(!arrivals.arrived(Network::Instagram, room("!c"), start, start, start));
        assert!(!arrivals.arrived(Network::Matrix, room("!d"), old, start, start));
        // an old message the server took when it was sent (an opened chat's latest, a sync that
        // starts over) is no history, however late the sync brings it.
        assert!(!arrivals.arrived(Network::Discord, room("!e"), old, old, now(10)));

        assert_eq!(
            arrivals.catching_up(start + Duration::from_secs(30)),
            [CatchUp {
                network: Network::Messenger,
                chats: 2,
                messages: 3
            }]
        );
        assert_eq!(arrivals.next_done(), Some(start + Duration::from_secs(66)));
        assert!(arrivals.catching_up(start + Duration::from_secs(66)).is_empty());
        assert_eq!(arrivals.next_done(), None);
    }
}
