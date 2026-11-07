// SPDX-License-Identifier: GPL-3.0-only
//! Trill task: detect on the external bus (D4/D5), read centroids at a
//! fixed period, publish the first touch; retry with backoff if absent.

use core::sync::atomic::Ordering;

use embassy_nrf::twim::Twim;
use embassy_time::{Delay, Duration, Ticker, Timer};
use motion_synth::mapping::TouchInput;
use trill_driver::{Config, Device, Trill};

use crate::board::*;
use crate::i2c::TimeoutI2c;
use crate::shared::*;

#[embassy_executor::task]
pub async fn trill_task(mut twim: Twim<'static>) {
    let timeout = Duration::from_millis(I2C_TIMEOUT_MS);
    loop {
        set_state(&STATS.trill_state, SensorState::Init);
        let mut trill = Trill::new(
            TimeoutI2c::new(&mut twim, timeout),
            Device::Flex.default_address(),
        );
        let ok = match trill.identify(&mut Delay) {
            Ok(id) => {
                STATS.trill_device.store(id.device as u8, Ordering::Relaxed);
                let cfg = Config::for_device(id.device);
                id.device.is_1d() && trill.init(&mut Delay, Some(id.device), &cfg).is_ok()
            }
            Err(_) => false,
        };
        if !ok {
            bump(&STATS.trill_errors);
            set_state(&STATS.trill_state, SensorState::Retry);
            TOUCH.lock(|t| t.set(TouchInput::default()));
            Timer::after_secs(2).await;
            continue;
        }
        set_state(&STATS.trill_state, SensorState::Running);
        let full = trill
            .identity()
            .and_then(|i| i.device.location_full_scale())
            .unwrap_or(3712);
        let mut ticker = Ticker::every(Duration::from_millis(TRILL_POLL_MS));
        let mut consecutive = 0u32;
        loop {
            ticker.next().await;
            match trill.read_touches(&mut Delay) {
                Ok(touches) => {
                    consecutive = 0;
                    bump(&STATS.trill_reads);
                    let first = touches.iter().next();
                    let input = match first {
                        Some(t) => TouchInput {
                            location: Some(t.location as f32 / full as f32),
                            size: (t.size as f32 / 4096.0).min(1.0),
                        },
                        None => TouchInput::default(),
                    };
                    TOUCH.lock(|c| c.set(input));
                }
                Err(_) => {
                    bump(&STATS.trill_errors);
                    consecutive += 1;
                    if consecutive >= 10 {
                        break;
                    }
                }
            }
        }
        TOUCH.lock(|t| t.set(TouchInput::default()));
        set_state(&STATS.trill_state, SensorState::Retry);
        Timer::after_secs(1).await;
    }
}
