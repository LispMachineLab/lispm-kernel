// Copyright (C) 2026  Ryan.K
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Resource accounting as a componentwise-ordered monoid.
//!
//! `Usage` is a vector of counters. Charges compose with `+`, releases with `-`,
//! and a limit admits a charge iff `current + charge <= limit` in every component.
//! The ledger keeps one global sum and one sum per owner.
//!
//! Invariant: `total == sum(owners.values())`, and no owner entry is zero.
//! Preservation: `add` and `sub` apply the same delta to both sides and remove an
//! owner entry as soon as it returns to zero.

use crate::{Config, Owner, EVENT_OVERHEAD};
use std::collections::BTreeMap;

/// Resources held by accepted requests and undrained chunks.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(crate) struct Usage {
    /// Requests that hold an admission slot.
    pub(crate) requests: usize,
    /// Input, output and event reservations in bytes.
    pub(crate) reserved: usize,
    /// Undrained incremental chunks.
    pub(crate) stream_items: usize,
    /// Allocation bytes of undrained incremental chunks, including the event charge.
    pub(crate) stream_bytes: usize,
}

impl Usage {
    /// The charge of an admitted request with the given byte reservation.
    pub(crate) const fn request(reservation: usize) -> Self {
        Self {
            requests: 1,
            reserved: reservation,
            stream_items: 0,
            stream_bytes: 0,
        }
    }

    /// The charge left by a released request: its retained final event only.
    pub(crate) const fn released() -> Self {
        Self {
            requests: 0,
            reserved: EVENT_OVERHEAD,
            stream_items: 0,
            stream_bytes: 0,
        }
    }

    /// The charge of one undrained chunk with the given storage cost.
    pub(crate) const fn chunk(cost: usize) -> Self {
        Self {
            requests: 0,
            reserved: 0,
            stream_items: 1,
            stream_bytes: cost,
        }
    }

    /// Componentwise sum, or `None` when any component overflows.
    pub(crate) fn checked_add(self, other: Self) -> Option<Self> {
        Some(Self {
            requests: self.requests.checked_add(other.requests)?,
            reserved: self.reserved.checked_add(other.reserved)?,
            stream_items: self.stream_items.checked_add(other.stream_items)?,
            stream_bytes: self.stream_bytes.checked_add(other.stream_bytes)?,
        })
    }

    /// Componentwise sum that saturates instead of overflowing.
    pub(crate) fn saturating_add(self, other: Self) -> Self {
        Self {
            requests: self.requests.saturating_add(other.requests),
            reserved: self.reserved.saturating_add(other.reserved),
            stream_items: self.stream_items.saturating_add(other.stream_items),
            stream_bytes: self.stream_bytes.saturating_add(other.stream_bytes),
        }
    }

    /// Componentwise difference that saturates at zero.
    pub(crate) fn saturating_sub(self, other: Self) -> Self {
        Self {
            requests: self.requests.saturating_sub(other.requests),
            reserved: self.reserved.saturating_sub(other.reserved),
            stream_items: self.stream_items.saturating_sub(other.stream_items),
            stream_bytes: self.stream_bytes.saturating_sub(other.stream_bytes),
        }
    }

    /// Whether every component is at most the matching component of `limit`.
    pub(crate) fn fits_within(self, limit: Self) -> bool {
        self.requests <= limit.requests
            && self.reserved <= limit.reserved
            && self.stream_items <= limit.stream_items
            && self.stream_bytes <= limit.stream_bytes
    }

    fn is_zero(self) -> bool {
        self == Self::default()
    }
}

/// Global and per-owner maxima derived from a validated `Config`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct Limits {
    pub(crate) global: Usage,
    pub(crate) per_owner: Usage,
}

impl Limits {
    pub(crate) fn from_config(config: &Config) -> Self {
        Self {
            global: Usage {
                requests: config.max_requests,
                reserved: config.max_reserved_bytes,
                stream_items: config.max_stream_items,
                stream_bytes: config.max_stream_bytes,
            },
            per_owner: Usage {
                requests: config.max_requests_per_owner,
                reserved: config.max_reserved_bytes_per_owner,
                stream_items: config.max_stream_items_per_owner,
                stream_bytes: config.max_stream_bytes_per_owner,
            },
        }
    }

    /// Whether a charge could fit for some owner in an otherwise empty runtime.
    pub(crate) fn could_ever_admit(&self, charge: Usage) -> bool {
        charge.fits_within(self.global) && charge.fits_within(self.per_owner)
    }
}

/// Global and per-owner usage sums.
#[derive(Debug, Default, PartialEq, Eq)]
pub(crate) struct Ledger {
    total: Usage,
    owners: BTreeMap<Owner, Usage>,
}

impl Ledger {
    /// Global usage.
    pub(crate) fn total(&self) -> Usage {
        self.total
    }

    /// Usage of one owner; zero for owners without charges.
    pub(crate) fn owner(&self, owner: Owner) -> Usage {
        self.owners.get(&owner).copied().unwrap_or_default()
    }

    /// Whether `owner` may additionally hold `charge` after giving up `release`.
    ///
    /// Pre: `release` is part of the owner's current usage.
    /// Post: true iff `(usage - release + charge) <= limit` globally and per owner.
    pub(crate) fn admits(
        &self,
        owner: Owner,
        release: Usage,
        charge: Usage,
        limits: &Limits,
    ) -> bool {
        let fits = |current: Usage, limit: Usage| {
            current
                .saturating_sub(release)
                .checked_add(charge)
                .is_some_and(|next| next.fits_within(limit))
        };
        fits(self.total, limits.global) && fits(self.owner(owner), limits.per_owner)
    }

    /// Charge `owner` with `delta`.
    pub(crate) fn add(&mut self, owner: Owner, delta: Usage) {
        if delta.is_zero() {
            return;
        }
        self.total = self.total.saturating_add(delta);
        let entry = self.owners.entry(owner).or_default();
        *entry = entry.saturating_add(delta);
    }

    /// Release `delta` from `owner`.
    pub(crate) fn sub(&mut self, owner: Owner, delta: Usage) {
        self.total = self.total.saturating_sub(delta);
        if let Some(entry) = self.owners.get_mut(&owner) {
            *entry = entry.saturating_sub(delta);
            if entry.is_zero() {
                self.owners.remove(&owner);
            }
        }
    }

    /// Rebuild a ledger from individual charges; the audit compares it with the live one.
    pub(crate) fn from_charges(charges: impl IntoIterator<Item = (Owner, Usage)>) -> Self {
        let mut ledger = Self::default();
        for (owner, charge) in charges {
            ledger.add(owner, charge);
        }
        ledger
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn limits() -> Limits {
        Limits::from_config(&Config {
            max_requests: 3,
            max_requests_per_owner: 2,
            max_reserved_bytes: 300,
            max_reserved_bytes_per_owner: 200,
            max_stream_items: 3,
            max_stream_items_per_owner: 2,
            max_stream_bytes: 300,
            max_stream_bytes_per_owner: 200,
            ..Config::default()
        })
    }

    // Law: sub(o, d) after add(o, d) restores the previous ledger exactly.
    #[test]
    fn add_then_sub_is_identity_and_drops_zero_owner_entries() {
        let mut ledger = Ledger::default();
        ledger.add(1, Usage::request(100));
        let before = Ledger::from_charges([(1, Usage::request(100))]);
        assert_eq!(ledger, before);
        ledger.add(2, Usage::chunk(70));
        ledger.sub(2, Usage::chunk(70));
        assert_eq!(ledger, before);
        ledger.sub(1, Usage::request(100));
        assert_eq!(ledger, Ledger::default());
    }

    #[test]
    fn per_owner_limits_bind_before_global_limits() {
        let limits = limits();
        let mut ledger = Ledger::default();
        ledger.add(1, Usage::request(150));
        assert!(!ledger.admits(1, Usage::default(), Usage::request(60), &limits));
        assert!(ledger.admits(2, Usage::default(), Usage::request(60), &limits));
        ledger.add(2, Usage::request(150));
        // Owner 3 fits its own quota but not the remaining global bytes.
        assert!(!ledger.admits(3, Usage::default(), Usage::request(1), &limits));
        assert!(ledger.admits(3, Usage::default(), Usage::request(0), &limits));
    }

    #[test]
    fn releases_count_before_new_charges() {
        let limits = limits();
        let mut ledger = Ledger::default();
        ledger.add(1, Usage::chunk(150));
        ledger.add(1, Usage::chunk(40));
        assert!(!ledger.admits(1, Usage::default(), Usage::chunk(20), &limits));
        // A replacement gives one item back before taking one.
        let release = Usage::chunk(40);
        assert!(ledger.admits(1, release, Usage::chunk(50), &limits));
        assert!(!ledger.admits(1, release, Usage::chunk(51), &limits));
    }

    #[test]
    fn overflowing_charges_are_never_admitted() {
        let limits = Limits {
            global: Usage::request(usize::MAX),
            per_owner: Usage::request(usize::MAX),
        };
        let mut ledger = Ledger::default();
        ledger.add(1, Usage::request(usize::MAX));
        assert!(!ledger.admits(1, Usage::default(), Usage::request(1), &limits));
    }

    #[test]
    fn could_ever_admit_checks_both_limits() {
        let limits = limits();
        assert!(limits.could_ever_admit(Usage::chunk(200)));
        assert!(!limits.could_ever_admit(Usage::chunk(201)));
    }
}
