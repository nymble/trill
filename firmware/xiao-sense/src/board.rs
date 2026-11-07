// SPDX-License-Identifier: GPL-3.0-only
//! XIAO nRF52840 Sense board constants (Seeed schematic v1.1 Sense, Seeed
//! Arduino variant, Zephyr `xiao_ble_nrf52840_sense.dts`). Pins themselves
//! are taken by name in `main.rs`; this file documents and centralises rates.
//!
//! | Function | nRF pin | Notes |
//! |---|---|---|
//! | IMU SDA / SCL (internal) | P0.07 / P0.27 | 10 k pull-ups to IMU supply |
//! | IMU power | P1.08 | push-pull, high drive '1' (S0H1) |
//! | IMU INT1 | P0.11 | data-ready, active high |
//! | Trill SDA / SCL (D4 / D5) | P0.04 / P0.05 | external 4.7 k pull-ups to 3V3 |
//! | Mic PDM CLK / DATA / power | P1.00 / P0.16 / P1.10 | not used yet |
//! | LED red / green / blue | P0.26 / P0.30 / P0.06 | active low |

/// Audio sample rate for the synth (Hz). 16 000, 32 000 or 48 000.
pub const SAMPLE_RATE: u32 = 32_000;
/// Samples per audio block. 64 @ 32 kHz = 2 ms.
pub const BLOCK: usize = 64;
/// PCM blocks buffered towards USB (8 × 2 ms = 16 ms).
pub const PCM_QUEUE: usize = 8;
/// Trill poll period (ms).
pub const TRILL_POLL_MS: u64 = 5;
/// Per-transaction I²C timeout (ms): bounded even if a bus hangs.
pub const I2C_TIMEOUT_MS: u64 = 5;
/// Consecutive IMU read errors before the IMU is power-cycled.
pub const IMU_MAX_CONSECUTIVE_ERRORS: u32 = 5;
/// Max wait for IMU data-ready before polling anyway (ms).
pub const IMU_DRDY_TIMEOUT_MS: u64 = 20;
