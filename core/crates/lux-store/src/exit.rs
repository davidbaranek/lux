//! The process's exit and the stores' threads.
//!
//! The apps close their stores before the process exits: the Mac as it quits, the iPhone as the
//! system ends it, the view tests' host as its tests end. This is the backstop for an exit that
//! comes while a store is open all the same (the app's close ran out of time, an exit nobody
//! announced). SQLCipher frees its ciphers and their memory in an exit handler of its own
//! (`atexit`), while other threads still run: a store's thread in a commit then encrypts pages
//! with freed memory and crashes (`sqlite3Codec` in `walWriteOneFrame`). So a handler that runs
//! before SQLCipher's waits a moment for the stores' SQLite calls under way, then lets the exit
//! go on. From then on no store's thread enters SQLite: one asked for a call ends instead, its
//! connection left open (closing it is a call too), so a store dropped later in the exit (by
//! another exit handler, a thread-local's destructor) ends its thread without waiting.

use std::sync::{Condvar, Mutex, MutexGuard, Once, PoisonError, WaitTimeoutResult};
use std::time::Duration;

/// How long the exit waits for the calls under way: a call waiting for another process's lock
/// (`busy_timeout`) or a long statement does not hold the app's quitting for longer.
const HOLD: Duration = Duration::from_secs(2);

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

/// A store's thread is in SQLite until it drops this.
pub(crate) struct Call(());

impl Call {
    /// The call, or none once the process is exiting: the thread then calls SQLite no more.
    pub(crate) fn begin() -> Option<Self> {
        let mut calls = calls();
        if calls.exiting {
            return None;
        }
        calls.running += 1;
        Some(Self(()))
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

/// Lets no call begin, and waits for those under way, at most [`HOLD`].
extern "C" fn hold_calls() {
    let mut calls = calls();
    calls.exiting = true;
    // the exit goes on whether the calls ended or the time ran out; the lock is let go here.
    let (calls, _): (MutexGuard<'static, Calls>, WaitTimeoutResult) = ENDED
        .wait_timeout_while(calls, HOLD, |calls| calls.running > 0)
        .unwrap_or_else(PoisonError::into_inner);
    drop(calls);
}
