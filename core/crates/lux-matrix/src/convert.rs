//! The few conversions between the core's values and the SDK's that every adapter needs: a chat's
//! room, a timestamp, a member's name.

use std::time::{Duration, SystemTime};

use lux_core::ids::{ChatId, RoomId};
use lux_core::ports::BackendError;
use matrix_sdk::ruma::{MilliSecondsSinceUnixEpoch, RoomId as SdkRoomId, UserId};
use matrix_sdk::{Client, Room};

/// The account's room `room` (joined, invited or left, as the client knows it).
pub(crate) fn room(client: &Client, room: &RoomId) -> Result<Room, BackendError> {
    <&SdkRoomId>::try_from(room.as_str())
        .ok()
        .and_then(|id| client.get_room(id))
        .ok_or_else(|| BackendError::UnknownChat(ChatId::Room(room.clone())))
}

/// A server timestamp as a time.
pub(crate) fn system_time(timestamp: MilliSecondsSinceUnixEpoch) -> SystemTime {
    SystemTime::UNIX_EPOCH + Duration::from_millis(timestamp.get().into())
}

/// A member's name in `room`: their display name there, else their id's local part. The callers
/// keep the names they looked up.
pub(crate) async fn member_name(room: &Room, user: &UserId) -> String {
    match room.get_member_no_sync(user).await {
        Ok(Some(member)) => member
            .display_name()
            .map_or_else(|| user.localpart().to_owned(), str::to_owned),
        _ => user.localpart().to_owned(),
    }
}
