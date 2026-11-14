//! A place's colour: the accent the apps draw it in. Neutral is the apps' own look.

/// A place's colour, one of the system's: the apps draw each in the platform's own shade of it.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub enum Theme {
    /// No colour of its own: the apps' look.
    #[default]
    Neutral,
    /// Red.
    Red,
    /// Orange.
    Orange,
    /// Yellow.
    Yellow,
    /// Green.
    Green,
    /// Mint.
    Mint,
    /// Teal.
    Teal,
    /// Cyan.
    Cyan,
    /// Blue.
    Blue,
    /// Indigo.
    Indigo,
    /// Purple.
    Purple,
    /// Pink.
    Pink,
    /// Brown.
    Brown,
}

impl Theme {
    /// Every theme, in the order the apps offer them: neutral, then the colours round the wheel.
    pub const ALL: [Self; 13] = [
        Self::Neutral,
        Self::Red,
        Self::Orange,
        Self::Yellow,
        Self::Green,
        Self::Mint,
        Self::Teal,
        Self::Cyan,
        Self::Blue,
        Self::Indigo,
        Self::Purple,
        Self::Pink,
        Self::Brown,
    ];

    /// Its key, as the account keeps it.
    #[must_use]
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Neutral => "neutral",
            Self::Red => "red",
            Self::Orange => "orange",
            Self::Yellow => "yellow",
            Self::Green => "green",
            Self::Mint => "mint",
            Self::Teal => "teal",
            Self::Cyan => "cyan",
            Self::Blue => "blue",
            Self::Indigo => "indigo",
            Self::Purple => "purple",
            Self::Pink => "pink",
            Self::Brown => "brown",
        }
    }

    /// The theme a key names; `None` for one this version does not know.
    #[must_use]
    pub fn from_key(key: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|theme| theme.as_str() == key)
    }
}

#[cfg(test)]
mod tests {
    use super::Theme;

    #[test]
    fn every_theme_reads_back_from_its_key() {
        for theme in Theme::ALL {
            assert_eq!(Theme::from_key(theme.as_str()), Some(theme));
        }
        assert_eq!(Theme::from_key("ultraviolet"), None);
        assert_eq!(Theme::default(), Theme::Neutral);
    }
}
