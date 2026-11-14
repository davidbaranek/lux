//! The runtime the core runs on.
//!
//! UniFFI polls each exported future inside `async-compat`'s Tokio runtime, made on the first
//! call. Left alone that runtime has one thread, and the sync, decryption, the lists' tasks and
//! the listeners' calls into Swift would all wait on each other. [`start_core`] sets how it is made.
//!
//! A few workers: the listeners' calls into Swift may come from any of them, at once, so the
//! Swift side takes them as `Sendable` values (checked by Swift 6, and by Thread Sanitizer on the
//! demo). Blocking work (stores, files) has its own pool.

use std::sync::Once;

use tokio::runtime::{Builder, Handle};

/// Which process the core runs in.
#[derive(Clone, Copy, Debug, uniffi::Enum)]
pub enum CoreProcess {
    /// The app.
    App,
    /// The notification extension, in its small memory: small stacks, few blocking threads.
    NotificationExtension,
}

/// Sets how the core's runtime is made. Call it before any other call into the core; a later
/// call changes nothing.
#[uniffi::export]
pub fn start_core(process: CoreProcess) {
    static START: Once = Once::new();
    START.call_once(|| async_compat::set_runtime_builder(Box::new(move || builder(process))));
}

fn builder(process: CoreProcess) -> Builder {
    let mut builder = Builder::new_multi_thread();
    builder.enable_all().thread_name("lux-core");
    match process {
        CoreProcess::App => {
            let cores = std::thread::available_parallelism().map_or(2, usize::from);
            builder.worker_threads(cores.clamp(2, 4)).max_blocking_threads(32);
        }
        CoreProcess::NotificationExtension => {
            // as the SDK's own lightweight runtime: 1 MiB is ample for its futures.
            builder
                .worker_threads(2)
                .max_blocking_threads(2)
                .thread_stack_size(1024 * 1024);
        }
    }
    builder
}

/// The core's runtime, from any thread: the one the exported futures run on.
pub(crate) fn handle() -> Handle {
    async_compat::get_runtime_handle()
}
