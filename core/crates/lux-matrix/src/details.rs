//! A chat's details over the SDK: a room's state (name, topic, picture, encryption) and what the
//! account may change of it by its power levels, its members, its notifications in the push
//! rules, and leaving it.

use lux_core::ids::{ChatId, MediaId, RoomId, UserId};
use lux_core::ports::{
    BackendError, ChatActions, ChatChange, ChatDetails, Member, NotificationMode, Picture, PictureFormat, Role,
    RoomDetails, RoomPermissions, SharedPage, ThreadPage,
};
use matrix_sdk::RoomMemberships;
use matrix_sdk::notification_settings::RoomNotificationMode;
use matrix_sdk::room::RoomMemberRole;
use matrix_sdk::ruma::events::StateEventType;

use crate::account::MatrixAccount;
use crate::errors::from_sdk;

impl ChatDetails for MatrixAccount {
    async fn room_details(&self, room: &RoomId) -> Result<RoomDetails, BackendError> {
        let room = self.room(room)?;
        let own = self.client.user_id().ok_or(BackendError::SignedOut)?;
        let power = room.power_levels_or_default().await;
        let may = |state: StateEventType| power.user_can_send_state(own, state);
        let settings = self.client.notification_settings().await;
        let notifications =
            crate::actions::notification_mode(settings.get_user_defined_room_notification_mode(room.room_id()).await);
        Ok(RoomDetails {
            id: RoomId::from(room.room_id().as_str()),
            name: crate::mapping::display_name(&room),
            topic: room.topic().filter(|topic| !topic.trim().is_empty()),
            avatar: crate::mapping::room_picture(&room)
                .await
                .map(|url| MediaId::from(url.as_str())),
            address: room.canonical_alias().map(|alias| alias.to_string()),
            is_encrypted: room.latest_encryption_state().await.map_err(from_sdk)?.is_encrypted(),
            is_direct: room.is_direct().await.unwrap_or(false),
            joined_members: room.joined_members_count(),
            notifications,
            may: RoomPermissions {
                rename: may(StateEventType::RoomName),
                change_topic: may(StateEventType::RoomTopic),
                change_avatar: may(StateEventType::RoomAvatar),
            },
        })
    }

    async fn members(&self, room: &RoomId) -> Result<Vec<Member>, BackendError> {
        let room = self.room(room)?;
        // the sync names only the members of the events it brought (lazy loading).
        if !room.are_members_synced() {
            room.sync_members().await.map_err(from_sdk)?;
        }
        let members = room.members(RoomMemberships::JOIN).await.map_err(from_sdk)?;
        Ok(members
            .iter()
            .map(|member| Member {
                user: UserId::from(member.user_id().as_str()),
                name: member
                    .display_name()
                    .map_or_else(|| member.user_id().localpart().to_owned(), str::to_owned),
                avatar: member.avatar_url().map(|url| MediaId::from(url.as_str())),
                role: match member.suggested_role_for_power_level() {
                    RoomMemberRole::Creator => Role::Creator,
                    RoomMemberRole::Administrator => Role::Admin,
                    RoomMemberRole::Moderator => Role::Moderator,
                    RoomMemberRole::User => Role::Member,
                },
                is_own: member.is_account_user(),
                may_mention_room: member.can_trigger_room_notification(),
            })
            .collect())
    }

    async fn shared(&self, room: &RoomId, from: Option<&str>) -> Result<SharedPage, BackendError> {
        crate::timeline::shared::page(&self.room(room)?, from).await
    }

    async fn threads(&self, room: &RoomId, from: Option<&str>) -> Result<ThreadPage, BackendError> {
        self.timelines().threads(room, from).await
    }

    async fn set_notifications(&self, chat: &ChatId, mode: NotificationMode) -> Result<(), BackendError> {
        let mode = match mode {
            // the chat menu's mute keeps the mentions in the list; unmuting puts back the account's
            // settings, the archive kept.
            NotificationMode::Off => return self.change(chat, ChatChange::Mute).await,
            NotificationMode::Default => return self.change(chat, ChatChange::Unmute).await,
            NotificationMode::All => RoomNotificationMode::AllMessages,
            NotificationMode::Mentions => RoomNotificationMode::MentionsAndKeywordsOnly,
        };
        let settings = self.client.notification_settings().await;
        for room in self.rooms_of(chat)? {
            settings
                .set_room_notification_mode(room.room_id(), mode)
                .await
                .map_err(BackendError::refused)?;
        }
        Ok(())
    }

    async fn rename_room(&self, room: &RoomId, name: &str) -> Result<(), BackendError> {
        let name = lux_core::ports::display_name(name)?.unwrap_or_default();
        self.room(room)?.set_name(name.to_owned()).await.map_err(from_sdk)?;
        Ok(())
    }

    async fn set_topic(&self, room: &RoomId, topic: &str) -> Result<(), BackendError> {
        self.room(room)?.set_room_topic(topic.trim()).await.map_err(from_sdk)?;
        Ok(())
    }

    async fn set_room_avatar(&self, room: &RoomId, picture: Picture) -> Result<(), BackendError> {
        let format = match picture.format {
            PictureFormat::Jpeg => mime::IMAGE_JPEG,
            PictureFormat::Png => mime::IMAGE_PNG,
        };
        self.room(room)?
            .upload_avatar(&format, picture.data, None)
            .await
            .map_err(from_sdk)?;
        Ok(())
    }

    async fn remove_room_avatar(&self, room: &RoomId) -> Result<(), BackendError> {
        self.room(room)?.remove_avatar().await.map_err(from_sdk)?;
        Ok(())
    }

    async fn leave(&self, chat: &ChatId) -> Result<(), BackendError> {
        for room in self.rooms_of(chat)? {
            room.leave().await.map_err(from_sdk)?;
        }
        Ok(())
    }
}
