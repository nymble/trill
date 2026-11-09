// SPDX-License-Identifier: GPL-3.0-only
//! USB device layout shared by the firmware and the host-side descriptor
//! tests, so the tests check the exact descriptors the firmware sends.
//!
//! Functions, in interface order:
//! 1. CDC ACM "diagnostics" (interfaces 0-1): text status and key commands.
//! 2. USB-MIDI 1.0 (interfaces 2-3): Audio Control + MIDI Streaming, two
//!    virtual cables (two embedded IN and two embedded OUT jacks) on one pair
//!    of 64-byte bulk endpoints. Cable 0 ([`CABLE_INSTRUMENT`]) carries only
//!    the instrument's notes and controllers; cable 1 ([`CABLE_CONFIG`])
//!    carries only the SysEx configuration protocol (`trill-config`), so
//!    configuration replies never appear on the port a DAW records from.
//!    Class compliant: macOS and iOS use their built-in driver and show each
//!    cable as its own MIDI source/destination pair.
//! 3. Optional CDC ACM "PCM" test stream (interfaces 4-5), only with the
//!    `pcm-synth` firmware feature.
//!
//! This is **not** a USB Audio (sound card) device: no audio streams.
//!
//! # Identifiers
//! VID `0x1209` is the pid.codes shared VID. PIDs `0x0001..=0x0010` are
//! pid.codes *test* PIDs, for private development and testing only; they must
//! not be used for distributed hardware (<https://pid.codes/1209/0002/>).
//! A distinct test PID is used per descriptor layout so a host that caches
//! descriptors per VID/PID does not mix them up. A product needs its own
//! assigned PID before distribution.
#![no_std]
#![forbid(unsafe_code)]
#![warn(missing_docs)]

use embassy_usb::class::cdc_acm::{CdcAcmClass, State};
use embassy_usb::class::midi::MidiClass;
use embassy_usb::driver::Driver;
use embassy_usb::{Builder, Config};

/// pid.codes VID.
pub const USB_VID: u16 = 0x1209;
/// pid.codes test PID for the default layout (diagnostics + MIDI).
pub const USB_PID_MIDI: u16 = 0x0002;
/// pid.codes test PID for the layout with the optional PCM port.
pub const USB_PID_MIDI_PCM: u16 = 0x0003;
/// USB-MIDI virtual cables (embedded jack pairs).
pub const MIDI_CABLES: u8 = 2;
/// Cable for instrument output (notes, controllers, pressure, bend).
pub const CABLE_INSTRUMENT: u8 = 0;
/// Cable for the SysEx configuration protocol (both directions).
pub const CABLE_CONFIG: u8 = 1;
/// `bcdDevice`: bumped whenever the descriptor layout changes under the same
/// PID (0x0200 = two MIDI cables), so hosts that cache descriptors per
/// VID/PID/bcdDevice re-read them.
pub const DEVICE_RELEASE: u16 = 0x0200;
/// Full-speed bulk packet size used by every function.
pub const MAX_PACKET: u16 = 64;
/// Size of the configuration-descriptor buffer the firmware must provide.
pub const CONFIG_DESC_LEN: usize = 384;
/// Size of the BOS-descriptor buffer.
pub const BOS_DESC_LEN: usize = 64;
/// Size of the control buffer.
pub const CONTROL_BUF_LEN: usize = 64;
/// Power requested from the host, mA. Kept at 100 mA (one unit load), which
/// is what bus-powered iOS adapters are expected to supply.
pub const MAX_POWER_MA: u16 = 100;

/// Product ID for a layout.
pub const fn product_id(pcm: bool) -> u16 {
    if pcm {
        USB_PID_MIDI_PCM
    } else {
        USB_PID_MIDI
    }
}

/// Device configuration for a layout.
pub fn device_config(pcm: bool) -> Config<'static> {
    let mut cfg = Config::new(USB_VID, product_id(pcm));
    cfg.manufacturer = Some("nymble/trill");
    cfg.product = Some(if pcm {
        "Trill XIAO MIDI+PCM (dev)"
    } else {
        "Trill XIAO MIDI (dev)"
    });
    cfg.serial_number = None;
    cfg.device_release = DEVICE_RELEASE;
    cfg.max_power = MAX_POWER_MA;
    cfg.max_packet_size_0 = 64;
    // Composite with IADs: device class EF/02/01 (embassy default).
    cfg.composite_with_iads = true;
    cfg
}

/// The classes created on a builder.
pub struct Functions<'d, D: Driver<'d>> {
    /// Diagnostics CDC ACM port.
    pub diag: CdcAcmClass<'d, D>,
    /// USB-MIDI function.
    pub midi: MidiClass<'d, D>,
    /// Optional PCM CDC ACM port.
    pub pcm: Option<CdcAcmClass<'d, D>>,
}

/// Add all functions to `builder` in the documented order.
pub fn add_functions<'d, D: Driver<'d>>(
    builder: &mut Builder<'d, D>,
    diag_state: &'d mut State<'d>,
    pcm_state: Option<&'d mut State<'d>>,
) -> Functions<'d, D> {
    let diag = CdcAcmClass::new(builder, diag_state, MAX_PACKET);
    let midi = MidiClass::new(builder, MIDI_CABLES, MIDI_CABLES, MAX_PACKET);
    let pcm = pcm_state.map(|s| CdcAcmClass::new(builder, s, MAX_PACKET));
    Functions { diag, midi, pcm }
}
