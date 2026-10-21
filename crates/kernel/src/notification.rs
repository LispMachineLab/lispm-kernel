// Copyright (C) 2026  Ryan.K
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Coalesced nonblocking wake hints. Payloads stay in the bounded state queue.
use super::*;
use std::io::{ErrorKind, Write};
use std::net::Shutdown;
use std::os::unix::net::UnixStream;

pub(super) struct Writer {
    stream: UnixStream,
    armed: bool,
    broken: bool,
}
impl Writer {
    pub(super) fn signal(&mut self) {
        if self.armed || self.broken {
            return;
        }
        for _ in 0..4 {
            match self.stream.write(&[1]) {
                Ok(1) => {
                    self.armed = true;
                    return;
                }
                Err(error) if error.kind() == ErrorKind::WouldBlock => {
                    self.armed = true;
                    return;
                }
                Err(error) if error.kind() == ErrorKind::Interrupted => continue,
                _ => {
                    self.broken = true;
                    return;
                }
            }
        }
        // Repeated interruption must not leave work stranded without a hint.
        // EOF tells the frontend to fall back to polling/re-registration.
        self.broken = true;
        let _ = self.stream.shutdown(Shutdown::Write);
    }
    pub(super) fn rearm(&mut self) {
        self.armed = false;
    }
}
impl Kernel {
    /// Register one frontend wake channel, replacing any previous registration.
    /// Read until WouldBlock BEFORE drain; if drain reports Busy, retry it without
    /// waiting for another wake. A successful partial drain signals remaining work.
    pub fn attach_notifications(&self) -> Result<UnixStream, Error> {
        let (reader, writer) = UnixStream::pair().map_err(|_| Error::NotificationIo)?;
        reader
            .set_nonblocking(true)
            .map_err(|_| Error::NotificationIo)?;
        writer
            .set_nonblocking(true)
            .map_err(|_| Error::NotificationIo)?;
        let mut state = self.state()?;
        if self.shared.stopping.load(Ordering::Acquire) {
            return Err(Error::Closed);
        }
        state.notification = Some(Writer {
            stream: writer,
            armed: false,
            broken: false,
        });
        if !state.ready.is_empty() {
            state.signal();
        }
        Ok(reader)
    }
    pub fn detach_notifications(&self) -> Result<(), Error> {
        self.state()?.notification = None;
        Ok(())
    }
}
