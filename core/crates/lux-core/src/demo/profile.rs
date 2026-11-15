//! The demo account's profile: kept in memory, so the apps' profile editing can be shown and
//! tested with no server. A picture "uploaded" becomes a new made-up picture.

use std::sync::{Mutex, PoisonError};

use crate::ids::{MediaId, UserId};
use crate::ports::{BackendError, Picture, Profile, display_name};

/// The demo profile's name and picture, and how many pictures were set.
pub(super) struct DemoProfile {
    state: Mutex<State>,
}

struct State {
    name: Option<String>,
    avatar: Option<MediaId>,
    pictures: u64,
}

impl DemoProfile {
    pub(super) fn new() -> Self {
        Self {
            state: Mutex::new(State {
                name: Some("Demo".to_owned()),
                avatar: None,
                pictures: 0,
            }),
        }
    }

    fn state(&self) -> std::sync::MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }

    pub(super) fn profile(&self, user_id: &UserId) -> Profile {
        let state = self.state();
        Profile {
            user_id: user_id.clone(),
            name: state.name.clone(),
            avatar: state.avatar.clone(),
            can_change_name: true,
            can_change_avatar: true,
        }
    }

    pub(super) fn set_name(&self, name: &str) -> Result<(), BackendError> {
        let name = display_name(name)?.map(ToOwned::to_owned);
        self.state().name = name;
        Ok(())
    }

    pub(super) fn set_avatar(&self, picture: &Picture) -> Result<MediaId, BackendError> {
        if picture.data.is_empty() {
            return Err(BackendError::file("the picture is empty"));
        }
        let mut state = self.state();
        state.pictures += 1;
        // a demo picture's name: the apps draw a made-up one for it.
        let avatar = MediaId::from(format!("demo-me-{}", state.pictures));
        state.avatar = Some(avatar.clone());
        Ok(avatar)
    }

    pub(super) fn remove_avatar(&self) {
        self.state().avatar = None;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ports::PictureFormat;

    #[test]
    fn the_demo_keeps_what_the_user_changes() {
        let user = UserId::from("@me:demo");
        let profile = DemoProfile::new();
        assert_eq!(profile.profile(&user).name.as_deref(), Some("Demo"));

        profile.set_name("  Ada ").unwrap();
        assert_eq!(profile.profile(&user).name.as_deref(), Some("Ada"));
        profile.set_name("").unwrap();
        assert_eq!(profile.profile(&user).name, None);

        let picture = Picture {
            data: vec![1],
            format: PictureFormat::Png,
        };
        let first = profile.set_avatar(&picture).unwrap();
        let second = profile.set_avatar(&picture).unwrap();
        assert_ne!(first, second);
        assert_eq!(profile.profile(&user).avatar, Some(second));
        profile.remove_avatar();
        assert_eq!(profile.profile(&user).avatar, None);
    }
}
