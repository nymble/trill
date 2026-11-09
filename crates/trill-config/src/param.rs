// SPDX-License-Identifier: GPL-3.0-only
//! Configurable parameters. Values are unsigned 14-bit on the wire
//! (`value_hi << 7 | value_lo`); every parameter has an inclusive range and
//! values outside it are rejected, never clamped.
//!
//! Parameters are grouped in pages so a `CONFIG` reply fits one 64-byte
//! message (at most [`PAGE_MAX`] parameters each). Page 0 (IDs 1..=13) is
//! exactly the firmware 0.3 parameter set; page 1 (IDs 14..=30) was added in
//! firmware 0.4 and is only present when `HELLO_REPLY` advertises
//! `CAP_CONFIG_PAGES`; page 2 (IDs 31..=37, directional strikes) was added in
//! firmware 0.5 and is only present with `CAP_STRIKES`.

use instrument_events::{Axis, CcSource, Config, Mode, PitchMode, Scale, StrikeDirection};

/// One configurable engine parameter.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum Param {
    /// Touch voice MIDI channel, 0-based (0 = channel 1).
    Channel = 1,
    /// Note at the left end of the strip.
    BaseNote = 2,
    /// Semitones across the strip (integer).
    RangeSemitones = 3,
    /// 0 = chromatic, 1 = pentatonic.
    Scale = 4,
    /// 0 = continuous pitch bend, 1 = stepped notes.
    PitchMode = 5,
    /// Pitch-bend range in semitones (sent as RPN 0).
    BendRange = 6,
    /// Velocity at the onset threshold.
    VelocityMin = 7,
    /// Motion controllers (CC74 rotation, CC1 tilt) on/off.
    MotionEnabled = 8,
    /// Rotation rate (deg/s) giving CC74 = 127.
    RotationFullDps = 9,
    /// Forward tilt (deg) giving CC1 = 127.
    TiltFullDeg = 10,
    /// Tap percussion on/off.
    PercussionEnabled = 11,
    /// Percussion channel, 0-based (9 = GM drums).
    PercussionChannel = 12,
    /// Percussion note number.
    PercussionNote = 13,
    /// Sensor mode: 0 = touch strip (default), 1 = tilt notes, 2 = theremin.
    Mode = 14,
    /// Controller A source (0 off, 1 rotation, 2 pitch forward, 3 pitch back,
    /// 4 roll right, 5 roll left, 6 pitch centred, 7 roll centred).
    CcASource = 15,
    /// Controller A CC number.
    CcANumber = 16,
    /// Controller B source (as `CcASource`).
    CcBSource = 17,
    /// Controller B CC number.
    CcBNumber = 18,
    /// Controller deadzone, percent of full scale.
    CcDeadzone = 19,
    /// Controller smoothing time constant, ms (0 = off).
    CcSmoothingMs = 20,
    /// Tilt modes: roll (deg) from centre to each end of the note range.
    TiltSpanDeg = 21,
    /// Tilt modes: forward pitch (deg) that opens the note gate.
    GateDeg = 22,
    /// Stepped-note hysteresis, percent of one step.
    StepHysteresis = 23,
    /// Tilt modes: CC number mirroring note pressure (0 = off).
    ExpressionCc = 24,
    /// Tap threshold in centi-g above baseline (lower = more sensitive).
    TapThresholdCg = 25,
    /// Minimum time between taps, ms.
    TapCooldownMs = 26,
    /// Flick gestures: 0 = off, 1 = X, 2 = Y, 3 = Z sensor axis.
    GestureAxis = 27,
    /// Flick threshold, deg/s.
    GestureThresholdDps = 28,
    /// Minimum time between flicks, ms.
    GestureCooldownMs = 29,
    /// Flick note: negative = base, positive = base+1, zig-zag = base+2.
    GestureBaseNote = 30,
    /// Directional strikes: 0 = off (every tap plays `PercussionNote`),
    /// 2 = down/up, 4 = + left/right, 6 = + forward/back. 1, 3 and 5 are
    /// out of range.
    StrikeDirections = 31,
    /// Note for a strike moving down.
    StrikeNoteDown = 32,
    /// Note for a strike moving up.
    StrikeNoteUp = 33,
    /// Note for a strike moving left.
    StrikeNoteLeft = 34,
    /// Note for a strike moving right.
    StrikeNoteRight = 35,
    /// Note for a strike moving forward.
    StrikeNoteForward = 36,
    /// Note for a strike moving back.
    StrikeNoteBack = 37,
}

/// Most parameters in one page (a `CONFIG` reply is 7 + 3 + 3·n + 1 bytes).
pub const PAGE_MAX: usize = 17;
/// Number of pages.
pub const PAGES: u8 = 3;

/// A value outside the parameter's range.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct OutOfRange;

impl Param {
    /// Every parameter, in ID order.
    pub const ALL: [Param; 37] = [
        Param::Channel,
        Param::BaseNote,
        Param::RangeSemitones,
        Param::Scale,
        Param::PitchMode,
        Param::BendRange,
        Param::VelocityMin,
        Param::MotionEnabled,
        Param::RotationFullDps,
        Param::TiltFullDeg,
        Param::PercussionEnabled,
        Param::PercussionChannel,
        Param::PercussionNote,
        Param::Mode,
        Param::CcASource,
        Param::CcANumber,
        Param::CcBSource,
        Param::CcBNumber,
        Param::CcDeadzone,
        Param::CcSmoothingMs,
        Param::TiltSpanDeg,
        Param::GateDeg,
        Param::StepHysteresis,
        Param::ExpressionCc,
        Param::TapThresholdCg,
        Param::TapCooldownMs,
        Param::GestureAxis,
        Param::GestureThresholdDps,
        Param::GestureCooldownMs,
        Param::GestureBaseNote,
        Param::StrikeDirections,
        Param::StrikeNoteDown,
        Param::StrikeNoteUp,
        Param::StrikeNoteLeft,
        Param::StrikeNoteRight,
        Param::StrikeNoteForward,
        Param::StrikeNoteBack,
    ];

    /// Page 0: the firmware 0.3 parameters, in ID order.
    pub const PAGE0: &'static [Param] = Self::ALL.split_at(13).0;
    /// Page 1: added in firmware 0.4.
    pub const PAGE1: &'static [Param] = Self::ALL.split_at(30).0.split_at(13).1;
    /// Page 2: added in firmware 0.5 (directional strikes).
    pub const PAGE2: &'static [Param] = Self::ALL.split_at(30).1;

    /// Parameters of page `p`, if it exists.
    pub fn page_params(p: u8) -> Option<&'static [Param]> {
        match p {
            0 => Some(Self::PAGE0),
            1 => Some(Self::PAGE1),
            2 => Some(Self::PAGE2),
            _ => None,
        }
    }

    /// Page holding this parameter.
    pub fn page(self) -> u8 {
        match self.id() {
            0..=13 => 0,
            14..=30 => 1,
            _ => 2,
        }
    }

    /// Wire ID.
    pub fn id(self) -> u8 {
        self as u8
    }

    /// From a wire ID.
    pub fn from_id(id: u8) -> Option<Self> {
        Self::ALL.iter().copied().find(|p| p.id() == id)
    }

    /// Inclusive value range.
    pub fn range(self) -> (u16, u16) {
        match self {
            Param::Channel | Param::PercussionChannel => (0, 15),
            Param::BaseNote | Param::PercussionNote => (0, 127),
            Param::RangeSemitones => (1, 96),
            Param::Scale | Param::PitchMode => (0, 1),
            Param::BendRange => (1, 24),
            Param::VelocityMin => (1, 127),
            Param::MotionEnabled | Param::PercussionEnabled => (0, 1),
            Param::RotationFullDps => (30, 2000),
            Param::TiltFullDeg => (5, 90),
            Param::Mode => (0, 2),
            Param::CcASource | Param::CcBSource => (0, 7),
            Param::CcANumber | Param::CcBNumber => (1, 119),
            Param::CcDeadzone => (0, 50),
            Param::CcSmoothingMs => (0, 500),
            Param::TiltSpanDeg => (10, 90),
            Param::GateDeg => (5, 60),
            Param::StepHysteresis => (0, 49),
            Param::ExpressionCc => (0, 119),
            Param::TapThresholdCg => (30, 400),
            Param::TapCooldownMs => (50, 1000),
            Param::GestureAxis => (0, 3),
            Param::GestureThresholdDps => (100, 2000),
            Param::GestureCooldownMs => (100, 2000),
            Param::GestureBaseNote => (0, 125),
            Param::StrikeDirections => (0, 6),
            Param::StrikeNoteDown
            | Param::StrikeNoteUp
            | Param::StrikeNoteLeft
            | Param::StrikeNoteRight
            | Param::StrikeNoteForward
            | Param::StrikeNoteBack => (0, 127),
        }
    }

    /// Current value in `cfg` (floats rounded to the nearest integer and
    /// clamped into range, so a reply always holds a valid value).
    pub fn get(self, cfg: &Config) -> u16 {
        let f = |x: f32| {
            let (lo, hi) = self.range();
            if !x.is_finite() {
                return lo;
            }
            let r = (x + 0.5) as i32; // values are positive here
            r.clamp(i32::from(lo), i32::from(hi)) as u16
        };
        match self {
            Param::Channel => u16::from(cfg.channel),
            Param::BaseNote => u16::from(cfg.base_note),
            Param::RangeSemitones => f(cfg.range_semitones),
            Param::Scale => match cfg.scale {
                Scale::Chromatic => 0,
                Scale::Pentatonic => 1,
            },
            Param::PitchMode => match cfg.pitch_mode {
                PitchMode::Bend => 0,
                PitchMode::Steps => 1,
            },
            Param::BendRange => u16::from(cfg.bend_range_semitones),
            Param::VelocityMin => u16::from(cfg.velocity_min),
            Param::MotionEnabled => u16::from(cfg.motion_enabled),
            Param::RotationFullDps => f(cfg.rotation_full_dps),
            Param::TiltFullDeg => f(cfg.tilt_full_deg),
            Param::PercussionEnabled => u16::from(cfg.percussion_enabled),
            Param::PercussionChannel => u16::from(cfg.percussion_channel),
            Param::PercussionNote => u16::from(cfg.percussion_note),
            Param::Mode => match cfg.mode {
                Mode::Touch => 0,
                Mode::TiltNotes => 1,
                Mode::Theremin => 2,
            },
            Param::CcASource => source_code(cfg.cc_a.source),
            Param::CcANumber => u16::from(cfg.cc_a.control).max(1),
            Param::CcBSource => source_code(cfg.cc_b.source),
            Param::CcBNumber => u16::from(cfg.cc_b.control).max(1),
            Param::CcDeadzone => f(cfg.cc_deadzone * 100.0),
            Param::CcSmoothingMs => f(cfg.cc_smoothing_us as f32 / 1000.0),
            Param::TiltSpanDeg => f(cfg.tilt_span_deg),
            Param::GateDeg => f(cfg.gate_deg),
            Param::StepHysteresis => f(cfg.step_hysteresis * 100.0),
            Param::ExpressionCc => u16::from(cfg.expression_cc).min(119),
            Param::TapThresholdCg => f(cfg.tap_threshold_g * 100.0),
            Param::TapCooldownMs => f(cfg.tap_cooldown_us as f32 / 1000.0),
            Param::GestureAxis => match cfg.gesture_axis {
                None => 0,
                Some(Axis::X) => 1,
                Some(Axis::Y) => 2,
                Some(Axis::Z) => 3,
            },
            Param::GestureThresholdDps => f(cfg.gesture_threshold_dps),
            Param::GestureCooldownMs => f(cfg.gesture_cooldown_us as f32 / 1000.0),
            Param::GestureBaseNote => u16::from(cfg.gesture_base_note).min(125),
            Param::StrikeDirections => u16::from(cfg.strike_directions).min(6),
            _ => match self.strike_index() {
                Some(i) => u16::from(cfg.strike_notes[i]).min(127),
                None => 0,
            },
        }
    }

    /// Store `v` into `cfg` after a range check.
    pub fn set(self, cfg: &mut Config, v: u16) -> Result<(), OutOfRange> {
        let (lo, hi) = self.range();
        if v < lo || v > hi {
            return Err(OutOfRange);
        }
        if self == Param::StrikeDirections && v % 2 == 1 {
            return Err(OutOfRange);
        }
        let b = v as u8; // every u8 field has hi <= 127
        match self {
            Param::Channel => cfg.channel = b,
            Param::BaseNote => cfg.base_note = b,
            Param::RangeSemitones => cfg.range_semitones = f32::from(v),
            Param::Scale => {
                cfg.scale = if v == 0 {
                    Scale::Chromatic
                } else {
                    Scale::Pentatonic
                }
            }
            Param::PitchMode => {
                cfg.pitch_mode = if v == 0 {
                    PitchMode::Bend
                } else {
                    PitchMode::Steps
                }
            }
            Param::BendRange => cfg.bend_range_semitones = b,
            Param::VelocityMin => cfg.velocity_min = b,
            Param::MotionEnabled => cfg.motion_enabled = v == 1,
            Param::RotationFullDps => cfg.rotation_full_dps = f32::from(v),
            Param::TiltFullDeg => cfg.tilt_full_deg = f32::from(v),
            Param::PercussionEnabled => cfg.percussion_enabled = v == 1,
            Param::PercussionChannel => cfg.percussion_channel = b,
            Param::PercussionNote => cfg.percussion_note = b,
            Param::Mode => {
                cfg.mode = match v {
                    0 => Mode::Touch,
                    1 => Mode::TiltNotes,
                    _ => Mode::Theremin,
                }
            }
            Param::CcASource => cfg.cc_a.source = CcSource::ALL[usize::from(v)],
            Param::CcANumber => cfg.cc_a.control = b,
            Param::CcBSource => cfg.cc_b.source = CcSource::ALL[usize::from(v)],
            Param::CcBNumber => cfg.cc_b.control = b,
            Param::CcDeadzone => cfg.cc_deadzone = f32::from(v) / 100.0,
            Param::CcSmoothingMs => cfg.cc_smoothing_us = u32::from(v) * 1000,
            Param::TiltSpanDeg => cfg.tilt_span_deg = f32::from(v),
            Param::GateDeg => cfg.gate_deg = f32::from(v),
            Param::StepHysteresis => cfg.step_hysteresis = f32::from(v) / 100.0,
            Param::ExpressionCc => cfg.expression_cc = b,
            Param::TapThresholdCg => cfg.tap_threshold_g = f32::from(v) / 100.0,
            Param::TapCooldownMs => cfg.tap_cooldown_us = u32::from(v) * 1000,
            Param::GestureAxis => {
                cfg.gesture_axis = match v {
                    0 => None,
                    1 => Some(Axis::X),
                    2 => Some(Axis::Y),
                    _ => Some(Axis::Z),
                }
            }
            Param::GestureThresholdDps => cfg.gesture_threshold_dps = f32::from(v),
            Param::GestureCooldownMs => cfg.gesture_cooldown_us = u32::from(v) * 1000,
            Param::GestureBaseNote => cfg.gesture_base_note = b,
            Param::StrikeDirections => cfg.strike_directions = b,
            _ => {
                if let Some(i) = self.strike_index() {
                    cfg.strike_notes[i] = b;
                }
            }
        }
        Ok(())
    }

    /// Index into `Config::strike_notes` for the strike note parameters.
    fn strike_index(self) -> Option<usize> {
        let d = match self {
            Param::StrikeNoteDown => StrikeDirection::Down,
            Param::StrikeNoteUp => StrikeDirection::Up,
            Param::StrikeNoteLeft => StrikeDirection::Left,
            Param::StrikeNoteRight => StrikeDirection::Right,
            Param::StrikeNoteForward => StrikeDirection::Forward,
            Param::StrikeNoteBack => StrikeDirection::Back,
            _ => return None,
        };
        Some(d as usize)
    }
}

fn source_code(s: CcSource) -> u16 {
    CcSource::ALL.iter().position(|&x| x == s).unwrap_or(0) as u16
}
