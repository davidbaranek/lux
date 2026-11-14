//! A message's HTML body (the subset Matrix allows) as the text the bubble shows and its runs of
//! formatting. A small scanner, not an HTML engine: it knows Matrix's tags (a reply's fallback
//! quote goes, a mention shows as its name, in bold) and runs in microseconds.

use super::{StyleKind, TextStyle};

/// The text of `html` and its runs of formatting, in UTF-16 offsets of the text.
#[must_use]
pub fn parse(html: &str) -> (String, Vec<TextStyle>) {
    let mut scanner = Scanner::new(html);
    scanner.run();
    scanner.finish()
}

/// Tags that start a block: a space before one does not belong to the text after it.
const BLOCKS: [&str; 15] = [
    "br",
    "hr",
    "pre",
    "blockquote",
    "h1",
    "h2",
    "h3",
    "h4",
    "h5",
    "h6",
    "p",
    "div",
    "ul",
    "ol",
    "li",
];

/// An open tag.
struct Open {
    name: String,
    start: usize,
    kind: Option<StyleKind>,
}

struct Scanner {
    chars: Vec<char>,
    at: usize,
    text: String,
    /// The text's length in UTF-16 units.
    length: usize,
    styles: Vec<TextStyle>,
    open: Vec<Open>,
    pending_space: bool,
    pre_depth: usize,
    /// Inside `<mx-reply>`: everything is skipped.
    skip_depth: usize,
    /// The next number of each open list; `None` for a bulleted one.
    lists: Vec<Option<u64>>,
}

impl Scanner {
    fn new(html: &str) -> Self {
        Self {
            chars: html.chars().collect(),
            at: 0,
            text: String::with_capacity(html.len()),
            length: 0,
            styles: Vec::new(),
            open: Vec::new(),
            pending_space: false,
            pre_depth: 0,
            skip_depth: 0,
            lists: Vec::new(),
        }
    }

    fn append(&mut self, text: &str) {
        self.text.push_str(text);
        self.length += text.encode_utf16().count();
    }

    /// Starts a new line, unless the text is empty or already at one.
    fn newline(&mut self) {
        self.pending_space = false;
        if !self.text.is_empty() && !self.text.ends_with('\n') {
            self.append("\n");
        }
    }

    fn at_line_start(&self) -> bool {
        self.text.is_empty() || self.text.ends_with('\n')
    }

    fn run(&mut self) {
        while let Some(&next) = self.chars.get(self.at) {
            if next == '<' {
                self.tag();
            } else if self.skip_depth > 0 {
                self.at += 1;
            } else if next == '&' {
                let entity = self.entity();
                self.character(&entity);
            } else {
                self.at += 1;
                self.character(next.encode_utf8(&mut [0; 4]));
            }
        }
    }

    fn character(&mut self, text: &str) {
        if self.pre_depth > 0 {
            self.append(text);
            return;
        }
        if text.chars().all(char::is_whitespace) {
            self.pending_space = true;
            return;
        }
        if self.pending_space && !self.at_line_start() {
            self.append(" ");
        }
        self.pending_space = false;
        self.append(text);
    }

    fn entity(&mut self) -> String {
        let start = self.at;
        let mut end = start + 1;
        while end < self.chars.len() && end - start < 12 && !matches!(self.chars[end], ';' | '<' | '&') {
            end += 1;
        }
        if self.chars.get(end) != Some(&';') {
            self.at += 1;
            return "&".to_owned();
        }
        let name: String = self.chars[start + 1..end].iter().collect();
        self.at = end + 1;
        match name.as_str() {
            "amp" => "&".to_owned(),
            "lt" => "<".to_owned(),
            "gt" => ">".to_owned(),
            "quot" => "\"".to_owned(),
            "apos" => "'".to_owned(),
            "nbsp" => "\u{00A0}".to_owned(),
            _ => {
                let number = if let Some(hex) = name.strip_prefix("#x").or_else(|| name.strip_prefix("#X")) {
                    u32::from_str_radix(hex, 16).ok()
                } else {
                    name.strip_prefix('#').and_then(|decimal| decimal.parse().ok())
                };
                match number.and_then(char::from_u32) {
                    Some(character) => character.to_string(),
                    None => format!("&{name};"),
                }
            }
        }
    }

    fn tag(&mut self) {
        let chars = &self.chars;
        let at = self.at;
        // a comment
        if chars.get(at + 1..at + 4) == Some(&['!', '-', '-'][..]) {
            let mut end = at + 4;
            while end + 2 < chars.len() && chars[end..end + 3] != ['-', '-', '>'] {
                end += 1;
            }
            self.at = chars.len().min(end + 3);
            return;
        }
        let mut end = at + 1;
        let mut quote: Option<char> = None;
        while let Some(&next) = chars.get(end) {
            match quote {
                Some(open) if next == open => quote = None,
                None if next == '"' || next == '\'' => quote = Some(next),
                None if next == '>' => break,
                Some(_) | None => {}
            }
            end += 1;
        }
        let inside: String = chars[at + 1..end.min(chars.len())].iter().collect();
        self.at = chars.len().min(end + 1);
        let (closing, body) = match inside.strip_prefix('/') {
            Some(body) => (true, body),
            None => (false, inside.as_str()),
        };
        let name_length = body
            .find(|character: char| !(character.is_alphanumeric() || character == '-'))
            .unwrap_or(body.len());
        let name = body[..name_length].to_lowercase();
        if name.is_empty() {
            return;
        }
        if closing {
            self.close(&name);
        } else {
            let attributes = body[name_length..].to_owned();
            self.start(name, &attributes, inside.ends_with('/'));
        }
    }

    fn start(&mut self, name: String, attributes: &str, self_closing: bool) {
        if name == "mx-reply" {
            self.skip_depth += 1;
            return;
        }
        if self.skip_depth > 0 {
            return;
        }
        // a space before an inline tag belongs before its run, not in it.
        if !BLOCKS.contains(&name.as_str()) && self.pending_space && self.pre_depth == 0 && !self.at_line_start() {
            self.append(" ");
            self.pending_space = false;
        }
        let kind = match name.as_str() {
            "br" => {
                self.append("\n");
                self.pending_space = false;
                return;
            }
            "img" => {
                if let Some(alt) = attribute("alt", attributes).filter(|alt| !alt.is_empty()) {
                    self.character(&alt);
                }
                return;
            }
            "hr" => {
                self.newline();
                return;
            }
            "b" | "strong" => Some(StyleKind::Bold),
            "i" | "em" => Some(StyleKind::Italic),
            "u" | "ins" => Some(StyleKind::Underline),
            "s" | "del" | "strike" => Some(StyleKind::Strikethrough),
            "code" => (self.pre_depth == 0).then_some(StyleKind::Code),
            "pre" => {
                self.newline();
                self.pre_depth += 1;
                Some(StyleKind::CodeBlock)
            }
            "blockquote" => {
                self.newline();
                Some(StyleKind::Quote)
            }
            "h1" | "h2" | "h3" | "h4" | "h5" | "h6" => {
                self.newline();
                Some(StyleKind::Bold)
            }
            "p" | "div" => {
                self.newline();
                None
            }
            "ul" => {
                self.newline();
                self.lists.push(None);
                None
            }
            "ol" => {
                self.newline();
                let first = attribute("start", attributes).and_then(|start| start.parse().ok());
                self.lists.push(Some(first.unwrap_or(1)));
                None
            }
            "li" => {
                self.newline();
                match self.lists.last_mut() {
                    Some(Some(number)) => {
                        let bullet = format!("{number}. ");
                        *number += 1;
                        self.append(&bullet);
                    }
                    _ => self.append("• "),
                }
                None
            }
            "a" => attribute("href", attributes).and_then(|href| {
                // a mention links to matrix.to: shown as the name, in bold.
                if href.starts_with("https://matrix.to/") {
                    Some(StyleKind::Bold)
                } else {
                    has_scheme(&href).then_some(StyleKind::Link(href))
                }
            }),
            _ => None,
        };
        if self_closing {
            return;
        }
        self.open.push(Open {
            name,
            start: self.length,
            kind,
        });
    }

    fn close(&mut self, name: &str) {
        if name == "mx-reply" {
            self.skip_depth = self.skip_depth.saturating_sub(1);
            return;
        }
        if self.skip_depth > 0 {
            return;
        }
        let Some(index) = self.open.iter().rposition(|open| open.name == name) else {
            return;
        };
        // a tag left open inside this one ends with it.
        for open in self.open.drain(index..).rev() {
            if let Some(kind) = open.kind
                && self.length > open.start
            {
                self.styles.push(TextStyle {
                    kind,
                    range: open.start..self.length,
                });
            }
        }
        match name {
            "pre" => {
                self.pre_depth = self.pre_depth.saturating_sub(1);
                self.newline();
            }
            "blockquote" | "p" | "div" | "h1" | "h2" | "h3" | "h4" | "h5" | "h6" | "li" => self.newline(),
            "ul" | "ol" => {
                self.lists.pop();
                self.newline();
            }
            _ => {}
        }
    }

    /// The text without white space at its end; runs end with it.
    fn finish(mut self) -> (String, Vec<TextStyle>) {
        for open in std::mem::take(&mut self.open).into_iter().rev() {
            if let Some(kind) = open.kind
                && self.length > open.start
            {
                self.styles.push(TextStyle {
                    kind,
                    range: open.start..self.length,
                });
            }
        }
        let trimmed = self.text.trim_end().len();
        self.text.truncate(trimmed);
        let end = self.text.encode_utf16().count();
        let mut styles: Vec<TextStyle> = self
            .styles
            .into_iter()
            .filter_map(|style| {
                let upper = style.range.end.min(end);
                (style.range.start < upper).then_some(TextStyle {
                    kind: style.kind,
                    range: style.range.start..upper,
                })
            })
            .collect();
        styles.sort_by_key(|style| style.range.start);
        (self.text, styles)
    }
}

/// Whether `href` is an address with a scheme (`https:`, `mailto:`).
fn has_scheme(href: &str) -> bool {
    href.split_once(':').is_some_and(|(scheme, _)| {
        let mut characters = scheme.chars();
        characters.next().is_some_and(|first| first.is_ascii_alphabetic())
            && characters.all(|character| character.is_ascii_alphanumeric() || matches!(character, '+' | '-' | '.'))
    })
}

/// An attribute's value in a tag's attributes (`href="…"`, `href='…'` or `href=…`), its
/// entities read.
fn attribute(name: &str, attributes: &str) -> Option<String> {
    let lower = attributes.to_ascii_lowercase();
    let found = lower.find(&format!("{name}="))? + name.len() + 1;
    let rest = &attributes[found..];
    let first = rest.chars().next()?;
    if first == '"' || first == '\'' {
        let value = rest[1..].split(first).next().unwrap_or_default();
        return Some(parse(value).0);
    }
    Some(
        rest.split(|character: char| character.is_whitespace() || character == '>')
            .next()
            .unwrap_or_default()
            .to_owned(),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn style(kind: StyleKind, start: usize, end: usize) -> TextStyle {
        TextStyle {
            kind,
            range: start..end,
        }
    }

    #[test]
    fn runs_of_formatting_in_utf16_offsets() {
        let (text, styles) = parse("👍 <b>bold</b> and <i>it<u>al</u></i>");
        assert_eq!(text, "👍 bold and ital");
        assert_eq!(
            styles,
            [
                style(StyleKind::Bold, 3, 7),
                style(StyleKind::Italic, 12, 16),
                style(StyleKind::Underline, 14, 16)
            ]
        );
    }

    #[test]
    fn a_reply_fallback_goes_and_a_mention_is_its_name() {
        let (text, styles) = parse(
            "<mx-reply><blockquote>In reply to <a href=\"https://matrix.to/#/@a:b\">a</a></blockquote></mx-reply>\
             hi <a href=\"https://matrix.to/#/@anna:example.org\">Anna</a>",
        );
        assert_eq!(text, "hi Anna");
        assert_eq!(styles, [style(StyleKind::Bold, 3, 7)]);
    }

    #[test]
    fn links_lists_blocks_and_entities() {
        let (text, styles) = parse(
            "<p>see <a href='https://example.org/?a=1&amp;b=2'>this</a></p><ol start=\"3\"><li>one</li><li>two</li></ol>\
             <ul><li>dot</li></ul><pre><code>a  b\n</code></pre>&lt;3 &#x1F600; &unknown;",
        );
        assert_eq!(text, "see this\n3. one\n4. two\n• dot\na  b\n<3 😀 &unknown;");
        assert_eq!(
            styles[0],
            style(StyleKind::Link("https://example.org/?a=1&b=2".to_owned()), 4, 8)
        );
        assert!(styles.iter().any(|style| style.kind == StyleKind::CodeBlock));
        assert!(!styles.iter().any(|style| style.kind == StyleKind::Code));
    }

    #[test]
    fn white_space_folds_and_ends_trimmed() {
        let (text, styles) = parse("  a \n  <b>b</b>  <br>c<i>  </i>\n");
        assert_eq!(text, "a b\nc");
        assert_eq!(styles, [style(StyleKind::Bold, 2, 3)]);
    }

    #[test]
    fn a_link_without_a_scheme_is_no_link() {
        let (_, styles) = parse("<a href=\"example.org\">x</a> <img alt=\"🙂\" src=\"mxc://a/b\"/>");
        assert!(styles.is_empty());
        assert_eq!(parse("<img alt=\"🙂\">").0, "🙂");
    }
}
