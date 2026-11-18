//! The process ending while a store is open: SQLCipher frees its ciphers' memory as the process
//! exits, so a commit still running then would read freed memory, and a store let go after that
//! must not wait for its thread to call SQLite again.

#![allow(
    clippy::unwrap_used,
    clippy::panic,
    reason = "a test's helpers fail it as its asserts do"
)]

use std::env;
use std::path::PathBuf;
use std::process::{self, Command, Stdio};
use std::sync::Mutex;
use std::thread;
use std::time::{Duration, Instant, SystemTime};

use lux_core::timeline::IndexedMessage;
use lux_store::{Key, Store};
use tempfile::TempDir;

/// Set in the process the test starts: it writes, and exits while it does.
const WRITER: &str = "LUX_STORE_EXIT_WRITER";

fn messages(batch: u64) -> Vec<IndexedMessage> {
    (0..200)
        .map(|n| IndexedMessage {
            event_id: format!("$m{batch}-{n}").into(),
            room: "!a:x".into(),
            sender_name: "Anna Nováková".into(),
            body: format!("zpráva {n} z dávky {batch}, a few more words to fill the page"),
            links: Vec::new(),
            thread: None,
            date: SystemTime::UNIX_EPOCH + Duration::from_secs(1_700_000_000 + batch * 1000 + n),
            is_own: false,
        })
        .collect()
}

/// Writes to a store without end on another thread, and exits the process while it does.
fn write_and_exit(file: PathBuf) -> ! {
    let (opened, open) = std::sync::mpsc::channel();
    thread::spawn(move || {
        let runtime = tokio::runtime::Builder::new_current_thread().build().unwrap();
        runtime.block_on(async {
            let store = Store::open(file, Key::from_hex(&"ab".repeat(32)).unwrap())
                .await
                .unwrap();
            opened.send(()).unwrap();
            for batch in 0..=u64::MAX {
                store.add(messages(batch)).await.unwrap();
            }
        });
    });
    open.recv().unwrap();
    thread::sleep(Duration::from_millis(150));
    process::exit(0)
}

/// Set in the process the late-drop test starts: a store is let go by an exit handler that runs
/// after the stores' own.
const LATE_DROPPER: &str = "LUX_STORE_EXIT_LATE_DROPPER";

/// The store the exit handler lets go.
static LATE: Mutex<Option<Store>> = Mutex::new(None);

extern "C" fn drop_late() {
    drop(LATE.lock().unwrap().take());
}

/// Adds an exit handler before any store opens (so it runs after theirs), keeps a store open for
/// it to let go, and exits.
#[expect(unsafe_code, reason = "`atexit` with a plain function")]
fn drop_late_and_exit(file: PathBuf) -> ! {
    // SAFETY: `atexit` takes a function that lives as long as the program.
    let registered = unsafe { libc::atexit(drop_late) };
    assert_eq!(registered, 0);
    let runtime = tokio::runtime::Builder::new_current_thread().build().unwrap();
    let store = runtime.block_on(async {
        let store = Store::open(file, Key::from_hex(&"ab".repeat(32)).unwrap())
            .await
            .unwrap();
        store.add(messages(0)).await.unwrap();
        store
    });
    *LATE.lock().unwrap() = Some(store);
    process::exit(0)
}

/// Runs this test binary's `test` in a process of its own with `variable` set to a store's file,
/// and how it ended; a process still running after a while is ended, and the test fails.
fn run_alone(test: &str, variable: &str) -> process::Output {
    let folder = TempDir::new().unwrap();
    let mut child = Command::new(env::current_exe().unwrap())
        .args(["--exact", test, "--nocapture"])
        .env(variable, folder.path().join("index.sqlite"))
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let started = Instant::now();
    while child.try_wait().unwrap().is_none() {
        if started.elapsed() > Duration::from_secs(30) {
            child.kill().unwrap();
            panic!("the process did not end: its exit waits for a store's thread");
        }
        thread::sleep(Duration::from_millis(20));
    }
    child.wait_with_output().unwrap()
}

#[test]
fn a_store_let_go_late_in_the_exit_ends_without_waiting() {
    if let Some(file) = env::var_os(LATE_DROPPER) {
        drop_late_and_exit(file.into());
    }
    let output = run_alone("a_store_let_go_late_in_the_exit_ends_without_waiting", LATE_DROPPER);
    assert!(
        output.status.success(),
        "the process ended with {:?}\n{}",
        output.status,
        String::from_utf8_lossy(&output.stderr)
    );
}

#[test]
fn the_process_exits_cleanly_while_a_store_writes() {
    if let Some(file) = env::var_os(WRITER) {
        write_and_exit(file.into());
    }
    // without the wait, about one exit in ten crashes.
    for run in 0..50 {
        let output = run_alone("the_process_exits_cleanly_while_a_store_writes", WRITER);
        assert!(
            output.status.success(),
            "run {run}: the writing process ended with {:?}\n{}",
            output.status,
            String::from_utf8_lossy(&output.stderr)
        );
    }
}
