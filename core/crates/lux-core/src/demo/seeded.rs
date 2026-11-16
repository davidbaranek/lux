//! Made-up values that are the same in every run.

/// A small deterministic generator (`SplitMix64`), as the Swift demo had, so the made-up texts
/// stay the ones the apps showed.
pub(crate) struct Seeded(u64);

const GOLDEN: u64 = 0x9E37_79B9_7F4A_7C15;

impl Seeded {
    pub(crate) fn new(seed: u64) -> Self {
        Self(seed.wrapping_add(GOLDEN))
    }

    pub(crate) fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(GOLDEN);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }

    /// A number below `bound`.
    pub(crate) fn below(&mut self, bound: usize) -> usize {
        // `bound` is small: the remainder fits.
        usize::try_from(self.next() % u64::try_from(bound.max(1)).unwrap_or(1)).unwrap_or(0)
    }
}

/// The item `index` counts to, going round `items` from the start again past its end: `None`
/// only when there are none.
pub(crate) fn round<T>(items: &[T], index: usize) -> Option<&T> {
    items.get(index.checked_rem(items.len())?)
}

/// The name `index` counts to, going round `names` (none: no name).
pub(crate) fn round_name(names: &[&'static str], index: usize) -> &'static str {
    round(names, index).copied().unwrap_or_default()
}

/// The made-up words.
const WORDS: &str = "lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod tempor incididunt ut \
    labore et dolore magna aliqua tomorrow tonight coffee train photo meeting weekend sounds good see you later";

/// A made-up sentence of 2 to 29 words.
pub(crate) fn text(seed: u64) -> String {
    let words: Vec<&str> = WORDS.split_whitespace().collect();
    let mut generator = Seeded::new(seed);
    let count = 2 + generator.below(28);
    let mut text = String::new();
    for index in 0..count {
        if index > 0 {
            text.push(' ');
        }
        text.push_str(round_name(&words, generator.below(words.len())));
    }
    text
}

#[cfg(test)]
mod tests {
    use super::text;

    #[test]
    fn the_same_seed_makes_the_same_text() {
        assert_eq!(text(7), text(7));
        assert_ne!(text(7), text(8));
        let words = text(3).split(' ').count();
        assert!((2..30).contains(&words));
    }
}
