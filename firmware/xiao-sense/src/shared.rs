// SPDX-License-Identifier: GPL-3.0-only
//! State shared between executors. Everything is fixed-size; cross-priority
//! access uses critical sections that only copy a few words.

use core::cell::{Cell, RefCell};
use core::sync::atomic::{AtomicBool, AtomicU32, AtomicU8, Ordering};

use embassy_sync::blocking_mutex::raw::CriticalSectionRawMutex;
use embassy_sync::blocking_mutex::Mutex;
use embassy_sync::channel::Channel;
use motion_synth::mailbox::ControlMailbox;
use motion_synth::mapping::TouchInput;
use motion_synth::motion::MotionFrame;

use crate::board::{BLOCK, PCM_QUEUE};

/// One rendered audio block.
pub struct PcmBlock {
    /// Block sequence number.
    pub seq: u32,
    /// stream::FLAG_* bits.
    pub flags: u8,
    /// Samples.
    pub samples: [i16; BLOCK],
}

/// Sensor state machine, reported over diagnostics.
#[derive(Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum SensorState {
    /// Not yet tried.
    Off = 0,
    /// Initialising.
    Init = 1,
    /// Producing data.
    Running = 2,
    /// Not detected / failed, retrying with backoff.
    Retry = 3,
    /// Disabled (safe mode).
    Disabled = 4,
}

impl SensorState {
    /// From the atomic representation.
    pub fn from_u8(v: u8) -> Self {
        match v {
            1 => Self::Init,
            2 => Self::Running,
            3 => Self::Retry,
            4 => Self::Disabled,
            _ => Self::Off,
        }
    }
    /// Short label.
    pub fn label(self) -> &'static str {
        match self {
            Self::Off => "off",
            Self::Init => "init",
            Self::Running => "run",
            Self::Retry => "retry",
            Self::Disabled => "disabled",
        }
    }
}

/// Counters (wrap on overflow).
pub struct Stats {
    pub imu_state: AtomicU8,
    pub imu_samples: AtomicU32,
    pub imu_errors: AtomicU32,
    pub imu_drdy_timeouts: AtomicU32,
    pub imu_power_cycles: AtomicU32,
    pub imu_last_error: AtomicU8,
    pub trill_state: AtomicU8,
    pub trill_reads: AtomicU32,
    pub trill_errors: AtomicU32,
    pub trill_device: AtomicU8,
    pub audio_blocks: AtomicU32,
    pub audio_late: AtomicU32,
    pub audio_resyncs: AtomicU32,
    pub audio_render_us_last: AtomicU32,
    pub audio_render_us_max: AtomicU32,
    pub audio_starved: AtomicU32,
    pub audio_triggers: AtomicU32,
    pub pcm_sent: AtomicU32,
    pub pcm_dropped: AtomicU32,
    /// Control-to-block latency of the newest frame used (µs).
    pub control_age_us_last: AtomicU32,
    pub control_age_us_max: AtomicU32,
}

#[allow(clippy::declare_interior_mutable_const)]
const Z: AtomicU32 = AtomicU32::new(0);

pub static STATS: Stats = Stats {
    imu_state: AtomicU8::new(0),
    imu_samples: Z,
    imu_errors: Z,
    imu_drdy_timeouts: Z,
    imu_power_cycles: Z,
    imu_last_error: AtomicU8::new(0),
    trill_state: AtomicU8::new(0),
    trill_reads: Z,
    trill_errors: Z,
    trill_device: AtomicU8::new(0),
    audio_blocks: Z,
    audio_late: Z,
    audio_resyncs: Z,
    audio_render_us_last: Z,
    audio_render_us_max: Z,
    audio_starved: Z,
    audio_triggers: Z,
    pcm_sent: Z,
    pcm_dropped: Z,
    control_age_us_last: Z,
    control_age_us_max: Z,
};

/// Set a sensor state.
pub fn set_state(slot: &AtomicU8, s: SensorState) {
    slot.store(s as u8, Ordering::Relaxed);
}

/// Increment a counter.
pub fn bump(c: &AtomicU32) {
    c.fetch_add(1, Ordering::Relaxed);
}

/// Store `v` and raise `max` if exceeded.
pub fn record_max(last: &AtomicU32, max: &AtomicU32, v: u32) {
    last.store(v, Ordering::Relaxed);
    max.fetch_max(v, Ordering::Relaxed);
}

/// Control → audio mailbox.
pub static MAILBOX: Mutex<CriticalSectionRawMutex, RefCell<ControlMailbox>> =
    Mutex::new(RefCell::new(ControlMailbox::new()));

/// Latest Trill touch.
pub static TOUCH: Mutex<CriticalSectionRawMutex, Cell<TouchInput>> =
    Mutex::new(Cell::new(TouchInput {
        location: None,
        size: 0.0,
    }));

/// Latest motion frame (diagnostics only).
pub static LAST_MOTION: Mutex<CriticalSectionRawMutex, Cell<MotionFrame>> =
    Mutex::new(Cell::new(MotionFrame {
        t_us: 0,
        pitch_deg: 0.0,
        roll_deg: 0.0,
        rotation_dps: 0.0,
        tap: None,
        calibrated: false,
    }));

/// Scaled IMU reading: accel (g), gyro (dps).
pub type ImuReading = ([f32; 3], [f32; 3]);

/// Latest scaled IMU values (diagnostics only).
pub static LAST_IMU: Mutex<CriticalSectionRawMutex, Cell<ImuReading>> =
    Mutex::new(Cell::new(([0.0; 3], [0.0; 3])));

/// Audio → USB PCM queue.
pub static PCM: Channel<CriticalSectionRawMutex, PcmBlock, PCM_QUEUE> = Channel::new();

/// Host has the PCM port open (DTR asserted).
pub static PCM_ENABLED: AtomicBool = AtomicBool::new(false);
/// Request gyro re-calibration (diagnostics command `c`).
pub static RECALIBRATE: AtomicBool = AtomicBool::new(false);
/// Safe mode: crash loop detected, sensors and audio disabled.
pub static SAFE_MODE: AtomicBool = AtomicBool::new(false);
