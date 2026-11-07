// SPDX-License-Identifier: GPL-3.0-only
use instrument_events::{Config, PitchMode};
use trill_config::usb::{cin_len, encode_sysex, Assembler, MAX_PACKETS};
use trill_config::*;

const INFO: DeviceInfo = DeviceInfo {
    firmware: [0, 2, 0],
    variant: VARIANT_PCM_SYNTH,
    uptime_s: 5,
    boot_id: 7,
};

fn packets(cable: u8, msg: &[u8]) -> Vec<[u8; 4]> {
    let mut out = [[0u8; 4]; MAX_PACKETS];
    let n = encode_sysex(cable, msg, &mut out).unwrap();
    out[..n].to_vec()
}

fn assemble(asm: &mut Assembler, ps: &[[u8; 4]]) -> Vec<(Vec<u8>, bool)> {
    let mut v = Vec::new();
    for &p in ps {
        if let Some(c) = asm.push_packet(p) {
            v.push((asm.message(c).to_vec(), c.truncated));
        }
    }
    v
}

#[test]
fn encode_uses_correct_code_index_numbers() {
    // 8 bytes: 4, 4, 6.
    let p = packets(1, &request::get_config(2));
    assert_eq!(p.len(), 3);
    assert_eq!(p[0], [0x14, 0xF0, 0x7D, 0x54]);
    assert_eq!(p[1], [0x14, 0x52, 0x01, 0x02]);
    assert_eq!(p[2], [0x16, 0x02, 0xF7, 0x00]);
    // 9 bytes: last packet CIN 7; 10 bytes: CIN 5.
    assert_eq!(packets(0, &[0xF0, 1, 2, 3, 4, 5, 6, 7, 0xF7])[2][0], 0x07);
    assert_eq!(
        packets(0, &[0xF0, 1, 2, 3, 4, 5, 6, 7, 8, 0xF7])[3],
        [0x05, 0xF7, 0, 0]
    );
    assert_eq!(encode_sysex(0, &[], &mut [[0; 4]; 1]), None);
    assert_eq!(encode_sysex(0, &[0xF0; 7], &mut [[0; 4]; 2]), None);
    assert_eq!(cin_len(0x0), 0);
    assert_eq!(cin_len(0xF), 1);
}

#[test]
fn roundtrip_through_packets() {
    for len in 2..=MAX_MESSAGE_LEN {
        let mut m = vec![0xF0];
        m.extend((0..len - 2).map(|i| (i % 128) as u8));
        m.push(0xF7);
        let mut a = Assembler::new(1);
        assert_eq!(
            assemble(&mut a, &packets(1, &m)),
            vec![(m.clone(), false)],
            "len {len}"
        );
    }
}

#[test]
fn realtime_is_transparent_inside_sysex() {
    let msg = request::hello(4);
    let mut ps = packets(1, &msg);
    ps.insert(1, [0x1F, 0xF8, 0, 0]); // clock on the same cable
    ps.insert(2, [0x0F, 0xFE, 0, 0]); // active sensing on cable 0
    let mut a = Assembler::new(1);
    assert_eq!(assemble(&mut a, &ps), vec![(msg.to_vec(), false)]);
}

#[test]
fn status_byte_aborts_and_other_cables_are_ignored() {
    let msg = request::hello(4);
    let ps = packets(1, &msg);
    let mut a = Assembler::new(1);
    // Note on (cable 1) in the middle aborts the message.
    let mut broken = ps.clone();
    broken.insert(1, [0x19, 0x90, 60, 100]);
    assert!(assemble(&mut a, &broken).is_empty());
    assert_eq!(a.aborted, 1);
    // A new F0 restarts cleanly afterwards.
    assert_eq!(assemble(&mut a, &ps).len(), 1);
    // The same message on cable 0 is not ours.
    assert!(assemble(&mut a, &packets(0, &msg)).is_empty());
    // F7 without F0 and stray data bytes are ignored.
    assert!(a.push_byte(0xF7).is_none());
    assert!(a.push_byte(0x10).is_none());
}

#[test]
fn overlong_message_is_truncated_not_overflowed() {
    let mut a = Assembler::new(0);
    a.push_byte(0xF0);
    for _ in 0..500 {
        assert!(a.push_byte(0x11).is_none());
    }
    let c = a.push_byte(0xF7).unwrap();
    assert!(c.truncated);
    assert!(c.len <= MAX_MESSAGE_LEN);
    // Exactly MAX_MESSAGE_LEN fits.
    a.push_byte(0xF0);
    for _ in 0..MAX_MESSAGE_LEN - 2 {
        a.push_byte(0x11);
    }
    let c = a.push_byte(0xF7).unwrap();
    assert!(!c.truncated);
    assert_eq!(c.len, MAX_MESSAGE_LEN);
}

#[test]
fn every_parameter_roundtrips_and_rejects_out_of_range() {
    for p in Param::ALL {
        assert_eq!(Param::from_id(p.id()), Some(p));
        let (lo, hi) = p.range();
        for v in [lo, (lo + hi) / 2, hi] {
            let mut c = Config::default();
            p.set(&mut c, v).unwrap();
            assert_eq!(p.get(&c), v, "{p:?}");
            // The engine keeps validated values unchanged.
            assert_eq!(c.sanitized(), c, "{p:?}={v} survives sanitize");
        }
        let mut c = Config::default();
        if lo > 0 {
            assert!(p.set(&mut c, lo - 1).is_err());
        }
        assert!(p.set(&mut c, hi + 1).is_err());
        assert!(p.set(&mut c, 0x3FFF).is_err());
        assert_eq!(c, Config::default());
        // Defaults are representable.
        let d = p.get(&Config::default());
        assert!(lo <= d && d <= hi);
    }
    assert_eq!(Param::from_id(0), None);
    assert_eq!(Param::from_id(14), None);
}

#[test]
fn set_is_atomic_and_bumps_generation_only_on_change() {
    let cfg = Config::default();
    let req = request::set_config(1, &[(Param::PitchMode, 1), (Param::BendRange, 25)]).unwrap();
    let o = handle(&req, false, &cfg, 9, &INFO).unwrap();
    assert_eq!(o.config, None);
    assert_eq!(o.reply[5], msg::ERROR);
    assert_eq!(
        &o.reply[7..9],
        &[ErrorCode::OutOfRange as u8, Param::BendRange.id()]
    );

    let req = request::set_config(2, &[(Param::PitchMode, 1)]).unwrap();
    let o = handle(&req, false, &cfg, 0x3FFF, &INFO).unwrap();
    let new = o.config.unwrap();
    assert_eq!(new.pitch_mode, PitchMode::Steps);
    assert_eq!(o.generation, 0, "14-bit wrap");
    // Same values again: acknowledged, no change, same generation.
    let o2 = handle(&req, false, &new, 0, &INFO).unwrap();
    assert_eq!(o2.config, None);
    assert_eq!(o2.reply[5], msg::CONFIG);
    assert_eq!(&o2.reply[7..9], &[0, 0]);
}

#[test]
fn hello_reports_version_variant_caps_and_not_persistent() {
    let o = handle(&request::hello(3), false, &Config::default(), 0, &INFO).unwrap();
    let r = &o.reply;
    assert_eq!(r[5], msg::HELLO_REPLY);
    assert_eq!(r[6], 3);
    assert_eq!(&r[7..11], &[PROTOCOL_VERSION, 0, 2, 0]);
    assert_eq!(r[11], VARIANT_PCM_SYNTH);
    assert_eq!(r[12], CAP_SET_CONFIG | CAP_ACTIONS);
    assert_eq!(r[12] & CAP_PERSISTENT, 0);
    assert_eq!(r[13] as usize, MAX_MESSAGE_LEN);
    assert_eq!(r[14] as usize, Param::ALL.len());
    assert_eq!(*r.last().unwrap(), 0xF7);
    // Uptime saturates at 21 bits.
    let big = DeviceInfo {
        uptime_s: u32::MAX,
        ..INFO
    };
    let o = handle(&request::hello(3), false, &Config::default(), 0, &big).unwrap();
    assert_eq!(&o.reply[15..18], &[0x7F, 0x7F, 0x7F]);
}

#[test]
fn actions_map_to_side_effects() {
    let cfg = Config::default();
    for (a, code) in [
        (Action::Panic, 1),
        (Action::RecalibrateGyro, 2),
        (Action::LedSelfTest, 3),
    ] {
        let o = handle(&request::action(1, a), false, &cfg, 0, &INFO).unwrap();
        assert_eq!(o.action, Some(a));
        assert_eq!(o.config, None);
        assert_eq!(&o.reply[5..8], &[msg::ACTION_ACK, 1, code]);
    }
    let mut changed = cfg;
    changed.channel = 5;
    let o = handle(
        &request::action(2, Action::RestoreDefaults),
        false,
        &changed,
        4,
        &INFO,
    )
    .unwrap();
    assert_eq!(o.config, Some(Config::default()));
    assert_eq!(o.generation, 5);
    assert_eq!(o.reply[5], msg::CONFIG);
}

#[test]
fn arbitrary_bytes_never_panic_and_replies_are_bounded() {
    // Deterministic xorshift fuzz over the full packet -> reply path.
    let mut s: u32 = 0x1234_5678;
    let mut rnd = || {
        s ^= s << 13;
        s ^= s >> 17;
        s ^= s << 5;
        s
    };
    let cfg = Config::default();
    let mut a = Assembler::new(1);
    let mut replies = 0;
    for i in 0..200_000u32 {
        let r = rnd();
        let mut p = r.to_le_bytes();
        // Bias towards our header so deep paths are reached.
        if i % 7 == 0 {
            a.push_packet([0x14, 0xF0, 0x7D, 0x54]);
            p = [0x14, 0x52, 0x01, (r & 0x07) as u8];
        }
        if let Some(c) = a.push_packet(p) {
            let m = a.message(c).to_vec();
            if let Some(o) = handle(&m, c.truncated, &cfg, 0, &INFO) {
                replies += 1;
                assert!(o.reply.len() <= MAX_MESSAGE_LEN);
                assert_eq!(o.reply[0], 0xF0);
                assert_eq!(*o.reply.last().unwrap(), 0xF7);
                assert!(o.reply[1..o.reply.len() - 1].iter().all(|&b| b < 0x80));
                if let Some(c) = o.config {
                    assert_eq!(c.sanitized(), c);
                }
            }
        }
    }
    assert!(replies > 0);
}

#[test]
fn handler_rejects_garbage_without_reply() {
    let cfg = Config::default();
    for m in [
        &[][..],
        &[0xF0, 0xF7],
        &[0xF0, 0x7D, 0x54, 0x52, 0x01, 0x01],
        &[0xF0, 0x7D, 0x54, 0x52, 0x01, 0x01, 0x01, 0x01], // no F7
        &[0xF0, 0x7D, 0x54, 0x52, 0x81, 0x01, 0x01, 0x01, 0xF7],
        &[0xF0, 0x7D, 0x54, 0x52, 0x01, 0x00, 0x01, 0xF7],
        &[0xF0, 0x7D, 0x54, 0x52, 0x01, 0x01, 0x01, 0x90, 0xF7],
    ] {
        assert!(handle(m, false, &cfg, 0, &INFO).is_none(), "{m:02X?}");
    }
}
