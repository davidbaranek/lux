//! Embeddings as the store keeps them, and how a search compares them: a photo's in 8 bits per
//! number, a query's in 32, their cosine by an SQL function that runs over every photo.
//!
//! An embedding has unit length, so each number is within ±1: 127 steps each way keep its
//! cosine to another within about 0.01, in a quarter of the space of 32-bit floats.

use rusqlite::Connection;
use rusqlite::functions::FunctionFlags;

/// The SQL function `similarity(photo, query)`: the cosine of a kept photo's embedding and a
/// query's (`query_bytes`); NULL when either is missing or their lengths differ.
const SIMILARITY: &str = "similarity";

/// One step of a kept number.
const STEP: f32 = 127.0;

/// A unit embedding as kept: each number rounded to the nearest of ±127 steps.
pub(crate) fn kept(embedding: &[f32]) -> Vec<u8> {
    embedding
        .iter()
        .map(|value| {
            // within ±127 after the clamp and rounding, so the cast keeps every value.
            #[allow(clippy::cast_possible_truncation)]
            let step = (value.clamp(-1.0, 1.0) * STEP).round() as i8;
            step.cast_unsigned()
        })
        .collect()
}

/// A query's embedding as the SQL function takes it: its numbers' little-endian bytes.
pub(crate) fn query_bytes(embedding: &[f32]) -> Vec<u8> {
    embedding.iter().flat_map(|value| value.to_le_bytes()).collect()
}

/// The cosine of a kept embedding and a query's bytes; `None` when their lengths differ.
fn cosine(photo: &[u8], query: &[u8]) -> Option<f32> {
    if query.len() != photo.len() * 4 {
        return None;
    }
    let (numbers, _) = query.as_chunks::<4>();
    let dot: f32 = photo
        .iter()
        .zip(numbers)
        .map(|(&kept, &bytes)| f32::from(kept.cast_signed()) * f32::from_le_bytes(bytes))
        .sum();
    Some(dot / STEP)
}

/// Adds the `similarity` function to a connection.
pub(crate) fn register(connection: &Connection) -> rusqlite::Result<()> {
    connection.create_scalar_function(
        SIMILARITY,
        2,
        FunctionFlags::SQLITE_UTF8 | FunctionFlags::SQLITE_DETERMINISTIC,
        |context| {
            let (Some(photo), Some(query)) = (
                context.get_raw(0).as_blob_or_null()?,
                context.get_raw(1).as_blob_or_null()?,
            ) else {
                return Ok(None);
            };
            Ok(cosine(photo, query).map(f64::from))
        },
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn unit(values: &[f32]) -> Vec<f32> {
        let length = values.iter().map(|value| value * value).sum::<f32>().sqrt();
        values.iter().map(|value| value / length).collect()
    }

    #[test]
    fn a_kept_embedding_keeps_its_cosine() {
        let photo = unit(&[0.3, -0.5, 0.1, 0.8, -0.2, 0.05]);
        let query = unit(&[0.25, -0.4, 0.3, 0.7, 0.1, -0.1]);
        let exact: f32 = photo.iter().zip(&query).map(|(a, b)| a * b).sum();
        let alike = cosine(&kept(&photo), &query_bytes(&query)).unwrap();
        assert!((alike - exact).abs() < 0.01, "{alike} vs {exact}");
        // itself: one.
        assert!((cosine(&kept(&photo), &query_bytes(&photo)).unwrap() - 1.0).abs() < 0.01);
    }

    #[test]
    fn embeddings_of_other_lengths_compare_to_nothing() {
        assert_eq!(cosine(&kept(&[1.0, 0.0]), &query_bytes(&[1.0, 0.0, 0.0])), None);
    }
}
