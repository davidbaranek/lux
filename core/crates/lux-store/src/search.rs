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

/// One way of finding photos (their words, messages near them, their look), best first.
pub(crate) type Ranked<T> = Vec<(String, T)>;

/// Merges rankings of the same photos by reciprocal rank: a photo high in any, or found by
/// several, comes first. Each photo keeps what the first ranking that found it says of it.
pub(crate) fn fuse<T>(rankings: Vec<Ranked<T>>, limit: usize) -> Vec<T> {
    // the usual constant: a first place outweighs a tenth, without drowning the others.
    const K: f64 = 60.0;
    let mut scored: Vec<(String, f64, usize, T)> = Vec::new();
    let mut at = std::collections::HashMap::<String, usize>::new();
    for ranking in rankings {
        for (place, (id, value)) in ranking.into_iter().enumerate() {
            // a place is far below 2^52.
            #[allow(clippy::cast_precision_loss)]
            let score = 1.0 / (K + place as f64 + 1.0);
            if let Some(scored) = at.get(&id).and_then(|&index| scored.get_mut(index)) {
                scored.1 += score;
            } else {
                at.insert(id.clone(), scored.len());
                let order = scored.len();
                scored.push((id, score, order, value));
            }
        }
    }
    // the higher score first; a tie keeps the order found.
    scored.sort_by(|a, b| b.1.total_cmp(&a.1).then(a.2.cmp(&b.2)));
    scored.into_iter().take(limit).map(|(_, _, _, value)| value).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_photo_found_several_ways_comes_first_and_keeps_its_first_reason() {
        let words = vec![("a".to_owned(), "a by words"), ("b".to_owned(), "b by words")];
        let looks = vec![("c".to_owned(), "c by look"), ("b".to_owned(), "b by look")];
        assert_eq!(
            fuse(vec![words, looks], 10),
            vec!["b by words", "a by words", "c by look"]
        );
        assert_eq!(fuse::<&str>(vec![vec![], vec![]], 10), Vec::<&str>::new());
        assert_eq!(fuse(vec![vec![("a".to_owned(), 1), ("b".to_owned(), 2)]], 1), vec![1]);
    }

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
