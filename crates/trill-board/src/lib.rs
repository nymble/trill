// SPDX-License-Identifier: GPL-3.0-only
//! Board support logic that does not touch hardware, so it is unit tested
//! on the host: battery measurement maths and presence heuristic
//! ([`battery`]), and the Bluetooth settings record stored in flash
//! ([`settings`]). See docs/battery.md and docs/ble-midi.md.
#![no_std]
#![forbid(unsafe_code)]
#![warn(missing_docs)]

pub mod battery;
pub mod settings;
