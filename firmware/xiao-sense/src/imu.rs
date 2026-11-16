// SPDX-License-Identifier: GPL-3.0-only
//! IMU task: power, init, data-ready-paced reads (833 Hz ODR; every sample
//! is read and processed), motion processing, hand-off to the event engine,
//! with bounded fault recovery (power-cycle + exponential backoff). Touch
//! does not depend on this task.
//!
//! At boot the IMU is probed at both LSM6DS3TR-C addresses. A board without
//! one (plain XIAO nRF52840) is reported as `absent` after `PROBE_ATTEMPTS`,
//! the internal bus is scanned once for diagnostics, the sensor supply is
//! switched off and the task stops: no endless retries, no fault LED.

use core::sync::atomic::Ordering;

use embassy_nrf::gpio::{Input, Output};
use embassy_nrf::twim::Twim;
use embassy_time::{with_timeout, Delay, Duration, Instant, Timer};
use embedded_hal::i2c::I2c as _;
use lsm6ds3trc::{
    AccelScale, Config, Error, GyroScale, Lsm6ds3trc, Odr, ADDRESS_SA0_HIGH, ADDRESS_SA0_LOW,
    TURN_ON_MS, WHO_AM_I_VALUE,
};
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

/// 833 Hz (1.2 ms per sample, half the 416 Hz wait) and ±8 g so hard taps
/// do not clip (velocity and strike direction need the unclipped spike).
/// Gyro ±1000 dps as before.
const IMU_CONFIG: Config = Config {
    accel_odr: Odr::Hz833,
    accel_scale: AccelScale::G8,
    gyro_odr: Odr::Hz833,
    gyro_scale: GyroScale::Dps1000,
    int1_drdy_accel: true,
};

/// LSM6DS3TR-C addresses: SA0 low (XIAO Sense) first, then SA0 high.
const IMU_ADDRESSES: [u8; 2] = [ADDRESS_SA0_LOW, ADDRESS_SA0_HIGH];
/// Power-cycled probe rounds before the IMU is declared absent (~0.2 s).
const PROBE_ATTEMPTS: u32 = 3;

/// Find a supported IMU. Records what answered in `IMU_PROBE`; returns
/// its address, or `None` (supply left off) when nothing usable answered.
async fn probe(twim: &mut Twim<'static>, power: &mut Output<'static>) -> Option<u8> {
    let timeout = Duration::from_millis(I2C_TIMEOUT_MS);
    for attempt in 0..PROBE_ATTEMPTS {
        power.set_high();
        Timer::after_millis(TURN_ON_MS as u64 + 5).await;
        for &addr in &IMU_ADDRESSES {
            let mut imu = Lsm6ds3trc::new(TimeoutI2c::new(twim, timeout), addr);
            match imu.who_am_i() {
                Ok(id) => {
                    IMU_PROBE.who_am_i.store(id, Ordering::Relaxed);
                    if id == WHO_AM_I_VALUE {
                        IMU_PROBE.address.store(addr, Ordering::Relaxed);
                        IMU_PROBE.presence.store(IMU_PRESENT, Ordering::Relaxed);
                        return Some(addr);
                    }
                    // Something else answered (unsupported part): record the
                    // WrongId code and keep looking.
                    STATS.imu_last_error.store(2, Ordering::Relaxed);
                }
                Err(e) => STATS
                    .imu_last_error
                    .store(error_code(&e), Ordering::Relaxed),
            }
        }
        power.set_low();
        if attempt + 1 < PROBE_ATTEMPTS {
            Timer::after_millis(50).await;
        }
    }
    None
}

/// One-byte read at every 7-bit address on the (powered) internal bus;
/// acknowledged addresses go into `IMU_PROBE.bus` for the diagnostics
/// banner. A NACK costs ~25 µs at 400 kHz, so the scan takes a few ms.
async fn scan_bus(twim: &mut Twim<'static>, power: &mut Output<'static>) {
    power.set_high();
    Timer::after_millis(TURN_ON_MS as u64 + 5).await;
    let mut bus = TimeoutI2c::new(twim, Duration::from_millis(I2C_TIMEOUT_MS));
    for addr in 0x08u8..=0x77 {
        let mut b = [0u8; 1];
        if bus.read(addr, &mut b).is_ok() {
            IMU_PROBE.bus[usize::from(addr / 32)].fetch_or(1 << (addr % 32), Ordering::Relaxed);
        }
    }
    power.set_low();
}

#[embassy_executor::task]
pub async fn imu_task(
    mut twim: Twim<'static>,
    mut power: Output<'static>,
    mut int1: Input<'static>,
) {
    let mut motion = MotionProcessor::new(MotionConfig {
        // ≈ 1 s of stillness at 833 Hz, as 400 samples were at 416 Hz.
        calib_samples: 800,
        ..MotionConfig::default()
    });
    let mut backoff_ms: u64 = 100;
    let timeout = Duration::from_millis(I2C_TIMEOUT_MS);

    set_state(&STATS.imu_state, SensorState::Init);
    let Some(address) = probe(&mut twim, &mut power).await else {
        scan_bus(&mut twim, &mut power).await;
        IMU_PROBE.presence.store(IMU_ABSENT, Ordering::Relaxed);
        set_state(&STATS.imu_state, SensorState::Absent);
        motion_lost();
        // Nothing to do on this board; touch, USB and the LED run elsewhere.
        core::future::pending::<()>().await;
        return;
    };

    loop {
        set_state(&STATS.imu_state, SensorState::Init);
        power.set_high();
        Timer::after_millis(TURN_ON_MS as u64 + 5).await;

        let mut imu = Lsm6ds3trc::new(TimeoutI2c::new(&mut twim, timeout), address);
        if let Err(e) = imu.init(&mut Delay, IMU_CONFIG) {
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
            let mut applied_tap = (f32::NAN, 0u32);
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
                        let tap_cfg = with_engine(|e| {
                            e.motion(
                                t_us as u32,
                                instrument_events::MotionSample {
                                    calibrated: frame.calibrated,
                                    rotation_dps: frame.rotation_dps,
                                    pitch_deg: frame.pitch_deg,
                                    roll_deg: frame.roll_deg,
                                    gyro_dps: frame.gyro_dps,
                                    tap: frame.tap,
                                    tap_dir: frame.tap_dir,
                                },
                            );
                            (e.config().tap_threshold_g, e.config().tap_cooldown_us)
                        });
                        // Tap sensitivity lives in the engine config (set over
                        // SysEx); the detector picks it up from the next sample.
                        if let Some(tap_cfg) = tap_cfg.filter(|c| *c != applied_tap) {
                            applied_tap = tap_cfg;
                            motion.set_tap(tap_cfg.0, u64::from(tap_cfg.1));
                        }
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
