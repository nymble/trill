// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 M-of-N (https://m-of-n.com)

//! MIDI over Bluetooth Low Energy (BLE-MIDI 1.0, the Apple / MMA
//! specification) packet framing. `no_std`, no allocation.
//!
//! A packet is one GATT notification or write on the MIDI I/O
//! characteristic:
//!
//! ```text
//! header     1 0 t12 t11 t10 t9 t8 t7      (timestamp bits 12..7)
//! timestamp  1 t6 t5 t4 t3 t2 t1 t0        (timestamp bits 6..0)
//! message    status [data [data]]
//! timestamp  ...                           (before every further message)
//! message    ...
//! ```
//!
//! The timestamp is a 13-bit millisecond counter that wraps every
//! 8.192 s. This encoder always writes a timestamp byte and a full
//! status byte before each message (no running status), which every
//! receiver must accept, and uses one timestamp per packet so the header
//! is always correct. System exclusive and real-time messages are not
//! produced by the instrument and are rejected by [`Packet::push`].

#![no_std]
#![forbid(unsafe_code)]

/// BLE-MIDI service UUID `03B80E5A-EDE8-4B33-A751-6CE34EC4C700`, most
/// significant byte first (as written).
pub const SERVICE_UUID: [u8; 16] = [
    0x03, 0xB8, 0x0E, 0x5A, 0xED, 0xE8, 0x4B, 0x33, 0xA7, 0x51, 0x6C, 0xE3, 0x4E, 0xC4, 0xC7, 0x00,
];
/// MIDI I/O characteristic UUID `7772E5DB-3868-4112-A1A9-F2669D106BF3`,
/// most significant byte first.
pub const CHARACTERISTIC_UUID: [u8; 16] = [
    0x77, 0x72, 0xE5, 0xDB, 0x38, 0x68, 0x41, 0x12, 0xA1, 0xA9, 0xF2, 0x66, 0x9D, 0x10, 0x6B, 0xF3,
];

/// A UUID in the little-endian byte order used on air (and by the
/// SoftDevice and advertising data).
pub const fn uuid_le(uuid: &[u8; 16]) -> [u8; 16] {
    let mut out = [0u8; 16];
    let mut i = 0;
    while i < 16 {
        out[i] = uuid[15 - i];
        i += 1;
    }
    out
}

/// Timestamp period: the 13-bit millisecond counter wraps at this value.
pub const TIMESTAMP_MODULO: u32 = 1 << 13;
/// Smallest packet: the payload of a notification at the default ATT MTU
/// of 23 (MTU − 3).
pub const MIN_PACKET_LEN: usize = 20;
/// Largest packet this encoder builds (Apple hosts negotiate MTUs up to
/// 185; 128 bytes keeps buffers small and is far above one instrument tick).
pub const MAX_PACKET_LEN: usize = 128;

/// Length in bytes of a MIDI 1.0 message that starts with `status`, for
/// the messages a packet may carry (channel voice, and system common
/// other than SysEx). `None` for a data byte, SysEx (`F0`/`F7`),
/// undefined or real-time status bytes.
pub const fn message_len(status: u8) -> Option<usize> {
    match status {
        0x80..=0xBF | 0xE0..=0xEF => Some(3),
        0xC0..=0xDF => Some(2),
        0xF1 | 0xF3 => Some(2),
        0xF2 => Some(3),
        0xF6 => Some(1),
        _ => None,
    }
}

/// Header byte for a 13-bit millisecond timestamp.
pub const fn header_byte(timestamp_ms: u32) -> u8 {
    0x80 | ((timestamp_ms >> 7) & 0x3F) as u8
}

/// Timestamp byte (before each message) for a 13-bit millisecond timestamp.
pub const fn timestamp_byte(timestamp_ms: u32) -> u8 {
    0x80 | (timestamp_ms & 0x7F) as u8
}

/// Why a message could not be added to a packet.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PushError {
    /// Not a supported message (see [`message_len`]), or a data byte has
    /// bit 7 set, or the slice length does not match the status.
    Invalid,
    /// The packet has no room left; send it and start a new one.
    Full,
}

/// One BLE-MIDI packet being built.
#[derive(Clone, Debug)]
pub struct Packet {
    buf: [u8; MAX_PACKET_LEN],
    len: usize,
    limit: usize,
    timestamp: u32,
    messages: usize,
}

impl Packet {
    /// Start a packet stamped `now_ms` (any millisecond counter; only the
    /// low 13 bits are used) that will be at most `max_len` bytes. `max_len`
    /// is the notification payload (ATT MTU − 3), clamped to
    /// [`MIN_PACKET_LEN`]..=[`MAX_PACKET_LEN`].
    pub fn new(now_ms: u32, max_len: usize) -> Self {
        let timestamp = now_ms % TIMESTAMP_MODULO;
        let mut buf = [0u8; MAX_PACKET_LEN];
        buf[0] = header_byte(timestamp);
        Self {
            buf,
            len: 1,
            limit: max_len.clamp(MIN_PACKET_LEN, MAX_PACKET_LEN),
            timestamp,
            messages: 0,
        }
    }

    /// Append one complete MIDI message (status byte first).
    pub fn push(&mut self, msg: &[u8]) -> Result<(), PushError> {
        let Some(&status) = msg.first() else {
            return Err(PushError::Invalid);
        };
        if message_len(status) != Some(msg.len()) || msg[1..].iter().any(|b| b & 0x80 != 0) {
            return Err(PushError::Invalid);
        }
        if self.len + 1 + msg.len() > self.limit {
            return Err(PushError::Full);
        }
        self.buf[self.len] = timestamp_byte(self.timestamp);
        self.buf[self.len + 1..self.len + 1 + msg.len()].copy_from_slice(msg);
        self.len += 1 + msg.len();
        self.messages += 1;
        Ok(())
    }

    /// Room for another message of `len` bytes.
    pub fn fits(&self, len: usize) -> bool {
        self.len + 1 + len <= self.limit
    }

    /// Number of messages in the packet.
    pub fn messages(&self) -> usize {
        self.messages
    }

    /// True when no message has been added (an empty packet is not sent).
    pub fn is_empty(&self) -> bool {
        self.messages == 0
    }

    /// The 13-bit timestamp of every message in this packet.
    pub fn timestamp(&self) -> u32 {
        self.timestamp
    }

    /// The bytes to send.
    pub fn as_bytes(&self) -> &[u8] {
        &self.buf[..self.len]
    }
}

/// One message decoded from a packet.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Decoded {
    /// 13-bit millisecond timestamp.
    pub timestamp: u32,
    /// Message bytes; `len` of them are valid.
    pub bytes: [u8; 3],
    /// Number of valid bytes in `bytes`.
    pub len: usize,
}

impl Decoded {
    /// The message bytes.
    pub fn message(&self) -> &[u8] {
        &self.bytes[..self.len]
    }
}

/// Why a packet could not be decoded.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DecodeError {
    /// Empty packet, or the header byte is not `10xxxxxx`.
    BadHeader,
    /// A message is cut short or a byte is out of place at this offset.
    Malformed(usize),
    /// SysEx, real-time or undefined status at this offset (not handled
    /// by this small decoder).
    Unsupported(usize),
}

/// Decode the channel-voice and system-common messages in one packet,
/// including running status and timestamp low-byte wrap within the
/// packet, calling `f` for each. Used by tests and as a reference for
/// host-side parsing.
pub fn decode(packet: &[u8], mut f: impl FnMut(Decoded)) -> Result<(), DecodeError> {
    let (&header, rest) = packet.split_first().ok_or(DecodeError::BadHeader)?;
    if header & 0xC0 != 0x80 {
        return Err(DecodeError::BadHeader);
    }
    let mut high = (header & 0x3F) as u32;
    let mut last_low: Option<u32> = None;
    let mut running: Option<u8> = None;
    let mut i = 0;
    while i < rest.len() {
        let at = i + 1;
        // A message starts with a timestamp byte, except running-status
        // data that directly follows a complete message.
        let mut timestamp = None;
        if rest[i] & 0x80 != 0 {
            let low = (rest[i] & 0x7F) as u32;
            if let Some(prev) = last_low {
                if low < prev {
                    high = (high + 1) & 0x3F;
                }
            }
            last_low = Some(low);
            timestamp = Some((high << 7) | low);
            i += 1;
        } else if last_low.is_none() {
            return Err(DecodeError::Malformed(at));
        }
        let ts = timestamp.unwrap_or(((high << 7) | last_low.unwrap_or(0)) % TIMESTAMP_MODULO);
        let status = match rest.get(i) {
            Some(&b) if b & 0x80 != 0 => {
                i += 1;
                b
            }
            Some(_) => running.ok_or(DecodeError::Malformed(i + 1))?,
            None => return Err(DecodeError::Malformed(i + 1)),
        };
        let Some(n) = message_len(status) else {
            return Err(DecodeError::Unsupported(i));
        };
        let mut bytes = [status, 0, 0];
        for slot in bytes.iter_mut().take(n).skip(1) {
            match rest.get(i) {
                Some(&b) if b & 0x80 == 0 => *slot = b,
                _ => return Err(DecodeError::Malformed(i + 1)),
            }
            i += 1;
        }
        running = (status < 0xF0).then_some(status);
        f(Decoded {
            timestamp: ts,
            bytes,
            len: n,
        });
    }
    Ok(())
}
