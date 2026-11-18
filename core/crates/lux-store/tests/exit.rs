//! The process ending while a store writes: SQLCipher frees its ciphers' memory as the process
//! exits, so a commit still running then would read freed memory.

#![allow(
    clippy::unwrap_used,
    clippy::panic,
    reason = "a test's helpers fail it as its asserts do"
)]

use std::env;
use std::path::PathBuf;
use std::process::{self, Command};
use std::thread;
use std::time::{Duration, SystemTime};

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

#[test]
fn the_process_exits_cleanly_while_a_store_writes() {
    if let Some(file) = env::var_os(WRITER) {
        write_and_exit(file.into());
    }
    let this = env::current_exe().unwrap();
    // without the wait, about one exit in ten crashes.
    for run in 0..50 {
        let folder = TempDir::new().unwrap();
        let output = Command::new(&this)
            .args([
                "--exact",
                "the_process_exits_cleanly_while_a_store_writes",
                "--nocapture",
            ])
            .env(WRITER, folder.path().join("index.sqlite"))
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "run {run}: the writing process ended with {:?}\n{}",
            output.status,
            String::from_utf8_lossy(&output.stderr)
        );
    }
}
