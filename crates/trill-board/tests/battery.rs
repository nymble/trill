// SPDX-License-Identifier: GPL-3.0-only
use trill_board::battery::*;
use trill_config::Battery;

#[test]
fn adc_to_millivolts_uses_the_1m_510k_divider() {
    assert_eq!(mv_from_adc(0), 0);
    assert_eq!(mv_from_adc(-5), 0);
    // Full scale on the pin (3.6 V) is 3.6 × 1510 / 510 = 10.66 V.
    assert_eq!(mv_from_adc(4096), 10_659);
    // 4.20 V cell -> pin 1.4185 V -> code 1614.
    let code = (4_200u64 * 510 * 4096 / 1510 / 3600) as i16;
    assert!((mv_from_adc(code) as i32 - 4_200).abs() <= 3);
    // 3.70 V cell.
    let code = (3_700u64 * 510 * 4096 / 1510 / 3600) as i16;
    assert!((mv_from_adc(code) as i32 - 3_700).abs() <= 3);
    // Large codes do not overflow (u64 maths).
    assert_eq!(mv_from_adc(i16::MAX), u16::MAX, "saturates");
}

#[test]
fn lipo_curve_is_monotonic_and_bounded() {
    for w in LIPO_CURVE.windows(2) {
        assert!(w[0].0 < w[1].0 && w[0].1 < w[1].1);
    }
    assert_eq!(percent_from_mv(0), 0);
    assert_eq!(percent_from_mv(3_300), 0);
    assert_eq!(percent_from_mv(4_180), 100);
    assert_eq!(percent_from_mv(4_300), 100);
    assert_eq!(percent_from_mv(3_840), 50);
    assert_eq!(percent_from_mv(3_870), 55);
    let mut last = 0;
    for mv in (3_000..4_400).step_by(5) {
        let p = percent_from_mv(mv);
        assert!(p >= last && p <= 100, "{mv}");
        last = p;
    }
}

fn obs(usb: bool, charging: bool, edges: u16, mv: u16) -> Observation {
    Observation {
        usb_power: usb,
        charging,
        chg_edges: edges,
        mv,
    }
}

#[test]
fn on_battery_power_a_cell_is_present_at_once() {
    let mut d = Detector::new();
    assert_eq!(d.state(), Battery::Unknown);
    assert_eq!(d.update(obs(false, false, 0, 3_900)), Battery::Present);
}

#[test]
fn on_usb_a_steady_charging_cell_is_present_after_the_window() {
    let mut d = Detector::new();
    for i in 0..WINDOW - 1 {
        assert_eq!(
            d.update(obs(true, true, 0, 3_950 + i as u16)),
            Battery::Unknown,
            "{i}"
        );
    }
    assert_eq!(d.update(obs(true, true, 0, 3_960)), Battery::Present);
}

#[test]
fn on_usb_a_full_cell_not_charging_is_present() {
    let mut d = Detector::new();
    for _ in 0..WINDOW {
        d.update(obs(true, false, 0, 4_170));
    }
    assert_eq!(d.state(), Battery::Present);
}

#[test]
fn charger_cycling_without_a_cell_is_absent_quickly() {
    let mut d = Detector::new();
    assert_eq!(d.update(obs(true, false, 2, 4_200)), Battery::Unknown);
    assert_eq!(d.update(obs(true, true, 3, 4_100)), Battery::Absent);
}

#[test]
fn rippling_or_out_of_range_voltage_is_absent() {
    let mut d = Detector::new();
    for i in 0..WINDOW {
        d.update(obs(true, false, 0, if i % 2 == 0 { 3_900 } else { 4_200 }));
    }
    assert_eq!(d.state(), Battery::Absent);
    let mut d = Detector::new();
    assert_eq!(d.update(obs(true, false, 0, 4_500)), Battery::Absent);
    let mut d = Detector::new();
    assert_eq!(d.update(obs(true, false, 0, 100)), Battery::Absent);
}

#[test]
fn a_single_odd_sample_does_not_flip_the_judgement() {
    let mut d = Detector::new();
    for _ in 0..WINDOW {
        d.update(obs(true, true, 0, 4_000));
    }
    assert_eq!(d.state(), Battery::Present);
    // One out-of-range reading, then normal again: stays present.
    assert_eq!(d.update(obs(true, true, 0, 4_400)), Battery::Present);
    assert_eq!(d.update(obs(true, true, 0, 4_000)), Battery::Present);
    // The cell is removed: the charger starts cycling. Absent after the
    // confirmation streak.
    let mut state = Battery::Present;
    for _ in 0..CONFIRM + 1 {
        state = d.update(obs(true, false, 3, 4_200));
    }
    assert_eq!(state, Battery::Absent);
}

#[test]
fn unplugging_usb_is_judged_immediately() {
    let mut d = Detector::new();
    for _ in 0..WINDOW {
        d.update(obs(true, false, 0, 4_450));
    }
    assert_eq!(d.state(), Battery::Absent);
    // Still running without USB: it must be a battery.
    assert_eq!(d.update(obs(false, false, 0, 4_100)), Battery::Present);
}
