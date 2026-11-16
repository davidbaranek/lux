//! Lowercase hexadecimal text.

/// Appends `bytes` to `text` as lowercase hex digits, two for each.
pub fn push_hex<'a>(text: &mut String, bytes: impl IntoIterator<Item = &'a u8>) {
    for byte in bytes {
        text.push(digit(byte >> 4));
        text.push(digit(byte & 0x0f));
    }
}

/// The digit of `nibble` (under 16).
fn digit(nibble: u8) -> char {
    char::from(if nibble < 10 {
        b'0' + nibble
    } else {
        b'a' + (nibble - 10)
    })
}

#[cfg(test)]
mod tests {
    #[test]
    fn writes_each_byte_as_two_digits() {
        let mut text = String::from("x");
        super::push_hex(&mut text, &[0x00, 0x0f, 0xa0, 0xff]);
        assert_eq!(text, "x000fa0ff");
    }
}
