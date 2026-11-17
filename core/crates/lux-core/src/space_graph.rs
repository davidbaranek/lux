//! The spaces the user is in, as the rail and a space's sections show them: the top-level spaces,
//! each with the spaces right inside it.
//!
//! Which space is top-level is decided once the spaces the apps leave out are gone
//! ([`crate::bridged_space`]): a space a bridge's login space holds (a Discord server in the
//! bridge's "Discord" space) is a top-level one, its categories the spaces inside it. Levels read
//! before that would make the login space the top-level one, and its servers' categories a level
//! too deep to be shown.

use std::cmp::Ordering;
use std::collections::HashSet;

use crate::chat::Space;
use crate::ids::{ChatId, MediaId, RoomId};

/// A space the user joined, as its room says.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SpaceNode {
    /// Its room.
    pub id: RoomId,
    /// Its name.
    pub name: String,
    /// Its picture.
    pub avatar: Option<MediaId>,
    /// The rooms right inside it, spaces and chats, in any order.
    pub children: Vec<SpaceChild>,
}

/// A room right inside a space, as the space's `m.space.child` event places it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SpaceChild {
    /// The room.
    pub id: RoomId,
    /// Its `order`, if the space gives it one.
    pub order: Option<String>,
    /// When the space took it in (its `m.space.child` event's time, in milliseconds), if known.
    pub added: Option<u64>,
}

impl SpaceChild {
    /// The [spec's order] of a space's children: those with an `order` first, by it, then by when
    /// they were added, then by their id.
    ///
    /// [spec's order]: https://spec.matrix.org/latest/client-server-api/#ordering-of-children-within-a-space
    fn by_place(&self, other: &Self) -> Ordering {
        let ordered = |child: &Self| child.order.is_none();
        let added = |child: &Self| (child.added.is_none(), child.added);
        ordered(self)
            .cmp(&ordered(other))
            .then_with(|| self.order.cmp(&other.order))
            .then_with(|| added(self).cmp(&added(other)))
            .then_with(|| self.id.as_str().cmp(other.id.as_str()))
    }
}

/// The joined spaces and what is inside them.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct SpaceGraph {
    /// In the order the top-level spaces go.
    nodes: Vec<SpaceNode>,
}

impl SpaceGraph {
    /// The graph of `nodes`, the top-level spaces among them going in their order. A loop of
    /// spaces is the caller's to break: its spaces are inside one another, none top-level.
    #[must_use]
    pub fn new(mut nodes: Vec<SpaceNode>) -> Self {
        for node in &mut nodes {
            node.children.sort_by(SpaceChild::by_place);
        }
        Self { nodes }
    }

    fn node(&self, id: &RoomId) -> Option<&SpaceNode> {
        self.nodes.iter().find(|node| node.id == *id)
    }

    /// The joined spaces' rooms.
    pub fn ids(&self) -> impl Iterator<Item = &RoomId> {
        self.nodes.iter().map(|node| &node.id)
    }

    /// The rooms inside the space `id`, those inside the spaces inside it too, the spaces in
    /// `hidden` and what only they hold aside.
    #[must_use]
    pub fn descendants(&self, id: &RoomId, hidden: &HashSet<RoomId>) -> Vec<RoomId> {
        let mut seen: HashSet<&RoomId> = HashSet::from([id]);
        let mut found = Vec::new();
        let mut next = vec![id];
        while let Some(space) = next.pop() {
            for child in self.node(space).into_iter().flat_map(|node| &node.children) {
                if hidden.contains(&child.id) || !seen.insert(&child.id) {
                    continue;
                }
                found.push(child.id.clone());
                next.push(&child.id);
            }
        }
        found
    }

    /// The spaces the rail shows, but those in `hidden`: each top-level one (inside no space
    /// shown), then each space right inside it, which names it as its parent. A space holds the
    /// chats of all the spaces inside it.
    #[must_use]
    pub fn spaces(&self, hidden: &HashSet<RoomId>) -> Vec<Space> {
        let shown: Vec<&SpaceNode> = self.nodes.iter().filter(|node| !hidden.contains(&node.id)).collect();
        let inside_one = |id: &RoomId| {
            shown
                .iter()
                .any(|parent| parent.children.iter().any(|child| child.id == *id))
        };
        let space = |node: &SpaceNode, parents: Vec<RoomId>| Space {
            id: node.id.clone(),
            name: node.name.clone(),
            avatar: node.avatar.clone(),
            chats: self
                .descendants(&node.id, hidden)
                .into_iter()
                .map(ChatId::from)
                .collect(),
            parents,
        };
        let mut spaces: Vec<Space> = Vec::new();
        for top in shown.iter().filter(|node| !inside_one(&node.id)) {
            spaces.push(space(top, Vec::new()));
            for child in &top.children {
                let Some(inner) = shown.iter().find(|node| node.id == child.id) else {
                    continue;
                };
                // a space inside two top-level ones is listed once, with both as its parents.
                if let Some(known) = spaces.iter_mut().find(|known| known.id == inner.id) {
                    known.parents.push(top.id.clone());
                } else {
                    spaces.push(space(inner, vec![top.id.clone()]));
                }
            }
        }
        spaces
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn node(id: &str, children: &[&str]) -> SpaceNode {
        SpaceNode {
            id: id.into(),
            name: id.trim_start_matches('!').to_owned(),
            avatar: None,
            children: children
                .iter()
                .enumerate()
                .map(|(at, &child)| SpaceChild {
                    id: child.into(),
                    order: None,
                    added: u64::try_from(at).ok(),
                })
                .collect(),
        }
    }

    fn hidden(ids: &[&str]) -> HashSet<RoomId> {
        ids.iter().map(|&id| id.into()).collect()
    }

    /// Each space's id, parents and chats, sorted.
    fn shape(spaces: &[Space]) -> Vec<(String, Vec<String>, Vec<String>)> {
        spaces
            .iter()
            .map(|space| {
                let mut chats: Vec<String> = space.chats.iter().map(ToString::to_string).collect();
                chats.sort();
                let parents = space.parents.iter().map(ToString::to_string).collect();
                (space.id.to_string(), parents, chats)
            })
            .collect()
    }

    fn row(id: &str, parents: &[&str], chats: &[&str]) -> (String, Vec<String>, Vec<String>) {
        let strings = |ids: &[&str]| ids.iter().map(|&id| id.to_owned()).collect();
        (id.to_owned(), strings(parents), strings(chats))
    }

    #[test]
    fn a_top_level_space_lists_the_spaces_inside_it() {
        // a space the user made, its categories inside it.
        let graph = SpaceGraph::new(vec![
            node("!krtek", &["!text", "!voice"]),
            node("!text", &["!general"]),
            node("!voice", &["!lounge"]),
        ]);
        assert_eq!(
            shape(&graph.spaces(&HashSet::new())),
            [
                row("!krtek", &[], &["!general", "!lounge", "!text", "!voice"]),
                row("!text", &["!krtek"], &["!general"]),
                row("!voice", &["!krtek"], &["!lounge"]),
            ]
        );
    }

    #[test]
    fn a_server_in_a_bridges_login_space_lists_its_categories() {
        // the Discord bridge's own "Discord" space holds the servers; it is left out, so the
        // server is the top-level space and its categories (empty ones too) the spaces inside.
        let graph = SpaceGraph::new(vec![
            node("!discord", &["!radian", "!dms"]),
            node("!radian", &["!important", "!general", "!team", "!voice"]),
            node("!important", &["!rules", "!updates", "!sneek-peeks"]),
            node("!general", &["!open-space", "!radian-chat"]),
            node("!team", &[]),
            node("!voice", &[]),
        ]);
        assert_eq!(
            shape(&graph.spaces(&hidden(&["!discord"]))),
            [
                row(
                    "!radian",
                    &[],
                    &[
                        "!general",
                        "!important",
                        "!open-space",
                        "!radian-chat",
                        "!rules",
                        "!sneek-peeks",
                        "!team",
                        "!updates",
                        "!voice",
                    ],
                ),
                row("!important", &["!radian"], &["!rules", "!sneek-peeks", "!updates"]),
                row("!general", &["!radian"], &["!open-space", "!radian-chat"]),
                row("!team", &["!radian"], &[]),
                row("!voice", &["!radian"], &[]),
            ]
        );
    }

    #[test]
    fn the_spaces_inside_one_go_in_the_spaces_order() {
        let mut radian = node("!radian", &[]);
        let child = |id: &str, order: Option<&str>, added: Option<u64>| SpaceChild {
            id: id.into(),
            order: order.map(ToOwned::to_owned),
            added,
        };
        radian.children = vec![
            child("!unknown", None, None),
            child("!later", None, Some(20)),
            child("!earlier", None, Some(10)),
            child("!b", Some("b"), Some(1)),
            child("!a", Some("a"), Some(5)),
        ];
        let graph = SpaceGraph::new(vec![
            radian,
            node("!unknown", &[]),
            node("!later", &[]),
            node("!earlier", &[]),
            node("!b", &[]),
            node("!a", &[]),
        ]);
        let ids: Vec<String> = graph
            .spaces(&HashSet::new())
            .iter()
            .map(|space| space.id.to_string())
            .collect();
        assert_eq!(ids, ["!radian", "!a", "!b", "!earlier", "!later", "!unknown"]);
    }

    #[test]
    fn a_space_inside_two_lists_both_and_a_space_two_deep_is_not_listed() {
        let graph = SpaceGraph::new(vec![
            node("!one", &["!shared"]),
            node("!two", &["!shared"]),
            node("!shared", &["!deep"]),
            node("!deep", &["!chat"]),
        ]);
        assert_eq!(
            shape(&graph.spaces(&HashSet::new())),
            [
                row("!one", &[], &["!chat", "!deep", "!shared"]),
                row("!shared", &["!one", "!two"], &["!chat", "!deep"]),
                row("!two", &[], &["!chat", "!deep", "!shared"]),
            ]
        );
    }

    #[test]
    fn a_loop_of_spaces_ends() {
        let graph = SpaceGraph::new(vec![node("!a", &["!b"]), node("!b", &["!a", "!chat"])]);
        let mut found = graph.descendants(&"!a".into(), &HashSet::new());
        found.sort_by(|one, other| one.as_str().cmp(other.as_str()));
        assert_eq!(found, [RoomId::from("!b"), RoomId::from("!chat")]);
    }
}
