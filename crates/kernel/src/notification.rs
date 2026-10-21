// Copyright (C) 2026  Ryan.K
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Coalesced nonblocking wake hints. Payloads stay in the bounded state queue.
//!
//! The writer sends at most one byte per arm. One-byte writes have no partial
//! case: `Ok(1)` delivers, `WouldBlock` means a hint is already buffered,
//! `Interrupted` is retried a bounded number of times, and anything else breaks
//! the channel. A broken channel shuts down its write side so the reader sees EOF
//! and falls back to polling or re-registration.

use crate::{Error, Kernel};
use std::io::{self, ErrorKind, Write};
use std::net::Shutdown;
use std::os::unix::net::UnixStream;

/// Bounded retries for interrupted writes.
const WRITE_ATTEMPTS: usize = 4;

/// Make writes to `stream` return `EPIPE` instead of raising `SIGPIPE`.
///
/// Apple has no `MSG_NOSIGNAL`, and std does not set `SO_NOSIGPIPE` for socket
/// pairs, so the option is set here.
#[cfg(target_vendor = "apple")]
fn suppress_sigpipe(stream: &UnixStream) -> io::Result<()> {
    socket2::SockRef::from(stream).set_nosigpipe(true)
}

/// std documents that `UnixStream` writes pass `MSG_NOSIGNAL` on these targets
/// (the same list as std's own `cfg`). The writer only uses `write`.
#[cfg(any(
    target_os = "linux",
    target_os = "android",
    target_os = "hurd",
    target_os = "dragonfly",
    target_os = "freebsd",
    target_os = "openbsd",
    target_os = "netbsd",
    target_os = "solaris",
    target_os = "illumos",
    target_os = "haiku",
    target_os = "nto",
    target_os = "cygwin",
))]
fn suppress_sigpipe(_stream: &UnixStream) -> io::Result<()> {
    Ok(())
}

/// No known way to suppress `SIGPIPE` per socket: refuse to attach.
#[cfg(not(any(
    target_vendor = "apple",
    target_os = "linux",
    target_os = "android",
    target_os = "hurd",
    target_os = "dragonfly",
    target_os = "freebsd",
    target_os = "openbsd",
    target_os = "netbsd",
    target_os = "solaris",
    target_os = "illumos",
    target_os = "haiku",
    target_os = "nto",
    target_os = "cygwin",
)))]
fn suppress_sigpipe(_stream: &UnixStream) -> io::Result<()> {
    Err(io::Error::from(ErrorKind::Unsupported))
}

/// What one write attempt means for the channel.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Attempt {
    /// A hint is buffered for the reader.
    Armed,
    /// Interrupted before writing; try again.
    Retry,
    /// The channel cannot deliver hints any more.
    Broken,
}

fn classify(result: &io::Result<usize>) -> Attempt {
    match result {
        Ok(1) => Attempt::Armed,
        Err(error) if error.kind() == ErrorKind::WouldBlock => Attempt::Armed,
        Err(error) if error.kind() == ErrorKind::Interrupted => Attempt::Retry,
        Ok(_) | Err(_) => Attempt::Broken,
    }
}

/// The write side of a wake channel.
pub(crate) trait Channel {
    /// Try to write one hint byte without blocking.
    fn send_hint(&mut self) -> io::Result<usize>;
    /// Shut down the write side so the reader sees EOF.
    fn close(&mut self);
}

impl Channel for UnixStream {
    fn send_hint(&mut self) -> io::Result<usize> {
        self.write(&[1])
    }

    fn close(&mut self) {
        let _ = self.shutdown(Shutdown::Write);
    }
}

pub(crate) struct Writer<C = UnixStream> {
    channel: C,
    armed: bool,
    broken: bool,
}

impl<C: Channel> Writer<C> {
    fn new(channel: C) -> Self {
        Self {
            channel,
            armed: false,
            broken: false,
        }
    }

    /// Post: `armed`, or `broken` with the channel closed.
    fn signal(&mut self) {
        if self.armed || self.broken {
            return;
        }
        for _ in 0..WRITE_ATTEMPTS {
            match classify(&self.channel.send_hint()) {
                Attempt::Armed => {
                    self.armed = true;
                    return;
                }
                Attempt::Retry => {}
                Attempt::Broken => break,
            }
        }
        // Failure or repeated interruption: work must not be stranded without a hint.
        self.broken = true;
        self.channel.close();
    }
}

/// The registered writer, if any. Every field combination is valid, so a poisoned
/// notifier lock is always recovered.
pub(crate) struct Notifier<C = UnixStream> {
    writer: Option<Writer<C>>,
    disabled: bool,
}

impl<C> Default for Notifier<C> {
    fn default() -> Self {
        Self {
            writer: None,
            disabled: false,
        }
    }
}

impl<C: Channel> Notifier<C> {
    pub(crate) fn signal(&mut self) {
        if let Some(writer) = &mut self.writer {
            writer.signal();
        }
    }

    pub(crate) fn rearm(&mut self) {
        if let Some(writer) = &mut self.writer {
            writer.armed = false;
        }
    }

    pub(crate) fn is_broken(&self) -> bool {
        self.writer.as_ref().is_some_and(|writer| writer.broken)
    }

    /// Register `writer`, returning the replaced one; `Err` once disabled.
    fn install(&mut self, writer: Writer<C>) -> Result<Option<Writer<C>>, Writer<C>> {
        if self.disabled {
            return Err(writer);
        }
        Ok(self.writer.replace(writer))
    }

    /// Permanently stop hints; the returned writer is closed by dropping it.
    pub(crate) fn disable(&mut self) -> Option<Writer<C>> {
        self.disabled = true;
        self.writer.take()
    }

    fn detach(&mut self) -> Option<Writer<C>> {
        self.writer.take()
    }
}

impl Kernel {
    /// Register one frontend wake channel, replacing any previous registration.
    ///
    /// Protocol: read until WouldBlock BEFORE drain; if drain reports Busy, retry it
    /// without waiting for another wake. A successful partial drain hints remaining
    /// work. EOF means the channel broke or the kernel shut down: poll instead or
    /// re-register. Returns `Closed` after shutdown and `NotificationIo` where hint
    /// writes cannot be kept from raising `SIGPIPE`.
    pub fn attach_notifications(&self) -> Result<UnixStream, Error> {
        // Stopping never reverts: after shutdown the answer is Closed, not the
        // Busy a worker still holding the lock would cause.
        if self.shared.is_stopping() {
            return Err(Error::Closed);
        }
        let (reader, writer) = UnixStream::pair().map_err(|_| Error::NotificationIo)?;
        reader
            .set_nonblocking(true)
            .map_err(|_| Error::NotificationIo)?;
        writer
            .set_nonblocking(true)
            .map_err(|_| Error::NotificationIo)?;
        suppress_sigpipe(&writer).map_err(|_| Error::NotificationIo)?;
        let state = self.state()?;
        // Checked again under the lock, so shutdown and registration cannot cross.
        if self.shared.is_stopping() {
            return Err(Error::Closed);
        }
        let replaced = {
            let mut notifier = self.shared.notifier();
            let replaced = notifier
                .install(Writer::new(writer))
                .map_err(|_| Error::Closed)?;
            if state.has_ready() {
                notifier.signal();
            }
            replaced
        };
        drop(state);
        drop(replaced);
        Ok(reader)
    }

    /// Unregister the wake channel; its reader then sees EOF. Never `Busy`.
    pub fn detach_notifications(&self) -> Result<(), Error> {
        let writer = self.shared.notifier().detach();
        drop(writer);
        Ok(())
    }
}

impl crate::Shared {
    pub(crate) fn notifier(&self) -> std::sync::MutexGuard<'_, Notifier> {
        self.notifier
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::VecDeque;
    use std::io::Read;

    fn pair() -> (UnixStream, Writer) {
        let (reader, writer) = UnixStream::pair().unwrap();
        reader.set_nonblocking(true).unwrap();
        writer.set_nonblocking(true).unwrap();
        suppress_sigpipe(&writer).unwrap();
        (reader, Writer::new(writer))
    }

    /// A channel that replays scripted write results and records closing.
    #[derive(Default)]
    struct Script {
        results: VecDeque<io::Result<usize>>,
        writes: usize,
        closed: bool,
    }

    impl Channel for Script {
        fn send_hint(&mut self) -> io::Result<usize> {
            self.writes += 1;
            self.results.pop_front().unwrap_or(Ok(1))
        }

        fn close(&mut self) {
            self.closed = true;
        }
    }

    #[test]
    fn write_results_are_classified_exhaustively() {
        let error = |kind| Err(io::Error::from(kind));
        let table = [
            (Ok(1), Attempt::Armed),
            (Ok(0), Attempt::Broken),
            (Ok(2), Attempt::Broken),
            (error(ErrorKind::WouldBlock), Attempt::Armed),
            (error(ErrorKind::Interrupted), Attempt::Retry),
            (error(ErrorKind::BrokenPipe), Attempt::Broken),
            (error(ErrorKind::Other), Attempt::Broken),
        ];
        for (result, expected) in table {
            assert_eq!(classify(&result), expected, "{result:?}");
        }
    }

    // Regression: a write error used to set `broken` without shutting the writer
    // down, so the reader never saw EOF and waited for hints forever.
    #[test]
    fn every_broken_write_closes_the_channel_and_only_those() {
        let error = |kind| Err(io::Error::from(kind));
        let interrupted = || error(ErrorKind::Interrupted);
        // (script, writes, armed, broken and closed)
        let table: Vec<(Vec<io::Result<usize>>, usize, bool, bool)> = vec![
            (vec![Ok(1)], 1, true, false),
            (vec![error(ErrorKind::WouldBlock)], 1, true, false),
            (vec![interrupted(), Ok(1)], 2, true, false),
            (vec![Ok(0)], 1, false, true),
            (vec![error(ErrorKind::BrokenPipe)], 1, false, true),
            (vec![error(ErrorKind::ConnectionReset)], 1, false, true),
            (vec![interrupted(), error(ErrorKind::Other)], 2, false, true),
            (
                (0..WRITE_ATTEMPTS).map(|_| interrupted()).collect(),
                WRITE_ATTEMPTS,
                false,
                true,
            ),
        ];
        for (results, writes, armed, broken) in table {
            let mut writer = Writer::new(Script {
                results: results.into(),
                ..Script::default()
            });
            writer.signal();
            assert_eq!(writer.channel.writes, writes);
            assert_eq!((writer.armed, writer.broken), (armed, broken));
            assert_eq!(writer.channel.closed, broken);
            // A broken or armed writer does not write again until rearmed.
            writer.signal();
            assert_eq!(writer.channel.writes, writes);
        }
    }

    #[test]
    fn signal_coalesces_until_rearmed() {
        let (mut reader, writer) = pair();
        let mut notifier = Notifier::default();
        assert!(notifier.install(writer).ok().flatten().is_none());
        notifier.signal();
        notifier.signal();
        let mut buffer = [0; 8];
        assert_eq!(reader.read(&mut buffer).unwrap(), 1);
        notifier.signal();
        assert_eq!(
            reader.read(&mut buffer).unwrap_err().kind(),
            ErrorKind::WouldBlock
        );
        notifier.rearm();
        notifier.signal();
        assert_eq!(reader.read(&mut buffer).unwrap(), 1);
    }

    #[test]
    fn write_to_a_closed_reader_breaks_the_channel() {
        let (reader, writer) = pair();
        drop(reader);
        let mut notifier = Notifier::default();
        assert!(notifier.install(writer).is_ok());
        notifier.signal();
        assert!(notifier.is_broken());
    }

    #[test]
    fn disabled_notifier_refuses_writers_and_never_writes() {
        let (mut reader, writer) = pair();
        let mut notifier = Notifier::default();
        assert!(notifier.install(writer).is_ok());
        drop(notifier.disable());
        notifier.signal();
        assert_eq!(reader.read(&mut [0; 1]).unwrap(), 0);
        let (_reader, writer) = pair();
        assert!(notifier.install(writer).is_err());
    }
}
