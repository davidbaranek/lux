//! The account's own profile, as others see it everywhere: its display name and its picture.

use std::future::Future;

use crate::ids::{MediaId, UserId};

use super::BackendError;

/// The longest display name, in characters: what Synapse accepts.
pub const MAX_NAME_LENGTH: usize = 256;

/// The account's own profile.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Profile {
    /// The account.
    pub user_id: UserId,
    /// Its display name, when it has one.
    pub name: Option<String>,
    /// Its picture.
    pub avatar: Option<MediaId>,
    /// The server lets the user change the display name.
    pub can_change_name: bool,
    /// The server lets the user change the picture.
    pub can_change_avatar: bool,
}

impl Profile {
    /// The name to show: the display name, else the user id's local part.
    #[must_use]
    pub fn shown_name(&self) -> &str {
        self.name.as_deref().unwrap_or_else(|| self.user_id.localpart())
    }
}

/// A display name as the user typed it, ready to set: trimmed, and none when empty (the
/// account's name is then removed).
///
/// # Errors
/// [`BackendError::NameTooLong`] for a name longer than [`MAX_NAME_LENGTH`].
pub fn display_name(typed: &str) -> Result<Option<&str>, BackendError> {
    let name = typed.trim();
    if name.chars().count() > MAX_NAME_LENGTH {
        return Err(BackendError::NameTooLong);
    }
    Ok((!name.is_empty()).then_some(name))
}

/// The format of a picture's bytes.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PictureFormat {
    /// JPEG.
    Jpeg,
    /// PNG.
    Png,
}

/// A picture to upload: its bytes, encoded in its format.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Picture {
    /// The encoded image.
    pub data: Vec<u8>,
    /// How it is encoded.
    pub format: PictureFormat,
}

/// The account's own profile, and changing it.
pub trait AccountProfile: Send + Sync {
    /// The profile, from the server.
    fn profile(&self) -> impl Future<Output = Result<Profile, BackendError>> + Send;

    /// Sets the display name to `name` as typed (see [`display_name`]); an empty one removes it.
    fn set_name(&self, name: &str) -> impl Future<Output = Result<(), BackendError>> + Send;

    /// Uploads `picture` and makes it the account's picture. The picture's media.
    fn set_avatar(&self, picture: Picture) -> impl Future<Output = Result<MediaId, BackendError>> + Send;

    /// Removes the account's picture.
    fn remove_avatar(&self) -> impl Future<Output = Result<(), BackendError>> + Send;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_typed_name_is_trimmed_and_an_empty_one_removes_it() {
        assert_eq!(display_name("  Alice \n").ok(), Some(Some("Alice")));
        assert_eq!(display_name("   ").ok(), Some(None));
        assert_eq!(display_name("").ok(), Some(None));
    }

    #[test]
    fn a_name_is_measured_in_characters() {
        let longest = "ř".repeat(MAX_NAME_LENGTH);
        assert!(display_name(&longest).is_ok());
        assert!(matches!(
            display_name(&format!("{longest}x")),
            Err(BackendError::NameTooLong)
        ));
    }
}
