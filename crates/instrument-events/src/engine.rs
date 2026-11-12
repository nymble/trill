// SPDX-License-Identifier: GPL-3.0-only
//! Deterministic touch + motion → MIDI event engine (single voice, one
//! channel).
//!
//! # Inputs
//! * [`Engine::touch`]: one *fresh* Trill frame (first touch only) or `None`
//!   for "no touch". The caller must not re-submit a frame it already read
//!   (the firmware filters on the Trill frame counter).
//! * [`Engine::touch_lost`]: the touch sensor stopped answering.
//! * [`Engine::motion`] / [`Engine::motion_lost`]: one processed IMU frame,
//!   or IMU failure. Touch works without any motion input.
//! * [`Engine::tick`]: periodic housekeeping (stale-input timeouts,
//!   percussion note length). Call every few milliseconds.
//! * [`Engine::connect`] / [`Engine::disconnect`]: transport state.
//!
//! Timestamps are free-running `u32` microseconds; all comparisons use
//! wrapping arithmetic, so the 71.6-minute rollover is harmless. A sample
//! whose timestamp is older than the previous sample of the same input is
//! rejected and counted.
//!
//! # Output
//! [`Engine::next_message`] yields messages in priority order:
//! 1. a pending emergency All Notes Off (only if a note off could not be
//!    queued, which the reserve below makes unreachable in normal use);
//! 2. the *critical* FIFO: note on/off, the pitch bend that must precede a
//!    note on, and the connect/panic sequence;
//! 3. *continuous* controllers (pressure, pitch bend, CC74, CC1): one
//!    latest-value slot each, so updates coalesce instead of queueing; each
//!    slot has a deadband and a minimum interval (rate limit).
//!
//! # Guarantees (tested in `tests/engine.rs`)
//! * A note on is only queued if, after it, at least [`NOTE_OFF_RESERVE`]
//!   critical slots stay free, so the matching note off always fits. If the
//!   queue is too full the note on is deferred to the next frame and counted.
//! * Every queued note on is followed by its note off before the next note
//!   on of the same voice (release-then-attack on note changes).
//! * Disconnect forgets all queued messages and active notes; the engine
//!   holds nothing that could later sound. Connect queues a reset sequence
//!   and requires the finger to be lifted before the next note (no note from
//!   a touch held across reconnect or present at start-up).
//! * Non-finite inputs are rejected and counted; data bytes are always
//!   `<= 127`.

use heapless::Deque;

use crate::midi::{cc, MidiMessage, BEND_CENTER, BEND_MAX};

/// Capacity of the critical FIFO.
pub const CRITICAL_CAPACITY: usize = 32;
/// Critical slots that must remain free after queueing a note on.
pub const NOTE_OFF_RESERVE: usize = 4;

/// How touch position is turned into a note number.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Scale {
    /// Every semitone.
    Chromatic,
    /// Major pentatonic (0, 2, 4, 7, 9) relative to `base_note`.
    Pentatonic,
    /// Major (0, 2, 4, 5, 7, 9, 11).
    Major,
    /// Natural minor (0, 2, 3, 5, 7, 8, 10).
    Minor,
}

impl Scale {
    /// Semitone offsets of one octave of the scale, ascending from 0.
    pub fn degrees(self) -> &'static [u8] {
        match self {
            Scale::Chromatic => &[0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11],
            Scale::Pentatonic => &[0, 2, 4, 7, 9],
            Scale::Major => &[0, 2, 4, 5, 7, 9, 11],
            Scale::Minor => &[0, 2, 3, 5, 7, 8, 10],
        }
    }

    /// Semitone offset of scale step `i` (may be negative or above one
    /// octave): step 0 = 0, step `degrees().len()` = 12.
    pub fn offset(self, i: i32) -> i32 {
        let d = self.degrees();
        let n = d.len() as i32;
        i.div_euclid(n) * 12 + i32::from(d[i.rem_euclid(n) as usize])
    }

    /// Scale steps closest to `semitones` (for chord tones: a third is 2
    /// steps in a 7-note scale, 2 in pentatonic, 4 in chromatic).
    pub fn steps_for(self, semitones: i32) -> i32 {
        let n = self.degrees().len() as i32;
        (semitones * n * 2 + 12 * semitones.signum()) / 24
    }
}

/// How pitch follows the finger after the note starts.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PitchMode {
    /// The note is chosen (quantised) at touch onset; afterwards 14-bit
    /// pitch bend follows the finger continuously, clamped to
    /// `±bend_range_semitones`. The receiving synth must use the same bend
    /// range: the engine sends RPN 0 on connect, but not every synth obeys it.
    Bend,
    /// The note follows the quantised position with hysteresis; a change
    /// sends note off (old) then note on (new). Pitch bend stays centred.
    Steps,
}

/// What drives the single melodic voice.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Mode {
    /// Trill touch plays the voice (position = pitch, contact size =
    /// velocity / pressure). Motion only sends the two controllers.
    Touch,
    /// Tilt plays stepped notes: roll picks the scale note across
    /// `±tilt_span_deg`, forward pitch past `gate_deg` opens the note and its
    /// depth sets velocity / pressure. Trill touch is ignored for the voice.
    TiltNotes,
    /// Like [`Mode::TiltNotes`] but continuous: the note is chosen at the gate
    /// and roll then bends the pitch smoothly (theremin-like). The receiver's
    /// bend range must equal `bend_range_semitones` (sent as RPN 0).
    Theremin,
    /// Selection and excitation separated (motion-mapping report §6.2):
    /// roll picks a scale step in zones across `±tilt_span_deg` (finer near
    /// level with `zone_quadratic`), forward/back tilt past `gate_deg` picks
    /// the octave above/below (`register_tilt`), and a tap or strike plays
    /// the chosen note on `channel`, velocity from the impact, for
    /// `note_len_us`. With `strike_voicing` and `strike_directions` > 0 the
    /// strike direction adds a chord tone (see [`Engine::voicing_steps`]).
    /// Taps play these notes instead of percussion.
    TiltStrike,
}

/// Motion quantity feeding a controller slot. "Forward/back/right/left"
/// are the signs of pitch and roll in the IMU's own axes (relative to the
/// zero set with [`Engine::zero_orientation`]); which physical direction
/// that is depends on how the board is mounted.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CcSource {
    /// Slot disabled.
    Off,
    /// Rotation-rate magnitude, 0 at rest, 127 at `rotation_full_dps`.
    Rotation,
    /// Positive pitch, 0..`tilt_full_deg` → 0..127.
    PitchForward,
    /// Negative pitch.
    PitchBack,
    /// Positive roll.
    RollRight,
    /// Negative roll.
    RollLeft,
    /// Pitch −`tilt_full_deg`..+`tilt_full_deg` → 0..127, 64 when level.
    PitchCentered,
    /// Roll, centred like [`CcSource::PitchCentered`].
    RollCentered,
}

impl CcSource {
    /// All sources in wire order (0..=7).
    pub const ALL: [CcSource; 8] = [
        CcSource::Off,
        CcSource::Rotation,
        CcSource::PitchForward,
        CcSource::PitchBack,
        CcSource::RollRight,
        CcSource::RollLeft,
        CcSource::PitchCentered,
        CcSource::RollCentered,
    ];
}

/// One configurable motion controller: a source and a CC number.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct CcMap {
    /// What drives it.
    pub source: CcSource,
    /// Controller number, 1..=119.
    pub control: u8,
}

/// IMU axis (the LSM6DS3TR-C's own frame).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Axis {
    /// X.
    X,
    /// Y.
    Y,
    /// Z.
    Z,
}

/// Forward pitch must fall this far below `gate_deg` to close a tilt note.
pub const GATE_HYSTERESIS_DEG: f32 = 3.0;
/// After a flick, an opposite flick within `gesture_cooldown_us` plus this
/// window also counts as a zig-zag.
pub const ZIGZAG_EXTRA_US: u32 = 400_000;
/// A flick needs the rate to fall below this fraction of the threshold
/// before the next one can fire.
pub const GESTURE_QUIET_FRACTION: f32 = 0.3;
/// A sample more than this much *older* than the previous one of the same
/// input is a clock fault (rejected); anything else counts as forward, so a
/// long outage (≥ 35.8 min) never makes later samples look "old".
pub const BACKWARDS_LIMIT_US: u32 = 1_000_000;

/// Engine configuration. Use [`Config::default`] and adjust; values are
/// sanitised by [`Engine::new`] / [`Engine::set_config`].
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Config {
    /// MIDI channel for the touch voice, 0-based (0 = channel 1).
    pub channel: u8,
    /// Note at the left end of the strip (location 0).
    pub base_note: u8,
    /// Semitones across the full strip.
    pub range_semitones: f32,
    /// Note quantisation.
    pub scale: Scale,
    /// Continuous bend or stepped notes.
    pub pitch_mode: PitchMode,
    /// Pitch-bend range in semitones (sent as RPN 0 on connect), 1..=24.
    pub bend_range_semitones: u8,
    /// Steps mode: how far (semitones) the finger must be closer to a new
    /// note than to the current one before switching.
    pub step_hysteresis: f32,
    /// Normalised touch size that starts a note.
    pub touch_on: f32,
    /// Normalised touch size below which a note is released (`< touch_on`).
    pub touch_off: f32,
    /// Normalised touch size mapped to full velocity / pressure.
    pub size_full: f32,
    /// Release the note if no touch frame arrives for this long.
    pub touch_stale_us: u32,
    /// Velocity at the onset threshold (full velocity at `size_full`).
    pub velocity_min: u8,
    /// One-pole smoothing time constant for channel pressure.
    pub pressure_tau_us: u32,
    /// Minimum interval between two messages of one continuous controller.
    pub control_interval_us: u32,
    /// Send motion controllers (CC74 from rotation rate, CC1 from tilt).
    pub motion_enabled: bool,
    /// Rotation rate (deg/s) giving CC74 = 127.
    pub rotation_full_dps: f32,
    /// Forward tilt (deg) giving CC1 = 127; backward tilt gives 0.
    pub tilt_full_deg: f32,
    /// Treat motion as lost if no frame arrives for this long.
    pub motion_stale_us: u32,
    /// Send a percussion note on detected taps.
    pub percussion_enabled: bool,
    /// Percussion channel, 0-based (9 = General MIDI drums).
    pub percussion_channel: u8,
    /// Percussion note number.
    pub percussion_note: u8,
    /// Percussion note length.
    pub percussion_len_us: u32,
    /// Taps are ignored until the gyro has been calibrated this long.
    pub percussion_arm_us: u32,
    /// Tap strength (g above the detector threshold) giving velocity 127.
    pub tap_full_g: f32,
    /// What plays the melodic voice.
    pub mode: Mode,
    /// First motion controller (default rotation → CC74).
    pub cc_a: CcMap,
    /// Second motion controller (default forward tilt → CC1).
    pub cc_b: CcMap,
    /// Fraction of each controller's full scale ignored near its zero (or
    /// centre for centred sources), 0..=0.5.
    pub cc_deadzone: f32,
    /// One-pole smoothing of the motion controllers (0 = none), at most
    /// 500 ms; this is the added latency (time constant).
    pub cc_smoothing_us: u32,
    /// Tilt modes: roll from −span to +span covers `range_semitones`.
    pub tilt_span_deg: f32,
    /// Tilt modes: forward pitch that opens the note (5..=60°).
    pub gate_deg: f32,
    /// Also send the voice's pressure value as this CC (e.g. 11 expression,
    /// 7 volume); 0 = off.
    pub expression_cc: u8,
    /// Tap detector threshold in g (high-passed |a|); applied by the caller's
    /// detector (`motion-synth`), stored here so it travels with the mapping.
    pub tap_threshold_g: f32,
    /// Tap detector refractory time; applied by the caller's detector.
    pub tap_cooldown_us: u32,
    /// Flick gestures about this axis (None = off).
    pub gesture_axis: Option<Axis>,
    /// Rotation rate (deg/s) that counts as a flick.
    pub gesture_threshold_dps: f32,
    /// Minimum time between two flicks.
    pub gesture_cooldown_us: u32,
    /// Negative flick → this note, positive → +1, zig-zag → +2 (percussion
    /// channel, `percussion_len_us` long).
    pub gesture_base_note: u8,
    /// Directional strikes: how many tap directions pick their own note
    /// (0 = off: every tap plays `percussion_note`; 2 = down/up; 4 = +
    /// left/right; 6 = + forward/back). A tap whose direction is ambiguous
    /// plays `percussion_note`.
    pub strike_directions: u8,
    /// Note per direction, in [`StrikeDirection`] order.
    pub strike_notes: [u8; 6],
    /// [`Mode::TiltStrike`]: how long a struck note sounds.
    pub note_len_us: u32,
    /// [`Mode::TiltStrike`]: forward/back tilt past `gate_deg` shifts the
    /// chosen note an octave up/down.
    pub register_tilt: bool,
    /// [`Mode::TiltStrike`]: zones narrow near level and wide towards the
    /// ends (zone edges at (k/n)² of the span, after Rahman et al. 2009).
    pub zone_quadratic: bool,
    /// [`Mode::TiltStrike`]: strike direction adds a chord tone.
    pub strike_voicing: bool,
}

/// Direction of travel of a tap, relative to gravity. Index into
/// [`Config::strike_notes`].
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum StrikeDirection {
    /// Moving down (with gravity).
    Down = 0,
    /// Moving up.
    Up = 1,
    /// Moving left (sensor +Y side when flat).
    Left = 2,
    /// Moving right.
    Right = 3,
    /// Moving forward (sensor +X when flat).
    Forward = 4,
    /// Moving back.
    Back = 5,
}

/// A strike is classified only if its main component is at least this
/// large (unit vector; 0.55 ≈ within 57° of the axis)…
pub const STRIKE_MIN_COMPONENT: f32 = 0.55;
/// …and at least this many times the next largest considered component.
pub const STRIKE_MARGIN: f32 = 1.2;

/// Classify a tap travel direction `[down, forward, right]` (unit vector
/// from the motion processor) into one of `directions` classes (2, 4 or 6).
/// None = ambiguous or classification off.
pub fn classify_strike(dir: [f32; 3], directions: u8) -> Option<StrikeDirection> {
    let [down, forward, right] = dir;
    // (component, positive class, negative class), in priority order.
    let axes = [
        (down, StrikeDirection::Down, StrikeDirection::Up),
        (-right, StrikeDirection::Left, StrikeDirection::Right),
        (forward, StrikeDirection::Forward, StrikeDirection::Back),
    ];
    let n = match directions {
        2 => 1,
        4 => 2,
        6 => 3,
        _ => return None,
    };
    let considered = &axes[..n];
    let mut best = 0;
    for (i, a) in considered.iter().enumerate() {
        if a.0.abs() > considered[best].0.abs() {
            best = i;
        }
    }
    let (v, pos, neg) = considered[best];
    if v.is_nan() || v.abs() < STRIKE_MIN_COMPONENT {
        return None;
    }
    let second = considered
        .iter()
        .enumerate()
        .filter(|(i, _)| *i != best)
        .map(|(_, a)| a.0.abs())
        .fold(0.0f32, f32::max);
    if n > 1 && v.abs() < STRIKE_MARGIN * second {
        return None;
    }
    Some(if v > 0.0 { pos } else { neg })
}

impl Default for Config {
    fn default() -> Self {
        Self {
            channel: 0,
            base_note: 48,
            range_semitones: 24.0,
            scale: Scale::Chromatic,
            pitch_mode: PitchMode::Bend,
            bend_range_semitones: 24,
            step_hysteresis: 0.2,
            touch_on: 0.05,
            touch_off: 0.025,
            size_full: 0.6,
            touch_stale_us: 50_000,
            velocity_min: 30,
            pressure_tau_us: 15_000,
            control_interval_us: 4_000,
            motion_enabled: true,
            rotation_full_dps: 360.0,
            tilt_full_deg: 60.0,
            motion_stale_us: 100_000,
            percussion_enabled: false,
            percussion_channel: 9,
            percussion_note: 39,
            percussion_len_us: 60_000,
            percussion_arm_us: 1_000_000,
            tap_full_g: 3.0,
            mode: Mode::Touch,
            cc_a: CcMap {
                source: CcSource::Rotation,
                control: cc::BRIGHTNESS,
            },
            cc_b: CcMap {
                source: CcSource::PitchForward,
                control: cc::MODULATION,
            },
            cc_deadzone: 0.0,
            cc_smoothing_us: 0,
            tilt_span_deg: 45.0,
            gate_deg: 15.0,
            expression_cc: 0,
            tap_threshold_g: 0.8,
            tap_cooldown_us: 120_000,
            gesture_axis: None,
            gesture_threshold_dps: 400.0,
            gesture_cooldown_us: 300_000,
            gesture_base_note: 60,
            strike_directions: 0,
            // GM drums: snare, crash, kick, closed hi-hat, low tom, ride.
            strike_notes: [38, 49, 36, 42, 45, 51],
            note_len_us: 300_000,
            register_tilt: true,
            zone_quadratic: true,
            strike_voicing: true,
        }
    }
}

fn finite_or(v: f32, d: f32) -> f32 {
    if v.is_finite() {
        v
    } else {
        d
    }
}

impl Config {
    /// Clamp every field into its valid range (non-finite values fall back to
    /// the defaults).
    pub fn sanitized(mut self) -> Self {
        let d = Self::default();
        self.channel &= 0x0F;
        self.percussion_channel &= 0x0F;
        self.base_note = self.base_note.min(127);
        self.percussion_note = self.percussion_note.min(127);
        self.range_semitones = finite_or(self.range_semitones, d.range_semitones).clamp(1.0, 96.0);
        self.bend_range_semitones = self.bend_range_semitones.clamp(1, 24);
        self.step_hysteresis = finite_or(self.step_hysteresis, d.step_hysteresis).clamp(0.0, 0.49);
        self.touch_on = finite_or(self.touch_on, d.touch_on).clamp(0.001, 1.0);
        self.touch_off = finite_or(self.touch_off, d.touch_off).clamp(0.0, self.touch_on * 0.95);
        self.size_full = finite_or(self.size_full, d.size_full).max(self.touch_on + 0.001);
        self.velocity_min = self.velocity_min.clamp(1, 127);
        self.rotation_full_dps = finite_or(self.rotation_full_dps, d.rotation_full_dps).max(1.0);
        self.tilt_full_deg = finite_or(self.tilt_full_deg, d.tilt_full_deg).clamp(1.0, 90.0);
        self.tap_full_g = finite_or(self.tap_full_g, d.tap_full_g).max(0.1);
        self.touch_stale_us = self.touch_stale_us.clamp(1_000, 1_000_000);
        self.motion_stale_us = self.motion_stale_us.clamp(1_000, 1_000_000);
        self.percussion_len_us = self.percussion_len_us.clamp(1_000, 1_000_000);
        self.control_interval_us = self.control_interval_us.min(1_000_000);
        for m in [&mut self.cc_a, &mut self.cc_b] {
            m.control = m.control.clamp(1, 119);
        }
        self.cc_deadzone = finite_or(self.cc_deadzone, 0.0).clamp(0.0, 0.5);
        self.cc_smoothing_us = self.cc_smoothing_us.min(500_000);
        self.tilt_span_deg = finite_or(self.tilt_span_deg, d.tilt_span_deg).clamp(10.0, 90.0);
        self.gate_deg = finite_or(self.gate_deg, d.gate_deg).clamp(5.0, 60.0);
        self.expression_cc = self.expression_cc.min(119);
        self.tap_threshold_g = finite_or(self.tap_threshold_g, d.tap_threshold_g).clamp(0.3, 4.0);
        self.tap_cooldown_us = self.tap_cooldown_us.clamp(50_000, 1_000_000);
        self.gesture_threshold_dps =
            finite_or(self.gesture_threshold_dps, d.gesture_threshold_dps).clamp(100.0, 2000.0);
        self.gesture_cooldown_us = self.gesture_cooldown_us.clamp(100_000, 2_000_000);
        self.gesture_base_note = self.gesture_base_note.min(125);
        self.strike_directions = match self.strike_directions {
            0 => 0,
            1 | 2 => 2,
            3 | 4 => 4,
            _ => 6,
        };
        for n in &mut self.strike_notes {
            *n = (*n).min(127);
        }
        self.note_len_us = self.note_len_us.clamp(20_000, 2_000_000);
        self
    }

    /// Pitch mode actually used by the voice (tilt modes fix it).
    pub fn effective_pitch_mode(&self) -> PitchMode {
        match self.mode {
            Mode::Touch => self.pitch_mode,
            Mode::TiltNotes => PitchMode::Steps,
            Mode::Theremin => PitchMode::Bend,
            Mode::TiltStrike => PitchMode::Steps,
        }
    }
}

/// One fresh touch frame (the first Trill touch).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct TouchSample {
    /// Position along the strip, 0.0 ..= 1.0 (clamped).
    pub location: f32,
    /// Normalised capacitive contact size (0 = none, ~1 = large firm
    /// contact). Not a force measurement.
    pub size: f32,
}

/// One processed IMU frame.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct MotionSample {
    /// Gyro bias calibration complete; motion controls are gated on this.
    pub calibrated: bool,
    /// Smoothed rotation rate magnitude, deg/s.
    pub rotation_dps: f32,
    /// Tilt pitch, degrees (positive = forward).
    pub pitch_deg: f32,
    /// Roll, degrees (−180..180).
    pub roll_deg: f32,
    /// Bias-corrected rotation rate per axis, deg/s (gestures).
    pub gyro_dps: [f32; 3],
    /// Tap detected in this frame: strength in g above the detector threshold.
    pub tap: Option<f32>,
    /// With a tap: unit travel direction `[down, forward, right]` relative
    /// to gravity (`motion_synth` `MotionFrame::tap_dir`); zero if unknown.
    pub tap_dir: [f32; 3],
}

/// Counters for diagnostics.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Stats {
    /// Note ons queued (touch and percussion).
    pub note_on: u32,
    /// Note offs queued.
    pub note_off: u32,
    /// Note ons postponed because the critical queue lacked reserve space.
    pub note_on_deferred: u32,
    /// Emergency All Notes Off sent because a note off did not fit.
    pub emergency_all_notes_off: u32,
    /// Continuous-controller messages emitted.
    pub control_sent: u32,
    /// Continuous updates merged into a not-yet-sent value.
    pub control_coalesced: u32,
    /// Inputs rejected as NaN / infinite.
    pub invalid_inputs: u32,
    /// Inputs rejected because their timestamp went backwards.
    pub stale_inputs: u32,
    /// Notes released because touch frames stopped arriving.
    pub touch_timeouts: u32,
    /// Times the touch sensor was reported lost.
    pub touch_lost: u32,
    /// Times motion went stale or was reported lost.
    pub motion_lost: u32,
    /// Taps that produced a percussion note.
    pub taps: u32,
    /// Directional-strike taps whose direction was ambiguous (they played
    /// the plain percussion note).
    pub strikes_ambiguous: u32,
    /// Flick gestures that produced a note.
    pub gestures: u32,
    /// Transport connects.
    pub connects: u32,
    /// Transport disconnects.
    pub disconnects: u32,
    /// Highest critical-queue occupancy seen.
    pub critical_high_water: u32,
}

#[derive(Clone, Copy, Debug)]
struct Slot {
    active: bool,
    target: f32,
    sent: Option<u16>,
    last_sent: Option<u32>,
    deadband: f32,
    max: u16,
    force: bool,
}

impl Slot {
    const fn new(deadband: f32, max: u16) -> Self {
        Self {
            active: false,
            target: 0.0,
            sent: None,
            last_sent: None,
            deadband,
            max,
            force: false,
        }
    }

    fn quantised(&self) -> u16 {
        let t = self.target.clamp(0.0, self.max as f32);
        ((t + 0.5) as u16).min(self.max)
    }

    fn pending(&self) -> bool {
        if !self.active {
            return false;
        }
        let q = self.quantised();
        match self.sent {
            None => true,
            Some(s) if self.force => s != q,
            Some(s) => q != s && (self.target - s as f32).abs() >= self.deadband,
        }
    }

    fn set(&mut self, v: f32, stats: &mut Stats) {
        if self.pending() {
            stats.control_coalesced = stats.control_coalesced.wrapping_add(1);
        }
        self.target = v;
        self.active = true;
    }

    fn force(&mut self, v: f32) {
        self.target = v;
        self.active = true;
        self.force = self.sent != Some(self.quantised());
    }

    fn mark_sent(&mut self, v: u16, now: Option<u32>) {
        self.sent = Some(v);
        self.target = v as f32;
        self.last_sent = now;
        self.force = false;
    }

    fn reset(&mut self, sent: Option<u16>) {
        self.active = sent.is_some();
        self.target = sent.unwrap_or(0) as f32;
        self.sent = sent;
        self.last_sent = None;
        self.force = false;
    }

    fn due(&self, now: u32, interval: u32) -> Option<u16> {
        if !self.pending() {
            return None;
        }
        if !self.force {
            if let Some(t) = self.last_sent {
                // Elapsed as u32: a slot idle for more than 35.8 min must
                // not look "sent in the future" (signed compare would block
                // it for the next 35.8 min). `now` and `t` both come from
                // `next_message`, which is monotonic.
                if now.wrapping_sub(t) < interval {
                    return None;
                }
            }
        }
        Some(self.quantised())
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
struct Voice {
    note: u8,
    /// Semitone offset of `note` from `base_note`.
    offset: f32,
    velocity: u8,
}

/// The engine. See the module documentation.
#[derive(Debug)]
pub struct Engine {
    cfg: Config,
    connected: bool,
    critical: Deque<MidiMessage, CRITICAL_CAPACITY>,
    emergency_all_off: bool,
    pressure: Slot,
    expr: Slot,
    bend: Slot,
    cc_a: Slot,
    cc_b: Slot,
    cc_smooth: [Option<f32>; 2],
    voice: Option<Voice>,
    armed: bool,
    last_touch: Option<u32>,
    pressure_smooth: f32,
    last_motion: Option<u32>,
    motion_ok: bool,
    calibrated_since: Option<u32>,
    /// Latched once the gyro has stayed calibrated for `percussion_arm_us`.
    /// A latch (not a timestamp comparison on every tap) because the u32
    /// microsecond clock makes "since + arm <= now" ambiguous after 35.8 min.
    motion_armed: bool,
    orientation: Option<(f32, f32)>,
    zero: (f32, f32),
    flick_quiet: bool,
    last_flick: Option<(u32, bool)>,
    percussion_off_at: Option<(u8, u8, u32)>,
    gesture_off_at: [Option<(u8, u8, u32)>; 2],
    /// [`Mode::TiltStrike`] selection: scale zone (with hysteresis) and
    /// register (−1, 0, +1).
    zone: Option<usize>,
    register: i8,
    /// [`Mode::TiltStrike`] sounding note: (channel, note, start time).
    strike_off_at: Option<(u8, u8, u32)>,
    stats: Stats,
}

/// Wrapping "a is earlier than b".
fn before(a: u32, b: u32) -> bool {
    (b.wrapping_sub(a) as i32) > 0
}

fn wrap180(v: f32) -> f32 {
    let mut x = v % 360.0;
    if x > 180.0 {
        x -= 360.0;
    } else if x < -180.0 {
        x += 360.0;
    }
    x
}

fn unit(v: f32) -> f32 {
    v.clamp(0.0, 1.0)
}

fn round_pos(v: f32) -> f32 {
    // v >= 0 here.
    ((v + 0.5) as i32) as f32
}

impl Engine {
    /// New engine, disconnected, no voice, not armed.
    pub fn new(cfg: Config) -> Self {
        Self {
            cfg: cfg.sanitized(),
            connected: false,
            critical: Deque::new(),
            emergency_all_off: false,
            pressure: Slot::new(0.75, 127),
            expr: Slot::new(0.75, 127),
            bend: Slot::new(4.0, BEND_MAX),
            cc_a: Slot::new(0.75, 127),
            cc_b: Slot::new(0.75, 127),
            cc_smooth: [None; 2],
            voice: None,
            armed: false,
            last_touch: None,
            pressure_smooth: 0.0,
            last_motion: None,
            motion_ok: false,
            calibrated_since: None,
            motion_armed: false,
            orientation: None,
            zero: (0.0, 0.0),
            flick_quiet: false,
            last_flick: None,
            percussion_off_at: None,
            gesture_off_at: [None; 2],
            zone: None,
            register: 0,
            strike_off_at: None,
            stats: Stats::default(),
        }
    }

    /// Current (sanitised) configuration.
    pub fn config(&self) -> &Config {
        &self.cfg
    }

    /// Counters.
    pub fn stats(&self) -> Stats {
        self.stats
    }

    /// Transport connected.
    pub fn is_connected(&self) -> bool {
        self.connected
    }

    /// Currently sounding touch note, if any.
    pub fn active_note(&self) -> Option<u8> {
        self.voice.map(|v| v.note)
    }

    /// True once a no-touch frame has been seen since start/connect, i.e. the
    /// next touch above threshold will start a note.
    pub fn is_armed(&self) -> bool {
        self.armed
    }

    /// Messages waiting in the critical FIFO.
    pub fn critical_len(&self) -> usize {
        self.critical.len()
    }

    /// Replace the configuration. A sounding note is released first and, if
    /// the bend range or mode changed, the bend is re-centred and RPN 0 resent.
    pub fn set_config(&mut self, cfg: Config) {
        let cfg = cfg.sanitized();
        if cfg == self.cfg {
            return;
        }
        self.release_voice(false);
        // A new mapping must not re-trigger under a held finger.
        self.armed = false;
        self.percussion_release();
        self.gesture_release();
        self.strike_release();
        self.zone = None;
        let old = self.cfg;
        // Controllers whose number or source changes (or that are switched
        // off) go back to 0 on their old number first, so nothing is left
        // stuck at the synth.
        let motion_on = |c: &Config, m: CcMap| c.motion_enabled && m.source != CcSource::Off;
        for (i, (o, n)) in [(old.cc_a, cfg.cc_a), (old.cc_b, cfg.cc_b)]
            .into_iter()
            .enumerate()
        {
            let changed = o != n || motion_on(&old, o) != motion_on(&cfg, n);
            if changed {
                let slot = if i == 0 {
                    &mut self.cc_a
                } else {
                    &mut self.cc_b
                };
                let sent = slot.sent;
                slot.reset(None);
                self.cc_smooth[i] = None;
                self.zero_cc(old.channel, o.control, sent);
            }
        }
        if old.expression_cc != cfg.expression_cc || old.channel != cfg.channel {
            let sent = self.expr.sent;
            self.expr.reset(None);
            if old.expression_cc != 0 {
                self.zero_cc(old.channel, old.expression_cc, sent);
            }
        }
        if old.gesture_axis != cfg.gesture_axis {
            self.flick_quiet = false;
            self.last_flick = None;
        }
        if self.connected
            && (old.channel != cfg.channel
                || old.effective_pitch_mode() != cfg.effective_pitch_mode()
                || old.bend_range_semitones != cfg.bend_range_semitones)
        {
            self.cfg = cfg;
            self.channel_reset(cfg.channel, true);
        } else {
            self.cfg = cfg;
        }
    }

    fn zero_cc(&mut self, channel: u8, control: u8, sent: Option<u16>) {
        if self.connected && sent.is_some_and(|v| v != 0) {
            let _ = self.critical.push_back(MidiMessage::ControlChange {
                channel,
                control,
                value: 0,
            });
            self.note_high_water();
        }
    }

    /// Make the current orientation the zero for pitch and roll (tilt modes
    /// and tilt controllers). A tilt-mode note is released first so pitch
    /// cannot jump under it. Returns false if no orientation is known yet.
    pub fn zero_orientation(&mut self) -> bool {
        let Some(o) = self.orientation else {
            return false;
        };
        self.zero = o;
        if self.cfg.mode != Mode::Touch {
            self.release_voice(false);
            self.armed = false;
        }
        true
    }

    /// Forget the orientation zero (back to the IMU's own axes).
    pub fn clear_zero(&mut self) {
        self.zero = (0.0, 0.0);
    }

    /// Current orientation zero (pitch, roll), degrees.
    pub fn orientation_zero(&self) -> (f32, f32) {
        self.zero
    }

    /// Transport became usable: queue the reset sequence and wait for the
    /// finger to be lifted before the next note.
    pub fn connect(&mut self, _now: u32) {
        self.connected = true;
        self.stats.connects = self.stats.connects.wrapping_add(1);
        self.reset_output();
    }

    /// Transport went away: forget everything that could sound later.
    pub fn disconnect(&mut self) {
        if self.connected {
            self.stats.disconnects = self.stats.disconnects.wrapping_add(1);
        }
        self.connected = false;
        self.critical.clear();
        self.emergency_all_off = false;
        self.voice = None;
        self.percussion_off_at = None;
        self.gesture_off_at = [None; 2];
        self.strike_off_at = None;
        self.armed = false;
        for s in [
            &mut self.pressure,
            &mut self.expr,
            &mut self.bend,
            &mut self.cc_a,
            &mut self.cc_b,
        ] {
            s.reset(None);
        }
        self.cc_smooth = [None; 2];
    }

    /// User panic: same reset sequence as on connect (no-op if disconnected).
    pub fn panic(&mut self, _now: u32) {
        if self.connected {
            self.reset_output();
        }
    }

    fn reset_output(&mut self) {
        self.critical.clear();
        self.emergency_all_off = false;
        self.voice = None;
        self.percussion_off_at = None;
        self.gesture_off_at = [None; 2];
        self.strike_off_at = None;
        self.armed = false;
        self.channel_reset(self.cfg.channel, true);
        if self.cfg.percussion_channel != self.cfg.channel {
            self.channel_reset(self.cfg.percussion_channel, false);
        }
        self.pressure.reset(Some(0));
        self.bend.reset(Some(BEND_CENTER));
        self.cc_a.reset(None);
        self.cc_b.reset(None);
        self.expr.reset(None);
        self.cc_smooth = [None; 2];
    }

    /// CC123, CC120, bend centre (+ pressure 0 and RPN 0 for the voice channel).
    fn channel_reset(&mut self, channel: u8, voice_channel: bool) {
        let mut push = |m| {
            let _ = self.critical.push_back(m);
        };
        let ccm = |control, value| MidiMessage::ControlChange {
            channel,
            control,
            value,
        };
        push(ccm(cc::ALL_NOTES_OFF, 0));
        push(ccm(cc::ALL_SOUND_OFF, 0));
        push(MidiMessage::PitchBend {
            channel,
            value: BEND_CENTER,
        });
        if voice_channel {
            push(MidiMessage::ChannelPressure { channel, value: 0 });
            push(ccm(cc::RPN_MSB, 0));
            push(ccm(cc::RPN_LSB, 0));
            push(ccm(cc::DATA_ENTRY_MSB, self.cfg.bend_range_semitones));
            push(ccm(cc::DATA_ENTRY_LSB, 0));
            push(ccm(cc::RPN_MSB, 127));
            push(ccm(cc::RPN_LSB, 127));
            self.bend.reset(Some(BEND_CENTER));
        }
        self.note_high_water();
    }

    fn note_high_water(&mut self) {
        let n = self.critical.len() as u32;
        if n > self.stats.critical_high_water {
            self.stats.critical_high_water = n;
        }
    }

    fn free(&self) -> usize {
        CRITICAL_CAPACITY - self.critical.len()
    }

    fn push_note_off(&mut self, channel: u8, note: u8) {
        let m = MidiMessage::NoteOff {
            channel,
            note,
            velocity: 64,
        };
        if self.critical.push_back(m).is_err() {
            self.emergency_all_off = true;
            self.stats.emergency_all_notes_off = self.stats.emergency_all_notes_off.wrapping_add(1);
        } else {
            self.stats.note_off = self.stats.note_off.wrapping_add(1);
        }
        self.note_high_water();
    }

    fn accept_time(last: &mut Option<u32>, t: u32, stats: &mut Stats) -> bool {
        if let Some(p) = *last {
            let back = p.wrapping_sub(t);
            if back != 0 && back < BACKWARDS_LIMIT_US {
                stats.stale_inputs = stats.stale_inputs.wrapping_add(1);
                return false;
            }
        }
        *last = Some(t);
        true
    }

    /// Semitone offset for a strip position.
    fn position(&self, location: f32) -> f32 {
        unit(location) * self.cfg.range_semitones
    }

    fn quantise(&self, s: f32) -> f32 {
        let range = self.cfg.range_semitones;
        let top = (range as i32) as f32; // highest whole semitone on the strip
        match self.cfg.scale {
            Scale::Chromatic => round_pos(s).min(top),
            scale => {
                let oct = ((s / 12.0) as i32) as f32 * 12.0;
                let mut best = 0.0f32;
                let mut best_d = f32::MAX;
                for o in [oct - 12.0, oct, oct + 12.0] {
                    for &d in scale.degrees() {
                        let n = o + f32::from(d);
                        if n < 0.0 || n > top {
                            continue;
                        }
                        let dist = (s - n).abs();
                        if dist < best_d {
                            best_d = dist;
                            best = n;
                        }
                    }
                }
                best
            }
        }
    }

    fn bend_value(&self, semis: f32) -> u16 {
        let r = self.cfg.bend_range_semitones as f32;
        let x = (semis / r).clamp(-1.0, 1.0);
        let v = BEND_CENTER as f32 + x * 8191.0;
        ((v + 0.5) as u16).min(BEND_MAX)
    }

    fn velocity(&self, size: f32) -> u8 {
        let c = &self.cfg;
        let x = unit((size - c.touch_on) / (c.size_full - c.touch_on));
        let v = c.velocity_min as f32 + x * (127 - c.velocity_min) as f32;
        ((v + 0.5) as u8).clamp(1, 127)
    }

    fn pressure_target(&self, size: f32) -> f32 {
        let c = &self.cfg;
        unit((size - c.touch_off) / (c.size_full - c.touch_off)) * 127.0
    }

    /// Feed one fresh touch frame (`None` = no touch). Ignored for the
    /// voice in the tilt modes.
    pub fn touch(&mut self, t: u32, sample: Option<TouchSample>) {
        if self.cfg.mode != Mode::Touch {
            return;
        }
        self.apply_touch(t, sample);
    }

    fn apply_touch(&mut self, t: u32, sample: Option<TouchSample>) {
        if let Some(s) = sample {
            if !s.location.is_finite() || !s.size.is_finite() {
                self.stats.invalid_inputs = self.stats.invalid_inputs.wrapping_add(1);
                return;
            }
        }
        let prev = self.last_touch;
        if !Self::accept_time(&mut self.last_touch, t, &mut self.stats) {
            return;
        }
        let (location, size) = match sample {
            Some(s) => (unit(s.location), s.size.max(0.0)),
            None => (0.0, 0.0),
        };
        let held = size >= self.cfg.touch_off && sample.is_some();
        match self.voice {
            Some(v) => {
                if held {
                    let dt = prev.map_or(0, |p| t.wrapping_sub(p));
                    self.update_voice(v, dt, location, size);
                } else {
                    self.release_voice(true);
                }
            }
            None => {
                if !held {
                    self.armed = true;
                } else if self.armed && self.connected && size >= self.cfg.touch_on {
                    self.onset(location, size);
                }
            }
        }
    }

    fn onset(&mut self, location: f32, size: f32) {
        let s = self.position(location);
        let offset = self.quantise(s);
        let note = self.cfg.base_note as f32 + offset;
        if note > 127.0 {
            return;
        }
        let note = note as u8;
        let bend_mode = self.cfg.effective_pitch_mode() == PitchMode::Bend;
        let needed = 1 + usize::from(bend_mode) + NOTE_OFF_RESERVE;
        if self.free() < needed {
            self.stats.note_on_deferred = self.stats.note_on_deferred.wrapping_add(1);
            return;
        }
        let channel = self.cfg.channel;
        if bend_mode {
            let b = self.bend_value(s - offset);
            let _ = self
                .critical
                .push_back(MidiMessage::PitchBend { channel, value: b });
            self.bend.mark_sent(b, None);
            self.bend.active = true;
        }
        let velocity = self.velocity(size);
        let _ = self.critical.push_back(MidiMessage::NoteOn {
            channel,
            note,
            velocity,
        });
        self.note_high_water();
        self.stats.note_on = self.stats.note_on.wrapping_add(1);
        self.voice = Some(Voice {
            note,
            offset,
            velocity,
        });
        self.pressure_smooth = self.pressure_target(size);
        self.set_pressure(self.pressure_smooth);
    }

    fn set_pressure(&mut self, v: f32) {
        self.pressure.set(v, &mut self.stats);
        if self.cfg.expression_cc != 0 {
            self.expr.set(v, &mut self.stats);
        }
    }

    fn update_voice(&mut self, v: Voice, dt: u32, location: f32, size: f32) {
        let s = self.position(location);
        match self.cfg.effective_pitch_mode() {
            PitchMode::Bend => {
                let b = self.bend_value(s - v.offset) as f32;
                self.bend.set(b, &mut self.stats);
            }
            PitchMode::Steps => {
                let cand = self.quantise(s);
                if cand != v.offset
                    && (s - v.offset).abs() - (s - cand).abs() > self.cfg.step_hysteresis
                {
                    // Release, then attack the new note (if it fits).
                    self.release_voice(false);
                    self.armed = true;
                    self.onset(location, size);
                    return;
                }
            }
        }
        let target = self.pressure_target(size);
        let tau = self.cfg.pressure_tau_us as f32;
        let dt = dt.min(1_000_000) as f32;
        let a = if tau <= 0.0 { 1.0 } else { dt / (tau + dt) };
        self.pressure_smooth += a * (target - self.pressure_smooth);
        self.set_pressure(self.pressure_smooth);
    }

    /// Release the touch voice. `rearm`: a normal lift (the next touch may
    /// play); otherwise the caller decides.
    fn release_voice(&mut self, rearm: bool) {
        if let Some(v) = self.voice.take() {
            self.push_note_off(self.cfg.channel, v.note);
            self.pressure.force(0.0);
            if self.cfg.expression_cc != 0 {
                self.expr.force(0.0);
            }
        }
        if rearm {
            self.armed = true;
        }
    }

    /// The touch sensor stopped answering: release and disarm.
    pub fn touch_lost(&mut self, _now: u32) {
        self.stats.touch_lost = self.stats.touch_lost.wrapping_add(1);
        if self.cfg.mode == Mode::Touch {
            self.release_voice(false);
            self.armed = false;
        }
    }

    /// Feed one processed IMU frame.
    pub fn motion(&mut self, t: u32, m: MotionSample) {
        if !m.rotation_dps.is_finite()
            || !m.pitch_deg.is_finite()
            || !m.roll_deg.is_finite()
            || m.gyro_dps.iter().any(|g| !g.is_finite())
            || m.tap.is_some_and(|g| !g.is_finite())
            || m.tap_dir.iter().any(|d| !d.is_finite())
        {
            self.stats.invalid_inputs = self.stats.invalid_inputs.wrapping_add(1);
            return;
        }
        let prev = self.last_motion;
        if !Self::accept_time(&mut self.last_motion, t, &mut self.stats) {
            return;
        }
        self.motion_ok = true;
        self.orientation = Some((m.pitch_deg, m.roll_deg));
        if !m.calibrated {
            self.calibrated_since = None;
            self.motion_armed = false;
            self.tilt_voice_stop();
            return;
        }
        let since = *self.calibrated_since.get_or_insert(t);
        // Elapsed since calibration as u32 is exact while < 71.6 min; this
        // runs on every IMU sample (416 Hz), so the latch is set within one
        // sample of the arm time, long before any ambiguity.
        if !self.motion_armed && t.wrapping_sub(since) >= self.cfg.percussion_arm_us {
            self.motion_armed = true;
        }
        if !self.connected {
            return;
        }
        let c = self.cfg;
        let pitch = m.pitch_deg - self.zero.0;
        let roll = wrap180(m.roll_deg - self.zero.1);
        let dt = prev.map_or(0, |p| t.wrapping_sub(p)).min(1_000_000);
        if c.motion_enabled {
            for i in 0..2 {
                let map = if i == 0 { c.cc_a } else { c.cc_b };
                if let Some(v) = self.cc_value(map.source, &m, pitch, roll) {
                    let a = if c.cc_smoothing_us == 0 {
                        1.0
                    } else {
                        dt as f32 / (c.cc_smoothing_us as f32 + dt as f32)
                    };
                    let y = match self.cc_smooth[i] {
                        Some(old) => old + a * (v - old),
                        None => v,
                    };
                    self.cc_smooth[i] = Some(y);
                    let slot = if i == 0 {
                        &mut self.cc_a
                    } else {
                        &mut self.cc_b
                    };
                    slot.set(y * 127.0, &mut self.stats);
                }
            }
        }
        match c.mode {
            Mode::TiltNotes | Mode::Theremin => self.tilt_voice(t, pitch, roll),
            Mode::TiltStrike => self.select(pitch, roll),
            Mode::Touch => {}
        }
        if !self.motion_armed {
            return;
        }
        if let (Some(g), Mode::TiltStrike) = (m.tap, c.mode) {
            if g > 0.0 {
                let dir = if c.strike_voicing && c.strike_directions > 0 {
                    classify_strike(m.tap_dir, c.strike_directions)
                } else {
                    None
                };
                self.strike_note(t, g, dir);
            }
        } else if let Some(g) = m.tap {
            if c.percussion_enabled && g > 0.0 {
                let note = if c.strike_directions == 0 {
                    c.percussion_note
                } else if let Some(d) = classify_strike(m.tap_dir, c.strike_directions) {
                    c.strike_notes[d as usize]
                } else {
                    self.stats.strikes_ambiguous = self.stats.strikes_ambiguous.wrapping_add(1);
                    c.percussion_note
                };
                self.percussion_hit(t, g, note);
            }
        }
        if let Some(axis) = c.gesture_axis {
            let w = m.gyro_dps[match axis {
                Axis::X => 0,
                Axis::Y => 1,
                Axis::Z => 2,
            }];
            if let Some((positive, zigzag)) = self.flick(t, w) {
                self.gesture_hit(t, positive, zigzag, w.abs());
            }
        }
    }

    /// Unit value (0..=1) for a controller source after the deadzone.
    fn cc_value(&self, src: CcSource, m: &MotionSample, pitch: f32, roll: f32) -> Option<f32> {
        let c = &self.cfg;
        let dz = c.cc_deadzone;
        let uni = |x: f32| {
            let u = unit(x);
            if u <= dz {
                0.0
            } else {
                (u - dz) / (1.0 - dz)
            }
        };
        let centred = |x: f32| {
            let x = x.clamp(-1.0, 1.0);
            0.5 + 0.5 * x.signum() * uni(x.abs())
        };
        let tilt = c.tilt_full_deg;
        Some(match src {
            CcSource::Off => return None,
            CcSource::Rotation => uni(m.rotation_dps.abs() / c.rotation_full_dps),
            CcSource::PitchForward => uni(pitch / tilt),
            CcSource::PitchBack => uni(-pitch / tilt),
            CcSource::RollRight => uni(roll / tilt),
            CcSource::RollLeft => uni(-roll / tilt),
            CcSource::PitchCentered => centred(pitch / tilt),
            CcSource::RollCentered => centred(roll / tilt),
        })
    }

    /// Tilt modes: turn orientation into a virtual touch for the voice.
    fn tilt_voice(&mut self, t: u32, pitch: f32, roll: f32) {
        let c = self.cfg;
        let span = c.tilt_span_deg;
        let location = unit((roll + span) / (2.0 * span));
        let open = if self.voice.is_some() {
            pitch >= c.gate_deg - GATE_HYSTERESIS_DEG
        } else {
            pitch >= c.gate_deg
        };
        let sample = open.then(|| {
            let depth = unit((pitch - c.gate_deg) / c.tilt_full_deg);
            TouchSample {
                location,
                size: c.touch_on + (c.size_full - c.touch_on) * (0.4 + 0.6 * depth),
            }
        });
        self.apply_touch(t, sample);
    }

    /// Tilt modes: motion became unusable; end the note and disarm.
    fn tilt_voice_stop(&mut self) {
        if self.cfg.mode != Mode::Touch {
            self.release_voice(false);
            self.armed = false;
        }
        self.zone = None;
    }

    /// [`Mode::TiltStrike`]: number of scale steps between `base_note` and
    /// `base_note + range_semitones` (inclusive), at least 1.
    pub fn zone_count(&self) -> usize {
        let top = self.cfg.range_semitones as i32;
        let mut n = 0;
        while n < 128 && self.cfg.scale.offset(n as i32) <= top {
            n += 1;
        }
        n.max(1)
    }

    /// [`Mode::TiltStrike`]: current selection (scale zone, register).
    pub fn selection(&self) -> Option<(usize, i8)> {
        self.zone.map(|z| (z, self.register))
    }

    /// Update the zone (roll) and register (pitch) with hysteresis.
    fn select(&mut self, pitch: f32, roll: f32) {
        let c = self.cfg;
        let n = self.zone_count();
        let x = (roll / c.tilt_span_deg).clamp(-1.0, 1.0);
        let y = if c.zone_quadratic {
            x.signum() * libm::sqrtf(x.abs())
        } else {
            x
        };
        let pos = (y + 1.0) * 0.5 * n as f32;
        let h = c.step_hysteresis;
        self.zone = Some(match self.zone {
            Some(z) if z < n && pos >= z as f32 - h && pos < (z + 1) as f32 + h => z,
            _ => (pos as usize).min(n - 1),
        });
        self.register = if !c.register_tilt {
            0
        } else {
            let (thr, hy) = (c.gate_deg, GATE_HYSTERESIS_DEG);
            match self.register {
                1 if pitch >= thr - hy => 1,
                -1 if pitch <= -(thr - hy) => -1,
                _ if pitch >= thr => 1,
                _ if pitch <= -thr => -1,
                _ => 0,
            }
        };
    }

    /// Chord tone added by a strike direction, in scale steps: down = the
    /// chosen note, up = octave above, left = third, right = fifth,
    /// forward = second (ninth), back = octave below.
    pub fn voicing_steps(scale: Scale, dir: Option<StrikeDirection>) -> i32 {
        let n = scale.degrees().len() as i32;
        match dir {
            None | Some(StrikeDirection::Down) => 0,
            Some(StrikeDirection::Up) => n,
            Some(StrikeDirection::Left) => scale.steps_for(4),
            Some(StrikeDirection::Right) => scale.steps_for(7),
            Some(StrikeDirection::Forward) => scale.steps_for(2),
            Some(StrikeDirection::Back) => -n,
        }
    }

    /// [`Mode::TiltStrike`]: play the selected note now.
    fn strike_note(&mut self, t: u32, g: f32, dir: Option<StrikeDirection>) {
        let Some(zone) = self.zone else {
            return;
        };
        self.strike_release();
        if self.free() < 1 + NOTE_OFF_RESERVE {
            self.stats.note_on_deferred = self.stats.note_on_deferred.wrapping_add(1);
            return;
        }
        let c = self.cfg;
        let step = zone as i32 + Self::voicing_steps(c.scale, dir);
        let n = i32::from(c.base_note) + c.scale.offset(step) + 12 * i32::from(self.register);
        let note = n.clamp(0, 127) as u8;
        let v = c.velocity_min as f32 + unit(g / c.tap_full_g) * (127 - c.velocity_min) as f32;
        let velocity = ((v + 0.5) as u8).clamp(1, 127);
        let _ = self.critical.push_back(MidiMessage::NoteOn {
            channel: c.channel,
            note,
            velocity,
        });
        self.note_high_water();
        self.stats.note_on = self.stats.note_on.wrapping_add(1);
        self.stats.taps = self.stats.taps.wrapping_add(1);
        self.strike_off_at = Some((c.channel, note, t));
    }

    fn strike_release(&mut self) {
        if let Some((ch, note, _)) = self.strike_off_at.take() {
            self.push_note_off(ch, note);
        }
    }

    /// Flick recogniser on one gyro axis. Fires on the sample where |rate|
    /// first reaches the threshold, provided the rate fell below
    /// [`GESTURE_QUIET_FRACTION`] of it since the last flick and the cooldown
    /// has passed. Returns (positive direction, completes a zig-zag).
    fn flick(&mut self, t: u32, w: f32) -> Option<(bool, bool)> {
        let c = &self.cfg;
        let thr = c.gesture_threshold_dps;
        if let Some((lt, _)) = self.last_flick {
            // Forget it once it can no longer matter; this runs every sample,
            // so the u32 elapsed value is never ambiguous.
            if t.wrapping_sub(lt) > c.gesture_cooldown_us.saturating_add(ZIGZAG_EXTRA_US) {
                self.last_flick = None;
            }
        }
        let a = w.abs();
        if a < thr * GESTURE_QUIET_FRACTION {
            self.flick_quiet = true;
            return None;
        }
        if !self.flick_quiet || a < thr {
            return None;
        }
        if let Some((lt, _)) = self.last_flick {
            if t.wrapping_sub(lt) < c.gesture_cooldown_us {
                return None;
            }
        }
        let positive = w > 0.0;
        let zigzag = matches!(self.last_flick, Some((_, p)) if p != positive);
        self.flick_quiet = false;
        self.last_flick = Some((t, positive));
        Some((positive, zigzag))
    }

    fn gesture_hit(&mut self, t: u32, positive: bool, zigzag: bool, rate: f32) {
        self.gesture_release();
        let n = 1 + usize::from(zigzag);
        if self.free() < n + NOTE_OFF_RESERVE {
            self.stats.note_on_deferred = self.stats.note_on_deferred.wrapping_add(1);
            return;
        }
        let c = self.cfg;
        let thr = c.gesture_threshold_dps;
        let v = 64.0 + unit((rate - thr) / thr) * 63.0;
        let velocity = ((v + 0.5) as u8).clamp(1, 127);
        let base = c.gesture_base_note;
        let notes = [base + u8::from(positive), base + 2];
        for (i, &note) in notes.iter().take(n).enumerate() {
            let _ = self.critical.push_back(MidiMessage::NoteOn {
                channel: c.percussion_channel,
                note,
                velocity,
            });
            self.stats.note_on = self.stats.note_on.wrapping_add(1);
            self.gesture_off_at[i] = Some((c.percussion_channel, note, t));
        }
        self.note_high_water();
        self.stats.gestures = self.stats.gestures.wrapping_add(1);
    }

    fn gesture_release(&mut self) {
        for i in 0..2 {
            if let Some((ch, note, _)) = self.gesture_off_at[i].take() {
                self.push_note_off(ch, note);
            }
        }
    }

    fn percussion_hit(&mut self, t: u32, g: f32, note: u8) {
        self.percussion_release();
        if self.free() < 1 + NOTE_OFF_RESERVE {
            self.stats.note_on_deferred = self.stats.note_on_deferred.wrapping_add(1);
            return;
        }
        let c = self.cfg;
        let v = 40.0 + unit(g / c.tap_full_g) * 87.0;
        let velocity = ((v + 0.5) as u8).clamp(1, 127);
        let _ = self.critical.push_back(MidiMessage::NoteOn {
            channel: c.percussion_channel,
            note,
            velocity,
        });
        self.note_high_water();
        self.stats.note_on = self.stats.note_on.wrapping_add(1);
        self.stats.taps = self.stats.taps.wrapping_add(1);
        self.percussion_off_at = Some((
            c.percussion_channel,
            note,
            t.wrapping_add(c.percussion_len_us),
        ));
    }

    fn percussion_release(&mut self) {
        if let Some((ch, note, _)) = self.percussion_off_at.take() {
            self.push_note_off(ch, note);
        }
    }

    /// The IMU stopped producing frames: end any percussion note and return
    /// the motion controllers to 0. Touch is unaffected.
    pub fn motion_lost(&mut self, _now: u32) {
        self.stats.motion_lost = self.stats.motion_lost.wrapping_add(1);
        self.motion_ok = false;
        self.calibrated_since = None;
        self.motion_armed = false;
        self.percussion_release();
        self.gesture_release();
        self.strike_release();
        self.tilt_voice_stop();
        self.cc_smooth = [None; 2];
        if self.connected {
            for s in [&mut self.cc_a, &mut self.cc_b] {
                if s.sent.is_some_and(|v| v != 0) {
                    s.force(0.0);
                }
            }
        }
    }

    /// Housekeeping: stale-touch release, motion timeout, percussion length.
    pub fn tick(&mut self, now: u32) {
        if self.voice.is_some() {
            if let Some(t) = self.last_touch {
                if (now.wrapping_sub(t) as i32) > self.cfg.touch_stale_us as i32 {
                    self.stats.touch_timeouts = self.stats.touch_timeouts.wrapping_add(1);
                    self.release_voice(false);
                    self.armed = false;
                }
            }
        }
        if self.motion_ok {
            if let Some(t) = self.last_motion {
                if (now.wrapping_sub(t) as i32) > self.cfg.motion_stale_us as i32 {
                    self.motion_lost(now);
                }
            }
        }
        if let Some((_, _, at)) = self.percussion_off_at {
            if !before(now, at) {
                self.percussion_release();
            }
        }
        if let Some((_, _, start)) = self.strike_off_at {
            // Signed like the gesture notes: `start` is an IMU timestamp.
            if (now.wrapping_sub(start) as i32) >= self.cfg.note_len_us as i32 {
                self.strike_release();
            }
        }
        for i in 0..2 {
            if let Some((ch, note, start)) = self.gesture_off_at[i] {
                // Signed: `start` comes from the IMU task and may be a few
                // µs ahead of `now`; the interval is short.
                if (now.wrapping_sub(start) as i32) >= self.cfg.percussion_len_us as i32 {
                    self.gesture_off_at[i] = None;
                    self.push_note_off(ch, note);
                }
            }
        }
    }

    /// Next message to transmit, in priority order (see module docs). `now`
    /// drives the continuous-controller rate limit; the message is
    /// considered sent when returned.
    pub fn next_message(&mut self, now: u32) -> Option<MidiMessage> {
        if !self.connected {
            return None;
        }
        if self.emergency_all_off {
            self.emergency_all_off = false;
            return Some(MidiMessage::ControlChange {
                channel: self.cfg.channel,
                control: cc::ALL_NOTES_OFF,
                value: 0,
            });
        }
        if let Some(m) = self.critical.pop_front() {
            return Some(m);
        }
        let interval = self.cfg.control_interval_us;
        let channel = self.cfg.channel;
        let c = &self.cfg;
        let motion = c.motion_enabled || self.cc_a.force || self.cc_b.force;
        let msg = if let Some(v) = self.pressure.due(now, interval) {
            self.pressure.mark_sent(v, Some(now));
            MidiMessage::ChannelPressure {
                channel,
                value: v as u8,
            }
        } else if let Some(v) = (c.expression_cc != 0)
            .then(|| self.expr.due(now, interval))
            .flatten()
        {
            self.expr.mark_sent(v, Some(now));
            MidiMessage::ControlChange {
                channel,
                control: c.expression_cc,
                value: v as u8,
            }
        } else if let Some(v) = (c.effective_pitch_mode() == PitchMode::Bend)
            .then(|| self.bend.due(now, interval))
            .flatten()
        {
            self.bend.mark_sent(v, Some(now));
            MidiMessage::PitchBend { channel, value: v }
        } else if let Some(v) = motion.then(|| self.cc_a.due(now, interval)).flatten() {
            self.cc_a.mark_sent(v, Some(now));
            MidiMessage::ControlChange {
                channel,
                control: c.cc_a.control,
                value: v as u8,
            }
        } else {
            let v = motion.then(|| self.cc_b.due(now, interval)).flatten()?;
            self.cc_b.mark_sent(v, Some(now));
            MidiMessage::ControlChange {
                channel,
                control: c.cc_b.control,
                value: v as u8,
            }
        };
        self.stats.control_sent = self.stats.control_sent.wrapping_add(1);
        Some(msg)
    }
}
