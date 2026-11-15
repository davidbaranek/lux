//! The store's key.

use std::fmt;

use crate::Error;

/// The salt SQLCipher would otherwise keep in the file's first 16 bytes, which stay plain (see
/// `connect`). It only derives the pages' HMAC key from the raw key, which is random per store, so
/// one fixed salt costs nothing.
const SALT: [u8; 16] = *b"lux-store.salt.1";

/// The store's raw AES-256 key: 32 random bytes, so SQLCipher derives nothing from it.
#[derive(Clone, PartialEq, Eq)]
pub struct Key([u8; 32]);

impl Key {
    /// The key as the app keeps it: 64 hex digits.
    ///
    /// # Errors
    /// [`Error::InvalidKey`] when `hex` is not 64 hex digits.
    pub fn from_hex(hex: &str) -> Result<Self, Error> {
        let digits = hex.as_bytes();
        if digits.len() != 64 {
            return Err(Error::InvalidKey);
        }
        let mut bytes = [0; 32];
        for (byte, [high, low]) in bytes.iter_mut().zip(digits.as_chunks::<2>().0) {
            *byte = (digit(*high)? << 4) | digit(*low)?;
        }
        Ok(Self(bytes))
    }

    /// The key as the `key` pragma takes it raw, with the file's salt after it: `x'…'`, lowercase
    /// hex digits only, so it can be written into the statement.
    pub(crate) fn pragma_value(&self) -> String {
        use fmt::Write as _;
        let mut value = String::with_capacity(99);
        value.push_str("x'");
        for byte in self.0.iter().chain(&SALT) {
            let _ = write!(value, "{byte:02x}");
        }
        value.push('\'');
        value
    }
}

fn digit(character: u8) -> Result<u8, Error> {
    match character {
        b'0'..=b'9' => Ok(character - b'0'),
        b'a'..=b'f' => Ok(character - b'a' + 10),
        b'A'..=b'F' => Ok(character - b'A' + 10),
        _ => Err(Error::InvalidKey),
    }
}

impl fmt::Debug for Key {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("Key(…)")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_hex_and_writes_the_pragma_value() {
        let key = Key::from_hex(&"aB".repeat(32)).unwrap();
        assert_eq!(
            key.pragma_value(),
            format!("x'{}{}'", "ab".repeat(32), "6c75782d73746f72652e73616c742e31")
        );
        assert_eq!(format!("{key:?}"), "Key(…)");
    }

    #[test]
    fn refuses_anything_but_64_hex_digits() {
        assert!(matches!(Key::from_hex("ab"), Err(Error::InvalidKey)));
        assert!(matches!(Key::from_hex(&"zz".repeat(32)), Err(Error::InvalidKey)));
        assert!(matches!(
            Key::from_hex(&format!("{}'", "a".repeat(63))),
            Err(Error::InvalidKey)
        ));
    }
}
