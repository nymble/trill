// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Nymble (https://github.com/nymble)

//! Protocol tests against the byte sequences described in the Trill datasheet
//! (Rev C v1.3, section 7). No hardware required.

use embedded_hal::i2c::{ErrorKind, ErrorType, I2c, Operation};
use embedded_hal_mock::eh1::delay::NoopDelay;
use embedded_hal_mock::eh1::i2c::{Mock as I2cMock, Transaction as T};
use trill_driver::{
    noise_threshold_counts, Config, Device, Error, Mode, Speed, Trill, DEFAULT_FLEX_ADDRESS,
};

const A: u8 = DEFAULT_FLEX_ADDRESS;

fn ack() -> T {
    T::read(A, vec![0xFE])
}

#[test]
fn init_flex_fw3_exact_bytes() {
    let mut payload = vec![0xFF; 20];
    // touch 0: location 1856 (0x0740), size 600 (0x0258)
    payload[0] = 0x07;
    payload[1] = 0x40;
    payload[10] = 0x02;
    payload[11] = 0x58;
    let expectations = [
        T::write(A, vec![0, 0xFF]),
        T::read(A, vec![0xFE, 6, 3]),
        T::write(A, vec![0, 1, 0]), // Mode = Centroid
        ack(),
        T::write(A, vec![0, 3, 4]), // Prescaler = 4
        ack(),
        T::write(A, vec![0, 2, 0, 12]), // ScanSettings ultra-fast, 12 bit
        ack(),
        T::write(A, vec![0, 4, 123]), // NoiseThreshold 0.03 * 4096
        ack(),
        T::write(A, vec![0, 6]), // UpdateBaseline
        ack(),
        T::write(A, vec![4]), // move read pointer to payload
        T::read(A, payload.clone()),
        T::read(A, payload), // pointer cached: no second offset write
    ];
    let mut i2c = I2cMock::new(&expectations);
    let mut delay = NoopDelay::new();
    let mut trill = Trill::new(i2c.clone(), A);
    let id = trill
        .init(
            &mut delay,
            Some(Device::Flex),
            &Config::for_device(Device::Flex),
        )
        .unwrap();
    assert_eq!(id.device, Device::Flex);
    assert_eq!(id.firmware, 3);
    for _ in 0..2 {
        let t = trill.read_touches(&mut delay).unwrap();
        assert_eq!(t.len(), 1);
        assert_eq!(t.as_slice()[0].location, 1856);
        assert_eq!(t.as_slice()[0].size, 600);
        assert_eq!(t.as_slice()[0].normalised(Device::Flex), Some(0.5));
    }
    i2c.done();
}

#[test]
fn wrong_device_is_reported() {
    let expectations = [T::write(A, vec![0, 0xFF]), T::read(A, vec![0xFE, 1, 3])];
    let mut i2c = I2cMock::new(&expectations);
    let mut trill = Trill::new(i2c.clone(), A);
    let err = trill
        .init(
            &mut NoopDelay::new(),
            Some(Device::Flex),
            &Config::for_device(Device::Flex),
        )
        .unwrap_err();
    assert_eq!(
        err,
        Error::WrongDevice {
            expected: Device::Flex,
            found: Device::Bar
        }
    );
    i2c.done();
}

#[test]
fn diff_mode_reads_60_bytes_for_flex() {
    let mut raw = Vec::new();
    for ch in 0u16..30 {
        raw.extend_from_slice(&(ch * 10).to_be_bytes());
    }
    let expectations = [
        T::write(A, vec![0, 0xFF]),
        T::read(A, vec![0xFE, 6, 3]),
        T::write(A, vec![0, 1, 3]), // Mode = Diff
        ack(),
        T::write(A, vec![4]),
        T::read(A, raw),
    ];
    let mut i2c = I2cMock::new(&expectations);
    let mut d = NoopDelay::new();
    let mut trill = Trill::new(i2c.clone(), A);
    trill.identify(&mut d).unwrap();
    trill.set_mode(&mut d, Mode::Diff).unwrap();
    let ch = trill.read_channels(&mut d).unwrap();
    assert_eq!(ch.as_slice().len(), 30);
    assert_eq!(ch.as_slice()[29], 290);
    assert!(matches!(
        trill.read_touches(&mut d),
        Err(Error::WrongMode {
            current: Mode::Diff
        })
    ));
    i2c.done();
}

#[test]
fn invalid_arguments_do_not_touch_the_bus() {
    let mut i2c = I2cMock::new(&[]);
    let mut d = NoopDelay::new();
    let mut trill = Trill::new(i2c.clone(), A);
    assert!(matches!(
        trill.set_prescaler(&mut d, 9),
        Err(Error::InvalidArgument(_))
    ));
    assert!(matches!(
        trill.set_scan_settings(&mut d, Speed::Slow, 17),
        Err(Error::InvalidArgument(_))
    ));
    assert!(matches!(
        trill.read_touches(&mut d),
        Err(Error::NotIdentified)
    ));
    i2c.done();
}

#[test]
fn threshold_conversion() {
    assert_eq!(noise_threshold_counts(0.03, 12), 123);
    assert_eq!(noise_threshold_counts(40.0 / 4096.0, 12), 40);
    assert_eq!(noise_threshold_counts(1.0, 16), 255);
    assert_eq!(noise_threshold_counts(-1.0, 12), 0);
    assert_eq!(noise_threshold_counts(f32::NAN, 12), 0);
}

// ---------------------------------------------------------------------------
// Behavioural fake: models the shared memory and delayed acknowledgement.

struct FakeTrill {
    mem: Vec<u8>,
    offset: usize,
    device: u8,
    firmware: u8,
    /// Number of reads at offset 0 before the ACK appears.
    ack_after_reads: u32,
    pending: u32,
    commands: Vec<Vec<u8>>,
    reads: u32,
    /// Only acknowledge Identify, never other commands.
    ack_identify_only: bool,
}

impl Default for FakeTrill {
    fn default() -> Self {
        Self {
            mem: vec![0; 64],
            offset: 0,
            device: 0,
            firmware: 0,
            ack_after_reads: 0,
            pending: 0,
            commands: Vec::new(),
            reads: 0,
            ack_identify_only: false,
        }
    }
}

impl ErrorType for FakeTrill {
    type Error = ErrorKind;
}

impl I2c for FakeTrill {
    fn transaction(&mut self, address: u8, ops: &mut [Operation<'_>]) -> Result<(), ErrorKind> {
        if address != A {
            return Err(ErrorKind::NoAcknowledge(
                embedded_hal::i2c::NoAcknowledgeSource::Address,
            ));
        }
        for op in ops {
            match op {
                Operation::Write(bytes) => {
                    self.offset = bytes[0] as usize;
                    if self.offset == 0 && bytes.len() > 1 {
                        self.commands.push(bytes[1..].to_vec());
                        self.mem[0..3].copy_from_slice(&[bytes[1], 0, 0]);
                        self.pending = self.ack_after_reads;
                    }
                }
                Operation::Read(buf) => {
                    self.reads += 1;
                    if self.offset == 0 && self.firmware >= 3 {
                        let cmd = self.commands.last().map(|c| c[0]).unwrap_or(0);
                        if self.ack_identify_only && cmd != 0xFF {
                            // never acknowledge
                        } else if self.pending == 0 {
                            self.mem[0] = 0xFE;
                            if cmd == 0xFF {
                                self.mem[1] = self.device;
                                self.mem[2] = self.firmware;
                            }
                        } else {
                            self.pending -= 1;
                        }
                    }
                    let end = (self.offset + buf.len()).min(64);
                    let n = end - self.offset;
                    buf[..n].copy_from_slice(&self.mem[self.offset..end]);
                }
            }
        }
        Ok(())
    }
}

#[test]
fn ack_polling_waits_for_slow_sensor() {
    let fake = FakeTrill {
        device: 6,
        firmware: 3,
        ack_after_reads: 3,
        ..Default::default()
    };
    let mut trill = Trill::new(fake, A);
    let mut d = NoopDelay::new();
    let id = trill.identify(&mut d).unwrap();
    assert_eq!(id.device, Device::Flex);
    trill.update_baseline(&mut d).unwrap();
    let fake = trill.release();
    assert_eq!(fake.commands, vec![vec![0xFF], vec![6]]);
}

#[test]
fn never_acknowledged_command_times_out() {
    let fake = FakeTrill {
        device: 6,
        firmware: 3,
        ack_identify_only: true,
        ..Default::default()
    };
    let mut trill = Trill::new(fake, A);
    let mut d = NoopDelay::new();
    trill.identify(&mut d).unwrap();
    assert_eq!(
        trill.set_mode(&mut d, Mode::Diff),
        Err(Error::NoAck { command: 1 })
    );
    // Mode is not updated when the command fails.
    assert_eq!(trill.mode(), Mode::Centroid);
    // Polling is bounded: 1+2+4+8+16+32+64+64+64 ms >= 200 ms budget -> 9 reads.
    let fake = trill.release();
    assert_eq!(fake.reads, 1 + 9);
}

#[test]
fn absent_identify_response_is_not_detected() {
    let fake = FakeTrill {
        device: 0,
        firmware: 0,
        ..Default::default()
    };
    let mut trill = Trill::new(fake, A);
    assert_eq!(
        trill.identify(&mut NoopDelay::new()),
        Err(Error::NotDetected)
    );
}

#[test]
fn absent_device_is_an_i2c_error() {
    let fake = FakeTrill::default();
    let mut trill = Trill::new(fake, 0x49);
    let err = trill.identify(&mut NoopDelay::new()).unwrap_err();
    assert!(matches!(err, Error::I2c(ErrorKind::NoAcknowledge(_))));
}

#[test]
fn legacy_firmware_without_ack_is_accepted() {
    // Firmware 2 never writes 0xFE; Identify data is accepted after the budget.
    let mut fake = FakeTrill {
        device: 6,
        firmware: 2,
        ..Default::default()
    };
    fake.mem[0..3].copy_from_slice(&[0, 6, 2]);
    struct Legacy(FakeTrill);
    impl ErrorType for Legacy {
        type Error = ErrorKind;
    }
    impl I2c for Legacy {
        fn transaction(&mut self, a: u8, ops: &mut [Operation<'_>]) -> Result<(), ErrorKind> {
            self.0.transaction(a, ops)?;
            // Legacy firmware leaves [x, type, fw] in the command region.
            self.0.mem[0..3].copy_from_slice(&[0, self.0.device, self.0.firmware]);
            Ok(())
        }
    }
    let mut trill = Trill::new(Legacy(fake), A);
    let mut d = NoopDelay::new();
    let id = trill.identify(&mut d).unwrap();
    assert_eq!(id.firmware, 2);
    // Commands on legacy firmware use a fixed delay and no ACK reads.
    trill.set_mode(&mut d, Mode::Diff).unwrap();
    assert!(matches!(
        trill.read_status(&mut d),
        Err(Error::FirmwareTooOld {
            required: 3,
            found: 2
        })
    ));
}

#[test]
fn read_frame_includes_status_in_one_transaction() {
    let mut frame = vec![0xFF; 21];
    frame[0] = 0x80 | 0x40 | 17; // initialised, activity, frame 17
    frame[1] = 0x07;
    frame[2] = 0x40;
    frame[11] = 0x02;
    frame[12] = 0x58;
    let mut next = frame.clone();
    next[0] = 0x80 | 18;
    let expectations = [
        T::write(A, vec![0, 0xFF]),
        T::read(A, vec![0xFE, 6, 3]),
        T::write(A, vec![0, 1, 0]),
        ack(),
        T::write(A, vec![0, 3, 4]),
        ack(),
        T::write(A, vec![0, 2, 0, 10]), // ultra-fast, 10 bit
        ack(),
        T::write(A, vec![0, 4, 31]), // 0.03 * 1024 rounded
        ack(),
        T::write(A, vec![0, 6]),
        ack(),
        T::write(A, vec![3]), // read pointer at the status byte
        T::read(A, frame),
        T::read(A, next), // cached pointer: one read per frame
    ];
    let mut i2c = I2cMock::new(&expectations);
    let mut delay = NoopDelay::new();
    let mut trill = Trill::new(i2c.clone(), A);
    let mut cfg = Config::for_device(Device::Flex);
    cfg.bits = 10;
    cfg.noise_threshold = noise_threshold_counts(0.03, 10);
    trill.init(&mut delay, Some(Device::Flex), &cfg).unwrap();
    let (st, t) = trill.read_frame(&mut delay).unwrap();
    assert_eq!(st.frame_id(), 17);
    assert!(st.activity() && st.initialised());
    assert_eq!(t.as_slice()[0].location, 1856);
    assert_eq!(t.as_slice()[0].size, 600);
    let (st, t) = trill.read_frame(&mut delay).unwrap();
    assert_eq!(st.frame_id(), 18);
    assert!(!st.activity());
    assert_eq!(t.len(), 1);
    i2c.done();
}
