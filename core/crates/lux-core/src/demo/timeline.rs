//! The demo's chats' timelines: each room's long made-up history (texts, photos, videos, files,
//! albums, reactions, quotes, formatted bodies, readers), made on first use and the same every
//! run, and what the user does to it (sending, editing, reacting…), live as diffs. A merged
//! chat's rooms are two of them.
//!
//! [`DemoTimelines`] implements [`ChatTimelines`] and [`ChatSending`]; the made-up account holds
//! them as a thread's backend.

use std::collections::HashMap;
use std::fmt::Write;
use std::num::NonZeroU32;
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::time::{Duration, SystemTime};

use eyeball_im::{ObservableVector, Vector};
use futures_util::{StreamExt, stream};
use tokio::sync::broadcast;

use super::SentMessages;
use super::data::stable;
use super::seeded::text;
use crate::ids::{ChatId, EventId, MediaId, MessageId, MessageRef, RoomId, UserId};
use crate::message::{self, Attachment, Message, SendState};
use crate::ports::{BackendError, ChatSending, ChatTimelines, DiffStream, RoomChanges, TimelineHold, TypingStream};
use crate::preview::{PreviewKind, PreviewSource as Kind};
use crate::timeline::{
    Draft, FileKind, IndexedMessage, Media, MessageKind, OutgoingAttachment, OutgoingKind, Picture, Quote, Reaction,
    Reader, Receipt, SharedPost, TextHistory, TimelineMessage, Typist, html,
};

/// The demo account's user.
pub const OWN_USER: &str = "@me:demo";

const PEOPLE: [&str; 3] = ["Anna Nováková", "Petr Svoboda", "Jana Dvořáková"];

const FORMATTED: [&str; 5] = [
    "<b>Heads up:</b> the meeting moved to <i>Thursday</i>, room <code>4.12</code>.",
    "<blockquote>Can you bring the cables?</blockquote>Sure, <b>both</b> of them.",
    "Shopping list:<ul><li>milk</li><li><s>bread</s> got it</li><li>coffee</li></ul>",
    "Run this:<pre><code>swift test --parallel\nswift build -c release</code></pre>",
    "Details on <a href=\"https://example.org/plan\">the plan page</a>, thanks <a href=\"https://matrix.to/#/@anna:demo\">Anna</a>!",
];

/// How many room changes wait for a slow listener.
const CHANGES_BUFFER: usize = 256;

/// The demo's chats' timelines, as a backend serves them.
pub struct DemoTimelines {
    messages_per_room: usize,
    /// The newest made-up message's time: this launch's minute.
    start: SystemTime,
    state: Mutex<State>,
    changes: broadcast::Sender<RoomId>,
    next_id: AtomicU64,
    /// The account, told what the user sends; none for timelines on their own.
    sent: Option<SentMessages>,
    /// Tests: how long finding the first unread message and forwarding take, in milliseconds,
    /// as on a slow connection.
    #[cfg(test)]
    pub(crate) unread_millis: AtomicU64,
    #[cfg(test)]
    pub(crate) forward_millis: AtomicU64,
}

#[derive(Default)]
struct State {
    rooms: HashMap<RoomId, ObservableVector<Arc<TimelineMessage>>>,
    drafts: HashMap<RoomId, Draft>,
    /// Uploads under way: when each began, and its size.
    uploads: HashMap<MessageId, (SystemTime, u64)>,
}

impl std::fmt::Debug for DemoTimelines {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("DemoTimelines")
            .field("messages_per_room", &self.messages_per_room)
            .finish_non_exhaustive()
    }
}

impl DemoTimelines {
    /// Rooms of `messages_per_room` made-up messages each, the newest at this minute.
    #[must_use]
    pub fn new(messages_per_room: usize) -> Self {
        let now = SystemTime::now()
            .duration_since(SystemTime::UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs();
        Self {
            messages_per_room,
            start: SystemTime::UNIX_EPOCH + Duration::from_secs(now / 60 * 60),
            state: Mutex::new(State::default()),
            changes: broadcast::channel(CHANGES_BUFFER).0,
            next_id: AtomicU64::new(0),
            sent: None,
            #[cfg(test)]
            unread_millis: AtomicU64::new(0),
            #[cfg(test)]
            forward_millis: AtomicU64::new(0),
        }
    }

    /// These timelines tell `account` what the user sends.
    pub(crate) fn sending_to(mut self, account: SentMessages) -> Self {
        self.sent = Some(account);
        self
    }

    fn state(&self) -> MutexGuard<'_, State> {
        // the state is whole after each change: nothing awaits while it is held.
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Changes the room's messages (made first if new) and tells the listeners.
    fn change<T>(&self, room: &RoomId, change: impl FnOnce(&mut ObservableVector<Arc<TimelineMessage>>) -> T) -> T {
        let answer = {
            let mut state = self.state();
            change(self.room(&mut state, room))
        };
        // nobody listening is no error.
        let _ = self.changes.send(room.clone());
        answer
    }

    fn room<'a>(&self, state: &'a mut State, room: &RoomId) -> &'a mut ObservableVector<Arc<TimelineMessage>> {
        state
            .rooms
            .entry(room.clone())
            .or_insert_with(|| ObservableVector::from(history(room, self.messages_per_room, self.start)))
    }

    /// A message's position and value.
    fn find(&self, room: &RoomId, id: &MessageId) -> Result<(usize, Arc<TimelineMessage>), BackendError> {
        self.find_ref(room, &MessageRef::Local(id.clone()))
    }

    fn find_ref(&self, room: &RoomId, message: &MessageRef) -> Result<(usize, Arc<TimelineMessage>), BackendError> {
        let mut state = self.state();
        let messages = self.room(&mut state, room);
        messages
            .iter()
            .position(|found| match message {
                MessageRef::Local(id) => found.message.id == *id,
                MessageRef::Event(event) => found.event_id.as_ref() == Some(event),
            })
            .map(|index| (index, Arc::clone(&messages[index])))
            .ok_or(BackendError::UnknownMessage)
    }

    /// Replaces a message with what `edit` makes of it.
    fn edit_message(
        &self,
        room: &RoomId,
        id: &MessageId,
        edit: impl FnOnce(&mut TimelineMessage),
    ) -> Result<(), BackendError> {
        let (index, message) = self.find(room, id)?;
        let mut changed = (*message).clone();
        edit(&mut changed);
        self.change(room, |messages| {
            if index < messages.len() {
                messages.set(index, Arc::new(changed));
            }
        });
        Ok(())
    }

    fn new_id(&self) -> MessageId {
        MessageId::from(format!("demo-sent-{}", self.next_id.fetch_add(1, Ordering::Relaxed)))
    }

    /// The account's new message in `room`.
    fn own_message(&self, room: &RoomId, body: &str) -> TimelineMessage {
        let id = self.new_id();
        TimelineMessage {
            message: Message {
                id: id.clone(),
                sender: OWN_USER.into(),
                room: Some(room.clone()),
                date: SystemTime::now(),
                state: SendState::Sent,
                is_edited: false,
                body: body.to_owned(),
                attachment: None,
                is_reply: false,
                has_reactions: false,
                links: message::links(body, &[]),
            },
            event_id: Some(EventId::from(id.as_str())),
            sender_name: "Me".to_owned(),
            sender_avatar: None,
            is_own: true,
            is_editable: true,
            kind: MessageKind::Message,
            media: None,
            styles: Vec::new(),
            reactions: Vec::new(),
            reply: None,
            readers: Vec::new(),
            shared: None,
        }
    }

    /// The quote of the message `reply` names, for an answer to it.
    fn quote(&self, room: &RoomId, reply: &MessageRef) -> Option<Quote> {
        let (_, message) = self.find_ref(room, reply).ok()?;
        Some(Quote {
            event_id: message.event_id.clone()?,
            sender_name: message.sender_name.clone(),
            kind: Some(PreviewKind::from(Kind::Text(&message.message.body))),
        })
    }

    fn append(&self, room: &RoomId, message: TimelineMessage) {
        self.change(room, |messages| messages.push_back(Arc::new(message)));
    }
}

impl ChatTimelines for DemoTimelines {
    fn changes(&self) -> RoomChanges {
        Box::pin(stream::unfold(self.changes.subscribe(), |mut changes| async move {
            loop {
                match changes.recv().await {
                    Ok(room) => return Some((room, changes)),
                    Err(broadcast::error::RecvError::Lagged(_)) => {}
                    Err(broadcast::error::RecvError::Closed) => return None,
                }
            }
        }))
    }

    /// The whole made-up history is there at once: nothing closes.
    fn hold(&self, _room: &RoomId) -> TimelineHold {
        TimelineHold::new(|| {})
    }

    async fn messages(&self, room: &RoomId) -> Result<DiffStream<Arc<TimelineMessage>>, BackendError> {
        let (values, batches) = {
            let mut state = self.state();
            self.room(&mut state, room).subscribe().into_values_and_batched_stream()
        };
        let first = stream::once(async move { vec![eyeball_im::VectorDiff::Reset { values }] });
        Ok(Box::pin(first.chain(batches)))
    }

    async fn prefetch(&self, room: &RoomId) -> Result<(), BackendError> {
        let mut state = self.state();
        self.room(&mut state, room);
        Ok(())
    }

    async fn wait_until_filled(&self, _room: &RoomId) {}

    async fn load_older(&self, _room: &RoomId, _count: usize) -> Result<(), BackendError> {
        Ok(())
    }

    async fn is_at_start(&self, _room: &RoomId) -> Result<bool, BackendError> {
        Ok(true)
    }

    async fn show_event(&self, room: &RoomId, event: &EventId) -> Result<Option<MessageId>, BackendError> {
        Ok(self
            .find(room, &MessageId::from(event.as_str()))
            .ok()
            .map(|(_, message)| message.message.id.clone()))
    }

    /// The demo's chats have their last five messages unread.
    async fn first_unread(&self, room: &RoomId) -> Result<Option<MessageId>, BackendError> {
        #[cfg(test)]
        tokio::time::sleep(Duration::from_millis(self.unread_millis.load(Ordering::Relaxed))).await;
        Ok(self
            .messages_per_room
            .checked_sub(5)
            .map(|index| MessageId::from(format!("{room}/{index}"))))
    }

    async fn text_history(
        &self,
        room: &RoomId,
        since: SystemTime,
        max_pages: u32,
    ) -> Result<TextHistory, BackendError> {
        let messages: Vec<IndexedMessage> = {
            let mut state = self.state();
            self.room(&mut state, room)
                .iter()
                .rev()
                .filter(|message| !message.message.body.is_empty() && message.message.date >= since)
                .map(|message| IndexedMessage {
                    event_id: EventId::from(message.message.id.as_str()),
                    room: room.clone(),
                    sender_name: message.sender_name.clone(),
                    body: message.message.body.clone(),
                    date: message.message.date,
                    is_own: message.is_own,
                })
                .collect()
        };
        // pages of 50, as a server gives them.
        let most = max_pages as usize * 50;
        Ok(TextHistory {
            reached_start: messages.len() <= most,
            messages: messages.into_iter().take(most).collect(),
            removed: Vec::new(),
            deleted_until: None,
        })
    }

    /// Someone types for a few seconds now and then, so the indicator shows.
    fn typing(&self, _room: &RoomId) -> Result<TypingStream, BackendError> {
        let anna = Typist {
            user: UserId::from("@friend0:demo"),
            name: PEOPLE[0].to_owned(),
            avatar: Some(MediaId::from("demo-@friend0:demo")),
        };
        // 3 s quiet, 5 s typing, 10 s quiet, and again.
        Ok(Box::pin(stream::unfold(None, move |typing: Option<bool>| {
            let anna = anna.clone();
            async move {
                let (wait, now) = match typing {
                    None => (3, vec![anna]),
                    Some(true) => (5, Vec::new()),
                    Some(false) => (13, vec![anna]),
                };
                tokio::time::sleep(Duration::from_secs(wait)).await;
                let typing = !now.is_empty();
                Some((now, Some(typing)))
            }
        })))
    }
}

impl ChatSending for DemoTimelines {
    /// A message with "fail" in it fails, to show the retry and discard actions.
    async fn send_text(&self, room: &RoomId, text: &str, reply: Option<&MessageRef>) -> Result<(), BackendError> {
        let mut message = self.own_message(room, text);
        if text.contains("fail") {
            message.message.state = SendState::Failed;
        }
        if let Some(reply) = reply {
            message.reply = self.quote(room, reply);
            message.message.is_reply = message.reply.is_some();
        }
        self.state().drafts.remove(room);
        let date = message.message.date;
        self.append(room, message);
        if let Some(account) = &self.sent {
            account.sent(room, text, date);
        }
        Ok(())
    }

    async fn edit(&self, room: &RoomId, message: &MessageId, text: &str) -> Result<(), BackendError> {
        self.edit_message(room, message, |message| {
            text.clone_into(&mut message.message.body);
            message.message.is_edited = true;
            message.message.links = message::links(text, &[]);
            message.styles.clear();
        })
    }

    async fn delete(&self, room: &RoomId, message: &MessageId) -> Result<(), BackendError> {
        self.edit_message(room, message, |message| {
            message.kind = MessageKind::Deleted;
            message.message.body.clear();
            message.message.attachment = None;
            message.message.has_reactions = false;
            message.message.links.clear();
            message.media = None;
            message.styles.clear();
            message.reactions.clear();
            message.is_editable = false;
        })
    }

    async fn retry(&self, room: &RoomId, message: &MessageId) -> Result<(), BackendError> {
        self.edit_message(room, message, |message| message.message.state = SendState::Sent)
    }

    async fn discard(&self, room: &RoomId, message: &MessageId) -> Result<(), BackendError> {
        let (index, _) = self.find(room, message)?;
        self.change(room, |messages| {
            if index < messages.len() {
                messages.remove(index);
            }
        });
        Ok(())
    }

    async fn toggle_reaction(&self, room: &RoomId, message: &MessageId, key: &str) -> Result<(), BackendError> {
        self.edit_message(room, message, |message| {
            toggle(&mut message.reactions, key);
            message.message.has_reactions = !message.reactions.is_empty();
        })
    }

    /// Shows the attachment at once, sent; its upload goes on for a second a megabyte, at most
    /// five (`send_state`). Its picture is the file on the device.
    async fn send_attachment(
        &self,
        room: &RoomId,
        attachment: &OutgoingAttachment,
        caption: Option<&str>,
        reply: Option<&MessageRef>,
    ) -> Result<Option<MessageId>, BackendError> {
        let mut message = self.own_message(room, caption.unwrap_or_default());
        let picture = |file: &Path, width, height| Picture {
            source: MediaId::from(file.to_string_lossy().into_owned()),
            width,
            height,
        };
        let thumbnail = attachment.thumbnail.as_ref().map(|thumbnail| thumbnail.file.as_path());
        message.media = Some(match attachment.kind {
            OutgoingKind::Photo { width, height } => Media::Photo {
                picture: picture(thumbnail.unwrap_or(&attachment.file), width, height),
                is_animated: attachment.mimetype == "image/gif",
            },
            OutgoingKind::Video {
                width,
                height,
                duration,
            } => Media::Video {
                poster: thumbnail.map(|file| picture(file, width, height)),
                duration: Some(duration),
            },
            OutgoingKind::File => Media::File {
                name: attachment.name.clone(),
                size: Some(attachment.size),
                mimetype: attachment.mimetype.clone(),
                kind: FileKind::Document,
                duration: None,
            },
        });
        message.message.attachment = attachment_of(message.media.as_ref());
        message.is_editable = false;
        if let Some(reply) = reply {
            message.reply = self.quote(room, reply);
            message.message.is_reply = message.reply.is_some();
        }
        let id = message.message.id.clone();
        self.state()
            .uploads
            .insert(id.clone(), (SystemTime::now(), attachment.size));
        self.append(room, message);
        Ok(Some(id))
    }

    async fn send_state(&self, room: &RoomId, message: &MessageId) -> Result<Option<SendState>, BackendError> {
        if self.find(room, message).is_err() {
            return Ok(None);
        }
        let Some((started, size)) = self.state().uploads.get(message).copied() else {
            return Ok(Some(SendState::Sent));
        };
        let megabytes = f64::from(u32::try_from(size / 1_000).unwrap_or(u32::MAX)) / 1_000.0;
        let length = megabytes.clamp(1.0, 5.0);
        let fraction = started.elapsed().unwrap_or_default().as_secs_f64() / length;
        Ok(Some(if fraction >= 1.0 {
            SendState::Sent
        } else {
            SendState::Sending { upload: Some(fraction) }
        }))
    }

    async fn forward(&self, room: &RoomId, message: &MessageId, target: &ChatId) -> Result<(), BackendError> {
        #[cfg(test)]
        tokio::time::sleep(Duration::from_millis(self.forward_millis.load(Ordering::Relaxed))).await;
        let (_, message) = self.find(room, message)?;
        let target = match &self.sent {
            Some(account) => account.send_room(target),
            None => target.room().cloned(),
        }
        .ok_or_else(|| BackendError::UnknownChat(target.clone()))?;
        self.send_text(&target, &message.message.body, None).await
    }

    async fn draft(&self, room: &RoomId) -> Result<Option<Draft>, BackendError> {
        Ok(self.state().drafts.get(room).cloned())
    }

    async fn save_draft(&self, room: &RoomId, text: &str, reply: Option<&MessageRef>) -> Result<(), BackendError> {
        let reply = reply.and_then(|reply| self.quote(room, reply));
        let mut state = self.state();
        if text.is_empty() && reply.is_none() {
            state.drafts.remove(room);
        } else {
            state.drafts.insert(
                room.clone(),
                Draft {
                    text: text.to_owned(),
                    reply,
                },
            );
        }
        Ok(())
    }

    async fn mark_read(&self, _room: &RoomId, _receipt: Receipt) -> Result<(), BackendError> {
        Ok(())
    }

    async fn set_typing(&self, _room: &RoomId, _typing: bool) -> Result<(), BackendError> {
        Ok(())
    }
}

/// Adds the account's reaction `key`, or takes it away.
fn toggle(reactions: &mut Vec<Reaction>, key: &str) {
    match reactions.iter().position(|reaction| reaction.key == key) {
        Some(index) if reactions[index].is_mine => {
            reactions[index].is_mine = false;
            reactions[index].count = reactions[index].count.saturating_sub(1);
            if reactions[index].count == 0 {
                reactions.remove(index);
            }
        }
        Some(index) => {
            reactions[index].is_mine = true;
            reactions[index].count += 1;
        }
        None => reactions.push(Reaction {
            key: key.to_owned(),
            count: 1,
            is_mine: true,
        }),
    }
}

fn attachment_of(media: Option<&Media>) -> Option<Attachment> {
    match media? {
        Media::Photo { .. } => Some(Attachment::Pictures(NonZeroU32::MIN)),
        Media::Video { poster, .. } => poster.as_ref().map(|_| Attachment::Pictures(NonZeroU32::MIN)),
        Media::File { .. } => Some(Attachment::File),
    }
}

// MARK: the made-up history

/// A room's made-up history, oldest first: a message every 15 minutes or so, three of the user's
/// in turn with three of the others', photos (some without words, sent together into albums),
/// now and then a video, a file, a reaction, an answer to the message ten before, a link, a
/// formatted text; the user's last messages read by two.
#[allow(clippy::too_many_lines)]
fn history(room: &RoomId, count: usize, start: SystemTime) -> Vector<Arc<TimelineMessage>> {
    let seed = stable(room.as_str()) % 97;
    (0..count)
        .map(|index| {
            let i = index as u64;
            let is_own = (index / 3) % 2 == 0;
            let sender = if is_own {
                OWN_USER.to_owned()
            } else {
                format!("@friend{}:demo", index % 3)
            };
            let id = MessageId::from(format!("{room}/{index}"));
            let mut body = text(i * 31 + 7 + seed);
            let mut media = None;
            if index % 15 == 4 {
                let (width, height) = if index % 2 == 0 { (1200, 900) } else { (900, 1200) };
                media = Some(Media::Photo {
                    picture: Picture {
                        source: MediaId::from(format!("demo-photo-{}.jpg", index % 6)),
                        width,
                        height,
                    },
                    is_animated: false,
                });
                if index % 30 == 4 {
                    body.clear();
                }
            }
            // a reel shared from another network, its caption long enough to fold.
            let shared = (index % 90 == 19 || index + 6 == count).then(|| SharedPost {
                url: format!("https://www.instagram.com/reel/demo{index}/"),
                title: Some(format!("{} on Instagram", PEOPLE[index % 3])),
                description: Some(REEL_CAPTION.to_owned()),
            });
            if index % 45 == 19 || shared.is_some() {
                media = Some(Media::Video {
                    poster: Some(Picture {
                        source: MediaId::from(format!("demo-poster-{}.jpg", index % 4)),
                        width: 1280,
                        height: 720,
                    }),
                    duration: Some(Duration::from_secs(17 + i % 90)),
                });
                body.clear();
            } else if index % 45 == 34 {
                media = Some(Media::File {
                    name: format!("Trip plan {}.pdf", index % 7),
                    size: Some(180_000 + i * 977),
                    mimetype: "application/pdf".to_owned(),
                    kind: FileKind::Document,
                    duration: None,
                });
                body.clear();
            }
            let reactions = if index % 9 == 2 {
                vec![Reaction {
                    key: "❤️".to_owned(),
                    count: 1 + u32::try_from(index % 3).unwrap_or_default(),
                    is_mine: false,
                }]
            } else {
                Vec::new()
            };
            let reply = (index % 12 == 5 && index >= 10).then(|| Quote {
                event_id: EventId::from(format!("{room}/{}", index - 10)),
                sender_name: PEOPLE[(index - 10) % 3].to_owned(),
                kind: Some(PreviewKind::Text(text((i - 10) * 31 + 7))),
            });
            let readers = if index + 4 == count {
                PEOPLE[..2]
                    .iter()
                    .enumerate()
                    .map(|(friend, name)| Reader {
                        user: UserId::from(format!("@friend{friend}:demo")),
                        name: (*name).to_owned(),
                    })
                    .collect()
            } else {
                Vec::new()
            };
            if index % 20 == 7 {
                let _ = write!(body, " https://example.org/page{index}");
            }
            let mut styles = Vec::new();
            if index % 11 == 3 {
                (body, styles) = html::parse(FORMATTED[index % FORMATTED.len()]);
            }
            let links = message::links(&body, &styles);
            // the history covers several days.
            let back = Duration::from_secs((count - index) as u64 * 97 * 9);
            let sender_avatar = (!is_own && index % 3 != 2).then(|| MediaId::from(format!("demo-{sender}")));
            Arc::new(TimelineMessage {
                message: Message {
                    id: id.clone(),
                    sender: UserId::from(sender),
                    room: Some(room.clone()),
                    date: start.checked_sub(back).unwrap_or(SystemTime::UNIX_EPOCH),
                    state: SendState::Sent,
                    is_edited: false,
                    attachment: attachment_of(media.as_ref()),
                    is_reply: reply.is_some(),
                    has_reactions: !reactions.is_empty(),
                    links,
                    body,
                },
                event_id: Some(EventId::from(id.as_str())),
                sender_name: if is_own {
                    "Me".to_owned()
                } else {
                    PEOPLE[index % 3].to_owned()
                },
                sender_avatar,
                is_own,
                is_editable: is_own && !matches!(media, Some(Media::Photo { .. } | Media::Video { .. })),
                kind: MessageKind::Message,
                media,
                styles,
                reactions,
                reply,
                readers,
                shared,
            })
        })
        .collect()
}

/// A shared reel's caption, as long as such captions run.
const REEL_CAPTION: &str = "The double slit experiment, explained in under a minute: a single particle passes \
    through both slits at once and interferes with itself, until you look. We filmed it with a laser pointer, \
    a hair and a dark room. Follow for part two, where the detector changes everything. #physics #quantum #science";

#[cfg(test)]
mod tests {
    use futures_util::StreamExt;

    use super::*;

    fn room() -> RoomId {
        RoomId::from("!room1:demo")
    }

    #[test]
    fn the_history_is_the_same_every_run_and_has_all_kinds() {
        let start = SystemTime::UNIX_EPOCH + Duration::from_hours(500_000);
        let first: Vec<_> = history(&room(), 100, start).into_iter().collect();
        assert_eq!(first, history(&room(), 100, start).into_iter().collect::<Vec<_>>());
        assert_eq!(first.len(), 100);
        assert!(first.windows(2).all(|pair| pair[0].message.date < pair[1].message.date));
        assert!(
            first
                .iter()
                .any(|message| matches!(message.media, Some(Media::Photo { .. })))
        );
        assert!(
            first
                .iter()
                .any(|message| matches!(message.media, Some(Media::Video { .. })))
        );
        assert!(
            first
                .iter()
                .any(|message| matches!(message.media, Some(Media::File { .. })))
        );
        assert!(first.iter().any(|message| !message.styles.is_empty()));
        assert!(first.iter().any(|message| message.reply.is_some()));
        assert_eq!(first[96].readers.len(), 2);
        // a photo without words and its neighbours make albums with others' photos only if
        // sent together; the made-up ones are far apart.
        assert_ne!(text(1), text(2));
    }

    #[tokio::test]
    async fn sending_reacting_and_deleting_show_as_diffs() {
        let demo = DemoTimelines::new(20);
        let mut messages = demo.messages(&room()).await.expect("opens");
        let first = messages.next().await.expect("a reset");
        assert!(matches!(first.as_slice(), [eyeball_im::VectorDiff::Reset { values }] if values.len() == 20));
        demo.send_text(&room(), "hi", Some(&MessageRef::Local("!room1:demo/15".into())))
            .await
            .expect("sends");
        let sent = messages.next().await.expect("a batch");
        let eyeball_im::VectorDiff::PushBack { value } = &sent[0] else {
            panic!("an append");
        };
        assert!(value.reply.is_some());
        let id = value.message.id.clone();
        demo.toggle_reaction(&room(), &id, "👍").await.expect("reacts");
        let reacted = messages.next().await.expect("a batch");
        assert!(matches!(&reacted[0], eyeball_im::VectorDiff::Set { value, .. } if value.reactions[0].is_mine));
        demo.delete(&room(), &id).await.expect("deletes");
        let deleted = messages.next().await.expect("a batch");
        assert!(matches!(&deleted[0], eyeball_im::VectorDiff::Set { value, .. } if value.kind == MessageKind::Deleted));
    }

    #[tokio::test]
    async fn a_failing_message_retries_and_the_first_unread_is_five_back() {
        let demo = DemoTimelines::new(20);
        demo.send_text(&room(), "this will fail", None).await.expect("queued");
        let (_, failed) = demo.find(&room(), &MessageId::from("demo-sent-0")).expect("there");
        assert_eq!(failed.message.state, SendState::Failed);
        demo.retry(&room(), &failed.message.id).await.expect("retries");
        let (_, sent) = demo.find(&room(), &failed.message.id).expect("there");
        assert_eq!(sent.message.state, SendState::Sent);
        assert_eq!(
            demo.first_unread(&room()).await.expect("known"),
            Some(MessageId::from("!room1:demo/15"))
        );
    }
}
