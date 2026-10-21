// Copyright (C) 2026  Ryan.K
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Events drained from the kernel but not yet delivered to Lisp.
//!
//! The kernel removes the events it drains. The bridge keeps them here until
//! the Lisp vector holding them exists, so that a conversion failure or a
//! non-local exit (a quit, a signal from Lisp) delivers them on the next drain
//! instead of losing them, final outcomes included.
//!
//! Invariant: carried events are older than every event still in the kernel,
//! so carried-then-fresh is delivery order.

use lispm_kernel::{Error, Event, Kernel};
use std::collections::VecDeque;

/// Most events one drain delivers.
const MAX_ITEMS: usize = 16;
/// Most bytes one drain delivers, unless its first event alone is larger.
const MAX_BYTES: usize = 64 * 1024;

/// What one drain may deliver, within the bridge's hard caps.
#[derive(Clone, Copy, Debug)]
pub(crate) struct Budget {
    items: usize,
    bytes: usize,
}

impl Budget {
    /// The caller's limits, capped at 16 events and 64 KiB.
    pub(crate) fn new(items: usize, bytes: usize) -> Self {
        Self {
            items: items.min(MAX_ITEMS),
            bytes: bytes.min(MAX_BYTES),
        }
    }
}

/// Undelivered events, oldest first.
#[derive(Debug, Default)]
pub(crate) struct Carry(VecDeque<Event>);

impl Carry {
    /// Selects the next delivery: carried events first, then events drained
    /// from `kernel` behind them. Returns how many front events it holds.
    ///
    /// Post: at most `budget.items` events within `budget.bytes`, or exactly
    /// one event when the first one alone exceeds `budget.bytes` (kernel
    /// stream and output limits bound it); never a budget error.
    ///
    /// # Errors
    ///
    /// The kernel's error (busy, poisoned) when nothing at all can be delivered.
    pub(crate) fn select(&mut self, kernel: &Kernel, budget: Budget) -> Result<usize, Error> {
        let (count, room) = self.fit(budget);
        // Pre for the subtraction: `room` exists only when `count < budget.items`.
        let Some(room) = room.filter(|_| count < budget.items) else {
            return Ok(count);
        };
        let fresh = match kernel.drain(budget.items - count, room) {
            Ok(fresh) => fresh,
            // The oldest ready event alone exceeds the budget: deliver it alone.
            Err(Error::DrainBudget { .. }) if count == 0 => kernel.drain(1, usize::MAX)?,
            Err(error) if count == 0 => return Err(error),
            // The carried events are delivered now; the kernel's wait.
            Err(_) => Vec::new(),
        };
        self.0.extend(fresh);
        Ok(self.fit(budget).0)
    }

    /// The `count` front events, oldest first.
    pub(crate) fn front(&self, count: usize) -> impl Iterator<Item = &Event> {
        self.0.iter().take(count)
    }

    /// Forgets the `count` front events, once Lisp holds them.
    pub(crate) fn delivered(&mut self, count: usize) {
        self.0.drain(..count.min(self.0.len()));
    }

    /// How many front events fit `budget`, and the bytes left for fresh events
    /// when every carried event fits with room to spare.
    fn fit(&self, budget: Budget) -> (usize, Option<usize>) {
        let mut room = budget.bytes;
        for (count, event) in self.0.iter().take(budget.items).enumerate() {
            match room.checked_sub(event.byte_cost()) {
                Some(left) => room = left,
                None if count == 0 => return (1, None),
                None => return (count, None),
            }
        }
        (self.0.len().min(budget.items), Some(room))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use lispm_kernel::{Config, Outcome};
    use std::time::{Duration, Instant};

    /// Submits an echo job; owners spread jobs over per-owner quotas.
    fn submit(kernel: &Kernel, owner: u64, bytes: Vec<u8>) -> u64 {
        let limit = bytes.len();
        loop {
            let input = bytes.clone();
            match kernel.submit(owner, 0, input, limit, |_, bytes| Ok(bytes)) {
                Err(Error::Busy) => std::thread::yield_now(),
                result => return result.unwrap(),
            }
        }
    }

    /// Selects as the bridge does, retrying while the kernel is busy.
    fn select(carry: &mut Carry, kernel: &Kernel, items: usize, bytes: usize) -> usize {
        loop {
            match carry.select(kernel, Budget::new(items, bytes)) {
                Err(Error::Busy) => std::thread::yield_now(),
                result => return result.unwrap(),
            }
        }
    }

    fn ready(kernel: &Kernel, count: usize) {
        let deadline = Instant::now() + Duration::from_secs(3);
        while !kernel.stats().is_ok_and(|stats| stats.ready >= count) {
            assert!(Instant::now() < deadline);
            std::thread::yield_now();
        }
    }

    fn requests(carry: &Carry, count: usize) -> Vec<u64> {
        carry.front(count).map(|event| event.request).collect()
    }

    #[test]
    fn oversized_first_event_is_delivered_alone() {
        let kernel = Kernel::new(Config::default()).unwrap();
        let big = submit(&kernel, 1, vec![b'x'; 100 * 1024]);
        ready(&kernel, 1);
        let small = submit(&kernel, 1, b"small".to_vec());
        ready(&kernel, 2);
        let mut carry = Carry::default();
        assert_eq!(select(&mut carry, &kernel, 16, 64 * 1024), 1);
        assert_eq!(requests(&carry, 1), [big]);
        carry.delivered(1);
        assert_eq!(select(&mut carry, &kernel, 16, 64 * 1024), 1);
        assert_eq!(requests(&carry, 1), [small]);
    }

    #[test]
    fn undelivered_events_are_selected_again_in_order() {
        let kernel = Kernel::new(Config::default()).unwrap();
        let ids: Vec<u64> = (0..3)
            .map(|n| {
                let id = submit(&kernel, 1, vec![b'a' + n]);
                ready(&kernel, usize::from(n) + 1);
                id
            })
            .collect();
        let mut carry = Carry::default();
        assert_eq!(select(&mut carry, &kernel, 2, 64 * 1024), 2);
        // Conversion failed: nothing delivered, the same events come again.
        assert_eq!(select(&mut carry, &kernel, 2, 64 * 1024), 2);
        assert_eq!(requests(&carry, 2), ids[..2]);
        carry.delivered(2);
        assert_eq!(select(&mut carry, &kernel, 2, 64 * 1024), 1);
        assert_eq!(requests(&carry, 1), ids[2..]);
        let outcome = &carry.front(1).next().unwrap().outcome;
        assert_eq!(*outcome, Outcome::Success(b"c".to_vec()));
    }

    #[test]
    fn carried_events_count_against_the_budget() {
        let kernel = Kernel::new(Config::default()).unwrap();
        for n in 0..20 {
            submit(&kernel, n, vec![b'x'; 1024]);
            ready(&kernel, usize::try_from(n).unwrap() + 1);
        }
        let mut carry = Carry::default();
        assert_eq!(select(&mut carry, &kernel, 4, 64 * 1024), 4);
        // A larger request takes the four carried events and twelve fresh ones.
        assert_eq!(select(&mut carry, &kernel, 100, usize::MAX), 16);
        carry.delivered(16);
        let two = 2 * (1024 + lispm_kernel::EVENT_OVERHEAD);
        assert_eq!(select(&mut carry, &kernel, 16, two), 2);
        assert_eq!(select(&mut carry, &kernel, 16, two - 1), 1);
        assert_eq!(select(&mut carry, &kernel, 0, two), 0);
    }
}
