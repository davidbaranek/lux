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
//! A store that may discard its file ([`File::discard`]) makes a new one in place of a file it
//! cannot use: on opening, and after a job that found it damaged, before the next job.

use lux_core::gone::OtherEndGone;
use std::mem;
use std::sync::mpsc;
use std::thread::{self, JoinHandle};

use rusqlite::Connection;
use tokio::sync::{oneshot, watch};

use crate::exit::{self, Call};
use crate::{Error, Result};

/// Runs on the connection (or the error opening it), answers its caller, and says whether it
/// found the file damaged.
type Job = Box<dyn FnOnce(Result<&mut Connection>) -> Found + Send>;

/// What a job found of the file.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Found {
    Whole,
    Damaged,
}

/// Removes the store's files: a new one is made in their place.
pub(crate) type Discard = Box<dyn Fn() -> Result<()> + Send>;

enum Message {
    Run(Job),
    /// Closes the connection, then answers.
    Release(oneshot::Sender<()>),
    /// Closes the connection and ends the thread, then answers (when asked to).
    Stop(Option<oneshot::Sender<()>>),
}

/// The store's file, as the thread opens it.
struct File<Open> {
    open: Open,
    /// Present when the store is a cache: a file it cannot use gives way to a new one.
    discard: Option<Discard>,
}

impl<Open: Fn() -> Result<Connection>> File<Open> {
    /// The connection, and whether it is to a new file made in place of one it could not use.
    fn open(&self) -> Result<(Connection, bool)> {
        match (self.open)() {
            Err(error) if error.is_unusable_file() && self.discard.is_some() => {
                self.remove()?;
                (self.open)().map(|connection| (connection, true))
            }
            opened => opened.map(|connection| (connection, false)),
        }
    }

    /// Closes `connection` and removes its damaged file, if the store may; true when it did.
    fn discard(&self, connection: &mut Option<Connection>) -> bool {
        if self.discard.is_none() {
            return false;
        }
        *connection = None;
        // a file that cannot be removed (no permission) stays: the next job finds it again.
        self.remove().is_ok()
    }

    fn remove(&self) -> Result<()> {
        self.discard.as_ref().map_or(Ok(()), |discard| discard())
    }
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
    /// release. With `discard`, a file the store cannot use gives way to a new one.
    pub(crate) async fn start(
        open: impl Fn() -> Result<Connection> + Send + 'static,
        discard: Option<Discard>,
    ) -> Result<Self> {
        let file = File { open, discard };
        let (messages, inbox) = mpsc::channel::<Message>();
        let (opened, opening) = oneshot::channel();
        let (replaced, replacements) = watch::channel(0_u64);
        exit::watch();
        let thread = thread::Builder::new().name("lux-store".into()).spawn(move || {
            let Some(first) = Call::begin() else {
                opened
                    .send(Err(Error::Closed))
                    .other_end_may_be_gone("the store's opener");
                return;
            };
            let mut connection = match file.open() {
                Ok((connection, _)) => {
                    opened.send(Ok(())).other_end_may_be_gone("the store's opener");
                    Some(connection)
                }
                Err(error) => {
                    opened.send(Err(error)).other_end_may_be_gone("the store's opener");
                    return;
                }
            };
            drop(first);
            let replace = || replaced.send_modify(|count| *count += 1);
            for message in inbox {
                // each message runs in SQLite: opening, a job, closing.
                let Some(_call) = Call::begin() else {
                    // the process is exiting, SQLCipher's memory freed or about to be: the
                    // connection is left open (closing it calls SQLite), the process takes it.
                    mem::forget(connection);
                    return;
                };
                match message {
                    Message::Run(job) => {
                        let found = match &mut connection {
                            Some(connection) => job(Ok(connection)),
                            None => match file.open() {
                                Ok((opened, new)) => {
                                    if new {
                                        replace();
                                    }
                                    job(Ok(connection.insert(opened)))
                                }
                                Err(error) => job(Err(error)),
                            },
                        };
                        if found == Found::Damaged && file.discard(&mut connection) {
                            replace();
                        }
                    }
                    Message::Release(done) => {
                        connection = None;
                        done.send(()).other_end_may_be_gone("the caller");
                    }
                    Message::Stop(done) => {
                        drop(connection);
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
    /// the file is damaged comes back as [`Error::Damaged`].
    pub(crate) async fn run<T: Send + 'static>(
        &self,
        job: impl FnOnce(&mut Connection) -> Result<T> + Send + 'static,
    ) -> Result<T> {
        let (answer, answered) = oneshot::channel();
        self.messages
            .send(Message::Run(Box::new(move |connection| {
                let result = connection.and_then(|connection| job(connection).map_err(Error::examined));
                let found = if matches!(result, Err(Error::Damaged)) {
                    Found::Damaged
                } else {
                    Found::Whole
                };
                answer.send(result).other_end_may_be_gone("the caller");
                found
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
