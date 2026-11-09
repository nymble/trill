// SPDX-License-Identifier: GPL-3.0-only
//! State shared between executors. Everything is fixed-size; cross-priority
//! access uses critical sections that only copy a few words.

use core::cell::{Cell, RefCell};
use core::sync::atomic::{AtomicBool, AtomicU16, AtomicU32, AtomicU8, Ordering};

use embassy_sync::blocking_mutex::raw::CriticalSectionRawMutex;
use embassy_sync::blocking_mutex::Mutex;
use embassy_sync::channel::Channel;
use embassy_sync::signal::Signal;
use embassy_time::Instant;
use instrument_events::Engine;
#[cfg(feature = "pcm-synth")]
use motion_synth::mailbox::ControlMailbox;
use motion_synth::mapping::TouchInput;
use motion_synth::motion::MotionFrame;

#[cfg(feature = "pcm-synth")]
use crate::board::{BLOCK, PCM_QUEUE};

/// One rendered audio block.
#[cfg(feature = "pcm-synth")]
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

/// Counters (wrap on overflow). Audio/PCM counters stay zero without
/// the `pcm-synth` feature.
#[cfg_attr(not(feature = "pcm-synth"), allow(dead_code))]
pub struct Stats {
    pub imu_state: AtomicU8,
    pub imu_samples: AtomicU32,
    pub imu_errors: AtomicU32,
    pub imu_drdy_timeouts: AtomicU32,
    pub imu_power_cycles: AtomicU32,
    pub imu_last_error: AtomicU8,
    /// Taps detected by the motion pipeline.
    pub imu_taps: AtomicU32,
    /// Gyro bias calibrations completed (uncalibrated -> calibrated).
    pub imu_calibrations: AtomicU32,
    pub trill_state: AtomicU8,
    pub trill_reads: AtomicU32,
    pub trill_errors: AtomicU32,
    pub trill_device: AtomicU8,
    /// Polls that returned the same Trill frame ID as the previous poll.
    pub trill_stale_frames: AtomicU32,
    /// USB-MIDI packets written to the IN endpoint (1..=16 events each).
    pub midi_packets: AtomicU32,
    /// USB-MIDI events written.
    pub midi_events: AtomicU32,
    /// Writes still pending after `MIDI_STALL_MS` (host not reading).
    pub midi_stalls: AtomicU32,
    /// Writes that failed because the endpoint was disabled (unplug/reset).
    pub midi_write_errors: AtomicU32,
    /// Packets received from the host on the MIDI OUT endpoint.
    pub midi_rx_packets: AtomicU32,
    /// Configuration requests answered (cable 1 SysEx for this protocol).
    pub config_requests: AtomicU32,
    /// Complete SysEx messages on cable 1 that were not ours (no reply).
    pub config_ignored: AtomicU32,
    /// Telemetry frames handed to the USB writer (cable 1).
    pub telemetry_frames: AtomicU32,
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
    imu_taps: Z,
    imu_calibrations: Z,
    trill_state: AtomicU8::new(0),
    trill_reads: Z,
    trill_errors: Z,
    trill_device: AtomicU8::new(0),
    trill_stale_frames: Z,
    midi_packets: Z,
    midi_events: Z,
    midi_stalls: Z,
    midi_write_errors: Z,
    midi_rx_packets: Z,
    config_requests: Z,
    config_ignored: Z,
    telemetry_frames: Z,
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
#[cfg(feature = "pcm-synth")]
pub fn record_max(last: &AtomicU32, max: &AtomicU32, v: u32) {
    last.store(v, Ordering::Relaxed);
    max.fetch_max(v, Ordering::Relaxed);
}

/// Control → audio mailbox (debug synth).
#[cfg(feature = "pcm-synth")]
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
        gyro_dps: [0.0; 3],
        tap_dir: [0.0; 3],
    }));

/// Scaled IMU reading: accel (g), gyro (dps).
pub type ImuReading = ([f32; 3], [f32; 3]);

/// One IMU sample with everything derived from it, published in a single
/// critical section so readers (telemetry) never see values from two
/// different samples.
#[derive(Clone, Copy)]
pub struct SensorSnapshot {
    /// Device time of the sample (µs since boot).
    pub t_us: u64,
    /// Acceleration (g).
    pub accel_g: [f32; 3],
    /// Angular rate (°/s).
    pub gyro_dps: [f32; 3],
    /// Pitch (°), complementary filter.
    pub pitch_deg: f32,
    /// Roll (°), complementary filter.
    pub roll_deg: f32,
    /// Gyro bias calibrated.
    pub calibrated: bool,
}

/// Latest IMU sample (telemetry).
pub static SENSOR_SNAPSHOT: Mutex<CriticalSectionRawMutex, Cell<SensorSnapshot>> =
    Mutex::new(Cell::new(SensorSnapshot {
        t_us: 0,
        accel_g: [0.0; 3],
        gyro_dps: [0.0; 3],
        pitch_deg: 0.0,
        roll_deg: 0.0,
        calibrated: false,
    }));

/// Telemetry subscription change from the config reader to the MIDI
/// writer: [`TELEMETRY_NO_CHANGE`] or a rate in Hz (0 = stop).
pub static TELEMETRY_REQUEST: AtomicU8 = AtomicU8::new(TELEMETRY_NO_CHANGE);
/// No pending telemetry change.
pub const TELEMETRY_NO_CHANGE: u8 = 0xFF;
/// Current telemetry rate (Hz, 0 = off), for diagnostics.
pub static TELEMETRY_RATE: AtomicU8 = AtomicU8::new(0);

/// Latest scaled IMU values (diagnostics only).
pub static LAST_IMU: Mutex<CriticalSectionRawMutex, Cell<ImuReading>> =
    Mutex::new(Cell::new(([0.0; 3], [0.0; 3])));

/// Audio → USB PCM queue.
#[cfg(feature = "pcm-synth")]
pub static PCM: Channel<CriticalSectionRawMutex, PcmBlock, PCM_QUEUE> = Channel::new();

/// Host has the PCM port open (DTR asserted).
pub static PCM_ENABLED: AtomicBool = AtomicBool::new(false);
/// Request gyro re-calibration (diagnostics command `c`).
pub static RECALIBRATE: AtomicBool = AtomicBool::new(false);
/// Safe mode: crash loop detected, sensors and audio disabled.
pub static SAFE_MODE: AtomicBool = AtomicBool::new(false);

/// Pending LED debug key from diagnostics (`status_led::Command::from_key`);
/// 0 = none. Consumed by the LED task.
pub static LED_COMMAND: AtomicU8 = AtomicU8::new(0);
/// Current LED indication (`status_led::Indication as u8`), for diagnostics.
pub static LED_INDICATION: AtomicU8 = AtomicU8::new(status_led::Indication::Booting as u8);
/// Colour currently driven (`status_led::Color::bits`), for diagnostics.
pub static LED_COLOR: AtomicU8 = AtomicU8::new(0);

/// Free-running microsecond timestamp for the event engine (wraps every
/// ~71.6 min; the engine uses wrapping comparisons).
pub fn now_us32() -> u32 {
    Instant::now().as_micros() as u32
}

/// The sensor -> MIDI event engine. Initialised in `main` before any task
/// runs; every access is a short critical section (no I/O inside).
pub static ENGINE: Mutex<CriticalSectionRawMutex, RefCell<Option<Engine>>> =
    Mutex::new(RefCell::new(None));

/// Run `f` on the engine (no-op before initialisation).
pub fn with_engine<R>(f: impl FnOnce(&mut Engine) -> R) -> Option<R> {
    ENGINE.lock(|e| e.borrow_mut().as_mut().map(f))
}

/// Wakes the MIDI writer when the engine may have output.
pub static MIDI_WAKE: Signal<CriticalSectionRawMutex, ()> = Signal::new();
/// The host has configured the device and the MIDI IN endpoint is enabled.
/// This is USB-level state: it does not mean an app is listening.
pub static MIDI_CONFIGURED: AtomicBool = AtomicBool::new(false);
/// Diagnostics -> MIDI writer requests (`MIDI_REQ_*` bits).
pub static MIDI_REQUEST: AtomicU8 = AtomicU8::new(0);
/// Send the panic/reset sequence now.
pub const MIDI_REQ_PANIC: u8 = 1;

/// Configuration generation (14-bit, wraps): bumped on every mapping change
/// from the SysEx protocol or a diagnostics key, reported in `CONFIG` replies.
pub static CONFIG_GEN: AtomicU16 = AtomicU16::new(0);
/// Random 14-bit ID chosen at boot (hardware RNG), reported by `HELLO`.
pub static BOOT_ID: AtomicU16 = AtomicU16::new(0);
/// Configuration replies waiting for the MIDI writer (cable 1). Small and
/// bounded: the reader waits when it is full, which back-pressures the host.
pub static CONFIG_REPLIES: Channel<CriticalSectionRawMutex, trill_config::Reply, 2> =
    Channel::new();

/// Bump [`CONFIG_GEN`] after a mapping change made outside the protocol.
pub fn bump_config_generation() {
    let g = CONFIG_GEN.load(Ordering::Relaxed);
    CONFIG_GEN.store(trill_config::next_generation(g), Ordering::Relaxed);
}
