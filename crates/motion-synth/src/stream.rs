// SPDX-License-Identifier: GPL-3.0-only
//! Framed PCM test stream (device → host over a USB CDC ACM port).
//!
//! This is a diagnostics transport, **not** a USB Audio Class device: the
//! host must run `tools/pcm_capture.py` (or equivalent) to read it.
//!
//! Frame, all little endian:
//!
//! | off | size | field |
//! |-----|------|-------|
//! | 0 | 4 | magic `b"TRPC"` |
//! | 4 | 1 | version (1) |
//! | 5 | 1 | flags: bit0 = frames dropped before this one |
//! | 6 | 2 | sample count N |
//! | 8 | 4 | sequence number (block counter, wraps) |
//! | 12 | 4 | sample rate (Hz) |
//! | 16 | 2N | N × i16 mono samples |
//! | 16+2N | 2 | CRC-16/CCITT-FALSE over bytes 0..16+2N |

/// Frame magic.
pub const MAGIC: [u8; 4] = *b"TRPC";
/// Format version.
pub const VERSION: u8 = 1;
/// Header length.
pub const HEADER_LEN: usize = 16;
/// Flag: the producer dropped at least one frame before this one.
pub const FLAG_DROPPED: u8 = 1;

/// Encoded length for `n` samples.
pub const fn frame_len(n: usize) -> usize {
    HEADER_LEN + 2 * n + 2
}

/// CRC-16/CCITT-FALSE (poly 0x1021, init 0xFFFF, no reflection).
pub fn crc16(data: &[u8]) -> u16 {
    let mut crc: u16 = 0xFFFF;
    for &b in data {
        crc ^= (b as u16) << 8;
        for _ in 0..8 {
            crc = if crc & 0x8000 != 0 {
                (crc << 1) ^ 0x1021
            } else {
                crc << 1
            };
        }
    }
    crc
}

/// Encode a frame into `out`; returns bytes written, or `None` if `out` is
/// too small or `samples` exceeds `u16::MAX`.
pub fn encode(
    out: &mut [u8],
    seq: u32,
    sample_rate: u32,
    flags: u8,
    samples: &[i16],
) -> Option<usize> {
    let n = samples.len();
    let len = frame_len(n);
    if n > u16::MAX as usize || out.len() < len {
        return None;
    }
    out[0..4].copy_from_slice(&MAGIC);
    out[4] = VERSION;
    out[5] = flags;
    out[6..8].copy_from_slice(&(n as u16).to_le_bytes());
    out[8..12].copy_from_slice(&seq.to_le_bytes());
    out[12..16].copy_from_slice(&sample_rate.to_le_bytes());
    for (i, s) in samples.iter().enumerate() {
        out[HEADER_LEN + 2 * i..HEADER_LEN + 2 * i + 2].copy_from_slice(&s.to_le_bytes());
    }
    let crc = crc16(&out[..len - 2]);
    out[len - 2..len].copy_from_slice(&crc.to_le_bytes());
    Some(len)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn crc_check_value() {
        // Standard check value for CRC-16/CCITT-FALSE.
        assert_eq!(crc16(b"123456789"), 0x29B1);
    }

    #[test]
    fn golden_frame() {
        let mut buf = [0u8; 64];
        let n = encode(&mut buf, 0x0102_0304, 32_000, FLAG_DROPPED, &[1, -1]).unwrap();
        assert_eq!(n, 22);
        assert_eq!(
            &buf[..20],
            &[b'T', b'R', b'P', b'C', 1, 1, 2, 0, 4, 3, 2, 1, 0x00, 0x7D, 0, 0, 1, 0, 0xFF, 0xFF]
        );
        let crc = crc16(&buf[..20]);
        assert_eq!(&buf[20..22], &crc.to_le_bytes());
        // Vector shared with tools/test_pcm_capture.py.
        assert_eq!(crc, 0x5E73, "crc 0x{crc:04X}");
    }

    #[test]
    fn rejects_small_buffer() {
        let mut buf = [0u8; 10];
        assert!(encode(&mut buf, 0, 16_000, 0, &[0; 4]).is_none());
    }
}
