// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Nymble (https://github.com/nymble)

//! Wire-level constants from the Trill datasheet (Rev C, v1.3, section 7)
//! and timing values observed in Bela's reference host libraries.

/// Offset of the command / acknowledgement region (bytes 0..=2, R/W).
pub const OFFSET_COMMAND: u8 = 0;
/// Offset of the status byte (R/O, firmware ≥ 3).
pub const OFFSET_STATUS: u8 = 3;
/// Offset of the payload region (bytes 4..=63, R/O).
pub const OFFSET_DATA: u8 = 4;

/// Mode command, 1 argument.
pub const CMD_MODE: u8 = 1;
/// ScanSettings command, 2 arguments (speed, bits).
pub const CMD_SCAN_SETTINGS: u8 = 2;
/// Prescaler command, 1 argument.
pub const CMD_PRESCALER: u8 = 3;
/// NoiseThreshold command, 1 argument.
pub const CMD_NOISE_THRESHOLD: u8 = 4;
/// Idac command, 1 argument.
pub const CMD_IDAC: u8 = 5;
/// UpdateBaseline command, no argument.
pub const CMD_BASELINE_UPDATE: u8 = 6;
/// MinimumSize command, 2 arguments (big-endian u16).
pub const CMD_MINIMUM_SIZE: u8 = 7;
/// Reset command, no argument (firmware ≥ 3).
pub const CMD_RESET: u8 = 12;
/// Identify command, response `[ACK, type, firmware]`.
pub const CMD_IDENTIFY: u8 = 255;

/// Acknowledgement marker written to offset 0 when a command is processed.
pub const ACK_BYTE: u8 = 0xFE;
/// Location/size value marking an inactive touch slot.
pub const NO_TOUCH: u16 = 0xFFFF;

/// Minimum ScanSettings resolution.
pub const MIN_BITS: u8 = 9;
/// Maximum ScanSettings resolution.
pub const MAX_BITS: u8 = 16;
/// Maximum Prescaler index.
pub const MAX_PRESCALER: u8 = 8;

/// Wait after Identify before the first read (Trill-Arduino uses 25 ms).
pub const IDENTIFY_DELAY_MS: u32 = 25;
/// Fixed delay after a command on firmware < 3 (Trill-Arduino: 15 ms).
pub const LEGACY_COMMAND_DELAY_MS: u32 = 15;
/// First acknowledgement poll interval (Trill-Linux: 1 ms, doubling).
pub const ACK_POLL_START_MS: u32 = 1;
/// Upper bound for one poll interval.
pub const ACK_POLL_MAX_STEP_MS: u32 = 64;
/// Total acknowledgement polling budget (Trill-Linux: 200 ms).
pub const ACK_TIMEOUT_MS: u32 = 200;
/// Wait after Reset before talking to the sensor (Trill-Linux: 500 ms).
pub const RESET_DELAY_MS: u32 = 500;
/// Wait after changing the read offset (Trill-Linux: 1 ms).
pub const OFFSET_SETTLE_US: u32 = 1000;
