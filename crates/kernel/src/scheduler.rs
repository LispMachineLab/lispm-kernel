use super::{Owner, State, Task};
use std::time::Instant;

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum WorkClass {
    #[default]
    Cpu,
    Io,
}
impl WorkClass {
    fn index(self) -> usize {
        match self {
            Self::Cpu => 0,
            Self::Io => 1,
        }
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum Priority {
    Low,
    #[default]
    Normal,
    High,
}
impl Priority {
    fn weight(self) -> u128 {
        match self {
            Self::Low => 0,
            Self::Normal => 1,
            Self::High => 2,
        }
    }
}

#[derive(Clone, Copy, Debug, Default)]
pub struct JobOptions {
    pub class: WorkClass,
    pub priority: Priority,
}

// Rotate over active owner IDs in each class. Within an owner, priority aging
// makes old low-priority work eventually outrank newly admitted high-priority work.
pub(super) fn take(state: &mut State, class: WorkClass) -> Option<Task> {
    take_at(state, class, Instant::now())
}
fn take_at(state: &mut State, class: WorkClass, now: Instant) -> Option<Task> {
    let previous = state.last_owner[class.index()];
    let owners = state
        .queue
        .iter()
        .filter(|task| task.options.class == class)
        .map(|task| state.records[&task.id].owner);
    let owner: Owner = owners
        .clone()
        .filter(|owner| previous.is_none_or(|last| *owner > last))
        .min()
        .or_else(|| owners.min())?;
    let mut chosen = None;
    let mut best_score = 0;
    for (index, task) in state.queue.iter().enumerate() {
        if task.options.class != class || state.records[&task.id].owner != owner {
            continue;
        }
        let score = task.options.priority.weight()
            + now.saturating_duration_since(task.submitted).as_millis() / 50;
        // Stable queue order breaks ties.
        if chosen.is_none() || score > best_score {
            chosen = Some(index);
            best_score = score;
        }
    }
    state.last_owner[class.index()] = Some(owner);
    state.queue.remove(chosen?)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{Config, Kernel, Record};
    use std::sync::{atomic::AtomicBool, Arc};
    use std::time::Duration;

    #[test]
    fn rotates_owners_and_ages_priority_without_sleeping() {
        let kernel = Kernel::new(Config::default()).unwrap();
        let mut state = kernel.shared.state.lock().unwrap();
        let now = Instant::now();
        for (id, owner, priority, age) in [
            (1, 1, Priority::Low, 200),
            (2, 1, Priority::High, 0),
            (3, 2, Priority::Normal, 0),
            (4, 3, Priority::High, 0),
        ] {
            state.records.insert(
                id,
                Record {
                    owner,
                    generation: 0,
                    cancelled: Arc::new(AtomicBool::new(false)),
                    output_limit: 0,
                    reservation: 0,
                    complete: false,
                },
            );
            state.queue.push_back(Task {
                id,
                input: vec![],
                job: Box::new(|_, _| Ok(vec![])),
                options: JobOptions {
                    class: WorkClass::Cpu,
                    priority,
                },
                submitted: now - Duration::from_millis(age),
            });
        }
        assert_eq!(take_at(&mut state, WorkClass::Cpu, now).unwrap().id, 1);
        assert_eq!(take_at(&mut state, WorkClass::Cpu, now).unwrap().id, 3);
        assert_eq!(take_at(&mut state, WorkClass::Cpu, now).unwrap().id, 4);
        assert_eq!(take_at(&mut state, WorkClass::Cpu, now).unwrap().id, 2);
        assert!(take_at(&mut state, WorkClass::Io, now).is_none());
        kernel.shutdown();
    }
}
