// SPDX-License-Identifier: GPL-3.0-only
//! Panic / HardFault capture and crash-loop protection.
//!
//! A panic or HardFault writes a short record into a `.uninit` RAM section
//! (not zeroed at boot) and performs a system reset. On the next boot the
//! record is reported on the diagnostics port. After [`MAX_CRASHES`]
//! consecutive crash resets the firmware enters *safe mode*: USB
//! diagnostics only, no sensors, no audio, so the board stays reachable
//! and is never stuck in a silent panic loop. A clean power-on or pin
//! reset clears the counter; the bootloader stays reachable by
//! double-tapping RESET in every case.
//!
//! Best effort: the UF2 bootloader runs between our reset and our next
//! boot and may reuse that RAM; the record then fails its magic check and
//! is ignored (no false report, but the crash may go unreported).

use core::fmt::Write;
use core::mem::MaybeUninit;
use core::ptr::addr_of_mut;

const MAGIC: u32 = 0x5452_4C43; // "TRLC"
const MSG_LEN: usize = 160;
/// Consecutive crash resets that trigger safe mode.
pub const MAX_CRASHES: u32 = 3;

#[repr(C)]
struct Record {
    magic: u32,
    crashes: u32,
    kind: u32, // 1 panic, 2 hardfault
    pc: u32,
    len: u32,
    msg: [u8; MSG_LEN],
}

#[link_section = ".uninit.CRASH"]
static mut RECORD: MaybeUninit<Record> = MaybeUninit::uninit();

/// What the previous boot left behind.
pub struct BootReport {
    /// Consecutive crash resets so far.
    pub crashes: u32,
    /// 0 none, 1 panic, 2 HardFault.
    pub kind: u32,
    /// Faulting PC (HardFault only).
    pub pc: u32,
    /// Message bytes (UTF-8, truncated).
    pub msg: heapless::String<MSG_LEN>,
    /// Raw RESETREAS.
    pub resetreas: u32,
}

/// Inspect and reset the record. Call once, early in `main`.
pub fn take_boot_report(resetreas: u32) -> BootReport {
    // RESETREAS bit 3 = SREQ (software reset, used by our crash path),
    // bit 4 = LOCKUP. 0 = power-on / brown-out.
    let crash_reset = resetreas & ((1 << 3) | (1 << 4)) != 0;
    // SAFETY: single-threaded early boot, interrupts not yet using RECORD.
    let r = unsafe { &mut *addr_of_mut!(RECORD) };
    let mut out = BootReport {
        crashes: 0,
        kind: 0,
        pc: 0,
        msg: heapless::String::new(),
        resetreas,
    };
    // SAFETY: every field is plain old data; garbage is rejected by MAGIC.
    let rec = unsafe { r.assume_init_mut() };
    if rec.magic == MAGIC && crash_reset && rec.kind != 0 {
        out.crashes = rec.crashes;
        out.kind = rec.kind;
        out.pc = rec.pc;
        let n = (rec.len as usize).min(MSG_LEN);
        for &b in &rec.msg[..n] {
            let c = if b.is_ascii_graphic() || b == b' ' {
                b as char
            } else {
                '?'
            };
            let _ = out.msg.push(c);
        }
    }
    // Keep the count only while crashes keep happening back to back.
    let keep = if rec.magic == MAGIC && crash_reset {
        out.crashes
    } else {
        0
    };
    rec.magic = MAGIC;
    rec.crashes = keep;
    rec.kind = 0;
    rec.pc = 0;
    rec.len = 0;
    out
}

/// Clear the consecutive-crash counter after a period of healthy running.
pub fn mark_healthy() {
    cortex_m::interrupt::free(|_| {
        // SAFETY: inside a critical section; record initialised by take_boot_report.
        let r = unsafe { (*addr_of_mut!(RECORD)).assume_init_mut() };
        r.crashes = 0;
    });
}

struct Buf<'a> {
    b: &'a mut [u8; MSG_LEN],
    n: usize,
}

impl Write for Buf<'_> {
    fn write_str(&mut self, s: &str) -> core::fmt::Result {
        for &c in s.as_bytes() {
            if self.n < MSG_LEN {
                self.b[self.n] = c;
                self.n += 1;
            }
        }
        Ok(())
    }
}

fn record_and_reset(kind: u32, pc: u32, write: impl FnOnce(&mut Buf<'_>)) -> ! {
    cortex_m::interrupt::disable();
    // SAFETY: interrupts disabled, we never return.
    let r = unsafe { (*addr_of_mut!(RECORD)).assume_init_mut() };
    if r.magic != MAGIC {
        r.magic = MAGIC;
        r.crashes = 0;
    }
    r.crashes = r.crashes.saturating_add(1);
    r.kind = kind;
    r.pc = pc;
    let mut b = Buf {
        b: &mut r.msg,
        n: 0,
    };
    write(&mut b);
    r.len = b.n as u32;
    cortex_m::asm::dsb();
    cortex_m::peripheral::SCB::sys_reset();
}

#[panic_handler]
fn panic(info: &core::panic::PanicInfo) -> ! {
    record_and_reset(1, 0, |b| {
        let _ = write!(b, "{info}");
    })
}

#[cortex_m_rt::exception]
unsafe fn HardFault(ef: &cortex_m_rt::ExceptionFrame) -> ! {
    let pc = ef.pc();
    record_and_reset(2, pc, |b| {
        let _ = write!(b, "HardFault pc=0x{:08x} lr=0x{:08x}", ef.pc(), ef.lr());
    })
}
