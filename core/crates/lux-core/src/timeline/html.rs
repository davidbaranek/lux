//! A message's HTML body as the text the bubble shows and its runs of formatting. ruma reads the
//! HTML as a browser does (html5ever: every entity, broken markup mended) and keeps it to the
//! subset Matrix allows, without a reply's fallback quote; this walks what is left: a mention
//! shows as its name, in bold, a list item with its bullet or number.

use ruma_html::matrix::{AnchorUri, MatrixElement};
use ruma_html::{Html, NodeData, NodeRef};

use super::{StyleKind, TextStyle};

/// The text of `html` and its runs of formatting, in UTF-16 offsets of the text.
#[must_use]
pub fn parse(html: &str) -> (String, Vec<TextStyle>) {
    let html = Html::parse(html);
    html.sanitize();
    let mut writer = Writer::new();
    for node in html.children() {
        writer.node(&node);
    }
    writer.finish()
}

/// How an element shows.
enum Shape {
    /// Inside a line: a space before it belongs before its run, not in it.
    Inline,
    /// Its own lines.
    Block,
}

/// The text and its runs, as the walk writes them.
struct Writer {
    text: String,
    /// The text's length in UTF-16 units.
    length: usize,
    styles: Vec<TextStyle>,
    /// White space was read where the text has none yet: one space, unless a line starts.
    pending_space: bool,
    /// Inside `<pre>`: white space is kept.
    pre_depth: usize,
    /// The next number of each open list; `None` for a bulleted one.
    lists: Vec<Option<i64>>,
}

impl Writer {
    fn new() -> Self {
        Self {
            text: String::new(),
            length: 0,
            styles: Vec::new(),
            pending_space: false,
            pre_depth: 0,
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
        if !self.at_line_start() {
            self.append("\n");
        }
    }

    fn at_line_start(&self) -> bool {
        self.text.is_empty() || self.text.ends_with('\n')
    }

    /// The space read before this point, unless a line starts here.
    fn flush_space(&mut self) {
        if self.pending_space && !self.at_line_start() {
            self.append(" ");
        }
        self.pending_space = false;
    }

    /// Text as HTML shows it: runs of HTML's white space (not a no-break space) fold to one,
    /// except in `<pre>`.
    fn characters(&mut self, text: &str) {
        if self.pre_depth > 0 {
            self.append(text);
            return;
        }
        for character in text.chars() {
            if character.is_ascii_whitespace() {
                self.pending_space = true;
            } else {
                self.flush_space();
                self.append(character.encode_utf8(&mut [0; 4]));
            }
        }
    }

    fn node(&mut self, node: &NodeRef) {
        match node.data() {
            NodeData::Text(text) => self.characters(&text.borrow()),
            NodeData::Element(element) => self.element(node, element.to_matrix().element),
            NodeData::Document | NodeData::Other => {}
        }
    }

    fn children(&mut self, node: &NodeRef) {
        for child in node.children() {
            self.node(&child);
        }
    }

    fn element(&mut self, node: &NodeRef, element: MatrixElement) {
        let shape = match &element {
            MatrixElement::Br => {
                self.append("\n");
                self.pending_space = false;
                return;
            }
            MatrixElement::Hr => {
                self.newline();
                return;
            }
            MatrixElement::Img(image) => {
                if let Some(alt) = image.alt.as_ref().filter(|alt| !alt.is_empty()) {
                    self.characters(alt);
                }
                return;
            }
            MatrixElement::Pre
            | MatrixElement::Blockquote
            | MatrixElement::H(_)
            | MatrixElement::P
            | MatrixElement::Div(_)
            | MatrixElement::Ul
            | MatrixElement::Ol(_)
            | MatrixElement::Li
            | MatrixElement::Table
            | MatrixElement::Tr
            | MatrixElement::Details
            | MatrixElement::Summary => Shape::Block,
            _ => Shape::Inline,
        };
        match shape {
            Shape::Block => self.newline(),
            Shape::Inline if self.pre_depth == 0 => self.flush_space(),
            Shape::Inline => {}
        }
        let is_pre = matches!(element, MatrixElement::Pre);
        let is_list = matches!(element, MatrixElement::Ul | MatrixElement::Ol(_));
        let kind = match element {
            MatrixElement::B | MatrixElement::Strong | MatrixElement::H(_) => Some(StyleKind::Bold),
            MatrixElement::I | MatrixElement::Em => Some(StyleKind::Italic),
            MatrixElement::U => Some(StyleKind::Underline),
            MatrixElement::S | MatrixElement::Del => Some(StyleKind::Strikethrough),
            MatrixElement::Code(_) => (self.pre_depth == 0).then_some(StyleKind::Code),
            MatrixElement::Pre => Some(StyleKind::CodeBlock),
            MatrixElement::Blockquote => Some(StyleKind::Quote),
            MatrixElement::A(anchor) => match anchor.href {
                // a mention links to matrix.to (or a matrix: address): shown as the name, in bold.
                Some(AnchorUri::MatrixTo(_) | AnchorUri::Matrix(_)) => Some(StyleKind::Bold),
                Some(AnchorUri::Other(href)) => Some(StyleKind::Link(href.to_string())),
                _ => None,
            },
            MatrixElement::Ul => {
                self.lists.push(None);
                None
            }
            MatrixElement::Ol(list) => {
                self.lists.push(Some(list.start.unwrap_or(1)));
                None
            }
            MatrixElement::Li => {
                self.bullet();
                None
            }
            _ => None,
        };
        self.pre_depth += usize::from(is_pre);
        let start = self.length;
        self.children(node);
        if let Some(kind) = kind
            && self.length > start
        {
            self.styles.push(TextStyle {
                kind,
                range: start..self.length,
            });
        }
        self.pre_depth -= usize::from(is_pre);
        if is_list {
            self.lists.pop();
        }
        if matches!(shape, Shape::Block) {
            self.newline();
        }
    }

    /// A list item's bullet, or its number in a numbered list.
    fn bullet(&mut self) {
        match self.lists.last_mut() {
            Some(Some(number)) => {
                let bullet = format!("{number}. ");
                *number = number.saturating_add(1);
                self.append(&bullet);
            }
            _ => self.append("• "),
        }
    }

    /// The text without white space at its end; runs end with it.
    fn finish(mut self) -> (String, Vec<TextStyle>) {
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
    fn broken_html_reads_without_failing() {
        for html in [
            "<",
            "&",
            "&#",
            "&#x;",
            "&#xFFFFFFFF;",
            "&ž;",
            "<!--",
            "<!-- ž -",
            "ž<",
            "<ž",
            "</",
            "<a href=",
            "<a href=\"ž",
            "<a href='",
            "<a href=ž>x</a>",
            "<b><i>ž</b>",
            "</b>ž",
            "<mx-reply>ž",
            "<ul><li>a<ol><li>b</ul>c",
            "<pre><b>a</pre>b</b>",
            "<table><td>a<p>b</table>c",
        ] {
            let (text, styles) = parse(html);
            let length = text.encode_utf16().count();
            assert!(styles.iter().all(|style| style.range.end <= length), "{html:?}");
        }
        assert_eq!(parse("&#x17E;").0, "ž");
        assert_eq!(parse("<mx-reply>ž").0, "");
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
    fn a_matrix_address_is_a_mention_too() {
        let (text, styles) = parse("hi <a href=\"matrix:u/anna:example.org\">Anna</a>");
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
    fn named_entities_read_as_a_browser_reads_them() {
        assert_eq!(
            parse("a &mdash; b&hellip; &copy; 5&euro; &rarr; &nbsp;&quot;x&apos; &lt;&gt;&amp;").0,
            "a — b… © 5€ → \u{a0}\"x' <>&"
        );
        // the legacy entities without their semicolon too, as browsers read them.
        assert_eq!(parse("a &amp b &copy c").0, "a & b © c");
        assert_eq!(parse("&zzz; &;").0, "&zzz; &;");
        assert_eq!(parse("&notit;").0, "¬it;");
        // in an address as well.
        let (_, styles) = parse("<a href=\"https://example.org/?a&mdash;b\">x</a>");
        assert_eq!(
            styles,
            [style(StyleKind::Link("https://example.org/?a—b".to_owned()), 0, 1)]
        );
    }

    #[test]
    fn numeric_entities_read() {
        assert_eq!(parse("&#8212; &#x2014; &#X2014; &#128512;").0, "— — — 😀");
        // a number that is no character is the replacement character, as browsers read it.
        assert_eq!(parse("&#xFFFFFFFF;").0, "\u{FFFD}");
        assert_eq!(parse("&#0;").0, "\u{FFFD}");
    }

    #[test]
    fn nested_formatting_keeps_every_run() {
        let (text, styles) = parse("<b>a <i>b <s>c <code>d</code></s></i></b> <del>e</del>");
        assert_eq!(text, "a b c d e");
        assert_eq!(
            styles,
            [
                style(StyleKind::Bold, 0, 7),
                style(StyleKind::Italic, 2, 7),
                style(StyleKind::Strikethrough, 4, 7),
                style(StyleKind::Code, 6, 7),
                style(StyleKind::Strikethrough, 8, 9),
            ]
        );
        let (text, styles) =
            parse("<blockquote><p>quoted <b>bold</b></p></blockquote><ul><li>a<ol><li>b</li></ol></li></ul>");
        assert_eq!(text, "quoted bold\n• a\n1. b");
        assert_eq!(styles, [style(StyleKind::Quote, 0, 12), style(StyleKind::Bold, 7, 11)]);
    }

    #[test]
    fn malformed_html_is_mended_as_a_browser_mends_it() {
        // a tag left open ends with its parent's, and goes on after it, as in a browser.
        let (text, styles) = parse("<b><i>ab</b>c");
        assert_eq!(text, "abc");
        assert_eq!(
            styles,
            [
                style(StyleKind::Italic, 0, 2),
                style(StyleKind::Bold, 0, 2),
                style(StyleKind::Italic, 2, 3)
            ]
        );
        // tags closed in the wrong order.
        let (text, styles) = parse("<b>a<i>b</b>c</i>");
        assert_eq!(text, "abc");
        assert_eq!(
            styles,
            [
                style(StyleKind::Bold, 0, 2),
                style(StyleKind::Italic, 1, 2),
                style(StyleKind::Italic, 2, 3)
            ]
        );
        // a closing tag nothing opened, an unclosed comment, a tag never closed.
        assert_eq!(parse("a</b> b<!-- c").0, "a b");
        assert_eq!(parse("<p>a<p>b").0, "a\nb");
        // tags outside the Matrix subset keep their text, only as text.
        assert_eq!(parse("<marquee>a</marquee> <script>b</script>c").0, "a bc");
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
        let (text, styles) = parse("<a href=\"javascript:alert(1)\">x</a>");
        assert_eq!(text, "x");
        assert!(styles.is_empty());
    }
}
