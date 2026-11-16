//! Where the Markdown a user types is formatted, for the composer to show as it is typed. It
//! reads the text with the parser and options sending uses (ruma's `text_markdown`:
//! `pulldown-cmark` with tables and strikethrough), so what the composer shows bold is what the
//! others get bold.

use std::ops::Range;

use pulldown_cmark::{CodeBlockKind, Event, Options, Parser, Tag};

/// The options of ruma's `text_markdown`, which sends the composer's text.
const OPTIONS: Options = Options::ENABLE_TABLES.union(Options::ENABLE_STRIKETHROUGH);

/// How a run of the text shows.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum MarkdownStyle {
    /// Strong emphasis (`**`).
    Bold,
    /// Emphasis (`*`, `_`).
    Italic,
    /// Struck through (`~~`).
    Strikethrough,
    /// Code within a line.
    Code,
    /// A block of code.
    CodeBlock,
    /// A quote's text.
    Quote,
    /// The marks themselves (`**`, `` ` ``, `> `): shown, but dimmed.
    Mark,
}

/// A run of the text and how it shows, in UTF-16 code units, as text views count.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct MarkdownRun {
    /// How it shows.
    pub style: MarkdownStyle,
    /// Where it starts.
    pub start: usize,
    /// How long it is.
    pub length: usize,
}

/// The formatted runs of `text` and the runs of their marks, in the order the parser finds them.
#[must_use]
pub fn markdown_runs(text: &str) -> Vec<MarkdownRun> {
    let offsets = Utf16Offsets::new(text);
    let mut runs = Found {
        text,
        offsets: &offsets,
        runs: Vec::new(),
    };
    let mut quotes = 0_usize;
    for (event, range) in Parser::new_ext(text, OPTIONS).into_offset_iter() {
        match event {
            Event::Start(Tag::Strong) => runs.delimited(MarkdownStyle::Bold, range, 2),
            Event::Start(Tag::Emphasis) => runs.delimited(MarkdownStyle::Italic, range, 1),
            Event::Start(Tag::Strikethrough) => {
                let marks = text
                    .get(range.clone())
                    .unwrap_or_default()
                    .bytes()
                    .take_while(|byte| *byte == b'~')
                    .count();
                runs.delimited(MarkdownStyle::Strikethrough, range, marks);
            }
            Event::Code(_) => {
                let marks = text
                    .get(range.clone())
                    .unwrap_or_default()
                    .bytes()
                    .take_while(|byte| *byte == b'`')
                    .count();
                runs.delimited(MarkdownStyle::Code, range, marks);
            }
            Event::Start(Tag::CodeBlock(CodeBlockKind::Fenced(_))) => runs.fenced(range),
            Event::Start(Tag::CodeBlock(CodeBlockKind::Indented)) => runs.push(MarkdownStyle::CodeBlock, range),
            Event::Start(Tag::BlockQuote(_)) => {
                // a quote's lines once: those of a quote inside it are among them.
                if quotes == 0 {
                    runs.quote(range);
                }
                quotes += 1;
            }
            Event::End(pulldown_cmark::TagEnd::BlockQuote(_)) => quotes = quotes.saturating_sub(1),
            _ => {}
        }
    }
    runs.runs
}

/// The runs found so far, and how to place them.
struct Found<'a> {
    text: &'a str,
    offsets: &'a Utf16Offsets,
    runs: Vec<MarkdownRun>,
}

impl Found<'_> {
    fn push(&mut self, style: MarkdownStyle, range: Range<usize>) {
        if range.is_empty() {
            return;
        }
        let start = self.offsets.at(range.start);
        self.runs.push(MarkdownRun {
            style,
            start,
            length: self.offsets.at(range.end).saturating_sub(start),
        });
    }

    /// A span with `marks` bytes of marks on each side.
    fn delimited(&mut self, style: MarkdownStyle, range: Range<usize>, marks: usize) {
        if range.len() < 2 * marks {
            return;
        }
        let inner = range.start + marks..range.end - marks;
        self.push(style, inner.clone());
        self.push(MarkdownStyle::Mark, range.start..inner.start);
        self.push(MarkdownStyle::Mark, inner.end..range.end);
    }

    /// A fenced block: its opening line and its closing fence are marks, what is between code.
    fn fenced(&mut self, range: Range<usize>) {
        let block = self.text.get(range.clone()).unwrap_or_default();
        let opening = block.find('\n').map_or(block.len(), |end| end + 1);
        let body = block.get(opening..).unwrap_or_default();
        let trimmed = body.trim_end_matches(['\n', '\r']);
        let closing = trimmed.rfind('\n').map_or(0, |end| end + 1);
        let last = trimmed.get(closing..).unwrap_or_default();
        let fence = block.trim_start().chars().next().unwrap_or('`');
        let closed = !last.is_empty() && last.trim().chars().all(|character| character == fence);
        let code_end = if closed { opening + closing } else { block.len() };
        self.push(MarkdownStyle::Mark, range.start..range.start + opening);
        self.push(MarkdownStyle::CodeBlock, range.start + opening..range.start + code_end);
        if closed {
            self.push(
                MarkdownStyle::Mark,
                range.start + code_end..range.start + opening + trimmed.len(),
            );
        }
    }

    /// A quote: each line's `>` marks (and the space after each), then its text.
    fn quote(&mut self, range: Range<usize>) {
        let mut line_start = range.start;
        for line in self.text.get(range.clone()).unwrap_or_default().split_inclusive('\n') {
            let content = line.trim_end_matches(['\n', '\r']);
            let mut marks = 0;
            for (index, character) in content.char_indices() {
                match character {
                    '>' => marks = index + 1,
                    ' ' | '\t' if marks > 0 && index == marks => marks = index + 1,
                    ' ' | '\t' if marks == 0 => {}
                    _ => break,
                }
            }
            let marks_start = content.find('>').unwrap_or(0);
            if marks > 0 {
                self.push(MarkdownStyle::Mark, line_start + marks_start..line_start + marks);
            }
            self.push(MarkdownStyle::Quote, line_start + marks..line_start + content.len());
            line_start += line.len();
        }
    }
}

/// Byte offsets of a text in UTF-16 code units.
struct Utf16Offsets {
    /// Each character's byte offset and UTF-16 offset, then the text's end.
    starts: Vec<(usize, usize)>,
}

impl Utf16Offsets {
    fn new(text: &str) -> Self {
        let mut utf16 = 0;
        let mut starts = Vec::with_capacity(text.len() + 1);
        for (byte, character) in text.char_indices() {
            starts.push((byte, utf16));
            utf16 += character.len_utf16();
        }
        starts.push((text.len(), utf16));
        Self { starts }
    }

    /// The UTF-16 offset of the byte offset `byte` (a character's start, or the end).
    fn at(&self, byte: usize) -> usize {
        match self.starts.binary_search_by_key(&byte, |(start, _)| *start) {
            Ok(index) | Err(index) => self.starts.get(index).map_or(0, |(_, utf16)| *utf16),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{MarkdownStyle, markdown_runs};

    #[test]
    fn marks_around_wide_characters_stay_within_the_text() {
        for text in [
            "~~ž~~",
            "~ž~",
            "`ž`",
            "**ž**",
            "```\nž",
            "```ž\nž\n```",
            "> ž\n>> ž",
            ">",
            "``",
            "~~~",
        ] {
            let length = text.encode_utf16().count();
            for run in markdown_runs(text) {
                assert!(run.start + run.length <= length, "{text:?}");
            }
        }
    }

    /// The text of each run of `style`.
    fn shown(text: &str, style: MarkdownStyle) -> Vec<String> {
        let utf16: Vec<u16> = text.encode_utf16().collect();
        markdown_runs(text)
            .into_iter()
            .filter(|run| run.style == style)
            .map(|run| String::from_utf16_lossy(&utf16[run.start..run.start + run.length]))
            .collect()
    }

    #[test]
    fn bold_italic_and_strikethrough_show_their_text_and_dim_their_marks() {
        let text = "a **bold** *it* ~~gone~~";
        assert_eq!(shown(text, MarkdownStyle::Bold), ["bold"]);
        assert_eq!(shown(text, MarkdownStyle::Italic), ["it"]);
        assert_eq!(shown(text, MarkdownStyle::Strikethrough), ["gone"]);
        assert_eq!(shown(text, MarkdownStyle::Mark), ["**", "**", "*", "*", "~~", "~~"]);
    }

    #[test]
    fn an_underscore_inside_a_word_is_text_as_it_is_sent() {
        assert!(shown("snake_case_name", MarkdownStyle::Italic).is_empty());
        assert_eq!(shown("_word_", MarkdownStyle::Italic), ["word"]);
    }

    #[test]
    fn nothing_is_formatted_inside_code() {
        let text = "`**not bold**` and\n```\n*not it*\n```";
        assert_eq!(shown(text, MarkdownStyle::Code), ["**not bold**"]);
        assert_eq!(shown(text, MarkdownStyle::CodeBlock), ["*not it*\n"]);
        assert!(shown(text, MarkdownStyle::Bold).is_empty());
        assert!(shown(text, MarkdownStyle::Italic).is_empty());
    }

    #[test]
    fn an_unclosed_fence_is_code_to_the_end() {
        let text = "```swift\nlet a = 1";
        assert_eq!(shown(text, MarkdownStyle::CodeBlock), ["let a = 1"]);
        assert_eq!(shown(text, MarkdownStyle::Mark), ["```swift\n"]);
    }

    #[test]
    fn a_quote_dims_its_marks_and_shows_its_lines() {
        let text = "> first\n> second";
        assert_eq!(shown(text, MarkdownStyle::Quote), ["first", "second"]);
        assert_eq!(shown(text, MarkdownStyle::Mark), ["> ", "> "]);
    }

    #[test]
    fn runs_count_utf16_as_text_views_do() {
        let runs = markdown_runs("😀 **b**");
        let bold = runs.iter().find(|run| run.style == MarkdownStyle::Bold).copied();
        assert_eq!(bold.map(|run| (run.start, run.length)), Some((5, 1)));
    }

    #[test]
    fn plain_text_has_no_runs() {
        assert!(markdown_runs("just words, 2 * 3 = 6").is_empty());
    }
}
