// SPDX-License-Identifier: GPL-3.0-only
//! Print the documented example trace (docs/midi-mapping.md) as USB-MIDI
//! packets: `cargo run -p instrument-events --example trace`.
use instrument_events::{Config, Engine, MotionSample, TouchSample};

fn emit(e: &mut Engine, t: u32) {
    while let Some(m) = e.next_message(t) {
        let p = m.usb_packet(0);
        println!(
            "{:>7} us  {:02X} {:02X} {:02X} {:02X}  {:?}",
            t, p[0], p[1], p[2], p[3], m
        );
    }
}

fn main() {
    let mut e = Engine::new(Config::default());
    e.connect(0);
    emit(&mut e, 0);
    // Motion: calibrated, still; then a rotation.
    e.motion(
        1_000,
        MotionSample {
            calibrated: true,
            rotation_dps: 0.0,
            pitch_deg: 0.0,
            tap: None,
            ..Default::default()
        },
    );
    e.touch(1_000, None); // finger up: arms the touch voice
    emit(&mut e, 1_000);
    e.touch(
        5_000,
        Some(TouchSample {
            location: 0.5,
            size: 0.3,
        }),
    );
    emit(&mut e, 5_000);
    e.touch(
        10_000,
        Some(TouchSample {
            location: 0.625,
            size: 0.3,
        }),
    );
    e.motion(
        10_000,
        MotionSample {
            calibrated: true,
            rotation_dps: 90.0,
            pitch_deg: 15.0,
            tap: None,
            ..Default::default()
        },
    );
    emit(&mut e, 10_000);
    e.touch(15_000, None);
    emit(&mut e, 15_000);
}
