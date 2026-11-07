// SPDX-License-Identifier: GPL-3.0-only
//! Gesture → synthesis parameter mapping (control rate).
//!
//! Default instrument: tilt forward/back (pitch) selects a note on a
//! pentatonic scale over two octaves, roll opens the filter, rotation speed
//! sets the sustained level ("bowing"), taps pluck. A Trill touch, when
//! present, overrides the note with its location (continuous glide) and its
//! size adds brightness.

use crate::motion::MotionFrame;
use libm::{exp2f, floorf, roundf};

/// Parameters consumed by [`crate::synth::Synth`].
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SynthParams {
    /// Oscillator frequency (Hz).
    pub freq_hz: f32,
    /// Low-pass cutoff (Hz).
    pub cutoff_hz: f32,
    /// Filter resonance 0…1.
    pub resonance: f32,
    /// Sustained level 0…1.
    pub level: f32,
    /// Pluck/trigger velocity 0…1, if an event fired.
    pub trigger: Option<f32>,
}

impl Default for SynthParams {
    fn default() -> Self {
        Self {
            freq_hz: 220.0,
            cutoff_hz: 1200.0,
            resonance: 0.2,
            level: 0.0,
            trigger: None,
        }
    }
}

/// Optional Trill input (from `trill-driver` touches, normalised 0…1).
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct TouchInput {
    /// First touch location 0…1, `None` when not touched.
    pub location: Option<f32>,
    /// First touch size 0…1.
    pub size: f32,
}

/// Mapping tunables.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct MappingConfig {
    /// MIDI note at the bottom of the range.
    pub base_note: f32,
    /// Range in semitones.
    pub range_semitones: f32,
    /// Quantise tilt to the scale.
    pub quantise: bool,
    /// Pitch angle (deg) mapped to the top/bottom of the range (±).
    pub pitch_span_deg: f32,
    /// Rotation speed (dps) giving full level.
    pub full_level_dps: f32,
    /// Cutoff range (Hz).
    pub cutoff_min_hz: f32,
    /// See `cutoff_min_hz`.
    pub cutoff_max_hz: f32,
    /// Tap strength (g above threshold) giving full velocity.
    pub full_tap_g: f32,
}

impl Default for MappingConfig {
    fn default() -> Self {
        Self {
            base_note: 45.0, // A2, 110 Hz
            range_semitones: 24.0,
            quantise: true,
            pitch_span_deg: 60.0,
            full_level_dps: 360.0,
            cutoff_min_hz: 200.0,
            cutoff_max_hz: 6000.0,
            full_tap_g: 2.0,
        }
    }
}

const PENTATONIC: [f32; 5] = [0.0, 2.0, 4.0, 7.0, 9.0];

/// MIDI note number to Hz (A4 = 440 Hz).
pub fn note_hz(note: f32) -> f32 {
    440.0 * exp2f((note - 69.0) / 12.0)
}

/// Snap a semitone offset to the major pentatonic scale.
pub fn quantise_pentatonic(semis: f32) -> f32 {
    let octave = floorf(semis / 12.0);
    let within = semis - octave * 12.0;
    let mut best = PENTATONIC[0];
    let mut best_d = f32::MAX;
    for &s in PENTATONIC.iter().chain(core::iter::once(&12.0)) {
        let d = (within - s).abs();
        if d < best_d {
            best_d = d;
            best = s;
        }
    }
    octave * 12.0 + best
}

/// Map one motion frame (+ optional touch) to synth parameters.
pub fn map(cfg: &MappingConfig, m: &MotionFrame, touch: &TouchInput) -> SynthParams {
    let unit = |x: f32| x.clamp(0.0, 1.0);
    let semis = match touch.location {
        Some(loc) => unit(loc) * cfg.range_semitones,
        None => {
            let s = unit(0.5 + m.pitch_deg / (2.0 * cfg.pitch_span_deg)) * cfg.range_semitones;
            if cfg.quantise {
                quantise_pentatonic(roundf(s * 2.0) / 2.0)
            } else {
                s
            }
        }
    };
    let roll = unit((m.roll_deg.abs()) / 90.0);
    let bright = unit(roll + 0.5 * unit(touch.size));
    let cutoff = cfg.cutoff_min_hz * libm::powf(cfg.cutoff_max_hz / cfg.cutoff_min_hz, bright);
    SynthParams {
        freq_hz: note_hz(cfg.base_note + semis),
        cutoff_hz: cutoff,
        resonance: 0.15 + 0.25 * unit(m.rotation_dps / cfg.full_level_dps),
        level: unit(m.rotation_dps / cfg.full_level_dps),
        trigger: m.tap.map(|g| unit(0.3 + g / cfg.full_tap_g)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn note_table() {
        assert!((note_hz(69.0) - 440.0).abs() < 1e-3);
        assert!((note_hz(45.0) - 110.0).abs() < 1e-3);
    }

    #[test]
    fn pentatonic_snap() {
        assert_eq!(quantise_pentatonic(0.4), 0.0);
        assert_eq!(quantise_pentatonic(5.4), 4.0);
        assert_eq!(quantise_pentatonic(5.6), 7.0);
        assert_eq!(quantise_pentatonic(11.0), 12.0);
        assert_eq!(quantise_pentatonic(13.9), 14.0);
    }

    #[test]
    fn tilt_spans_range_and_clamps() {
        let c = MappingConfig::default();
        let t = TouchInput::default();
        let lo = map(
            &c,
            &MotionFrame {
                pitch_deg: -90.0,
                ..Default::default()
            },
            &t,
        );
        let hi = map(
            &c,
            &MotionFrame {
                pitch_deg: 90.0,
                ..Default::default()
            },
            &t,
        );
        assert!((lo.freq_hz - 110.0).abs() < 0.01);
        assert!((hi.freq_hz - 440.0).abs() < 0.01);
    }

    #[test]
    fn touch_overrides_tilt_and_tap_maps_velocity() {
        let c = MappingConfig::default();
        let t = TouchInput {
            location: Some(0.5),
            size: 0.0,
        };
        let m = MotionFrame {
            pitch_deg: -90.0,
            tap: Some(0.7),
            ..Default::default()
        };
        let p = map(&c, &m, &t);
        assert!((p.freq_hz - 220.0).abs() < 0.01);
        assert!((p.trigger.unwrap() - 0.65).abs() < 1e-6);
        assert!(p.cutoff_hz >= c.cutoff_min_hz && p.cutoff_hz <= c.cutoff_max_hz);
    }
}
