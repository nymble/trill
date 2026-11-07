// SPDX-License-Identifier: GPL-3.0-only
//! USB composite device: two CDC ACM ports.
//!
//! * Port 0 (first ttyACM / usbmodem): text diagnostics + single-key commands.
//! * Port 1: framed PCM test stream (`motion_synth::stream`), active while
//!   the host holds DTR (tools/pcm_capture.py does).
//!
//! This is not a USB Audio Class device and not a MIDI device.

use core::fmt::Write as _;
use core::sync::atomic::Ordering;

use embassy_futures::join::{join, join3};
use embassy_nrf::usb::vbus_detect::HardwareVbusDetect;
use embassy_nrf::usb::Driver;
use embassy_nrf::{peripherals, Peri};
use embassy_sync::blocking_mutex::raw::CriticalSectionRawMutex;
use embassy_sync::signal::Signal;
use embassy_time::{with_timeout, Duration, Instant, Timer};
use embassy_usb::class::cdc_acm::{CdcAcmClass, Sender, State};
use embassy_usb::{Builder, Config as UsbConfig};
use heapless::String;
use motion_synth::stream;
use static_cell::{ConstStaticCell, StaticCell};

use crate::board::*;
use crate::crash::BootReport;
use crate::shared::*;

/// Concrete driver type.
pub type UsbDriver = Driver<'static, HardwareVbusDetect>;

/// pid.codes test VID/PID: for development and testing only, never for
/// distributed hardware (https://pid.codes/1209/0001/).
pub const USB_VID: u16 = 0x1209;
/// See [`USB_VID`].
pub const USB_PID: u16 = 0x0001;
const MAX_PACKET: usize = 64;

static COMMAND: Signal<CriticalSectionRawMutex, u8> = Signal::new();

static CONFIG_DESC: ConstStaticCell<[u8; 256]> = ConstStaticCell::new([0; 256]);
static BOS_DESC: ConstStaticCell<[u8; 256]> = ConstStaticCell::new([0; 256]);
static MSOS_DESC: ConstStaticCell<[u8; 64]> = ConstStaticCell::new([0; 64]);
static CONTROL_BUF: ConstStaticCell<[u8; 64]> = ConstStaticCell::new([0; 64]);
static DIAG_STATE: StaticCell<State> = StaticCell::new();
static PCM_STATE: StaticCell<State> = StaticCell::new();

/// Build the composite device (two CDC ACM functions) and run it together
/// with the diagnostics and PCM loops. Lives on the medium-priority executor.
#[embassy_executor::task]
pub async fn usb_task(usbd: Peri<'static, peripherals::USBD>, report: &'static BootReport) {
    let driver = Driver::new(usbd, crate::Irqs, HardwareVbusDetect::new(crate::Irqs));
    let mut cfg = UsbConfig::new(USB_VID, USB_PID);
    cfg.manufacturer = Some("nymble/trill");
    cfg.product = Some("Trill XIAO Sense dev firmware");
    cfg.serial_number = None;
    cfg.max_power = 100;
    cfg.max_packet_size_0 = 64;
    let mut builder = Builder::new(
        driver,
        cfg,
        CONFIG_DESC.take(),
        BOS_DESC.take(),
        MSOS_DESC.take(),
        CONTROL_BUF.take(),
    );
    let diag = CdcAcmClass::new(
        &mut builder,
        DIAG_STATE.init(State::new()),
        MAX_PACKET as u16,
    );
    let pcm = CdcAcmClass::new(
        &mut builder,
        PCM_STATE.init(State::new()),
        MAX_PACKET as u16,
    );
    let mut dev = builder.build();
    join3(dev.run(), diag_loop(diag, report), pcm_loop(pcm)).await;
}

async fn write_all(tx: &mut Sender<'static, UsbDriver>, data: &[u8]) -> Result<(), ()> {
    let mut last_full = false;
    for chunk in data.chunks(MAX_PACKET) {
        match with_timeout(Duration::from_millis(100), tx.write_packet(chunk)).await {
            Ok(Ok(())) => last_full = chunk.len() == MAX_PACKET,
            _ => return Err(()),
        }
    }
    if last_full {
        // Zero-length packet terminates a transfer that ended on a packet boundary.
        let _ = with_timeout(Duration::from_millis(100), tx.write_packet(&[])).await;
    }
    Ok(())
}

fn status_line(out: &mut String<512>) {
    let s = &STATS;
    let r = |a: &core::sync::atomic::AtomicU32| a.load(Ordering::Relaxed);
    let m = LAST_MOTION.lock(|c| c.get());
    let (a, g) = LAST_IMU.lock(|c| c.get());
    let touch = TOUCH.lock(|c| c.get());
    let up_ms = Instant::now().as_millis();
    let _ = write!(
        out,
        "t={}.{:03}s imu={} n={} err={} e{} drdy_to={} pc={} | a=[{:.3},{:.3},{:.3}]g g=[{:.1},{:.1},{:.1}]dps pitch={:.1} roll={:.1} rot={:.0} cal={} | trill={} reads={} err={} touch={} | audio blocks={} late={} resync={} starve={} render={}us(max {}) ctl_age={}us(max {}) trig={} | pcm sent={} drop={}\r\n",
        up_ms / 1000,
        up_ms % 1000,
        SensorState::from_u8(s.imu_state.load(Ordering::Relaxed)).label(),
        r(&s.imu_samples),
        r(&s.imu_errors),
        s.imu_last_error.load(Ordering::Relaxed),
        r(&s.imu_drdy_timeouts),
        r(&s.imu_power_cycles),
        a[0], a[1], a[2], g[0], g[1], g[2],
        m.pitch_deg,
        m.roll_deg,
        m.rotation_dps,
        u8::from(m.calibrated),
        SensorState::from_u8(s.trill_state.load(Ordering::Relaxed)).label(),
        r(&s.trill_reads),
        r(&s.trill_errors),
        match touch.location {
            Some(_) => "yes",
            None => "no",
        },
        r(&s.audio_blocks),
        r(&s.audio_late),
        r(&s.audio_resyncs),
        r(&s.audio_starved),
        r(&s.audio_render_us_last),
        r(&s.audio_render_us_max),
        r(&s.control_age_us_last),
        r(&s.control_age_us_max),
        r(&s.audio_triggers),
        r(&s.pcm_sent),
        r(&s.pcm_dropped),
    );
}

const HELP: &str =
    "commands: s=status now, c=recalibrate gyro (hold still), b=boot report, v=version, h=help\r\n";

fn banner(out: &mut String<512>, report: &BootReport) {
    let _ = write!(
        out,
        "\r\ntrill xiao-sense-fw {} | {} Hz, block {} ({} us) | IMU 416 Hz | safe_mode={}\r\n",
        env!("CARGO_PKG_VERSION"),
        SAMPLE_RATE,
        BLOCK,
        BLOCK as u64 * 1_000_000 / SAMPLE_RATE as u64,
        u8::from(SAFE_MODE.load(Ordering::Relaxed)),
    );
    let _ = write!(
        out,
        "resetreas=0x{:08x} consecutive_crashes={}",
        report.resetreas, report.crashes
    );
    match report.kind {
        1 => {
            let _ = write!(out, " last=panic: {}", report.msg.as_str());
        }
        2 => {
            let _ = write!(out, " last=hardfault pc=0x{:08x}", report.pc);
        }
        _ => {}
    }
    let _ = out.push_str("\r\n");
}

async fn diag_loop(class: CdcAcmClass<'static, UsbDriver>, report: &'static BootReport) {
    let (mut tx, mut rx) = class.split();
    let reader = async {
        let mut buf = [0u8; MAX_PACKET];
        loop {
            rx.wait_connection().await;
            if let Ok(n) = rx.read_packet(&mut buf).await {
                for &b in &buf[..n] {
                    COMMAND.signal(b);
                }
            }
        }
    };
    let writer = async {
        loop {
            tx.wait_connection().await;
            let mut out: String<512> = String::new();
            banner(&mut out, report);
            let _ = out.push_str(HELP);
            if write_all(&mut tx, out.as_bytes()).await.is_err() {
                continue;
            }
            loop {
                let cmd =
                    match embassy_futures::select::select(COMMAND.wait(), Timer::after_secs(1))
                        .await
                    {
                        embassy_futures::select::Either::First(c) => Some(c),
                        embassy_futures::select::Either::Second(()) => None,
                    };
                out.clear();
                match cmd {
                    Some(b'c') => {
                        RECALIBRATE.store(true, Ordering::Relaxed);
                        let _ = out.push_str("recalibrating: keep the board still for ~1 s\r\n");
                    }
                    Some(b'b') => banner(&mut out, report),
                    Some(b'v') => {
                        let _ = write!(
                            out,
                            "xiao-sense-fw {} usb {:04x}:{:04x} (pid.codes test id)\r\n",
                            env!("CARGO_PKG_VERSION"),
                            USB_VID,
                            USB_PID
                        );
                    }
                    Some(b'h') | Some(b'?') => {
                        let _ = out.push_str(HELP);
                    }
                    Some(b'\r') | Some(b'\n') => continue,
                    Some(_) | None => status_line(&mut out),
                }
                if !tx.dtr() || write_all(&mut tx, out.as_bytes()).await.is_err() {
                    break;
                }
            }
        }
    };
    join(reader, writer).await;
}

async fn pcm_loop(class: CdcAcmClass<'static, UsbDriver>) {
    let (mut tx, _rx) = class.split();
    let mut frame = [0u8; stream::frame_len(BLOCK)];
    loop {
        tx.wait_connection().await;
        while PCM.try_receive().is_ok() {}
        PCM_ENABLED.store(true, Ordering::Relaxed);
        loop {
            let block = match with_timeout(Duration::from_millis(100), PCM.receive()).await {
                Ok(b) => b,
                Err(_) => {
                    if tx.dtr() {
                        continue;
                    }
                    break;
                }
            };
            let Some(n) = stream::encode(
                &mut frame,
                block.seq,
                SAMPLE_RATE,
                block.flags,
                &block.samples,
            ) else {
                continue;
            };
            if !tx.dtr() || write_all(&mut tx, &frame[..n]).await.is_err() {
                break;
            }
            bump(&STATS.pcm_sent);
        }
        PCM_ENABLED.store(false, Ordering::Relaxed);
        while PCM.try_receive().is_ok() {}
        Timer::after_millis(10).await;
    }
}
