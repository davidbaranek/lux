//! Mentions, both ways. The composer holds its text with pills: runs that stand for a member (or
//! `@room`), each showing their name. Sending writes them as the spec's intentional mentions
//! ([user and room mentions](https://spec.matrix.org/v1.16/client-server-api/#user-and-room-mentions)):
//! the plain body has the names, the HTML a `matrix.to` link for each member, and `m.mentions`
//! the members and the room. A kept draft is the same Markdown, its pills links, read back into
//! pills. While the user types `@` and a word, the room's members are offered, best match first.
//!
//! Coming in, a member's link is a pill showing their name in the room now (as Element shows it),
//! and `@room` is one when the message mentions the room.

use std::ops::Range;

use pulldown_cmark::{Event, LinkType, Parser, Tag, TagEnd};
use ruma_common::matrix_uri::MatrixId;
use ruma_common::{MatrixToUri, MatrixUri};

use crate::ids::UserId;
use crate::markdown::Utf16Offsets;
use crate::ports::Member;
use crate::search::folded;
use crate::timeline::{StyleKind, TextStyle};

/// What `@room` is written as.
pub const ROOM: &str = "@room";

/// Who a mention names.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum MentionTarget {
    /// A member.
    User(UserId),
    /// Everyone in the room (`@room`).
    Room,
}

/// A pill in a text: who it names and where it is, in UTF-16 offsets (as the apps' text views
/// count), over the name it shows.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Mention {
    /// Who.
    pub target: MentionTarget,
    /// Where.
    pub range: Range<usize>,
}

/// What the composer holds: its Markdown text, and the pills in it.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ComposedText {
    /// The text, each pill's name in its place.
    pub text: String,
    /// The pills, over their names.
    pub mentions: Vec<Mention>,
}

impl From<&str> for ComposedText {
    fn from(text: &str) -> Self {
        Self {
            text: text.to_owned(),
            mentions: Vec::new(),
        }
    }
}

impl From<String> for ComposedText {
    fn from(text: String) -> Self {
        Self {
            text,
            mentions: Vec::new(),
        }
    }
}

/// A text message as it goes: what the spec's `body`, `formatted_body` (from `markdown`) and
/// `m.mentions` hold.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct OutgoingText {
    /// The plain body: the text as written, each pill its name.
    pub body: String,
    /// The text with each member's pill a `matrix.to` link, for the HTML body.
    pub markdown: String,
    /// The members mentioned, each once, in the order they come.
    pub users: Vec<UserId>,
    /// `@room` was mentioned.
    pub room: bool,
}

impl ComposedText {
    /// A message's text as the composer starts from it to edit it: its pills kept.
    #[must_use]
    pub fn of_message(text: &str, styles: &[TextStyle]) -> Self {
        Self {
            text: text.to_owned(),
            mentions: styles
                .iter()
                .filter_map(|style| match &style.kind {
                    StyleKind::Mention(target) => Some(Mention {
                        target: target.clone(),
                        range: style.range.clone(),
                    }),
                    _ => None,
                })
                .collect(),
        }
    }

    /// Whether it holds nothing but white space.
    #[must_use]
    pub fn is_blank(&self) -> bool {
        self.text.trim().is_empty()
    }

    /// The text without white space around it, its pills kept where they are (a pill whose name
    /// ends in white space ends where the text does).
    #[must_use]
    pub fn trimmed(&self) -> Self {
        let leading = self.text.len() - self.text.trim_start().len();
        let shift = Utf16Offsets::new(&self.text).at(leading);
        let text = self.text.trim().to_owned();
        let length = text.encode_utf16().count();
        let mentions = self
            .mentions
            .iter()
            .filter_map(|mention| {
                let start = mention.range.start.checked_sub(shift)?;
                let end = mention.range.end.checked_sub(shift)?.min(length);
                (start < end).then(|| Mention {
                    target: mention.target.clone(),
                    range: start..end,
                })
            })
            .collect();
        Self { text, mentions }
    }

    /// Its pills over whole characters, in order, none overlapping another: their byte ranges in
    /// the text.
    fn pills(&self) -> Vec<(Range<usize>, &MentionTarget)> {
        let offsets = Utf16Offsets::new(&self.text);
        let mut pills: Vec<(Range<usize>, &MentionTarget)> = self
            .mentions
            .iter()
            .filter_map(|mention| {
                let start = offsets.byte(mention.range.start)?;
                let end = offsets.byte(mention.range.end)?;
                (start < end).then_some((start..end, &mention.target))
            })
            .collect();
        pills.sort_by_key(|(range, _)| range.start);
        let mut end = 0;
        pills.retain(|(range, _)| {
            let keep = range.start >= end;
            if keep {
                end = range.end;
            }
            keep
        });
        pills
    }

    /// The message it sends.
    #[must_use]
    pub fn outgoing(&self) -> OutgoingText {
        let mut outgoing = OutgoingText {
            body: self.text.clone(),
            ..OutgoingText::default()
        };
        let mut last = 0;
        for (range, target) in self.pills() {
            outgoing
                .markdown
                .push_str(self.text.get(last..range.start).unwrap_or_default());
            let name = self.text.get(range.clone()).unwrap_or_default();
            match target {
                MentionTarget::User(user) => match matrix_to(user) {
                    Some(address) => {
                        outgoing.markdown.push_str(&link(name, &address));
                        if !outgoing.users.contains(user) {
                            outgoing.users.push(user.clone());
                        }
                    }
                    None => outgoing.markdown.push_str(name),
                },
                MentionTarget::Room => {
                    outgoing.markdown.push_str(name);
                    outgoing.room = true;
                }
            }
            last = range.end;
        }
        outgoing.markdown.push_str(self.text.get(last..).unwrap_or_default());
        outgoing
    }

    /// Its text as a kept draft holds it: each member's pill a `matrix.to` link.
    #[must_use]
    pub fn draft_text(&self) -> String {
        self.outgoing().markdown
    }

    /// A kept draft's text, its members' `matrix.to` links pills again.
    #[must_use]
    pub fn from_draft(markdown: &str) -> Self {
        let mut composed = Self::default();
        let mut length = 0;
        let mut last = 0;
        // the link being read: where it starts, who it names, its text so far.
        let mut open: Option<(usize, UserId, String)> = None;
        for (event, range) in Parser::new(markdown).into_offset_iter() {
            match event {
                Event::Start(Tag::Link {
                    link_type: LinkType::Inline,
                    dest_url,
                    ..
                }) if open.is_none() => {
                    if let Some(user) = mentioned_user(&dest_url) {
                        open = Some((range.start, user, String::new()));
                    }
                }
                Event::Text(text) | Event::Code(text) => {
                    if let Some((_, _, name)) = open.as_mut() {
                        name.push_str(&text);
                    }
                }
                Event::End(TagEnd::Link) => {
                    if let Some((start, user, name)) = open.take() {
                        let before = markdown.get(last..start).unwrap_or_default();
                        composed.text.push_str(before);
                        length += before.encode_utf16().count();
                        let name_length = name.encode_utf16().count();
                        composed.text.push_str(&name);
                        composed.mentions.push(Mention {
                            target: MentionTarget::User(user),
                            range: length..length + name_length,
                        });
                        length += name_length;
                        last = range.end;
                    }
                }
                _ => {}
            }
        }
        composed.text.push_str(markdown.get(last..).unwrap_or_default());
        composed
    }
}

/// `@user`'s `matrix.to` address, if it is a user id.
fn matrix_to(user: &UserId) -> Option<String> {
    ruma_common::UserId::parse(user.as_str())
        .ok()
        .map(|user| user.matrix_to_uri().to_string())
}

/// The member a link's address names: a `matrix.to` or `matrix:` address of a user.
#[must_use]
pub fn mentioned_user(address: &str) -> Option<UserId> {
    let id = if let Ok(uri) = MatrixToUri::parse(address) {
        uri.id().clone()
    } else {
        MatrixUri::parse(address).ok()?.id().clone()
    };
    match id {
        MatrixId::User(user) => Some(UserId::from(user.as_str())),
        _ => None,
    }
}

/// A Markdown link to `address` showing `name` as it is: its marks escaped.
fn link(name: &str, address: &str) -> String {
    let mut link = String::with_capacity(name.len() + address.len() + 6);
    link.push('[');
    for character in name.chars() {
        match character {
            '\n' | '\r' => link.push(' '),
            character if character.is_ascii_punctuation() => {
                link.push('\\');
                link.push(character);
            }
            character => link.push(character),
        }
    }
    link.push_str("](<");
    link.push_str(address);
    link.push_str(">)");
    link
}

/// The `@` and the word the user is typing before the cursor, which the members offered match.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MentionQuery {
    /// Where the `@` and the word are, in UTF-16 offsets: a picked member's pill takes its place.
    pub range: Range<usize>,
    /// The word after the `@` (may be empty).
    pub text: String,
}

/// The mention typed right before `cursor` (a UTF-16 offset of `text`): an `@` at the start of
/// the text or after a space or an opening bracket or quote, then no space up to the cursor.
#[must_use]
pub fn mention_query(text: &str, cursor: usize) -> Option<MentionQuery> {
    let offsets = Utf16Offsets::new(text);
    let before = text.get(..offsets.byte(cursor)?)?;
    let at = before.rfind('@')?;
    let word = before.get(at + 1..)?;
    if word.chars().any(char::is_whitespace) {
        return None;
    }
    let opens = before
        .get(..at)?
        .chars()
        .next_back()
        .is_none_or(|character| character.is_whitespace() || "([{\"'«“‘".contains(character));
    opens.then(|| MentionQuery {
        range: offsets.at(at)..cursor,
        text: word.to_owned(),
    })
}

/// What the composer offers for a mention.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum MentionSuggestion {
    /// A member.
    Member(Member),
    /// `@room`, for an account whose power level lets it notify the room.
    Room,
}

/// A room's members as mentions find them: each one's name, user id and its local part folded
/// once (without case or accents), for every word typed after an `@` to rank them again.
#[derive(Debug)]
pub struct Mentionable {
    members: Vec<FoldedMember>,
    may_mention_room: bool,
}

#[derive(Debug)]
struct FoldedMember {
    member: Member,
    name: String,
    id: String,
    local: String,
}

impl Mentionable {
    /// `members`, folded; the account among them says whether `@room` is offered.
    #[must_use]
    pub fn new(members: &[Member]) -> Self {
        Self {
            may_mention_room: members.iter().any(|member| member.is_own && member.may_mention_room),
            members: members
                .iter()
                .filter(|member| !member.is_own)
                .map(|member| FoldedMember {
                    name: folded(&member.name),
                    id: folded(member.user.as_str().trim_start_matches('@')),
                    local: folded(member.user.localpart()),
                    member: member.clone(),
                })
                .collect(),
        }
    }

    /// The members (and `@room`) a mention's `query` offers, the best match first, at most
    /// `limit`: those whose name starts with it, then whose name has a word or whose user id
    /// starts with it, then whose name or id holds it, then whose name or id has its letters in
    /// order, each by name; ignoring case and accents. The account is never offered; `@room` only
    /// when its power level allows (`notifications.room`). An empty query offers everyone, by
    /// name, `@room` last.
    #[must_use]
    pub fn suggestions(&self, query: &str, limit: usize) -> Vec<MentionSuggestion> {
        let query = folded(query.trim_start_matches('@'));
        // (tier, folded name, the member's index; none for `@room`): only those shown are cloned.
        let mut ranked: Vec<(u8, &str, Option<usize>)> = self
            .members
            .iter()
            .enumerate()
            .filter_map(|(index, folded)| {
                let tier = rank(&query, &folded.name, &folded.id, &folded.local)?;
                Some((tier, folded.name.as_str(), Some(index)))
            })
            .collect();
        if self.may_mention_room {
            let tier = if query.is_empty() {
                Some(u8::MAX)
            } else {
                rank(&query, "room", "room", "room")
            };
            if let Some(tier) = tier {
                ranked.push((tier, "room", None));
            }
        }
        let limit = limit.min(ranked.len());
        if limit < ranked.len() {
            ranked.select_nth_unstable_by(limit, |a, b| (a.0, a.1).cmp(&(b.0, b.1)));
            ranked.truncate(limit);
        }
        ranked.sort_unstable_by(|a, b| (a.0, a.1).cmp(&(b.0, b.1)));
        ranked
            .into_iter()
            .filter_map(|(_, _, index)| match index {
                Some(index) => self
                    .members
                    .get(index)
                    .map(|folded| MentionSuggestion::Member(folded.member.clone())),
                None => Some(MentionSuggestion::Room),
            })
            .collect()
    }
}

/// `Mentionable::suggestions` of `members`, folded for this one query.
#[must_use]
pub fn mention_suggestions(members: &[Member], query: &str, limit: usize) -> Vec<MentionSuggestion> {
    Mentionable::new(members).suggestions(query, limit)
}

/// How well a folded `query` matches a folded name, id and its local part: lower is better; none
/// when it does not.
fn rank(query: &str, name: &str, id: &str, local: &str) -> Option<u8> {
    if query.is_empty() || name.starts_with(query) {
        Some(0)
    } else if local.starts_with(query)
        || name
            .split(|character: char| !character.is_alphanumeric())
            .any(|word| word.starts_with(query))
    {
        Some(1)
    } else if name.contains(query) || id.contains(query) {
        Some(2)
    } else if in_order(query, name) || in_order(query, local) {
        Some(3)
    } else {
        None
    }
}

/// Whether every character of `query` is in `text`, in its order.
fn in_order(query: &str, text: &str) -> bool {
    let mut characters = text.chars();
    query
        .chars()
        .all(|wanted| characters.by_ref().any(|character| character == wanted))
}

/// A message's text with each member's pill showing `name_of` them (their name in the room now),
/// its runs moved with the text; a pill whose member has no name there keeps its text.
#[must_use]
pub fn named_pills(
    text: String,
    styles: Vec<TextStyle>,
    mut name_of: impl FnMut(&UserId) -> Option<String>,
) -> (String, Vec<TextStyle>) {
    let offsets = Utf16Offsets::new(&text);
    // each pill to rename: its UTF-16 and byte ranges, and its new name; in order, apart.
    let mut renamed: Vec<(Range<usize>, Range<usize>, String)> = Vec::new();
    for style in &styles {
        let StyleKind::Mention(MentionTarget::User(user)) = &style.kind else {
            continue;
        };
        let (Some(start), Some(end)) = (offsets.byte(style.range.start), offsets.byte(style.range.end)) else {
            continue;
        };
        let Some(name) = name_of(user).filter(|name| !name.is_empty()) else {
            continue;
        };
        if text.get(start..end) != Some(name.as_str())
            && renamed.last().is_none_or(|(last, _, _)| last.end <= style.range.start)
        {
            renamed.push((style.range.clone(), start..end, name));
        }
    }
    if renamed.is_empty() {
        return (text, styles);
    }
    let mut named = String::with_capacity(text.len());
    let mut last = 0;
    for (_, bytes, name) in &renamed {
        named.push_str(text.get(last..bytes.start).unwrap_or_default());
        named.push_str(name);
        last = bytes.end;
    }
    named.push_str(text.get(last..).unwrap_or_default());
    // an offset in the new text: past a renamed pill it moves by how much the pill grew; inside
    // one, a run's start goes to the pill's start and its end to the pill's end.
    let moved = |offset: usize, is_end: bool| {
        let mut grown: isize = 0;
        for (range, _, name) in &renamed {
            let new_length = name.encode_utf16().count();
            if offset >= range.end {
                grown += isize::try_from(new_length).unwrap_or(0) - isize::try_from(range.len()).unwrap_or(0);
            } else if offset > range.start {
                let start = range.start.saturating_add_signed(grown);
                return if is_end { start + new_length } else { start };
            } else {
                break;
            }
        }
        offset.saturating_add_signed(grown)
    };
    let styles = styles
        .into_iter()
        .map(|style| TextStyle {
            range: moved(style.range.start, false)..moved(style.range.end, true),
            kind: style.kind,
        })
        .collect();
    (named, styles)
}

/// A message that mentions the room: each `@room` written in its text is a pill (not inside code
/// or another pill).
#[must_use]
pub fn room_pills(text: &str, mut styles: Vec<TextStyle>) -> Vec<TextStyle> {
    let offsets = Utf16Offsets::new(text);
    let length = ROOM.encode_utf16().count();
    let mut found = Vec::new();
    for (at, _) in text.match_indices(ROOM) {
        let before = text.get(..at).and_then(|before| before.chars().next_back());
        let after = text.get(at + ROOM.len()..).and_then(|after| after.chars().next());
        if before.is_some_and(char::is_alphanumeric) || after.is_some_and(char::is_alphanumeric) {
            continue;
        }
        let start = offsets.at(at);
        let range = start..start + length;
        let covered = styles.iter().any(|style| {
            matches!(
                style.kind,
                StyleKind::Code | StyleKind::CodeBlock | StyleKind::Mention(_)
            ) && style.range.start < range.end
                && range.start < style.range.end
        });
        if !covered {
            found.push(TextStyle {
                kind: StyleKind::Mention(MentionTarget::Room),
                range,
            });
        }
    }
    if !found.is_empty() {
        styles.extend(found);
        styles.sort_by_key(|style| style.range.start);
    }
    styles
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ports::Role;

    fn user(id: &str) -> MentionTarget {
        MentionTarget::User(UserId::from(id))
    }

    fn pill(target: MentionTarget, range: Range<usize>) -> Mention {
        Mention { target, range }
    }

    fn member(name: &str, id: &str) -> Member {
        Member {
            user: UserId::from(id),
            name: name.to_owned(),
            avatar: None,
            role: Role::Member,
            is_own: false,
            may_mention_room: false,
        }
    }

    fn names(suggestions: &[MentionSuggestion]) -> Vec<String> {
        suggestions
            .iter()
            .map(|suggestion| match suggestion {
                MentionSuggestion::Member(member) => member.name.clone(),
                MentionSuggestion::Room => ROOM.to_owned(),
            })
            .collect()
    }

    #[test]
    fn a_pill_sends_the_name_in_the_body_a_link_in_the_html_and_the_user_in_m_mentions() {
        let composed = ComposedText {
            text: "hi Anna and Petr, **look**".to_owned(),
            mentions: vec![
                pill(user("@anna:example.org"), 3..7),
                pill(user("@petr:example.org"), 12..16),
            ],
        };
        let outgoing = composed.outgoing();
        assert_eq!(outgoing.body, "hi Anna and Petr, **look**");
        assert_eq!(
            outgoing.markdown,
            "hi [Anna](<https://matrix.to/#/@anna:example.org>) and [Petr](<https://matrix.to/#/@petr:example.org>), **look**"
        );
        assert_eq!(
            outgoing.users,
            [UserId::from("@anna:example.org"), UserId::from("@petr:example.org")]
        );
        assert!(!outgoing.room);
    }

    #[test]
    fn a_name_with_marks_and_wide_characters_is_escaped_and_counted_in_utf16() {
        // 👋 is two UTF-16 units.
        let composed = ComposedText {
            text: "👋 *Ája_[x]* hey".to_owned(),
            mentions: vec![pill(user("@aja:example.org"), 3..12)],
        };
        let outgoing = composed.outgoing();
        assert_eq!(outgoing.body, "👋 *Ája_[x]* hey");
        assert_eq!(
            outgoing.markdown,
            "👋 [\\*Ája\\_\\[x\\]\\*](<https://matrix.to/#/@aja:example.org>) hey"
        );
    }

    #[test]
    fn room_mentions_the_room_and_a_member_mentioned_twice_is_listed_once() {
        let composed = ComposedText {
            text: "@room Anna Anna".to_owned(),
            mentions: vec![
                pill(MentionTarget::Room, 0..5),
                pill(user("@anna:a.b"), 6..10),
                pill(user("@anna:a.b"), 11..15),
            ],
        };
        let outgoing = composed.outgoing();
        assert!(outgoing.room);
        assert_eq!(outgoing.users, [UserId::from("@anna:a.b")]);
        assert!(outgoing.markdown.starts_with("@room [Anna]"));
    }

    #[test]
    fn a_pill_out_of_the_text_inside_a_character_or_over_another_is_left_out() {
        let composed = ComposedText {
            text: "👋 Anna".to_owned(),
            mentions: vec![
                pill(user("@a:a.b"), 1..3),
                pill(user("@b:a.b"), 3..20),
                pill(user("@c:a.b"), 3..7),
                pill(user("@d:a.b"), 4..6),
                pill(user("not an id"), 0..2),
            ],
        };
        let outgoing = composed.outgoing();
        assert_eq!(outgoing.users, [UserId::from("@c:a.b")]);
        assert_eq!(outgoing.markdown, "👋 [Anna](<https://matrix.to/#/@c:a.b>)");
    }

    #[test]
    fn a_text_without_pills_sends_as_written_and_mentions_nobody() {
        let outgoing = ComposedText::from("plain **text**").outgoing();
        assert_eq!(outgoing.markdown, "plain **text**");
        assert!(outgoing.users.is_empty() && !outgoing.room);
    }

    #[test]
    fn a_draft_keeps_its_pills() {
        let composed = ComposedText {
            text: "👋 *Ája* and Petr: **see**".to_owned(),
            mentions: vec![
                pill(user("@aja:example.org"), 3..8),
                pill(user("@petr:example.org"), 13..17),
            ],
        };
        let draft = composed.draft_text();
        assert_eq!(ComposedText::from_draft(&draft), composed);
        // other links stay as they were written.
        let other = "[a page](https://example.org) and [a room](https://matrix.to/#/!r:a.b)";
        assert_eq!(ComposedText::from_draft(other), ComposedText::from(other));
    }

    #[test]
    fn a_trimmed_text_keeps_its_pills_in_place() {
        let composed = ComposedText {
            text: "  hi Anna \n".to_owned(),
            mentions: vec![pill(user("@anna:a.b"), 5..9)],
        };
        assert_eq!(
            composed.trimmed(),
            ComposedText {
                text: "hi Anna".to_owned(),
                mentions: vec![pill(user("@anna:a.b"), 3..7)],
            }
        );
    }

    #[test]
    fn a_pill_whose_name_ends_in_white_space_is_kept_where_the_text_ends() {
        let composed = ComposedText {
            text: "hi Anna ".to_owned(),
            mentions: vec![pill(user("@anna:a.b"), 3..8)],
        };
        assert_eq!(composed.trimmed().mentions, [pill(user("@anna:a.b"), 3..7)]);
    }

    #[test]
    fn the_word_after_an_at_is_a_mention_being_typed() {
        assert_eq!(
            mention_query("hi @an", 6),
            Some(MentionQuery {
                range: 3..6,
                text: "an".to_owned()
            })
        );
        assert_eq!(
            mention_query("@", 1),
            Some(MentionQuery {
                range: 0..1,
                text: String::new()
            })
        );
        // a user id's server too.
        assert_eq!(
            mention_query("(@anna:mat", 10).map(|query| query.text),
            Some("anna:mat".to_owned())
        );
        // UTF-16 offsets, after wide characters.
        assert_eq!(mention_query("👋 @ž", 5).map(|query| query.range), Some(3..5));
        // the cursor before the word's end: only what is before it.
        assert_eq!(mention_query("@anna", 3).map(|query| query.text), Some("an".to_owned()));
        // an e-mail address, a space after the word, inside a character: none.
        assert_eq!(mention_query("me@example.org", 14), None);
        assert_eq!(mention_query("@anna ", 6), None);
        assert_eq!(mention_query("👋@", 1), None);
        assert_eq!(mention_query("no at", 5), None);
    }

    #[test]
    fn members_are_offered_best_match_first() {
        let members = vec![
            member("Zuzana Annová", "@zuzana:a.b"),
            member("Anna Nováková", "@anna:a.b"),
            member("Petr", "@discord_123:a.b"),
            member("Johanna", "@johanna:a.b"),
            member("Ondřej", "@ondra:a.b"),
            Member {
                is_own: true,
                ..member("Me Anna", "@me:a.b")
            },
        ];
        // a name's start, then a word's, then within; never the account.
        assert_eq!(
            names(&mention_suggestions(&members, "ann", 10)),
            ["Anna Nováková", "Zuzana Annová", "Johanna"]
        );
        // by the user id: its local part, a bridged ghost's too.
        assert_eq!(names(&mention_suggestions(&members, "@discord", 10)), ["Petr"]);
        // without accents, and letters in order.
        assert_eq!(names(&mention_suggestions(&members, "ondr", 10)), ["Ondřej"]);
        assert_eq!(names(&mention_suggestions(&members, "zna", 10)), ["Zuzana Annová"]);
        // everyone for no word, by name, at most `limit`.
        assert_eq!(
            names(&mention_suggestions(&members, "", 3)),
            ["Anna Nováková", "Johanna", "Ondřej"]
        );
        assert!(mention_suggestions(&members, "xyz", 10).is_empty());
    }

    #[test]
    fn room_is_offered_only_where_the_account_may_notify_the_room() {
        let mut members = vec![
            member("Radek", "@radek:a.b"),
            Member {
                is_own: true,
                ..member("Me", "@me:a.b")
            },
        ];
        assert_eq!(names(&mention_suggestions(&members, "r", 10)), ["Radek"]);
        if let Some(own) = members.last_mut() {
            own.may_mention_room = true;
        }
        assert_eq!(names(&mention_suggestions(&members, "r", 10)), ["Radek", ROOM]);
        assert_eq!(names(&mention_suggestions(&members, "roo", 10)), [ROOM]);
        assert_eq!(names(&mention_suggestions(&members, "", 10)), ["Radek", ROOM]);
    }

    #[test]
    fn a_member_link_names_its_user() {
        assert_eq!(
            mentioned_user("https://matrix.to/#/@anna:example.org"),
            Some(UserId::from("@anna:example.org"))
        );
        assert_eq!(
            mentioned_user("https://matrix.to/#/%40discord_1%3Aexample.org"),
            Some(UserId::from("@discord_1:example.org"))
        );
        assert_eq!(
            mentioned_user("matrix:u/anna:example.org"),
            Some(UserId::from("@anna:example.org"))
        );
        assert_eq!(mentioned_user("https://matrix.to/#/!room:example.org"), None);
        assert_eq!(mentioned_user("https://example.org"), None);
    }

    fn style(kind: StyleKind, range: Range<usize>) -> TextStyle {
        TextStyle { kind, range }
    }

    #[test]
    fn a_pill_shows_the_members_name_now_and_the_runs_move_with_it() {
        let text = "hi anna, see 👋 bob!".to_owned();
        let styles = vec![
            style(StyleKind::Bold, 0..8),
            style(StyleKind::Mention(user("@anna:a.b")), 3..7),
            style(StyleKind::Mention(user("@bob:a.b")), 16..19),
            style(StyleKind::Italic, 13..20),
        ];
        let (text, styles) = named_pills(text, styles, |user| match user.as_str() {
            "@anna:a.b" => Some("Anna Nováková".to_owned()),
            "@bob:a.b" => Some("Bo".to_owned()),
            _ => None,
        });
        assert_eq!(text, "hi Anna Nováková, see 👋 Bo!");
        assert_eq!(
            styles,
            [
                style(StyleKind::Bold, 0..17),
                style(StyleKind::Mention(user("@anna:a.b")), 3..16),
                style(StyleKind::Mention(user("@bob:a.b")), 25..27),
                style(StyleKind::Italic, 22..28),
            ]
        );
        // nobody known: as it came.
        let (same, _) = named_pills(
            "hi anna".to_owned(),
            vec![style(StyleKind::Mention(user("@x:a.b")), 3..7)],
            |_| None,
        );
        assert_eq!(same, "hi anna");
    }

    #[test]
    fn room_written_in_a_message_that_mentions_the_room_is_a_pill() {
        let text = "@room look, not `@room` nor @roomy";
        let styles = room_pills(text, vec![style(StyleKind::Code, 16..23)]);
        assert_eq!(
            styles,
            [
                style(StyleKind::Mention(MentionTarget::Room), 0..5),
                style(StyleKind::Code, 16..23)
            ]
        );
    }
}
