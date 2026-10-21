use super::*;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum EmitFailure {
    Backpressure,
    TooLarge,
    Cancelled,
    Closed,
    Poisoned,
}

#[derive(Debug, PartialEq, Eq)]
pub struct EmitError {
    pub reason: EmitFailure,
    /// Returned to the adapter so backpressure does not silently lose a chunk.
    pub bytes: Vec<u8>,
}

impl Context {
    /// Worker-only incremental emission. Backpressure returns ownership of bytes.
    pub fn try_emit(&self, bytes: Vec<u8>) -> Result<(), EmitError> {
        self.publish(None, bytes, false)
    }
    /// Worker-only cooperative wait for stream capacity; cancellation wakes it.
    pub fn emit(&self, bytes: Vec<u8>) -> Result<(), EmitError> {
        self.publish(None, bytes, true)
    }
    /// Replace a queued state update with the same request/key. Reliable chunks
    /// use emit/try_emit and are never coalesced.
    pub fn try_replace(&self, key: u64, bytes: Vec<u8>) -> Result<(), EmitError> {
        self.publish(Some(key), bytes, false)
    }

    fn publish(&self, key: Option<u64>, bytes: Vec<u8>, wait: bool) -> Result<(), EmitError> {
        let fail = |reason, bytes| Err(EmitError { reason, bytes });
        let Some(shared) = self.shared.upgrade() else {
            return fail(EmitFailure::Closed, bytes);
        };
        let Some(cost) = EVENT_OVERHEAD.checked_add(bytes.capacity()) else {
            return fail(EmitFailure::TooLarge, bytes);
        };
        if cost > shared.config.max_stream_bytes {
            return fail(EmitFailure::TooLarge, bytes);
        }
        let Ok(mut state) = shared.state.lock() else {
            return fail(EmitFailure::Poisoned, bytes);
        };
        loop {
            if self.is_cancelled() {
                return fail(EmitFailure::Cancelled, bytes);
            }
            let Some(record) = state.records.get(&self.request).filter(|r| !r.complete) else {
                return fail(EmitFailure::Closed, bytes);
            };
            let (owner, generation) = (record.owner, record.generation);
            let replace = key.and_then(|key| state.ready.iter().position(|event| event.request == self.request && matches!(&event.outcome, Outcome::Chunk { key: Some(old), .. } if *old == key)));
            let old_cost = replace
                .map(|index| match &state.ready[index].outcome {
                    Outcome::Chunk { bytes, .. } => EVENT_OVERHEAD + bytes.capacity(),
                    _ => unreachable!(),
                })
                .unwrap_or(0);
            if (replace.is_some() || state.stream_items < shared.config.max_stream_items)
                && cost <= shared.config.max_stream_bytes - (state.stream_bytes - old_cost)
            {
                let event = Event {
                    epoch: shared.epoch,
                    request: self.request,
                    owner,
                    generation,
                    outcome: Outcome::Chunk { key, bytes },
                };
                if let Some(index) = replace {
                    state.ready[index] = event;
                } else {
                    state.ready.push_back(event);
                    state.stream_items += 1;
                }
                state.stream_bytes = state.stream_bytes - old_cost + cost;
                state.metrics.stream_items_high_water = state
                    .metrics
                    .stream_items_high_water
                    .max(state.stream_items);
                state.metrics.stream_bytes_high_water = state
                    .metrics
                    .stream_bytes_high_water
                    .max(state.stream_bytes);
                state.signal();
                return Ok(());
            }
            if !wait {
                return fail(EmitFailure::Backpressure, bytes);
            }
            let Ok((next, _)) = shared.space.wait_timeout(state, Duration::from_millis(50)) else {
                return fail(EmitFailure::Poisoned, bytes);
            };
            state = next;
        }
    }
}
