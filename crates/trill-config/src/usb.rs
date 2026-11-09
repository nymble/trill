// SPDX-License-Identifier: GPL-3.0-only
//! SysEx over USB-MIDI 1.0 event packets (USB Device Class Definition for
//! MIDI Devices 1.0, §4).
//!
//! Packet = `cable << 4 | CIN`, then three MIDI bytes. SysEx uses CIN `0x4`
//! (start/continue, 3 bytes) and CIN `0x5`/`0x6`/`0x7` (ends with 1/2/3
//! bytes). Real-time messages (`F8..FF`, CIN `0xF`) may arrive between the
//! packets of a SysEx message and do not interrupt it; any other status
//! byte aborts an unfinished SysEx, as in MIDI 1.0.

use crate::MAX_MESSAGE_LEN;

/// Number of MIDI bytes carried by a packet with this Code Index Number.
pub fn cin_len(cin: u8) -> usize {
    match cin & 0x0F {
        0x5 | 0xF => 1,
        0x2 | 0x6 | 0xC | 0xD => 2,
        0x3 | 0x4 | 0x7 | 0x8 | 0x9 | 0xA | 0xB | 0xE => 3,
        // 0x0 / 0x1: reserved for future extensions; ignored.
        _ => 0,
    }
}

/// A complete SysEx message from [`Assembler::push_packet`] or
/// [`Assembler::push_byte`].
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Complete {
    /// Bytes stored in [`Assembler::message`] (`F0 .. F7`, or a prefix if truncated).
    pub len: usize,
    /// The message was longer than [`MAX_MESSAGE_LEN`]; only a prefix was kept.
    pub truncated: bool,
}

/// Bounded SysEx reassembler for one USB-MIDI cable.
#[derive(Clone, Debug)]
pub struct Assembler {
    cable: u8,
    buf: [u8; MAX_MESSAGE_LEN],
    len: usize,
    active: bool,
    truncated: bool,
    /// Messages abandoned because another status byte arrived.
    pub aborted: u32,
}

impl Assembler {
    /// Reassemble SysEx addressed to `cable` (other cables are ignored).
    pub const fn new(cable: u8) -> Self {
        Self {
            cable: cable & 0x0F,
            buf: [0; MAX_MESSAGE_LEN],
            len: 0,
            active: false,
            truncated: false,
            aborted: 0,
        }
    }

    /// The bytes of the last [`Complete`] message.
    pub fn message(&self, c: Complete) -> &[u8] {
        &self.buf[..c.len.min(MAX_MESSAGE_LEN)]
    }

    /// Feed one USB-MIDI event packet. Returns a message when its final
    /// packet arrives. Only the first complete message in a packet is
    /// reported; a packet can carry at most one `F7`.
    pub fn push_packet(&mut self, p: [u8; 4]) -> Option<Complete> {
        if p[0] >> 4 != self.cable {
            return None;
        }
        let n = cin_len(p[0]);
        let mut done = None;
        for &b in &p[1..1 + n] {
            if let Some(c) = self.push_byte(b) {
                done.get_or_insert(c);
            }
        }
        done
    }

    /// Feed one MIDI byte (byte-stream form).
    pub fn push_byte(&mut self, b: u8) -> Option<Complete> {
        match b {
            0xF8..=0xFF => None, // real-time: transparent
            0xF0 => {
                if self.active {
                    self.aborted = self.aborted.wrapping_add(1);
                }
                self.active = true;
                self.truncated = false;
                self.buf[0] = 0xF0;
                self.len = 1;
                None
            }
            0xF7 => {
                if !self.active {
                    return None;
                }
                self.active = false;
                if self.len < MAX_MESSAGE_LEN {
                    self.buf[self.len] = 0xF7;
                    self.len += 1;
                } else {
                    self.truncated = true;
                }
                Some(Complete {
                    len: self.len,
                    truncated: self.truncated,
                })
            }
            0x80..=0xF6 => {
                if self.active {
                    self.active = false;
                    self.aborted = self.aborted.wrapping_add(1);
                }
                None
            }
            _ => {
                if self.active {
                    // Keep room for the closing F7.
                    if self.len < MAX_MESSAGE_LEN - 1 {
                        self.buf[self.len] = b;
                        self.len += 1;
                    } else {
                        self.truncated = true;
                    }
                }
                None
            }
        }
    }
}

/// Maximum packets for one message.
pub const MAX_PACKETS: usize = MAX_MESSAGE_LEN.div_ceil(3);

/// Encode a complete SysEx message (`F0 .. F7`) as USB-MIDI packets on
/// `cable`. Returns the number of packets written to `out`, or `None` if
/// `out` is too small or `msg` is empty.
pub fn encode_sysex(cable: u8, msg: &[u8], out: &mut [[u8; 4]]) -> Option<usize> {
    let n = msg.len().div_ceil(3);
    if msg.is_empty() || n > out.len() {
        return None;
    }
    let c = (cable & 0x0F) << 4;
    for (i, chunk) in msg.chunks(3).enumerate() {
        let last = i + 1 == n;
        let cin = match (last, chunk.len()) {
            (false, _) => 0x4,
            (true, 1) => 0x5,
            (true, 2) => 0x6,
            (true, _) => 0x7,
        };
        let mut p = [c | cin, 0, 0, 0];
        p[1..1 + chunk.len()].copy_from_slice(chunk);
        out[i] = p;
    }
    Some(n)
}
