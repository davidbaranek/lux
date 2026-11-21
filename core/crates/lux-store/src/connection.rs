//! The thread that owns the connection: callers send it jobs and await their answers, so SQLite's
//! blocking calls never run on an async runtime and the connection needs no lock.
//!
//! The store pauses ([`Worker::pause`]) while the app is in the background, where iOS ends an app
//! that holds a lock on a file in a shared container (`0xdead10cc`): the statement under way is
//! interrupted (SQLite rolls its transaction back), the connection closes, and every job until
//! [`Worker::resume`] fails with [`Error::Paused`] without touching the file. A job is refused
//! rather than run on a connection opened again, which would hold the file's locks as iOS
//! suspends the app; the next job after the resume opens it again.
//!
//! [`Worker::close`] ends the thread and awaits its connection's close, blocking no thread
//! meanwhile, and nothing waits for the thread to return after it. A handle dropped without it
//! stops the thread and waits for it there. A process that exits while the thread runs
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
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, PoisonError, mpsc};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use lux_core::gone::OtherEndGone;
use rusqlite::{Connection, InterruptHandle};
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
    Pause(oneshot::Sender<()>),
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

/// Whether the store is paused, shared by its handle and its thread.
#[derive(Default)]
struct Pause {
    paused: AtomicBool,
    /// Interrupts the job under way; none between jobs, where an interrupt would stop the
    /// checkpoint that closing the connection makes.
    interrupt: Mutex<Option<InterruptHandle>>,
}

impl std::fmt::Debug for Pause {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("Pause")
            .field("paused", &self.paused)
            .finish_non_exhaustive()
    }
}

impl Pause {
    fn is_paused(&self) -> bool {
        self.paused.load(Ordering::SeqCst)
    }

    fn set_interrupt(&self, handle: Option<InterruptHandle>) {
        // nothing panics while holding it.
        *self.interrupt.lock().unwrap_or_else(PoisonError::into_inner) = handle;
    }

    /// Interrupts the job under way, if any: SQLite rolls its transaction back and the job
    /// fails.
    fn interrupt(&self) {
        if let Some(handle) = &*self.interrupt.lock().unwrap_or_else(PoisonError::into_inner) {
            handle.interrupt();
        }
    }
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
    pause: Arc<Pause>,
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

    /// Runs `job` on the connection; its error, if it speaks against the file, is weighed. A
    /// paused store refuses it, and a job the pause interrupted fails as refused.
    fn run<T>(&mut self, job: impl FnOnce(&mut Connection) -> Result<T>) -> Result<T> {
        if self.pause.is_paused() {
            return Err(Error::Paused);
        }
        let pause = Arc::clone(&self.pause);
        let connection = self.connection()?;
        pause.set_interrupt(Some(connection.get_interrupt_handle()));
        let result = job(connection);
        pause.set_interrupt(None);
        result.map_err(|error| {
            if self.pause.is_paused() && error.interrupted() {
                return Error::Paused;
            }
            match self.weigh(error) {
                Outcome::Kept(error) | Outcome::Damaged(error) | Outcome::Replaced(error) => error,
            }
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
    pause: Arc<Pause>,
    /// The thread, until it is closed: once it has said so, it only returns, and nothing waits for
    /// it. A handle dropped without closing it waits for it there.
    thread: Mutex<Option<JoinHandle<()>>>,
}

impl Worker {
    /// Starts the thread and opens the connection on it with `open`, which opens it again after a
    /// pause. With `discard`, a damaged file gives way to a new one.
    pub(crate) async fn start(open: Open, discard: Option<Discard>) -> Result<Self> {
        let (messages, inbox) = mpsc::channel::<Message>();
        let (opened, opening) = oneshot::channel();
        let (replaced, replacements) = watch::channel(0_u64);
        let pause = Arc::new(Pause::default());
        let mut file = File {
            open,
            discard,
            connection: None,
            replacements: Vec::new(),
            replaced,
            pause: Arc::clone(&pause),
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
                    Message::Pause(done) => {
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
            pause,
            thread: Mutex::new(Some(thread)),
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
        // the connection has closed, and the thread only returns: the last handle, let go on any
        // thread (the main one, for a session), does not wait for it to end.
        drop(self.thread.lock().unwrap_or_else(PoisonError::into_inner).take());
    }

    /// Pauses the store: the statement under way is interrupted, the jobs not yet begun fail
    /// with [`Error::Paused`], and so does every job until [`Worker::resume`]; the connection
    /// closes, and this returns once it has. Nothing holds the file meanwhile.
    pub(crate) async fn pause(&self) -> Result<()> {
        self.pause.paused.store(true, Ordering::SeqCst);
        self.pause.interrupt();
        let (done, paused) = oneshot::channel();
        self.messages.send(Message::Pause(done)).map_err(|_| Error::Closed)?;
        paused.await.map_err(|_| Error::Closed)
    }

    /// Ends a pause: the next job opens the connection again.
    pub(crate) fn resume(&self) {
        self.pause.paused.store(false, Ordering::SeqCst);
    }
}

impl Drop for Worker {
    fn drop(&mut self) {
        // a thread that failed to open, or was closed, has ended already, and the send fails.
        self.messages
            .send(Message::Stop(None))
            .other_end_may_be_gone("the store's thread");
        if let Some(thread) = self.thread.get_mut().unwrap_or_else(PoisonError::into_inner).take() {
            // a panic in a job has already been reported on its thread.
            thread.join().other_end_may_be_gone("the store's thread");
        }
    }
}

#[cfg(test)]
mod tests {
    use std::path::{Path, PathBuf};
    use std::sync::mpsc;

    use rusqlite::Connection;
    use rusqlite::functions::FunctionFlags;
    use tempfile::TempDir;

    use super::Worker;
    use crate::Error;

    /// A plain file in WAL, as the store's, with a table to write in.
    fn opener(path: PathBuf) -> super::Open {
        Box::new(move || {
            let connection = Connection::open(&path)?;
            connection.execute_batch("PRAGMA journal_mode = WAL; CREATE TABLE IF NOT EXISTS t(x);")?;
            Ok(connection)
        })
    }

    /// Whether no connection holds the file: leaving WAL needs every other one closed.
    fn held_by_none(path: &Path) -> bool {
        let other = Connection::open(path).unwrap();
        other
            .query_row("PRAGMA journal_mode = DELETE", [], |row| row.get::<_, String>(0))
            .is_ok_and(|mode| mode == "delete")
    }

    /// A write in flight as the app leaves is cut short, its transaction rolled back, and the
    /// file closed: nothing holds it as iOS suspends the app.
    #[tokio::test]
    async fn a_pause_interrupts_the_write_under_way_and_closes_the_file() {
        let folder = TempDir::new().unwrap();
        let path = folder.path().join("store.sqlite");
        let worker = Worker::start(opener(path.clone()), None).await.unwrap();
        let (began, beginning) = mpsc::channel();
        let writing = worker.run(move |connection| {
            // tells the test from inside the statement: the pause finds it running.
            connection.create_scalar_function("began", 0, FunctionFlags::SQLITE_UTF8, move |_| {
                began.send(()).ok();
                Ok(true)
            })?;
            // an endless write, in one transaction: only an interrupt ends it.
            connection.execute_batch(
                "BEGIN; WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM n WHERE began()) \
                 INSERT INTO t SELECT x FROM n; COMMIT;",
            )?;
            Ok(())
        });
        let pausing = async {
            tokio::task::spawn_blocking(move || beginning.recv())
                .await
                .unwrap()
                .unwrap();
            worker.pause().await.unwrap();
        };
        let (written, ()) = tokio::join!(writing, pausing);
        assert!(matches!(written, Err(Error::Paused)), "{written:?}");
        assert!(held_by_none(&path), "the connection is closed");
        worker.resume();
        let rows = worker
            .run(|connection| Ok(connection.query_row("SELECT count(*) FROM t", [], |row| row.get::<_, i64>(0))?))
            .await
            .unwrap();
        assert_eq!(rows, 0, "the interrupted transaction was rolled back");
    }

    /// A call while paused fails without opening the file again; after the resume it runs.
    #[tokio::test]
    async fn a_paused_store_refuses_calls_until_it_resumes() {
        let folder = TempDir::new().unwrap();
        let path = folder.path().join("store.sqlite");
        let worker = Worker::start(opener(path.clone()), None).await.unwrap();
        worker.pause().await.unwrap();
        let refused = worker
            .run(|connection| Ok(connection.execute("INSERT INTO t VALUES (1)", [])?))
            .await;
        assert!(matches!(refused, Err(Error::Paused)));
        assert!(held_by_none(&path), "the refused call did not open the file");
        worker.resume();
        let inserted = worker
            .run(|connection| Ok(connection.execute("INSERT INTO t VALUES (1)", [])?))
            .await
            .unwrap();
        assert_eq!(inserted, 1);
    }
}
