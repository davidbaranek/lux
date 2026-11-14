//! The composer's Markdown as the apps see it: where its formatting is, read as sending reads it.

use lux_core::markdown::{MarkdownRun, MarkdownStyle, markdown_runs};

use crate::chat::position;

/// How a run of the composer's text shows.
#[derive(Clone, Copy, uniffi::Enum)]
pub enum CoreMarkdownStyle {
    /// Strong emphasis.
    Bold,
    /// Emphasis.
    Italic,
    /// Struck through.
    Strikethrough,
    /// Code within a line.
    Code,
    /// A block of code.
    CodeBlock,
    /// A quote's text.
    Quote,
    /// The marks themselves: shown, but dimmed.
    Mark,
}

/// A run of the composer's text, in UTF-16 code units.
#[derive(uniffi::Record)]
pub struct CoreMarkdownRun {
    /// How it shows.
    pub style: CoreMarkdownStyle,
    /// Where it starts.
    pub start: u32,
    /// How long it is.
    pub length: u32,
}

impl From<MarkdownRun> for CoreMarkdownRun {
    fn from(run: MarkdownRun) -> Self {
        Self {
            style: match run.style {
                MarkdownStyle::Bold => CoreMarkdownStyle::Bold,
                MarkdownStyle::Italic => CoreMarkdownStyle::Italic,
                MarkdownStyle::Strikethrough => CoreMarkdownStyle::Strikethrough,
                MarkdownStyle::Code => CoreMarkdownStyle::Code,
                MarkdownStyle::CodeBlock => CoreMarkdownStyle::CodeBlock,
                MarkdownStyle::Quote => CoreMarkdownStyle::Quote,
                MarkdownStyle::Mark => CoreMarkdownStyle::Mark,
            },
            start: position(run.start),
            length: position(run.length),
        }
    }
}

/// The formatted runs of the composer's `text` and the runs of their marks.
#[uniffi::export]
#[must_use]
pub fn composer_markdown(text: &str) -> Vec<CoreMarkdownRun> {
    markdown_runs(text).into_iter().map(CoreMarkdownRun::from).collect()
}
