// SPDX-License-Identifier: GPL-3.0-only
//! IMU task: power, init, data-ready-paced reads (416 Hz ODR; every sample
//! is read and processed), motion processing, hand-off to the event engine,
//! with bounded fault recovery (power-cycle + exponential backoff). Touch
//! does not depend on this task.

use core::sync::atomic::Ordering;

use embassy_nrf::gpio::{Input, Output};
use embassy_nrf::twim::Twim;
use embassy_time::{with_timeout, Delay, Duration, Instant, Timer};
use lsm6ds3trc::{Config, Error, Lsm6ds3trc, ADDRESS_SA0_LOW, TURN_ON_MS};
use motion_synth::motion::{MotionConfig, MotionProcessor, MotionSample};

use crate::board::*;
use crate::i2c::{BusError, TimeoutI2c};
use crate::shared::*;

fn error_code(e: &Error<BusError>) -> u8 {
    match e {
        Error::I2c(_) => 1,
        Error::WrongId(_) => 2,
        Error::ResetTimeout => 3,
    }
}

/// Tell the engine motion is gone (percussion off, motion CCs to 0) and
/// clear the published frame so `calibrated` does not linger.
fn motion_lost() {
    with_engine(|e| e.motion_lost(now_us32()));
    LAST_MOTION.lock(|m| {
        let mut f = m.get();
        f.calibrated = false;
        f.rotation_dps = 0.0;
        m.set(f)
    });
    MIDI_WAKE.signal(());
}

#[embassy_executor::task]
pub async fn imu_task(
    mut twim: Twim<'static>,
    mut power: Output<'static>,
    mut int1: Input<'static>,
) {
    let mut motion = MotionProcessor::new(MotionConfig::default());
    let mut backoff_ms: u64 = 100;
    let timeout = Duration::from_millis(I2C_TIMEOUT_MS);

    loop {
        set_state(&STATS.imu_state, SensorState::Init);
        power.set_high();
        Timer::after_millis(TURN_ON_MS as u64 + 5).await;

        let mut imu = Lsm6ds3trc::new(TimeoutI2c::new(&mut twim, timeout), ADDRESS_SA0_LOW);
        if let Err(e) = imu.init(&mut Delay, Config::default()) {
            motion_lost();
            STATS
                .imu_last_error
                .store(error_code(&e), Ordering::Relaxed);
            bump(&STATS.imu_errors);
        } else {
            set_state(&STATS.imu_state, SensorState::Running);
            backoff_ms = 100;
            let mut consecutive = 0u32;
            let mut was_calibrated = false;
            loop {
                if with_timeout(
                    Duration::from_millis(IMU_DRDY_TIMEOUT_MS),
                    int1.wait_for_high(),
                )
                .await
                .is_err()
                {
                    bump(&STATS.imu_drdy_timeouts);
                }
                let t_us = Instant::now().as_micros();
                match imu.read() {
                    Ok(s) => {
                        consecutive = 0;
                        bump(&STATS.imu_samples);
                        if RECALIBRATE.swap(false, Ordering::Relaxed) {
                            motion.reset(true);
                        }
                        let frame = motion.update(&MotionSample {
                            t_us,
                            accel_g: s.accel_g,
                            gyro_dps: s.gyro_dps,
                        });
                        if frame.tap.is_some() {
                            bump(&STATS.imu_taps);
                        }
                        if frame.calibrated && !was_calibrated {
                            bump(&STATS.imu_calibrations);
                        }
                        was_calibrated = frame.calibrated;
                        with_engine(|e| {
                            e.motion(
                                t_us as u32,
                                instrument_events::MotionSample {
                                    calibrated: frame.calibrated,
                                    rotation_dps: frame.rotation_dps,
                                    pitch_deg: frame.pitch_deg,
                                    tap: frame.tap,
                                },
                            )
                        });
                        MIDI_WAKE.signal(());
                        #[cfg(feature = "pcm-synth")]
                        crate::audio::post_controls(&frame, t_us);
                        LAST_MOTION.lock(|m| m.set(frame));
                        LAST_IMU.lock(|m| m.set((s.accel_g, s.gyro_dps)));
                        SENSOR_SNAPSHOT.lock(|m| {
                            m.set(SensorSnapshot {
                                t_us,
                                accel_g: s.accel_g,
                                gyro_dps: s.gyro_dps,
                                pitch_deg: frame.pitch_deg,
                                roll_deg: frame.roll_deg,
                                calibrated: frame.calibrated,
                            })
                        });
                    }
                    Err(e) => {
                        bump(&STATS.imu_errors);
                        STATS
                            .imu_last_error
                            .store(error_code(&e), Ordering::Relaxed);
                        consecutive += 1;
                        if consecutive >= IMU_MAX_CONSECUTIVE_ERRORS {
                            break;
                        }
                    }
                }
            }
        }

        // Failure path: power-cycle the sensor, forget the bias (a cold
        // sensor has a different offset), back off exponentially to 2 s.
        set_state(&STATS.imu_state, SensorState::Retry);
        motion_lost();
        bump(&STATS.imu_power_cycles);
        power.set_low();
        motion.reset(true);
        Timer::after_millis(backoff_ms).await;
        backoff_ms = (backoff_ms * 2).min(2000);
    }
}
