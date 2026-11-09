// SPDX-License-Identifier: GPL-3.0-only
//! Audio task (high-priority interrupt executor), only built with the
//! optional `pcm-synth` feature: the on-board synth is a debug/test path,
//! not the instrument's audio output (USB MIDI drives a host synth).
//!
//! Controls reach the synth through `MAILBOX`, posted by both the IMU task
//! and the Trill task (so touch reaches the synth without the IMU).
//!
//! Every block period: take one control snapshot, render `BLOCK` samples,
//! hand the block to the USB PCM queue without ever blocking. The block
//! deadline schedule is computed from the sample count, so the long-term
//! rate is exactly `SAMPLE_RATE` against the 32.768 kHz crystal (±1 RTC
//! tick ≈ 31 µs jitter per block). With an I²S DAC the I²S clock would pace
//! the blocks instead (see docs/motion-synth.md, "Output paths").

use core::sync::atomic::Ordering;

use cortex_m::peripheral::DWT;
use embassy_time::{Instant, Timer, TICK_HZ};
use motion_synth::mapping::{map, MappingConfig};
use motion_synth::motion::MotionFrame;
use motion_synth::stream::FLAG_DROPPED;
use motion_synth::synth::Synth;

use crate::board::*;
use crate::shared::*;

/// CPU clock used to convert DWT cycles to µs.
const CPU_HZ: u32 = 64_000_000;

/// Map the latest motion + touch to synth parameters and post them.
/// `frame.tap` triggers a percussive hit; callers other than the IMU task
/// must pass a frame with `tap: None`.
pub fn post_controls(frame: &MotionFrame, t_us: u64) {
    let touch = TOUCH.lock(|t| t.get());
    let params = map(&MappingConfig::default(), frame, &touch);
    MAILBOX.lock(|m| m.borrow_mut().post(params, t_us));
}

/// Touch-only update for the synth (no tap trigger).
pub fn post_touch(t_us: u64) {
    let mut frame = LAST_MOTION.lock(|m| m.get());
    frame.tap = None;
    post_controls(&frame, t_us);
}

fn deadline_ticks(start: u64, block_index: u64) -> u64 {
    start + block_index * BLOCK as u64 * TICK_HZ / SAMPLE_RATE as u64
}

#[embassy_executor::task]
pub async fn audio_task() {
    let mut synth = Synth::new(SAMPLE_RATE);
    let mut buf = [0i16; BLOCK];
    let mut start = Instant::now().as_ticks();
    let mut index: u64 = 0;
    let mut seq: u32 = 0;
    let mut dropped_since_sent = false;

    loop {
        index += 1;
        let deadline = deadline_ticks(start, index);
        let now = Instant::now().as_ticks();
        if now > deadline {
            bump(&STATS.audio_late);
            // More than 4 blocks behind: resynchronise instead of bursting.
            if now > deadline_ticks(start, index + 4) {
                bump(&STATS.audio_resyncs);
                start = now;
                index = 0;
            }
        } else {
            Timer::at(Instant::from_ticks(deadline)).await;
        }

        let c0 = DWT::cycle_count();
        let snap = MAILBOX.lock(|m| m.borrow_mut().take());
        if snap.frames == 0 {
            bump(&STATS.audio_starved);
        } else {
            let age = Instant::now().as_micros().saturating_sub(snap.t_us);
            record_max(
                &STATS.control_age_us_last,
                &STATS.control_age_us_max,
                age.min(u32::MAX as u64) as u32,
            );
        }
        if snap.trigger.is_some() {
            STATS
                .audio_triggers
                .fetch_add(snap.triggers as u32, Ordering::Relaxed);
        }
        synth.apply(&snap);
        synth.render(&mut buf);
        let cycles = DWT::cycle_count().wrapping_sub(c0);
        record_max(
            &STATS.audio_render_us_last,
            &STATS.audio_render_us_max,
            cycles / (CPU_HZ / 1_000_000),
        );
        bump(&STATS.audio_blocks);

        if PCM_ENABLED.load(Ordering::Relaxed) {
            let block = PcmBlock {
                seq,
                flags: if dropped_since_sent { FLAG_DROPPED } else { 0 },
                samples: buf,
            };
            match PCM.try_send(block) {
                Ok(()) => dropped_since_sent = false,
                Err(_) => {
                    bump(&STATS.pcm_dropped);
                    dropped_since_sent = true;
                }
            }
        }
        seq = seq.wrapping_add(1);
    }
}
