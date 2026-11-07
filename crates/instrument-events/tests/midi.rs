// SPDX-License-Identifier: GPL-3.0-only
use instrument_events::midi::{decode_usb_packet, MidiMessage, BEND_CENTER, BEND_MAX};

#[test]
fn usb_packet_headers_cin_and_cable() {
    let cases = [
        (
            MidiMessage::NoteOn {
                channel: 0,
                note: 60,
                velocity: 100,
            },
            [0x09, 0x90, 60, 100],
        ),
        (
            MidiMessage::NoteOff {
                channel: 3,
                note: 61,
                velocity: 64,
            },
            [0x08, 0x83, 61, 64],
        ),
        (
            MidiMessage::ControlChange {
                channel: 15,
                control: 74,
                value: 127,
            },
            [0x0B, 0xBF, 74, 127],
        ),
        (
            MidiMessage::ChannelPressure {
                channel: 1,
                value: 90,
            },
            [0x0D, 0xD1, 90, 0],
        ),
        (
            MidiMessage::PitchBend {
                channel: 0,
                value: BEND_CENTER,
            },
            [0x0E, 0xE0, 0x00, 0x40],
        ),
    ];
    for (m, want) in cases {
        assert_eq!(m.usb_packet(0), want, "{m:?}");
        assert_eq!(decode_usb_packet(want), Some((0, m)));
    }
    let p = MidiMessage::NoteOn {
        channel: 0,
        note: 1,
        velocity: 1,
    }
    .usb_packet(5);
    assert_eq!(p[0], 0x59);
}

#[test]
fn pitch_bend_is_lsb_first_14_bit() {
    for (v, lsb, msb) in [
        (0u16, 0u8, 0u8),
        (1, 1, 0),
        (127, 127, 0),
        (128, 0, 1),
        (8191, 127, 63),
        (8192, 0, 64),
        (BEND_MAX, 127, 127),
    ] {
        let (b, n) = MidiMessage::PitchBend {
            channel: 2,
            value: v,
        }
        .to_bytes();
        assert_eq!(n, 3);
        assert_eq!(b, [0xE2, lsb, msb], "value {v}");
    }
    // Out of range saturates instead of wrapping.
    let (b, _) = MidiMessage::PitchBend {
        channel: 0,
        value: u16::MAX,
    }
    .to_bytes();
    assert_eq!(&b[1..], &[127, 127]);
}

#[test]
fn data_bytes_never_exceed_127_and_channel_is_masked() {
    let ms = [
        MidiMessage::NoteOn {
            channel: 0xFF,
            note: 0xFF,
            velocity: 0xFF,
        },
        MidiMessage::NoteOff {
            channel: 0xFF,
            note: 200,
            velocity: 200,
        },
        MidiMessage::ControlChange {
            channel: 16,
            control: 200,
            value: 255,
        },
        MidiMessage::ChannelPressure {
            channel: 99,
            value: 255,
        },
    ];
    for m in ms {
        let (b, n) = m.to_bytes();
        assert!(b[0] & 0x80 != 0);
        for &d in &b[1..n] {
            assert!(d <= 127, "{m:?}");
        }
        let p = m.usb_packet(0);
        assert_eq!(p[0] & 0x0F, p[1] >> 4);
    }
    assert_eq!(
        MidiMessage::ChannelPressure {
            channel: 0,
            value: 1
        }
        .to_bytes()
        .1,
        2
    );
}
