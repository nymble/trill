// SPDX-License-Identifier: GPL-3.0-only
//! Battery voltage, charge status and presence (every build).
//!
//! Pins (Seeed XIAO nRF52840 schematic; see `trill_board::battery` and
//! docs/battery.md):
//!
//! * P0.14 READ_BAT (active low): **driven LOW from the first lines of
//!   `main` and never released.** With P0.14 high or floating the divider
//!   is open and P0.31 can reach its 3.6 V limit while the battery
//!   charges; Seeed asks to keep P0.14 LOW whenever the battery may be
//!   charging. The divider then draws about 4.2 V / 1.51 MΩ ≈ 2.8 µA.
//! * P0.31 / AIN7: VBAT × 510 k / 1510 k, read by the SAADC once a second.
//! * P0.17 ~CHG: charger status, LOW while charging. Input without pull
//!   (the charger's open-drain output and the charge LED set the level);
//!   only meaningful with USB power.
//! * P0.13 HICHG: left as the reset-default input, so the charger keeps
//!   its 50 mA setting. Never driven by this firmware.

use core::sync::atomic::Ordering;

use embassy_futures::select::{select, Either};
use embassy_nrf::gpio::{Input, Output};
use embassy_nrf::saadc::Saadc;
use embassy_time::{Duration, Instant, Timer};
use trill_board::battery::{mv_from_adc, Detector, Observation};

use crate::shared::*;

/// Sample period.
const PERIOD: Duration = Duration::from_secs(1);
/// ~CHG edges counted per period at most; a faster toggle stops edge
/// waiting for the rest of the period so this low-priority task cannot
/// keep the thread executor busy.
const MAX_EDGES: u16 = 64;

/// Measure once a second and publish battery state. `_read_bat` is the
/// P0.14 output, held LOW for as long as the firmware runs.
#[embassy_executor::task]
pub async fn battery_task(
    mut saadc: Saadc<'static, 1>,
    mut chg: Input<'static>,
    _read_bat: Output<'static>,
) {
    saadc.calibrate().await;
    let mut detector = Detector::new();
    let mut next = Instant::now();
    loop {
        next += PERIOD;
        let mut edges: u16 = 0;
        while edges < MAX_EDGES {
            match select(chg.wait_for_any_edge(), Timer::at(next)).await {
                Either::First(()) => edges += 1,
                Either::Second(()) => break,
            }
        }
        if Instant::now() < next {
            Timer::at(next).await;
        }
        let mut buf = [0i16; 1];
        saadc.sample(&mut buf).await;
        let mv = mv_from_adc(buf[0]);
        let usb = usb_power_now();
        let charging = usb && chg.is_low();
        let before = battery_state();
        let state = detector.update(Observation {
            usb_power: usb,
            charging,
            // Without USB the charger is off and ~CHG floats: not evidence.
            chg_edges: if usb { edges } else { 0 },
            mv,
        });
        BATTERY_MV.store(mv, Ordering::Relaxed);
        BATTERY_CHARGING.store(charging, Ordering::Relaxed);
        USB_POWER.store(usb, Ordering::Relaxed);
        BATTERY_STATE.store(state as u8, Ordering::Relaxed);
        if state != before {
            BLE_WAKE.signal(());
        }
    }
}

/// USB power: from the SoftDevice's USB events when it runs (POWER is
/// its peripheral then), otherwise from POWER.USBREGSTATUS.
fn usb_power_now() -> bool {
    #[cfg(feature = "ble-midi")]
    if let Some(v) = crate::ble::usb_power() {
        return v;
    }
    embassy_nrf::pac::POWER.usbregstatus().read().vbusdetect()
}
