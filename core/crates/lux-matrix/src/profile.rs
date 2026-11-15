//! The account's own profile: its display name and picture, as the server keeps them, and
//! whether the server lets the user change them (`m.profile_fields`, else `m.set_displayname`
//! and `m.set_avatar_url`).

use futures_util::try_join;
use lux_core::ids::{MediaId, UserId};
use lux_core::ports::{AccountProfile, BackendError, Picture, PictureFormat, Profile, display_name};
use matrix_sdk::ruma::OwnedMxcUri;
use matrix_sdk::ruma::api::client::profile::{AvatarUrl, DisplayName};

use crate::account::MatrixAccount;
use crate::errors::from_sdk;

impl AccountProfile for MatrixAccount {
    async fn profile(&self) -> Result<Profile, BackendError> {
        let own = self.client.user_id().ok_or(BackendError::SignedOut)?.to_owned();
        let account = self.client.account();
        let capabilities = self.client.homeserver_capabilities();
        // the whole profile at once: a field the account has not set is left out, where asking for
        // that field alone answers 404.
        let (fields, can_change_name, can_change_avatar) = try_join!(
            account.fetch_user_profile(),
            capabilities.can_change_displayname(),
            capabilities.can_change_avatar(),
        )
        .map_err(from_sdk)?;
        let name = fields.get_static::<DisplayName>().map_err(BackendError::refused)?;
        let avatar = fields.get_static::<AvatarUrl>().map_err(BackendError::refused)?;
        Ok(Profile {
            user_id: UserId::from(own.as_str()),
            name,
            avatar: avatar.map(|url| media(&url)),
            can_change_name,
            can_change_avatar,
        })
    }

    async fn set_name(&self, name: &str) -> Result<(), BackendError> {
        let name = display_name(name)?;
        self.client.account().set_display_name(name).await.map_err(from_sdk)
    }

    async fn set_avatar(&self, picture: Picture) -> Result<MediaId, BackendError> {
        let format = match picture.format {
            PictureFormat::Jpeg => mime::IMAGE_JPEG,
            PictureFormat::Png => mime::IMAGE_PNG,
        };
        let url = self
            .client
            .account()
            .upload_avatar(&format, picture.data)
            .await
            .map_err(from_sdk)?;
        Ok(media(&url))
    }

    async fn remove_avatar(&self) -> Result<(), BackendError> {
        self.client.account().set_avatar_url(None).await.map_err(from_sdk)
    }
}

fn media(url: &OwnedMxcUri) -> MediaId {
    MediaId::from(url.as_str())
}
