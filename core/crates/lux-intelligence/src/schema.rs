//! An answer's JSON Schema, from its type.

use schemars::JsonSchema;
use schemars::generate::SchemaSettings;
use serde_json::Value;

/// The JSON Schema of `T`, with every subschema inline and no meta-schema, so a model's adapter
/// can map it without resolving references.
#[must_use]
pub fn schema_of<T: JsonSchema>() -> Value {
    let generator = SchemaSettings::draft2020_12()
        .with(|settings| {
            settings.inline_subschemas = true;
            settings.meta_schema = None;
        })
        .into_generator();
    generator.into_root_schema_for::<T>().to_value()
}
