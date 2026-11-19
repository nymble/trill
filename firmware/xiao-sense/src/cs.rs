// SPDX-License-Identifier: GPL-3.0-only
//! Single-core critical section (PRIMASK) for builds without the
//! SoftDevice. With `ble-midi`, nrf-softdevice provides the implementation
//! instead: it masks application interrupts only, so the SoftDevice's
//! radio timing is never delayed.

struct SingleCore;
critical_section::set_impl!(SingleCore);

// SAFETY: single-core Cortex-M; disabling interrupts excludes every other
// execution context, and the previous PRIMASK state is restored.
unsafe impl critical_section::Impl for SingleCore {
    unsafe fn acquire() -> critical_section::RawRestoreState {
        let was_active = cortex_m::register::primask::read().is_active();
        cortex_m::interrupt::disable();
        was_active
    }

    unsafe fn release(was_active: critical_section::RawRestoreState) {
        if was_active {
            // SAFETY: interrupts were enabled when the section began.
            unsafe { cortex_m::interrupt::enable() }
        }
    }
}
