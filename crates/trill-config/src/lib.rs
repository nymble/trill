// SPDX-License-Identifier: GPL-3.0-only
//! Trill configuration protocol, version 1 (see docs/config-protocol.md).
//!
//! A small request/reply protocol carried in MIDI 1.0 System Exclusive
//! messages, so it works through the class-compliant USB-MIDI driver on
//! macOS and iOS without any extra driver or serial-port access.
//!
//! ```text
//! F0 7D 54 52 <version> <type> <request id> <payload ...> F7
//! ```
//!
//! * `7D` is the MIDI "non-commercial / educational" manufacturer ID. It is a
//!   **development-only** identifier: it is not assigned to this project and
//!   must not ship in a commercial product, which needs its own MMA/AMEI ID.
//!   `54 52` ("TR") marks the message as ours so other `7D` traffic is
//!   ignored.
//! * Every message is at most [`MAX_MESSAGE_LEN`] bytes including `F0`/`F7`.
//! * Requests have types `0x01..=0x3F`; replies set bit 6 (`0x40`). The
//!   device never answers a reply-typed message, so a MIDI loop that echoes
//!   the device's own output back to it cannot cause a feedback storm.
//! * Settings live in RAM only ([`PERSISTENT`] is `false`): a power cycle or
//!   reset restores the firmware defaults.
//!
//! [`usb`] reassembles SysEx from USB-MIDI event packets (bounded, with
//! interleaved real-time messages) and encodes replies; [`handle`] validates
//! one request against the current [`instrument_events::Config`] and returns
//! the reply plus any change for the firmware to apply.
#![no_std]
#![forbid(unsafe_code)]
#![warn(missing_docs)]

pub mod param;
pub mod request;
pub mod usb;

use heapless::Vec;
use instrument_events::Config;
pub use param::Param;

/// MIDI manufacturer ID for non-commercial / educational use (development only).
pub const MANUFACTURER_ID: u8 = 0x7D;
/// Signature after the manufacturer ID ("TR").
pub const SIGNATURE: [u8; 2] = [0x54, 0x52];
/// Protocol version implemented here.
pub const PROTOCOL_VERSION: u8 = 1;
/// Largest message, `F0` and `F7` included.
pub const MAX_MESSAGE_LEN: usize = 64;
/// Header length: `F0`, ID, signature (2), version, type, request id.
pub const HEADER_LEN: usize = 7;
/// Maximum parameters in one `SET_CONFIG` request.
pub const MAX_SET_PARAMS: usize = 16;
/// Settings survive a reset or power cycle. Not implemented: RAM only.
pub const PERSISTENT: bool = false;

/// Message types.
pub mod msg {
    /// Handshake: payload = highest protocol version the host speaks.
    pub const HELLO: u8 = 0x01;
    /// Read all parameters.
    pub const GET_CONFIG: u8 = 0x02;
    /// Change parameters atomically: payload = `(id, value_hi, value_lo)*`.
    pub const SET_CONFIG: u8 = 0x03;
    /// Run an action: payload = action code.
    pub const ACTION: u8 = 0x04;
    /// Reply bit.
    pub const REPLY: u8 = 0x40;
    /// Reply to `HELLO`.
    pub const HELLO_REPLY: u8 = 0x41;
    /// Full parameter set (reply to `GET_CONFIG`, `SET_CONFIG`, restore defaults).
    pub const CONFIG: u8 = 0x42;
    /// Reply to `ACTION` (except restore defaults, which sends `CONFIG`).
    pub const ACTION_ACK: u8 = 0x44;
    /// Error reply: payload = error code, detail.
    pub const ERROR: u8 = 0x7F;
}

/// Error codes carried by [`msg::ERROR`].
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum ErrorCode {
    /// Unsupported protocol version (detail = supported version).
    BadVersion = 1,
    /// Unknown request type (detail = the type).
    UnknownType = 2,
    /// Payload has the wrong length for its type (detail = payload length, max 127).
    BadLength = 3,
    /// Unknown parameter ID (detail = the ID). Nothing was changed.
    UnknownParam = 4,
    /// Value out of range (detail = parameter ID). Nothing was changed.
    OutOfRange = 5,
    /// Message longer than [`MAX_MESSAGE_LEN`] (detail = 0).
    TooLong = 6,
    /// Unknown action code (detail = the code).
    UnknownAction = 7,
    /// The same parameter appears twice (detail = parameter ID). Nothing was changed.
    DuplicateParam = 8,
}

/// Actions (`msg::ACTION` payload).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum Action {
    /// MIDI panic: release notes, All Sound Off, All Notes Off, bend centre.
    Panic = 1,
    /// Re-measure the gyro bias (board must be still for about 1 s).
    RecalibrateGyro = 2,
    /// Status LED self-test (R G B Y C M W off).
    LedSelfTest = 3,
    /// Restore the firmware default mapping (RAM only). Replies with `CONFIG`.
    RestoreDefaults = 4,
}

impl Action {
    /// From the wire code.
    pub fn from_code(c: u8) -> Option<Self> {
        Some(match c {
            1 => Self::Panic,
            2 => Self::RecalibrateGyro,
            3 => Self::LedSelfTest,
            4 => Self::RestoreDefaults,
            _ => return None,
        })
    }
}

/// Variant flag: firmware built with the `pcm-synth` debug feature.
pub const VARIANT_PCM_SYNTH: u8 = 0x01;
/// Capability bit: `SET_CONFIG` supported.
pub const CAP_SET_CONFIG: u8 = 0x01;
/// Capability bit: `ACTION` supported.
pub const CAP_ACTIONS: u8 = 0x02;
/// Capability bit: settings persist across reset (never set by this firmware).
pub const CAP_PERSISTENT: u8 = 0x04;

/// Facts reported by `HELLO_REPLY`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct DeviceInfo {
    /// Firmware version (major, minor, patch), each `0..=127`.
    pub firmware: [u8; 3],
    /// `VARIANT_*` bits.
    pub variant: u8,
    /// Seconds since boot (sent as 21 bits, saturating).
    pub uptime_s: u32,
    /// Random 14-bit value chosen at boot; changes when the device restarts.
    pub boot_id: u16,
}

/// Reply buffer.
pub type Reply = Vec<u8, MAX_MESSAGE_LEN>;

/// What the firmware must do after a request.
#[derive(Clone, Debug, PartialEq)]
pub struct Outcome {
    /// Reply to send to the host (always a complete SysEx message).
    pub reply: Reply,
    /// New configuration to apply (already validated), if any.
    pub config: Option<Config>,
    /// New configuration generation (only meaningful with `config`).
    pub generation: u16,
    /// Side effect to perform, if any.
    pub action: Option<Action>,
}

/// Generations are 14-bit and wrap.
pub fn next_generation(g: u16) -> u16 {
    g.wrapping_add(1) & 0x3FFF
}

fn header(ty: u8, req: u8) -> Reply {
    let mut r = Reply::new();
    // Infallible: HEADER_LEN - 1 < MAX_MESSAGE_LEN.
    let _ = r.extend_from_slice(&[
        0xF0,
        MANUFACTURER_ID,
        SIGNATURE[0],
        SIGNATURE[1],
        PROTOCOL_VERSION,
        ty,
        req & 0x7F,
    ]);
    r
}

fn finish(mut r: Reply) -> Reply {
    let _ = r.push(0xF7);
    r
}

/// Encode an `ERROR` reply.
pub fn error_reply(req: u8, code: ErrorCode, detail: u8) -> Reply {
    let mut r = header(msg::ERROR, req);
    let _ = r.extend_from_slice(&[code as u8, detail & 0x7F]);
    finish(r)
}

/// Encode a `CONFIG` reply with every parameter of `cfg`.
pub fn config_reply(req: u8, cfg: &Config, generation: u16) -> Reply {
    let mut r = header(msg::CONFIG, req);
    let _ = r.extend_from_slice(&[
        ((generation >> 7) & 0x7F) as u8,
        (generation & 0x7F) as u8,
        u8::from(PERSISTENT),
    ]);
    for p in Param::ALL {
        let v = p.get(cfg);
        let _ = r.extend_from_slice(&[p.id(), (v >> 7) as u8 & 0x7F, v as u8 & 0x7F]);
    }
    finish(r)
}

/// Encode a `HELLO_REPLY`.
pub fn hello_reply(req: u8, info: &DeviceInfo) -> Reply {
    let mut r = header(msg::HELLO_REPLY, req);
    let up = info.uptime_s.min(0x1F_FFFF);
    let caps = CAP_SET_CONFIG | CAP_ACTIONS | if PERSISTENT { CAP_PERSISTENT } else { 0 };
    let _ = r.extend_from_slice(&[
        PROTOCOL_VERSION,
        info.firmware[0] & 0x7F,
        info.firmware[1] & 0x7F,
        info.firmware[2] & 0x7F,
        info.variant & 0x7F,
        caps,
        MAX_MESSAGE_LEN as u8,
        Param::ALL.len() as u8,
        (up >> 14) as u8 & 0x7F,
        (up >> 7) as u8 & 0x7F,
        up as u8 & 0x7F,
        ((info.boot_id >> 7) & 0x7F) as u8,
        (info.boot_id & 0x7F) as u8,
    ]);
    finish(r)
}

fn plain(reply: Reply) -> Outcome {
    Outcome {
        reply,
        config: None,
        generation: 0,
        action: None,
    }
}

/// Handle one complete SysEx message (`F0 .. F7`) from the host.
///
/// `truncated` means the reassembler dropped bytes beyond
/// [`MAX_MESSAGE_LEN`]; `msg` then holds the first bytes only.
///
/// Returns `None` for anything that is not a request for this protocol
/// (other manufacturers, other `7D` users, replies, too-short frames): the
/// device stays silent so it never talks back to traffic it does not own.
pub fn handle(
    msg: &[u8],
    truncated: bool,
    cfg: &Config,
    generation: u16,
    info: &DeviceInfo,
) -> Option<Outcome> {
    // Identify first: F0 7D 54 52 ver type req ... F7.
    if msg.len() < HEADER_LEN
        || msg[0] != 0xF0
        || msg[1] != MANUFACTURER_ID
        || msg[2..4] != SIGNATURE
    {
        return None;
    }
    if msg[4..HEADER_LEN].iter().any(|&b| b > 0x7F) {
        return None;
    }
    let (ver, ty, req) = (msg[4], msg[5], msg[6]);
    if ty & msg::REPLY != 0 || ty == 0 {
        // Replies (including our own, echoed by a loop) and invalid types.
        return None;
    }
    if truncated {
        return Some(plain(error_reply(req, ErrorCode::TooLong, 0)));
    }
    if msg.len() < HEADER_LEN + 1 || msg[msg.len() - 1] != 0xF7 {
        return None;
    }
    let payload = &msg[HEADER_LEN..msg.len() - 1];
    if payload.iter().any(|&b| b > 0x7F) {
        return None;
    }
    if ver != PROTOCOL_VERSION {
        return Some(plain(error_reply(
            req,
            ErrorCode::BadVersion,
            PROTOCOL_VERSION,
        )));
    }
    let bad_len = || {
        Some(plain(error_reply(
            req,
            ErrorCode::BadLength,
            payload.len().min(127) as u8,
        )))
    };
    match ty {
        msg::HELLO => {
            if payload.len() != 1 {
                return bad_len();
            }
            // The host's highest version is informational: version 1 is
            // the only one, and a mismatching header was rejected above.
            Some(plain(hello_reply(req, info)))
        }
        msg::GET_CONFIG => {
            if !payload.is_empty() {
                return bad_len();
            }
            Some(plain(config_reply(req, cfg, generation)))
        }
        msg::SET_CONFIG => {
            if payload.is_empty() || payload.len() % 3 != 0 || payload.len() / 3 > MAX_SET_PARAMS {
                return bad_len();
            }
            let mut new = *cfg;
            let mut seen: u32 = 0;
            for t in payload.chunks_exact(3) {
                let Some(p) = Param::from_id(t[0]) else {
                    return Some(plain(error_reply(req, ErrorCode::UnknownParam, t[0])));
                };
                let bit = 1u32 << p.id();
                if seen & bit != 0 {
                    return Some(plain(error_reply(req, ErrorCode::DuplicateParam, p.id())));
                }
                seen |= bit;
                let v = (u16::from(t[1]) << 7) | u16::from(t[2]);
                if p.set(&mut new, v).is_err() {
                    return Some(plain(error_reply(req, ErrorCode::OutOfRange, p.id())));
                }
            }
            let changed = new != *cfg;
            let generation = if changed {
                next_generation(generation)
            } else {
                generation
            };
            Some(Outcome {
                reply: config_reply(req, &new, generation),
                config: changed.then_some(new),
                generation,
                action: None,
            })
        }
        msg::ACTION => {
            if payload.len() != 1 {
                return bad_len();
            }
            let Some(a) = Action::from_code(payload[0]) else {
                return Some(plain(error_reply(
                    req,
                    ErrorCode::UnknownAction,
                    payload[0],
                )));
            };
            if a == Action::RestoreDefaults {
                let new = Config::default();
                let changed = new != *cfg;
                let generation = if changed {
                    next_generation(generation)
                } else {
                    generation
                };
                return Some(Outcome {
                    reply: config_reply(req, &new, generation),
                    config: changed.then_some(new),
                    generation,
                    action: Some(a),
                });
            }
            let mut r = header(msg::ACTION_ACK, req);
            let _ = r.push(a as u8);
            Some(Outcome {
                reply: finish(r),
                config: None,
                generation: 0,
                action: Some(a),
            })
        }
        other => Some(plain(error_reply(req, ErrorCode::UnknownType, other))),
    }
}
