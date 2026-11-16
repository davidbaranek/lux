//! A chat's messages as the timeline shows them: runs of one sender, the day and pause
//! separators, photos sent together folded into albums, the links in each text, and what shows
//! under a message that is not plain.
//!
//! The core decides; the apps format. Nothing here is user-facing text: separators carry no
//! date strings, a footer is a state, and the apps localize both.

use std::borrow::Borrow;
use std::num::NonZeroU32;
use std::ops::Range;
use std::time::{Duration, SystemTime};

use jiff::Timestamp;
use jiff::civil::Date;
use jiff::tz::TimeZone;
use linkify::{LinkFinder, LinkKind};

use crate::ids::{MessageId, RoomId, UserId};
use crate::timeline::{StyleKind, TextStyle};

/// Messages of one sender this close together form a run: one name above, one tail below.
pub const RUN_GAP: Duration = Duration::from_mins(5);
/// Messages this far apart get the time between them, as Messages shows it.
pub const PAUSE: Duration = Duration::from_hours(2);
/// Pictures sent within this of the album's first fold into it.
pub const ALBUM_GAP: Duration = Duration::from_secs(60);
/// The most pictures an album holds.
pub const ALBUM_LIMIT: u32 = 9;

/// Where a message is on its way to the server.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum SendState {
    /// Not yet sent; an upload says how much has gone, 0 to 1.
    Sending {
        /// How much of the upload has gone, 0 to 1; `None` for a message with nothing to upload.
        upload: Option<f64>,
    },
    /// The server has it.
    Sent,
    /// Sending failed.
    Failed,
}

impl SendState {
    /// Whether two states are the same stage, whatever an upload's progress.
    fn is_same_stage(self, other: Self) -> bool {
        std::mem::discriminant(&self) == std::mem::discriminant(&other)
    }
}

/// What a message shows besides its text.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Attachment {
    /// A photo, or a video's poster: as many as it already holds (an album folded before).
    Pictures(NonZeroU32),
    /// A file or a sound, drawn as a row with its name.
    File,
}

/// A web address in a message's text.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Link {
    /// Where it is in the text, in UTF-16 code units, as the apps' text views count.
    pub range: Range<usize>,
    /// Where it leads.
    pub url: String,
}

/// One message, with what the timeline's presentation needs of it.
#[derive(Clone, Debug, PartialEq)]
pub struct Message {
    /// Its id.
    pub id: MessageId,
    /// Who sent it.
    pub sender: UserId,
    /// The room it is in: one of a merged chat's; `None` when not known.
    pub room: Option<RoomId>,
    /// When it was sent.
    pub date: SystemTime,
    /// Where it is on its way.
    pub state: SendState,
    /// It was edited.
    pub is_edited: bool,
    /// Its text: a caption, or empty.
    pub body: String,
    /// What it shows besides its text.
    pub attachment: Option<Attachment>,
    /// It answers another message (and quotes it).
    pub is_reply: bool,
    /// Someone reacted to it.
    pub has_reactions: bool,
    /// The web addresses in its text, found once when the message is read ([`links`]).
    pub links: Vec<Link>,
}

impl Message {
    /// Only pictures: no words, no quote, no file. Drawn without a bubble round it.
    #[must_use]
    pub fn is_media_only(&self) -> bool {
        matches!(self.attachment, Some(Attachment::Pictures(_))) && self.body.is_empty() && !self.is_reply
    }

    fn pictures(&self) -> u32 {
        match self.attachment {
            Some(Attachment::Pictures(count)) => count.get(),
            _ => 0,
        }
    }

    /// Whether `next` folds into this message's album: pictures alone from the same sender, in
    /// the same room and state, within a minute, with room left. This one may carry a caption.
    fn takes_into_album(&self, pictures: u32, next: &Self) -> bool {
        next.is_media_only()
            && !next.has_reactions
            && pictures > 0
            && !self.is_reply
            && !self.has_reactions
            && self.sender == next.sender
            && self.room == next.room
            && self.state.is_same_stage(next.state)
            && signed_gap(self.date, next.date).is_none_or(|gap| gap < ALBUM_GAP)
            && pictures + next.pictures() <= ALBUM_LIMIT
    }

    /// What shows under it when it is not plain; `None` for a sent message never edited.
    #[must_use]
    pub fn footer(&self) -> Option<Footer> {
        let status = match self.state {
            SendState::Sending { upload: Some(progress) } => Some(Status::Uploading(progress)),
            SendState::Sending { upload: None } => Some(Status::Sending),
            SendState::Failed => Some(Status::Failed),
            SendState::Sent => None,
        };
        (self.is_edited || status.is_some()).then_some(Footer {
            is_edited: self.is_edited,
            status,
        })
    }
}

/// How far a message being sent has got, as its footer says.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Status {
    /// On its way.
    Sending,
    /// Its upload has gone this far, 0 to 1.
    Uploading(f64),
    /// It did not go.
    Failed,
}

/// What shows under a message that is not plain ("Edited · Sending…").
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Footer {
    /// It was edited.
    pub is_edited: bool,
    /// It is not sent yet, or failed.
    pub status: Option<Status>,
}

/// What separates a message from the one before it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Separator {
    /// The first message of a day: the day shows above it.
    Day,
    /// Two hours or more after the one before, the same day: the time shows above it.
    Pause,
}

/// One row of the timeline: a message, or an album of several.
#[derive(Clone, Debug, PartialEq)]
pub struct Row {
    /// The message it shows, a position in the messages given.
    pub message: usize,
    /// An album's messages, this one first, as positions in the messages given; empty for
    /// anything else.
    pub album: Vec<usize>,
    /// The first of a run of one sender's messages: it shows the sender's name in a group.
    pub starts_run: bool,
    /// The last of the run: its bubble gets the tail and some space after.
    pub ends_run: bool,
    /// What shows above it.
    pub separator: Option<Separator>,
    /// The web addresses in its text: its formatted links, then those written as text.
    pub links: Vec<Link>,
    /// What shows under it.
    pub footer: Option<Footer>,
}

/// The timeline's rows for `messages`, oldest first, with days in `zone`: albums folded, runs
/// marked, separators set, links found. Takes the messages as they are held (`Message`s, or
/// what carries one).
#[must_use]
pub fn present<M: Borrow<Message>>(messages: &[M], zone: &TimeZone) -> Vec<Row> {
    let folded: Vec<Folded<'_>> = fold_albums(messages)
        .into_iter()
        .map(|(lead, message, album)| Folded {
            lead,
            message,
            album,
            day: local_day(message.date, zone),
        })
        .collect();
    let together = |first: &Folded<'_>, second: &Folded<'_>| {
        first.message.sender == second.message.sender
            && first.day == second.day
            && signed_gap(first.message.date, second.message.date).is_none_or(|gap| gap < RUN_GAP)
    };
    folded
        .iter()
        .enumerate()
        .map(|(index, row)| {
            let previous = index.checked_sub(1).and_then(|previous| folded.get(previous));
            let next = index.checked_add(1).and_then(|next| folded.get(next));
            let separator = match previous {
                None => Some(Separator::Day),
                Some(previous) if previous.day != row.day => Some(Separator::Day),
                Some(previous) => signed_gap(previous.message.date, row.message.date)
                    .is_some_and(|gap| gap >= PAUSE)
                    .then_some(Separator::Pause),
            };
            Row {
                message: row.lead,
                album: row.album.clone(),
                starts_run: previous.is_none_or(|previous| !together(previous, row)),
                ends_run: next.is_none_or(|next| !together(row, next)),
                separator,
                links: row.message.links.clone(),
                footer: row.message.footer(),
            }
        })
        .collect()
}

/// A row being presented: its lead message, where it is, its album and its local day.
struct Folded<'a> {
    lead: usize,
    message: &'a Message,
    album: Vec<usize>,
    day: Date,
}

/// Each row's lead message (its position and itself) and, for an album, all of its messages
/// (the lead first).
fn fold_albums<M: Borrow<Message>>(messages: &[M]) -> Vec<(usize, &Message, Vec<usize>)> {
    let mut rows: Vec<(usize, &Message, Vec<usize>, u32)> = Vec::with_capacity(messages.len());
    for (index, message) in messages.iter().map(Borrow::borrow).enumerate() {
        if let Some((lead_index, lead, album, pictures)) = rows.last_mut()
            && lead.takes_into_album(*pictures, message)
        {
            if album.is_empty() {
                album.push(*lead_index);
            }
            album.push(index);
            *pictures = pictures.saturating_add(message.pictures());
            continue;
        }
        rows.push((index, message, Vec::new(), message.pictures()));
    }
    rows.into_iter()
        .map(|(index, lead, album, _)| (index, lead, album))
        .collect()
}

/// How long after `earlier` `later` came; `None` when it came before.
fn signed_gap(earlier: SystemTime, later: SystemTime) -> Option<Duration> {
    later.duration_since(earlier).ok()
}

fn local_day(date: SystemTime, zone: &TimeZone) -> Date {
    // a date beyond jiff's range (years past 9999) counts as its far end's day.
    let timestamp = Timestamp::try_from(date).unwrap_or(Timestamp::MAX);
    zone.to_datetime(timestamp).date()
}

/// The web addresses in a message's `text`: those its `styles` link, then those written as
/// text that overlap none of them. The adapters find them once, when they read the message.
#[must_use]
pub fn links(text: &str, styles: &[TextStyle]) -> Vec<Link> {
    let mut links: Vec<Link> = styles
        .iter()
        .filter_map(|style| match &style.kind {
            StyleKind::Link(url) => Some(Link {
                range: style.range.clone(),
                url: url.clone(),
            }),
            _ => None,
        })
        .collect();
    let formatted = links.len();
    // most messages have no address: skip the finder for them.
    if !text.contains('.') {
        return links;
    }
    let mut counted = (0, 0); // (bytes, UTF-16 units) of the text before the last link.
    let mut utf16 = |byte: usize| {
        counted.1 += text.get(counted.0..byte).map_or(0, |part| part.encode_utf16().count());
        counted.0 = byte;
        counted.1
    };
    let mut finder = LinkFinder::new();
    finder.url_must_have_scheme(false);
    finder.kinds(&[LinkKind::Url, LinkKind::Email]);
    for found in finder.links(text) {
        let range = utf16(found.start())..utf16(found.end());
        if links
            .iter()
            .take(formatted)
            .any(|link| link.range.start < range.end && range.start < link.range.end)
        {
            continue;
        }
        let address = found.as_str();
        let url = match found.kind() {
            LinkKind::Email => format!("mailto:{address}"),
            _ if address.contains("://") => address.to_owned(),
            _ => format!("https://{address}"),
        };
        links.push(Link { range, url });
    }
    links
}

#[cfg(test)]
mod tests {
    use super::*;

    fn at(seconds: u64) -> SystemTime {
        SystemTime::UNIX_EPOCH + Duration::from_secs(seconds)
    }

    fn message(id: &str, sender: &str, seconds: u64) -> Message {
        Message {
            id: id.into(),
            sender: sender.into(),
            room: Some("!r".into()),
            date: at(seconds),
            state: SendState::Sent,
            is_edited: false,
            body: id.to_owned(),
            attachment: None,
            is_reply: false,
            has_reactions: false,
            links: Vec::new(),
        }
    }

    /// `message` with `body` and the links in it.
    fn saying(mut message: Message, body: &str, styles: &[TextStyle]) -> Message {
        body.clone_into(&mut message.body);
        message.links = links(body, styles);
        message
    }

    fn photo(id: &str, sender: &str, seconds: u64, body: &str) -> Message {
        Message {
            body: body.to_owned(),
            attachment: NonZeroU32::new(1).map(Attachment::Pictures),
            ..message(id, sender, seconds)
        }
    }

    fn present_utc(messages: &[Message]) -> Vec<Row> {
        present(messages, &TimeZone::UTC)
    }

    #[test]
    fn runs_of_one_sender_group_within_five_minutes() {
        let rows = present_utc(&[
            message("a", "x", 0),
            message("b", "x", 60),
            message("c", "y", 70),
            message("d", "y", 70 + 301),
        ]);
        assert_eq!(
            rows.iter().map(|row| row.starts_run).collect::<Vec<_>>(),
            [true, false, true, true]
        );
        assert_eq!(
            rows.iter().map(|row| row.ends_run).collect::<Vec<_>>(),
            [false, true, true, true]
        );
    }

    #[test]
    fn a_new_day_starts_with_a_separator_and_breaks_the_run() {
        let day = 86_400;
        let rows = present_utc(&[message("a", "x", 10 * day), message("b", "x", 11 * day)]);
        assert_eq!(rows[0].separator, Some(Separator::Day));
        assert_eq!(rows[1].separator, Some(Separator::Day));
        assert!(rows[1].starts_run);
    }

    #[test]
    fn days_follow_the_local_calendar() {
        // 23:30 and 00:30 the next day in Prague (UTC+1 in winter), but the same day in UTC.
        let late = 1_800_000_000 - 1_800_000_000 % 86_400 + 22 * 3_600 + 1_800;
        let messages = [message("a", "x", late), message("b", "x", late + 3_600)];
        assert_eq!(present_utc(&messages)[1].separator, None);
        let prague = TimeZone::get("Europe/Prague").unwrap_or(TimeZone::fixed(jiff::tz::offset(1)));
        assert_eq!(present(&messages, &prague)[1].separator, Some(Separator::Day));
    }

    #[test]
    fn a_pause_of_two_hours_shows_the_time() {
        let start = 1_800_000_000 - 1_800_000_000 % 86_400;
        let rows = present_utc(&[0, 60, 3_600, 3 * 3_600].map(|seconds| message("m", "@a", start + seconds)));
        assert_eq!(
            rows.iter().map(|row| row.separator).collect::<Vec<_>>(),
            [Some(Separator::Day), None, None, Some(Separator::Pause)]
        );
    }

    #[test]
    fn photos_sent_together_fold_into_one_album() {
        let rows = present_utc(&[
            photo("a", "@anna", 0, ""),
            photo("b", "@anna", 5, ""),
            photo("c", "@anna", 20, ""),
        ]);
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].album, [0, 1, 2]);
    }

    #[test]
    fn the_first_may_carry_the_caption() {
        let rows = present_utc(&[photo("a", "@anna", 0, "Trip"), photo("b", "@anna", 2, "")]);
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].album, [0, 1]);
    }

    #[test]
    fn a_later_caption_another_sender_or_a_long_pause_starts_anew() {
        let rows = present_utc(&[
            photo("a", "@anna", 0, ""),
            photo("b", "@anna", 5, "look"),
            photo("d", "@petr", 7, ""),
            photo("e", "@petr", 200, ""),
        ]);
        assert_eq!(rows.iter().map(|row| row.message).collect::<Vec<_>>(), [0, 1, 2, 3]);
        assert!(rows.iter().all(|row| row.album.is_empty()));
    }

    #[test]
    fn reactions_replies_rooms_and_states_keep_pictures_apart() {
        let reacted = Message {
            has_reactions: true,
            ..photo("b", "@anna", 1, "")
        };
        let reply = Message {
            is_reply: true,
            ..photo("a", "@anna", 0, "")
        };
        let elsewhere = Message {
            room: Some("!other".into()),
            ..photo("b", "@anna", 1, "")
        };
        let failed = Message {
            state: SendState::Failed,
            ..photo("b", "@anna", 1, "")
        };
        for pair in [
            [photo("a", "@anna", 0, ""), reacted],
            [reply, photo("b", "@anna", 1, "")],
            [photo("a", "@anna", 0, ""), elsewhere],
            [photo("a", "@anna", 0, ""), failed],
        ] {
            assert_eq!(present_utc(&pair).len(), 2);
        }
        // an upload's progress is the same stage.
        let uploading = |upload| Message {
            state: SendState::Sending { upload: Some(upload) },
            ..photo("a", "@anna", 0, "")
        };
        assert_eq!(present_utc(&[uploading(0.2), uploading(0.7)]).len(), 1);
    }

    #[test]
    fn an_album_holds_at_most_nine_and_counts_albums_folded_before() {
        let ten: Vec<Message> = (0..10).map(|second| photo("p", "@anna", second, "")).collect();
        let rows = present_utc(&ten);
        assert_eq!(rows.iter().map(|row| row.album.len()).collect::<Vec<_>>(), [9, 0]);
        // a merged chat presents its rooms' rows again: an album of eight takes one more only.
        let eight = Message {
            attachment: NonZeroU32::new(8).map(Attachment::Pictures),
            ..photo("a", "@anna", 0, "")
        };
        let rows = present_utc(&[eight, photo("b", "@anna", 1, ""), photo("c", "@anna", 2, "")]);
        assert_eq!(
            rows.iter().map(|row| row.album.clone()).collect::<Vec<_>>(),
            [vec![0, 1], vec![]]
        );
    }

    #[test]
    fn links_are_found_in_utf16_offsets() {
        let item = saying(message("m", "x", 0), "see https://example.org now", &[]);
        let rows = present_utc(&[item]);
        assert_eq!(
            rows[0].links,
            [Link {
                range: 4..23,
                url: "https://example.org".to_owned()
            }]
        );
        let emoji = saying(message("m", "x", 0), "👍🏽 example.com or anna@example.org", &[]);
        let links = &present_utc(&[emoji])[0].links;
        assert_eq!(links[0].range, 5..16);
        assert_eq!(links[0].url, "https://example.com");
        assert_eq!(links[1].url, "mailto:anna@example.org");
    }

    #[test]
    fn formatted_links_come_first_and_hide_what_they_cover() {
        let styles = [
            TextStyle {
                kind: StyleKind::Link("https://example.org/a".to_owned()),
                range: 4..8,
            },
            TextStyle {
                kind: StyleKind::Bold,
                range: 0..3,
            },
            TextStyle {
                kind: StyleKind::Link("https://example.org/b".to_owned()),
                range: 28..39,
            },
        ];
        let item = saying(message("m", "x", 0), "see this or example.com and example.org", &styles);
        let urls: Vec<String> = present_utc(&[item])[0]
            .links
            .iter()
            .map(|link| link.url.clone())
            .collect();
        assert_eq!(
            urls,
            ["https://example.org/a", "https://example.org/b", "https://example.com"]
        );
    }

    #[test]
    fn only_what_is_not_plain_shows_under_the_text() {
        let mut item = message("m", "me", 0);
        assert_eq!(item.footer(), None);
        item.is_edited = true;
        item.state = SendState::Sending { upload: None };
        assert_eq!(
            item.footer(),
            Some(Footer {
                is_edited: true,
                status: Some(Status::Sending)
            })
        );
        item.is_edited = false;
        item.state = SendState::Sending { upload: Some(0.4) };
        assert_eq!(
            item.footer().and_then(|footer| footer.status),
            Some(Status::Uploading(0.4))
        );
    }
}
