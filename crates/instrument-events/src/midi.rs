// SPDX-License-Identifier: GPL-3.0-only
//! MIDI 1.0 channel-voice messages and USB-MIDI 1.0 event packets.
//!
//! USB-MIDI 1.0 (USB Device Class Definition for MIDI Devices 1.0, §4) carries
//! each MIDI message in a 32-bit packet: byte 0 = `cable << 4 | CIN`, then up
//! to three MIDI bytes, zero padded. For channel-voice messages the Code Index
//! Number equals the status nibble (`0x8` note off, `0x9` note on, `0xB`
//! control change, `0xD` channel pressure, `0xE` pitch bend).

/// Pitch-bend centre (no bend), 14-bit.
pub const BEND_CENTER: u16 = 8192;
/// Largest 14-bit pitch-bend value.
pub const BEND_MAX: u16 = 16383;

/// Controller numbers used by the engine.
pub mod cc {
    /// Modulation wheel (MSB).
    pub const MODULATION: u8 = 1;
    /// Data entry MSB (RPN value).
    pub const DATA_ENTRY_MSB: u8 = 6;
    /// Data entry LSB (RPN value).
    pub const DATA_ENTRY_LSB: u8 = 38;
    /// Sound controller 5, "brightness" / filter cutoff by convention.
    pub const BRIGHTNESS: u8 = 74;
    /// RPN LSB.
    pub const RPN_LSB: u8 = 100;
    /// RPN MSB.
    pub const RPN_MSB: u8 = 101;
    /// Channel mode: All Sound Off.
    pub const ALL_SOUND_OFF: u8 = 120;
    /// Channel mode: All Notes Off.
    pub const ALL_NOTES_OFF: u8 = 123;
}

/// One MIDI 1.0 channel-voice message. Channels are 0-based (`0` = MIDI
/// channel 1). Out-of-range data is masked/clamped when encoded, so an encoded
/// data byte is always `<= 127`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MidiMessage {
    /// Note off.
    NoteOff {
        /// Channel 0..=15.
        channel: u8,
        /// Note number 0..=127.
        note: u8,
        /// Release velocity 0..=127.
        velocity: u8,
    },
    /// Note on. The engine never emits velocity 0 (which means note off).
    NoteOn {
        /// Channel 0..=15.
        channel: u8,
        /// Note number 0..=127.
        note: u8,
        /// Velocity 1..=127.
        velocity: u8,
    },
    /// Control change.
    ControlChange {
        /// Channel 0..=15.
        channel: u8,
        /// Controller 0..=127.
        control: u8,
        /// Value 0..=127.
        value: u8,
    },
    /// Channel pressure (aftertouch).
    ChannelPressure {
        /// Channel 0..=15.
        channel: u8,
        /// Value 0..=127.
        value: u8,
    },
    /// Pitch bend, 14-bit, [`BEND_CENTER`] = no bend.
    PitchBend {
        /// Channel 0..=15.
        channel: u8,
        /// Value 0..=16383.
        value: u16,
    },
}

impl MidiMessage {
    /// Status byte (with channel).
    pub fn status(&self) -> u8 {
        let (kind, ch) = match *self {
            Self::NoteOff { channel, .. } => (0x80, channel),
            Self::NoteOn { channel, .. } => (0x90, channel),
            Self::ControlChange { channel, .. } => (0xB0, channel),
            Self::ChannelPressure { channel, .. } => (0xD0, channel),
            Self::PitchBend { channel, .. } => (0xE0, channel),
        };
        kind | (ch & 0x0F)
    }

    /// True for note on / note off.
    pub fn is_note(&self) -> bool {
        matches!(self, Self::NoteOn { .. } | Self::NoteOff { .. })
    }

    /// MIDI 1.0 wire bytes (running status not used). Returns the bytes and
    /// the length (2 or 3).
    pub fn to_bytes(&self) -> ([u8; 3], usize) {
        let s = self.status();
        match *self {
            Self::NoteOff { note, velocity, .. } | Self::NoteOn { note, velocity, .. } => {
                ([s, note & 0x7F, velocity & 0x7F], 3)
            }
            Self::ControlChange { control, value, .. } => ([s, control & 0x7F, value & 0x7F], 3),
            Self::ChannelPressure { value, .. } => ([s, value & 0x7F, 0], 2),
            Self::PitchBend { value, .. } => {
                let v = value.min(BEND_MAX);
                ([s, (v & 0x7F) as u8, ((v >> 7) & 0x7F) as u8], 3)
            }
        }
    }

    /// USB-MIDI 1.0 Code Index Number for this message.
    pub fn code_index(&self) -> u8 {
        self.status() >> 4
    }

    /// USB-MIDI 1.0 event packet on virtual cable `cable` (0..=15).
    pub fn usb_packet(&self, cable: u8) -> [u8; 4] {
        let (b, _) = self.to_bytes();
        [((cable & 0x0F) << 4) | self.code_index(), b[0], b[1], b[2]]
    }
}

/// Decode one USB-MIDI 1.0 channel-voice event packet (for tests and host
/// tools). Returns `None` for other CINs.
pub fn decode_usb_packet(p: [u8; 4]) -> Option<(u8, MidiMessage)> {
    let cable = p[0] >> 4;
    let cin = p[0] & 0x0F;
    if cin != p[1] >> 4 {
        return None;
    }
    let channel = p[1] & 0x0F;
    let m = match cin {
        0x8 => MidiMessage::NoteOff {
            channel,
            note: p[2],
            velocity: p[3],
        },
        0x9 => MidiMessage::NoteOn {
            channel,
            note: p[2],
            velocity: p[3],
        },
        0xB => MidiMessage::ControlChange {
            channel,
            control: p[2],
            value: p[3],
        },
        0xD => MidiMessage::ChannelPressure {
            channel,
            value: p[2],
        },
        0xE => MidiMessage::PitchBend {
            channel,
            value: (p[2] as u16) | ((p[3] as u16) << 7),
        },
        _ => return None,
    };
    Some((cable, m))
}
