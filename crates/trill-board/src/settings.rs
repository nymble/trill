// SPDX-License-Identifier: GPL-3.0-only
//! The Bluetooth settings record (discoverable, Bluetooth MIDI) stored in
//! one 4 KiB flash page of the reserved storage area.
//!
//! The page is an append-only log of 8-byte records, so a change costs one
//! 8-byte write and the page is erased only once every 512 changes:
//!
//! ```text
//! word 0: MAGIC ("TBS" + format 1)
//! word 1: flags | !flags << 8 | 0x0000 << 16  (bits 16..31 written as 0)
//! ```
//!
//! Erased flash reads `0xFF`; the last valid record before the first erased
//! slot wins. A torn or foreign record fails the magic or the flag check
//! and is skipped, and an unusable page simply means defaults.

/// Flash page used for the record (start of the 32 KiB storage area
/// 0xEC000..0xF4000 in link/memory.x; the UF2 bootloader at 0xF4000 and
/// the SoftDevice below 0x27000 are never written).
pub const PAGE_ADDR: u32 = 0x000E_C000;
/// nRF52840 flash page size.
pub const PAGE_SIZE: u32 = 4_096;
/// First address that must never be written (UF2 bootloader).
pub const BOOTLOADER_ADDR: u32 = 0x000F_4000;
/// First address of the application/storage area (below is MBR and
/// SoftDevice).
pub const APP_ADDR: u32 = 0x0002_7000;
/// Record size in bytes.
pub const RECORD_LEN: usize = 8;
/// Records per page.
pub const SLOTS: usize = PAGE_SIZE as usize / RECORD_LEN;
/// Record magic: "TBS" + format 1.
pub const MAGIC: u32 = 0x5442_5301;

const _: () = assert!(PAGE_ADDR >= 0x000E_C000 && PAGE_ADDR + PAGE_SIZE <= BOOTLOADER_ADDR);
const _: () = assert!(PAGE_ADDR % PAGE_SIZE == 0);

const DISCOVERABLE: u8 = 0x01;
const BLE_MIDI: u8 = 0x02;

/// The stored Bluetooth settings.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct BleSettings {
    /// Advertise so hosts can find the board.
    pub discoverable: bool,
    /// BLE-MIDI service active.
    pub ble_midi: bool,
}

impl BleSettings {
    /// Defaults when nothing is stored: both on, so a battery board with
    /// the Bluetooth firmware shows up in Bluetooth MIDI panels at once.
    /// Bluetooth still only runs when a battery is detected.
    pub const DEFAULT: BleSettings = BleSettings {
        discoverable: true,
        ble_midi: true,
    };

    fn flags(self) -> u8 {
        (u8::from(self.discoverable) * DISCOVERABLE) | (u8::from(self.ble_midi) * BLE_MIDI)
    }

    /// The two record words.
    pub fn encode(self) -> [u32; 2] {
        let f = self.flags();
        [MAGIC, u32::from(f) | u32::from(!f) << 8]
    }

    /// The record as bytes (little endian, as written to flash).
    pub fn encode_bytes(self) -> [u8; RECORD_LEN] {
        let [a, b] = self.encode();
        let mut out = [0u8; RECORD_LEN];
        out[..4].copy_from_slice(&a.to_le_bytes());
        out[4..].copy_from_slice(&b.to_le_bytes());
        out
    }

    /// Decode one record; `None` if it is not a valid record.
    pub fn decode(words: [u32; 2]) -> Option<BleSettings> {
        let [magic, w] = words;
        let f = w as u8;
        if magic != MAGIC
            || (w >> 8) as u8 != !f
            || w >> 16 != 0
            || f & !(DISCOVERABLE | BLE_MIDI) != 0
        {
            return None;
        }
        Some(BleSettings {
            discoverable: f & DISCOVERABLE != 0,
            ble_midi: f & BLE_MIDI != 0,
        })
    }
}

/// What the log page holds.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Scan {
    /// Latest valid record, if any.
    pub latest: Option<BleSettings>,
    /// Slot for the next record; `None` when the page is full and must be
    /// erased first.
    pub next_slot: Option<usize>,
}

const ERASED: u32 = 0xFFFF_FFFF;

/// Scan a page given as `SLOTS` pairs of words (`word(i)` returns the
/// record in slot `i`).
pub fn scan(word: impl Fn(usize) -> [u32; 2]) -> Scan {
    let mut latest = None;
    for i in 0..SLOTS {
        let w = word(i);
        if w == [ERASED, ERASED] {
            return Scan {
                latest,
                next_slot: Some(i),
            };
        }
        if let Some(s) = BleSettings::decode(w) {
            latest = Some(s);
        }
    }
    Scan {
        latest,
        next_slot: None,
    }
}

/// Address of slot `i` in the page.
pub fn slot_addr(i: usize) -> u32 {
    PAGE_ADDR + (i * RECORD_LEN) as u32
}
