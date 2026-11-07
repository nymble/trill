// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Nymble (https://github.com/nymble)

//! Firmware for the Seeed XIAO nRF52840 **Sense** (application image for
//! the factory UF2 bootloader; see `memory.x` and docs/firmware-xiao-sense.md).
//!
//! Priorities (Cortex-M NVIC, lower number = more urgent):
//!
//! | Executor | IRQ | Prio | Tasks |
//! |---|---|---|---|
//! | high | EGU1_SWI1 | P5 | audio (block render, fixed deadline) |
//! | med | EGU0_SWI0 | P6 | USB device, diagnostics, PCM stream |
//! | thread | — | lowest | IMU, Trill (blocking I²C with timeouts), LED, health |
//!
//! Sensor I/O may block for bounded time (I²C timeouts) without delaying
//! audio or USB, because both preempt thread mode.

#![no_std]
#![no_main]

mod audio;
mod board;
mod crash;
mod i2c;
mod imu;
mod shared;
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
use embassy_time::Timer;
use static_cell::{ConstStaticCell, StaticCell};

use shared::{set_state, SensorState, SAFE_MODE, STATS};

bind_interrupts!(pub struct Irqs {
    USBD => nrf_usb::InterruptHandler<peripherals::USBD>;
    CLOCK_POWER => vbus_detect::InterruptHandler;
    TWISPI0 => twim::InterruptHandler<peripherals::TWISPI0>;
    TWISPI1 => twim::InterruptHandler<peripherals::TWISPI1>;
});

static EXECUTOR_HIGH: InterruptExecutor = InterruptExecutor::new();
static EXECUTOR_MED: InterruptExecutor = InterruptExecutor::new();
static EXECUTOR_LOW: StaticCell<Executor> = StaticCell::new();

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

#[embassy_executor::task]
async fn led_task(mut green: Output<'static>, mut red: Output<'static>) {
    // Active-low LEDs. Normal: green 1 Hz blink. Safe mode: red fast blink.
    let safe = SAFE_MODE.load(Ordering::Relaxed);
    let led = if safe { &mut red } else { &mut green };
    let (on, off) = if safe { (100, 100) } else { (50, 950) };
    loop {
        led.set_low();
        Timer::after_millis(on).await;
        led.set_high();
        Timer::after_millis(off).await;
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

    // USB runs on the medium-priority executor; built inside its task.
    interrupt::EGU0_SWI0.set_priority(Priority::P6);
    let med = EXECUTOR_MED.start(interrupt::EGU0_SWI0);
    med.spawn(usb::usb_task(p.USBD, report).unwrap());

    let green = Output::new(p.P0_30, Level::High, OutputDrive::Standard);
    let red = Output::new(p.P0_26, Level::High, OutputDrive::Standard);

    let executor = EXECUTOR_LOW.init(Executor::new());
    if safe_mode {
        set_state(&STATS.imu_state, SensorState::Disabled);
        set_state(&STATS.trill_state, SensorState::Disabled);
        executor.run(|spawner| {
            spawner.spawn(led_task(green, red).unwrap());
            spawner.spawn(health_task().unwrap());
        });
    }

    interrupt::EGU1_SWI1.set_priority(Priority::P5);
    let high = EXECUTOR_HIGH.start(interrupt::EGU1_SWI1);
    high.spawn(audio::audio_task().unwrap());

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
    // docs/design-xiao-nrf52840.md (a 20-byte centroid read takes ~2.3 ms).
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
        spawner.spawn(led_task(green, red).unwrap());
        spawner.spawn(health_task().unwrap());
    })
}
