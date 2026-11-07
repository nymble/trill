// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Nymble (https://github.com/nymble)

//! Motion-to-music engine, `no_std`, no heap, fixed-size state.
//!
//! Two clocks, kept separate on purpose:
//!
//! * **Control rate** (IMU ODR, 104–833 Hz; 416 Hz default): [`motion`]
//!   turns accelerometer/gyro samples into orientation, rotation energy and
//!   tap events; [`mapping`] turns those (plus optional Trill touch) into
//!   [`mapping::SynthParams`].
//! * **Audio rate** (16, 32 or 48 kHz): [`synth::Synth`] renders fixed-size
//!   blocks. New parameters are latched only at block boundaries and then
//!   smoothed per sample, so control jitter never produces clicks and the
//!   render cost per block is bounded and data-independent.
//!
//! [`mailbox::ControlMailbox`] is the hand-off between the two (latest value
//! wins for continuous controls, events are accumulated, never lost), and
//! [`stream`] defines the framed PCM format used for the USB test stream.

#![cfg_attr(not(test), no_std)]
#![forbid(unsafe_code)]
#![warn(missing_docs)]

pub mod mailbox;
pub mod mapping;
pub mod motion;
pub mod stream;
pub mod synth;

/// Audio sample rates supported by the engine.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SampleRate {
    /// 16 kHz (matches the nRF52840 PDM microphone rate).
    Hz16000,
    /// 32 kHz (default for the firmware).
    Hz32000,
    /// 48 kHz.
    Hz48000,
}

impl SampleRate {
    /// Rate in Hz.
    pub const fn hz(self) -> u32 {
        match self {
            SampleRate::Hz16000 => 16_000,
            SampleRate::Hz32000 => 32_000,
            SampleRate::Hz48000 => 48_000,
        }
    }
}
