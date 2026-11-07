// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Nymble (https://github.com/nymble)

//! Minimal `no_std` driver for the ST **LSM6DS3TR-C** 6-axis IMU over I²C,
//! written from the ST datasheet (DocID030071 Rev 3), section 9 (register map).
//!
//! On the Seeed XIAO nRF52840 *Sense* the sensor sits on the internal bus
//! (SDA P0.07, SCL P0.27) at address **0x6A** (SDO/SA0 tied to GND) and is
//! powered from GPIO P1.08; see `docs/firmware-xiao-sense.md`.
//!
//! Scope: identification, software reset, accelerometer + gyroscope
//! configuration (ODR, full scale), block data update, data-ready routing to
//! INT1, status polling and burst reads of gyro + accel (+ temperature).

#![cfg_attr(not(test), no_std)]
#![forbid(unsafe_code)]
#![warn(missing_docs)]

use core::fmt;
use embedded_hal::delay::DelayNs;
use embedded_hal::i2c::I2c;

/// I²C address with SDO/SA0 tied to GND (XIAO nRF52840 Sense).
pub const ADDRESS_SA0_LOW: u8 = 0x6A;
/// I²C address with SDO/SA0 tied to VDDIO.
pub const ADDRESS_SA0_HIGH: u8 = 0x6B;
/// WHO_AM_I value of the LSM6DS3TR-C.
pub const WHO_AM_I_VALUE: u8 = 0x6A;
/// Turn-on time from power applied to valid data (datasheet Ton, typical).
pub const TURN_ON_MS: u32 = 35;

/// Register addresses (datasheet Table 18).
pub mod reg {
    /// INT1 pad control.
    pub const INT1_CTRL: u8 = 0x0D;
    /// Identification, reads 0x6A.
    pub const WHO_AM_I: u8 = 0x0F;
    /// Accelerometer ODR / full scale.
    pub const CTRL1_XL: u8 = 0x10;
    /// Gyroscope ODR / full scale.
    pub const CTRL2_G: u8 = 0x11;
    /// BOOT, BDU, IF_INC, SW_RESET.
    pub const CTRL3_C: u8 = 0x12;
    /// Data-ready flags.
    pub const STATUS_REG: u8 = 0x1E;
    /// Temperature, then gyro X/Y/Z, then accel X/Y/Z (14 bytes, little endian).
    pub const OUT_TEMP_L: u8 = 0x20;
}

/// CTRL3_C bits.
pub mod ctrl3 {
    /// Reboot memory content.
    pub const BOOT: u8 = 1 << 7;
    /// Block data update: output registers not updated until both bytes read.
    pub const BDU: u8 = 1 << 6;
    /// Auto-increment register address on multi-byte access (default 1).
    pub const IF_INC: u8 = 1 << 2;
    /// Software reset (self-clearing).
    pub const SW_RESET: u8 = 1 << 0;
}

/// Output data rate shared by accelerometer and gyroscope (high-performance).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum Odr {
    /// Power down.
    PowerDown = 0b0000,
    /// 12.5 Hz.
    Hz12_5 = 0b0001,
    /// 26 Hz.
    Hz26 = 0b0010,
    /// 52 Hz.
    Hz52 = 0b0011,
    /// 104 Hz.
    Hz104 = 0b0100,
    /// 208 Hz.
    Hz208 = 0b0101,
    /// 416 Hz.
    Hz416 = 0b0110,
    /// 833 Hz.
    Hz833 = 0b0111,
    /// 1.66 kHz.
    Hz1660 = 0b1000,
}

impl Odr {
    /// Nominal rate in Hz (0 for power-down).
    pub fn hz(self) -> f32 {
        match self {
            Odr::PowerDown => 0.0,
            Odr::Hz12_5 => 12.5,
            Odr::Hz26 => 26.0,
            Odr::Hz52 => 52.0,
            Odr::Hz104 => 104.0,
            Odr::Hz208 => 208.0,
            Odr::Hz416 => 416.0,
            Odr::Hz833 => 833.0,
            Odr::Hz1660 => 1660.0,
        }
    }
}

/// Accelerometer full scale.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AccelScale {
    /// ±2 g, 0.061 mg/LSB.
    G2,
    /// ±4 g, 0.122 mg/LSB.
    G4,
    /// ±8 g, 0.244 mg/LSB.
    G8,
    /// ±16 g, 0.488 mg/LSB.
    G16,
}

impl AccelScale {
    fn bits(self) -> u8 {
        // FS_XL[1:0]: 00 ±2 g, 01 ±16 g, 10 ±4 g, 11 ±8 g (Table 51)
        match self {
            AccelScale::G2 => 0b00,
            AccelScale::G16 => 0b01,
            AccelScale::G4 => 0b10,
            AccelScale::G8 => 0b11,
        }
    }
    /// Sensitivity in g per LSB (Table 3, LA_So).
    pub fn g_per_lsb(self) -> f32 {
        match self {
            AccelScale::G2 => 0.061e-3,
            AccelScale::G4 => 0.122e-3,
            AccelScale::G8 => 0.244e-3,
            AccelScale::G16 => 0.488e-3,
        }
    }
}

/// Gyroscope full scale.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum GyroScale {
    /// ±125 dps, 4.375 mdps/LSB.
    Dps125,
    /// ±250 dps, 8.75 mdps/LSB.
    Dps250,
    /// ±500 dps, 17.5 mdps/LSB.
    Dps500,
    /// ±1000 dps, 35 mdps/LSB.
    Dps1000,
    /// ±2000 dps, 70 mdps/LSB.
    Dps2000,
}

impl GyroScale {
    fn bits(self) -> u8 {
        // FS_G[1:0] in bits 3:2, FS_125 in bit 1 (Table 54)
        match self {
            GyroScale::Dps125 => 0b0010,
            GyroScale::Dps250 => 0b0000,
            GyroScale::Dps500 => 0b0100,
            GyroScale::Dps1000 => 0b1000,
            GyroScale::Dps2000 => 0b1100,
        }
    }
    /// Sensitivity in degrees per second per LSB (Table 3, G_So).
    pub fn dps_per_lsb(self) -> f32 {
        match self {
            GyroScale::Dps125 => 4.375e-3,
            GyroScale::Dps250 => 8.75e-3,
            GyroScale::Dps500 => 17.5e-3,
            GyroScale::Dps1000 => 35e-3,
            GyroScale::Dps2000 => 70e-3,
        }
    }
}

/// Sensor configuration.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Config {
    /// Accelerometer ODR.
    pub accel_odr: Odr,
    /// Accelerometer full scale.
    pub accel_scale: AccelScale,
    /// Gyroscope ODR.
    pub gyro_odr: Odr,
    /// Gyroscope full scale.
    pub gyro_scale: GyroScale,
    /// Route accelerometer data-ready to INT1.
    pub int1_drdy_accel: bool,
}

impl Default for Config {
    /// 416 Hz accel ±4 g and gyro ±1000 dps, data-ready on INT1. Chosen for
    /// gesture control: 2.4 ms sample period, headroom for shakes/taps.
    fn default() -> Self {
        Self {
            accel_odr: Odr::Hz416,
            accel_scale: AccelScale::G4,
            gyro_odr: Odr::Hz416,
            gyro_scale: GyroScale::Dps1000,
            int1_drdy_accel: true,
        }
    }
}

/// Raw 16-bit sample (sensor axes).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct RawSample {
    /// Temperature, 256 LSB/°C.
    pub temp: i16,
    /// Gyro X/Y/Z.
    pub gyro: [i16; 3],
    /// Accel X/Y/Z.
    pub accel: [i16; 3],
}

/// Scaled sample.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Sample {
    /// Acceleration in g.
    pub accel_g: [f32; 3],
    /// Angular rate in degrees per second.
    pub gyro_dps: [f32; 3],
}

/// Decode the 14-byte burst starting at OUT_TEMP_L.
pub fn decode_burst(b: &[u8; 14]) -> RawSample {
    let w = |i: usize| i16::from_le_bytes([b[i], b[i + 1]]);
    RawSample {
        temp: w(0),
        gyro: [w(2), w(4), w(6)],
        accel: [w(8), w(10), w(12)],
    }
}

/// Driver error.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Error<E> {
    /// Bus error.
    I2c(E),
    /// WHO_AM_I mismatch (found value).
    WrongId(u8),
    /// Software reset bit did not clear.
    ResetTimeout,
}

impl<E> From<E> for Error<E> {
    fn from(e: E) -> Self {
        Error::I2c(e)
    }
}

impl<E: fmt::Debug> fmt::Display for Error<E> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::I2c(e) => write!(f, "I2C error: {e:?}"),
            Error::WrongId(v) => write!(f, "WHO_AM_I 0x{v:02X}, expected 0x6A (LSM6DS3TR-C)"),
            Error::ResetTimeout => f.write_str("software reset did not complete"),
        }
    }
}

impl<E: fmt::Debug> core::error::Error for Error<E> {}

/// LSM6DS3TR-C on an I²C bus.
pub struct Lsm6ds3trc<I2C> {
    i2c: I2C,
    address: u8,
    config: Config,
}

impl<I2C: I2c> Lsm6ds3trc<I2C> {
    /// New driver; no bus traffic.
    pub fn new(i2c: I2C, address: u8) -> Self {
        Self {
            i2c,
            address,
            config: Config::default(),
        }
    }

    /// Release the bus.
    pub fn release(self) -> I2C {
        self.i2c
    }

    /// Active configuration.
    pub fn config(&self) -> Config {
        self.config
    }

    /// Read WHO_AM_I.
    pub fn who_am_i(&mut self) -> Result<u8, Error<I2C::Error>> {
        self.read_reg(reg::WHO_AM_I)
    }

    /// Check identity, software-reset, then apply `config`.
    pub fn init<D: DelayNs>(
        &mut self,
        delay: &mut D,
        config: Config,
    ) -> Result<(), Error<I2C::Error>> {
        let id = self.who_am_i()?;
        if id != WHO_AM_I_VALUE {
            return Err(Error::WrongId(id));
        }
        self.write_reg(reg::CTRL3_C, ctrl3::SW_RESET | ctrl3::IF_INC)?;
        let mut cleared = false;
        for _ in 0..10 {
            delay.delay_ms(1);
            if self.read_reg(reg::CTRL3_C)? & ctrl3::SW_RESET == 0 {
                cleared = true;
                break;
            }
        }
        if !cleared {
            return Err(Error::ResetTimeout);
        }
        self.configure(config)
    }

    /// Write ODR/scale/BDU/INT1 registers.
    pub fn configure(&mut self, config: Config) -> Result<(), Error<I2C::Error>> {
        self.write_reg(reg::CTRL3_C, ctrl3::BDU | ctrl3::IF_INC)?;
        self.write_reg(
            reg::CTRL1_XL,
            ((config.accel_odr as u8) << 4) | (config.accel_scale.bits() << 2),
        )?;
        self.write_reg(
            reg::CTRL2_G,
            ((config.gyro_odr as u8) << 4) | config.gyro_scale.bits(),
        )?;
        self.write_reg(reg::INT1_CTRL, u8::from(config.int1_drdy_accel))?;
        self.config = config;
        Ok(())
    }

    /// STATUS_REG: bit0 XLDA, bit1 GDA, bit2 TDA.
    pub fn status(&mut self) -> Result<u8, Error<I2C::Error>> {
        self.read_reg(reg::STATUS_REG)
    }

    /// Burst-read temperature, gyro and accel (one 14-byte transaction).
    pub fn read_raw(&mut self) -> Result<RawSample, Error<I2C::Error>> {
        let mut b = [0u8; 14];
        self.i2c
            .write_read(self.address, &[reg::OUT_TEMP_L], &mut b)?;
        Ok(decode_burst(&b))
    }

    /// Read and scale to g and dps using the configured full scales.
    pub fn read(&mut self) -> Result<Sample, Error<I2C::Error>> {
        let raw = self.read_raw()?;
        Ok(scale(&raw, self.config.accel_scale, self.config.gyro_scale))
    }

    fn read_reg(&mut self, r: u8) -> Result<u8, Error<I2C::Error>> {
        let mut b = [0u8];
        self.i2c.write_read(self.address, &[r], &mut b)?;
        Ok(b[0])
    }

    fn write_reg(&mut self, r: u8, v: u8) -> Result<(), Error<I2C::Error>> {
        self.i2c.write(self.address, &[r, v])?;
        Ok(())
    }
}

/// Scale a raw sample.
pub fn scale(raw: &RawSample, a: AccelScale, g: GyroScale) -> Sample {
    let mut s = Sample::default();
    for i in 0..3 {
        s.accel_g[i] = raw.accel[i] as f32 * a.g_per_lsb();
        s.gyro_dps[i] = raw.gyro[i] as f32 * g.dps_per_lsb();
    }
    s
}

#[cfg(test)]
mod tests {
    use super::*;
    use embedded_hal_mock::eh1::delay::NoopDelay;
    use embedded_hal_mock::eh1::i2c::{Mock, Transaction as T};

    const A: u8 = ADDRESS_SA0_LOW;

    #[test]
    fn init_default_config_bytes() {
        let ex = [
            T::write_read(A, vec![0x0F], vec![0x6A]),
            T::write(A, vec![0x12, 0x05]), // SW_RESET | IF_INC
            T::write_read(A, vec![0x12], vec![0x04]),
            T::write(A, vec![0x12, 0x44]),        // BDU | IF_INC
            T::write(A, vec![0x10, 0b0110_1000]), // 416 Hz, ±4 g
            T::write(A, vec![0x11, 0b0110_1000]), // 416 Hz, ±1000 dps
            T::write(A, vec![0x0D, 0x01]),        // INT1_DRDY_XL
        ];
        let mut i2c = Mock::new(&ex);
        let mut imu = Lsm6ds3trc::new(i2c.clone(), A);
        imu.init(&mut NoopDelay::new(), Config::default()).unwrap();
        i2c.done();
    }

    #[test]
    fn wrong_id_rejected() {
        let ex = [T::write_read(A, vec![0x0F], vec![0x69])];
        let mut i2c = Mock::new(&ex);
        let mut imu = Lsm6ds3trc::new(i2c.clone(), A);
        assert_eq!(
            imu.init(&mut NoopDelay::new(), Config::default()),
            Err(Error::WrongId(0x69))
        );
        i2c.done();
    }

    #[test]
    fn reset_timeout_reported() {
        let mut ex = vec![
            T::write_read(A, vec![0x0F], vec![0x6A]),
            T::write(A, vec![0x12, 0x05]),
        ];
        for _ in 0..10 {
            ex.push(T::write_read(A, vec![0x12], vec![0x05]));
        }
        let mut i2c = Mock::new(&ex);
        let mut imu = Lsm6ds3trc::new(i2c.clone(), A);
        assert_eq!(
            imu.init(&mut NoopDelay::new(), Config::default()),
            Err(Error::ResetTimeout)
        );
        i2c.done();
    }

    #[test]
    fn burst_decode_and_scale() {
        // temp=0x0100, gx=1000, gy=-1000, gz=0, ax=8197 (~1 g at ±4 g), ay=0, az=-8197
        let mut b = [0u8; 14];
        let vals: [i16; 7] = [256, 1000, -1000, 0, 8197, 0, -8197];
        for (i, v) in vals.iter().enumerate() {
            b[2 * i..2 * i + 2].copy_from_slice(&v.to_le_bytes());
        }
        let raw = decode_burst(&b);
        assert_eq!(raw.temp, 256);
        assert_eq!(raw.gyro, [1000, -1000, 0]);
        let s = scale(&raw, AccelScale::G4, GyroScale::Dps1000);
        assert!((s.accel_g[0] - 1.0).abs() < 0.001);
        assert!((s.accel_g[2] + 1.0).abs() < 0.001);
        assert!((s.gyro_dps[0] - 35.0).abs() < 1e-4);
    }

    #[test]
    fn scale_bit_patterns_match_datasheet() {
        assert_eq!(AccelScale::G16.bits(), 0b01);
        assert_eq!(AccelScale::G4.bits(), 0b10);
        assert_eq!(GyroScale::Dps125.bits(), 0b0010);
        assert_eq!(GyroScale::Dps2000.bits(), 0b1100);
        assert_eq!(Odr::Hz416 as u8, 0b0110);
    }
}
