// SPDX-License-Identifier: GPL-3.0-only
//! Optional logic-analyser timing outputs (`timing-gpio` feature, off by
//! default). Without the feature every function is an empty inline stub.
//!
//! | Pin | Header | Meaning |
//! |---|---|---|
//! | P0.02 | D0 | high while the latest *new* Trill frame had a touch (set after the I2C read completes) |
//! | P0.03 | D1 | high while a USB-MIDI packet containing a note on is being handed to the USB peripheral |
//!
//! D0/D1 have no on-board connection on the XIAO nRF52840 Sense (on-board
//! sensors use P0.07/P0.27/P0.11/P1.08 and P1.00/P0.16/P1.10; Trill uses
//! D4/D5). Only enable this if nothing external is wired to D0/D1. The
//! rising edge of D1 minus the rising edge of D0 is the firmware's
//! frame-to-USB-write time; it excludes the Trill scan/read before D0 and
//! the host's USB polling and audio path after D1.

#[cfg(feature = "timing-gpio")]
mod imp {
    use embassy_nrf::gpio::{Level, Output, OutputDrive};
    use embassy_nrf::{pac, peripherals, Peri};

    const D0: u32 = 1 << 2;
    const D1: u32 = 1 << 3;

    /// Configure D0/D1 as outputs (low) and keep them configured.
    pub fn init(d0: Peri<'static, peripherals::P0_02>, d1: Peri<'static, peripherals::P0_03>) {
        // The Output drivers stay alive for the whole run; afterwards the
        // pins are toggled with single atomic OUTSET/OUTCLR writes so any
        // task can mark events without sharing a driver object.
        core::mem::forget(Output::new(d0, Level::Low, OutputDrive::Standard));
        core::mem::forget(Output::new(d1, Level::Low, OutputDrive::Standard));
    }

    fn set(mask: u32, high: bool) {
        if high {
            pac::P0.outset().write(|w| w.0 = mask);
        } else {
            pac::P0.outclr().write(|w| w.0 = mask);
        }
    }

    /// New Trill frame processed.
    pub fn touch_frame(touching: bool) {
        set(D0, touching);
    }

    /// Note-on packet write begins (`true`) / was accepted (`false`).
    pub fn note_write(active: bool) {
        set(D1, active);
    }
}

#[cfg(not(feature = "timing-gpio"))]
mod imp {
    /// No-op.
    #[inline(always)]
    pub fn touch_frame(_touching: bool) {}
    /// No-op.
    #[inline(always)]
    pub fn note_write(_active: bool) {}
}

pub use imp::*;
