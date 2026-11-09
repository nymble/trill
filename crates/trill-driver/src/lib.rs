// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Nymble (https://github.com/nymble)

//! `no_std` driver for Bela Trill capacitive touch sensors, written against
//! the [`embedded_hal::i2c::I2c`] and [`embedded_hal::delay::DelayNs`] 1.0 traits.
//!
//! This is an independent implementation of the I²C protocol described in the
//! Trill datasheet (Rev C, v1.3, section 7). It is not affiliated with or
//! endorsed by Bela / Augmented Instruments Ltd.
//!
//! Scope of this version:
//! * Identify (device type + firmware version) with acknowledgement polling.
//! * Mode, scan settings, prescaler, noise threshold, IDAC, minimum size,
//!   baseline update, reset.
//! * Bounded decoding of 1-axis centroid frames (Bar, Craft, Ring, Flex) and of
//!   16-bit Raw / Baseline / Diff channel frames.
//!
//! Not yet implemented: 2-axis centroid decoding (Square, Hex), 8/12-bit
//! transmission formats, channel masks, event mode, timer-driven scanning.
//!
//! ```no_run
//! # fn demo<I: embedded_hal::i2c::I2c, D: embedded_hal::delay::DelayNs>(i2c: I, mut delay: D)
//! #     -> Result<(), trill_driver::Error<I::Error>> {
//! use trill_driver::{Config, Device, Trill, DEFAULT_FLEX_ADDRESS};
//! let mut trill = Trill::new(i2c, DEFAULT_FLEX_ADDRESS);
//! let id = trill.init(&mut delay, Some(Device::Flex), &Config::for_device(Device::Flex))?;
//! let frame = trill.read_touches(&mut delay)?;
//! for touch in frame.iter() {
//!     let _pos = touch.normalised(id.device); // 0.0 ..= 1.0 along the strip
//! }
//! # Ok(()) }
//! ```

#![no_std]
#![forbid(unsafe_code)]
#![warn(missing_docs)]

use core::fmt;
use embedded_hal::delay::DelayNs;
use embedded_hal::i2c::I2c;

pub mod protocol;
use protocol::*;

/// Default 7-bit I²C address of Trill Flex (no address pads bridged).
pub const DEFAULT_FLEX_ADDRESS: u8 = 0x48;

/// Maximum number of touches reported on one axis in centroid mode.
pub const MAX_TOUCHES_1D: usize = 5;

/// Maximum number of capacitive channels on any Trill device.
pub const MAX_CHANNELS: usize = 30;

/// Trill device type, as reported by the Identify command.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum Device {
    /// Trill Bar (1-axis, 26 channels).
    Bar = 1,
    /// Trill Square (2-axis).
    Square = 2,
    /// Trill Craft (30 channels, custom geometry).
    Craft = 3,
    /// Trill Ring (1-axis circular plus two pads).
    Ring = 4,
    /// Trill Hex (2-axis).
    Hex = 5,
    /// Trill Flex (30 channels on a flexible PCB).
    Flex = 6,
}

impl Device {
    /// Parse a device-type byte from an Identify response.
    pub const fn from_code(code: u8) -> Option<Self> {
        match code {
            1 => Some(Self::Bar),
            2 => Some(Self::Square),
            3 => Some(Self::Craft),
            4 => Some(Self::Ring),
            5 => Some(Self::Hex),
            6 => Some(Self::Flex),
            _ => None,
        }
    }

    /// Human-readable name.
    pub const fn name(self) -> &'static str {
        match self {
            Self::Bar => "Bar",
            Self::Square => "Square",
            Self::Craft => "Craft",
            Self::Ring => "Ring",
            Self::Hex => "Hex",
            Self::Flex => "Flex",
        }
    }

    /// Default 7-bit I²C address (datasheet Table 8, offset +0).
    pub const fn default_address(self) -> u8 {
        match self {
            Self::Bar => 0x20,
            Self::Square => 0x28,
            Self::Craft => 0x30,
            Self::Ring => 0x38,
            Self::Hex => 0x40,
            Self::Flex => 0x48,
        }
    }

    /// Number of capacitive channels reported in Raw/Baseline/Diff mode with
    /// the default (all-enabled) channel mask.
    pub const fn num_channels(self) -> usize {
        match self {
            Self::Bar => 26,
            _ => 30,
        }
    }

    /// `true` for sensors whose centroid payload is a single axis.
    pub const fn is_1d(self) -> bool {
        matches!(self, Self::Bar | Self::Craft | Self::Ring | Self::Flex)
    }

    /// Centroid payload length in bytes (datasheet Table 14).
    pub const fn centroid_len(self) -> usize {
        match self {
            Self::Square | Self::Hex => 32,
            Self::Ring => 24,
            _ => 20,
        }
    }

    /// Full-scale value of a centroid location, if documented.
    ///
    /// The datasheet gives the range `0 ..= 128 * (n - 1)` for `n` pads on
    /// the axis. Flex: 30 pads → 3712. Bar: 26 → 3200. Ring: 28 slider pads
    /// → 3584. Craft is not given a value because its geometry is user-defined.
    pub const fn location_full_scale(self) -> Option<u16> {
        match self {
            Self::Flex => Some(3712),
            Self::Bar => Some(3200),
            Self::Ring => Some(3584),
            _ => None,
        }
    }
}

impl fmt::Display for Device {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.name())
    }
}

/// Acquisition mode (Mode command argument).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum Mode {
    /// On-sensor touch detection: location and size of up to 5 touches.
    Centroid = 0,
    /// Raw capacitance reading per channel.
    Raw = 1,
    /// Baseline per channel.
    Baseline = 2,
    /// Raw minus baseline per channel (touch activation).
    Diff = 3,
}

impl fmt::Display for Mode {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::Centroid => "centroid",
            Self::Raw => "raw",
            Self::Baseline => "baseline",
            Self::Diff => "diff",
        })
    }
}

/// Scanning speed (first ScanSettings argument).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum Speed {
    /// `CSD_ULTRA_FAST_SPEED` (default).
    UltraFast = 0,
    /// `CSD_FAST_SPEED`.
    Fast = 1,
    /// `CSD_NORMAL_SPEED`.
    Normal = 2,
    /// `CSD_SLOW_SPEED`.
    Slow = 3,
}

/// Device type and firmware revision returned by Identify.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Identity {
    /// Detected device type.
    pub device: Device,
    /// Firmware revision. Rev C sensors report 3.
    pub firmware: u8,
}

/// Sensor configuration applied by [`Trill::init`].
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Config {
    /// Acquisition mode.
    pub mode: Mode,
    /// Scan speed.
    pub speed: Speed,
    /// Scan resolution in bits, 9 ..= 16.
    pub bits: u8,
    /// Prescaler index 0 ..= 8 (divides by 2^index).
    pub prescaler: u8,
    /// Noise threshold in raw counts (`CSD_bNoiseThreshold`).
    pub noise_threshold: u8,
}

impl Config {
    /// Configuration matching the defaults chosen by Bela's Trill-Linux
    /// library for each device type: centroid mode (Craft: diff),
    /// ultra-fast speed, 12 bits, per-device prescaler, and a noise
    /// threshold of `40/4096` of full scale (Flex: `0.03`).
    pub fn for_device(device: Device) -> Self {
        let (mode, prescaler, threshold) = match device {
            Device::Bar => (Mode::Centroid, 2, 40.0 / 4096.0),
            Device::Square => (Mode::Centroid, 1, 40.0 / 4096.0),
            Device::Craft => (Mode::Diff, 1, 40.0 / 4096.0),
            Device::Ring => (Mode::Centroid, 2, 40.0 / 4096.0),
            Device::Hex => (Mode::Centroid, 1, 40.0 / 4096.0),
            Device::Flex => (Mode::Centroid, 4, 0.03),
        };
        let bits = 12;
        Self {
            mode,
            speed: Speed::UltraFast,
            bits,
            prescaler,
            noise_threshold: noise_threshold_counts(threshold, bits),
        }
    }

    /// Same as [`Config::for_device`] with a different mode.
    pub fn with_mode(mut self, mode: Mode) -> Self {
        self.mode = mode;
        self
    }
}

/// Convert a noise threshold expressed as a fraction of full scale into the
/// 8-bit count sent with the NoiseThreshold command, for a given resolution.
/// The result is rounded and saturated to `0 ..= 255`.
pub fn noise_threshold_counts(fraction: f32, bits: u8) -> u8 {
    let bits = bits.clamp(MIN_BITS, MAX_BITS);
    let counts = fraction * (1u32 << bits) as f32 + 0.5;
    if counts.is_nan() || counts <= 0.0 {
        0
    } else if counts >= 255.0 {
        255
    } else {
        counts as u8
    }
}

/// One detected touch in centroid mode.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Touch {
    /// Location in sensor units, `0 ..= 128 * (pads - 1)` (Flex: 0 ..= 3712).
    pub location: u16,
    /// Sum of the differential readings of the pads assigned to the touch.
    /// Uncalibrated; depends on scan settings and sensor geometry.
    pub size: u16,
}

impl Touch {
    /// Location normalised to `0.0 ..= 1.0` using the device full scale, or
    /// `None` when the device has no documented full scale.
    pub fn normalised(&self, device: Device) -> Option<f32> {
        device
            .location_full_scale()
            .map(|fs| (self.location as f32 / fs as f32).clamp(0.0, 1.0))
    }
}

/// Touches decoded from one 1-axis centroid frame.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Touches {
    touches: [Touch; MAX_TOUCHES_1D],
    count: u8,
}

impl Touches {
    /// Number of active touches (0 ..= 5).
    pub fn len(&self) -> usize {
        self.count as usize
    }
    /// `true` when no touch is present.
    pub fn is_empty(&self) -> bool {
        self.count == 0
    }
    /// Active touches, in the order reported by the sensor.
    pub fn as_slice(&self) -> &[Touch] {
        &self.touches[..self.len()]
    }
    /// Iterate over active touches.
    pub fn iter(&self) -> core::slice::Iter<'_, Touch> {
        self.as_slice().iter()
    }
}

/// Decode a 1-axis centroid payload (offset 4 onward).
///
/// Layout (datasheet Table 12): five big-endian `u16` locations followed by
/// five big-endian `u16` sizes. The first location equal to `0xFFFF` ends the
/// list. Input shorter than 20 bytes yields only the touches fully present.
pub fn decode_centroids_1d(payload: &[u8]) -> Touches {
    let mut out = Touches::default();
    for i in 0..MAX_TOUCHES_1D {
        let loc = be_u16(payload, 2 * i);
        let size = be_u16(payload, 2 * (MAX_TOUCHES_1D + i));
        match (loc, size) {
            (Some(NO_TOUCH), _) | (None, _) | (_, None) => break,
            (Some(location), Some(size)) => {
                out.touches[i] = Touch { location, size };
                out.count += 1;
            }
        }
    }
    out
}

/// Decode 16-bit big-endian channel values (Raw/Baseline/Diff, Format width
/// 16) into `out`. Returns the number of values written, bounded by both
/// `payload.len() / 2` and `out.len()`.
pub fn decode_channels_16(payload: &[u8], out: &mut [u16]) -> usize {
    let n = (payload.len() / 2).min(out.len());
    for (i, v) in out.iter_mut().enumerate().take(n) {
        *v = u16::from_be_bytes([payload[2 * i], payload[2 * i + 1]]);
    }
    n
}

fn be_u16(buf: &[u8], at: usize) -> Option<u16> {
    match (buf.get(at), buf.get(at + 1)) {
        (Some(&h), Some(&l)) => Some(u16::from_be_bytes([h, l])),
        _ => None,
    }
}

/// Status byte (offset 3, firmware ≥ 3).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Status(pub u8);

impl Status {
    /// 6-bit frame counter, incremented for every new scan.
    pub fn frame_id(self) -> u8 {
        self.0 & 0x3F
    }
    /// Activity detected in the current scan.
    pub fn activity(self) -> bool {
        self.0 & 0x40 != 0
    }
    /// Cleared on reset, set after Identify.
    pub fn initialised(self) -> bool {
        self.0 & 0x80 != 0
    }
}

/// One frame of per-channel readings.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Channels {
    values: [u16; MAX_CHANNELS],
    len: u8,
}

impl Channels {
    /// Channel values, `0 ..= 2^bits - 1` before any Format shift.
    pub fn as_slice(&self) -> &[u16] {
        &self.values[..self.len as usize]
    }
}

/// Driver error.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Error<E> {
    /// Underlying I²C bus error (NACK, arbitration loss, …).
    I2c(E),
    /// The sensor did not acknowledge a command within the polling budget.
    NoAck {
        /// Command code that was not acknowledged.
        command: u8,
    },
    /// Identify returned no recognisable device (all zeros or no ACK byte).
    NotDetected,
    /// Identify returned an unknown device-type byte.
    UnknownDevice(u8),
    /// A different device type than the one requested was found.
    WrongDevice {
        /// Requested device type.
        expected: Device,
        /// Device type reported by the sensor.
        found: Device,
    },
    /// An operation needing the device type was attempted before Identify.
    NotIdentified,
    /// The current mode does not produce the requested data.
    WrongMode {
        /// Mode the sensor is in.
        current: Mode,
    },
    /// Operation not implemented for this device in this driver version.
    Unsupported(&'static str),
    /// Firmware revision too old for the requested command.
    FirmwareTooOld {
        /// Minimum firmware revision.
        required: u8,
        /// Reported firmware revision.
        found: u8,
    },
    /// Argument outside its documented range.
    InvalidArgument(&'static str),
}

impl<E> From<E> for Error<E> {
    fn from(e: E) -> Self {
        Error::I2c(e)
    }
}

impl<E: fmt::Debug> fmt::Display for Error<E> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::I2c(e) => write!(f, "I2C bus error: {e:?}"),
            Error::NoAck { command } => {
                write!(
                    f,
                    "sensor did not acknowledge command {command} (0x{command:02X})"
                )
            }
            Error::NotDetected => f.write_str("no Trill device answered Identify at this address"),
            Error::UnknownDevice(c) => write!(f, "unknown Trill device type code {c}"),
            Error::WrongDevice { expected, found } => {
                write!(f, "expected Trill {expected}, found Trill {found}")
            }
            Error::NotIdentified => {
                f.write_str("device not identified yet; call identify() or init()")
            }
            Error::WrongMode { current } => {
                write!(f, "operation not valid while sensor is in {current} mode")
            }
            Error::Unsupported(what) => write!(f, "unsupported: {what}"),
            Error::FirmwareTooOld { required, found } => {
                write!(f, "firmware {found} too old, requires {required} or newer")
            }
            Error::InvalidArgument(what) => write!(f, "invalid argument: {what}"),
        }
    }
}

impl<E: fmt::Debug> core::error::Error for Error<E> {}

/// Trill sensor on an I²C bus.
pub struct Trill<I2C> {
    i2c: I2C,
    address: u8,
    identity: Option<Identity>,
    mode: Mode,
    read_offset: Option<u8>,
}

impl<I2C: I2c> Trill<I2C> {
    /// Create a driver for the sensor at the 7-bit `address`. No bus traffic.
    pub fn new(i2c: I2C, address: u8) -> Self {
        Self {
            i2c,
            address,
            identity: None,
            mode: Mode::Centroid,
            read_offset: None,
        }
    }

    /// Release the bus.
    pub fn release(self) -> I2C {
        self.i2c
    }

    /// 7-bit I²C address.
    pub fn address(&self) -> u8 {
        self.address
    }

    /// Result of the last successful Identify.
    pub fn identity(&self) -> Option<Identity> {
        self.identity
    }

    /// Mode last set through this driver (Centroid before any Mode command).
    pub fn mode(&self) -> Mode {
        self.mode
    }

    /// Identify, check the device type, and apply `config`
    /// (mode, prescaler, scan settings, noise threshold, then baseline update).
    pub fn init<D: DelayNs>(
        &mut self,
        delay: &mut D,
        expected: Option<Device>,
        config: &Config,
    ) -> Result<Identity, Error<I2C::Error>> {
        let id = self.identify(delay)?;
        if let Some(expected) = expected {
            if expected != id.device {
                return Err(Error::WrongDevice {
                    expected,
                    found: id.device,
                });
            }
        }
        self.set_mode(delay, config.mode)?;
        self.set_prescaler(delay, config.prescaler)?;
        self.set_scan_settings(delay, config.speed, config.bits)?;
        self.set_noise_threshold(delay, config.noise_threshold)?;
        self.update_baseline(delay)?;
        Ok(id)
    }

    /// Send Identify and read `[ACK, type, firmware]` from offset 0.
    ///
    /// Firmware ≥ 3 is detected by the `0xFE` acknowledgement byte. Older
    /// firmware does not acknowledge; after the polling budget the response
    /// is accepted if byte 1 is a valid device type and byte 2 is 1 or 2.
    pub fn identify<D: DelayNs>(&mut self, delay: &mut D) -> Result<Identity, Error<I2C::Error>> {
        self.identity = None;
        self.i2c
            .write(self.address, &[OFFSET_COMMAND, CMD_IDENTIFY])?;
        self.read_offset = Some(OFFSET_COMMAND);
        delay.delay_ms(IDENTIFY_DELAY_MS);

        let mut buf = [0u8; 3];
        let mut waited_ms = IDENTIFY_DELAY_MS;
        let mut step = ACK_POLL_START_MS;
        loop {
            self.i2c.read(self.address, &mut buf)?;
            if buf[0] == ACK_BYTE {
                break;
            }
            if waited_ms >= ACK_TIMEOUT_MS {
                // Legacy firmware (< 3) path.
                if Device::from_code(buf[1]).is_some() && matches!(buf[2], 1 | 2) {
                    break;
                }
                return Err(Error::NotDetected);
            }
            delay.delay_ms(step);
            waited_ms += step;
            step = (step * 2).min(ACK_POLL_MAX_STEP_MS);
        }
        if buf[1] == 0 {
            return Err(Error::NotDetected);
        }
        let device = Device::from_code(buf[1]).ok_or(Error::UnknownDevice(buf[1]))?;
        let id = Identity {
            device,
            firmware: buf[2],
        };
        self.identity = Some(id);
        Ok(id)
    }

    /// Set the acquisition mode.
    pub fn set_mode<D: DelayNs>(
        &mut self,
        delay: &mut D,
        mode: Mode,
    ) -> Result<(), Error<I2C::Error>> {
        self.command(delay, &[CMD_MODE, mode as u8])?;
        self.mode = mode;
        Ok(())
    }

    /// Set scan speed and resolution (`bits` must be 9 ..= 16).
    pub fn set_scan_settings<D: DelayNs>(
        &mut self,
        delay: &mut D,
        speed: Speed,
        bits: u8,
    ) -> Result<(), Error<I2C::Error>> {
        if !(MIN_BITS..=MAX_BITS).contains(&bits) {
            return Err(Error::InvalidArgument(
                "scan resolution must be 9..=16 bits",
            ));
        }
        self.command(delay, &[CMD_SCAN_SETTINGS, speed as u8, bits])
    }

    /// Set the prescaler index (0 ..= 8).
    pub fn set_prescaler<D: DelayNs>(
        &mut self,
        delay: &mut D,
        prescaler: u8,
    ) -> Result<(), Error<I2C::Error>> {
        if prescaler > MAX_PRESCALER {
            return Err(Error::InvalidArgument("prescaler must be 0..=8"));
        }
        self.command(delay, &[CMD_PRESCALER, prescaler])
    }

    /// Set the noise threshold in raw counts.
    pub fn set_noise_threshold<D: DelayNs>(
        &mut self,
        delay: &mut D,
        counts: u8,
    ) -> Result<(), Error<I2C::Error>> {
        self.command(delay, &[CMD_NOISE_THRESHOLD, counts])
    }

    /// Set the IDAC value.
    pub fn set_idac<D: DelayNs>(
        &mut self,
        delay: &mut D,
        value: u8,
    ) -> Result<(), Error<I2C::Error>> {
        self.command(delay, &[CMD_IDAC, value])
    }

    /// Set the minimum centroid size (raw size units, big-endian on the wire).
    pub fn set_minimum_size<D: DelayNs>(
        &mut self,
        delay: &mut D,
        size: u16,
    ) -> Result<(), Error<I2C::Error>> {
        let [hi, lo] = size.to_be_bytes();
        self.command(delay, &[CMD_MINIMUM_SIZE, hi, lo])
    }

    /// Re-capture the per-channel baseline. Do not touch the sensor meanwhile.
    pub fn update_baseline<D: DelayNs>(&mut self, delay: &mut D) -> Result<(), Error<I2C::Error>> {
        self.command(delay, &[CMD_BASELINE_UPDATE])
    }

    /// Reset the sensor MCU (firmware ≥ 3). Identify must be repeated afterwards.
    pub fn reset<D: DelayNs>(&mut self, delay: &mut D) -> Result<(), Error<I2C::Error>> {
        self.require_firmware(3)?;
        self.i2c.write(self.address, &[OFFSET_COMMAND, CMD_RESET])?;
        self.read_offset = None;
        self.identity = None;
        self.mode = Mode::Centroid;
        delay.delay_ms(RESET_DELAY_MS);
        Ok(())
    }

    /// Read the status byte (firmware ≥ 3).
    pub fn read_status<D: DelayNs>(&mut self, delay: &mut D) -> Result<Status, Error<I2C::Error>> {
        self.require_firmware(3)?;
        let mut b = [0u8; 1];
        self.read_from(delay, OFFSET_STATUS, &mut b)?;
        Ok(Status(b[0]))
    }

    /// Read one centroid frame. Requires an identified 1-axis device in
    /// centroid mode.
    pub fn read_touches<D: DelayNs>(
        &mut self,
        delay: &mut D,
    ) -> Result<Touches, Error<I2C::Error>> {
        let id = self.identity.ok_or(Error::NotIdentified)?;
        if self.mode != Mode::Centroid {
            return Err(Error::WrongMode { current: self.mode });
        }
        if !id.device.is_1d() {
            return Err(Error::Unsupported("2-axis centroid decoding (Square/Hex)"));
        }
        let mut buf = [0u8; 24];
        let len = id.device.centroid_len();
        self.read_from(delay, OFFSET_DATA, &mut buf[..len])?;
        Ok(decode_centroids_1d(&buf[..2 * 2 * MAX_TOUCHES_1D]))
    }

    /// Read the status byte and one centroid frame in a single I²C read
    /// starting at offset 3 (firmware ≥ 3). Comparing
    /// [`Status::frame_id`] with the previous call tells whether the sensor
    /// finished a new scan since then, so a caller polling faster than the
    /// scan time does not treat a repeated frame as new data.
    pub fn read_frame<D: DelayNs>(
        &mut self,
        delay: &mut D,
    ) -> Result<(Status, Touches), Error<I2C::Error>> {
        let id = self.identity.ok_or(Error::NotIdentified)?;
        self.require_firmware(3)?;
        if self.mode != Mode::Centroid {
            return Err(Error::WrongMode { current: self.mode });
        }
        if !id.device.is_1d() {
            return Err(Error::Unsupported("2-axis centroid decoding (Square/Hex)"));
        }
        let mut buf = [0u8; 25];
        let len = 1 + id.device.centroid_len();
        self.read_from(delay, OFFSET_STATUS, &mut buf[..len])?;
        Ok((
            Status(buf[0]),
            decode_centroids_1d(&buf[1..1 + 2 * 2 * MAX_TOUCHES_1D]),
        ))
    }

    /// Read one frame of 16-bit channel values. Requires an identified device
    /// in Raw, Baseline or Diff mode with the default Format (16 bit) and
    /// channel mask.
    pub fn read_channels<D: DelayNs>(
        &mut self,
        delay: &mut D,
    ) -> Result<Channels, Error<I2C::Error>> {
        let id = self.identity.ok_or(Error::NotIdentified)?;
        if self.mode == Mode::Centroid {
            return Err(Error::WrongMode { current: self.mode });
        }
        let n = id.device.num_channels();
        let mut buf = [0u8; 2 * MAX_CHANNELS];
        self.read_from(delay, OFFSET_DATA, &mut buf[..2 * n])?;
        let mut values = [0u16; MAX_CHANNELS];
        let len = decode_channels_16(&buf[..2 * n], &mut values[..n]);
        Ok(Channels {
            values,
            len: len as u8,
        })
    }

    fn require_firmware(&self, required: u8) -> Result<(), Error<I2C::Error>> {
        let id = self.identity.ok_or(Error::NotIdentified)?;
        if id.firmware < required {
            return Err(Error::FirmwareTooOld {
                required,
                found: id.firmware,
            });
        }
        Ok(())
    }

    fn read_from<D: DelayNs>(
        &mut self,
        delay: &mut D,
        offset: u8,
        buf: &mut [u8],
    ) -> Result<(), Error<I2C::Error>> {
        if self.read_offset != Some(offset) {
            self.read_offset = None;
            self.i2c.write(self.address, &[offset])?;
            self.read_offset = Some(offset);
            delay.delay_us(OFFSET_SETTLE_US);
        }
        self.i2c.read(self.address, buf)?;
        Ok(())
    }

    /// Write `[0, cmd, args..]` and wait until the sensor has processed it.
    fn command<D: DelayNs>(&mut self, delay: &mut D, cmd: &[u8]) -> Result<(), Error<I2C::Error>> {
        debug_assert!(!cmd.is_empty() && cmd.len() <= 3);
        let mut buf = [0u8; 4];
        buf[0] = OFFSET_COMMAND;
        buf[1..=cmd.len()].copy_from_slice(cmd);
        self.read_offset = None;
        self.i2c.write(self.address, &buf[..=cmd.len()])?;
        self.read_offset = Some(OFFSET_COMMAND);

        let firmware = self.identity.map(|i| i.firmware).unwrap_or(0);
        if firmware < 3 {
            // No acknowledgement before firmware 3: fixed inter-command delay.
            delay.delay_ms(LEGACY_COMMAND_DELAY_MS);
            return Ok(());
        }
        let mut waited_ms = 0;
        let mut step = ACK_POLL_START_MS;
        let mut ack = [0u8; 1];
        while waited_ms < ACK_TIMEOUT_MS {
            delay.delay_ms(step);
            waited_ms += step;
            self.i2c.read(self.address, &mut ack)?;
            if ack[0] == ACK_BYTE {
                return Ok(());
            }
            step = (step * 2).min(ACK_POLL_MAX_STEP_MS);
        }
        Err(Error::NoAck { command: cmd[0] })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn no_touch_frame_is_empty() {
        let t = decode_centroids_1d(&[0xFF; 20]);
        assert!(t.is_empty());
        assert_eq!(t.iter().count(), 0);
    }

    #[test]
    fn touches_stop_at_first_sentinel() {
        let mut p = [0xFFu8; 20];
        p[0..2].copy_from_slice(&100u16.to_be_bytes());
        p[2..4].copy_from_slice(&3712u16.to_be_bytes());
        // slot 2 empty, slot 3 has stale data that must be ignored
        p[6..8].copy_from_slice(&5u16.to_be_bytes());
        p[10..12].copy_from_slice(&50u16.to_be_bytes());
        p[12..14].copy_from_slice(&70u16.to_be_bytes());
        let t = decode_centroids_1d(&p);
        assert_eq!(t.len(), 2);
        assert_eq!(
            t.as_slice()[0],
            Touch {
                location: 100,
                size: 50
            }
        );
        assert_eq!(
            t.as_slice()[1],
            Touch {
                location: 3712,
                size: 70
            }
        );
        assert_eq!(t.as_slice()[1].normalised(Device::Flex), Some(1.0));
    }

    #[test]
    fn five_touches_maximum() {
        let mut p = [0u8; 20];
        for i in 0..5 {
            p[2 * i..2 * i + 2].copy_from_slice(&((i as u16 + 1) * 500).to_be_bytes());
            p[10 + 2 * i..12 + 2 * i].copy_from_slice(&(i as u16).to_be_bytes());
        }
        let t = decode_centroids_1d(&p);
        assert_eq!(t.len(), 5);
        assert_eq!(t.as_slice()[4].location, 2500);
    }

    #[test]
    fn truncated_payload_is_bounded() {
        assert!(decode_centroids_1d(&[]).is_empty());
        // location present but size region missing → not reported
        assert!(decode_centroids_1d(&[0x00, 0x10, 0x00]).is_empty());
        let mut out = [0u16; 4];
        assert_eq!(decode_channels_16(&[0, 1, 0, 2, 9], &mut out), 2);
        assert_eq!(out[..2], [1, 2]);
        let mut small = [0u16; 1];
        assert_eq!(decode_channels_16(&[0, 1, 0, 2], &mut small), 1);
    }

    #[test]
    fn location_beyond_full_scale_clamps() {
        let t = Touch {
            location: 4000,
            size: 1,
        };
        assert_eq!(t.normalised(Device::Flex), Some(1.0));
        assert_eq!(t.normalised(Device::Craft), None);
    }

    #[test]
    fn status_bits() {
        let s = Status(0b1100_0101);
        assert_eq!(s.frame_id(), 5);
        assert!(s.activity());
        assert!(s.initialised());
    }

    #[test]
    fn device_table() {
        assert_eq!(Device::from_code(6), Some(Device::Flex));
        assert_eq!(Device::from_code(0), None);
        assert_eq!(Device::from_code(7), None);
        assert_eq!(Device::Flex.default_address(), DEFAULT_FLEX_ADDRESS);
        assert_eq!(Device::Flex.num_channels(), 30);
        assert_eq!(Device::Bar.location_full_scale(), Some(128 * 25));
    }
}
