//! The thread that owns the connection: callers send it jobs and await their answers, so SQLite's
//! blocking calls never run on an async runtime and the connection needs no lock.
//!
//! The connection can be let go ([`Worker::release`]) while the app is in the background, where
//! iOS ends an app that holds a lock on a file in a shared container; the next job opens it again.
//!
//! [`Worker::close`] ends the thread and awaits it, blocking no thread meanwhile. A handle dropped
//! without it stops the thread and waits for it there. A process that exits while the thread runs
//! waits for its call in SQLite, and the thread makes no other ([`crate::exit`]).

use lux_core::gone::OtherEndGone;
use std::sync::mpsc;
use std::thread::{self, JoinHandle};

use rusqlite::Connection;
use tokio::sync::oneshot;

use crate::exit::{self, Call};
use crate::{Error, Result};

type Job = Box<dyn FnOnce(Result<&mut Connection>) + Send>;

enum Message {
    Run(Job),
    /// Closes the connection, then answers.
    Release(oneshot::Sender<()>),
    /// Closes the connection and ends the thread, then answers (when asked to).
    Stop(Option<oneshot::Sender<()>>),
}

/// The handle to the connection's thread. Dropping it ends the thread, after the jobs sent
/// before, and waits until the connection is closed.
#[derive(Debug)]
pub(crate) struct Worker {
    messages: mpsc::Sender<Message>,
    thread: Option<JoinHandle<()>>,
}

impl Worker {
    /// Starts the thread and opens the connection on it with `open`, which opens it again after a
    /// release.
    pub(crate) async fn start(open: impl Fn() -> Result<Connection> + Send + 'static) -> Result<Self> {
        let (messages, inbox) = mpsc::channel::<Message>();
        let (opened, opening) = oneshot::channel();
        exit::watch();
        let thread = thread::Builder::new().name("lux-store".into()).spawn(move || {
            let first = Call::begin();
            let mut connection = match open() {
                Ok(connection) => {
                    opened.send(Ok(())).other_end_may_be_gone("the store's opener");
                    Some(connection)
                }
                Err(error) => {
                    opened.send(Err(error)).other_end_may_be_gone("the store's opener");
                    return;
                }
            };
            drop(first);
            for message in inbox {
                // each message runs in SQLite: opening, a job, closing.
                let _call = Call::begin();
                match message {
                    Message::Run(job) => match &mut connection {
                        Some(connection) => job(Ok(connection)),
                        None => match open() {
                            Ok(opened) => job(Ok(connection.insert(opened))),
                            Err(error) => job(Err(error)),
                        },
                    },
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
            thread: Some(thread),
        })
    }

    /// Runs `job` on the connection's thread, after the jobs sent before it.
    pub(crate) async fn run<T: Send + 'static>(
        &self,
        job: impl FnOnce(&mut Connection) -> Result<T> + Send + 'static,
    ) -> Result<T> {
        let (answer, answered) = oneshot::channel();
        self.messages
            .send(Message::Run(Box::new(move |connection| {
                answer
                    .send(connection.and_then(job))
                    .other_end_may_be_gone("the caller");
            })))
            .map_err(|_| Error::Closed)?;
        answered.await.map_err(|_| Error::Closed)?
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
