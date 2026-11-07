// SPDX-License-Identifier: GPL-3.0-only
use super::*;
use embedded_hal_mock::eh1::digital::{Mock as PinMock, State, Transaction as T};

fn ready() -> Inputs {
    Inputs {
        imu: Sensor::Running,
        imu_calibrated: true,
        ..Inputs::default()
    }
}

fn pick(inp: &Inputs) -> Indication {
    let mut s = StatusLed::new();
    s.update(0, inp);
    s.update(10, inp).indication
}

#[test]
fn color_bits_round_trip() {
    for b in 0..8 {
        assert_eq!(Color::from_bits(b).bits(), b);
    }
    assert_eq!(Color::Yellow.channels(), (true, true, false));
    assert_eq!(Color::Cyan.channels(), (false, true, true));
    assert_eq!(Color::from_bits(0xF9), Color::Red);
}

#[test]
fn indication_u8_round_trip() {
    for v in 0..=13u8 {
        assert_eq!(Indication::from_u8(v).unwrap() as u8, v);
    }
    assert_eq!(Indication::from_u8(14), None);
}

#[test]
fn pattern_timing() {
    let p = Pattern::blink(Color::Green, 50, 1000);
    assert_eq!(p.color_at(0), Color::Green);
    assert_eq!(p.color_at(49), Color::Green);
    assert_eq!(p.color_at(50), Color::Off);
    assert_eq!(p.color_at(999), Color::Off);
    assert_eq!(p.color_at(1000), Color::Green);
    assert_eq!(Pattern::solid(Color::Blue).color_at(u32::MAX), Color::Blue);
}

#[test]
fn priority_faults_beat_activity() {
    let busy = Inputs {
        touching: true,
        rotation_dps: 500.0,
        usb_streaming: true,
        ..ready()
    };
    assert_eq!(pick(&busy), Indication::Touch);
    assert_eq!(
        pick(&Inputs {
            safe_mode: true,
            imu: Sensor::Disabled,
            ..busy
        }),
        Indication::SafeMode
    );
    assert_eq!(
        pick(&Inputs {
            imu: Sensor::Retry,
            ..busy
        }),
        Indication::ImuFault
    );
    assert_eq!(
        pick(&Inputs {
            previous_crash: true,
            ..busy
        }),
        Indication::PreviousCrash
    );
}

#[test]
fn priority_activity_and_idle() {
    assert_eq!(pick(&ready()), Indication::Ready);
    assert_eq!(
        pick(&Inputs {
            usb_streaming: true,
            ..ready()
        }),
        Indication::ReadyStreaming
    );
    assert_eq!(
        pick(&Inputs {
            rotation_dps: 61.0,
            usb_streaming: true,
            ..ready()
        }),
        Indication::Motion
    );
    assert_eq!(
        pick(&Inputs {
            rotation_dps: 59.0,
            ..ready()
        }),
        Indication::Ready
    );
    assert_eq!(
        pick(&Inputs {
            imu_calibrated: false,
            touching: true,
            ..ready()
        }),
        Indication::Calibrating
    );
    assert_eq!(pick(&Inputs::default()), Indication::Booting);
    assert_eq!(
        pick(&Inputs {
            imu: Sensor::Init,
            ..Inputs::default()
        }),
        Indication::Booting
    );
}

#[test]
fn imu_lost_after_running_is_fault_not_booting() {
    let mut s = StatusLed::new();
    s.update(0, &ready());
    let re_init = Inputs {
        imu: Sensor::Init,
        ..ready()
    };
    assert_eq!(s.update(20, &re_init).indication, Indication::ImuFault);
}

#[test]
fn trill_absent_is_silent_but_loss_is_shown() {
    let absent = Inputs {
        trill: Sensor::Retry,
        ..ready()
    };
    assert_eq!(pick(&absent), Indication::Ready);
    let mut s = StatusLed::new();
    s.update(
        0,
        &Inputs {
            trill: Sensor::Running,
            ..ready()
        },
    );
    assert_eq!(s.update(20, &absent).indication, Indication::TrillLost);
}

#[test]
fn audio_fault_held_then_cleared() {
    let mut s = StatusLed::new();
    let mut inp = Inputs {
        audio_faults: 5,
        ..ready()
    };
    // Baseline: an already non-zero counter at start is not an event.
    assert_eq!(s.update(0, &inp).indication, Indication::Ready);
    inp.audio_faults = 6;
    inp.touching = true;
    assert_eq!(s.update(20, &inp).indication, Indication::AudioFault);
    assert_eq!(
        s.update(20 + AUDIO_FAULT_HOLD_MS - 1, &inp).indication,
        Indication::AudioFault
    );
    assert_eq!(
        s.update(20 + AUDIO_FAULT_HOLD_MS, &inp).indication,
        Indication::Touch
    );
}

#[test]
fn tap_flash() {
    let mut s = StatusLed::new();
    let mut inp = ready();
    s.update(0, &inp);
    inp.taps = 1;
    let o = s.update(20, &inp);
    assert_eq!((o.indication, o.color), (Indication::Tap, Color::White));
    assert_eq!(
        s.update(20 + TAP_FLASH_MS, &inp).indication,
        Indication::Ready
    );
}

#[test]
fn previous_crash_only_first_seconds() {
    let mut s = StatusLed::new();
    let inp = Inputs {
        previous_crash: true,
        ..ready()
    };
    assert_eq!(s.update(1000, &inp).indication, Indication::PreviousCrash);
    assert_eq!(
        s.update(1000 + PREVIOUS_CRASH_MS - 1, &inp).indication,
        Indication::PreviousCrash
    );
    assert_eq!(
        s.update(1000 + PREVIOUS_CRASH_MS, &inp).indication,
        Indication::Ready
    );
    // Latched: not shown again later in the same run.
    assert_eq!(s.update(999, &inp).indication, Indication::Ready);
}

#[test]
fn blink_starts_on_and_reports_changes() {
    let mut s = StatusLed::new();
    let o = s.update(5, &ready());
    assert_eq!((o.color, o.changed), (Color::Green, true));
    let o = s.update(25, &ready());
    assert_eq!((o.color, o.changed), (Color::Green, false));
    let o = s.update(55, &ready());
    assert_eq!((o.color, o.changed), (Color::Off, true));
    let o = s.update(1005, &ready());
    assert_eq!((o.color, o.changed), (Color::Green, true));
}

#[test]
fn blink_phase_continuous_across_u32_wrap() {
    let mut s = StatusLed::new();
    let inp = ready();
    // Start so that the counter wraps mid-run; 20 ms tick for ~4 s.
    let start = u32::MAX - 1_999;
    let mut t = start;
    let mut ons = 0;
    let mut prev = Color::Off;
    for _ in 0..200 {
        let o = s.update(t, &inp);
        let elapsed = t.wrapping_sub(start);
        let expect = if elapsed % 1000 < 50 {
            Color::Green
        } else {
            Color::Off
        };
        assert_eq!(o.color, expect, "elapsed {elapsed}");
        if o.color == Color::Green && prev == Color::Off {
            ons += 1;
        }
        prev = o.color;
        t = t.wrapping_add(20);
    }
    assert_eq!(ons, 4);
}

#[test]
fn holds_survive_wrap() {
    let mut s = StatusLed::new();
    let mut inp = ready();
    s.update(u32::MAX - 10, &inp);
    inp.audio_faults = 1;
    assert_eq!(
        s.update(u32::MAX - 5, &inp).indication,
        Indication::AudioFault
    );
    assert_eq!(s.update(100, &inp).indication, Indication::AudioFault);
    assert_eq!(
        s.update(AUDIO_FAULT_HOLD_MS, &inp).indication,
        Indication::Ready
    );
}

#[test]
fn commands() {
    assert_eq!(Command::from_key(b'a'), Some(Command::Auto));
    assert_eq!(Command::from_key(b'0'), Some(Command::Manual(Color::Off)));
    assert_eq!(
        Command::from_key(b'3'),
        Some(Command::Manual(Color::Yellow))
    );
    assert_eq!(Command::from_key(b'7'), Some(Command::Manual(Color::White)));
    assert_eq!(Command::from_key(b'8'), None);
    assert_eq!(Command::from_key(b'L'), Some(Command::SelfTest));
    assert_eq!(Command::from_key(b's'), None);
    assert_eq!(Command::from_key(b'c'), None);
}

#[test]
fn manual_override_and_timeout() {
    let mut s = StatusLed::new();
    let inp = Inputs {
        safe_mode: true,
        ..ready()
    };
    s.update(0, &inp);
    s.command(100, Command::Manual(Color::Cyan));
    assert!(s.overridden());
    let o = s.update(120, &inp);
    assert_eq!((o.indication, o.color), (Indication::Manual, Color::Cyan));
    assert_eq!(
        s.update(100 + MANUAL_TIMEOUT_MS, &inp).indication,
        Indication::SafeMode
    );
    assert!(!s.overridden());
    s.command(200_000, Command::Manual(Color::Off));
    assert_eq!(s.update(200_020, &inp).color, Color::Off);
    s.command(200_040, Command::Auto);
    assert_eq!(s.update(200_060, &inp).indication, Indication::SafeMode);
}

#[test]
fn self_test_sequence_then_auto() {
    let mut s = StatusLed::new();
    s.update(0, &ready());
    s.command(1000, Command::SelfTest);
    for (i, &c) in SELF_TEST.iter().enumerate() {
        let t = 1000 + i as u32 * SELF_TEST_STEP_MS + 10;
        let o = s.update(t, &ready());
        assert_eq!((o.indication, o.color), (Indication::SelfTest, c));
    }
    let end = 1000 + SELF_TEST.len() as u32 * SELF_TEST_STEP_MS;
    assert_eq!(s.update(end, &ready()).indication, Indication::Ready);
    assert!(!s.overridden());
}

#[test]
fn rgb_led_active_low_writes_only_changes() {
    let r = PinMock::new(&[T::set(State::Low), T::set(State::High)]);
    let g = PinMock::new(&[T::set(State::Low)]);
    let b = PinMock::new(&[]);
    let mut led = RgbLed::new(r, g, b, Polarity::ActiveLow);
    led.set(Color::Yellow).unwrap(); // r low, g low
    led.set(Color::Yellow).unwrap(); // no writes
    led.set(Color::Green).unwrap(); // r high
    assert_eq!(led.color(), Color::Green);
    let (mut r, mut g, mut b) = led.release();
    r.done();
    g.done();
    b.done();
}

#[test]
fn rgb_led_active_high() {
    let r = PinMock::new(&[]);
    let g = PinMock::new(&[]);
    let b = PinMock::new(&[T::set(State::High), T::set(State::Low)]);
    let mut led = RgbLed::new(r, g, b, Polarity::ActiveHigh);
    led.set(Color::Blue).unwrap();
    led.set(Color::Off).unwrap();
    let (mut r, mut g, mut b) = led.release();
    r.done();
    g.done();
    b.done();
}
