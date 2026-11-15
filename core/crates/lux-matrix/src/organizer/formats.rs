//! The account data events the app keeps on the server, which the account's other devices read
//! and write too: each read into the core's types, and written back keeping the keys this version
//! does not know (another version's), so no device loses another's data.
//!
//! Every event is global account data under `com.bardav.lux.`: the server keeps it private to
//! the account, and no bridge reads it.

use std::collections::HashMap;
use std::fmt::Write as _;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use lux_core::chat::{SavedKind, SavedMessage};
use lux_core::ids::{ChatId, EventId, LabelId, RoomId, UserId};
use lux_core::merge::Merge;
use lux_core::organizer::{ChatMarks, LabelRecord, Reminder, Reminders, WholeLabel};
use lux_core::places::{Arrangement, InboxRule, PlaceKey, Theme};
use serde_json::{Map, Value, json};
use sha2::{Digest, Sha256};

/// What every type of the app's own starts with.
pub(crate) const PREFIX: &str = "com.bardav.lux.";
/// The archived and deleted chats.
pub(crate) const CHATS: &str = "com.bardav.lux.chats";
/// The reminders.
pub(crate) const REMINDERS: &str = "com.bardav.lux.reminders";
/// The merged chats.
pub(crate) const MERGES: &str = "com.bardav.lux.merges";
/// The saved messages.
pub(crate) const BOOKMARKS: &str = "com.bardav.lux.bookmarks";
/// The places' order, the hidden ones, and their colours.
pub(crate) const PLACE_ORDER: &str = "com.bardav.lux.place_order";
/// The labels' first document, read only: their changes are records.
pub(crate) const LABELS: &str = "com.bardav.lux.labels";
/// What each label record's type starts with.
pub(crate) const LABEL_RECORD_PREFIX: &str = "com.bardav.lux.labels.v2.";
/// Changed with each change to the labels, so a device that watches it reads them again.
pub(crate) const LABELS_CHANGED: &str = "com.bardav.lux.labels.changed";

/// The documents of one type the core reads at launch from the store, by their type.
pub(crate) const KNOWN: [&str; 6] = [CHATS, REMINDERS, MERGES, BOOKMARKS, PLACE_ORDER, LABELS];

/// An event's content: a JSON object.
pub(crate) type Content = Map<String, Value>;

pub(crate) fn time(millis: u64) -> SystemTime {
    UNIX_EPOCH + Duration::from_millis(millis)
}

pub(crate) fn millis(time: SystemTime) -> u64 {
    let since = time.duration_since(UNIX_EPOCH).unwrap_or_default();
    u64::try_from(since.as_millis()).unwrap_or(u64::MAX)
}

fn object<'a>(content: &'a Content, key: &str) -> Option<&'a Content> {
    content.get(key).and_then(Value::as_object)
}

fn text<'a>(content: &'a Content, key: &str) -> Option<&'a str> {
    content.get(key).and_then(Value::as_str)
}

fn number(content: &Content, key: &str) -> Option<u64> {
    content.get(key).and_then(Value::as_u64)
}

// MARK: archived and deleted chats

/// `{"archived": {"<room>": {"ts": <ms>}}, "hidden": {…}, "cleared": {…}}`.
pub(crate) fn chat_marks(content: &Content) -> ChatMarks {
    let times = |key: &str| -> HashMap<RoomId, SystemTime> {
        object(content, key)
            .into_iter()
            .flatten()
            .filter_map(|(room, mark)| {
                let ts = mark.as_object().and_then(|mark| number(mark, "ts"))?;
                Some((RoomId::from(room.as_str()), time(ts)))
            })
            .collect()
    };
    ChatMarks {
        archived: times("archived"),
        hidden: times("hidden"),
        cleared: times("cleared"),
    }
}

pub(crate) fn with_chat_marks(content: &Content, marks: &ChatMarks) -> Content {
    let times = |marks: &HashMap<RoomId, SystemTime>| -> Value {
        marks
            .iter()
            .map(|(room, at)| (room.to_string(), json!({ "ts": millis(*at) })))
            .collect::<Map<_, _>>()
            .into()
    };
    let mut content = content.clone();
    content.insert("archived".to_owned(), times(&marks.archived));
    content.insert("hidden".to_owned(), times(&marks.hidden));
    content.insert("cleared".to_owned(), times(&marks.cleared));
    content
}

// MARK: reminders

/// `{"reminders": {"<room>": {"at": <ms>, "set": <ms>}}}`.
pub(crate) fn reminders(content: &Content) -> Reminders {
    object(content, "reminders")
        .into_iter()
        .flatten()
        .filter_map(|(room, reminder)| {
            let reminder = reminder.as_object()?;
            let reminder = Reminder {
                at: time(number(reminder, "at")?),
                set_at: time(number(reminder, "set").unwrap_or(0)),
            };
            Some((RoomId::from(room.as_str()), reminder))
        })
        .collect()
}

pub(crate) fn with_reminders(content: &Content, reminders: &Reminders) -> Content {
    let all: Map<String, Value> = reminders
        .iter()
        .map(|(room, reminder)| {
            let entry = json!({ "at": millis(reminder.at), "set": millis(reminder.set_at) });
            (room.to_string(), entry)
        })
        .collect();
    let mut content = content.clone();
    content.insert("reminders".to_owned(), all.into());
    content
}

// MARK: merged chats

/// `{"merges": [{"id", "name", "rooms": […], "default"}]}`; one with fewer than two rooms is
/// none, and a default that is none of its rooms is its first.
pub(crate) fn merges(content: &Content) -> Vec<Merge> {
    content
        .get("merges")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|merge| {
            let merge = merge.as_object()?;
            let rooms: Vec<RoomId> = merge
                .get("rooms")?
                .as_array()?
                .iter()
                .filter_map(|room| room.as_str().map(RoomId::from))
                .collect();
            if rooms.len() < 2 {
                return None;
            }
            let chosen = text(merge, "default").map(RoomId::from);
            let default_room = chosen
                .filter(|room| rooms.contains(room))
                .unwrap_or_else(|| rooms[0].clone());
            Some(Merge {
                id: text(merge, "id")?.into(),
                name: text(merge, "name").unwrap_or_default().to_owned(),
                rooms,
                default_room,
            })
        })
        .collect()
}

pub(crate) fn with_merges(content: &Content, merges: &[Merge]) -> Content {
    let all: Vec<Value> = merges
        .iter()
        .map(|merge| {
            json!({
                "id": merge.id.as_str(),
                "name": merge.name,
                "rooms": merge.rooms.iter().map(RoomId::as_str).collect::<Vec<_>>(),
                "default": merge.default_room.as_str(),
            })
        })
        .collect();
    let mut content = content.clone();
    content.insert("merges".to_owned(), all.into());
    content
}

// MARK: saved messages

/// `{"bookmarks": [{"room", "event", "sender", "senderName", "body", "kind", "fileName", "ts",
/// "savedAt"}]}`, the last saved first.
pub(crate) fn bookmarks(content: &Content, own: &UserId) -> Vec<SavedMessage> {
    content
        .get("bookmarks")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|mark| {
            let mark = mark.as_object()?;
            let (room, event) = (text(mark, "room")?, text(mark, "event")?);
            if room.is_empty() || event.is_empty() {
                return None;
            }
            let sender = text(mark, "sender").unwrap_or_default();
            let sender_name = text(mark, "senderName")
                .filter(|name| !name.is_empty())
                .unwrap_or(sender);
            Some(SavedMessage {
                event: EventId::from(event),
                room: RoomId::from(room),
                sender_name: sender_name.to_owned(),
                is_own: sender == own.as_str(),
                body: text(mark, "body").unwrap_or_default().to_owned(),
                kind: saved_kind(text(mark, "kind").unwrap_or_default()),
                file_name: text(mark, "fileName").unwrap_or_default().to_owned(),
                date: time(number(mark, "ts").unwrap_or(0)),
                saved_at: time(number(mark, "savedAt").unwrap_or(0)),
            })
        })
        .collect()
}

/// A saved message as the document keeps it.
pub(crate) struct Bookmark<'a> {
    pub(crate) message: &'a SavedMessage,
    pub(crate) sender: &'a str,
}

/// The longest text a saved message keeps: the list shows three lines, the chat the rest.
pub(crate) const BOOKMARK_BODY_LIMIT: usize = 500;

/// The bookmarks with `added` first (in place of the same message) and without `removed`.
pub(crate) fn with_bookmark(
    content: &Content,
    added: Option<&Bookmark<'_>>,
    removed: Option<(&RoomId, &EventId)>,
) -> Content {
    let same = |mark: &Value, room: &str, event: &str| {
        mark.as_object()
            .is_some_and(|mark| text(mark, "room") == Some(room) && text(mark, "event") == Some(event))
    };
    let mut marks: Vec<Value> = content
        .get("bookmarks")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    if let Some((room, event)) = removed {
        marks.retain(|mark| !same(mark, room.as_str(), event.as_str()));
    }
    if let Some(Bookmark { message, sender }) = added {
        marks.retain(|mark| !same(mark, message.room.as_str(), message.event.as_str()));
        let body: String = message.body.chars().take(BOOKMARK_BODY_LIMIT).collect();
        marks.insert(
            0,
            json!({
                "room": message.room.as_str(),
                "event": message.event.as_str(),
                "sender": sender,
                "senderName": message.sender_name,
                "body": body,
                "kind": saved_kind_name(message.kind),
                "fileName": message.file_name,
                "ts": millis(message.date),
                "savedAt": millis(message.saved_at),
            }),
        );
    }
    let mut content = content.clone();
    content.insert("bookmarks".to_owned(), marks.into());
    content
}

fn saved_kind(name: &str) -> SavedKind {
    match name {
        "text" => SavedKind::Text,
        "image" => SavedKind::Image,
        "video" => SavedKind::Video,
        "voice" => SavedKind::Voice,
        "audio" => SavedKind::Audio,
        "file" => SavedKind::File,
        "sticker" => SavedKind::Sticker,
        _ => SavedKind::Other,
    }
}

fn saved_kind_name(kind: SavedKind) -> &'static str {
    match kind {
        SavedKind::Text => "text",
        SavedKind::Image => "image",
        SavedKind::Video => "video",
        SavedKind::Voice => "voice",
        SavedKind::Audio => "audio",
        SavedKind::File => "file",
        SavedKind::Sticker => "sticker",
        SavedKind::Other => "other",
    }
}

// MARK: the places' arrangement

/// `{"order": ["network:whatsapp", …], "hidden": […], "themes": {"space:!s": "blue", …},
/// "theme": "green", "inbox": {"network:discord": "mentions", …}, "chatInbox": {"!r": "all", …}}`;
/// all but the order came later, and their absence hides nothing, colours nothing and keeps
/// nothing out of the inbox. A colour or a rule this version does not know reads as none.
pub(crate) fn arrangement(content: &Content) -> Arrangement {
    let keys = |key: &str| {
        content
            .get(key)
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(|key| key.as_str().map(PlaceKey::from))
    };
    let themes = object(content, "themes")
        .into_iter()
        .flatten()
        .filter_map(|(key, theme)| Some((PlaceKey::from(key.as_str()), Theme::from_key(theme.as_str()?)?)))
        .collect();
    let rules = |key: &str| {
        object(content, key)
            .into_iter()
            .flatten()
            .filter_map(|(key, rule)| Some((key.as_str(), InboxRule::from_key(rule.as_str()?)?)))
    };
    Arrangement {
        order: keys("order").collect(),
        hidden: keys("hidden").collect(),
        themes,
        theme: text(content, "theme").and_then(Theme::from_key).unwrap_or_default(),
        // all is what the inbox shows unasked: a place keeps none.
        inbox: rules(INBOX)
            .filter(|&(_, rule)| rule != InboxRule::All)
            .map(|(key, rule)| (PlaceKey::from(key), rule))
            .collect(),
        chat_inbox: rules(CHAT_INBOX)
            .map(|(chat, rule)| (ChatId::from(chat), rule))
            .collect(),
    }
}

/// The arrangement's key for the places' inbox rules.
const INBOX: &str = "inbox";
/// The arrangement's key for the chats' own inbox rules.
const CHAT_INBOX: &str = "chatInbox";

/// `content`'s map at `key` with `written` in place of the values this version knows; one it
/// does not know stays until this device writes that key.
fn kept_unknown<'a>(
    content: &Content,
    key: &str,
    known: impl Fn(&str) -> bool,
    written: impl IntoIterator<Item = (&'a str, &'static str)>,
) -> Content {
    let mut map: Content = object(content, key)
        .into_iter()
        .flatten()
        .filter(|(_, value)| !value.as_str().is_some_and(&known))
        .map(|(key, value)| (key.clone(), value.clone()))
        .collect();
    for (key, value) in written {
        map.insert(key.to_owned(), value.into());
    }
    map
}

/// The content with `arrangement` written in. A place's colour this version does not know stays
/// until this device gives that place another.
pub(crate) fn with_arrangement(content: &Content, arrangement: &Arrangement) -> Content {
    let mut hidden: Vec<&str> = arrangement.hidden.iter().map(PlaceKey::as_str).collect();
    hidden.sort_unstable();
    let themes = kept_unknown(
        content,
        "themes",
        |theme| Theme::from_key(theme).is_some(),
        (arrangement.themes.iter()).map(|(key, theme)| (key.as_str(), theme.as_str())),
    );
    let known_rule = |rule: &str| InboxRule::from_key(rule).is_some();
    let inbox = kept_unknown(
        content,
        INBOX,
        known_rule,
        (arrangement.inbox.iter()).map(|(key, rule)| (key.as_str(), rule.as_str())),
    );
    let chat_ids: Vec<(String, InboxRule)> = (arrangement.chat_inbox.iter())
        .map(|(chat, &rule)| (chat.to_string(), rule))
        .collect();
    let chat_inbox = kept_unknown(
        content,
        CHAT_INBOX,
        known_rule,
        chat_ids.iter().map(|(chat, rule)| (chat.as_str(), rule.as_str())),
    );
    let mut content = content.clone();
    content.insert(
        "order".to_owned(),
        arrangement
            .order
            .iter()
            .map(PlaceKey::as_str)
            .collect::<Vec<_>>()
            .into(),
    );
    content.insert("hidden".to_owned(), hidden.into());
    content.insert("themes".to_owned(), themes.into());
    content.insert(INBOX.to_owned(), inbox.into());
    content.insert(CHAT_INBOX.to_owned(), chat_inbox.into());
    // an unknown colour for every place stays while this device keeps neutral.
    if arrangement.theme != Theme::Neutral || text(&content, "theme").and_then(Theme::from_key).is_some() {
        content.insert("theme".to_owned(), arrangement.theme.as_str().into());
    }
    content
}

// MARK: labels

/// The first document: `{"labels": [{"id", "name", "roomIds": […]}], "revision"}`.
pub(crate) fn whole_labels(content: &Content) -> Vec<WholeLabel> {
    content
        .get("labels")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|label| {
            let label = label.as_object()?;
            Some(WholeLabel {
                id: text(label, "id")?.into(),
                name: text(label, "name").unwrap_or_default().to_owned(),
                rooms: label
                    .get("roomIds")
                    .and_then(Value::as_array)
                    .into_iter()
                    .flatten()
                    .filter_map(|room| room.as_str().map(RoomId::from))
                    .collect(),
            })
        })
        .collect()
}

/// A label record from its event, `{"id", "name"}`, `{"id", "roomId", "included"}` or `{"id",
/// "deleted": true}`; `None` for one whose type is not the one its content makes (written by
/// hand, or by another app).
pub(crate) fn label_record(event_type: &str, content: &Content) -> Option<LabelRecord> {
    let id = LabelId::from(text(content, "id").filter(|id| !id.is_empty())?);
    let (name, room, included, deleted) = (
        content.get("name").and_then(Value::as_str),
        content.get("roomId").and_then(Value::as_str),
        content.get("included").and_then(Value::as_bool),
        content.get("deleted").and_then(Value::as_bool),
    );
    let record = match (name, room, included, deleted) {
        (Some(name), None, None, None) => LabelRecord::Name {
            id,
            name: name.to_owned(),
        },
        (None, Some(room), Some(included), None) => LabelRecord::Room {
            id,
            room: RoomId::from(room),
            included,
        },
        (None, None, None, Some(true)) => LabelRecord::Deleted { id },
        _ => return None,
    };
    (label_record_type(&record) == event_type).then_some(record)
}

/// A label record's event: its type and content.
pub(crate) fn label_record_event(record: &LabelRecord) -> (String, Content) {
    let mut content = Content::new();
    content.insert("id".to_owned(), record.label().as_str().into());
    match record {
        LabelRecord::Name { name, .. } => {
            content.insert("name".to_owned(), name.as_str().into());
        }
        LabelRecord::Room { room, included, .. } => {
            content.insert("roomId".to_owned(), room.as_str().into());
            content.insert("included".to_owned(), (*included).into());
        }
        LabelRecord::Deleted { .. } => {
            content.insert("deleted".to_owned(), true.into());
        }
    }
    (label_record_type(record), content)
}

/// The type a record is kept as: one per label's name, per label's deletion, per label and
/// room. The parts are hashed (SHA-256, each framed by its length so no two pairs read alike),
/// which keeps the type short for any id.
fn label_record_type(record: &LabelRecord) -> String {
    let (field, parts): (&str, Vec<&str>) = match record {
        LabelRecord::Name { id, .. } => ("name.", vec![id.as_str()]),
        LabelRecord::Deleted { id } => ("deleted.", vec![id.as_str()]),
        LabelRecord::Room { id, room, .. } => ("room.", vec![id.as_str(), room.as_str()]),
    };
    let mut hasher = Sha256::new();
    for part in parts {
        hasher.update(format!("{}:", part.len()));
        hasher.update(part);
    }
    let digest = hasher.finalize();
    let mut name = String::with_capacity(LABEL_RECORD_PREFIX.len() + field.len() + 64);
    name.push_str(LABEL_RECORD_PREFIX);
    name.push_str(field);
    for byte in digest {
        let _ = write!(name, "{byte:02x}");
    }
    name
}

/// The marker's content: a new revision each time.
pub(crate) fn labels_changed() -> Content {
    let mut content = Content::new();
    content.insert(
        "revision".to_owned(),
        uuid::Uuid::new_v4().to_string().to_uppercase().into(),
    );
    content
}

#[cfg(test)]
mod tests {
    use lux_core::chat::{SavedKind, SavedMessage};
    use lux_core::ids::{RoomId, UserId};
    use lux_core::organizer::LabelRecord;
    use serde_json::json;

    use super::*;

    fn content(value: Value) -> Content {
        let Value::Object(content) = value else {
            panic!("not an object")
        };
        content
    }

    #[test]
    fn chat_marks_read_and_write_keeping_other_keys() {
        let stored = content(json!({
            "archived": {"!a:x": {"ts": 1000}},
            "hidden": {"!b:x": {"ts": 2000}},
            "cleared": {"!b:x": {"ts": 2000}},
            "later": {"kept": true}
        }));
        let mut marks = chat_marks(&stored);
        assert_eq!(marks.archived.get("!a:x"), Some(&time(1000)));
        assert_eq!(marks.hidden.get("!b:x"), Some(&time(2000)));
        marks.archived.clear();
        let written = with_chat_marks(&stored, &marks);
        assert_eq!(written["later"], json!({"kept": true}));
        assert_eq!(written["archived"], json!({}));
        assert_eq!(chat_marks(&written), marks);
    }

    #[test]
    fn reminders_round_trip() {
        let stored = content(json!({"reminders": {"!a:x": {"at": 5000, "set": 4000}, "!bad": {}}}));
        let all = reminders(&stored);
        assert_eq!(all.len(), 1);
        assert_eq!(reminders(&with_reminders(&Content::new(), &all)), all);
    }

    #[test]
    fn merges_need_two_rooms_and_a_default_among_them() {
        let stored = content(json!({"merges": [
            {"id": "m1", "name": "Jana", "rooms": ["!a", "!b"], "default": "!c"},
            {"id": "m2", "name": "Solo", "rooms": ["!d"], "default": "!d"}
        ]}));
        let all = merges(&stored);
        assert_eq!(all.len(), 1);
        assert_eq!(all[0].default_room, RoomId::from("!a"));
        assert_eq!(merges(&with_merges(&stored, &all)), all);
    }

    #[test]
    fn bookmarks_add_remove_and_read() {
        let own = UserId::from("@me:x");
        let message = SavedMessage {
            event: "$e".into(),
            room: "!a".into(),
            sender_name: "Me".to_owned(),
            is_own: true,
            body: "x".repeat(600),
            kind: SavedKind::Image,
            file_name: String::new(),
            date: time(1000),
            saved_at: time(2000),
        };
        let stored = content(json!({"bookmarks": [{"room": "!a", "event": "$old", "sender": "@b:x"}], "v": 2}));
        let added = with_bookmark(
            &stored,
            Some(&Bookmark {
                message: &message,
                sender: "@me:x",
            }),
            None,
        );
        let read = bookmarks(&added, &own);
        assert_eq!(read.len(), 2);
        assert_eq!(read[0].body.len(), BOOKMARK_BODY_LIMIT);
        assert!(read[0].is_own && read[0].kind == SavedKind::Image);
        // a sender without a name is shown by their id.
        assert_eq!(read[1].sender_name, "@b:x");
        let removed = with_bookmark(&added, None, Some((&"!a".into(), &"$old".into())));
        assert_eq!(bookmarks(&removed, &own).len(), 1);
        assert_eq!(removed["v"], json!(2));
    }

    #[test]
    fn an_arrangement_without_hidden_hides_nothing() {
        let old = arrangement(&content(json!({"order": ["network:whatsapp"]})));
        assert_eq!(old.order, [PlaceKey::from("network:whatsapp")]);
        assert!(old.hidden.is_empty());
        let mut changed = old.clone();
        changed.hidden.insert("space:!s".into());
        assert_eq!(arrangement(&with_arrangement(&Content::new(), &changed)), changed);
    }

    #[test]
    fn the_places_colours_read_back_and_unknown_ones_stay() {
        let old = content(json!({
            "order": [],
            "themes": {"space:!s": "blue", "space:!new": "ultraviolet"},
            "theme": "green",
        }));
        let read = arrangement(&old);
        assert_eq!(read.theme, Theme::Green);
        assert_eq!(read.themes.len(), 1);
        assert_eq!(read.theme_of(&"space:!s".into()), Theme::Blue);
        assert_eq!(read.theme_of(&"space:!new".into()), Theme::Green);
        let changed = read
            .with_theme("space:!s".into(), None)
            .with_theme("label:work".into(), Some(Theme::Neutral));
        let written = with_arrangement(&old, &changed);
        assert_eq!(
            Value::Object(written["themes"].as_object().unwrap().clone()),
            json!({"space:!new": "ultraviolet", "label:work": "neutral"})
        );
        assert_eq!(arrangement(&written), changed);
        let neutral = Arrangement {
            theme: Theme::Neutral,
            ..changed
        };
        assert_eq!(with_arrangement(&old, &neutral)["theme"], json!("neutral"));
        assert!(!with_arrangement(&Content::new(), &Arrangement::default()).contains_key("theme"));
    }

    #[test]
    fn the_inbox_rules_read_back_and_unknown_ones_stay() {
        let old = content(json!({
            "order": [],
            "inbox": {"network:discord": "mentions", "space:!s": "all", "space:!new": "weekends"},
            "chatInbox": {"!a:x": "never"},
        }));
        let read = arrangement(&old);
        assert_eq!(read.inbox_of(&"network:discord".into()), InboxRule::Mentions);
        // all is what a place shows unasked; a rule this version does not know reads as none.
        assert_eq!(read.inbox.len(), 1);
        assert_eq!(read.chat_inbox.get(&ChatId::from("!a:x")), Some(&InboxRule::Never));
        let changed = read
            .with_inbox("network:discord".into(), InboxRule::All)
            .with_inbox("space:!guild".into(), InboxRule::Never)
            .with_chat_inbox("!a:x".into(), None)
            .with_chat_inbox("merge:m".into(), Some(InboxRule::All));
        let written = with_arrangement(&old, &changed);
        assert_eq!(
            written["inbox"],
            json!({"space:!new": "weekends", "space:!guild": "never"})
        );
        assert_eq!(written["chatInbox"], json!({"merge:m": "all"}));
        assert_eq!(arrangement(&written), changed);
        assert!(arrangement(&content(json!({"order": []}))).chat_inbox.is_empty());
    }

    #[test]
    fn label_records_are_typed_by_their_parts() {
        let record = LabelRecord::Room {
            id: "L".into(),
            room: "!a:x".into(),
            included: true,
        };
        let (event_type, content) = label_record_event(&record);
        assert!(event_type.starts_with("com.bardav.lux.labels.v2.room."));
        assert_eq!(event_type.len(), LABEL_RECORD_PREFIX.len() + "room.".len() + 64);
        assert_eq!(label_record(&event_type, &content), Some(record));
        // the same content under another type is not the record.
        assert_eq!(label_record("com.bardav.lux.labels.v2.room.00", &content), None);
        let name = LabelRecord::Name {
            id: "L".into(),
            name: "Work".to_owned(),
        };
        let (name_type, _) = label_record_event(&name);
        // SHA-256 of each part after its length ("1:L"), as every device names them.
        assert_eq!(
            name_type,
            "com.bardav.lux.labels.v2.name.ee6482e3c3ed581458c69fea1a4b38f7dc4e095b9cd4f87177abe73eaa2a364f"
        );
        assert_eq!(
            event_type,
            "com.bardav.lux.labels.v2.room.f17805b160f67e0ce2987ce0d66d65ba6eeb5a163e5897f2c6ef8fc8eb52ae21"
        );
    }

    #[test]
    fn whole_labels_read() {
        let labels = whole_labels(&content(
            json!({"labels": [{"id": "w", "name": "Work", "roomIds": ["!a"]}], "revision": "r"}),
        ));
        assert_eq!(labels[0].rooms, [RoomId::from("!a")]);
    }
}
