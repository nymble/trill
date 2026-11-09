// SPDX-License-Identifier: GPL-3.0-only
//! Scripted-gesture tests for the event engine.
use instrument_events::engine::{CRITICAL_CAPACITY, NOTE_OFF_RESERVE};
use instrument_events::midi::{cc, BEND_CENTER};
use instrument_events::{Config, Engine, MidiMessage, MotionSample, PitchMode, Scale, TouchSample};
use MidiMessage::*;

fn drain(e: &mut Engine, now: u32) -> Vec<MidiMessage> {
    let mut v = Vec::new();
    while let Some(m) = e.next_message(now) {
        v.push(m);
        assert!(v.len() < 1000, "runaway");
    }
    v
}

fn notes(ms: &[MidiMessage]) -> Vec<MidiMessage> {
    ms.iter().copied().filter(|m| m.is_note()).collect()
}

fn touch(loc: f32, size: f32) -> Option<TouchSample> {
    Some(TouchSample {
        location: loc,
        size,
    })
}

fn motion(cal: bool, rot: f32, pitch: f32, tap: Option<f32>) -> MotionSample {
    MotionSample {
        calibrated: cal,
        rotation_dps: rot,
        pitch_deg: pitch,
        tap,
        ..Default::default()
    }
}

/// Connected engine with the reset sequence drained and the touch armed.
fn ready(cfg: Config, t: u32) -> Engine {
    let mut e = Engine::new(cfg);
    e.connect(t);
    drain(&mut e, t);
    e.touch(t, None);
    e
}

/// Track sounding notes from a message stream; panics on a double note on.
fn check_balanced(ms: &[MidiMessage]) -> Vec<(u8, u8)> {
    let mut on = Vec::new();
    for m in ms {
        match *m {
            NoteOn {
                channel,
                note,
                velocity,
            } => {
                assert!(velocity > 0);
                assert!(!on.contains(&(channel, note)), "double note on {note}");
                assert!(
                    on.iter().all(|&(c, _)| c != channel),
                    "second voice on ch {channel}"
                );
                on.push((channel, note));
            }
            NoteOff { channel, note, .. } => {
                let i = on
                    .iter()
                    .position(|&x| x == (channel, note))
                    .expect("note off without on");
                on.remove(i);
            }
            ControlChange {
                control: cc::ALL_NOTES_OFF,
                channel,
                ..
            } => on.retain(|&(c, _)| c != channel),
            _ => {}
        }
    }
    on
}

#[test]
fn connect_sends_reset_sequence_in_order() {
    let mut e = Engine::new(Config::default());
    assert_eq!(e.next_message(0), None, "nothing while disconnected");
    e.connect(0);
    let ms = drain(&mut e, 0);
    let ccm = |control, value| ControlChange {
        channel: 0,
        control,
        value,
    };
    assert_eq!(
        &ms[..10],
        &[
            ccm(123, 0),
            ccm(120, 0),
            PitchBend {
                channel: 0,
                value: BEND_CENTER
            },
            ChannelPressure {
                channel: 0,
                value: 0
            },
            ccm(101, 0),
            ccm(100, 0),
            ccm(6, 24),
            ccm(38, 0),
            ccm(101, 127),
            ccm(100, 127),
        ]
    );
    let p = |control| ControlChange {
        channel: 9,
        control,
        value: 0,
    };
    assert_eq!(
        &ms[10..],
        &[
            p(123),
            p(120),
            PitchBend {
                channel: 9,
                value: BEND_CENTER
            }
        ]
    );
}

#[test]
fn no_note_at_startup_or_from_touch_held_across_connect() {
    let mut e = Engine::new(Config::default());
    // Finger already on the strip before connect.
    e.touch(0, touch(0.5, 0.5));
    e.connect(1_000);
    drain(&mut e, 1_000);
    for i in 0..20 {
        e.touch(2_000 + i * 5_000, touch(0.5, 0.5));
    }
    assert!(notes(&drain(&mut e, 200_000)).is_empty());
    // Lift, then touch: now it plays.
    e.touch(200_000, None);
    e.touch(205_000, touch(0.5, 0.5));
    let n = notes(&drain(&mut e, 205_000));
    assert_eq!(n.len(), 1);
}

#[test]
fn bend_mode_note_bend_and_pitch_scaling() {
    let mut e = ready(Config::default(), 0);
    // 0.5 of a 24-semitone strip = +12 semitones -> note 60, bend centred.
    e.touch(5_000, touch(0.5, 0.3));
    let ms = drain(&mut e, 5_000);
    assert_eq!(
        ms[0],
        PitchBend {
            channel: 0,
            value: BEND_CENTER
        },
        "bend precedes note on"
    );
    assert!(matches!(ms[1], NoteOn { note: 60, .. }));
    // Slide +3 semitones (0.625): bend = 8192 + 3/24 * 8191 = 9216 (rounded).
    e.touch(10_000, touch(0.625, 0.3));
    let ms = drain(&mut e, 10_000);
    assert!(
        ms.contains(&PitchBend {
            channel: 0,
            value: 9216
        }),
        "{ms:?}"
    );
    assert!(
        notes(&ms).is_empty(),
        "sliding does not retrigger in bend mode"
    );
    // Off-grid onset: 0.51 -> s = 12.24 -> note 60 with +0.24 st bend.
    e.touch(15_000, None);
    e.touch(20_000, touch(0.51, 0.3));
    let ms = drain(&mut e, 20_000);
    let want = (8192.0f32 + 0.24 / 24.0 * 8191.0 + 0.5) as u16;
    assert_eq!(
        ms[ms.len() - 2],
        PitchBend {
            channel: 0,
            value: want
        }
    );
    assert!(matches!(ms[ms.len() - 1], NoteOn { note: 60, .. }));
}

#[test]
fn bend_is_clamped_to_range() {
    let cfg = Config {
        bend_range_semitones: 2,
        ..Config::default()
    };
    let mut e = ready(cfg, 0);
    e.touch(5_000, touch(0.0, 0.3));
    drain(&mut e, 5_000);
    e.touch(10_000, touch(1.0, 0.3)); // +24 semitones, range only ±2
    let ms = drain(&mut e, 10_000);
    assert!(ms.contains(&PitchBend {
        channel: 0,
        value: 16383
    }));
}

#[test]
fn steps_mode_releases_before_attack_with_hysteresis() {
    let cfg = Config {
        pitch_mode: PitchMode::Steps,
        ..Config::default()
    };
    let mut e = ready(cfg, 0);
    let step = 1.0 / 24.0;
    e.touch(5_000, touch(12.0 * step, 0.3));
    let ms = drain(&mut e, 5_000);
    assert_eq!(
        notes(&ms),
        vec![NoteOn {
            channel: 0,
            note: 60,
            velocity: ms
                .iter()
                .find_map(|m| if let NoteOn { velocity, .. } = m {
                    Some(*velocity)
                } else {
                    None
                })
                .unwrap()
        }]
    );
    assert!(
        !ms.iter().any(|m| matches!(m, PitchBend { .. })),
        "no bend in steps mode"
    );
    // Just past the half-way point: inside hysteresis, no change.
    e.touch(10_000, touch(12.55 * step, 0.3));
    assert!(notes(&drain(&mut e, 10_000)).is_empty());
    // Clearly nearer 61.
    e.touch(15_000, touch(12.8 * step, 0.3));
    let n = notes(&drain(&mut e, 15_000));
    assert!(matches!(n[0], NoteOff { note: 60, .. }));
    assert!(matches!(n[1], NoteOn { note: 61, .. }));
    assert_eq!(n.len(), 2);
}

#[test]
fn pentatonic_quantisation() {
    let cfg = Config {
        scale: Scale::Pentatonic,
        pitch_mode: PitchMode::Steps,
        ..Config::default()
    };
    let mut e = ready(cfg, 0);
    let mut t = 5_000;
    let mut got = Vec::new();
    for s in [0.0f32, 1.2, 2.9, 5.4, 6.0, 10.6, 11.4, 23.9] {
        e.touch(t, touch(s / 24.0, 0.3));
        got.push(e.active_note().unwrap());
        e.touch(t + 1_000, None);
        t += 5_000;
    }
    assert_eq!(got, vec![48, 50, 50, 52, 55, 60, 60, 72]);
}

#[test]
fn hysteresis_on_off_thresholds_and_velocity() {
    let mut e = ready(Config::default(), 0);
    e.touch(5_000, touch(0.5, 0.04)); // above off, below on: no note
    assert!(e.active_note().is_none());
    e.touch(10_000, touch(0.5, 0.05)); // at on threshold: min velocity
    let ms = drain(&mut e, 10_000);
    assert!(ms.contains(&NoteOn {
        channel: 0,
        note: 60,
        velocity: 30
    }));
    e.touch(15_000, touch(0.5, 0.03)); // between thresholds: still held
    assert_eq!(e.active_note(), Some(60));
    e.touch(20_000, touch(0.5, 0.02)); // below off: release
    assert!(notes(&drain(&mut e, 20_000)).contains(&NoteOff {
        channel: 0,
        note: 60,
        velocity: 64
    }));
    e.touch(25_000, touch(0.5, 5.0)); // huge size saturates at 127
    assert!(drain(&mut e, 25_000).contains(&NoteOn {
        channel: 0,
        note: 60,
        velocity: 127
    }));
}

#[test]
fn pressure_is_smoothed_deadbanded_and_rate_limited() {
    let cfg = Config {
        pressure_tau_us: 0,
        ..Config::default()
    };
    let mut e = ready(cfg, 0);
    e.touch(5_000, touch(0.5, 0.3));
    let first = drain(&mut e, 5_000);
    let p0 = first
        .iter()
        .find_map(|m| {
            if let ChannelPressure { value, .. } = m {
                Some(*value)
            } else {
                None
            }
        })
        .unwrap();
    // Jitter smaller than the deadband produces nothing.
    let tiny = 0.3 + 0.4 / 127.0 * (0.6 - 0.025);
    e.touch(10_000, touch(0.5, tiny));
    assert!(drain(&mut e, 10_000).is_empty());
    // Many updates inside one rate-limit interval coalesce to one message.
    let before = e.stats().control_coalesced;
    e.touch(11_000, touch(0.5, 0.4));
    e.touch(11_500, touch(0.5, 0.45));
    e.touch(12_000, touch(0.5, 0.5));
    // Interval is 4 ms from the last send at 5 ms -> nothing at 8 ms.
    assert!(drain(&mut e, 8_000).is_empty());
    let ms = drain(&mut e, 12_000);
    assert_eq!(ms.len(), 1, "{ms:?}");
    assert!(matches!(ms[0], ChannelPressure { value, .. } if value > p0));
    assert!(e.stats().control_coalesced >= before + 2);
    // Release forces pressure 0 after the note off, without waiting.
    e.touch(12_500, None);
    let ms = drain(&mut e, 12_500);
    assert!(matches!(ms[0], NoteOff { .. }));
    assert_eq!(
        ms[1],
        ChannelPressure {
            channel: 0,
            value: 0
        }
    );
}

#[test]
fn smoothing_converges() {
    let mut e = ready(Config::default(), 0);
    e.touch(5_000, touch(0.5, 0.1));
    drain(&mut e, 5_000);
    let mut last = 0;
    for i in 1..60u32 {
        let t = 5_000 + i * 5_000;
        e.touch(t, touch(0.5, 0.6));
        for m in drain(&mut e, t) {
            if let ChannelPressure { value, .. } = m {
                assert!(value >= last, "monotonic rise");
                last = value;
            }
        }
    }
    assert!(last >= 126, "{last}");
}

#[test]
fn unplug_reconnect_leaves_no_stuck_note() {
    let mut e = ready(Config::default(), 0);
    e.touch(5_000, touch(0.5, 0.3));
    // Disconnect before the note on was even transmitted.
    e.disconnect();
    assert_eq!(e.active_note(), None);
    assert_eq!(e.critical_len(), 0);
    assert_eq!(e.next_message(6_000), None);
    // Touch continues while unplugged: nothing is generated.
    for i in 0..10 {
        e.touch(10_000 + i * 5_000, touch(0.5, 0.3));
    }
    e.connect(70_000);
    let ms = drain(&mut e, 70_000);
    assert!(notes(&ms).is_empty());
    assert_eq!(
        ms[0],
        ControlChange {
            channel: 0,
            control: 123,
            value: 0
        }
    );
    // Held finger does not sound until lifted.
    e.touch(75_000, touch(0.5, 0.3));
    assert!(notes(&drain(&mut e, 75_000)).is_empty());
    assert_eq!(e.stats().disconnects, 1);
    assert_eq!(e.stats().connects, 2);
}

#[test]
fn missing_imu_does_not_block_touch() {
    let mut e = ready(Config::default(), 0);
    // No motion input ever.
    for i in 0..100u32 {
        let t = 5_000 + i * 5_000;
        e.touch(t, if i % 20 < 10 { touch(0.5, 0.3) } else { None });
        e.tick(t);
    }
    let ms = drain(&mut e, 600_000);
    assert_eq!(check_balanced(&ms), vec![]);
    assert_eq!(e.stats().note_on, 5);
    assert!(!ms.iter().any(|m| matches!(
        m,
        ControlChange {
            control: 74 | 1,
            ..
        }
    )));
}

#[test]
fn imu_failure_mid_gesture_releases_percussion_and_neutralises_ccs() {
    let cfg = Config {
        percussion_enabled: true,
        ..Config::default()
    };
    let mut e = ready(cfg, 0);
    e.motion(0, motion(true, 0.0, 0.0, None));
    e.motion(2_000_000, motion(true, 200.0, 30.0, Some(2.0)));
    e.touch(2_000_000, touch(0.5, 0.3));
    let ms = drain(&mut e, 2_000_000);
    assert!(ms.contains(&NoteOn {
        channel: 9,
        note: 39,
        velocity: (40.0f32 + 2.0 / 3.0 * 87.0 + 0.5) as u8
    }));
    assert!(ms
        .iter()
        .any(|m| matches!(m, ControlChange { control: 74, value, .. } if *value > 60)));
    // IMU goes silent; the tick timeout reports it.
    e.touch(2_010_000, touch(0.5, 0.3));
    e.tick(2_010_000); // percussion length (60 ms) not reached yet
    e.touch(2_150_000, touch(0.5, 0.3));
    e.tick(2_150_000);
    let ms = drain(&mut e, 2_150_000);
    assert!(ms.contains(&NoteOff {
        channel: 9,
        note: 39,
        velocity: 64
    }));
    assert!(ms.contains(&ControlChange {
        channel: 0,
        control: 74,
        value: 0
    }));
    assert!(ms.contains(&ControlChange {
        channel: 0,
        control: 1,
        value: 0
    }));
    assert_eq!(e.stats().motion_lost, 1);
    // Touch voice still sounding.
    assert_eq!(e.active_note(), Some(60));
}

#[test]
fn percussion_is_gated_until_calibrated_and_armed() {
    let cfg = Config {
        percussion_enabled: true,
        ..Config::default()
    };
    let mut e = ready(cfg, 0);
    e.motion(1_000, motion(false, 0.0, 0.0, Some(2.0)));
    e.motion(2_000, motion(true, 0.0, 0.0, Some(2.0))); // calibrated just now
    e.motion(500_000, motion(true, 0.0, 0.0, Some(2.0)));
    assert!(notes(&drain(&mut e, 500_000)).is_empty());
    e.motion(1_002_000, motion(true, 0.0, 0.0, Some(2.0)));
    assert_eq!(notes(&drain(&mut e, 1_002_000)).len(), 1);
    e.tick(1_062_000);
    assert!(matches!(
        notes(&drain(&mut e, 1_062_000))[..],
        [NoteOff { channel: 9, .. }]
    ));
    // Motion CCs are not sent while uncalibrated.
    let mut e = ready(Config::default(), 0);
    e.motion(1_000, motion(false, 300.0, 40.0, None));
    assert!(drain(&mut e, 1_000).is_empty());
}

#[test]
fn touch_sensor_loss_and_stale_frames_release() {
    let mut e = ready(Config::default(), 0);
    e.touch(5_000, touch(0.5, 0.3));
    drain(&mut e, 5_000);
    e.touch_lost(6_000);
    assert!(matches!(
        notes(&drain(&mut e, 6_000))[..],
        [NoteOff { note: 60, .. }]
    ));
    // Frames resume with the finger still down: no note until lifted.
    e.touch(10_000, touch(0.5, 0.3));
    assert!(notes(&drain(&mut e, 10_000)).is_empty());
    e.touch(15_000, None);
    e.touch(20_000, touch(0.5, 0.3));
    assert_eq!(e.active_note(), Some(60));
    // Frames stop arriving without an error: tick releases after 50 ms.
    e.tick(60_000);
    assert_eq!(e.active_note(), Some(60));
    e.tick(70_001);
    assert_eq!(e.active_note(), None);
    assert_eq!(e.stats().touch_timeouts, 1);
}

#[test]
fn invalid_inputs_are_rejected() {
    let mut e = ready(Config::default(), 0);
    e.touch(5_000, touch(f32::NAN, 0.3));
    e.touch(5_000, touch(0.5, f32::INFINITY));
    e.motion(5_000, motion(true, f32::NAN, 0.0, None));
    e.motion(5_000, motion(true, 0.0, f32::NEG_INFINITY, None));
    e.motion(5_000, motion(true, 0.0, 0.0, Some(f32::NAN)));
    assert_eq!(e.stats().invalid_inputs, 5);
    assert!(drain(&mut e, 5_000).is_empty());
    // Out-of-range but finite values are clamped.
    e.touch(6_000, touch(7.0, 0.3));
    assert_eq!(e.active_note(), Some(72));
    e.touch(7_000, touch(-3.0, 0.3));
    for m in drain(&mut e, 7_000) {
        let (b, n) = m.to_bytes();
        assert!(b[1..n].iter().all(|&d| d <= 127));
    }
    // A NaN-laden config falls back to sane values.
    let c = Config {
        range_semitones: f32::NAN,
        touch_on: f32::NAN,
        channel: 200,
        ..Config::default()
    }
    .sanitized();
    assert_eq!(c.range_semitones, 24.0);
    assert_eq!(c.channel, 200 & 0x0F);
    assert!(c.touch_off < c.touch_on);
}

#[test]
fn timestamp_rollover_and_backwards_samples() {
    let t0 = u32::MAX - 20_000;
    let mut e = ready(Config::default(), t0);
    e.touch(t0 + 5_000, touch(0.5, 0.3));
    assert_eq!(e.active_note(), Some(60));
    // Cross the 2^32 µs wrap with regular frames: no timeout, no release.
    let mut t = t0 + 5_000;
    for _ in 0..10 {
        t = t.wrapping_add(5_000);
        e.touch(t, touch(0.5, 0.3));
        e.tick(t);
    }
    assert!(t < t0, "wrapped");
    assert_eq!(e.active_note(), Some(60));
    assert_eq!(e.stats().touch_timeouts, 0);
    // A sample stamped before the previous one is ignored.
    e.touch(t.wrapping_sub(1_000), None);
    assert_eq!(e.active_note(), Some(60));
    assert_eq!(e.stats().stale_inputs, 1);
    // tick() with a 'now' slightly older than the last frame (task skew) is harmless.
    e.tick(t.wrapping_sub(100));
    assert_eq!(e.active_note(), Some(60));
    // Rate limiting across the wrap.
    let cfg = Config {
        pressure_tau_us: 0,
        ..Config::default()
    };
    let mut e = ready(cfg, u32::MAX - 1_000);
    e.touch(u32::MAX - 500, touch(0.5, 0.3));
    drain(&mut e, u32::MAX - 500);
    e.touch(1_000, touch(0.5, 0.5));
    assert!(
        drain(&mut e, 1_000).is_empty(),
        "only 1.5 ms since last send"
    );
    assert_eq!(drain(&mut e, 3_600).len(), 1);
}

#[test]
fn queue_flood_never_loses_a_note_off() {
    // Host never reads: messages pile up in the critical queue.
    let cfg = Config {
        pitch_mode: PitchMode::Steps,
        step_hysteresis: 0.0,
        ..Config::default()
    };
    let mut e = ready(cfg, 0);
    let mut all = Vec::new();
    let mut t = 0u32;
    for i in 0..400u32 {
        t += 1_000;
        let loc = ((i * 7) % 24) as f32 / 24.0 + 0.01;
        e.touch(t, if i % 3 == 2 { None } else { touch(loc, 0.3) });
        assert!(e.critical_len() <= CRITICAL_CAPACITY);
        // Drain one message only every 10 ms: severe backpressure.
        if i % 10 == 0 {
            all.extend(e.next_message(t));
        }
    }
    e.touch(t + 1_000, None);
    all.extend(drain(&mut e, t + 1_000));
    let s = e.stats();
    assert!(s.note_on_deferred > 0, "flood exercised the reserve");
    assert_eq!(s.emergency_all_notes_off, 0);
    assert_eq!(s.note_on, s.note_off);
    assert!(s.critical_high_water as usize <= CRITICAL_CAPACITY);
    assert_eq!(check_balanced(&all), vec![], "everything released");
    let _ = NOTE_OFF_RESERVE;
}

#[test]
fn panic_key_resets_and_requires_lift() {
    let mut e = ready(Config::default(), 0);
    e.touch(5_000, touch(0.5, 0.3));
    drain(&mut e, 5_000);
    e.panic(6_000);
    let ms = drain(&mut e, 6_000);
    assert_eq!(
        ms[0],
        ControlChange {
            channel: 0,
            control: 123,
            value: 0
        }
    );
    assert_eq!(
        ms[1],
        ControlChange {
            channel: 0,
            control: 120,
            value: 0
        }
    );
    assert_eq!(
        ms[2],
        PitchBend {
            channel: 0,
            value: BEND_CENTER
        }
    );
    assert_eq!(e.active_note(), None);
    e.touch(10_000, touch(0.5, 0.3));
    assert_eq!(e.active_note(), None);
}

#[test]
fn config_change_releases_and_resends_bend_range() {
    let mut e = ready(Config::default(), 0);
    e.touch(5_000, touch(0.5, 0.3));
    drain(&mut e, 5_000);
    e.set_config(Config {
        bend_range_semitones: 12,
        ..Config::default()
    });
    let ms = drain(&mut e, 6_000);
    assert!(matches!(ms[0], NoteOff { note: 60, .. }));
    assert!(ms.contains(&ControlChange {
        channel: 0,
        control: 6,
        value: 12
    }));
    assert_eq!(notes(&ms).len(), 1, "only the release");
    // Changing only the scale does not resend RPN but still needs a lift.
    let mut e = ready(Config::default(), 0);
    e.touch(5_000, touch(0.5, 0.3));
    drain(&mut e, 5_000);
    e.set_config(Config {
        scale: Scale::Pentatonic,
        ..Config::default()
    });
    let ms = drain(&mut e, 6_000);
    assert_eq!(notes(&ms).len(), 1);
    e.touch(7_000, touch(0.5, 0.3));
    assert_eq!(e.active_note(), None);
}

#[test]
fn scripted_gesture_fixture() {
    // Tap-slide-lift gesture with motion running: a deterministic trace.
    let mut e = ready(Config::default(), 0);
    let mut out = Vec::new();
    for i in 0..40u32 {
        let t = 1_000 + i * 5_000;
        e.motion(t, motion(true, i as f32 * 10.0, 0.0, None));
        let tf = match i {
            0..=4 => None,
            5..=29 => touch(0.25 + (i - 5) as f32 * 0.01, 0.2 + (i - 5) as f32 * 0.01),
            _ => None,
        };
        e.touch(t, tf);
        e.tick(t);
        out.extend(drain(&mut e, t));
    }
    assert_eq!(check_balanced(&out), vec![]);
    let n = notes(&out);
    assert_eq!(n.len(), 2);
    assert!(matches!(n[0], NoteOn { note: 54, .. }));
    assert!(out
        .iter()
        .any(|m| matches!(m, PitchBend { value, .. } if *value > BEND_CENTER)));
    assert!(out
        .iter()
        .any(|m| matches!(m, ControlChange { control: 74, .. })));
    // The rate limit bounds controller traffic: <= 1 per controller per 4 ms.
    let ctl = out.iter().filter(|m| !m.is_note()).count();
    assert!(ctl <= 4 * 40 + 2, "{ctl}");
}

/// The exact trace printed by `examples/trace.rs` and listed in
/// docs/midi-mapping.md ("Example trace"). Keep all three in sync.
#[test]
fn documented_trace() {
    let mut e = Engine::new(Config::default());
    let mut got: Vec<(u32, [u8; 4])> = Vec::new();
    let mut emit = |e: &mut Engine, t: u32| {
        while let Some(m) = e.next_message(t) {
            got.push((t, m.usb_packet(0)));
        }
    };
    e.connect(0);
    emit(&mut e, 0);
    e.motion(1_000, motion(true, 0.0, 0.0, None));
    e.touch(1_000, None);
    emit(&mut e, 1_000);
    e.touch(5_000, touch(0.5, 0.3));
    emit(&mut e, 5_000);
    e.touch(10_000, touch(0.625, 0.3));
    e.motion(10_000, motion(true, 90.0, 15.0, None));
    emit(&mut e, 10_000);
    e.touch(15_000, None);
    emit(&mut e, 15_000);
    let want: &[(u32, [u8; 4])] = &[
        (0, [0x0B, 0xB0, 0x7B, 0x00]),
        (0, [0x0B, 0xB0, 0x78, 0x00]),
        (0, [0x0E, 0xE0, 0x00, 0x40]),
        (0, [0x0D, 0xD0, 0x00, 0x00]),
        (0, [0x0B, 0xB0, 0x65, 0x00]),
        (0, [0x0B, 0xB0, 0x64, 0x00]),
        (0, [0x0B, 0xB0, 0x06, 0x18]),
        (0, [0x0B, 0xB0, 0x26, 0x00]),
        (0, [0x0B, 0xB0, 0x65, 0x7F]),
        (0, [0x0B, 0xB0, 0x64, 0x7F]),
        (0, [0x0B, 0xB9, 0x7B, 0x00]),
        (0, [0x0B, 0xB9, 0x78, 0x00]),
        (0, [0x0E, 0xE9, 0x00, 0x40]),
        (1_000, [0x0B, 0xB0, 0x4A, 0x00]),
        (1_000, [0x0B, 0xB0, 0x01, 0x00]),
        (5_000, [0x0E, 0xE0, 0x00, 0x40]),
        (5_000, [0x09, 0x90, 0x3C, 0x4A]),
        (5_000, [0x0D, 0xD0, 0x3D, 0x00]),
        (10_000, [0x0E, 0xE0, 0x00, 0x48]),
        (10_000, [0x0B, 0xB0, 0x4A, 0x20]),
        (10_000, [0x0B, 0xB0, 0x01, 0x20]),
        (15_000, [0x08, 0x80, 0x3C, 0x40]),
        (15_000, [0x0D, 0xD0, 0x00, 0x00]),
    ];
    assert_eq!(got, want);
}
