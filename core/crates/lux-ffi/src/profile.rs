//! The account's own profile, as the apps see it: showing it and changing its name and picture.

use lux_core::ports::{AccountProfile, Picture, PictureFormat, Profile};

use crate::account::{CoreAccount, CoreAccountError, with_account};

/// The account's profile.
#[derive(uniffi::Record)]
pub struct CoreProfile {
    /// The account.
    pub user_id: String,
    /// The name to show: the display name, else the user id's local part.
    pub name: String,
    /// The display name, when the account has one.
    pub display_name: Option<String>,
    /// Its picture.
    pub avatar: Option<String>,
    /// The server lets the user change the name.
    pub can_change_name: bool,
    /// The server lets the user change the picture.
    pub can_change_avatar: bool,
}

impl From<Profile> for CoreProfile {
    fn from(profile: Profile) -> Self {
        Self {
            user_id: profile.user_id.to_string(),
            name: profile
                .name
                .clone()
                .unwrap_or_else(|| profile.user_id.localpart().to_owned()),
            display_name: profile.name,
            avatar: profile.avatar.map(|avatar| avatar.to_string()),
            can_change_name: profile.can_change_name,
            can_change_avatar: profile.can_change_avatar,
        }
    }
}

/// How a picture's bytes are encoded.
#[derive(Clone, Copy, uniffi::Enum)]
pub enum CorePictureFormat {
    /// JPEG.
    Jpeg,
    /// PNG.
    Png,
}

impl From<CorePictureFormat> for PictureFormat {
    fn from(format: CorePictureFormat) -> Self {
        match format {
            CorePictureFormat::Jpeg => Self::Jpeg,
            CorePictureFormat::Png => Self::Png,
        }
    }
}

#[uniffi::export(async_runtime = "tokio")]
impl CoreAccount {
    /// The account's profile, from the server (the demo's, from memory).
    ///
    /// # Errors
    /// When the server cannot be reached.
    pub async fn profile(&self) -> Result<CoreProfile, CoreAccountError> {
        let profile = with_account!(self.backend(), account => account.profile().await)?;
        Ok(profile.into())
    }

    /// Sets the display name as typed: trimmed; an empty one removes it.
    ///
    /// # Errors
    /// `NameTooLong`, or when the server refuses.
    pub async fn set_profile_name(&self, name: String) -> Result<(), CoreAccountError> {
        Ok(with_account!(self.backend(), account => account.set_name(&name).await)?)
    }

    /// Uploads a picture and makes it the account's. The picture's media.
    ///
    /// # Errors
    /// When the upload or the server's change fails.
    pub async fn set_profile_picture(
        &self,
        data: Vec<u8>,
        format: CorePictureFormat,
    ) -> Result<String, CoreAccountError> {
        let picture = Picture {
            data,
            format: format.into(),
        };
        let avatar = with_account!(self.backend(), account => account.set_avatar(picture).await)?;
        Ok(avatar.to_string())
    }

    /// Removes the account's picture.
    ///
    /// # Errors
    /// When the server refuses.
    pub async fn remove_profile_picture(&self) -> Result<(), CoreAccountError> {
        Ok(with_account!(self.backend(), account => account.remove_avatar().await)?)
    }
}
