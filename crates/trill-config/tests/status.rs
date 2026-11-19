// SPDX-License-Identifier: GPL-3.0-only
//! Battery and Bluetooth status (`GET_STATUS`, actions 10..=13).
use instrument_events::Config;
use trill_config::*;

const STATUS: Status = Status {
    battery: Battery::Present,
    charging: false,
    usb_power: true,
    battery_mv: 4123,
    battery_percent: Some(93),
    discoverable: true,
    ble_midi: false,
    settings_stored: true,
    link: Link::Advertising,
    off_reason: BluetoothOff::Running,
};

const BLE: DeviceInfo = DeviceInfo {
    firmware: [0, 8, 0],
    variant: VARIANT_IMU | VARIANT_BLE_MIDI | VARIANT_STATUS,
    uptime_s: 9,
    boot_id: 3,
    status: STATUS,
};

const USB_ONLY: DeviceInfo = DeviceInfo {
    variant: VARIANT_IMU | VARIANT_STATUS,
    status: Status {
        battery: Battery::Absent,
        usb_power: true,
        battery_mv: 4310,
        ..Status::NONE
    },
    ..BLE
};

fn run(msg: &[u8], info: &DeviceInfo) -> Outcome {
    handle(msg, false, &Config::default(), 0, info).unwrap()
}

#[test]
fn variant_bits_are_7_bit_and_distinct() {
    let bits = [
        VARIANT_PCM_SYNTH,
        VARIANT_IMU,
        VARIANT_MIC,
        VARIANT_MULTI_TOUCH,
        VARIANT_BLE_MIDI,
        VARIANT_STATUS,
    ];
    assert_eq!(VARIANT_STATUS, 0x20);
    let mut all = 0u8;
    for b in bits {
        assert_eq!(all & b, 0);
        assert!(b < 0x80);
        all |= b;
    }
    let o = run(&request::hello(1), &BLE);
    assert_eq!(o.reply[11], VARIANT_IMU | VARIANT_BLE_MIDI | VARIANT_STATUS);
}

#[test]
fn action_codes_are_stable_and_9_stays_unassigned() {
    for (code, a) in [
        (1, Action::Panic),
        (6, Action::EnterBootloader),
        (7, Action::StartMic),
        (8, Action::StopMic),
        (10, Action::BluetoothDiscoverableOn),
        (11, Action::BluetoothDiscoverableOff),
        (12, Action::BluetoothMidiOn),
        (13, Action::BluetoothMidiOff),
    ] {
        assert_eq!(Action::from_code(code), Some(a));
        assert_eq!(a as u8, code);
    }
    assert_eq!(Action::from_code(9), None);
    assert_eq!(Action::from_code(14), None);
    let o = run(
        &[0xF0, 0x7D, 0x54, 0x52, 0x01, 0x04, 0x05, 0x09, 0xF7],
        &BLE,
    );
    assert_eq!(
        &o.reply[5..9],
        &[msg::ERROR, 5, ErrorCode::UnknownAction as u8, 9]
    );
}

#[test]
fn status_round_trips_and_is_7_bit() {
    let samples = [
        STATUS,
        Status::NONE,
        Status {
            battery: Battery::Absent,
            charging: true,
            usb_power: true,
            battery_mv: u16::MAX,
            battery_percent: Some(100),
            discoverable: false,
            ble_midi: true,
            settings_stored: false,
            link: Link::Streaming,
            off_reason: BluetoothOff::CheckingBattery,
        },
    ];
    for s in samples {
        let p = s.encode();
        assert!(p.iter().all(|&b| b < 0x80), "{s:?}");
        let d = Status::decode(&p).unwrap();
        let mut want = s;
        want.battery_mv = want.battery_mv.min(0x3FFF);
        assert_eq!(d, want);
    }
    assert_eq!(Status::decode(&[1, 0, 0, 0, 127, 0]), None, "short");
    assert_eq!(Status::decode(&[2, 0, 0, 0, 127, 0, 0]), None, "format");
    assert_eq!(Status::decode(&[1, 0x80, 0, 0, 127, 0, 0]), None, "bit 7");
    // Percent above 100 reads as unknown.
    assert_eq!(
        Status::decode(&[1, 2, 0, 0, 101, 0, 0])
            .unwrap()
            .battery_percent,
        None
    );
}

#[test]
fn get_status_reports_the_snapshot() {
    let o = run(&request::get_status(4), &BLE);
    assert_eq!(o.action, None);
    assert_eq!(o.reply.len(), HEADER_LEN + status::STATUS_LEN + 1);
    assert_eq!(o.reply[5], msg::STATUS);
    assert_eq!(o.reply[6], 4);
    assert_eq!(
        Status::decode(&o.reply[HEADER_LEN..o.reply.len() - 1]),
        Some(STATUS)
    );
    // 4123 mV = 32 * 128 + 27.
    assert_eq!(&o.reply[9..11], &[32, 27]);
}

#[test]
fn get_status_needs_the_variant_bit_and_no_payload() {
    let old = DeviceInfo {
        variant: VARIANT_IMU,
        ..BLE
    };
    let o = run(&request::get_status(1), &old);
    assert_eq!(
        &o.reply[5..9],
        &[msg::ERROR, 1, ErrorCode::UnknownType as u8, msg::GET_STATUS]
    );
    let o = run(
        &[0xF0, 0x7D, 0x54, 0x52, 0x01, 0x07, 0x02, 0x01, 0xF7],
        &BLE,
    );
    assert_eq!(
        &o.reply[5..9],
        &[msg::ERROR, 2, ErrorCode::BadLength as u8, 1]
    );
}

#[test]
fn bluetooth_actions_reply_with_the_new_settings() {
    let cases = [
        (Action::BluetoothDiscoverableOff, false, false),
        (Action::BluetoothDiscoverableOn, true, false),
        (Action::BluetoothMidiOn, true, true),
        (Action::BluetoothMidiOff, true, false),
    ];
    for (a, discoverable, midi) in cases {
        let o = run(&request::action(7, a), &BLE);
        assert_eq!(o.action, Some(a));
        assert_eq!(o.config, None);
        assert_eq!(o.reply[5], msg::STATUS);
        let s = Status::decode(&o.reply[HEADER_LEN..o.reply.len() - 1]).unwrap();
        assert_eq!((s.discoverable, s.ble_midi), (discoverable, midi), "{a:?}");
        // Everything else is the snapshot.
        assert_eq!(s.battery_mv, STATUS.battery_mv);
        assert_eq!(s.link, STATUS.link);
    }
}

#[test]
fn bluetooth_actions_are_refused_without_bluetooth() {
    for a in [
        Action::BluetoothDiscoverableOn,
        Action::BluetoothDiscoverableOff,
        Action::BluetoothMidiOn,
        Action::BluetoothMidiOff,
    ] {
        let o = run(&request::action(2, a), &USB_ONLY);
        assert_eq!(o.action, None, "{a:?}");
        assert_eq!(
            &o.reply[5..9],
            &[msg::ERROR, 2, ErrorCode::UnknownAction as u8, a as u8]
        );
    }
    // Status still works on a USB-only build.
    let o = run(&request::get_status(3), &USB_ONLY);
    let s = Status::decode(&o.reply[HEADER_LEN..o.reply.len() - 1]).unwrap();
    assert_eq!(s.battery, Battery::Absent);
    assert_eq!(s.off_reason, BluetoothOff::NotBuilt);
}
