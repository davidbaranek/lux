//! Photo search's query: the typed words as the token ids the model's text encoder reads, by the
//! tokenizer that comes with the model (its `tokenizer.json`). The apps run the encoder (Core ML);
//! the words become ids here, the same on every platform.

use std::sync::Arc;

use tokenizers::Tokenizer;

/// Why the tokenizer cannot be had or used.
#[derive(Debug, thiserror::Error, uniffi::Error)]
#[uniffi(flat_error)]
pub enum CoreTokenizerError {
    /// The file is not a tokenizer, or the words cannot be read by it.
    #[error("{0}")]
    Failed(String),
}

/// How the model reads words.
#[derive(uniffi::Record)]
pub struct CoreTokenizerSettings {
    /// The `tokenizer.json` file.
    pub path: String,
    /// How many ids the encoder reads: fewer are padded, more cut.
    pub length: u32,
    /// The id that pads.
    pub pad_id: u32,
    /// The model learned from lowercased words.
    pub lowercase: bool,
}

/// The model's tokenizer, loaded once.
#[derive(uniffi::Object)]
pub struct CoreQueryTokenizer {
    tokenizer: Tokenizer,
    length: usize,
    pad_id: i32,
    lowercase: bool,
}

#[uniffi::export]
impl CoreQueryTokenizer {
    /// Loads the tokenizer; a large file (the vocabulary of every language), so not on the main
    /// thread.
    ///
    /// # Errors
    /// When the file is not a tokenizer.
    #[uniffi::constructor]
    pub fn open(settings: CoreTokenizerSettings) -> Result<Arc<Self>, CoreTokenizerError> {
        let CoreTokenizerSettings {
            path,
            length,
            pad_id,
            lowercase,
        } = settings;
        let failed = |error: &dyn std::fmt::Display| CoreTokenizerError::Failed(error.to_string());
        Ok(Arc::new(Self {
            tokenizer: Tokenizer::from_file(path).map_err(|error| failed(&error))?,
            length: length as usize,
            pad_id: i32::try_from(pad_id).map_err(|error| failed(&error))?,
            lowercase,
        }))
    }

    /// The words' ids, with the model's special ones, exactly `length` of them.
    ///
    /// # Errors
    /// When the tokenizer cannot read the words.
    pub fn ids(&self, text: String) -> Result<Vec<i32>, CoreTokenizerError> {
        let mut ids: Vec<i32> = self
            .encoding(text)?
            .get_ids()
            .iter()
            .map(|&id| i32::try_from(id).unwrap_or(self.pad_id))
            .collect();
        ids.resize(self.length, self.pad_id);
        Ok(ids)
    }

    /// Whether the words fit the encoder whole, with the model's special ones: more than
    /// `length` tokens are cut.
    ///
    /// # Errors
    /// When the tokenizer cannot read the words.
    pub fn fits(&self, text: String) -> Result<bool, CoreTokenizerError> {
        Ok(self.encoding(text)?.len() <= self.length)
    }
}

impl CoreQueryTokenizer {
    fn encoding(&self, text: String) -> Result<tokenizers::Encoding, CoreTokenizerError> {
        let text = if self.lowercase { text.to_lowercase() } else { text };
        self.tokenizer
            .encode(text, true)
            .map_err(|error| CoreTokenizerError::Failed(error.to_string()))
    }
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, reason = "a test's helpers fail it as its asserts do")]

    use super::*;

    /// The ids the model's own processor (in Python) gives these words: this tokenizer reads
    /// them the same. Needs the model's tokenizer (`scripts/image-search/convert.py` writes it):
    /// `LUX_TOKENIZER=<folder>/tokenizer.json cargo test -p lux-ffi -- --ignored`.
    #[test]
    #[ignore = "needs the model's tokenizer.json"]
    fn reads_words_as_the_model_learned_them() {
        let path = std::env::var("LUX_TOKENIZER").unwrap();
        let tokenizer = CoreQueryTokenizer::open(CoreTokenizerSettings {
            path,
            length: 64,
            pad_id: 0,
            lowercase: false,
        })
        .unwrap();
        // EmbeddingGemma 2's query prompt and a Czech word, between its start and end ids.
        let ids = tokenizer.ids("task: search result | query: výlet".into()).unwrap();
        assert_eq!(
            ids[..12],
            [2, 8071, 236_787, 3927, 1354, 1109, 7609, 236_787, 16799, 1184, 1, 0]
        );
        assert_eq!(ids.len(), 64);
        assert_eq!(tokenizer.ids("slovo ".repeat(100)).unwrap().len(), 64);
        // the start and end ids count: the prompt and a word fit, a hundred words do not.
        assert!(tokenizer.fits("title: none | text: výlet".into()).unwrap());
        assert!(!tokenizer.fits("slovo ".repeat(100)).unwrap());
    }
}
