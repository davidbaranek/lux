//! Typed text to FTS5, and FTS5's snippets back to text with the found words' places.

use std::ops::Range;

/// Opens a found word in a snippet: a private-use character no message holds.
pub(crate) const OPEN: char = '\u{E000}';
/// Closes it.
pub(crate) const CLOSE: char = '\u{E001}';

/// FTS5's query for typed text: every word, each as a prefix, quoted so no word is an operator.
/// `None` when there is no word.
pub(crate) fn query(text: &str) -> Option<String> {
    let mut query = String::with_capacity(text.len() + 8);
    for word in text
        .split(|character| !is_word(character))
        .filter(|word| !word.is_empty())
    {
        if !query.is_empty() {
            query.push(' ');
        }
        query.push('"');
        query.push_str(word);
        query.push_str("\"*");
    }
    (!query.is_empty()).then_some(query)
}

/// A letter or a digit, or a mark that belongs to the one before it (a decomposed accent).
fn is_word(character: char) -> bool {
    character.is_alphanumeric()
        || matches!(character,
            '\u{0300}'..='\u{036F}' | '\u{1AB0}'..='\u{1AFF}' | '\u{1DC0}'..='\u{1DFF}'
            | '\u{20D0}'..='\u{20FF}' | '\u{FE20}'..='\u{FE2F}')
}

/// The snippet without its markers, and the marked runs in it, in UTF-16 code units (as the apps'
/// strings count).
pub(crate) fn unmark(snippet: &str) -> (String, Vec<Range<u32>>) {
    let mut plain = String::with_capacity(snippet.len());
    let mut matches = Vec::new();
    let mut start = None;
    let mut length: u32 = 0;
    for character in snippet.chars() {
        match character {
            OPEN => start = Some(length),
            CLOSE => {
                if let Some(start) = start.take() {
                    matches.push(start..length);
                }
            }
            _ => {
                plain.push(character);
                length += u32::try_from(character.len_utf16()).unwrap_or(2);
            }
        }
    }
    (plain, matches)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_word_is_a_quoted_prefix() {
        assert_eq!(query("Zítra  výl").as_deref(), Some(r#""Zítra"* "výl"*"#));
        // a quote or an operator is only text: quotes split words, `OR` is a word.
        assert_eq!(query(r#""zit OR"#).as_deref(), Some(r#""zit"* "OR"*"#));
        // a decomposed accent stays in its word.
        assert_eq!(query("zi\u{0301}tra").as_deref(), Some("\"zi\u{0301}tra\"*"));
        assert_eq!(query("  ,. "), None);
    }

    #[test]
    fn unmarks_and_counts_in_utf16() {
        let (plain, matches) = unmark("Uvidíme se \u{E000}zítra\u{E001} ráno");
        assert_eq!(plain, "Uvidíme se zítra ráno");
        assert_eq!(matches, vec![11..16]);
        // an emoji is two UTF-16 units.
        let (plain, matches) = unmark("😀 \u{E000}hi\u{E001}");
        assert_eq!(plain, "😀 hi");
        assert_eq!(matches, vec![3..5]);
    }
}
