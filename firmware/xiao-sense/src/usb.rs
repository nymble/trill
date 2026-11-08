// SPDX-License-Identifier: GPL-3.0-only
//! USB composite device (layout and descriptors in the `trill-usb` crate,
//! checked by its host tests):
//!
//! * CDC ACM diagnostics (first ttyACM / usbmodem): text status and
//!   single-key commands.
//! * USB-MIDI 1.0 (class compliant, one virtual cable): the instrument
//!   output, produced by the `instrument-events` engine.
//! * With feature `pcm-synth` only: a second CDC ACM port carrying the
//!   framed PCM test stream of the on-board debug synth.
//!
//! This is not a USB Audio (sound card) device.

use core::fmt::Write as _;
use core::pin::pin;
use core::sync::atomic::{AtomicBool, AtomicU32, Ordering};

use embassy_futures::join::join;
use embassy_futures::select::{select, Either};
use embassy_nrf::usb::vbus_detect::HardwareVbusDetect;
use embassy_nrf::usb::Driver;
use embassy_nrf::{peripherals, Peri};
use embassy_sync::blocking_mutex::raw::CriticalSectionRawMutex;
use embassy_sync::signal::Signal;
use embassy_time::{with_timeout, Duration, Instant, Timer};
use embassy_usb::class::cdc_acm::{CdcAcmClass, Sender, State};
use embassy_usb::class::midi::MidiClass;
use embassy_usb::driver::EndpointError;
use embassy_usb::{Builder, Handler};
use heapless::String;
use instrument_events::{PitchMode, Scale};
use static_cell::{ConstStaticCell, StaticCell};
pub use trill_usb::USB_VID;

use crate::board::*;
use crate::crash::BootReport;
use crate::shared::*;

/// Concrete driver type.
pub type UsbDriver = Driver<'static, HardwareVbusDetect>;

/// pid.codes *test* PID of this build (development only; see `trill-usb`).
pub const USB_PID: u16 = trill_usb::product_id(cfg!(feature = "pcm-synth"));
const MAX_PACKET: usize = trill_usb::MAX_PACKET as usize;
/// Events per MIDI packet. 15 x 4 = 60 bytes: always a short packet, so a
/// transfer never needs a zero-length packet to terminate.
const MIDI_EVENTS_PER_PACKET: usize = 15;

static COMMAND: Signal<CriticalSectionRawMutex, u8> = Signal::new();

static CONFIG_DESC: ConstStaticCell<[u8; trill_usb::CONFIG_DESC_LEN]> =
    ConstStaticCell::new([0; trill_usb::CONFIG_DESC_LEN]);
static BOS_DESC: ConstStaticCell<[u8; trill_usb::BOS_DESC_LEN]> =
    ConstStaticCell::new([0; trill_usb::BOS_DESC_LEN]);
static MSOS_DESC: ConstStaticCell<[u8; 64]> = ConstStaticCell::new([0; 64]);
static CONTROL_BUF: ConstStaticCell<[u8; trill_usb::CONTROL_BUF_LEN]> =
    ConstStaticCell::new([0; trill_usb::CONTROL_BUF_LEN]);
static DIAG_STATE: StaticCell<State> = StaticCell::new();
#[cfg(feature = "pcm-synth")]
static PCM_STATE: StaticCell<State> = StaticCell::new();
static BUS_EVENTS: StaticCell<BusEvents> = StaticCell::new();

/// Bus-level state from embassy-usb callbacks. `USB_EPOCH` changes on every
/// reset, deconfiguration, suspend or power loss, so the MIDI writer notices
/// a disconnect even when it has nothing to send.
static USB_READY: AtomicBool = AtomicBool::new(false);
static USB_EPOCH: AtomicU32 = AtomicU32::new(0);

struct BusEvents {
    configured: bool,
    suspended: bool,
}

impl BusEvents {
    fn update(&mut self) {
        let ready = self.configured && !self.suspended;
        if !ready {
            USB_EPOCH.fetch_add(1, Ordering::Relaxed);
        }
        USB_READY.store(ready, Ordering::Relaxed);
        MIDI_WAKE.signal(());
    }
}

impl Handler for BusEvents {
    fn enabled(&mut self, enabled: bool) {
        if !enabled {
            self.configured = false;
        }
        self.update();
    }
    fn reset(&mut self) {
        self.configured = false;
        self.suspended = false;
        self.update();
    }
    fn configured(&mut self, configured: bool) {
        self.configured = configured;
        self.update();
    }
    fn suspended(&mut self, suspended: bool) {
        self.suspended = suspended;
        self.update();
    }
}

/// Build the composite device and run it with the diagnostics, MIDI and
/// (optionally) PCM loops. Lives on the medium-priority executor.
#[embassy_executor::task]
pub async fn usb_task(usbd: Peri<'static, peripherals::USBD>, report: &'static BootReport) {
    let driver = Driver::new(usbd, crate::Irqs, HardwareVbusDetect::new(crate::Irqs));
    let mut builder = Builder::new(
        driver,
        trill_usb::device_config(cfg!(feature = "pcm-synth")),
        CONFIG_DESC.take(),
        BOS_DESC.take(),
        MSOS_DESC.take(),
        CONTROL_BUF.take(),
    );
    builder.handler(BUS_EVENTS.init(BusEvents {
        configured: false,
        suspended: false,
    }));
    #[cfg(feature = "pcm-synth")]
    let pcm_state = Some(PCM_STATE.init(State::new()));
    #[cfg(not(feature = "pcm-synth"))]
    let pcm_state = None;
    let f = trill_usb::add_functions(&mut builder, DIAG_STATE.init(State::new()), pcm_state);
    let mut dev = builder.build();
    #[cfg(feature = "pcm-synth")]
    {
        let pcm = f.pcm.expect("pcm function");
        embassy_futures::join::join4(
            dev.run(),
            diag_loop(f.diag, report),
            midi_loop(f.midi),
            pcm_loop(pcm),
        )
        .await;
    }
    #[cfg(not(feature = "pcm-synth"))]
    embassy_futures::join::join3(dev.run(), diag_loop(f.diag, report), midi_loop(f.midi)).await;
}

/// A configuration reply being sent on cable 1, a few events per packet.
struct PendingReply {
    packets: [[u8; 4]; trill_config::usb::MAX_PACKETS],
    len: usize,
    next: usize,
}

impl PendingReply {
    const fn new() -> Self {
        Self {
            packets: [[0; 4]; trill_config::usb::MAX_PACKETS],
            len: 0,
            next: 0,
        }
    }
    fn is_empty(&self) -> bool {
        self.next >= self.len
    }
    /// Load the next queued reply if idle.
    fn refill(&mut self) {
        if !self.is_empty() {
            return;
        }
        if let Ok(r) = CONFIG_REPLIES.try_receive() {
            self.len =
                trill_config::usb::encode_sysex(trill_usb::CABLE_CONFIG, &r, &mut self.packets)
                    .unwrap_or(0);
            self.next = 0;
        }
    }
    /// Load a telemetry frame if idle and nothing else is queued.
    fn load_telemetry(&mut self, frame: &trill_config::Reply) -> bool {
        if !self.is_empty() || !CONFIG_REPLIES.is_empty() {
            return false;
        }
        self.len =
            trill_config::usb::encode_sysex(trill_usb::CABLE_CONFIG, frame, &mut self.packets)
                .unwrap_or(0);
        self.next = 0;
        self.len > 0
    }
    fn clear(&mut self) {
        self.len = 0;
        self.next = 0;
    }
}

/// Build one telemetry frame from the latest published sensor values.
/// Each source is read in one short critical section; nothing here blocks
/// the sensor tasks or allocates.
fn telemetry_frame(
    sched: &mut trill_config::telemetry::Schedule,
    last_imu: &mut u32,
) -> trill_config::Reply {
    use trill_config::telemetry::{self, Frame, Sample};
    let snap = SENSOR_SNAPSHOT.lock(|c| c.get());
    let touch = TOUCH.lock(|c| c.get());
    let imu_state = STATS.imu_state.load(Ordering::Relaxed);
    let trill_state = STATS.trill_state.load(Ordering::Relaxed);
    let imu_samples = STATS.imu_samples.load(Ordering::Relaxed);
    let mut f = Frame {
        seq: sched.next_seq(),
        t_ms: (snap.t_us / 1000) as u32,
        imu_state,
        trill_state,
        imu_samples: (imu_samples & 0x3FFF) as u16,
        taps: (STATS.imu_taps.load(Ordering::Relaxed) & 0x3FFF) as u16,
        calibrations: (STATS.imu_calibrations.load(Ordering::Relaxed) & 0x7F) as u8,
        skipped: sched.skipped,
        trill_frames: (STATS.trill_reads.load(Ordering::Relaxed) & 0x3FFF) as u16,
        ..Frame::default()
    };
    if snap.calibrated {
        f.flags |= telemetry::FLAG_CALIBRATED;
    }
    if imu_samples != *last_imu {
        f.flags |= telemetry::FLAG_IMU_NEW;
    }
    *last_imu = imu_samples;
    if SAFE_MODE.load(Ordering::Relaxed) {
        f.flags |= telemetry::FLAG_SAFE_MODE;
    }
    let trill_running = trill_state == SensorState::Running as u8;
    f.set_sample(
        &Sample {
            accel_g: snap.accel_g,
            gyro_dps: snap.gyro_dps,
            pitch_deg: snap.pitch_deg,
            roll_deg: snap.roll_deg,
            touch: if trill_running {
                touch.location.map(|l| (l, touch.size))
            } else {
                None
            },
        },
        imu_state == SensorState::Running as u8 && snap.t_us != 0,
    );
    bump(&STATS.telemetry_frames);
    telemetry::encode(&f)
}

/// Fill `buf` with up to `MIDI_EVENTS_PER_PACKET` USB-MIDI events: the
/// engine's instrument events (cable 0) first, then spare slots with
/// configuration-reply events (cable 1). Cables are independent streams in
/// USB-MIDI, so a reply can be interleaved with notes and never delays
/// them. Returns (bytes, contains a note on).
fn fill_packet(
    e: &mut instrument_events::Engine,
    now: u32,
    reply: &mut PendingReply,
    buf: &mut [u8; MAX_PACKET],
) -> (usize, bool) {
    let mut n = 0;
    let mut note_on = false;
    while n < MIDI_EVENTS_PER_PACKET {
        let Some(m) = e.next_message(now) else { break };
        note_on |= matches!(m, instrument_events::MidiMessage::NoteOn { .. });
        buf[4 * n..4 * n + 4].copy_from_slice(&m.usb_packet(trill_usb::CABLE_INSTRUMENT));
        n += 1;
    }
    while n < MIDI_EVENTS_PER_PACKET && !reply.is_empty() {
        buf[4 * n..4 * n + 4].copy_from_slice(&reply.packets[reply.next]);
        reply.next += 1;
        n += 1;
    }
    (4 * n, note_on)
}

/// Handle one complete SysEx message from cable 1 and queue the reply.
/// Validation happens in `trill-config`; only the listed side effects are
/// possible (no memory or pin access is reachable from a message).
async fn config_request(msg: &[u8], truncated: bool) {
    let info = trill_config::DeviceInfo {
        firmware: FW_VERSION,
        variant: if cfg!(feature = "pcm-synth") {
            trill_config::VARIANT_PCM_SYNTH
        } else {
            0
        },
        uptime_s: Instant::now().as_secs() as u32,
        boot_id: BOOT_ID.load(Ordering::Relaxed),
    };
    let outcome = with_engine(|e| {
        let gen = CONFIG_GEN.load(Ordering::Relaxed);
        let o = trill_config::handle(msg, truncated, e.config(), gen, &info)?;
        if let Some(c) = o.config {
            // Releases a sounding note, re-centres bend / resends RPN 0 if
            // needed, and waits for the finger to lift (engine contract).
            e.set_config(c);
            CONFIG_GEN.store(o.generation, Ordering::Relaxed);
        }
        Some(o)
    })
    .flatten();
    let Some(o) = outcome else {
        bump(&STATS.config_ignored);
        return;
    };
    match o.action {
        Some(trill_config::Action::Panic) => {
            MIDI_REQUEST.fetch_or(MIDI_REQ_PANIC, Ordering::Relaxed);
        }
        Some(trill_config::Action::RecalibrateGyro) => RECALIBRATE.store(true, Ordering::Relaxed),
        Some(trill_config::Action::LedSelfTest) => LED_COMMAND.store(b'L', Ordering::Relaxed),
        Some(trill_config::Action::RestoreDefaults) | None => {}
    }
    if let Some(rate) = o.telemetry {
        TELEMETRY_REQUEST.store(rate, Ordering::Relaxed);
    }
    bump(&STATS.config_requests);
    CONFIG_REPLIES.send(o.reply).await;
    MIDI_WAKE.signal(());
}

/// Firmware version for the protocol (from Cargo.toml).
const FW_VERSION: [u8; 3] = {
    const fn parse(s: &str) -> u8 {
        let b = s.as_bytes();
        let mut i = 0;
        let mut v: u32 = 0;
        while i < b.len() {
            v = v * 10 + (b[i] - b'0') as u32;
            i += 1;
        }
        if v > 127 {
            127
        } else {
            v as u8
        }
    }
    [
        parse(env!("CARGO_PKG_VERSION_MAJOR")),
        parse(env!("CARGO_PKG_VERSION_MINOR")),
        parse(env!("CARGO_PKG_VERSION_PATCH")),
    ]
};

/// Write one packet without ever abandoning it half way: a slow host only
/// delays it (counted as a stall every `MIDI_STALL_MS`); a bus disconnect
/// ends it.
async fn midi_write(
    tx: &mut embassy_usb::class::midi::Sender<'static, UsbDriver>,
    data: &[u8],
    epoch: u32,
) -> Result<(), EndpointError> {
    let mut fut = pin!(tx.write_packet(data));
    loop {
        match select(&mut fut, Timer::after_millis(MIDI_STALL_MS)).await {
            Either::First(r) => return r,
            Either::Second(()) => {
                bump(&STATS.midi_stalls);
                if USB_EPOCH.load(Ordering::Relaxed) != epoch {
                    return Err(EndpointError::Disabled);
                }
            }
        }
    }
}

async fn midi_loop(class: MidiClass<'static, UsbDriver>) {
    let (mut tx, mut rx) = class.split();
    // Host -> device: cable 1 SysEx is the configuration protocol; anything
    // else (notes, clock, cable 0) is read and discarded so the host never
    // blocks. A message is at most 64 bytes, so parsing is bounded.
    let reader = async {
        let mut buf = [0u8; MAX_PACKET];
        let mut asm = trill_config::usb::Assembler::new(trill_usb::CABLE_CONFIG);
        let mut msg = [0u8; trill_config::MAX_MESSAGE_LEN];
        loop {
            rx.wait_connection().await;
            let Ok(n) = rx.read_packet(&mut buf).await else {
                asm = trill_config::usb::Assembler::new(trill_usb::CABLE_CONFIG);
                continue;
            };
            bump(&STATS.midi_rx_packets);
            for p in buf[..n - n % 4].chunks_exact(4) {
                if let Some(c) = asm.push_packet([p[0], p[1], p[2], p[3]]) {
                    let m = asm.message(c);
                    msg[..m.len()].copy_from_slice(m);
                    config_request(&msg[..m.len()], c.truncated).await;
                }
            }
        }
    };
    let writer = async {
        let mut buf = [0u8; MAX_PACKET];
        let mut reply = PendingReply::new();
        let mut sched = trill_config::telemetry::Schedule::new();
        let mut last_imu = 0u32;
        loop {
            tx.wait_connection().await;
            if !USB_READY.load(Ordering::Relaxed) {
                // Endpoint enabled but suspended / not yet configured.
                let _ = select(MIDI_WAKE.wait(), Timer::after_millis(20)).await;
                continue;
            }
            let epoch = USB_EPOCH.load(Ordering::Relaxed);
            MIDI_CONFIGURED.store(true, Ordering::Relaxed);
            // Reset sequence (CC123, CC120, bend centre, pressure 0, RPN 0).
            with_engine(|e| e.connect(now_us32()));
            loop {
                if USB_EPOCH.load(Ordering::Relaxed) != epoch || !USB_READY.load(Ordering::Relaxed)
                {
                    break;
                }
                let now = now_us32();
                reply.refill();
                // Telemetry: lowest priority on cable 1 (after config
                // replies), and instrument events always fill the packet
                // first. A frame that cannot go out in its period is
                // skipped and counted; values are sampled when it is sent.
                let t64 = Instant::now().as_micros();
                let req = TELEMETRY_REQUEST.swap(TELEMETRY_NO_CHANGE, Ordering::Relaxed);
                if req != TELEMETRY_NO_CHANGE {
                    sched.subscribe(req, t64);
                }
                if reply.is_empty() && CONFIG_REPLIES.is_empty() && sched.due(t64) {
                    let frame = telemetry_frame(&mut sched, &mut last_imu);
                    reply.load_telemetry(&frame);
                }
                TELEMETRY_RATE.store(sched.rate_hz(), Ordering::Relaxed);
                let (n, note_on) = with_engine(|e| {
                    if MIDI_REQUEST.swap(0, Ordering::Relaxed) & MIDI_REQ_PANIC != 0 {
                        e.panic(now);
                    }
                    e.tick(now);
                    fill_packet(e, now, &mut reply, &mut buf)
                })
                .unwrap_or((0, false));
                if n == 0 {
                    let _ = select(MIDI_WAKE.wait(), Timer::after_millis(MIDI_TICK_MS)).await;
                    continue;
                }
                // `n` can be non-zero with only telemetry in it; that is a
                // normal packet on cable 1.
                if note_on {
                    crate::timing::note_write(true);
                }
                let r = midi_write(&mut tx, &buf[..n], epoch).await;
                crate::timing::note_write(false);
                if r.is_err() {
                    bump(&STATS.midi_write_errors);
                    break;
                }
                bump(&STATS.midi_packets);
                STATS
                    .midi_events
                    .fetch_add((n / 4) as u32, Ordering::Relaxed);
            }
            // Forget everything queued or sounding; on the next connection
            // the reset sequence goes out first. Notes the host was holding
            // while unplugged are the host's responsibility.
            MIDI_CONFIGURED.store(false, Ordering::Relaxed);
            with_engine(|e| e.disconnect());
            // Replies to a previous connection are meaningless now, and a
            // telemetry subscription ends with the connection.
            reply.clear();
            sched.stop();
            TELEMETRY_RATE.store(0, Ordering::Relaxed);
            TELEMETRY_REQUEST.store(TELEMETRY_NO_CHANGE, Ordering::Relaxed);
            while CONFIG_REPLIES.try_receive().is_ok() {}
        }
    };
    join(reader, writer).await;
}

/// Diagnostics output buffer size.
const OUT_LEN: usize = 768;

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

fn status_line(out: &mut String<OUT_LEN>) {
    let s = &STATS;
    let r = |a: &core::sync::atomic::AtomicU32| a.load(Ordering::Relaxed);
    let m = LAST_MOTION.lock(|c| c.get());
    let (a, g) = LAST_IMU.lock(|c| c.get());
    let touch = TOUCH.lock(|c| c.get());
    let up_ms = Instant::now().as_millis();
    let _ = write!(
        out,
        "t={}.{:03}s imu={} n={} err={} e{} drdy_to={} pc={} | a=[{:.3},{:.3},{:.3}]g g=[{:.1},{:.1},{:.1}]dps pitch={:.1} roll={:.1} rot={:.0} cal={} | trill={} reads={} err={} stale={} touch={}",
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
        r(&s.trill_stale_frames),
        match touch.location {
            Some(_) => "yes",
            None => "no",
        },
    );
    midi_summary(out);
    #[cfg(feature = "pcm-synth")]
    let _ = write!(
        out,
        " | audio blocks={} late={} resync={} starve={} render={}us(max {}) ctl_age={}us(max {}) trig={} | pcm sent={} drop={}",
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
    let _ = write!(
        out,
        " | taps={} led={}/{}\r\n",
        r(&s.imu_taps),
        status_led::Indication::from_u8(LED_INDICATION.load(Ordering::Relaxed))
            .map_or("?", |i| i.name()),
        status_led::Color::from_bits(LED_COLOR.load(Ordering::Relaxed)).name(),
    );
}

/// One-line MIDI summary appended to the status line.
fn midi_summary(out: &mut String<OUT_LEN>) {
    let r = |a: &AtomicU32| a.load(Ordering::Relaxed);
    let (note, st) = with_engine(|e| (e.active_note(), e.stats())).unwrap_or_default();
    let _ = write!(
        out,
        " | midi={} note={} on={} off={} pk={} ev={} stall={} werr={} defer={} coal={} cfg={}/{} gen={} tlm={}Hz/{}",
        if MIDI_CONFIGURED.load(Ordering::Relaxed) {
            "up"
        } else {
            "down"
        },
        note.map_or(-1, i16::from),
        st.note_on,
        st.note_off,
        r(&STATS.midi_packets),
        r(&STATS.midi_events),
        r(&STATS.midi_stalls),
        r(&STATS.midi_write_errors),
        st.note_on_deferred,
        st.control_coalesced,
        r(&STATS.config_requests),
        r(&STATS.config_ignored),
        CONFIG_GEN.load(Ordering::Relaxed),
        TELEMETRY_RATE.load(Ordering::Relaxed),
        r(&STATS.telemetry_frames),
    );
}

/// Full MIDI report (`m`): configuration and all engine counters.
fn midi_report(out: &mut String<OUT_LEN>) {
    let Some((c, st, armed, q)) =
        with_engine(|e| (*e.config(), e.stats(), e.is_armed(), e.critical_len()))
    else {
        return;
    };
    let _ = write!(
        out,
        "midi: usb {:04x}:{:04x} {} | ch={} base={} range={:.0}st scale={} pitch={} bend=+-{}st | pressure=contact size (not force) | motion_cc={} (CC74 rot, CC1 tilt) | tap_perc={} (ch {} note {})\r\n",
        USB_VID,
        USB_PID,
        if MIDI_CONFIGURED.load(Ordering::Relaxed) {
            "configured"
        } else {
            "not configured"
        },
        c.channel + 1,
        c.base_note,
        c.range_semitones,
        match c.scale {
            Scale::Chromatic => "chromatic",
            Scale::Pentatonic => "pentatonic",
        },
        match c.pitch_mode {
            PitchMode::Bend => "bend",
            PitchMode::Steps => "steps",
        },
        c.bend_range_semitones,
        u8::from(c.motion_enabled),
        u8::from(c.percussion_enabled),
        c.percussion_channel + 1,
        c.percussion_note,
    );
    let _ = write!(
        out,
        "midi: armed={} queue={} hw={} on={} off={} defer={} emerg_off={} ctl_sent={} coal={} invalid={} stale_in={} touch_to={} touch_lost={} motion_lost={} taps={} conn={} disc={} | rx_pk={}\r\n",
        u8::from(armed),
        q,
        st.critical_high_water,
        st.note_on,
        st.note_off,
        st.note_on_deferred,
        st.emergency_all_notes_off,
        st.control_sent,
        st.control_coalesced,
        st.invalid_inputs,
        st.stale_inputs,
        st.touch_timeouts,
        st.touch_lost,
        st.motion_lost,
        st.taps,
        st.connects,
        st.disconnects,
        STATS.midi_rx_packets.load(Ordering::Relaxed),
    );
}

/// Apply a mapping change from a diagnostics key; returns a description.
fn midi_key(k: u8) -> Option<&'static str> {
    with_engine(|e| {
        let mut c = *e.config();
        let msg = match k {
            b'k' => {
                c.pitch_mode = match c.pitch_mode {
                    PitchMode::Bend => PitchMode::Steps,
                    PitchMode::Steps => PitchMode::Bend,
                };
                "midi: pitch mode toggled (note released; lift finger to play)"
            }
            b'q' => {
                c.scale = match c.scale {
                    Scale::Chromatic => Scale::Pentatonic,
                    Scale::Pentatonic => Scale::Chromatic,
                };
                "midi: scale toggled (note released; lift finger to play)"
            }
            b't' => {
                c.percussion_enabled = !c.percussion_enabled;
                "midi: tap percussion toggled"
            }
            b'x' => {
                c.motion_enabled = !c.motion_enabled;
                "midi: motion controllers toggled"
            }
            _ => return None,
        };
        if c != *e.config() {
            e.set_config(c);
            bump_config_generation();
        }
        Some(msg)
    })
    .flatten()
}

const HELP: &str = "commands: s=status now, m=MIDI map+counters, p=MIDI panic (CC123/CC120/bend centre), c=recalibrate gyro (hold still), b=boot report, v=version, h=help\r\n\
     midi map: k=bend/steps, q=chromatic/pentatonic, t=tap percussion on/off, x=motion CCs on/off (RAM only, not persisted)\r\n\
     led: L=self-test, 0-7=manual colour (0 off 1 red 2 green 3 yellow 4 blue 5 magenta 6 cyan 7 white; 60 s), a=automatic\r\n";

fn banner(out: &mut String<OUT_LEN>, report: &BootReport) {
    let _ = write!(
        out,
        "\r\ntrill xiao-sense-fw {} | usb {:04x}:{:04x} (pid.codes test id) | {} | config: SysEx v1 on MIDI cable 1 (2nd port), RAM only | IMU 416 Hz ODR | Trill {} bit, poll {} ms | safe_mode={}\r\n",
        env!("CARGO_PKG_VERSION"),
        USB_VID,
        USB_PID,
        if cfg!(feature = "pcm-synth") {
            "MIDI + diag + PCM debug synth"
        } else {
            "MIDI + diag"
        },
        TRILL_SCAN_BITS,
        TRILL_POLL_MS,
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
            let mut out: String<OUT_LEN> = String::new();
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
                    Some(b'm') => midi_report(&mut out),
                    Some(b'p') => {
                        MIDI_REQUEST.fetch_or(MIDI_REQ_PANIC, Ordering::Relaxed);
                        MIDI_WAKE.signal(());
                        let _ = out.push_str(if MIDI_CONFIGURED.load(Ordering::Relaxed) {
                            "midi: panic sent (CC123, CC120, bend centre, pressure 0, RPN 0); lift finger to play\r\n"
                        } else {
                            "midi: not configured by a host; nothing sent\r\n"
                        });
                    }
                    Some(k @ (b'k' | b'q' | b't' | b'x')) => {
                        if let Some(msg) = midi_key(k) {
                            let _ = out.push_str(msg);
                            let _ = out.push_str("\r\n");
                        }
                        midi_report(&mut out);
                    }
                    Some(b'v') => {
                        let _ = write!(
                            out,
                            "xiao-sense-fw {} usb {:04x}:{:04x} (pid.codes test id, development only)\r\n",
                            env!("CARGO_PKG_VERSION"),
                            USB_VID,
                            USB_PID
                        );
                    }
                    Some(k) if status_led::Command::from_key(k).is_some() => {
                        LED_COMMAND.store(k, Ordering::Relaxed);
                        match status_led::Command::from_key(k) {
                            Some(status_led::Command::Auto) => {
                                let _ = out.push_str("led: automatic\r\n");
                            }
                            Some(status_led::Command::SelfTest) => {
                                let _ = out
                                    .push_str("led: self-test R G B Y C M W off, 400 ms each\r\n");
                            }
                            Some(status_led::Command::Manual(c)) => {
                                let _ = write!(
                                    out,
                                    "led: manual {} for 60 s ('a' = automatic)\r\n",
                                    c.name()
                                );
                            }
                            None => {}
                        }
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

#[cfg(feature = "pcm-synth")]
async fn pcm_loop(class: CdcAcmClass<'static, UsbDriver>) {
    use motion_synth::stream;
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
