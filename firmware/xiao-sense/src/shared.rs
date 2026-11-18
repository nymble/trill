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
use crate::board::{MIC_BLOCK, MIC_QUEUE};

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

/// One microphone capture block (16 kHz, 5 ms).
pub struct MicBlock {
    /// Block sequence number.
    pub seq: u32,
    /// stream::FLAG_* bits.
    pub flags: u8,
    /// Samples.
    pub samples: [i16; MIC_BLOCK],
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
    /// Not fitted on this board: probed at boot, never answered; not retried.
    Absent = 5,
}

impl SensorState {
    /// From the atomic representation.
    pub fn from_u8(v: u8) -> Self {
        match v {
            1 => Self::Init,
            2 => Self::Running,
            3 => Self::Retry,
            4 => Self::Disabled,
            5 => Self::Absent,
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
            Self::Absent => "absent",
        }
    }
}

/// Counters (wrap on overflow). Synth audio counters stay zero without
/// the `pcm-synth` feature. Microphone counters are always present.
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
    /// Microphone blocks captured while the test switch is on.
    pub mic_blocks: AtomicU32,
    /// Microphone blocks dropped because the USB queue was full.
    pub mic_dropped: AtomicU32,
    /// Microphone start/sampler errors.
    pub mic_errors: AtomicU32,
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
    mic_blocks: Z,
    mic_dropped: Z,
    mic_errors: Z,
    control_age_us_last: Z,
    control_age_us_max: Z,
};

/// What the boot probe found on the internal (IMU) I²C bus.
pub struct ImuProbe {
    /// `IMU_*` presence code.
    pub presence: AtomicU8,
    /// 7-bit address the IMU answered at (0 = none).
    pub address: AtomicU8,
    /// WHO_AM_I read back (0 = no answer).
    pub who_am_i: AtomicU8,
    /// Addresses 0..=127 that acknowledged the bus scan (bit n = address n).
    /// Filled only when no supported IMU answered.
    pub bus: [AtomicU32; 4],
}

/// Boot probe not finished yet.
pub const IMU_UNKNOWN: u8 = 0;
/// A supported IMU answered.
pub const IMU_PRESENT: u8 = 1;
/// No supported IMU on this board (plain XIAO nRF52840, or an unknown part).
pub const IMU_ABSENT: u8 = 2;

pub static IMU_PROBE: ImuProbe = ImuProbe {
    presence: AtomicU8::new(IMU_UNKNOWN),
    address: AtomicU8::new(0),
    who_am_i: AtomicU8::new(0),
    bus: [Z, Z, Z, Z],
};

/// `true` unless the boot probe concluded there is no usable IMU. Reported
/// to hosts in `HELLO_REPLY` (variant bit `VARIANT_IMU`).
pub fn imu_fitted() -> bool {
    IMU_PROBE.presence.load(Ordering::Relaxed) != IMU_ABSENT
}

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

/// Latest Trill touch (first contact only). The instrument engine and the
/// format-1 telemetry field still use this single voice.
pub static TOUCH: Mutex<CriticalSectionRawMutex, Cell<TouchInput>> =
    Mutex::new(Cell::new(TouchInput {
        location: None,
        size: 0.0,
    }));

/// Up to five 1-axis touches, normalised 0..=1. Published for the
/// `TELEMETRY_TOUCHES` companion; MIDI does not read this.
#[derive(Clone, Copy, Default)]
pub struct TouchFrame {
    /// Number of valid slots in [`Self::location`] / [`Self::size`].
    pub count: u8,
    /// Position along the strip, 0..=1.
    pub location: [f32; 5],
    /// Contact size, 0..=1.
    pub size: [f32; 5],
}

impl TouchFrame {
    /// Valid (location, size) pairs.
    pub fn iter(&self) -> impl Iterator<Item = (f32, f32)> + '_ {
        let n = self.count.min(5) as usize;
        (0..n).map(|i| (self.location[i], self.size[i]))
    }
}

/// Latest set of Trill touches (telemetry companion).
pub static TOUCHES: Mutex<CriticalSectionRawMutex, Cell<TouchFrame>> =
    Mutex::new(Cell::new(TouchFrame {
        count: 0,
        location: [0.0; 5],
        size: [0.0; 5],
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

/// Microphone test switch (action 7/8). Off at boot; power pin low when off.
pub static MIC_ENABLED: AtomicBool = AtomicBool::new(false);
/// Wakes the microphone task when the switch changes.
pub static MIC_WAKE: Signal<CriticalSectionRawMutex, ()> = Signal::new();
/// Microphone → USB PCM queue.
pub static MIC: Channel<CriticalSectionRawMutex, MicBlock, MIC_QUEUE> = Channel::new();

/// Request the microphone test path on or off. The pin is driven by the
/// microphone task, not here.
pub fn set_mic_enabled(on: bool) {
    MIC_ENABLED.store(on, Ordering::Relaxed);
    MIC_WAKE.signal(());
}
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
