// SPDX-License-Identifier: GPL-3.0-only
//! Long-runtime timing, tilt modes, configurable controllers and flicks.

use instrument_events::{
    Axis, CcMap, CcSource, Config, Engine, MidiMessage, Mode, MotionSample, TouchSample,
};

fn m(pitch: f32, roll: f32) -> MotionSample {
    MotionSample {
        calibrated: true,
        pitch_deg: pitch,
        roll_deg: roll,
        ..Default::default()
    }
}

fn drain(e: &mut Engine, now: u32) -> Vec<MidiMessage> {
    let mut v = Vec::new();
    while let Some(x) = e.next_message(now) {
        v.push(x);
    }
    v
}

fn notes_on(v: &[MidiMessage]) -> Vec<(u8, u8)> {
    v.iter()
        .filter_map(|x| match *x {
            MidiMessage::NoteOn { channel, note, .. } => Some((channel, note)),
            _ => None,
        })
        .collect()
}

fn notes_off(v: &[MidiMessage]) -> Vec<(u8, u8)> {
    v.iter()
        .filter_map(|x| match *x {
            MidiMessage::NoteOff { channel, note, .. } => Some((channel, note)),
            _ => None,
        })
        .collect()
}

fn ccs(v: &[MidiMessage], control: u8) -> Vec<u8> {
    v.iter()
        .filter_map(|x| match *x {
            MidiMessage::ControlChange {
                control: c, value, ..
            } if c == control => Some(value),
            _ => None,
        })
        .collect()
}

/// Connected engine, calibrated, drained, started at `t0`.
fn running(cfg: Config, t0: u32) -> Engine {
    let mut e = Engine::new(cfg);
    e.connect(t0);
    e.motion(t0, m(0.0, 0.0));
    drain(&mut e, t0);
    e
}

const MIN: u32 = 60_000_000;

/// Run still motion every 10 ms from `from` for `dur` µs (wrapping clock).
fn still(e: &mut Engine, from: u32, dur: u32) -> u32 {
    let mut t = from;
    let mut elapsed = 0u32;
    while elapsed < dur {
        t = t.wrapping_add(10_000);
        elapsed += 10_000;
        e.motion(t, m(0.0, 0.0));
        e.tick(t);
        let _ = drain(e, t);
    }
    t
}

fn tap(e: &mut Engine, t: u32) -> Vec<MidiMessage> {
    e.motion(
        t,
        MotionSample {
            calibrated: true,
            tap: Some(1.0),
            ..Default::default()
        },
    );
    drain(e, t)
}

#[test]
fn taps_play_across_35_8_and_71_6_minutes_and_the_clock_wrap() {
    let cfg = Config {
        percussion_enabled: true,
        ..Config::default()
    };
    // Start 10 minutes before the u32 µs clock wraps.
    let t0 = u32::MAX - 10 * MIN;
    let mut e = running(cfg, t0);
    let mut t = still(&mut e, t0, 2_000_000);
    let mut done: u64 = 2_000_000;
    assert_eq!(notes_on(&tap(&mut e, t.wrapping_add(1))), vec![(9, 39)]);
    // 35.8 min (2^31 µs) is where the old signed comparison flipped; 71.6
    // min (2^32 µs) is a full cycle of the u32 clock.
    let cases = [
        ("after wrap", 12u64),
        ("37 min", 37),
        ("60 min", 60),
        ("72 min", 72),
        ("100 min", 100),
        ("150 min", 150),
    ];
    for (label, until_min) in cases {
        let target = until_min * u64::from(MIN);
        let step = u32::try_from(target - done).unwrap();
        t = still(&mut e, t, step);
        done = target;
        let out = tap(&mut e, t.wrapping_add(1));
        assert_eq!(notes_on(&out), vec![(9, 39)], "{label}");
    }
    assert_eq!(e.stats().stale_inputs, 0);
}

#[test]
fn controllers_still_update_after_a_long_idle_period() {
    let mut e = running(Config::default(), 0);
    e.motion(10_000, m(30.0, 0.0));
    let v = drain(&mut e, 10_000);
    assert_eq!(ccs(&v, 1), vec![64]); // 30/60 deg → 63.5 → 64
                                      // Same tilt for 40 minutes: nothing to send.
    let mut t = 10_000u32;
    for _ in 0..(40 * 60 * 10) {
        t = t.wrapping_add(100_000);
        e.motion(t, m(30.0, 0.0));
        e.tick(t);
        assert!(drain(&mut e, t).is_empty());
    }
    e.motion(t + 10, m(60.0, 0.0));
    assert_eq!(ccs(&drain(&mut e, t + 10), 1), vec![127]);
}

#[test]
fn touch_resumes_after_a_long_sensor_outage() {
    let mut e = Engine::new(Config::default());
    e.connect(0);
    e.touch(0, None);
    drain(&mut e, 0);
    // No touch frames for 40 minutes (Trill unplugged), then it comes back.
    let t = 40 * MIN;
    e.touch(t, None);
    e.touch(
        t + 5_000,
        Some(TouchSample {
            location: 0.5,
            size: 0.3,
        }),
    );
    assert_eq!(notes_on(&drain(&mut e, t + 5_000)), vec![(0, 60)]);
    assert_eq!(e.stats().stale_inputs, 0);
    // A genuinely backwards sample is still rejected.
    e.touch(t + 4_000, None);
    assert_eq!(e.stats().stale_inputs, 1);
}

fn tilt_cfg(mode: Mode) -> Config {
    Config {
        mode,
        motion_enabled: false,
        scale: instrument_events::Scale::Chromatic,
        range_semitones: 24.0,
        tilt_span_deg: 45.0,
        gate_deg: 15.0,
        ..Config::default()
    }
}

#[test]
fn tilt_notes_gate_quantise_hysteresis_and_release() {
    let mut e = running(tilt_cfg(Mode::TiltNotes), 0);
    // Level: no note. Roll 0 = middle of the span = 12 semitones up.
    e.motion(1_000, m(0.0, 0.0));
    assert!(drain(&mut e, 1_000).is_empty());
    e.motion(2_000, m(14.0, 0.0));
    assert!(notes_on(&drain(&mut e, 2_000)).is_empty(), "below the gate");
    e.motion(3_000, m(16.0, 0.0));
    let v = drain(&mut e, 3_000);
    assert_eq!(notes_on(&v), vec![(0, 60)]);
    assert!(v
        .iter()
        .any(|x| matches!(x, MidiMessage::ChannelPressure { .. })));
    // Trill touch is ignored in tilt modes.
    e.touch(3_500, None);
    assert!(drain(&mut e, 3_500).is_empty());
    // Roll by 1 semitone's worth (45/12 = 3.75 deg): within hysteresis at
    // 0.6 semitone, switches at 0.75.
    e.motion(4_000, m(16.0, 0.6 * 3.75));
    assert!(notes_on(&drain(&mut e, 4_000)).is_empty());
    e.motion(5_000, m(16.0, 0.75 * 3.75));
    let v = drain(&mut e, 5_000);
    assert_eq!(notes_off(&v), vec![(0, 60)]);
    assert_eq!(notes_on(&v), vec![(0, 61)]);
    // Gate hysteresis: 13 deg keeps it, 11.9 closes.
    e.motion(6_000, m(13.0, 0.75 * 3.75));
    assert!(notes_off(&drain(&mut e, 6_000)).is_empty());
    e.motion(7_000, m(11.9, 0.75 * 3.75));
    assert_eq!(notes_off(&drain(&mut e, 7_000)), vec![(0, 61)]);
}

#[test]
fn tilt_note_released_on_calibration_loss_mode_change_and_disconnect() {
    for case in 0..3 {
        let mut e = running(tilt_cfg(Mode::TiltNotes), 0);
        e.motion(1_000, m(0.0, 0.0));
        e.motion(2_000, m(20.0, -45.0));
        assert_eq!(notes_on(&drain(&mut e, 2_000)), vec![(0, 48)]);
        match case {
            0 => e.motion(
                3_000,
                MotionSample {
                    calibrated: false,
                    pitch_deg: 20.0,
                    ..Default::default()
                },
            ),
            1 => e.set_config(Config::default()),
            _ => e.motion_lost(3_000),
        }
        let v = drain(&mut e, 3_000);
        assert_eq!(notes_off(&v), vec![(0, 48)], "case {case}");
        // Still tilted: no new note until the gate closes again.
        e.motion(4_000, m(20.0, -45.0));
        e.tick(4_000);
        assert!(notes_on(&drain(&mut e, 4_000)).is_empty(), "case {case}");
    }
}

#[test]
fn theremin_bends_continuously_and_sends_expression() {
    let cfg = Config {
        expression_cc: 11,
        ..tilt_cfg(Mode::Theremin)
    };
    let mut e = running(cfg, 0);
    e.motion(1_000, m(0.0, 0.0));
    e.motion(2_000, m(20.0, 1.0));
    let v = drain(&mut e, 2_000);
    // 12 + 1/3.75 = 12.27 semitones → note 60 plus a small upward bend.
    assert_eq!(notes_on(&v), vec![(0, 60)]);
    let bend = |v: &[MidiMessage]| {
        v.iter()
            .filter_map(|x| match *x {
                MidiMessage::PitchBend { value, .. } => Some(value),
                _ => None,
            })
            .next_back()
    };
    let b0 = bend(&v).unwrap();
    assert!(b0 > 8192 && b0 < 8192 + 200, "{b0}");
    assert!(!ccs(&v, 11).is_empty());
    // Rolling further bends without retriggering.
    e.motion(10_000, m(20.0, 10.0));
    let v = drain(&mut e, 10_000);
    assert!(notes_on(&v).is_empty());
    let b1 = bend(&v).unwrap();
    // (10 - 1) deg = 2.4 semitones of a ±24 range.
    assert!(
        (i32::from(b1) - i32::from(b0) - 819).abs() < 20,
        "{b0} {b1}"
    );
    // Closing the gate releases the note and sends expression 0.
    e.motion(20_000, m(0.0, 10.0));
    let v = drain(&mut e, 20_000);
    assert_eq!(notes_off(&v), vec![(0, 60)]);
    assert_eq!(ccs(&v, 11).last(), Some(&0));
}

#[test]
fn configurable_controllers_deadzone_inversion_and_no_stuck_values() {
    let cfg = Config {
        cc_a: CcMap {
            source: CcSource::RollCentered,
            control: 10,
        },
        cc_b: CcMap {
            source: CcSource::PitchBack,
            control: 2,
        },
        cc_deadzone: 0.1,
        ..Config::default()
    };
    let mut e = running(cfg, 0);
    e.motion(10_000, m(-30.0, 3.0));
    let v = drain(&mut e, 10_000);
    // Inside the deadzone: stays at the centre (64) already sent.
    assert!(ccs(&v, 10).is_empty());
    // pitch −30 of 60 → 0.5 → (0.5-0.1)/0.9 = 0.444 → 56
    assert_eq!(ccs(&v, 2), vec![56]);
    e.motion(20_000, m(-30.0, -60.0));
    assert_eq!(ccs(&drain(&mut e, 20_000), 10), vec![0]);
    // Moving CC 2 to CC 3 first returns CC 2 to 0.
    let mut c2 = cfg;
    c2.cc_b.control = 3;
    e.set_config(c2);
    let v = drain(&mut e, 30_000);
    assert_eq!(ccs(&v, 2), vec![0]);
    e.motion(40_000, m(-30.0, -60.0));
    assert_eq!(ccs(&drain(&mut e, 40_000), 3), vec![56]);
    // Turning motion controllers off returns them to 0.
    let mut c3 = c2;
    c3.motion_enabled = false;
    e.set_config(c3);
    let v = drain(&mut e, 50_000);
    assert_eq!(ccs(&v, 3), vec![0]);
}

#[test]
fn smoothing_bounds_latency() {
    let cfg = Config {
        cc_smoothing_us: 50_000,
        ..Config::default()
    };
    let mut e = running(cfg, 0);
    let mut t = 0;
    e.motion(t, m(0.0, 0.0));
    drain(&mut e, t);
    let mut last = 0;
    for _ in 0..100 {
        t += 2_400;
        e.motion(t, m(60.0, 0.0));
        if let Some(&v) = ccs(&drain(&mut e, t), 1).last() {
            last = v;
        }
        if t == 50_400 {
            // One time constant: ~63 % of the step.
            assert!((70..=90).contains(&last), "{last}");
        }
    }
    assert!(last >= 126, "{last}");
}

fn gyro_z(w: f32) -> MotionSample {
    MotionSample {
        calibrated: true,
        gyro_dps: [0.0, 0.0, w],
        ..Default::default()
    }
}

/// Feed a z-rate profile sampled every 2.4 ms from `t`; returns note ons.
fn profile(e: &mut Engine, t: &mut u32, rates: &[(f32, u32)]) -> Vec<(u8, u8)> {
    let mut on = Vec::new();
    for &(w, ms) in rates {
        let end = *t + ms * 1000;
        while *t < end {
            *t += 2_400;
            e.motion(*t, gyro_z(w));
            e.tick(*t);
            on.extend(notes_on(&drain(e, *t)));
        }
    }
    on
}

#[test]
fn flicks_cooldown_and_zigzag() {
    let cfg = Config {
        gesture_axis: Some(Axis::Z),
        motion_enabled: false,
        ..Config::default()
    };
    let mut e = running(cfg, 0);
    let mut t = 0;
    profile(&mut e, &mut t, &[(0.0, 1_100)]); // calibration arm time
                                              // Below threshold: nothing.
    assert!(profile(&mut e, &mut t, &[(350.0, 50), (0.0, 400)]).is_empty());
    // Positive flick then its quick return swing (inside the cooldown).
    let on = profile(
        &mut e,
        &mut t,
        &[(600.0, 40), (0.0, 20), (-500.0, 40), (0.0, 800)],
    );
    assert_eq!(on, vec![(9, 61)]);
    // Negative flick, then a positive one 350 ms later → flick + zig-zag.
    let on = profile(
        &mut e,
        &mut t,
        &[(-600.0, 40), (0.0, 310), (600.0, 40), (0.0, 1_000)],
    );
    assert_eq!(on, vec![(9, 60), (9, 61), (9, 62)]);
    // Every gesture note is released.
    assert_eq!(e.stats().note_on, e.stats().note_off);
    // Holding a rotation above threshold fires once, not repeatedly.
    let on = profile(&mut e, &mut t, &[(800.0, 2_000), (0.0, 500)]);
    assert_eq!(on, vec![(9, 61)]);
}

#[test]
fn gestures_and_tilt_modes_are_off_by_default() {
    let mut e = running(Config::default(), 0);
    let mut t = 0;
    profile(&mut e, &mut t, &[(0.0, 1_100)]);
    assert!(profile(&mut e, &mut t, &[(900.0, 50), (0.0, 400), (-900.0, 50)]).is_empty());
    e.motion(t + 1, m(40.0, 0.0));
    assert!(notes_on(&drain(&mut e, t + 1)).is_empty());
}

#[test]
fn zero_orientation_rebases_pitch_and_roll() {
    let cfg = Config {
        cc_a: CcMap {
            source: CcSource::RollCentered,
            control: 10,
        },
        ..Config::default()
    };
    let mut e = running(cfg, 0);
    e.motion(10_000, m(10.0, -82.0));
    drain(&mut e, 10_000);
    assert!(e.zero_orientation());
    e.motion(20_000, m(10.0, -82.0));
    let v = drain(&mut e, 20_000);
    assert_eq!(ccs(&v, 10), vec![64]);
    assert_eq!(ccs(&v, 1), vec![0]);
    // Roll wraps: −82 → +178 is −100 relative, clamped to full left.
    e.motion(30_000, m(10.0, 178.0));
    assert_eq!(ccs(&drain(&mut e, 30_000), 10), vec![0]);
}
