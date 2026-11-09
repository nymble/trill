// SPDX-License-Identifier: GPL-3.0-only
//! Sensor telemetry (protocol v1 extension, firmware 0.3.0 and newer).
//!
//! The host subscribes with `TELEMETRY_START` (rate in Hz) and the device
//! then sends one [`msg::TELEMETRY`](crate::msg::TELEMETRY) frame per
//! period on the configuration cable. A subscription is a **lease**: it ends
//! [`LEASE_S`] seconds after the last `TELEMETRY_START` unless renewed, and
//! also on `TELEMETRY_STOP`, USB disconnect or device reset. Frames are
//! lossy: the newest sensor values are sampled when a frame can be sent, a
//! frame that cannot be sent in its period is skipped (counted in
//! [`Frame::skipped`]), and instrument MIDI on cable 0 always goes first.
//!
//! A frame is a snapshot of the latest values, not every sensor sample: the
//! IMU runs at 416 Hz on the device; telemetry is at most [`MAX_RATE_HZ`].
//!
//! Frame payload (all 7-bit bytes, big-endian groups):
//!
//! | Offset | Size | Field |
//! |---|---|---|
//! | 0 | 1 | format (= [`FORMAT`]) |
//! | 1 | 2 | sequence, 14-bit, wraps |
//! | 3 | 3 | device time of the IMU sample, ms, 21-bit, wraps (~35 min) |
//! | 6 | 1 | flags (`FLAG_*`) |
//! | 7 | 1 | IMU state (0 off, 1 init, 2 run, 3 retry, 4 disabled) |
//! | 8 | 1 | Trill state (same codes) |
//! | 9 | 9 | accel x, y, z: i16 in mg (1/1000 g) |
//! | 18 | 9 | gyro x, y, z: i16 in 0.1 °/s |
//! | 27 | 6 | pitch, roll: i16 in 0.01 ° |
//! | 33 | 2 | touch position, 14-bit, 0..=16383 = 0..1 along the strip |
//! | 35 | 2 | touch size, 14-bit, 0..=16383 = 0..1 of full scale |
//! | 37 | 2 | IMU samples read, 14-bit counter, wraps |
//! | 39 | 2 | taps detected, 14-bit counter, wraps |
//! | 41 | 1 | gyro calibrations completed, 7-bit counter, wraps |
//! | 42 | 2 | frames skipped by the device, 14-bit counter, wraps |
//! | 44 | 2 | Trill frames read, 14-bit counter, wraps |
//!
//! An i16 is sent as three bytes holding bits 15..14, 13..7 and 6..0 of
//! its two's-complement value.

use crate::{finish, header, msg, Reply};

/// Telemetry frame format implemented here.
pub const FORMAT: u8 = 1;
/// Highest accepted rate.
pub const MAX_RATE_HZ: u8 = 100;
/// Lowest accepted rate.
pub const MIN_RATE_HZ: u8 = 1;
/// Rate the app requests by default.
pub const DEFAULT_RATE_HZ: u8 = 50;
/// A subscription ends this long after the last `TELEMETRY_START`.
pub const LEASE_S: u8 = 5;
/// Payload bytes in a frame.
pub const PAYLOAD_LEN: usize = 46;
/// Complete frame length, `F0`..`F7`.
pub const FRAME_LEN: usize = crate::HEADER_LEN + PAYLOAD_LEN + 1;

/// IMU values are finite and come from a running sensor.
pub const FLAG_IMU_VALID: u8 = 0x01;
/// The gyro bias is calibrated (pitch/roll and rotation are meaningful).
pub const FLAG_CALIBRATED: u8 = 0x02;
/// A finger is on the Trill (position and size are meaningful).
pub const FLAG_TOUCH: u8 = 0x04;
/// At least one new IMU sample since the previous frame.
pub const FLAG_IMU_NEW: u8 = 0x08;
/// Firmware is in safe mode (sensors disabled after crash loops).
pub const FLAG_SAFE_MODE: u8 = 0x10;

/// One telemetry frame, in wire units.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Frame {
    /// Sequence number (14-bit, wraps).
    pub seq: u16,
    /// Device time of the IMU sample, ms (21-bit, wraps).
    pub t_ms: u32,
    /// `FLAG_*` bits.
    pub flags: u8,
    /// IMU state code.
    pub imu_state: u8,
    /// Trill state code.
    pub trill_state: u8,
    /// Acceleration, mg.
    pub accel_mg: [i16; 3],
    /// Angular rate, 0.1 °/s.
    pub gyro_ddps: [i16; 3],
    /// Pitch, 0.01 °.
    pub pitch_cdeg: i16,
    /// Roll, 0.01 °.
    pub roll_cdeg: i16,
    /// Touch position, 0..=16383.
    pub touch_pos: u16,
    /// Touch size, 0..=16383.
    pub touch_size: u16,
    /// IMU samples counter (14-bit).
    pub imu_samples: u16,
    /// Taps counter (14-bit).
    pub taps: u16,
    /// Calibrations counter (7-bit).
    pub calibrations: u8,
    /// Skipped frames counter (14-bit).
    pub skipped: u16,
    /// Trill frames counter (14-bit).
    pub trill_frames: u16,
}

/// Quantise `v * scale` to i16, saturating. Non-finite input gives `None`.
pub fn quantize(v: f32, scale: f32) -> Option<i16> {
    let x = v * scale;
    if !x.is_finite() {
        return None;
    }
    let r = if x >= 0.0 { x + 0.5 } else { x - 0.5 };
    Some(if r >= 32767.0 {
        32767
    } else if r <= -32768.0 {
        -32768
    } else {
        r as i16
    })
}

/// Quantise a 0..=1 value to 14 bits (NaN and negatives give 0).
pub fn unit14(v: f32) -> u16 {
    if v.is_nan() || v <= 0.0 {
        0
    } else if v >= 1.0 {
        0x3FFF
    } else {
        (v * 16383.0 + 0.5) as u16
    }
}

/// Raw sensor values from the firmware, in physical units.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Sample {
    /// Acceleration, g.
    pub accel_g: [f32; 3],
    /// Angular rate, °/s.
    pub gyro_dps: [f32; 3],
    /// Pitch, °.
    pub pitch_deg: f32,
    /// Roll, °.
    pub roll_deg: f32,
    /// Touch position 0..1, `None` = no touch.
    pub touch: Option<(f32, f32)>,
}

impl Frame {
    /// Fill the sensor fields from physical values. Clears
    /// [`FLAG_IMU_VALID`] (and zeroes the IMU fields) if any IMU value is
    /// not finite; the caller sets the remaining flags and counters.
    pub fn set_sample(&mut self, s: &Sample, imu_running: bool) {
        let mut ok = imu_running;
        let mut q = |v: f32, k: f32| match quantize(v, k) {
            Some(x) => x,
            None => {
                ok = false;
                0
            }
        };
        let accel = [
            q(s.accel_g[0], 1000.0),
            q(s.accel_g[1], 1000.0),
            q(s.accel_g[2], 1000.0),
        ];
        let gyro = [
            q(s.gyro_dps[0], 10.0),
            q(s.gyro_dps[1], 10.0),
            q(s.gyro_dps[2], 10.0),
        ];
        let pitch = q(s.pitch_deg, 100.0);
        let roll = q(s.roll_deg, 100.0);
        if ok {
            self.accel_mg = accel;
            self.gyro_ddps = gyro;
            self.pitch_cdeg = pitch;
            self.roll_cdeg = roll;
            self.flags |= FLAG_IMU_VALID;
        } else {
            self.accel_mg = [0; 3];
            self.gyro_ddps = [0; 3];
            self.pitch_cdeg = 0;
            self.roll_cdeg = 0;
            self.flags &= !FLAG_IMU_VALID;
        }
        match s.touch {
            Some((pos, size)) if pos.is_finite() && size.is_finite() => {
                self.touch_pos = unit14(pos);
                self.touch_size = unit14(size);
                self.flags |= FLAG_TOUCH;
            }
            _ => {
                self.touch_pos = 0;
                self.touch_size = 0;
                self.flags &= !FLAG_TOUCH;
            }
        }
    }
}

fn u14(r: &mut Reply, v: u16) {
    let _ = r.extend_from_slice(&[((v >> 7) & 0x7F) as u8, (v & 0x7F) as u8]);
}

fn i16w(r: &mut Reply, v: i16) {
    let u = v as u16;
    let _ = r.extend_from_slice(&[
        (u >> 14) as u8 & 0x03,
        (u >> 7) as u8 & 0x7F,
        u as u8 & 0x7F,
    ]);
}

/// Encode a `TELEMETRY` frame (request id field = 0).
pub fn encode(f: &Frame) -> Reply {
    let mut r = header(msg::TELEMETRY, 0);
    let _ = r.push(FORMAT);
    u14(&mut r, f.seq);
    let t = f.t_ms & 0x1F_FFFF;
    let _ = r.extend_from_slice(&[
        (t >> 14) as u8 & 0x7F,
        (t >> 7) as u8 & 0x7F,
        t as u8 & 0x7F,
    ]);
    let _ = r.extend_from_slice(&[f.flags & 0x7F, f.imu_state & 0x7F, f.trill_state & 0x7F]);
    for v in f.accel_mg.iter().chain(f.gyro_ddps.iter()) {
        i16w(&mut r, *v);
    }
    i16w(&mut r, f.pitch_cdeg);
    i16w(&mut r, f.roll_cdeg);
    u14(&mut r, f.touch_pos);
    u14(&mut r, f.touch_size);
    u14(&mut r, f.imu_samples);
    u14(&mut r, f.taps);
    let _ = r.push(f.calibrations & 0x7F);
    u14(&mut r, f.skipped);
    u14(&mut r, f.trill_frames);
    finish(r)
}

/// Decode a `TELEMETRY` frame (host side and tests). `None` if malformed
/// or of an unknown format.
pub fn decode(m: &[u8]) -> Option<Frame> {
    if m.len() != FRAME_LEN
        || m[0] != 0xF0
        || m[m.len() - 1] != 0xF7
        || m[1] != crate::MANUFACTURER_ID
        || m[2..4] != crate::SIGNATURE
        || m[4] != crate::PROTOCOL_VERSION
        || m[5] != msg::TELEMETRY
        || m[1..m.len() - 1].iter().any(|&b| b > 0x7F)
    {
        return None;
    }
    let p = &m[crate::HEADER_LEN..m.len() - 1];
    if p[0] != FORMAT {
        return None;
    }
    let u14 = |i: usize| (u16::from(p[i]) << 7) | u16::from(p[i + 1]);
    let i16r = |i: usize| {
        ((u16::from(p[i]) << 14) | (u16::from(p[i + 1]) << 7) | u16::from(p[i + 2])) as i16
    };
    Some(Frame {
        seq: u14(1),
        t_ms: (u32::from(p[3]) << 14) | (u32::from(p[4]) << 7) | u32::from(p[5]),
        flags: p[6],
        imu_state: p[7],
        trill_state: p[8],
        accel_mg: [i16r(9), i16r(12), i16r(15)],
        gyro_ddps: [i16r(18), i16r(21), i16r(24)],
        pitch_cdeg: i16r(27),
        roll_cdeg: i16r(30),
        touch_pos: u14(33),
        touch_size: u14(35),
        imu_samples: u14(37),
        taps: u14(39),
        calibrations: p[41],
        skipped: u14(42),
        trill_frames: u14(44),
    })
}

/// Encode a `TELEMETRY_ACK`: accepted rate (0 = stopped), lease, frame
/// length and format.
pub fn ack(req: u8, rate_hz: u8) -> Reply {
    let mut r = header(msg::TELEMETRY_ACK, req);
    let _ = r.extend_from_slice(&[rate_hz & 0x7F, LEASE_S, FRAME_LEN as u8, FORMAT]);
    finish(r)
}

/// Device-side scheduler: when the next frame is due, lease expiry and the
/// skipped-frame count. Time is in microseconds from a monotonic 64-bit
/// clock (embassy `Instant`, which does not wrap in practice).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Schedule {
    rate_hz: u8,
    lease_until_us: u64,
    next_due_us: u64,
    /// Sequence of the next frame (14-bit).
    pub seq: u16,
    /// Frames skipped because they could not be sent in their period.
    pub skipped: u16,
}

impl Schedule {
    /// Idle schedule.
    pub const fn new() -> Self {
        Self {
            rate_hz: 0,
            lease_until_us: 0,
            next_due_us: 0,
            seq: 0,
            skipped: 0,
        }
    }

    /// Current rate (0 = off).
    pub fn rate_hz(&self) -> u8 {
        self.rate_hz
    }

    /// Start or renew at `rate_hz` (0 stops). Renewing at the same rate
    /// keeps the frame phase.
    pub fn subscribe(&mut self, rate_hz: u8, now_us: u64) {
        let rate = rate_hz.min(MAX_RATE_HZ);
        if rate == 0 {
            self.rate_hz = 0;
            return;
        }
        if rate != self.rate_hz {
            self.next_due_us = now_us;
        }
        self.rate_hz = rate;
        self.lease_until_us = now_us + u64::from(LEASE_S) * 1_000_000;
    }

    /// Stop (USB disconnect, reset).
    pub fn stop(&mut self) {
        self.rate_hz = 0;
    }

    fn period_us(&self) -> u64 {
        1_000_000 / u64::from(self.rate_hz.max(1))
    }

    /// Is a frame due now? Expires the lease. If several periods were
    /// missed, they are counted as skipped (the frame sent now carries the
    /// newest values, never a backlog).
    pub fn due(&mut self, now_us: u64) -> bool {
        if self.rate_hz == 0 {
            return false;
        }
        if now_us >= self.lease_until_us {
            self.rate_hz = 0;
            return false;
        }
        if now_us < self.next_due_us {
            return false;
        }
        let p = self.period_us();
        let late = (now_us - self.next_due_us) / p;
        if late > 0 {
            self.skipped = self.skipped.wrapping_add(late.min(0x3FFF) as u16) & 0x3FFF;
        }
        self.next_due_us += (late + 1) * p;
        true
    }

    /// Take the sequence number for a frame being sent.
    pub fn next_seq(&mut self) -> u16 {
        let s = self.seq;
        self.seq = (self.seq + 1) & 0x3FFF;
        s
    }
}
