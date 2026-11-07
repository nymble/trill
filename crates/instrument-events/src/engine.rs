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
        self
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
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct MotionSample {
    /// Gyro bias calibration complete; motion controls are gated on this.
    pub calibrated: bool,
    /// Smoothed rotation rate magnitude, deg/s.
    pub rotation_dps: f32,
    /// Tilt pitch, degrees (positive = forward).
    pub pitch_deg: f32,
    /// Tap detected in this frame: strength in g above the detector threshold.
    pub tap: Option<f32>,
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
                if (now.wrapping_sub(t) as i32) < interval as i32 {
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
    bend: Slot,
    timbre: Slot,
    tilt: Slot,
    voice: Option<Voice>,
    armed: bool,
    last_touch: Option<u32>,
    pressure_smooth: f32,
    last_motion: Option<u32>,
    motion_ok: bool,
    calibrated_since: Option<u32>,
    percussion_off_at: Option<(u8, u8, u32)>,
    stats: Stats,
}

/// Wrapping "a is earlier than b".
fn before(a: u32, b: u32) -> bool {
    (b.wrapping_sub(a) as i32) > 0
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
            bend: Slot::new(4.0, BEND_MAX),
            timbre: Slot::new(0.75, 127),
            tilt: Slot::new(0.75, 127),
            voice: None,
            armed: false,
            last_touch: None,
            pressure_smooth: 0.0,
            last_motion: None,
            motion_ok: false,
            calibrated_since: None,
            percussion_off_at: None,
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
        let old = self.cfg;
        if self.connected
            && (old.channel != cfg.channel
                || old.pitch_mode != cfg.pitch_mode
                || old.bend_range_semitones != cfg.bend_range_semitones)
        {
            self.cfg = cfg;
            self.channel_reset(cfg.channel, true);
        } else {
            self.cfg = cfg;
        }
        if old.percussion_enabled && !cfg.percussion_enabled {
            self.percussion_release();
        }
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
        self.armed = false;
        for s in [
            &mut self.pressure,
            &mut self.bend,
            &mut self.timbre,
            &mut self.tilt,
        ] {
            s.reset(None);
        }
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
        self.armed = false;
        self.channel_reset(self.cfg.channel, true);
        if self.cfg.percussion_channel != self.cfg.channel {
            self.channel_reset(self.cfg.percussion_channel, false);
        }
        self.pressure.reset(Some(0));
        self.bend.reset(Some(BEND_CENTER));
        self.timbre.reset(None);
        self.tilt.reset(None);
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
            if before(t, p) {
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
            Scale::Pentatonic => {
                const DEG: [f32; 5] = [0.0, 2.0, 4.0, 7.0, 9.0];
                let oct = ((s / 12.0) as i32) as f32 * 12.0;
                let mut best = 0.0f32;
                let mut best_d = f32::MAX;
                for o in [oct - 12.0, oct, oct + 12.0] {
                    for d in DEG {
                        let n = o + d;
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

    /// Feed one fresh touch frame (`None` = no touch).
    pub fn touch(&mut self, t: u32, sample: Option<TouchSample>) {
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
        let bend_mode = self.cfg.pitch_mode == PitchMode::Bend;
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
        self.pressure.set(self.pressure_smooth, &mut self.stats);
    }

    fn update_voice(&mut self, v: Voice, dt: u32, location: f32, size: f32) {
        let s = self.position(location);
        match self.cfg.pitch_mode {
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
        self.pressure.set(self.pressure_smooth, &mut self.stats);
    }

    /// Release the touch voice. `rearm`: a normal lift (the next touch may
    /// play); otherwise the caller decides.
    fn release_voice(&mut self, rearm: bool) {
        if let Some(v) = self.voice.take() {
            self.push_note_off(self.cfg.channel, v.note);
            self.pressure.force(0.0);
        }
        if rearm {
            self.armed = true;
        }
    }

    /// The touch sensor stopped answering: release and disarm.
    pub fn touch_lost(&mut self, _now: u32) {
        self.stats.touch_lost = self.stats.touch_lost.wrapping_add(1);
        self.release_voice(false);
        self.armed = false;
    }

    /// Feed one processed IMU frame.
    pub fn motion(&mut self, t: u32, m: MotionSample) {
        if !m.rotation_dps.is_finite()
            || !m.pitch_deg.is_finite()
            || m.tap.is_some_and(|g| !g.is_finite())
        {
            self.stats.invalid_inputs = self.stats.invalid_inputs.wrapping_add(1);
            return;
        }
        if !Self::accept_time(&mut self.last_motion, t, &mut self.stats) {
            return;
        }
        self.motion_ok = true;
        if !m.calibrated {
            self.calibrated_since = None;
            return;
        }
        let since = *self.calibrated_since.get_or_insert(t);
        if !self.connected {
            return;
        }
        let c = self.cfg;
        if c.motion_enabled {
            let r = unit(m.rotation_dps.abs() / c.rotation_full_dps) * 127.0;
            self.timbre.set(r, &mut self.stats);
            let p = unit(m.pitch_deg / c.tilt_full_deg) * 127.0;
            self.tilt.set(p, &mut self.stats);
        }
        if let Some(g) = m.tap {
            let armed = !before(t, since.wrapping_add(c.percussion_arm_us));
            if c.percussion_enabled && armed && g > 0.0 {
                self.percussion_hit(t, g);
            }
        }
    }

    fn percussion_hit(&mut self, t: u32, g: f32) {
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
            note: c.percussion_note,
            velocity,
        });
        self.note_high_water();
        self.stats.note_on = self.stats.note_on.wrapping_add(1);
        self.stats.taps = self.stats.taps.wrapping_add(1);
        self.percussion_off_at = Some((
            c.percussion_channel,
            c.percussion_note,
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
        self.percussion_release();
        if self.connected {
            for s in [&mut self.timbre, &mut self.tilt] {
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
        let motion = c.motion_enabled || self.timbre.force || self.tilt.force;
        let msg = if let Some(v) = self.pressure.due(now, interval) {
            self.pressure.mark_sent(v, Some(now));
            MidiMessage::ChannelPressure {
                channel,
                value: v as u8,
            }
        } else if let Some(v) = (c.pitch_mode == PitchMode::Bend)
            .then(|| self.bend.due(now, interval))
            .flatten()
        {
            self.bend.mark_sent(v, Some(now));
            MidiMessage::PitchBend { channel, value: v }
        } else if let Some(v) = motion.then(|| self.timbre.due(now, interval)).flatten() {
            self.timbre.mark_sent(v, Some(now));
            MidiMessage::ControlChange {
                channel,
                control: cc::BRIGHTNESS,
                value: v as u8,
            }
        } else {
            let v = motion.then(|| self.tilt.due(now, interval)).flatten()?;
            self.tilt.mark_sent(v, Some(now));
            MidiMessage::ControlChange {
                channel,
                control: cc::MODULATION,
                value: v as u8,
            }
        };
        self.stats.control_sent = self.stats.control_sent.wrapping_add(1);
        Some(msg)
    }
}
