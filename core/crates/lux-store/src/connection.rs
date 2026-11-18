//! The thread that owns the connection: callers send it jobs and await their answers, so SQLite's
//! blocking calls never run on an async runtime and the connection needs no lock.
//!
//! The connection can be let go ([`Worker::release`]) while the app is in the background, where
//! iOS ends an app that holds a lock on a file in a shared container; the next job opens it again.
//!
//! [`Worker::close`] ends the thread and awaits it, blocking no thread meanwhile. A handle dropped
//! without it stops the thread and waits for it there. A process that exits while the thread runs
//! waits a moment for its call in SQLite, and the thread then ends at its next message, without
//! calling SQLite again ([`crate::exit`]).
//!
//! An error that speaks against the file is weighed on the thread ([`File::weigh`]). SQLite's
//! "malformed" and "not a database" prove it damaged. SQLCipher's failed page check reads as "out
//! of memory", as a failed allocation or a failed encryption does, and a migration's SQL error
//! may be another process's migration: those are suspicions, which hold only if the file, opened
//! anew, fails again or does not pass SQLite's check. A store that may discard its file (only the
//! process that owns it, and only a cache) makes a new one in place of a damaged file, a few times
//! an hour at most: damage that comes back sooner is a bug to find (an FTS index out of step with
//! its table), not a file to throw away again and again.

use std::mem;
use std::sync::mpsc;
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use lux_core::gone::OtherEndGone;
use rusqlite::Connection;
use tokio::sync::{oneshot, watch};
use tracing::{error, info, warn};

use crate::error::Evidence;
use crate::exit::{self, Call};
use crate::{Error, Result};

/// Runs on the store's file and its connection, and answers its caller.
type Job = Box<dyn FnOnce(&mut File) + Send>;

/// Opens the store's file: keyed, read, its schema brought up to date.
pub(crate) type Open = Box<dyn Fn() -> Result<Connection> + Send>;

/// Removes the store's files: a new one is made in their place.
pub(crate) type Discard = Box<dyn Fn() -> Result<()> + Send>;

/// How many new files a store makes in place of damaged ones within [`RECENTLY`]; a file damaged
/// again after that stays.
const MAX_REPLACEMENTS: usize = 2;
const RECENTLY: Duration = Duration::from_hours(1);

enum Message {
    Run(Job),
    /// Closes the connection, then answers.
    Release(oneshot::Sender<()>),
    /// Closes the connection and ends the thread, then answers (when asked to).
    Stop(Option<oneshot::Sender<()>>),
}

/// What became of the file after an error.
enum Outcome {
    /// The error says nothing against the file, or its suspicion did not hold: the file stays.
    Kept(Error),
    /// The file cannot be used, and stays: the store may not discard it, or did so too often
    /// lately.
    Damaged(Error),
    /// The file could not be used, and a new one takes its place at the next open.
    Replaced(Error),
}

/// The store's file, as the thread holds it.
struct File {
    open: Open,
    /// Present when this process owns the file and it is a cache: a damaged file gives way to a
    /// new one.
    discard: Option<Discard>,
    connection: Option<Connection>,
    /// When the store made a new file in place of a damaged one, the latest last.
    replacements: Vec<Instant>,
    /// Counts them for [`Worker::replaced`].
    replaced: watch::Sender<u64>,
}

impl File {
    /// The connection, opened if it is not.
    fn connection(&mut self) -> Result<&mut Connection> {
        let connection = match self.connection.take() {
            Some(connection) => connection,
            None => self.opened()?,
        };
        Ok(self.connection.insert(connection))
    }

    /// A new connection; a failure that speaks against the file is weighed, and a file that gave
    /// way is made anew.
    fn opened(&mut self) -> Result<Connection> {
        let error = match (self.open)() {
            Ok(connection) => return Ok(connection),
            Err(error) => error,
        };
        match self.weigh(error) {
            // a suspicion that did not hold leaves the connection that passed the check.
            Outcome::Kept(error) => self.connection.take().ok_or(error),
            Outcome::Damaged(error) => Err(error),
            Outcome::Replaced(_) => (self.open)(),
        }
    }

    /// Runs `job` on the connection; its error, if it speaks against the file, is weighed.
    fn run<T>(&mut self, job: impl FnOnce(&mut Connection) -> Result<T>) -> Result<T> {
        let result = job(self.connection()?);
        result.map_err(|error| match self.weigh(error) {
            Outcome::Kept(error) | Outcome::Damaged(error) | Outcome::Replaced(error) => error,
        })
    }

    /// Weighs what `error` says against the file and acts on it: a file proven or confirmed
    /// damaged gives way to a new one, if the store may, and the error says it is damaged.
    fn weigh(&mut self, error: Error) -> Outcome {
        match error.evidence() {
            Evidence::None => return Outcome::Kept(error),
            Evidence::Proof => {}
            Evidence::Suspicion => {
                if !self.confirm() {
                    info!(code = error.extended_code(), %error, "the store's file passed its check after the error");
                    return Outcome::Kept(error);
                }
            }
        }
        let code = error.extended_code();
        let error = error.damage();
        self.connection = None;
        let Some(discard) = &self.discard else {
            warn!(code, %error, "the store cannot use its file");
            return Outcome::Damaged(error);
        };
        let now = Instant::now();
        self.replacements.retain(|at| now.duration_since(*at) < RECENTLY);
        if self.replacements.len() >= MAX_REPLACEMENTS {
            error!(
                code,
                %error,
                replaced = self.replacements.len(),
                "the store's file is damaged again so soon: it stays, for its cause to be found"
            );
            return Outcome::Damaged(error);
        }
        if let Err(removing) = discard() {
            // a file that cannot be removed (no permission) stays: the next call finds it again.
            warn!(code, %error, %removing, "the store cannot use its file, and cannot remove it");
            return Outcome::Damaged(error);
        }
        self.replacements.push(now);
        self.replaced.send_modify(|count| *count += 1);
        warn!(code, %error, "the store cannot use its file: a new one takes its place");
        Outcome::Replaced(error)
    }

    /// Whether a suspicion holds: the file opened anew (SQLCipher's state anew, another
    /// process's migration done meanwhile) fails again, or does not pass SQLite's check. A new
    /// connection that passes it stays.
    fn confirm(&mut self) -> bool {
        self.connection = None;
        let connection = match (self.open)() {
            Ok(connection) => connection,
            Err(error) => return error.evidence() != Evidence::None,
        };
        match check(&connection) {
            Ok(true) => {
                self.connection = Some(connection);
                false
            }
            Ok(false) => true,
            Err(error) => error.evidence() != Evidence::None,
        }
    }
}

/// Whether SQLite reads every page in use, each passing SQLCipher's check, and finds the file
/// whole. `quick_check` reads them through the write-ahead log, where a damaged commit stays until
/// a checkpoint; SQLCipher's own `cipher_integrity_check` reads the main file only.
fn check(connection: &Connection) -> Result<bool> {
    let mut statement = connection.prepare("PRAGMA quick_check")?;
    let lines = statement
        .query_map([], |row| row.get::<_, String>(0))?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    Ok(lines == ["ok"])
}

/// The handle to the connection's thread. Dropping it ends the thread, after the jobs sent
/// before, and waits until the connection is closed.
#[derive(Debug)]
pub(crate) struct Worker {
    messages: mpsc::Sender<Message>,
    /// How many times the thread made a new file in place of a damaged one.
    replacements: watch::Receiver<u64>,
    thread: Option<JoinHandle<()>>,
}

impl Worker {
    /// Starts the thread and opens the connection on it with `open`, which opens it again after a
    /// release. With `discard`, a damaged file gives way to a new one.
    pub(crate) async fn start(open: Open, discard: Option<Discard>) -> Result<Self> {
        let (messages, inbox) = mpsc::channel::<Message>();
        let (opened, opening) = oneshot::channel();
        let (replaced, replacements) = watch::channel(0_u64);
        let mut file = File {
            open,
            discard,
            connection: None,
            replacements: Vec::new(),
            replaced,
        };
        exit::watch();
        let thread = thread::Builder::new().name("lux-store".into()).spawn(move || {
            let Some(first) = Call::begin() else {
                opened
                    .send(Err(Error::Closed))
                    .other_end_may_be_gone("the store's opener");
                return;
            };
            let first_open = file.connection().map(|_| ());
            let failed = first_open.is_err();
            opened.send(first_open).other_end_may_be_gone("the store's opener");
            drop(first);
            if failed {
                return;
            }
            for message in inbox {
                // each message runs in SQLite: opening, a job, closing.
                let Some(_call) = Call::begin() else {
                    // the process is exiting, SQLCipher's memory freed or about to be: the
                    // connection is left open (closing it calls SQLite), the process takes it.
                    mem::forget(file.connection.take());
                    return;
                };
                match message {
                    Message::Run(job) => job(&mut file),
                    Message::Release(done) => {
                        file.connection = None;
                        done.send(()).other_end_may_be_gone("the caller");
                    }
                    Message::Stop(done) => {
                        drop(file);
                        if let Some(done) = done {
                            done.send(()).other_end_may_be_gone("the caller");
                        }
                        return;
                    }
                }
            }
        })?;
        opening.await.map_err(|_| Error::Closed)??;
        Ok(Self {
            messages,
            replacements,
            thread: Some(thread),
        })
    }

    /// Runs `job` on the connection's thread, after the jobs sent before it. An error that says
    /// the file is damaged, proven or confirmed, comes back as [`Error::Damaged`].
    pub(crate) async fn run<T: Send + 'static>(
        &self,
        job: impl FnOnce(&mut Connection) -> Result<T> + Send + 'static,
    ) -> Result<T> {
        let (answer, answered) = oneshot::channel();
        self.messages
            .send(Message::Run(Box::new(move |file: &mut File| {
                answer.send(file.run(job)).other_end_may_be_gone("the caller");
            })))
            .map_err(|_| Error::Closed)?;
        answered.await.map_err(|_| Error::Closed)?
    }

    /// Ready when the thread has made a new file in place of a damaged one, after this call
    /// (not after the first poll).
    pub(crate) fn replaced(&self) -> impl Future<Output = Result<()>> + Send + use<> {
        let mut replacements = self.replacements.clone();
        replacements.mark_unchanged();
        // the thread's end drops the sender.
        async move { replacements.changed().await.map_err(|_| Error::Closed) }
    }

    /// Closes the connection after the jobs sent before, and ends the thread; later jobs fail
    /// with [`Error::Closed`]. The handle's drop then has nothing to wait for.
    pub(crate) async fn close(&self) {
        let (done, closed) = oneshot::channel();
        // a thread already ended answers nothing: it is closed.
        if self.messages.send(Message::Stop(Some(done))).is_ok() {
            closed.await.other_end_may_be_gone("the store's thread");
        }
    }

    /// Closes the connection after the jobs sent before; the next job opens it again.
    pub(crate) async fn release(&self) -> Result<()> {
        let (done, released) = oneshot::channel();
        self.messages.send(Message::Release(done)).map_err(|_| Error::Closed)?;
        released.await.map_err(|_| Error::Closed)
    }
}

impl Drop for Worker {
    fn drop(&mut self) {
        // a thread that failed to open, or was closed, has ended already, and the send fails.
        self.messages
            .send(Message::Stop(None))
            .other_end_may_be_gone("the store's thread");
        if let Some(thread) = self.thread.take() {
            // a panic in a job has already been reported on its thread.
            thread.join().other_end_may_be_gone("the store's thread");
        }
    }
}
