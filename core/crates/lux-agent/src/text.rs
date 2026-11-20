//! What others wrote, given to an agent as plain data.

/// The longest message text given back, in characters.
pub(crate) const MAX_MESSAGE_CHARS: usize = 2000;

/// `text` without characters that hide or reorder what it says (zero-width, bidirectional
/// controls, other controls but line breaks and tabs), cut at [`MAX_MESSAGE_CHARS`].
pub(crate) fn plain(text: &str) -> String {
    let mut plain: String = text.chars().filter(|&c| !hides(c)).take(MAX_MESSAGE_CHARS).collect();
    if text.chars().filter(|&c| !hides(c)).nth(MAX_MESSAGE_CHARS).is_some() {
        plain.push('…');
    }
    plain
}

fn hides(c: char) -> bool {
    matches!(c, '\u{200B}'..='\u{200F}' | '\u{202A}'..='\u{202E}' | '\u{2060}'..='\u{2064}' | '\u{2066}'..='\u{2069}' | '\u{FEFF}')
        || (c.is_control() && c != '\n' && c != '\t')
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hidden_characters_go_and_long_text_is_cut() {
        assert_eq!(plain("ok\u{202E}evil\u{200B}\u{7}\nnext"), "okevil\nnext");
        let long = "a".repeat(MAX_MESSAGE_CHARS + 5);
        assert_eq!(plain(&long).chars().count(), MAX_MESSAGE_CHARS + 1);
    }
}
