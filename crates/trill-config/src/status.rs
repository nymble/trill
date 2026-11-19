// SPDX-License-Identifier: GPL-3.0-only
//! Board status: battery and Bluetooth (`GET_STATUS` -> `STATUS`), behind
//! [`crate::VARIANT_STATUS`].
//!
//! ```text
//! STATUS payload (7 bytes, all 7-bit):
//!   0  format (1)
//!   1  power:  bits 0-1 battery (0 unknown, 1 absent, 2 present)
//!              bit 2 charging, bit 3 USB power present
//!   2  battery millivolts, high 7 bits   (14-bit value, 0 = not measured)
//!   3  battery millivolts, low 7 bits
//!   4  battery percent 0..=100, 127 = unknown
//!   5  Bluetooth settings: bit 0 discoverable, bit 1 Bluetooth MIDI on,
//!      bit 2 settings are stored on the board (survive a restart)
//!   6  Bluetooth link: bits 0-2 link (0 off, 1 advertising, 2 connected,
//!      3 streaming MIDI); bits 3-5 why Bluetooth is off (BluetoothOff)
//! ```
//!
//! Actions 10..=13 change the Bluetooth settings and are answered with a
//! `STATUS` reply that already shows the new settings (the link state
//! follows within about a second; hosts poll `GET_STATUS`).

use crate::{finish, header, msg, Reply};

/// `STATUS` payload format implemented here.
pub const STATUS_FORMAT: u8 = 1;
/// `STATUS` payload length.
pub const STATUS_LEN: usize = 7;
/// Percent byte meaning "unknown".
pub const PERCENT_UNKNOWN: u8 = 127;

/// Battery presence as judged by the firmware (see the `trill-board` crate
/// for the heuristic).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
#[repr(u8)]
pub enum Battery {
    /// Not judged yet (first seconds on USB power) or not measured.
    #[default]
    Unknown = 0,
    /// No battery detected.
    Absent = 1,
    /// A battery is fitted.
    Present = 2,
}

impl Battery {
    /// From the 2-bit wire value (3 reads as unknown).
    pub fn from_bits(b: u8) -> Self {
        match b & 0x03 {
            1 => Self::Absent,
            2 => Self::Present,
            _ => Self::Unknown,
        }
    }
}

/// Bluetooth link state.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
#[repr(u8)]
pub enum Link {
    /// Not advertising and not connected.
    #[default]
    Off = 0,
    /// Discoverable: advertising, no central connected.
    Advertising = 1,
    /// A central is connected but is not receiving MIDI.
    Connected = 2,
    /// A central is connected and receives instrument MIDI.
    Streaming = 3,
}

impl Link {
    /// From the 3-bit wire value (unknown values read as off).
    pub fn from_bits(b: u8) -> Self {
        match b & 0x07 {
            1 => Self::Advertising,
            2 => Self::Connected,
            3 => Self::Streaming,
            _ => Self::Off,
        }
    }
}

/// Why Bluetooth is not advertising or connected.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
#[repr(u8)]
pub enum BluetoothOff {
    /// Bluetooth is running (advertising or connected).
    #[default]
    Running = 0,
    /// This firmware was built without Bluetooth.
    NotBuilt = 1,
    /// Bluetooth needs a battery and none is detected.
    NoBattery = 2,
    /// Turned off in the settings (not discoverable and not connected).
    TurnedOff = 3,
    /// The Bluetooth stack is not available (no SoftDevice in flash, safe
    /// mode, or it failed to start). USB is unaffected.
    Unavailable = 4,
    /// Still checking for a battery (first seconds on USB power).
    CheckingBattery = 5,
}

impl BluetoothOff {
    /// From the 3-bit wire value (unknown values read as unavailable).
    pub fn from_bits(b: u8) -> Self {
        match b & 0x07 {
            0 => Self::Running,
            1 => Self::NotBuilt,
            2 => Self::NoBattery,
            3 => Self::TurnedOff,
            5 => Self::CheckingBattery,
            _ => Self::Unavailable,
        }
    }
}

/// Everything a `STATUS` reply carries.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub struct Status {
    /// Battery presence.
    pub battery: Battery,
    /// The charger reports charging (only meaningful on USB power).
    pub charging: bool,
    /// USB power (VBUS) is present.
    pub usb_power: bool,
    /// Battery voltage in mV (0 = not measured; saturates at 16383).
    pub battery_mv: u16,
    /// Approximate state of charge, `None` when unknown or no battery.
    pub battery_percent: Option<u8>,
    /// Setting: advertise so hosts can find the board.
    pub discoverable: bool,
    /// Setting: the BLE-MIDI service is active.
    pub ble_midi: bool,
    /// The Bluetooth settings are stored on the board.
    pub settings_stored: bool,
    /// Current link.
    pub link: Link,
    /// Why Bluetooth is off ([`BluetoothOff::Running`] when it is not).
    pub off_reason: BluetoothOff,
}

impl Status {
    /// A board without Bluetooth and without battery measurement.
    pub const NONE: Status = Status {
        battery: Battery::Unknown,
        charging: false,
        usb_power: false,
        battery_mv: 0,
        battery_percent: None,
        discoverable: false,
        ble_midi: false,
        settings_stored: false,
        link: Link::Off,
        off_reason: BluetoothOff::NotBuilt,
    };

    /// Encode the 7-byte payload.
    pub fn encode(&self) -> [u8; STATUS_LEN] {
        let mv = self.battery_mv.min(0x3FFF);
        [
            STATUS_FORMAT,
            self.battery as u8 | u8::from(self.charging) << 2 | u8::from(self.usb_power) << 3,
            (mv >> 7) as u8 & 0x7F,
            mv as u8 & 0x7F,
            self.battery_percent.map_or(PERCENT_UNKNOWN, |p| p.min(100)),
            u8::from(self.discoverable)
                | u8::from(self.ble_midi) << 1
                | u8::from(self.settings_stored) << 2,
            self.link as u8 | (self.off_reason as u8) << 3,
        ]
    }

    /// Decode a payload (host side and tests). `None` for a wrong length,
    /// format, or a byte with bit 7 set.
    pub fn decode(p: &[u8]) -> Option<Status> {
        if p.len() != STATUS_LEN || p[0] != STATUS_FORMAT || p.iter().any(|&b| b > 0x7F) {
            return None;
        }
        Some(Status {
            battery: Battery::from_bits(p[1]),
            charging: p[1] & 0x04 != 0,
            usb_power: p[1] & 0x08 != 0,
            battery_mv: u16::from(p[2]) << 7 | u16::from(p[3]),
            battery_percent: (p[4] <= 100).then_some(p[4]),
            discoverable: p[5] & 0x01 != 0,
            ble_midi: p[5] & 0x02 != 0,
            settings_stored: p[5] & 0x04 != 0,
            link: Link::from_bits(p[6]),
            off_reason: BluetoothOff::from_bits(p[6] >> 3),
        })
    }
}

/// Encode a `STATUS` reply.
pub fn status_reply(req: u8, s: &Status) -> Reply {
    let mut r = header(msg::STATUS, req);
    let _ = r.extend_from_slice(&s.encode());
    finish(r)
}
