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
//! | LED red / green / blue | P0.26 / P0.30 / P0.06 | common-anode RGB to 3V3, active low; R7 2.2 k / R4 10 k / R3 2.2 k |
//! | Charge LED (red, CHG0) | — | driven by the BQ25101 ~CHG output (net also on P0.17); not firmware-controlled |

/// Audio sample rate for the synth (Hz). 16 000, 32 000 or 48 000.
#[cfg(feature = "pcm-synth")]
pub const SAMPLE_RATE: u32 = 32_000;
/// Samples per audio block. 64 @ 32 kHz = 2 ms.
#[cfg(feature = "pcm-synth")]
pub const BLOCK: usize = 64;
/// PCM blocks buffered towards USB (8 × 2 ms = 16 ms).
#[cfg(feature = "pcm-synth")]
pub const PCM_QUEUE: usize = 8;
/// Trill poll period (ms). Must exceed read time + scan time so each poll
/// normally sees a new frame: at 100 kHz the 21-byte status+centroid read
/// takes ~2.3 ms, and a 30-channel Flex scan at ultra-fast/10 bit takes
/// ~30 x 78 us = 2.3 ms (Bela scan-time table; firmware >= 3 starts a scan
/// after each I2C transaction). Repeated frames are detected by frame ID.
pub const TRILL_POLL_MS: u64 = 5;
/// Trill scan resolution (bits). 12 bits (Trill-Linux default) scans in
/// ~6.2 ms on Flex, longer than the poll period; 10 bits trades resolution
/// for a ~2.3 ms scan. Sensitivity at 10 bits is not yet tuned on hardware.
pub const TRILL_SCAN_BITS: u8 = 10;
/// Flex touch size giving ~1.0 at 12 bits (Trill-Linux rescale factor);
/// raw size scales by 2^(bits-12), so the firmware divides by
/// `TRILL_SIZE_FULL_12BIT >> (12 - bits)`.
pub const TRILL_SIZE_FULL_12BIT: u32 = 1200;
/// Trill failures in a row before the sensor is declared lost.
pub const TRILL_MAX_CONSECUTIVE_ERRORS: u32 = 4;
/// MIDI writer housekeeping period (ms): engine timeouts and coalesced
/// controller flushes happen at least this often while connected.
pub const MIDI_TICK_MS: u64 = 2;
/// A MIDI IN-endpoint write still pending after this long counts as a host
/// stall (the write keeps waiting; it is never abandoned mid-packet).
pub const MIDI_STALL_MS: u64 = 100;
/// Per-transaction I²C timeout (ms): bounded even if a bus hangs.
pub const I2C_TIMEOUT_MS: u64 = 5;
/// Consecutive IMU read errors before the IMU is power-cycled.
pub const IMU_MAX_CONSECUTIVE_ERRORS: u32 = 5;
/// Max wait for IMU data-ready before polling anyway (ms).
pub const IMU_DRDY_TIMEOUT_MS: u64 = 20;
/// LED task tick (ms): status re-evaluated and pins updated (only on change)
/// at most this often.
pub const LED_TICK_MS: u64 = 20;
