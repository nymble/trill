// SPDX-License-Identifier: GPL-3.0-only
//! BLE-MIDI framing vectors.

use ble_midi::*;

fn collect(p: &[u8]) -> Vec<(u32, Vec<u8>)> {
    let mut v = Vec::new();
    decode(p, |d| v.push((d.timestamp, d.message().to_vec()))).unwrap();
    v
}

#[test]
fn uuids_match_the_specification() {
    let hex = |u: &[u8; 16]| u.iter().map(|b| format!("{b:02X}")).collect::<String>();
    assert_eq!(hex(&SERVICE_UUID), "03B80E5AEDE84B33A7516CE34EC4C700");
    assert_eq!(
        hex(&CHARACTERISTIC_UUID),
        "7772E5DB38684112A1A9F2669D106BF3"
    );
    assert_eq!(uuid_le(&SERVICE_UUID)[0], 0x00);
    assert_eq!(uuid_le(&SERVICE_UUID)[15], 0x03);
}

#[test]
fn single_note_on_vector() {
    // 0x1234 ms -> 13 bits 0x1234 & 0x1FFF = 0x1234: high 0x24, low 0x34.
    let mut p = Packet::new(0x1234, 20);
    p.push(&[0x90, 60, 100]).unwrap();
    assert_eq!(p.as_bytes(), &[0xA4, 0xB4, 0x90, 0x3C, 0x64]);
    assert_eq!(collect(p.as_bytes()), vec![(0x1234, vec![0x90, 60, 100])]);
}

#[test]
fn timestamp_wraps_at_13_bits() {
    let p = Packet::new(8192 + 5, 20);
    assert_eq!(p.timestamp(), 5);
    assert_eq!(p.as_bytes(), &[0x80]);
    let p = Packet::new(8191, 20);
    assert_eq!(header_byte(8191), 0xBF);
    assert_eq!(timestamp_byte(8191), 0xFF);
    assert_eq!(p.as_bytes(), &[0xBF]);
}

#[test]
fn several_messages_each_get_a_timestamp() {
    let mut p = Packet::new(0, 20);
    p.push(&[0xB0, 74, 64]).unwrap();
    p.push(&[0xD0, 10]).unwrap();
    p.push(&[0xE0, 0x00, 0x40]).unwrap();
    assert_eq!(
        p.as_bytes(),
        &[0x80, 0x80, 0xB0, 74, 64, 0x80, 0xD0, 10, 0x80, 0xE0, 0x00, 0x40]
    );
    assert_eq!(p.messages(), 3);
    assert_eq!(collect(p.as_bytes()).len(), 3);
}

#[test]
fn respects_the_mtu_limit() {
    let mut p = Packet::new(0, 20); // 1 header + 4 x (1 + 3) = 17, a fifth needs 21
    for _ in 0..4 {
        p.push(&[0x80, 60, 0]).unwrap();
    }
    assert!(!p.fits(3));
    assert!(p.fits(2));
    assert_eq!(p.push(&[0x80, 60, 0]), Err(PushError::Full));
    p.push(&[0xD0, 1]).unwrap();
    assert_eq!(p.as_bytes().len(), 20);
    // Limits are clamped to the minimum and maximum notification sizes.
    assert!(Packet::new(0, 3).fits(3));
    let mut big = Packet::new(0, 10_000);
    let mut n = 0;
    while big.push(&[0x90, 1, 1]).is_ok() {
        n += 1;
    }
    assert_eq!(n, (MAX_PACKET_LEN - 1) / 4);
}

#[test]
fn rejects_unsupported_messages() {
    let mut p = Packet::new(0, 20);
    assert_eq!(p.push(&[]), Err(PushError::Invalid));
    assert_eq!(p.push(&[0xF0, 1, 2]), Err(PushError::Invalid)); // SysEx
    assert_eq!(p.push(&[0xF8]), Err(PushError::Invalid)); // real-time
    assert_eq!(p.push(&[0x90, 60]), Err(PushError::Invalid)); // short
    assert_eq!(p.push(&[0x90, 60, 0x80]), Err(PushError::Invalid)); // data bit 7
    assert_eq!(p.push(&[0x3C, 60, 1]), Err(PushError::Invalid)); // data byte first
    assert!(p.is_empty());
}

#[test]
fn decodes_running_status_and_low_byte_wrap() {
    // Header high = 1; first message at low 0x7E, running-status note on
    // without a timestamp, then low 0x02 wraps into high 2.
    let pkt = [0x81, 0xFE, 0x90, 60, 100, 62, 90, 0x82, 0x80, 60, 0];
    let v = collect(&pkt);
    assert_eq!(
        v,
        vec![
            ((1 << 7) | 0x7E, vec![0x90, 60, 100]),
            ((1 << 7) | 0x7E, vec![0x90, 62, 90]),
            ((2 << 7) | 0x02, vec![0x80, 60, 0]),
        ]
    );
}

#[test]
fn decode_errors() {
    assert_eq!(decode(&[], |_| ()), Err(DecodeError::BadHeader));
    assert_eq!(decode(&[0x40], |_| ()), Err(DecodeError::BadHeader));
    assert_eq!(
        decode(&[0x80, 0x80, 0x90, 60], |_| ()),
        Err(DecodeError::Malformed(4))
    );
    assert!(matches!(
        decode(&[0x80, 0x80, 0xF0, 1, 0xF7], |_| ()),
        Err(DecodeError::Unsupported(_))
    ));
}

#[test]
fn every_instrument_message_round_trips() {
    for status in [0x80u8, 0x9F, 0xB3, 0xD0, 0xE7] {
        let n = message_len(status).unwrap();
        let msg: Vec<u8> = [status, 0x12, 0x7F][..n].to_vec();
        for now in [0u32, 1, 127, 128, 4095, 8191, 8192, u32::MAX] {
            let mut p = Packet::new(now, 20);
            p.push(&msg).unwrap();
            assert_eq!(collect(p.as_bytes()), vec![(now % 8192, msg.clone())]);
        }
    }
}
