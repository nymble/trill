// SPDX-License-Identifier: GPL-3.0-only
//! Battery measurement on the Seeed XIAO nRF52840 (Sense).
//!
//! Circuit (Seeed XIAO nRF52840 KiCad project v1.2, nets `VBAT`,
//! `P0.14_~{READ_BAT}`, `P0.31_AIN7_BAT`, `P0.17_~{CHG}`, `P0.13_HICHG`):
//!
//! * VBAT -> 1 MΩ (1 %) -> P0.31 / AIN7 -> 510 kΩ (1 %) -> P0.14. Driving
//!   P0.14 LOW completes the divider, so AIN7 sees VBAT × 510 / 1510.
//! * P0.17 is the BQ25101 charger's open-drain ~CHG output (also the red
//!   charge LED): LOW while charging, released when not charging or done.
//! * P0.13 selects the charge current (input = about 50 mA, output LOW =
//!   about 100 mA). The firmware leaves it as an input (50 mA).
//!
//! Safety: Seeed warns that with P0.14 HIGH (or floating) the reading path
//! is disabled and P0.31 can reach its 3.6 V input limit, which risks
//! damaging the pin, and asks never to set P0.14 HIGH while the battery is
//! charging. The firmware therefore drives P0.14 LOW from the first lines
//! of `main`, in every mode, and never releases it.
//!
//! The SAADC reads AIN7 single-ended with the internal 0.6 V reference and
//! gain 1/6 (full scale 3.6 V), 12 bits.

use trill_config::Battery;

/// Divider top resistor (Ω).
pub const DIVIDER_TOP_OHMS: u32 = 1_000_000;
/// Divider bottom resistor (Ω).
pub const DIVIDER_BOTTOM_OHMS: u32 = 510_000;
/// SAADC full scale in mV (0.6 V reference, gain 1/6).
pub const ADC_FULL_SCALE_MV: u32 = 3_600;
/// SAADC full-scale code at 12-bit resolution.
pub const ADC_MAX: u32 = 4_096;

/// Battery voltage in mV from a 12-bit SAADC sample of AIN7. Negative
/// samples (noise around 0 V) read as 0.
pub fn mv_from_adc(sample: i16) -> u16 {
    let raw = sample.max(0) as u64;
    let num =
        raw * u64::from(ADC_FULL_SCALE_MV) * u64::from(DIVIDER_TOP_OHMS + DIVIDER_BOTTOM_OHMS);
    let den = u64::from(ADC_MAX) * u64::from(DIVIDER_BOTTOM_OHMS);
    ((num + den / 2) / den).min(u64::from(u16::MAX)) as u16
}

/// Open-circuit LiPo curve (mV, %), a typical single-cell 3.7 V lithium
/// polymer discharge curve at low load. Readings while charging are higher
/// than the resting voltage, so the percentage is only a rough guide then.
pub const LIPO_CURVE: [(u16, u8); 12] = [
    (3_300, 0),
    (3_500, 3),
    (3_600, 7),
    (3_680, 12),
    (3_730, 20),
    (3_770, 30),
    (3_800, 40),
    (3_840, 50),
    (3_900, 60),
    (3_980, 72),
    (4_080, 85),
    (4_180, 100),
];

/// Approximate state of charge (0..=100 %) from the battery voltage,
/// linear between the points of [`LIPO_CURVE`].
pub fn percent_from_mv(mv: u16) -> u8 {
    let (first_mv, first_pct) = LIPO_CURVE[0];
    if mv <= first_mv {
        return first_pct;
    }
    for w in LIPO_CURVE.windows(2) {
        let ((m0, p0), (m1, p1)) = (w[0], w[1]);
        if mv <= m1 {
            let span = u32::from(m1 - m0);
            let num = u32::from(mv - m0) * u32::from(p1 - p0) + span / 2;
            return p0 + (num / span) as u8;
        }
    }
    100
}

/// One battery observation, taken about once a second.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Observation {
    /// USB power (VBUS) present.
    pub usb_power: bool,
    /// ~CHG is LOW (charging) at the moment of the sample.
    pub charging: bool,
    /// ~CHG transitions counted since the previous observation.
    pub chg_edges: u16,
    /// Battery voltage (mV) from [`mv_from_adc`].
    pub mv: u16,
}

/// Observations in the judging window (one per second).
pub const WINDOW: usize = 10;
/// Below this the reading path sees no cell at all.
pub const MIN_CELL_MV: u16 = 2_500;
/// A plausible cell on USB power must read at least this.
pub const MIN_USB_CELL_MV: u16 = 3_000;
/// No LiPo cell rests above this; the charger output without a cell can.
pub const MAX_CELL_MV: u16 = 4_350;
/// ~CHG transitions in the window that mean the charger is cycling with
/// no cell (the red charge LED flickers).
pub const CYCLING_EDGES: u16 = 4;
/// Voltage spread in the window above which the reading is the unloaded
/// charger output rather than a cell (a cell changes slowly).
pub const MAX_RIPPLE_MV: u16 = 150;
/// The same new judgement this many seconds in a row before it replaces
/// the previous one (no flapping on a single odd sample).
pub const CONFIRM: u8 = 3;

/// Battery presence heuristic (see docs/battery.md):
///
/// * **No USB power**: the board is running, so it runs from a cell:
///   present (if the reading is a plausible cell voltage).
/// * **USB power** (after a 10 s window):
///   * absent if ~CHG toggles ([`CYCLING_EDGES`] or more in the window),
///     the voltage swings by more than [`MAX_RIPPLE_MV`], it is above
///     [`MAX_CELL_MV`] or below [`MIN_CELL_MV`];
///   * present if it is steady and in the cell range, charging or not.
///   * Until the first window is full the state is
///     [`Battery::Unknown`].
///
/// Limits: a board without a battery whose charger output happens to sit
/// steady in the cell range with ~CHG quiet reads as a full battery on USB.
/// A cell above 4.35 V (not a LiPo) reads as absent.
#[derive(Clone, Debug)]
pub struct Detector {
    edges: [u16; WINDOW],
    mv: [u16; WINDOW],
    filled: usize,
    next: usize,
    state: Battery,
    candidate: Battery,
    streak: u8,
}

impl Default for Detector {
    fn default() -> Self {
        Self::new()
    }
}

impl Detector {
    /// Nothing observed yet: [`Battery::Unknown`].
    pub const fn new() -> Self {
        Self {
            edges: [0; WINDOW],
            mv: [0; WINDOW],
            filled: 0,
            next: 0,
            state: Battery::Unknown,
            candidate: Battery::Unknown,
            streak: 0,
        }
    }

    /// Current judgement.
    pub fn state(&self) -> Battery {
        self.state
    }

    /// Feed one observation; returns the (possibly new) judgement.
    pub fn update(&mut self, o: Observation) -> Battery {
        self.edges[self.next] = o.chg_edges;
        self.mv[self.next] = o.mv;
        self.next = (self.next + 1) % WINDOW;
        self.filled = (self.filled + 1).min(WINDOW);

        let judged = self.judge(o);
        if judged == Battery::Unknown {
            return self.state;
        }
        if self.state == Battery::Unknown || !o.usb_power {
            // First judgement, or running from the battery: take it now.
            self.state = judged;
            self.streak = 0;
            self.candidate = judged;
            return self.state;
        }
        if judged == self.state {
            self.streak = 0;
        } else if judged == self.candidate {
            self.streak += 1;
            if self.streak >= CONFIRM {
                self.state = judged;
                self.streak = 0;
            }
        } else {
            self.candidate = judged;
            self.streak = 1;
            if CONFIRM <= 1 {
                self.state = judged;
            }
        }
        self.state
    }

    fn judge(&self, o: Observation) -> Battery {
        if o.mv < MIN_CELL_MV {
            return Battery::Absent;
        }
        if !o.usb_power {
            return if o.mv <= MAX_CELL_MV {
                Battery::Present
            } else {
                Battery::Unknown
            };
        }
        if o.mv > MAX_CELL_MV {
            return Battery::Absent;
        }
        let window = &self.mv[..self.filled];
        let edges: u16 = self.edges[..self.filled].iter().sum();
        if edges >= CYCLING_EDGES {
            return Battery::Absent;
        }
        if self.filled < WINDOW {
            return Battery::Unknown;
        }
        let max = window.iter().copied().max().unwrap_or(0);
        let min = window.iter().copied().min().unwrap_or(0);
        if max - min > MAX_RIPPLE_MV {
            return Battery::Absent;
        }
        if min >= MIN_USB_CELL_MV {
            Battery::Present
        } else {
            Battery::Unknown
        }
    }
}
