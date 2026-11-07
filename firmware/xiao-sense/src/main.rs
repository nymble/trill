// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Nymble (https://github.com/nymble)

//! Firmware for the Seeed XIAO nRF52840 **Sense** (application image for
//! the factory UF2 bootloader; see `memory.x` and docs/firmware-xiao-sense.md).
//!
//! Priorities (Cortex-M NVIC, lower number = more urgent):
//!
//! | Executor | IRQ | Prio | Tasks |
//! |---|---|---|---|
//! | high | EGU1_SWI1 | P5 | audio (debug synth block render; only with feature `pcm-synth`) |
//! | med | EGU0_SWI0 | P6 | USB device, diagnostics, MIDI writer, PCM stream (`pcm-synth`) |
//! | thread | — | lowest | IMU, Trill (blocking I²C with timeouts), LED, health |
//!
//! Sensor I/O may block for bounded time (I²C timeouts) without delaying
//! USB (or audio), because both preempt thread mode. Touch and IMU are
//! separate tasks: each hands its own timestamped samples to the event
//! engine (`instrument-events`), so either keeps working without the other.
//! The default build has no audio task and no high-priority executor.

#![no_std]
#![no_main]

#[cfg(feature = "pcm-synth")]
mod audio;
mod board;
mod crash;
mod i2c;
mod imu;
mod shared;
mod timing;
mod trill;
mod usb;

use core::sync::atomic::Ordering;

use cortex_m_rt::entry;
use embassy_executor::{Executor, InterruptExecutor};
use embassy_nrf::config::{Config as NrfConfig, HfclkSource, LfclkSource};
use embassy_nrf::gpio::{Input, Level, Output, OutputDrive, Pull};
use embassy_nrf::interrupt;
use embassy_nrf::interrupt::{InterruptExt, Priority};
use embassy_nrf::twim::{self, Twim};
use embassy_nrf::usb::vbus_detect;
use embassy_nrf::{bind_interrupts, pac, peripherals, usb as nrf_usb};
use embassy_time::{Duration, Instant, Ticker, Timer};
use static_cell::{ConstStaticCell, StaticCell};
use status_led::{Command as LedCommand, Inputs, Polarity, RgbLed, Sensor, StatusLed};

use shared::{
    set_state, SensorState, ENGINE, LAST_MOTION, LED_COLOR, LED_COMMAND, LED_INDICATION,
    MIDI_CONFIGURED, PCM_ENABLED, SAFE_MODE, STATS, TOUCH,
};

bind_interrupts!(pub struct Irqs {
    USBD => nrf_usb::InterruptHandler<peripherals::USBD>;
    CLOCK_POWER => vbus_detect::InterruptHandler;
    TWISPI0 => twim::InterruptHandler<peripherals::TWISPI0>;
    TWISPI1 => twim::InterruptHandler<peripherals::TWISPI1>;
});

#[cfg(feature = "pcm-synth")]
static EXECUTOR_HIGH: InterruptExecutor = InterruptExecutor::new();
static EXECUTOR_MED: InterruptExecutor = InterruptExecutor::new();
static EXECUTOR_LOW: StaticCell<Executor> = StaticCell::new();

#[cfg(feature = "pcm-synth")]
#[interrupt]
unsafe fn EGU1_SWI1() {
    // SAFETY: called only from this interrupt.
    unsafe { EXECUTOR_HIGH.on_interrupt() }
}

#[interrupt]
unsafe fn EGU0_SWI0() {
    // SAFETY: called only from this interrupt.
    unsafe { EXECUTOR_MED.on_interrupt() }
}

static REPORT: StaticCell<crash::BootReport> = StaticCell::new();
static TWIM_IMU_BUF: ConstStaticCell<[u8; 4]> = ConstStaticCell::new([0; 4]);
static TWIM_TRILL_BUF: ConstStaticCell<[u8; 4]> = ConstStaticCell::new([0; 4]);

type Led = RgbLed<Output<'static>, Output<'static>, Output<'static>>;

/// Status LED: samples shared state every `LED_TICK_MS`, selects an
/// indication (`status_led` priority order) and writes pins only on change.
/// Runs on the lowest-priority executor, so it can never delay audio/USB;
/// a blocking sensor I²C timeout can delay it by a few ms at most.
#[embassy_executor::task]
async fn led_task(mut led: Led, previous_crash: bool) {
    let mut ctl = StatusLed::new();
    let mut ticker = Ticker::every(Duration::from_millis(board::LED_TICK_MS));
    loop {
        let now = Instant::now().as_millis() as u32;
        if let Some(cmd) = LedCommand::from_key(LED_COMMAND.swap(0, Ordering::Relaxed)) {
            ctl.command(now, cmd);
        }
        let motion = LAST_MOTION.lock(|c| c.get());
        let r = |a: &core::sync::atomic::AtomicU32| a.load(Ordering::Relaxed);
        let sensor = |a: &core::sync::atomic::AtomicU8| match SensorState::from_u8(
            a.load(Ordering::Relaxed),
        ) {
            SensorState::Off => Sensor::Off,
            SensorState::Init => Sensor::Init,
            SensorState::Running => Sensor::Running,
            SensorState::Retry => Sensor::Retry,
            SensorState::Disabled => Sensor::Disabled,
        };
        let inputs = Inputs {
            safe_mode: SAFE_MODE.load(Ordering::Relaxed),
            previous_crash,
            imu: sensor(&STATS.imu_state),
            imu_calibrated: motion.calibrated,
            trill: sensor(&STATS.trill_state),
            audio_faults: r(&STATS.audio_late).wrapping_add(r(&STATS.audio_resyncs)),
            taps: r(&STATS.imu_taps),
            touching: TOUCH.lock(|t| t.get()).location.is_some(),
            rotation_dps: motion.rotation_dps,
            // Blue heartbeat: a host has configured the USB-MIDI function
            // (or opened the PCM debug port). Not proof an app is listening.
            usb_streaming: MIDI_CONFIGURED.load(Ordering::Relaxed)
                || PCM_ENABLED.load(Ordering::Relaxed),
        };
        let out = ctl.update(now, &inputs);
        if out.changed {
            let _ = led.set(out.color); // Infallible on nRF GPIO
        }
        LED_INDICATION.store(out.indication as u8, Ordering::Relaxed);
        LED_COLOR.store(led.color().bits(), Ordering::Relaxed);
        ticker.next().await;
    }
}

#[embassy_executor::task]
async fn health_task() {
    Timer::after_secs(30).await;
    crash::mark_healthy();
}

#[entry]
fn main() -> ! {
    let resetreas = pac::POWER.resetreas().read().0;
    // RESETREAS bits are cleared by writing 1.
    pac::POWER
        .resetreas()
        .write_value(pac::power::regs::Resetreas(resetreas));
    let report = REPORT.init(crash::take_boot_report(resetreas));
    let safe_mode = report.crashes >= crash::MAX_CRASHES;
    SAFE_MODE.store(safe_mode, Ordering::Relaxed);

    let mut cfg = NrfConfig::default();
    cfg.hfclk_source = HfclkSource::ExternalXtal; // required by USB
    cfg.lfclk_source = LfclkSource::ExternalXtal; // 32.768 kHz crystal X1
    let p = embassy_nrf::init(cfg);

    // Cycle counter for render-time measurement.
    let mut cp = cortex_m::Peripherals::take().unwrap();
    cp.DCB.enable_trace();
    cp.DWT.enable_cycle_counter();

    // Boot ID for the configuration protocol: lets a host notice a restart
    // (and that RAM-only settings went back to defaults).
    {
        let mut rng = embassy_nrf::rng::Rng::new_blocking(p.RNG);
        let mut b = [0u8; 2];
        rng.blocking_fill_bytes(&mut b);
        shared::BOOT_ID.store(u16::from_le_bytes(b) & 0x3FFF, Ordering::Relaxed);
    }

    // Event engine before any producer or consumer task starts.
    ENGINE.lock(|e| {
        *e.borrow_mut() = Some(instrument_events::Engine::new(
            instrument_events::Config::default(),
        ))
    });
    #[cfg(feature = "timing-gpio")]
    timing::init(p.P0_02, p.P0_03);

    // USB runs on the medium-priority executor; built inside its task.
    interrupt::EGU0_SWI0.set_priority(Priority::P6);
    let med = EXECUTOR_MED.start(interrupt::EGU0_SWI0);
    med.spawn(usb::usb_task(p.USBD, report).unwrap());

    // User RGB LED: common anode to 3V3, cathodes on GPIOs (active low).
    // Start high = off, so nothing lights before the LED task decides.
    let led = RgbLed::new(
        Output::new(p.P0_26, Level::High, OutputDrive::Standard),
        Output::new(p.P0_30, Level::High, OutputDrive::Standard),
        Output::new(p.P0_06, Level::High, OutputDrive::Standard),
        Polarity::ActiveLow,
    );
    let previous_crash = report.kind != 0; // last run ended in panic/HardFault

    let executor = EXECUTOR_LOW.init(Executor::new());
    if safe_mode {
        set_state(&STATS.imu_state, SensorState::Disabled);
        set_state(&STATS.trill_state, SensorState::Disabled);
        executor.run(|spawner| {
            spawner.spawn(led_task(led, previous_crash).unwrap());
            spawner.spawn(health_task().unwrap());
        });
    }

    #[cfg(feature = "pcm-synth")]
    {
        interrupt::EGU1_SWI1.set_priority(Priority::P5);
        let high = EXECUTOR_HIGH.start(interrupt::EGU1_SWI1);
        high.spawn(audio::audio_task().unwrap());
    }

    // Internal IMU bus (on-board 10 k pull-ups), 400 kHz like Zephyr's board file.
    let mut imu_cfg = twim::Config::default();
    imu_cfg.frequency = twim::Frequency::K400;
    let imu_twim = Twim::new(
        p.TWISPI1,
        Irqs,
        p.P0_07,
        p.P0_27,
        imu_cfg,
        TWIM_IMU_BUF.take(),
    );
    let imu_power = Output::new(p.P1_08, Level::Low, OutputDrive::Standard0HighDrive1);
    let imu_int1 = Input::new(p.P0_11, Pull::None);

    // External Trill bus on D4/D5; requires external pull-ups. 100 kHz as in
    // docs/design-xiao-nrf52840.md (a 21-byte status+centroid read takes ~2.3 ms).
    let mut trill_cfg = twim::Config::default();
    trill_cfg.frequency = twim::Frequency::K100;
    let trill_twim = Twim::new(
        p.TWISPI0,
        Irqs,
        p.P0_04,
        p.P0_05,
        trill_cfg,
        TWIM_TRILL_BUF.take(),
    );

    executor.run(|spawner| {
        spawner.spawn(imu::imu_task(imu_twim, imu_power, imu_int1).unwrap());
        spawner.spawn(trill::trill_task(trill_twim).unwrap());
        spawner.spawn(led_task(led, previous_crash).unwrap());
        spawner.spawn(health_task().unwrap());
    })
}
