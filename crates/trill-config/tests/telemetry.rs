// SPDX-License-Identifier: GPL-3.0-only
//! Telemetry subscription, scheduling and frame codec.
use instrument_events::Config;
use trill_config::telemetry::{self, Frame, Sample, Schedule, TouchPoint, TouchesFrame};
use trill_config::{
    handle, msg, request, DeviceInfo, ErrorCode, CAP_TELEMETRY, MAX_MESSAGE_LEN, VARIANT_BLE_MIDI,
    VARIANT_IMU, VARIANT_MIC, VARIANT_MULTI_TOUCH, VARIANT_PCM_SYNTH,
};

const INFO: DeviceInfo = DeviceInfo {
    firmware: [0, 3, 0],
    variant: 0,
    uptime_s: 1,
    boot_id: 1,
};

fn run(m: &[u8]) -> Option<trill_config::Outcome> {
    handle(m, false, &Config::default(), 0, &INFO)
}

#[test]
fn hello_advertises_telemetry() {
    let o = run(&request::hello(1)).unwrap();
    assert_eq!(o.reply[5], msg::HELLO_REPLY);
    assert_ne!(o.reply[HELLO_CAPS] & CAP_TELEMETRY, 0);
    assert_eq!(
        o.reply[HELLO_CAPS] & 0x80,
        0,
        "capability byte is 7-bit MIDI data"
    );
}

#[test]
fn hello_echoes_the_multi_touch_variant() {
    let info = DeviceInfo {
        variant: VARIANT_MULTI_TOUCH,
        ..INFO
    };
    let o = handle(&request::hello(1), false, &Config::default(), 0, &info).unwrap();
    assert_ne!(o.reply[11] & VARIANT_MULTI_TOUCH, 0);
    assert!(o.reply[1..o.reply.len() - 1].iter().all(|&b| b < 0x80));
}
const HELLO_CAPS: usize = 7 + 5;

#[test]
fn variant_bits_are_distinct_7_bit_flags() {
    let bits = [
        VARIANT_PCM_SYNTH,
        VARIANT_IMU,
        VARIANT_MIC,
        VARIANT_MULTI_TOUCH,
        VARIANT_BLE_MIDI,
    ];
    let mut seen = 0u8;
    for b in bits {
        assert_eq!(b.count_ones(), 1);
        assert_eq!(b & 0x80, 0, "SysEx data bytes cannot carry bit 7");
        assert_eq!(seen & b, 0, "variant bit 0x{b:02X} reused");
        seen |= b;
    }
    assert_eq!(VARIANT_BLE_MIDI, 0x10);
}

#[test]
fn hello_echoes_the_ble_midi_variant() {
    let info = DeviceInfo {
        variant: VARIANT_BLE_MIDI | VARIANT_IMU | VARIANT_MIC | VARIANT_MULTI_TOUCH,
        ..INFO
    };
    let o = handle(&request::hello(1), false, &Config::default(), 0, &info).unwrap();
    assert_eq!(o.reply[11], 0x1E);
    assert!(o.reply[1..o.reply.len() - 1].iter().all(|&b| b < 0x80));
}

#[test]
fn start_and_stop_report_rate_and_never_touch_config() {
    for rate in [1u8, 25, 50, 100] {
        let o = run(&request::telemetry_start(3, rate)).unwrap();
        assert_eq!(o.telemetry, Some(rate));
        assert!(o.config.is_none() && o.action.is_none());
        assert_eq!(
            &o.reply[..],
            &[
                0xF0,
                0x7D,
                0x54,
                0x52,
                1,
                msg::TELEMETRY_ACK,
                3,
                rate,
                telemetry::LEASE_S,
                telemetry::FRAME_LEN as u8,
                telemetry::FORMAT,
                0xF7
            ]
        );
    }
    let o = run(&request::telemetry_stop(4)).unwrap();
    assert_eq!(o.telemetry, Some(0));
    assert_eq!(o.reply[7], 0);
}

#[test]
fn bad_rates_and_lengths_are_rejected_without_change() {
    for rate in [0u8, 101, 127] {
        let o = run(&request::telemetry_start(5, rate)).unwrap();
        assert_eq!(o.telemetry, None);
        assert_eq!(o.reply[5], msg::ERROR);
        assert_eq!(o.reply[7], ErrorCode::OutOfRange as u8);
        assert_eq!(o.reply[8], rate);
    }
    let o = run(&[
        0xF0,
        0x7D,
        0x54,
        0x52,
        1,
        msg::TELEMETRY_STOP,
        6,
        0x01,
        0xF7,
    ])
    .unwrap();
    assert_eq!(
        (o.reply[7], o.telemetry),
        (ErrorCode::BadLength as u8, None)
    );
    let o = run(&[
        0xF0,
        0x7D,
        0x54,
        0x52,
        1,
        msg::TELEMETRY_START,
        7,
        50,
        1,
        0xF7,
    ])
    .unwrap();
    assert_eq!(
        (o.reply[7], o.telemetry),
        (ErrorCode::BadLength as u8, None)
    );
}

#[test]
fn frames_echoed_back_are_ignored() {
    let f = telemetry::encode(&Frame::default());
    assert!(run(&f).is_none());
}

#[test]
fn frame_is_bounded_and_seven_bit() {
    let f = Frame {
        seq: 0xFFFF,
        t_ms: u32::MAX,
        flags: 0xFF,
        imu_state: 0xFF,
        trill_state: 0xFF,
        accel_mg: [i16::MIN; 3],
        gyro_ddps: [i16::MAX; 3],
        pitch_cdeg: -1,
        roll_cdeg: i16::MIN,
        touch_pos: 0xFFFF,
        touch_size: 0xFFFF,
        imu_samples: 0xFFFF,
        taps: 0xFFFF,
        calibrations: 0xFF,
        skipped: 0xFFFF,
        trill_frames: 0xFFFF,
    };
    let b = telemetry::encode(&f);
    assert_eq!(b.len(), telemetry::FRAME_LEN);
    assert!(b.len() <= MAX_MESSAGE_LEN);
    assert!(b[1..b.len() - 1].iter().all(|&x| x < 0x80));
    let d = telemetry::decode(&b).unwrap();
    // Out-of-range wire values are masked, signed values survive exactly.
    assert_eq!(d.seq, 0x3FFF);
    assert_eq!(d.t_ms, 0x1F_FFFF);
    assert_eq!(d.accel_mg, [i16::MIN; 3]);
    assert_eq!(d.gyro_ddps, [i16::MAX; 3]);
    assert_eq!((d.pitch_cdeg, d.roll_cdeg), (-1, i16::MIN));
}

#[test]
fn decode_rejects_malformed() {
    let good = telemetry::encode(&Frame::default());
    assert!(telemetry::decode(&good).is_some());
    assert!(telemetry::decode(&good[..good.len() - 1]).is_none());
    let mut b = good.clone();
    b[7] = 2; // unknown format
    assert!(telemetry::decode(&b).is_none());
    let mut b = good.clone();
    b[20] = 0x80; // status byte inside
    assert!(telemetry::decode(&b).is_none());
    let mut b = good.clone();
    b[5] = msg::CONFIG;
    assert!(telemetry::decode(&b).is_none());
}

#[test]
fn quantize_rounds_saturates_and_flags_non_finite() {
    assert_eq!(telemetry::quantize(0.0004, 1000.0), Some(0));
    assert_eq!(telemetry::quantize(-0.0005, 1000.0), Some(-1));
    assert_eq!(telemetry::quantize(1e9, 1.0), Some(i16::MAX));
    assert_eq!(telemetry::quantize(-1e9, 1.0), Some(i16::MIN));
    assert_eq!(telemetry::quantize(f32::NAN, 1.0), None);
    assert_eq!(telemetry::quantize(f32::INFINITY, 1.0), None);
    assert_eq!(telemetry::unit14(f32::NAN), 0);
    assert_eq!(telemetry::unit14(2.0), 0x3FFF);
    assert_eq!(telemetry::unit14(0.5), 8192);
}

#[test]
fn non_finite_imu_values_clear_valid_flag_and_zero_fields() {
    let mut f = Frame::default();
    f.set_sample(
        &Sample {
            accel_g: [1.0, 0.0, 0.0],
            ..Sample::default()
        },
        true,
    );
    assert_ne!(f.flags & telemetry::FLAG_IMU_VALID, 0);
    assert_eq!(f.accel_mg, [1000, 0, 0]);
    f.set_sample(
        &Sample {
            accel_g: [f32::NAN, 0.0, 0.0],
            ..Sample::default()
        },
        true,
    );
    assert_eq!(f.flags & telemetry::FLAG_IMU_VALID, 0);
    assert_eq!(f.accel_mg, [0, 0, 0]);
    // A sensor that is not running is never "valid", even with old values.
    f.set_sample(
        &Sample {
            accel_g: [0.0, 0.0, 1.0],
            ..Sample::default()
        },
        false,
    );
    assert_eq!(f.flags & telemetry::FLAG_IMU_VALID, 0);
}

#[test]
fn missing_touch_is_distinct_from_zero_position() {
    let mut f = Frame::default();
    f.set_sample(
        &Sample {
            touch: Some((0.0, 0.0)),
            ..Sample::default()
        },
        true,
    );
    assert_ne!(f.flags & telemetry::FLAG_TOUCH, 0);
    assert_eq!(f.touch_pos, 0);
    f.set_sample(
        &Sample {
            touch: None,
            ..Sample::default()
        },
        true,
    );
    assert_eq!(f.flags & telemetry::FLAG_TOUCH, 0);
}

#[test]
fn schedule_rate_lease_and_skips() {
    let mut s = Schedule::new();
    assert!(!s.due(0));
    s.subscribe(50, 1_000);
    assert_eq!(s.rate_hz(), 50);
    assert!(s.due(1_000)); // first frame immediately
    assert!(!s.due(10_000));
    assert!(s.due(21_000)); // 20 ms period
    assert_eq!(s.skipped, 0);
    // Writer blocked for 100 ms: 4 periods missed, one frame now, no backlog.
    assert!(s.due(121_000));
    assert_eq!(s.skipped, 4);
    assert!(!s.due(122_000));
    // Lease: 5 s after the last subscribe.
    assert!(s.due(4_990_000));
    assert!(!s.due(5_001_000));
    assert_eq!(s.rate_hz(), 0);
    // Renewal keeps it alive.
    s.subscribe(25, 6_000_000);
    s.subscribe(25, 9_000_000);
    assert!(s.due(13_000_000));
    s.stop();
    assert!(!s.due(13_100_000));
    // Rates are clamped, 0 stops.
    s.subscribe(200, 0);
    assert_eq!(s.rate_hz(), telemetry::MAX_RATE_HZ);
    s.subscribe(0, 0);
    assert_eq!(s.rate_hz(), 0);
}

#[test]
fn sequence_and_skip_counters_wrap_at_14_bits() {
    let mut s = Schedule::new();
    s.seq = 0x3FFE;
    assert_eq!(s.next_seq(), 0x3FFE);
    assert_eq!(s.next_seq(), 0x3FFF);
    assert_eq!(s.next_seq(), 0);
    s.skipped = 0x3FFF;
    s.subscribe(100, 0);
    assert!(s.due(0));
    assert!(s.due(20_000)); // one missed period
    assert_eq!(s.skipped, 0);
}

#[test]
fn companion_roundtrip_and_rejects_malformed() {
    let empty = TouchesFrame::from_normalised(7, &[]);
    assert_eq!(empty.count, 0);
    let enc = telemetry::encode_touches(&empty);
    assert_eq!(enc.len(), telemetry::touches_frame_len(0));
    assert_eq!(enc[5], msg::TELEMETRY_TOUCHES);
    assert_eq!(telemetry::decode_touches(&enc), Some(empty));

    let five = TouchesFrame::from_normalised(
        0x3FFF,
        &[
            (0.0, 0.0),
            (0.5, 0.25),
            (1.0, 1.0),
            (0.1, 0.2),
            (0.9, 0.8),
            (0.3, 0.3), // sixth is dropped
        ],
    );
    assert_eq!(five.count, 5);
    assert_eq!(
        five.as_slice()[1],
        TouchPoint {
            position: 8192,
            size: 4096
        }
    );
    assert_eq!(five.as_slice()[2].position, 0x3FFF);
    let enc = telemetry::encode_touches(&five);
    assert_eq!(enc.len(), telemetry::touches_frame_len(5));
    assert!(enc.len() <= MAX_MESSAGE_LEN);
    let got = telemetry::decode_touches(&enc).unwrap();
    assert_eq!(got, five);

    // Non-finite entries are skipped, later valid ones still count.
    let mixed = TouchesFrame::from_normalised(1, &[(f32::NAN, 0.5), (0.25, 0.5)]);
    assert_eq!(mixed.count, 1);
    assert_eq!(mixed.as_slice()[0].position, telemetry::unit14(0.25));

    let good = telemetry::encode_touches(&five);
    assert!(telemetry::decode_touches(&good).is_some());
    assert!(telemetry::decode_touches(&good[..good.len() - 1]).is_none());
    let mut b = good.clone();
    b[5] = msg::TELEMETRY;
    assert!(
        telemetry::decode_touches(&b).is_none(),
        "format-1 frame is not a companion"
    );
    b = good.clone();
    b[7] = 2; // unknown companion format
    assert!(telemetry::decode_touches(&b).is_none());
    b = good.clone();
    b[10] = 6; // count > 5, length still 5-touch
    assert!(telemetry::decode_touches(&b).is_none());
    // Format 1 fixtures must not decode as companions.
    let mut f1 = Frame {
        seq: 2,
        flags: telemetry::FLAG_TOUCH,
        touch_pos: 8192,
        touch_size: 4096,
        ..Frame::default()
    };
    f1.set_sample(
        &Sample {
            touch: Some((0.5, 0.25)),
            ..Sample::default()
        },
        true,
    );
    assert!(telemetry::decode_touches(&telemetry::encode(&f1)).is_none());
    assert!(
        telemetry::decode(&enc).is_none(),
        "companion is not a format-1 frame"
    );
}
