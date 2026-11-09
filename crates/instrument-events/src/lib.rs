// SPDX-License-Identifier: GPL-3.0-only
//! Sensor-to-musical-event engine for the Trill instrument.
//!
//! * [`midi`]: MIDI 1.0 channel-voice messages, their wire bytes and the
//!   USB-MIDI 1.0 32-bit event packet (cable number + Code Index Number).
//! * [`engine`]: a deterministic, transport-independent state machine that
//!   takes timestamped touch and motion samples and produces MIDI messages
//!   with note on/off priority, coalesced and rate-limited continuous
//!   controllers, stuck-note protection and a defined panic sequence.
//!
//! Scope of this version: **one active voice on one MIDI channel** (plus an
//! optional percussion note on a second channel). The engine is fed the first
//! (strongest-ordered) Trill touch only; other simultaneous touches are
//! ignored. MPE and multi-touch are a later milestone.
//!
//! Touch "size" is the Trill capacitive contact-area value: it is a proxy that
//! grows with finger contact area and proximity, **not** a calibrated force or
//! pressure measurement. It is sent as MIDI channel pressure because that is
//! the closest standard message, not because it measures force.
#![no_std]
#![forbid(unsafe_code)]
#![warn(missing_docs)]

pub mod engine;
pub mod midi;

pub use engine::{
    classify_strike, Axis, CcMap, CcSource, Config, Engine, Mode, MotionSample, PitchMode, Scale,
    Stats, StrikeDirection, TouchSample,
};
pub use midi::MidiMessage;
