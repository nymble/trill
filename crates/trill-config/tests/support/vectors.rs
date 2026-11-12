// SPDX-License-Identifier: GPL-3.0-only
// Shared by tests/vectors.rs and examples/vectors.rs.
#![allow(dead_code)]

use instrument_events::Config;
use trill_config::telemetry::{self, Frame, Sample};
use trill_config::usb::Assembler;
use trill_config::{handle, request, Action, DeviceInfo, Param};

pub const INFO: DeviceInfo = DeviceInfo {
    firmware: [0, 4, 0],
    variant: 0,
    uptime_s: 1234,
    boot_id: 0x1555,
};

fn hex(b: &[u8]) -> String {
    b.iter()
        .map(|x| format!("{x:02X}"))
        .collect::<Vec<_>>()
        .join(" ")
}

/// Run raw request bytes through packets -> assembler -> handler.
pub fn device(req: &[u8], cfg: &Config, generation: u16) -> Option<Vec<u8>> {
    // Encode without the size limit of encode_sysex for over-long input.
    let mut packets = Vec::new();
    for (i, chunk) in req.chunks(3).enumerate() {
        let last = (i + 1) * 3 >= req.len();
        let cin = if !last { 4 } else { 4 + chunk.len() as u8 };
        let mut p = [0x10 | cin, 0, 0, 0];
        p[1..1 + chunk.len()].copy_from_slice(chunk);
        packets.push(p);
    }
    let mut asm = Assembler::new(1);
    let mut out = None;
    for p in packets {
        if let Some(c) = asm.push_packet(p) {
            let msg = asm.message(c).to_vec();
            out = handle(&msg, c.truncated, cfg, generation, &INFO).map(|o| o.reply.to_vec());
        }
    }
    out
}

pub fn vectors() -> Vec<(&'static str, Vec<u8>)> {
    let mut long = vec![0xF0, 0x7D, 0x54, 0x52, 0x01, 0x03, 0x0B];
    long.extend([0x01; 70]);
    long.push(0xF7);
    vec![
        ("hello", request::hello(1).to_vec()),
        ("get_config", request::get_config(2).to_vec()),
        (
            "set_channel_steps",
            request::set_config(3, &[(Param::Channel, 2), (Param::PitchMode, 1)])
                .unwrap()
                .to_vec(),
        ),
        (
            "set_rotation_2000",
            request::set_config(4, &[(Param::RotationFullDps, 2000)])
                .unwrap()
                .to_vec(),
        ),
        (
            "set_out_of_range",
            request::set_config(5, &[(Param::Channel, 2), (Param::BendRange, 30)])
                .unwrap()
                .to_vec(),
        ),
        (
            "set_unknown_param",
            vec![
                0xF0, 0x7D, 0x54, 0x52, 0x01, 0x03, 0x06, 0x63, 0x00, 0x01, 0xF7,
            ],
        ),
        (
            "set_duplicate",
            request::set_config(7, &[(Param::BaseNote, 60), (Param::BaseNote, 61)])
                .unwrap()
                .to_vec(),
        ),
        (
            "set_bad_length",
            vec![0xF0, 0x7D, 0x54, 0x52, 0x01, 0x03, 0x08, 0x01, 0x00, 0xF7],
        ),
        ("action_panic", request::action(9, Action::Panic).to_vec()),
        (
            "action_restore_defaults",
            request::action(10, Action::RestoreDefaults).to_vec(),
        ),
        (
            "action_unknown",
            vec![0xF0, 0x7D, 0x54, 0x52, 0x01, 0x04, 0x0B, 0x09, 0xF7],
        ),
        ("too_long", long),
        (
            "bad_version",
            vec![0xF0, 0x7D, 0x54, 0x52, 0x02, 0x02, 0x0C, 0xF7],
        ),
        (
            "unknown_type",
            vec![0xF0, 0x7D, 0x54, 0x52, 0x01, 0x20, 0x0D, 0xF7],
        ),
        (
            "ignored_reply_echo",
            vec![0xF0, 0x7D, 0x54, 0x52, 0x01, 0x44, 0x0E, 0x01, 0xF7],
        ),
        (
            "ignored_other_7d",
            vec![0xF0, 0x7D, 0x00, 0x01, 0x01, 0x02, 0x0F, 0xF7],
        ),
        (
            "ignored_universal",
            vec![0xF0, 0x7E, 0x7F, 0x06, 0x01, 0xF7],
        ),
        (
            "telemetry_start_50",
            request::telemetry_start(16, 50).to_vec(),
        ),
        (
            "telemetry_start_100",
            request::telemetry_start(17, 100).to_vec(),
        ),
        (
            "telemetry_start_0",
            request::telemetry_start(18, 0).to_vec(),
        ),
        (
            "telemetry_start_101",
            request::telemetry_start(19, 101).to_vec(),
        ),
        (
            "telemetry_start_bad_length",
            vec![0xF0, 0x7D, 0x54, 0x52, 0x01, 0x05, 0x14, 0xF7],
        ),
        ("telemetry_stop", request::telemetry_stop(21).to_vec()),
        (
            "ignored_telemetry_echo",
            telemetry::encode(&Frame::default()).to_vec(),
        ),
        // Firmware 0.4 (CAP_CONFIG_PAGES): paged configuration.
        ("get_config_page0", request::get_config_page(22, 0).to_vec()),
        ("get_config_page1", request::get_config_page(23, 1).to_vec()),
        (
            "get_config_bad_page",
            request::get_config_page(24, 3).to_vec(),
        ),
        (
            "get_config_bad_length",
            vec![0xF0, 0x7D, 0x54, 0x52, 0x01, 0x02, 0x19, 0x01, 0x00, 0xF7],
        ),
        (
            "set_theremin",
            request::set_config(
                26,
                &[
                    (Param::Mode, 2),
                    (Param::ExpressionCc, 11),
                    (Param::GateDeg, 20),
                ],
            )
            .unwrap()
            .to_vec(),
        ),
        (
            "set_flick_gestures",
            request::set_config(
                27,
                &[
                    (Param::GestureAxis, 3),
                    (Param::GestureThresholdDps, 500),
                    (Param::GestureBaseNote, 70),
                ],
            )
            .unwrap()
            .to_vec(),
        ),
        (
            "set_mixed_pages",
            request::set_config(28, &[(Param::BendRange, 12), (Param::Mode, 1)])
                .unwrap()
                .to_vec(),
        ),
        (
            "set_tap_out_of_range",
            request::set_config(29, &[(Param::TapThresholdCg, 10)])
                .unwrap()
                .to_vec(),
        ),
        (
            "action_zero_orientation",
            request::action(30, Action::ZeroOrientation).to_vec(),
        ),
        // Firmware 0.5 (CAP_STRIKES): directional strikes on page 2.
        ("get_config_page2", request::get_config_page(31, 2).to_vec()),
        (
            "set_strikes",
            request::set_config(
                32,
                &[
                    (Param::StrikeDirections, 4),
                    (Param::StrikeNoteDown, 36),
                    (Param::StrikeNoteRight, 46),
                ],
            )
            .unwrap()
            .to_vec(),
        ),
        (
            "set_strikes_odd",
            request::set_config(33, &[(Param::StrikeDirections, 3)])
                .unwrap()
                .to_vec(),
        ),
        (
            "set_tilt_strike_page2",
            request::set_config(
                34,
                &[
                    (Param::NoteLengthMs, 450),
                    (Param::RegisterTilt, 0),
                    (Param::ZoneCurve, 0),
                    (Param::StrikeVoicing, 0),
                ],
            )
            .unwrap()
            .to_vec(),
        ),
        (
            "set_mode_tilt_strike",
            request::set_config(35, &[(Param::Mode, 3)])
                .unwrap()
                .to_vec(),
        ),
        (
            "set_scale_minor",
            request::set_config(36, &[(Param::Scale, 3)])
                .unwrap()
                .to_vec(),
        ),
    ]
}

pub fn render() -> String {
    let mut s = String::from(
        "# Trill configuration protocol v1 test vectors. Generated by\n\
         # `cargo run -p trill-config --example vectors`; do not edit.\n\
         # Device state: firmware defaults, generation 0, firmware 0.4.0,\n\
         # variant 0, uptime 1234 s, boot id 0x1555.\n\
         # name | request (host -> device) | reply (device -> host, '-' = none)\n",
    );
    let cfg = Config::default();
    for (name, req) in vectors() {
        let rep = device(&req, &cfg, 0).map_or("-".to_string(), |r| hex(&r));
        s.push_str(&format!("{name} | {} | {rep}\n", hex(&req)));
    }
    s
}

/// Telemetry frame fixtures: (name, frame in wire units, encoded bytes).
pub fn telemetry_frames() -> Vec<(&'static str, Frame)> {
    let mut rest = Frame {
        seq: 1,
        t_ms: 27_652,
        flags: telemetry::FLAG_CALIBRATED | telemetry::FLAG_IMU_NEW,
        imu_state: 2,
        trill_state: 3,
        imu_samples: 10_881 & 0x3FFF,
        taps: 10,
        calibrations: 1,
        ..Frame::default()
    };
    rest.set_sample(
        &Sample {
            accel_g: [-0.178, -0.977, 0.226],
            gyro_dps: [-0.7, -2.1, 1.4],
            pitch_deg: 10.2,
            roll_deg: -77.3,
            touch: None,
        },
        true,
    );
    let mut touch = Frame {
        seq: 2,
        t_ms: 27_672,
        flags: telemetry::FLAG_CALIBRATED,
        imu_state: 2,
        trill_state: 2,
        trill_frames: 512,
        ..Frame::default()
    };
    touch.set_sample(
        &Sample {
            accel_g: [0.0, 0.0, 1.0],
            gyro_dps: [90.0, -45.5, 0.04],
            pitch_deg: -0.004,
            roll_deg: 179.99,
            touch: Some((0.5, 0.25)),
        },
        true,
    );
    let mut saturate = Frame {
        seq: 3,
        t_ms: 0x1F_FFFF,
        imu_state: 2,
        trill_state: 2,
        ..Frame::default()
    };
    saturate.set_sample(
        &Sample {
            accel_g: [40.0, -40.0, 32.767],
            gyro_dps: [4000.0, -4000.0, -3276.8],
            pitch_deg: 90.0,
            roll_deg: -180.0,
            touch: Some((1.5, -0.2)),
        },
        true,
    );
    let mut invalid = Frame {
        seq: 4,
        t_ms: 5,
        imu_state: 3,
        trill_state: 0,
        flags: telemetry::FLAG_SAFE_MODE,
        ..Frame::default()
    };
    invalid.set_sample(
        &Sample {
            accel_g: [f32::NAN, 0.0, 1.0],
            gyro_dps: [0.0, f32::INFINITY, 0.0],
            pitch_deg: 1.0,
            roll_deg: 1.0,
            touch: Some((f32::NAN, 0.5)),
        },
        true,
    );
    let rollover = Frame {
        seq: 0x3FFF,
        t_ms: 0x1F_FFFF,
        flags: telemetry::FLAG_IMU_VALID,
        imu_state: 2,
        trill_state: 2,
        accel_mg: [i16::MIN, i16::MAX, -1],
        gyro_ddps: [1, -2, 0],
        pitch_cdeg: -9000,
        roll_cdeg: 18000,
        touch_pos: 0x3FFF,
        touch_size: 1,
        imu_samples: 0x3FFF,
        taps: 0x3FFF,
        calibrations: 0x7F,
        skipped: 0x3FFF,
        trill_frames: 0x3FFF,
    };
    vec![
        ("rest_no_trill", rest),
        ("touch_and_motion", touch),
        ("saturated", saturate),
        ("invalid_imu", invalid),
        ("counters_at_wrap", rollover),
    ]
}

fn frame_fields(f: &Frame) -> String {
    format!(
        "seq={} t_ms={} flags={} imu_state={} trill_state={} accel_mg={},{},{} gyro_ddps={},{},{} pitch_cdeg={} roll_cdeg={} touch_pos={} touch_size={} imu_samples={} taps={} calibrations={} skipped={} trill_frames={}",
        f.seq, f.t_ms, f.flags, f.imu_state, f.trill_state,
        f.accel_mg[0], f.accel_mg[1], f.accel_mg[2],
        f.gyro_ddps[0], f.gyro_ddps[1], f.gyro_ddps[2],
        f.pitch_cdeg, f.roll_cdeg, f.touch_pos, f.touch_size,
        f.imu_samples, f.taps, f.calibrations, f.skipped, f.trill_frames
    )
}

pub fn render_telemetry() -> String {
    let mut s = String::from(
        "# Trill telemetry frame format 1 fixtures (protocol v1, firmware 0.3.0+).\n\
         # Generated by `cargo run -p trill-config --example vectors -- telemetry`; do not edit.\n\
         # Fields are wire units: accel mg, gyro 0.1 deg/s, pitch/roll 0.01 deg,\n\
         # touch 0..16383, t_ms 21-bit, counters 14-bit (calibrations 7-bit).\n\
         # name | fields | frame (device -> host)\n",
    );
    for (name, f) in telemetry_frames() {
        s.push_str(&format!(
            "{name} | {} | {}\n",
            frame_fields(&f),
            hex(&telemetry::encode(&f))
        ));
    }
    s
}
