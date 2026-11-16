//! The core's log: its `tracing` events, handed to the app, which writes them to the system's
//! unified log beside its own (`Log` in `LuxCore`), so levels, categories and privacy are decided in
//! one place.
//!
//! The core's own crates log from `info` up; the sdk and the other dependencies only warnings and
//! errors, as each event crosses into Swift.

use std::fmt;
use std::sync::Arc;

use tracing::field::{Field, Visit};
use tracing::{Event, Level, Subscriber};
use tracing_subscriber::Layer;
use tracing_subscriber::filter::Targets;
use tracing_subscriber::layer::{Context, SubscriberExt as _};

/// How much an event matters: `tracing`'s levels.
#[derive(Clone, Copy, Debug, PartialEq, Eq, uniffi::Enum)]
pub enum CoreLogLevel {
    /// Very verbose.
    Trace,
    /// For working on the core.
    Debug,
    /// What happened.
    Info,
    /// Something went wrong and the core went on.
    Warn,
    /// Something failed.
    Error,
}

impl From<Level> for CoreLogLevel {
    fn from(level: Level) -> Self {
        match level {
            Level::TRACE => Self::Trace,
            Level::DEBUG => Self::Debug,
            Level::INFO => Self::Info,
            Level::WARN => Self::Warn,
            Level::ERROR => Self::Error,
        }
    }
}

/// One event of the core's log.
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct CoreLogEvent {
    /// How much it matters.
    pub level: CoreLogLevel,
    /// Where it comes from: the module's path (`lux_matrix::room_list`, `matrix_sdk::…`).
    pub target: String,
    /// What happened: the event's fixed text, written in the code.
    pub message: String,
    /// The event's values (`error=…`, `room=…`): they may name people, rooms or servers.
    pub fields: String,
}

/// Writes the core's log: the app's, to the unified log.
#[uniffi::export(with_foreign)]
pub trait CoreLogSink: Send + Sync {
    /// One event, on whichever thread logged it.
    fn log(&self, event: CoreLogEvent);
}

/// The log's levels: the core's crates from `info`, everything else from `warn`.
fn targets() -> Targets {
    Targets::new()
        .with_default(Level::WARN)
        .with_target("lux_core", Level::INFO)
        .with_target("lux_matrix", Level::INFO)
        .with_target("lux_store", Level::INFO)
        .with_target("lux_ffi", Level::INFO)
}

/// Sends the core's log to `sink` from now on. The first call wins: a process has one log.
pub(crate) fn install(sink: Arc<dyn CoreLogSink>) {
    let subscriber = tracing_subscriber::registry().with(SinkLayer { sink }.with_filter(targets()));
    // a second call (or a test's own subscriber) keeps the one already set.
    if tracing::subscriber::set_global_default(subscriber).is_err() {
        tracing::debug!("the core's log already goes to a sink: this one is not used");
    }
}

struct SinkLayer {
    sink: Arc<dyn CoreLogSink>,
}

impl<S: Subscriber> Layer<S> for SinkLayer {
    fn on_event(&self, event: &Event<'_>, _: Context<'_, S>) {
        let metadata = event.metadata();
        let mut visitor = Fields::default();
        event.record(&mut visitor);
        self.sink.log(CoreLogEvent {
            level: (*metadata.level()).into(),
            target: metadata.target().to_owned(),
            message: visitor.message,
            fields: visitor.fields,
        });
    }
}

/// An event's message apart from its other values, written `name=value`.
#[derive(Default)]
struct Fields {
    message: String,
    fields: String,
}

impl Visit for Fields {
    fn record_str(&mut self, field: &Field, value: &str) {
        self.record(field, format_args!("{value}"));
    }

    fn record_debug(&mut self, field: &Field, value: &dyn fmt::Debug) {
        self.record(field, format_args!("{value:?}"));
    }
}

impl Fields {
    fn record(&mut self, field: &Field, value: fmt::Arguments<'_>) {
        if field.name() == "message" {
            self.message.push_str(&value.to_string());
        } else {
            if !self.fields.is_empty() {
                self.fields.push(' ');
            }
            self.fields.push_str(field.name());
            self.fields.push('=');
            self.fields.push_str(&value.to_string());
        }
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Mutex;

    use super::*;

    #[derive(Default)]
    struct Kept(Mutex<Vec<CoreLogEvent>>);

    impl CoreLogSink for Kept {
        fn log(&self, event: CoreLogEvent) {
            self.0.lock().unwrap().push(event);
        }
    }

    #[test]
    fn events_reach_the_sink_by_level_and_target() {
        let kept = Arc::new(Kept::default());
        let subscriber = tracing_subscriber::registry().with(SinkLayer { sink: kept.clone() }.with_filter(targets()));
        tracing::subscriber::with_default(subscriber, || {
            let error = "the server went away";
            tracing::warn!(target: "lux_matrix::room_list", %error, room = "!a:b", "the list is not available");
            tracing::info!(target: "lux_matrix::sync", "synced");
            tracing::debug!(target: "lux_matrix::sync", "not kept");
            tracing::info!(target: "matrix_sdk::sync", "not kept");
            tracing::error!(target: "matrix_sdk::crypto", "kept");
        });
        let events = kept.0.lock().unwrap();
        assert_eq!(
            *events,
            vec![
                CoreLogEvent {
                    level: CoreLogLevel::Warn,
                    target: "lux_matrix::room_list".into(),
                    message: "the list is not available".into(),
                    fields: "error=the server went away room=!a:b".into(),
                },
                CoreLogEvent {
                    level: CoreLogLevel::Info,
                    target: "lux_matrix::sync".into(),
                    message: "synced".into(),
                    fields: String::new(),
                },
                CoreLogEvent {
                    level: CoreLogLevel::Error,
                    target: "matrix_sdk::crypto".into(),
                    message: "kept".into(),
                    fields: String::new(),
                },
            ]
        );
    }
}
