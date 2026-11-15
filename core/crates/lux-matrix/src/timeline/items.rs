//! The SDK's timeline items as the core's messages: a message, a sticker, a poll's question, a
//! deleted or undecryptable message. Day dividers, state events and the like map to nothing.

use std::collections::{HashMap, HashSet};
use std::num::NonZeroU32;
use std::sync::Arc;

use lux_core::ids::{EventId, MediaId, MessageId, RoomId, UserId};
use lux_core::message::{self, Attachment, Message, SendState};
use lux_core::preview::{PreviewKind, PreviewSource as QuotedKind};
use lux_core::timeline::{
    FileKind, Media, MessageKind, Picture, Quote, Reaction, Reader, SharedPost, TextStyle, TimelineMessage, html,
};
use matrix_sdk::Room;
use matrix_sdk::ruma::events::AnySyncTimelineEvent;
use matrix_sdk::ruma::events::room::MediaSource;
use matrix_sdk::ruma::events::room::message::{FormattedBody, MessageFormat, MessageType};
use matrix_sdk::ruma::serde::Raw;
use matrix_sdk::ruma::{MilliSecondsSinceUnixEpoch, OwnedEventId, OwnedUserId, UInt};
use matrix_sdk_ui::timeline::{
    EventSendState, EventTimelineItem, InReplyToDetails, MsgLikeContent, MsgLikeKind, Profile, TimelineDetails,
    TimelineItem, TimelineItemContent,
};

use super::previews::{LinkPreview, LinkPreviews};
use crate::convert::{member_name, system_time};

/// Maps one room's items. Owned by the room's timeline task: it remembers the names of the
/// people it met, and the replies whose quoted message it asked the SDK for.
pub(crate) struct ItemMapper {
    room: Room,
    /// What shared posts' addresses say about them.
    previews: LinkPreviews,
    room_id: RoomId,
    own: OwnedUserId,
    names: HashMap<OwnedUserId, String>,
    asked: HashSet<OwnedEventId>,
}

/// A message, and the event whose quoted message is still to fetch.
pub(crate) struct Mapped {
    pub(crate) message: Option<Arc<TimelineMessage>>,
    pub(crate) fetch_quote_of: Option<OwnedEventId>,
}

impl ItemMapper {
    pub(crate) fn new(room: Room, previews: LinkPreviews) -> Self {
        let own = room.own_user_id().to_owned();
        let room_id = RoomId::from(room.room_id().as_str());
        Self {
            room,
            previews,
            room_id,
            own,
            names: HashMap::new(),
            asked: HashSet::new(),
        }
    }

    /// The message an item shows, if it is one.
    pub(crate) async fn map(&mut self, item: &TimelineItem) -> Mapped {
        let Some(event) = item.as_event() else {
            return Mapped {
                message: None,
                fetch_quote_of: None,
            };
        };
        let TimelineItemContent::MsgLike(content) = event.content() else {
            return Mapped {
                message: None,
                fetch_quote_of: None,
            };
        };
        let Some(mut shown) = Shown::of(content) else {
            return Mapped {
                message: None,
                fetch_quote_of: None,
            };
        };
        let shared = event.original_json().and_then(BridgedPost::of).map(|post| {
            let previews = &self.previews;
            let url = post.url.clone();
            post.shared(&mut shown, || previews.get(&url))
        });
        let sender_name = self.sender_name(event);
        let mut fetch_quote_of = None;
        let reply = content.in_reply_to.as_ref().map(|details| {
            if matches!(details.event, TimelineDetails::Unavailable)
                && let Some(event_id) = event.event_id()
                && self.asked.insert(event_id.to_owned())
            {
                fetch_quote_of = Some(event_id.to_owned());
            }
            quote(details)
        });
        let readers = self.readers(event).await;
        let reactions: Vec<Reaction> = event
            .reactions()
            .iter()
            .map(|(key, senders)| Reaction {
                key: key.clone(),
                count: u32::try_from(senders.len()).unwrap_or(u32::MAX),
                is_mine: senders.contains_key(&self.own),
            })
            .collect();
        let links = message::links(&shown.body, &shown.styles);
        let message = TimelineMessage {
            message: Message {
                id: MessageId::from(item.unique_id().0.as_str()),
                sender: UserId::from(event.sender().as_str()),
                room: Some(self.room_id.clone()),
                date: system_time(event.timestamp()),
                state: send_state(event),
                is_edited: content.as_message().is_some_and(|message| message.is_edited()),
                body: shown.body,
                attachment: shown.media.as_ref().and_then(attachment),
                is_reply: reply.is_some(),
                has_reactions: !reactions.is_empty(),
                links,
            },
            event_id: event.event_id().map(|id| EventId::from(id.as_str())),
            sender_name,
            sender_avatar: match event.sender_profile() {
                TimelineDetails::Ready(profile) => profile.avatar_url.as_ref().map(|url| MediaId::from(url.as_str())),
                _ => None,
            },
            is_own: event.is_own(),
            is_editable: event.is_editable(),
            kind: shown.kind,
            media: shown.media,
            styles: shown.styles,
            reactions,
            reply,
            readers,
            shared,
        };
        Mapped {
            message: Some(Arc::new(message)),
            fetch_quote_of,
        }
    }

    fn sender_name(&mut self, event: &EventTimelineItem) -> String {
        let name = profile_name(event.sender_profile(), event.sender().localpart());
        if let TimelineDetails::Ready(_) = event.sender_profile() {
            self.names.insert(event.sender().to_owned(), name.clone());
        }
        name
    }

    /// Who read up to the item, but its sender and the account, the earliest first.
    async fn readers(&mut self, event: &EventTimelineItem) -> Vec<Reader> {
        let mut receipts: Vec<(&OwnedUserId, Option<MilliSecondsSinceUnixEpoch>)> = event
            .read_receipts()
            .iter()
            .filter(|(user, _)| **user != self.own && *user != event.sender())
            .map(|(user, receipt)| (user, receipt.ts))
            .collect();
        receipts.sort_by_key(|(_, ts)| *ts);
        let mut readers = Vec::with_capacity(receipts.len());
        for (user, _) in receipts {
            let name = self.name_of(user).await;
            readers.push(Reader {
                user: UserId::from(user.as_str()),
                name,
            });
        }
        readers
    }

    /// A member's name, from the people met or the room's members.
    async fn name_of(&mut self, user: &OwnedUserId) -> String {
        if let Some(name) = self.names.get(user) {
            return name.clone();
        }
        let name = member_name(&self.room, user).await;
        self.names.insert(user.clone(), name.clone());
        name
    }
}

/// What a message-like item shows.
pub(super) struct Shown {
    kind: MessageKind,
    pub(super) body: String,
    pub(super) media: Option<Media>,
    pub(super) styles: Vec<TextStyle>,
}

impl Shown {
    fn of(content: &MsgLikeContent) -> Option<Self> {
        let plain = |kind| Self {
            kind,
            body: String::new(),
            media: None,
            styles: Vec::new(),
        };
        match &content.kind {
            MsgLikeKind::Message(message) => Some(message_shown(message.msgtype())),
            MsgLikeKind::Sticker(sticker) => {
                let content = sticker.content();
                let info = &content.info;
                Some(Self {
                    kind: MessageKind::Message,
                    body: String::new(),
                    media: Some(Media::Photo {
                        picture: Picture {
                            source: media_key(&content.source.clone().into()),
                            width: pixels(info.width),
                            height: pixels(info.height),
                        },
                        is_animated: is_animated(info.mimetype.as_deref()),
                    }),
                    styles: Vec::new(),
                })
            }
            MsgLikeKind::Poll(poll) => Some(Self {
                body: poll.results().question,
                ..plain(MessageKind::Message)
            }),
            MsgLikeKind::Redacted => Some(plain(MessageKind::Deleted)),
            MsgLikeKind::UnableToDecrypt(_) => Some(plain(MessageKind::Undecryptable)),
            MsgLikeKind::Other(_) | MsgLikeKind::LiveLocation(_) => None,
        }
    }
}

/// A post shared from another network, as mautrix bridges send one: the media, its caption the
/// post's address (`external_url`), at times with the post's title and caption beside it
/// (`com.beeper.meta.full_post_title`, `com.beeper.meta.caption_body_text`).
struct BridgedPost {
    url: String,
    title: Option<String>,
    caption: Option<String>,
}

impl BridgedPost {
    fn of(event: &Raw<AnySyncTimelineEvent>) -> Option<Self> {
        let content = event.get_field::<serde_json::Value>("content").ok().flatten()?;
        let text = |key: &str| {
            content[key]
                .as_str()
                .map(str::trim)
                .filter(|text| !text.is_empty())
                .map(str::to_owned)
        };
        Some(Self {
            url: text("external_url")?,
            title: text("com.beeper.meta.full_post_title"),
            caption: text("com.beeper.meta.caption_body_text"),
        })
    }

    /// The post with its title and description (the bridge's, else the page's `preview`, none
    /// until the server has read it); the message's text loses the address it ends with (whole,
    /// or shortened as a link's text shows it), which the post's card stands for.
    fn shared(self, shown: &mut Shown, preview: impl FnOnce() -> Option<LinkPreview>) -> SharedPost {
        if let Some(own) = without_address(&shown.body, &self.url) {
            shown.body = own.to_owned();
            // the formatting was the address's link, which is gone.
            shown.styles.clear();
        }
        let (title, description) = if self.title.is_some() || self.caption.is_some() {
            (self.title, self.caption)
        } else {
            let preview = preview().unwrap_or_default();
            (preview.title, preview.description)
        };
        SharedPost {
            url: self.url,
            title,
            description,
        }
    }
}

/// `body` without the address of `url` it ends with: `url` itself, or a shorter form of it (the
/// address without its query, as a bridge's link text shows it); none when it ends otherwise.
fn without_address<'a>(body: &'a str, url: &str) -> Option<&'a str> {
    let body = body.trim_end();
    let last = body.rsplit(char::is_whitespace).next()?;
    let shortened = last.starts_with("http") && url.starts_with(last.trim_end_matches('/'));
    (last == url || shortened).then(|| body[..body.len() - last.len()].trim_end())
}

/// A message's text (its formatted body's when it has formatting), media and runs.
pub(super) fn message_shown(message: &MessageType) -> Shown {
    let (body, formatted, media) = match message {
        MessageType::Text(text) => (text.body.clone(), text.formatted.as_ref(), None),
        MessageType::Notice(notice) => (notice.body.clone(), notice.formatted.as_ref(), None),
        MessageType::Emote(emote) => (emote.body.clone(), emote.formatted.as_ref(), None),
        MessageType::Image(image) => {
            let info = image.info.as_deref();
            let picture = Picture {
                source: media_key(
                    info.and_then(|info| info.thumbnail_source.as_ref())
                        .unwrap_or(&image.source),
                ),
                width: pixels(info.and_then(|info| info.width)),
                height: pixels(info.and_then(|info| info.height)),
            };
            let is_animated = is_animated(info.and_then(|info| info.mimetype.as_deref()));
            (
                image.caption().unwrap_or_default().to_owned(),
                image.formatted_caption(),
                Some(Media::Photo { picture, is_animated }),
            )
        }
        MessageType::Video(video) => {
            let info = video.info.as_deref();
            let poster = info.and_then(|info| {
                info.thumbnail_source.as_ref().map(|source| Picture {
                    source: media_key(source),
                    width: pixels(info.width),
                    height: pixels(info.height),
                })
            });
            (
                video.caption().unwrap_or_default().to_owned(),
                video.formatted_caption(),
                Some(Media::Video {
                    poster,
                    duration: info.and_then(|info| info.duration),
                }),
            )
        }
        MessageType::Audio(audio) => {
            let info = audio.info.as_deref();
            (
                audio.caption().unwrap_or_default().to_owned(),
                audio.formatted_caption(),
                Some(Media::File {
                    name: audio.filename().to_owned(),
                    size: info.and_then(|info| info.size).map(u64::from),
                    mimetype: info.and_then(|info| info.mimetype.clone()).unwrap_or_default(),
                    kind: if audio.voice.is_some() {
                        FileKind::Voice
                    } else {
                        FileKind::Audio
                    },
                    duration: info.and_then(|info| info.duration),
                }),
            )
        }
        MessageType::File(file) => {
            let info = file.info.as_deref();
            (
                file.caption().unwrap_or_default().to_owned(),
                file.formatted_caption(),
                Some(Media::File {
                    name: file.filename().to_owned(),
                    size: info.and_then(|info| info.size).map(u64::from),
                    mimetype: info.and_then(|info| info.mimetype.clone()).unwrap_or_default(),
                    kind: FileKind::Document,
                    duration: None,
                }),
            )
        }
        other => (other.body().to_owned(), None, None),
    };
    let (body, styles) = formatted_text(body, formatted);
    Shown {
        kind: MessageKind::Message,
        body,
        media,
        styles,
    }
}

/// The text a formatted body shows and its runs; the plain body when it has no formatting.
fn formatted_text(body: String, formatted: Option<&FormattedBody>) -> (String, Vec<TextStyle>) {
    if let Some(formatted) = formatted
        && formatted.format == MessageFormat::Html
    {
        let (text, styles) = html::parse(&formatted.body);
        if !text.is_empty() && !styles.is_empty() {
            return (text, styles);
        }
    }
    (body, Vec::new())
}

/// What the presentation counts of a message's media.
fn attachment(media: &Media) -> Option<Attachment> {
    match media {
        Media::Photo { .. } | Media::Video { poster: Some(_), .. } => NonZeroU32::new(1).map(Attachment::Pictures),
        Media::Video { poster: None, .. } => None,
        Media::File { .. } => Some(Attachment::File),
    }
}

/// The quote of the message a reply answers; empty while it is not known.
fn quote(details: &InReplyToDetails) -> Quote {
    let (sender_name, kind) = match &details.event {
        TimelineDetails::Ready(event) => (
            profile_name(&event.sender_profile, event.sender.localpart()),
            Some(quoted_kind(&event.content)),
        ),
        _ => (String::new(), None),
    };
    Quote {
        event_id: EventId::from(details.event_id.as_str()),
        sender_name,
        kind,
    }
}

/// What an item's content is, as a quote shows it: its text in one line, or its kind.
pub(crate) fn quoted_kind(content: &TimelineItemContent) -> PreviewKind {
    let Some(content) = content.as_msglike() else {
        return PreviewKind::Other;
    };
    let kind = match &content.kind {
        MsgLikeKind::Message(message) => match message.msgtype() {
            MessageType::Image(_) => QuotedKind::Image,
            MessageType::Video(_) => QuotedKind::Video,
            MessageType::Audio(audio) if audio.voice.is_some() => QuotedKind::Voice,
            MessageType::Audio(_) => QuotedKind::Audio,
            MessageType::File(file) => QuotedKind::File(Some(file.filename())),
            MessageType::Location(_) => QuotedKind::Location,
            other => QuotedKind::Text(other.body()),
        },
        MsgLikeKind::Sticker(_) => QuotedKind::Sticker,
        MsgLikeKind::Redacted => QuotedKind::Deleted,
        MsgLikeKind::UnableToDecrypt(_) => QuotedKind::Encrypted,
        MsgLikeKind::Poll(_) | MsgLikeKind::Other(_) | MsgLikeKind::LiveLocation(_) => QuotedKind::Other,
    };
    PreviewKind::from(kind)
}

/// A name from a profile, or the user id's local part.
pub(crate) fn profile_name(profile: &TimelineDetails<Profile>, localpart: &str) -> String {
    match profile {
        TimelineDetails::Ready(Profile {
            display_name: Some(name),
            ..
        }) if !name.is_empty() => name.clone(),
        _ => localpart.to_owned(),
    }
}

/// Where an item is on its way to the server.
pub(crate) fn send_state(event: &EventTimelineItem) -> SendState {
    match event.send_state() {
        Some(EventSendState::NotSentYet { progress }) => SendState::Sending {
            upload: progress
                .as_ref()
                .map(|progress| fraction(progress.progress.current, progress.progress.total)),
        },
        Some(EventSendState::SendingFailed { .. }) => SendState::Failed,
        Some(EventSendState::Sent { .. }) | None => SendState::Sent,
    }
}

/// `current` of `total`, 0 to 1.
fn fraction(current: usize, total: usize) -> f64 {
    if total == 0 {
        return 0.0;
    }
    // progress counts bytes: far below f64's exact range.
    #[allow(clippy::cast_precision_loss)]
    let fraction = current as f64 / total as f64;
    fraction.clamp(0.0, 1.0)
}

/// The media's key: its URL, which the app's caches go by.
pub(crate) fn media_key(source: &MediaSource) -> MediaId {
    match source {
        MediaSource::Plain(url) => MediaId::from(url.as_str()),
        MediaSource::Encrypted(file) => MediaId::from(file.url.as_str()),
    }
}

fn pixels(value: Option<UInt>) -> u32 {
    value.and_then(|value| u32::try_from(value).ok()).unwrap_or(0)
}

fn is_animated(mimetype: Option<&str>) -> bool {
    mimetype == Some("image/gif")
}

/// The media an item's message carries, to load: its source, its thumbnail or poster, its name.
pub(crate) struct MediaOf {
    pub(crate) source: MediaSource,
    pub(crate) thumbnail: Option<MediaSource>,
    pub(crate) filename: String,
    pub(crate) mimetype: Option<String>,
}

/// The media of an item's message or sticker.
pub(crate) fn media_of(event: &EventTimelineItem) -> Option<MediaOf> {
    let content = event.content().as_msglike()?;
    match &content.kind {
        MsgLikeKind::Message(message) => message_media(message.msgtype()),
        MsgLikeKind::Sticker(sticker) => {
            let content = sticker.content();
            Some(MediaOf {
                source: content.source.clone().into(),
                thumbnail: None,
                filename: content.body.clone(),
                mimetype: content.info.mimetype.clone(),
            })
        }
        _ => None,
    }
}

/// The media a message carries: a photo's, a video's, a sound's or a file's.
pub(crate) fn message_media(message: &MessageType) -> Option<MediaOf> {
    match message {
        MessageType::Image(image) => {
            let info = image.info.as_deref();
            Some(MediaOf {
                source: image.source.clone(),
                thumbnail: info.and_then(|info| info.thumbnail_source.clone()),
                filename: image.filename().to_owned(),
                mimetype: info.and_then(|info| info.mimetype.clone()),
            })
        }
        MessageType::Video(video) => {
            let info = video.info.as_deref();
            Some(MediaOf {
                source: video.source.clone(),
                thumbnail: info.and_then(|info| info.thumbnail_source.clone()),
                filename: video.filename().to_owned(),
                mimetype: info.and_then(|info| info.mimetype.clone()),
            })
        }
        MessageType::Audio(audio) => Some(MediaOf {
            source: audio.source.clone(),
            thumbnail: None,
            filename: audio.filename().to_owned(),
            mimetype: audio.info.as_deref().and_then(|info| info.mimetype.clone()),
        }),
        MessageType::File(file) => {
            let info = file.info.as_deref();
            Some(MediaOf {
                source: file.source.clone(),
                thumbnail: info.and_then(|info| info.thumbnail_source.clone()),
                filename: file.filename().to_owned(),
                mimetype: info.and_then(|info| info.mimetype.clone()),
            })
        }
        _ => None,
    }
}

/// The text the search index keeps of a message's content; `None` for anything but text.
pub(crate) fn indexed_text(message: &MessageType) -> Option<&str> {
    match message {
        MessageType::Text(text) => Some(&text.body),
        MessageType::Notice(notice) => Some(&notice.body),
        MessageType::Emote(emote) => Some(&emote.body),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use matrix_sdk::ruma::events::room::message::{
        AudioInfo, AudioMessageEventContent, ImageMessageEventContent, TextMessageEventContent,
        UnstableVoiceContentBlock, VideoInfo, VideoMessageEventContent,
    };
    use matrix_sdk::ruma::{mxc_uri, owned_mxc_uri, uint};

    use super::*;

    #[test]
    fn a_formatted_text_shows_its_html_runs() {
        let shown = message_shown(&MessageType::Text(TextMessageEventContent::html(
            "**hi** there",
            "<b>hi</b> there",
        )));
        assert_eq!(shown.body, "hi there");
        assert_eq!(shown.styles[0].kind, lux_core::timeline::StyleKind::Bold);
        assert_eq!(shown.styles[0].range, 0..2);
        // html with no formatting keeps the plain body.
        let plain = message_shown(&MessageType::Text(TextMessageEventContent::html(
            "a\nb",
            "<p>a</p><p>b</p>",
        )));
        assert_eq!(plain.body, "a\nb");
        assert!(plain.styles.is_empty());
    }

    /// A reel shared from Instagram, as mautrix-meta sends it: the video, its caption a link to
    /// the post (its text the address without the query, as Markdown in the plain body), the
    /// whole address beside it, and the post's title and caption when the bridge knows them.
    fn shared_reel(title: Option<&str>, caption: Option<&str>) -> Raw<AnySyncTimelineEvent> {
        let (short, url) = (
            "https://www.instagram.com/reel/abc/",
            "https://www.instagram.com/reel/abc/?id=1&a=b",
        );
        let mut content = serde_json::json!({
            "msgtype": "m.video",
            "body": format!("[{short}]({url})"),
            "filename": "reel.mp4",
            "format": "org.matrix.custom.html",
            "formatted_body": format!("<p><a href=\"{url}\">{short}</a></p>"),
            "url": "mxc://a/reel",
            "external_url": url,
        });
        if let Some(title) = title {
            content["com.beeper.meta.full_post_title"] = title.into();
        }
        if let Some(caption) = caption {
            content["com.beeper.meta.caption_body_text"] = caption.into();
        }
        Raw::new(&serde_json::json!({
            "type": "m.room.message",
            "event_id": "$reel",
            "sender": "@meta_1:example.org",
            "origin_server_ts": 1,
            "content": content,
        }))
        .unwrap()
        .cast_unchecked()
    }

    fn shown_with_post(event: &Raw<AnySyncTimelineEvent>, preview: Option<LinkPreview>) -> (Shown, SharedPost) {
        let content: matrix_sdk::ruma::events::room::message::RoomMessageEventContent =
            event.get_field("content").unwrap().unwrap();
        let mut shown = message_shown(&content.msgtype);
        let post = BridgedPost::of(event).unwrap().shared(&mut shown, || preview);
        (shown, post)
    }

    #[test]
    fn a_shared_post_tells_the_bridges_title_and_caption_apart_from_the_message_instead_of_its_address() {
        let (shown, post) = shown_with_post(&shared_reel(Some("galaxies"), Some("The quantum experiment")), None);
        assert_eq!(shown.body, "");
        assert!(shown.styles.is_empty());
        assert_eq!(
            post,
            SharedPost {
                url: "https://www.instagram.com/reel/abc/?id=1&a=b".to_owned(),
                title: Some("galaxies".to_owned()),
                description: Some("The quantum experiment".to_owned()),
            }
        );
    }

    #[test]
    fn a_shared_post_tells_what_its_pages_preview_says() {
        let preview = LinkPreview {
            title: Some("galaxies on Instagram".to_owned()),
            description: Some("The double slit experiment".to_owned()),
        };
        let (shown, post) = shown_with_post(&shared_reel(None, None), Some(preview));
        assert_eq!(shown.body, "");
        assert_eq!(post.title.as_deref(), Some("galaxies on Instagram"));
        assert_eq!(post.description.as_deref(), Some("The double slit experiment"));
    }

    #[test]
    fn a_shared_post_shows_no_address_while_its_preview_is_read() {
        let (shown, post) = shown_with_post(&shared_reel(None, None), None);
        assert_eq!(shown.body, "");
        assert_eq!((post.title, post.description), (None, None));
    }

    #[test]
    fn a_photo_shows_its_thumbnail_and_its_caption() {
        let mut image = ImageMessageEventContent::plain("Trip".to_owned(), owned_mxc_uri!("mxc://a/full"));
        image.filename = Some("trip.jpg".to_owned());
        let mut info = matrix_sdk::ruma::events::room::ImageInfo::new();
        info.width = Some(uint!(800));
        info.height = Some(uint!(600));
        info.mimetype = Some("image/gif".to_owned());
        info.thumbnail_source = Some(MediaSource::Plain(mxc_uri!("mxc://a/thumb").to_owned()));
        image.info = Some(Box::new(info));
        let shown = message_shown(&MessageType::Image(image));
        assert_eq!(shown.body, "Trip");
        let Some(Media::Photo { picture, is_animated }) = &shown.media else {
            panic!("not a photo");
        };
        assert_eq!(picture.source.as_str(), "mxc://a/thumb");
        assert_eq!((picture.width, picture.height), (800, 600));
        assert!(is_animated);
        assert_eq!(
            shown.media.as_ref().and_then(attachment),
            NonZeroU32::new(1).map(Attachment::Pictures)
        );
    }

    #[test]
    fn a_video_without_a_poster_shows_no_picture() {
        let mut info = VideoInfo::new();
        info.duration = Some(Duration::from_secs(12));
        let mut video = VideoMessageEventContent::plain("clip.mp4".to_owned(), owned_mxc_uri!("mxc://a/v"));
        video.info = Some(Box::new(info));
        let shown = message_shown(&MessageType::Video(video));
        assert_eq!(shown.body, "");
        assert_eq!(
            shown.media,
            Some(Media::Video {
                poster: None,
                duration: Some(Duration::from_secs(12))
            })
        );
        assert_eq!(shown.media.as_ref().and_then(attachment), None);
    }

    #[test]
    fn a_voice_message_is_a_sound_row() {
        let mut info = AudioInfo::new();
        info.duration = Some(Duration::from_secs(3));
        info.mimetype = Some("audio/ogg".to_owned());
        let mut audio = AudioMessageEventContent::plain("voice.ogg".to_owned(), owned_mxc_uri!("mxc://a/s"));
        audio.info = Some(Box::new(info));
        audio.voice = Some(UnstableVoiceContentBlock::new());
        let shown = message_shown(&MessageType::Audio(audio));
        let Some(Media::File {
            kind,
            duration,
            mimetype,
            ..
        }) = &shown.media
        else {
            panic!("not a file");
        };
        assert_eq!(*kind, FileKind::Voice);
        assert_eq!(*duration, Some(Duration::from_secs(3)));
        assert_eq!(mimetype, "audio/ogg");
        assert_eq!(shown.media.as_ref().and_then(attachment), Some(Attachment::File));
    }

    #[test]
    fn upload_progress_is_a_fraction() {
        assert!((fraction(1, 4) - 0.25).abs() < f64::EPSILON);
        assert!(fraction(5, 0).abs() < f64::EPSILON);
        assert!((fraction(9, 4) - 1.0).abs() < f64::EPSILON);
    }
}
