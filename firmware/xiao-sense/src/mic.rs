// SPDX-License-Identifier: GPL-3.0-only
//! Onboard PDM microphone test capture.
//!
//! Off by default. Action 7 powers the microphone, starts 16 kHz 16-bit
//! mono capture and queues blocks for the USB PCM port; action 8 (and USB
//! disconnect or safe mode) stops capture and drives the power pin low.
//! This path is a testing feature. It is not attached to any instrument
//! mapping and does not produce MIDI.

use core::sync::atomic::Ordering;

use embassy_nrf::gpio::Output;
use embassy_nrf::pdm::{Pdm, SamplerState};
use embassy_time::Timer;

use crate::board::{MIC_BLOCK, MIC_POWER_UP_MS};
use crate::shared::*;

/// Power pin, clock and data are taken in `main`; this task only runs
/// capture when [`MIC_ENABLED`] is set.
#[embassy_executor::task]
pub async fn mic_task(mut pdm: Pdm<'static>, mut power: Output<'static>) {
    // Off at boot: keep the enable pin low until a host starts the test.
    power.set_low();
    loop {
        if SAFE_MODE.load(Ordering::Relaxed) || !MIC_ENABLED.load(Ordering::Relaxed) {
            power.set_low();
            MIC_WAKE.wait().await;
            continue;
        }

        power.set_high();
        Timer::after_millis(MIC_POWER_UP_MS).await;
        if !MIC_ENABLED.load(Ordering::Relaxed) {
            power.set_low();
            continue;
        }

        let mut bufs = [[0i16; MIC_BLOCK]; 2];
        let mut seq: u32 = 0;
        let mut dropped_since_sent = false;
        let mut skip = true; // first buffer: decimation filter still settling
        let result = pdm
            .run_task_sampler(&mut bufs, |samples| {
                if !MIC_ENABLED.load(Ordering::Relaxed) {
                    return SamplerState::Stopped;
                }
                if skip {
                    skip = false;
                    return SamplerState::Sampled;
                }
                bump(&STATS.mic_blocks);
                let block = MicBlock {
                    seq,
                    flags: if dropped_since_sent {
                        motion_synth::stream::FLAG_DROPPED
                    } else {
                        0
                    },
                    samples: *samples,
                };
                seq = seq.wrapping_add(1);
                match MIC.try_send(block) {
                    Ok(()) => dropped_since_sent = false,
                    Err(_) => {
                        bump(&STATS.mic_dropped);
                        dropped_since_sent = true;
                    }
                }
                SamplerState::Sampled
            })
            .await;
        if result.is_err() {
            bump(&STATS.mic_errors);
            Timer::after_millis(50).await;
        }
        // Drive the enable pin low whenever capture is not running.
        power.set_low();
    }
}
