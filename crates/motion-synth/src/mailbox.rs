// SPDX-License-Identifier: GPL-3.0-only
//! Control → audio hand-off.
//!
//! The producer (IMU/Trill task) posts frames at control rate; the audio task
//! takes one snapshot per block. Continuous values are latest-wins (stale
//! values are useless), events (taps) accumulate so none is lost when two
//! arrive inside one audio block. Fixed size, no allocation; the firmware
//! wraps it in a critical-section mutex.

use crate::mapping::SynthParams;

/// Snapshot handed to the audio task.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct ControlSnapshot {
    /// Latest continuous parameters, if any were posted since start.
    pub params: Option<SynthParams>,
    /// Strongest trigger velocity posted since the last take.
    pub trigger: Option<f32>,
    /// Number of triggers merged into `trigger` since the last take.
    pub triggers: u16,
    /// Timestamp (µs) of the newest posted frame.
    pub t_us: u64,
    /// Frames posted since the last take (0 = control starved this block).
    pub frames: u16,
}

/// Single-slot mailbox with event accumulation.
#[derive(Clone, Copy, Debug, Default)]
pub struct ControlMailbox {
    pending: ControlSnapshot,
}

impl ControlMailbox {
    /// Empty mailbox.
    pub const fn new() -> Self {
        Self {
            pending: ControlSnapshot {
                params: None,
                trigger: None,
                triggers: 0,
                t_us: 0,
                frames: 0,
            },
        }
    }

    /// Post the latest parameters from control rate.
    pub fn post(&mut self, params: SynthParams, t_us: u64) {
        if let Some(v) = params.trigger {
            self.pending.trigger = Some(self.pending.trigger.map_or(v, |p| p.max(v)));
            self.pending.triggers = self.pending.triggers.saturating_add(1);
        }
        self.pending.params = Some(SynthParams {
            trigger: None,
            ..params
        });
        self.pending.t_us = t_us;
        self.pending.frames = self.pending.frames.saturating_add(1);
    }

    /// Take the snapshot for one audio block. Continuous params persist,
    /// events and counters reset.
    pub fn take(&mut self) -> ControlSnapshot {
        let out = self.pending;
        self.pending.trigger = None;
        self.pending.triggers = 0;
        self.pending.frames = 0;
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn p(freq: f32, trig: Option<f32>) -> SynthParams {
        SynthParams {
            freq_hz: freq,
            trigger: trig,
            ..SynthParams::default()
        }
    }

    #[test]
    fn latest_wins_events_accumulate() {
        let mut m = ControlMailbox::new();
        m.post(p(100.0, Some(0.3)), 1);
        m.post(p(200.0, None), 2);
        m.post(p(300.0, Some(0.7)), 3);
        let s = m.take();
        assert_eq!(s.params.unwrap().freq_hz, 300.0);
        assert_eq!(s.params.unwrap().trigger, None);
        assert_eq!(s.trigger, Some(0.7));
        assert_eq!(s.triggers, 2);
        assert_eq!(s.frames, 3);
        assert_eq!(s.t_us, 3);
        let s2 = m.take();
        assert_eq!(
            s2.params.unwrap().freq_hz,
            300.0,
            "continuous value persists"
        );
        assert_eq!(s2.trigger, None);
        assert_eq!(s2.frames, 0, "starvation visible");
    }
}
