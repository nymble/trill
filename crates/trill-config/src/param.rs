// SPDX-License-Identifier: GPL-3.0-only
//! Configurable parameters. Values are unsigned 14-bit on the wire
//! (`value_hi << 7 | value_lo`); every parameter has an inclusive range and
//! values outside it are rejected, never clamped.

use instrument_events::{Config, PitchMode, Scale};

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
}

/// A value outside the parameter's range.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct OutOfRange;

impl Param {
    /// Every parameter, in ID order (the order of a `CONFIG` reply).
    pub const ALL: [Param; 13] = [
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
    ];

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
        }
    }

    /// Store `v` into `cfg` after a range check.
    pub fn set(self, cfg: &mut Config, v: u16) -> Result<(), OutOfRange> {
        let (lo, hi) = self.range();
        if v < lo || v > hi {
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
        }
        Ok(())
    }
}
