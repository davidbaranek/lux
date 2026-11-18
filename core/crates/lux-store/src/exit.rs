//! The process's exit and the stores' threads.
//!
//! SQLCipher frees its ciphers and their memory in an exit handler of its own (`atexit`), while
//! other threads still run: a store's thread in a commit then encrypts pages with freed memory and
//! crashes (`sqlite3Codec` in `walWriteOneFrame`). Any code may end the process (the app quitting,
//! iOS ending an app that runs in the background, a test runner when its tests end), whatever store
//! is open then. So the exit waits here: a handler that runs before SQLCipher's waits for the
//! stores' SQLite calls under way, and holds every later one until the process is gone.

use std::sync::{Condvar, Mutex, MutexGuard, Once, PoisonError};

/// How many SQLite calls the stores' threads are in, and whether the process is exiting.
struct Calls {
    running: usize,
    exiting: bool,
}

static CALLS: Mutex<Calls> = Mutex::new(Calls {
    running: 0,
    exiting: false,
});
/// Told when a call ends.
static ENDED: Condvar = Condvar::new();
static WATCHING: Once = Once::new();

fn calls() -> MutexGuard<'static, Calls> {
    // nothing panics while holding it: the counts stay whole.
    CALLS.lock().unwrap_or_else(PoisonError::into_inner)
}

fn wait(calls: MutexGuard<'static, Calls>) -> MutexGuard<'static, Calls> {
    ENDED.wait(calls).unwrap_or_else(PoisonError::into_inner)
}

/// A store's thread is in SQLite until it drops this.
pub(crate) struct Call(());

impl Call {
    /// Waits for no exit: once the process is exiting, it waits until the process is gone.
    pub(crate) fn begin() -> Self {
        let mut calls = calls();
        while calls.exiting {
            calls = wait(calls);
        }
        calls.running += 1;
        Self(())
    }
}

impl Drop for Call {
    fn drop(&mut self) {
        calls().running -= 1;
        ENDED.notify_all();
    }
}

/// Makes the process's exit wait for the stores' calls, once. Exit handlers run in the reverse of
/// their order: SQLite starts first (SQLCipher adds its handler then), and this one, added after,
/// runs before it.
#[expect(
    unsafe_code,
    reason = "two C calls without preconditions; the handler is a plain function"
)]
pub(crate) fn watch() {
    WATCHING.call_once(|| {
        // SAFETY: `sqlite3_initialize` may be called from any thread, any number of times, and
        // `atexit` takes a function that lives as long as the program.
        unsafe {
            // its error, if any, is the first open's too, which reports it.
            let _: libc::c_int = rusqlite::ffi::sqlite3_initialize();
            // it fails only without memory for the handler, where nothing else would work either.
            let _: libc::c_int = libc::atexit(hold_calls);
        }
    });
}

/// Waits for the calls under way, and lets no other begin.
extern "C" fn hold_calls() {
    let mut calls = calls();
    calls.exiting = true;
    while calls.running > 0 {
        calls = wait(calls);
    }
}
