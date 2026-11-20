//! What a feature must not touch in a message, and positions as text views count them.

use std::collections::BTreeSet;
use std::ops::Range;

use linkify::LinkFinder;
use pulldown_cmark::{Event, Options, Parser, Tag, TagEnd};

/// The options of ruma's `text_markdown`, which sends the composer's text.
const OPTIONS: Options = Options::ENABLE_TABLES.union(Options::ENABLE_STRIKETHROUGH);

/// The byte ranges of `text` a correction must not touch: links, code, and the Markdown marks.
pub(crate) fn protected(text: &str) -> Vec<Range<usize>> {
    let mut ranges: Vec<Range<usize>> = LinkFinder::new()
        .links(text)
        .map(|link| link.start()..link.end())
        .collect();
    let mut code_block: Option<usize> = None;
    let mut content = Vec::new();
    for (event, range) in Parser::new_ext(text, OPTIONS).into_offset_iter() {
        match event {
            Event::Code(_)
            | Event::Html(_)
            | Event::InlineHtml(_)
            | Event::Start(Tag::Link { .. } | Tag::Image { .. }) => {
                ranges.push(range);
            }
            Event::Start(Tag::CodeBlock(_)) => code_block = Some(range.start),
            Event::End(TagEnd::CodeBlock) => {
                if let Some(start) = code_block.take() {
                    ranges.push(start..range.end);
                }
            }
            Event::Text(_) => content.push(range),
            _ => {}
        }
    }
    // what is not the text's own words is a mark (`**`, `> `, `- `, `1. `).
    let mut covered = 0;
    content.sort_by_key(|range| range.start);
    for range in content {
        if range.start > covered {
            ranges.push(covered..range.start);
        }
        covered = covered.max(range.end);
    }
    if covered < text.len() {
        ranges.push(covered..text.len());
    }
    ranges.retain(|range| text.get(range.clone()).is_some_and(|marks| !marks.trim().is_empty()));
    ranges
}

/// The links of `text`.
pub(crate) fn links(text: &str) -> BTreeSet<String> {
    LinkFinder::new()
        .links(text)
        .map(|link| link.as_str().to_owned())
        .collect()
}

/// The code of `text`: within a line and in blocks.
pub(crate) fn code(text: &str) -> BTreeSet<String> {
    let mut code = BTreeSet::new();
    let mut block: Option<String> = None;
    for event in Parser::new_ext(text, OPTIONS) {
        match event {
            Event::Code(content) => {
                code.insert(content.trim().to_owned());
            }
            Event::Start(Tag::CodeBlock(_)) => block = Some(String::new()),
            Event::Text(content) => {
                if let Some(block) = block.as_mut() {
                    block.push_str(&content);
                }
            }
            Event::End(TagEnd::CodeBlock) => {
                if let Some(block) = block.take() {
                    code.insert(block.trim().to_owned());
                }
            }
            _ => {}
        }
    }
    code
}

/// `range` of `text`, from bytes to UTF-16 code units, as text views count.
pub(crate) fn utf16(text: &str, range: Range<usize>) -> Range<usize> {
    let start = text
        .get(..range.start)
        .map_or(0, |before| before.encode_utf16().count());
    let length = text.get(range).map_or(0, |inside| inside.encode_utf16().count());
    start..start + length
}

#[cfg(test)]
mod tests {
    use super::*;

    fn protected_text(text: &str) -> Vec<&str> {
        let mut ranges = protected(text);
        ranges.sort_by_key(|range| range.start);
        ranges.into_iter().filter_map(|range| text.get(range)).collect()
    }

    #[test]
    fn marks_links_and_code_are_protected() {
        let text = "**Ahoj**, see https://lux.chat and `cargo test`";
        let found = protected_text(text);
        assert!(found.contains(&"**"));
        assert!(found.contains(&"https://lux.chat"));
        assert!(found.contains(&"`cargo test`"));
        assert!(!found.iter().any(|part| part.contains("Ahoj")));
    }

    #[test]
    fn utf16_counts_as_text_views() {
        let text = "Čau 👋 světe";
        let start = text.find("světe").unwrap_or_default();
        assert_eq!(utf16(text, start..text.len()), 7..12);
    }
}
