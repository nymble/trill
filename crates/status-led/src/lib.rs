// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Nymble (https://github.com/nymble)

//! `no_std` status indication for a plain three-channel RGB LED (one GPIO per
//! channel, no PWM, no addressable LED).
//!
//! * [`Color`]: the eight digital mixes of the three channels.
//! * [`Pattern`]: solid or blinking colour, evaluated from milliseconds.
//! * [`StatusLed`]: picks one [`Indication`] from a snapshot of system
//!   [`Inputs`] with a fixed priority (faults before activity), handles the
//!   debug [`Command`]s and returns the colour to show now.
//! * [`RgbLed`]: drives three `embedded_hal::digital::OutputPin`s with either
//!   polarity and only touches pins whose level changes.
//!
//! Time is a free-running `u32` millisecond counter; all arithmetic wraps,
//! so callers can pass `Instant::now().as_millis() as u32` directly.
//!
//! Priority (highest first), see [`Indication`] for colours:
//! manual/self-test > safe mode > IMU fault > audio fault > Trill lost >
//! previous crash > booting > calibrating > tap > touch > motion >
//! ready+streaming > ready.

#![cfg_attr(not(test), no_std)]
#![forbid(unsafe_code)]
#![warn(missing_docs)]

use embedded_hal::digital::OutputPin;

/// Red channel bit in a [`Color`].
pub const R: u8 = 1;
/// Green channel bit in a [`Color`].
pub const G: u8 = 2;
/// Blue channel bit in a [`Color`].
pub const B: u8 = 4;

/// A digital RGB mix: each channel fully on or off.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum Color {
    /// All channels off.
    Off = 0,
    /// Red.
    Red = R,
    /// Green.
    Green = G,
    /// Red + green.
    Yellow = R | G,
    /// Blue.
    Blue = B,
    /// Red + blue.
    Magenta = R | B,
    /// Green + blue.
    Cyan = G | B,
    /// All three channels.
    White = R | G | B,
}

impl Color {
    /// From channel bits (`R`=1, `G`=2, `B`=4); higher bits are ignored.
    pub const fn from_bits(bits: u8) -> Self {
        match bits & 7 {
            1 => Self::Red,
            2 => Self::Green,
            3 => Self::Yellow,
            4 => Self::Blue,
            5 => Self::Magenta,
            6 => Self::Cyan,
            7 => Self::White,
            _ => Self::Off,
        }
    }
    /// Channel bits.
    pub const fn bits(self) -> u8 {
        self as u8
    }
    /// `(red, green, blue)` channel states.
    pub const fn channels(self) -> (bool, bool, bool) {
        let b = self as u8;
        (b & R != 0, b & G != 0, b & B != 0)
    }
    /// Lower-case name.
    pub const fn name(self) -> &'static str {
        match self {
            Self::Off => "off",
            Self::Red => "red",
            Self::Green => "green",
            Self::Yellow => "yellow",
            Self::Blue => "blue",
            Self::Magenta => "magenta",
            Self::Cyan => "cyan",
            Self::White => "white",
        }
    }
}

/// Solid or blinking colour. `period_ms == 0` means solid.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Pattern {
    /// Colour while on.
    pub color: Color,
    /// On time at the start of each period (ms).
    pub on_ms: u16,
    /// Blink period (ms); 0 = solid.
    pub period_ms: u16,
}

impl Pattern {
    /// Solid colour.
    pub const fn solid(color: Color) -> Self {
        Self {
            color,
            on_ms: 0,
            period_ms: 0,
        }
    }
    /// Blink: `on_ms` on, then off for the rest of `period_ms`.
    pub const fn blink(color: Color, on_ms: u16, period_ms: u16) -> Self {
        Self {
            color,
            on_ms,
            period_ms,
        }
    }
    /// Colour `elapsed_ms` after the pattern started (wraps safely).
    pub const fn color_at(&self, elapsed_ms: u32) -> Color {
        if self.period_ms == 0 {
            return self.color;
        }
        if elapsed_ms % (self.period_ms as u32) < self.on_ms as u32 {
            self.color
        } else {
            Color::Off
        }
    }
}

/// What the LED is currently showing, in priority order (highest first).
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
#[repr(u8)]
pub enum Indication {
    /// Debug override from a [`Command::Manual`] (times out).
    Manual = 0,
    /// Debug self-test sequence.
    SelfTest,
    /// Crash loop detected; sensors and audio disabled. Red, 100/200 ms.
    SafeMode,
    /// IMU not answering / being power-cycled after it had worked. Red, 500/1000 ms.
    ImuFault,
    /// Audio missed a block deadline or resynchronised (held 3 s). Magenta, 500/1000 ms.
    AudioFault,
    /// Trill was seen and is now failing. Yellow, 500/1000 ms.
    TrillLost,
    /// The previous run ended in a panic/HardFault (first 10 s). Yellow, 100/200 ms.
    PreviousCrash,
    /// IMU not up yet. White, solid.
    Booting,
    /// IMU running, gyro bias not yet estimated: hold still. Cyan, 500/1000 ms.
    Calibrating,
    /// Tap detected (120 ms flash). White, solid.
    Tap,
    /// Finger on the Trill sensor. Green, solid.
    Touch,
    /// Rotating faster than the motion threshold. Blue, solid.
    Motion,
    /// Idle, host has the PCM port open. Blue heartbeat 50/1000 ms.
    ReadyStreaming,
    /// Idle. Green heartbeat 50/1000 ms.
    Ready,
}

impl Indication {
    /// Pattern for automatic indications (`Manual`/`SelfTest` are driven by
    /// the controller and return `Off` here).
    pub const fn pattern(self) -> Pattern {
        use Color::*;
        match self {
            Self::Manual | Self::SelfTest => Pattern::solid(Off),
            Self::SafeMode => Pattern::blink(Red, 100, 200),
            Self::ImuFault => Pattern::blink(Red, 500, 1000),
            Self::AudioFault => Pattern::blink(Magenta, 500, 1000),
            Self::TrillLost => Pattern::blink(Yellow, 500, 1000),
            Self::PreviousCrash => Pattern::blink(Yellow, 100, 200),
            Self::Booting => Pattern::solid(White),
            Self::Calibrating => Pattern::blink(Cyan, 500, 1000),
            Self::Tap => Pattern::solid(White),
            Self::Touch => Pattern::solid(Green),
            Self::Motion => Pattern::solid(Blue),
            Self::ReadyStreaming => Pattern::blink(Blue, 50, 1000),
            Self::Ready => Pattern::blink(Green, 50, 1000),
        }
    }
    /// Short label for diagnostics.
    pub const fn name(self) -> &'static str {
        match self {
            Self::Manual => "manual",
            Self::SelfTest => "selftest",
            Self::SafeMode => "safe_mode",
            Self::ImuFault => "imu_fault",
            Self::AudioFault => "audio_fault",
            Self::TrillLost => "trill_lost",
            Self::PreviousCrash => "prev_crash",
            Self::Booting => "booting",
            Self::Calibrating => "calibrating",
            Self::Tap => "tap",
            Self::Touch => "touch",
            Self::Motion => "motion",
            Self::ReadyStreaming => "ready_stream",
            Self::Ready => "ready",
        }
    }
    /// From the `repr(u8)` value (for passing through an atomic).
    pub const fn from_u8(v: u8) -> Option<Self> {
        Some(match v {
            0 => Self::Manual,
            1 => Self::SelfTest,
            2 => Self::SafeMode,
            3 => Self::ImuFault,
            4 => Self::AudioFault,
            5 => Self::TrillLost,
            6 => Self::PreviousCrash,
            7 => Self::Booting,
            8 => Self::Calibrating,
            9 => Self::Tap,
            10 => Self::Touch,
            11 => Self::Motion,
            12 => Self::ReadyStreaming,
            13 => Self::Ready,
            _ => return None,
        })
    }
}

/// Sensor task state as seen by the LED (mirrors the firmware's states).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub enum Sensor {
    /// Not started.
    #[default]
    Off,
    /// Initialising.
    Init,
    /// Producing data.
    Running,
    /// Failed, retrying.
    Retry,
    /// Disabled on purpose (safe mode).
    Disabled,
}

/// Snapshot of the system state; cheap to build every tick.
#[derive(Clone, Copy, Debug, PartialEq, Default)]
pub struct Inputs {
    /// Safe mode active.
    pub safe_mode: bool,
    /// The previous run ended in a panic or HardFault.
    pub previous_crash: bool,
    /// IMU task state.
    pub imu: Sensor,
    /// Gyro bias estimated (`MotionFrame::calibrated`).
    pub imu_calibrated: bool,
    /// Trill task state.
    pub trill: Sensor,
    /// Cumulative audio deadline misses + resyncs (wrapping counter).
    pub audio_faults: u32,
    /// Cumulative tap count (wrapping counter).
    pub taps: u32,
    /// A finger is on the Trill sensor.
    pub touching: bool,
    /// Bias-corrected rotation speed (dps).
    pub rotation_dps: f32,
    /// A host is using the USB data path: the firmware passes "USB-MIDI
    /// function configured by the host, or PCM debug port open".
    pub usb_streaming: bool,
}

/// Debug command (typed on the USB diagnostics port).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Command {
    /// Back to automatic status.
    Auto,
    /// Show a fixed colour (`Color::Off` turns the LED off) until
    /// [`Command::Auto`] or [`MANUAL_TIMEOUT_MS`].
    Manual(Color),
    /// Step through every channel combination, then return to automatic.
    SelfTest,
}

impl Command {
    /// Keys: `a` auto, `0`–`7` manual colour by channel bits (`0` off,
    /// `1` red, `2` green, `3` yellow, `4` blue, `5` magenta, `6` cyan,
    /// `7` white), `L` self-test.
    pub const fn from_key(key: u8) -> Option<Self> {
        match key {
            b'a' => Some(Self::Auto),
            b'0'..=b'7' => Some(Self::Manual(Color::from_bits(key - b'0'))),
            b'L' => Some(Self::SelfTest),
            _ => None,
        }
    }
}

/// Manual colour override expires after this long (ms).
pub const MANUAL_TIMEOUT_MS: u32 = 60_000;
/// Duration of each self-test step (ms).
pub const SELF_TEST_STEP_MS: u32 = 400;
/// Self-test order: each channel alone, then the mixes, then off.
pub const SELF_TEST: [Color; 8] = [
    Color::Red,
    Color::Green,
    Color::Blue,
    Color::Yellow,
    Color::Cyan,
    Color::Magenta,
    Color::White,
    Color::Off,
];
/// How long an audio fault stays visible after the last miss (ms).
pub const AUDIO_FAULT_HOLD_MS: u32 = 3_000;
/// Tap flash length (ms).
pub const TAP_FLASH_MS: u32 = 120;
/// How long a previous crash is shown after boot (ms).
pub const PREVIOUS_CRASH_MS: u32 = 10_000;
/// Rotation speed above which motion is indicated (dps).
pub const MOTION_DPS: f32 = 60.0;

/// Result of one [`StatusLed::update`].
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Output {
    /// Selected indication.
    pub indication: Indication,
    /// Colour to show now.
    pub color: Color,
    /// `color` differs from the previous update.
    pub changed: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Mode {
    Auto,
    Manual { color: Color, since: u32 },
    SelfTest { since: u32 },
}

/// Remembers a moment for a bounded time; cleared once expired so a stale
/// timestamp cannot look recent again after the `u32` wraps.
#[derive(Clone, Copy, Debug, Default)]
struct Hold(Option<u32>);

impl Hold {
    fn active(&mut self, now: u32, len: u32) -> bool {
        match self.0 {
            Some(t) if now.wrapping_sub(t) < len => true,
            _ => {
                self.0 = None;
                false
            }
        }
    }
}

/// Status selection and blink timing. Call [`update`](Self::update)
/// periodically (every 10–50 ms is plenty); it never blocks.
#[derive(Clone, Debug)]
pub struct StatusLed {
    mode: Mode,
    started: Option<u32>,
    crash_shown: bool,
    imu_seen: bool,
    trill_seen: bool,
    audio_faults: Option<u32>,
    audio_fault: Hold,
    taps: Option<u32>,
    tap: Hold,
    current: Indication,
    since: u32,
    color: Color,
}

impl Default for StatusLed {
    fn default() -> Self {
        Self::new()
    }
}

impl StatusLed {
    /// New controller; the LED is assumed off.
    pub const fn new() -> Self {
        Self {
            mode: Mode::Auto,
            started: None,
            crash_shown: false,
            imu_seen: false,
            trill_seen: false,
            audio_faults: None,
            audio_fault: Hold(None),
            taps: None,
            tap: Hold(None),
            current: Indication::Booting,
            since: 0,
            color: Color::Off,
        }
    }

    /// Apply a debug command at time `now_ms`.
    pub fn command(&mut self, now_ms: u32, cmd: Command) {
        self.mode = match cmd {
            Command::Auto => Mode::Auto,
            Command::Manual(color) => Mode::Manual {
                color,
                since: now_ms,
            },
            Command::SelfTest => Mode::SelfTest { since: now_ms },
        };
    }

    /// `true` while a manual colour or the self-test overrides the status.
    pub fn overridden(&self) -> bool {
        self.mode != Mode::Auto
    }

    /// Pick the indication for `inp` (pure apart from edge/hold tracking).
    fn select(&mut self, now: u32, inp: &Inputs) -> Indication {
        let started = *self.started.get_or_insert(now);

        if inp.imu == Sensor::Running {
            self.imu_seen = true;
        }
        if inp.trill == Sensor::Running {
            self.trill_seen = true;
        }
        // Counters: first sample is the baseline; any change afterwards is
        // an event.
        if let Some(prev) = self.audio_faults.replace(inp.audio_faults) {
            if prev != inp.audio_faults {
                self.audio_fault.0 = Some(now);
            }
        }
        if let Some(prev) = self.taps.replace(inp.taps) {
            if prev != inp.taps {
                self.tap.0 = Some(now);
            }
        }
        let audio_fault = self.audio_fault.active(now, AUDIO_FAULT_HOLD_MS);
        let tap = self.tap.active(now, TAP_FLASH_MS);
        if !self.crash_shown && now.wrapping_sub(started) >= PREVIOUS_CRASH_MS {
            self.crash_shown = true;
        }
        let failing = |s: Sensor| matches!(s, Sensor::Off | Sensor::Init | Sensor::Retry);

        if inp.safe_mode {
            Indication::SafeMode
        } else if inp.imu == Sensor::Retry || (self.imu_seen && failing(inp.imu)) {
            Indication::ImuFault
        } else if audio_fault {
            Indication::AudioFault
        } else if self.trill_seen && failing(inp.trill) {
            Indication::TrillLost
        } else if inp.previous_crash && !self.crash_shown {
            Indication::PreviousCrash
        } else if inp.imu != Sensor::Running {
            Indication::Booting
        } else if !inp.imu_calibrated {
            Indication::Calibrating
        } else if tap {
            Indication::Tap
        } else if inp.touching {
            Indication::Touch
        } else if inp.rotation_dps > MOTION_DPS {
            Indication::Motion
        } else if inp.usb_streaming {
            Indication::ReadyStreaming
        } else {
            Indication::Ready
        }
    }

    /// Advance to `now_ms` and return what to show.
    pub fn update(&mut self, now_ms: u32, inp: &Inputs) -> Output {
        let auto = self.select(now_ms, inp);
        let (indication, pattern) = match self.mode {
            Mode::Manual { color, since } if now_ms.wrapping_sub(since) < MANUAL_TIMEOUT_MS => {
                (Indication::Manual, Pattern::solid(color))
            }
            Mode::SelfTest { since } => {
                let step = now_ms.wrapping_sub(since) / SELF_TEST_STEP_MS;
                match SELF_TEST.get(step as usize) {
                    Some(&c) => (Indication::SelfTest, Pattern::solid(c)),
                    None => {
                        self.mode = Mode::Auto;
                        (auto, auto.pattern())
                    }
                }
            }
            Mode::Manual { .. } => {
                self.mode = Mode::Auto;
                (auto, auto.pattern())
            }
            Mode::Auto => (auto, auto.pattern()),
        };

        // Restart the blink phase on every change so a new state is visible
        // immediately (blinks start "on").
        if indication != self.current {
            self.current = indication;
            self.since = now_ms;
        } else if pattern.period_ms != 0 {
            // Re-anchor whole periods so the elapsed time stays below one
            // period and the phase is continuous across the u32 ms wrap.
            let elapsed = now_ms.wrapping_sub(self.since);
            let period = pattern.period_ms as u32;
            self.since = self.since.wrapping_add(elapsed - elapsed % period);
        }
        let color = pattern.color_at(now_ms.wrapping_sub(self.since));
        let changed = color != self.color;
        self.color = color;
        Output {
            indication,
            color,
            changed,
        }
    }
}

/// Electrical polarity of the LED channels.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Polarity {
    /// Pin low = LED on (common anode to VDD; e.g. XIAO nRF52840).
    ActiveLow,
    /// Pin high = LED on.
    ActiveHigh,
}

/// Three GPIOs driving one RGB LED. Pins are only written when their state
/// changes. Construct with the pins already at their *off* level.
pub struct RgbLed<PR, PG, PB> {
    red: PR,
    green: PG,
    blue: PB,
    polarity: Polarity,
    color: Color,
}

impl<PR, PG, PB, E> RgbLed<PR, PG, PB>
where
    PR: OutputPin<Error = E>,
    PG: OutputPin<Error = E>,
    PB: OutputPin<Error = E>,
{
    /// Wrap pins that are currently driving the LED off.
    pub fn new(red: PR, green: PG, blue: PB, polarity: Polarity) -> Self {
        Self {
            red,
            green,
            blue,
            polarity,
            color: Color::Off,
        }
    }

    /// Colour currently driven.
    pub fn color(&self) -> Color {
        self.color
    }

    /// Drive `color`, writing only channels that change.
    pub fn set(&mut self, color: Color) -> Result<(), E> {
        let (r0, g0, b0) = self.color.channels();
        let (r1, g1, b1) = color.channels();
        let pol = self.polarity;
        if r0 != r1 {
            drive(&mut self.red, pol, r1)?;
        }
        if g0 != g1 {
            drive(&mut self.green, pol, g1)?;
        }
        if b0 != b1 {
            drive(&mut self.blue, pol, b1)?;
        }
        self.color = color;
        Ok(())
    }

    /// Release the pins.
    pub fn release(self) -> (PR, PG, PB) {
        (self.red, self.green, self.blue)
    }
}

fn drive<P: OutputPin>(pin: &mut P, pol: Polarity, on: bool) -> Result<(), P::Error> {
    if on == (pol == Polarity::ActiveHigh) {
        pin.set_high()
    } else {
        pin.set_low()
    }
}

#[cfg(test)]
mod tests;
