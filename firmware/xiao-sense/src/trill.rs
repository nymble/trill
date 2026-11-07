// SPDX-License-Identifier: GPL-3.0-only
//! Trill task: detect on the external bus (D4/D5), read status + centroids
//! at a fixed period, hand each *new* frame (by Trill frame ID) to the event
//! engine; release notes and retry with backoff if the sensor disappears.
//! Independent of the IMU: touch keeps working with no IMU at all.

use core::sync::atomic::Ordering;

use embassy_nrf::twim::Twim;
use embassy_time::{Delay, Duration, Ticker, Timer};
use instrument_events::TouchSample;
use motion_synth::mapping::TouchInput;
use trill_driver::{noise_threshold_counts, Config, Device, Speed, Trill};

use crate::board::*;
use crate::i2c::TimeoutI2c;
use crate::shared::*;

/// Trill-Linux defaults with the faster scan used here.
fn scan_config(device: Device) -> Config {
    let mut cfg = Config::for_device(device);
    cfg.speed = Speed::UltraFast;
    cfg.bits = TRILL_SCAN_BITS;
    let fraction = if device == Device::Flex {
        0.03
    } else {
        40.0 / 4096.0
    };
    cfg.noise_threshold = noise_threshold_counts(fraction, TRILL_SCAN_BITS);
    cfg
}

fn lost() {
    TOUCH.lock(|t| t.set(TouchInput::default()));
    with_engine(|e| e.touch_lost(now_us32()));
    MIDI_WAKE.signal(());
}

#[embassy_executor::task]
pub async fn trill_task(mut twim: Twim<'static>) {
    let timeout = Duration::from_millis(I2C_TIMEOUT_MS);
    let size_full = (TRILL_SIZE_FULL_12BIT >> (12 - TRILL_SCAN_BITS as u32)) as f32;
    loop {
        set_state(&STATS.trill_state, SensorState::Init);
        let mut trill = Trill::new(
            TimeoutI2c::new(&mut twim, timeout),
            Device::Flex.default_address(),
        );
        // Frame-ID staleness needs the status byte: firmware >= 3.
        let ok = match trill.identify(&mut Delay) {
            Ok(id) => {
                STATS.trill_device.store(id.device as u8, Ordering::Relaxed);
                id.device.is_1d()
                    && id.firmware >= 3
                    && trill
                        .init(&mut Delay, Some(id.device), &scan_config(id.device))
                        .is_ok()
            }
            Err(_) => false,
        };
        if !ok {
            bump(&STATS.trill_errors);
            set_state(&STATS.trill_state, SensorState::Retry);
            lost();
            Timer::after_secs(2).await;
            continue;
        }
        set_state(&STATS.trill_state, SensorState::Running);
        let full = trill
            .identity()
            .and_then(|i| i.device.location_full_scale())
            .unwrap_or(3712) as f32;
        let mut ticker = Ticker::every(Duration::from_millis(TRILL_POLL_MS));
        let mut consecutive = 0u32;
        let mut last_frame: Option<u8> = None;
        loop {
            ticker.next().await;
            let t = now_us32();
            match trill.read_frame(&mut Delay) {
                Ok((status, touches)) => {
                    consecutive = 0;
                    bump(&STATS.trill_reads);
                    let id = status.frame_id();
                    if last_frame == Some(id) {
                        // Same scan as last poll: not new data.
                        bump(&STATS.trill_stale_frames);
                        continue;
                    }
                    last_frame = Some(id);
                    // Single voice: the first reported touch only.
                    let first = touches.iter().next();
                    let sample = first.map(|c| TouchSample {
                        location: c.location as f32 / full,
                        size: c.size as f32 / size_full,
                    });
                    TOUCH.lock(|c| {
                        c.set(match sample {
                            Some(s) => TouchInput {
                                location: Some(s.location.min(1.0)),
                                size: s.size.min(1.0),
                            },
                            None => TouchInput::default(),
                        })
                    });
                    with_engine(|e| e.touch(t, sample));
                    crate::timing::touch_frame(sample.is_some());
                    MIDI_WAKE.signal(());
                    #[cfg(feature = "pcm-synth")]
                    crate::audio::post_touch(embassy_time::Instant::now().as_micros());
                }
                Err(_) => {
                    bump(&STATS.trill_errors);
                    consecutive += 1;
                    if consecutive >= TRILL_MAX_CONSECUTIVE_ERRORS {
                        break;
                    }
                }
            }
        }
        lost();
        set_state(&STATS.trill_state, SensorState::Retry);
        Timer::after_secs(1).await;
    }
}
