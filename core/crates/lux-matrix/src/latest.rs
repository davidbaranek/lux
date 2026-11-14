//! The event a chat's row tells of. The SDK's latest event, except the account's own arrival in
//! a room that already holds messages (a chat a bridge filled with its history before the
//! account was in it, a group joined late): the newest of those messages says more than
//! "joined", and dates the chat. The arrival stays the row's event in a room without any.

use std::collections::HashMap;

use matrix_sdk::Room;
use matrix_sdk::check_validity_of_replacement_events;
use matrix_sdk::deserialized_responses::TimelineEvent;
use matrix_sdk::latest_events::LatestEventValue;
use matrix_sdk::ruma::events::room::member::MembershipChange;
use matrix_sdk::ruma::events::room::message::{MessageType, Relation, RoomMessageEventContent};
use matrix_sdk::ruma::events::{AnyMessageLikeEventContent, AnySyncStateEvent, AnySyncTimelineEvent, SyncStateEvent};
use matrix_sdk::ruma::{OwnedEventId, UserId};
use tracing::{debug, warn};

/// The event `room`'s row tells of, for the account `own`.
pub(crate) async fn row_event(room: &Room, own: &UserId) -> LatestEventValue {
    let latest = room.latest_event();
    let LatestEventValue::Remote(event) = &latest else {
        return latest;
    };
    if !event.raw().deserialize().is_ok_and(|event| is_own_arrival(&event, own)) {
        return latest;
    }
    match message_before_arrival(room, own).await {
        Some(message) => LatestEventValue::Remote(message),
        None => latest,
    }
}

/// Whether `event` is the account joining (or being let in): the SDK's latest event for a room
/// the account just entered, whatever the room held before.
fn is_own_arrival(event: &AnySyncTimelineEvent, own: &UserId) -> bool {
    let AnySyncTimelineEvent::State(AnySyncStateEvent::RoomMember(SyncStateEvent::Original(member))) = event else {
        return false;
    };
    member.state_key == own
        && matches!(
            member.membership_change(),
            MembershipChange::Joined
                | MembershipChange::InvitationAccepted
                | MembershipChange::KnockAccepted
                | MembershipChange::Invited
        )
}

/// What an event is to a row, by the SDK's rule for a latest event (`filter_timeline_event`,
/// not public): a message, an edit of one, or nothing to tell.
enum Told {
    Message,
    Edit(OwnedEventId),
    Nothing,
}

fn told(event: &AnySyncTimelineEvent) -> Told {
    let AnySyncTimelineEvent::MessageLike(event) = event else {
        return Told::Nothing;
    };
    match event.original_content() {
        Some(AnyMessageLikeEventContent::RoomMessage(RoomMessageEventContent {
            msgtype, relates_to, ..
        })) => match (msgtype, relates_to) {
            (MessageType::VerificationRequest(_), _) => Told::Nothing,
            (_, Some(Relation::Replacement(replacement))) => Told::Edit(replacement.event_id),
            _ => Told::Message,
        },
        Some(
            AnyMessageLikeEventContent::UnstablePollStart(_)
            | AnyMessageLikeEventContent::CallInvite(_)
            | AnyMessageLikeEventContent::RtcNotification(_)
            | AnyMessageLikeEventContent::Sticker(_),
        ) => Told::Message,
        // redacted, undecrypted, reactions, the rest: nothing a row says.
        _ => Told::Nothing,
    }
}

/// The newest message the room's events in memory hold before the account's arrival, as its
/// latest valid edit says it; none when they hold none.
async fn message_before_arrival(room: &Room, own: &UserId) -> Option<TimelineEvent> {
    let client = room.client();
    let events = match client.event_cache()?.room(room.room_id()).await {
        Ok((events, _handles)) => events,
        Err(error) => {
            warn!(%error, "a room's events cannot be read");
            return None;
        }
    };
    // newest first: the first edit met of each message is its latest.
    let mut edits: HashMap<OwnedEventId, TimelineEvent> = HashMap::new();
    let found = events
        .rfind_map_event_in_memory_by(|event| {
            let Ok(parsed) = event.raw().deserialize() else {
                return None;
            };
            if is_own_arrival(&parsed, own) {
                return None;
            }
            match told(&parsed) {
                Told::Nothing => None,
                Told::Edit(original) => {
                    edits.entry(original).or_insert_with(|| event.clone());
                    None
                }
                Told::Message => Some(as_edited(event, &edits)),
            }
        })
        .await;
    match found {
        Ok(found) => found,
        Err(error) => {
            warn!(%error, "a room's events cannot be read");
            None
        }
    }
}

/// `message`, or its latest edit when that edit is a valid replacement of it.
fn as_edited(message: &TimelineEvent, edits: &HashMap<OwnedEventId, TimelineEvent>) -> TimelineEvent {
    let Some(edit) = message.event_id().and_then(|id| edits.get(id)) else {
        return message.clone();
    };
    match check_validity_of_replacement_events(
        message.raw(),
        message.encryption_info().map(|info| &**info),
        edit.raw(),
        edit.encryption_info().map(|info| &**info),
    ) {
        Ok(()) => edit.clone(),
        Err(error) => {
            debug!(%error, "an edit of a row's message is not valid");
            message.clone()
        }
    }
}
