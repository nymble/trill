// SPDX-License-Identifier: GPL-3.0-only
//! Host-side request encoders (used by tests, tools and as the reference
//! for other implementations such as the Swift app's `TrillKit`).

use crate::{
    msg, Action, Param, Reply, MANUFACTURER_ID, MAX_SET_PARAMS, PROTOCOL_VERSION, SIGNATURE,
};

fn start(ty: u8, req: u8) -> Reply {
    let mut r = Reply::new();
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

fn end(mut r: Reply) -> Reply {
    let _ = r.push(0xF7);
    r
}

/// `HELLO`.
pub fn hello(req: u8) -> Reply {
    let mut r = start(msg::HELLO, req);
    let _ = r.push(PROTOCOL_VERSION);
    end(r)
}

/// `GET_CONFIG`.
pub fn get_config(req: u8) -> Reply {
    end(start(msg::GET_CONFIG, req))
}

/// `SET_CONFIG` with up to [`MAX_SET_PARAMS`] `(param, value)` pairs.
/// Returns `None` if there are too many pairs. Values are not range checked
/// here (the device does that), only masked to 14 bits.
pub fn set_config(req: u8, values: &[(Param, u16)]) -> Option<Reply> {
    if values.is_empty() || values.len() > MAX_SET_PARAMS {
        return None;
    }
    let mut r = start(msg::SET_CONFIG, req);
    for &(p, v) in values {
        let _ = r.extend_from_slice(&[p.id(), (v >> 7) as u8 & 0x7F, v as u8 & 0x7F]);
    }
    Some(end(r))
}

/// `ACTION`.
pub fn action(req: u8, a: Action) -> Reply {
    let mut r = start(msg::ACTION, req);
    let _ = r.push(a as u8);
    end(r)
}
