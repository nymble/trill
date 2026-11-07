// SPDX-License-Identifier: GPL-3.0-only
//! Audio-rate voice: band-limited saw + sine sub-oscillator → TPT state
//! variable low-pass → (sustain level + plucked AD envelope) → soft clip.
//!
//! Real-time properties:
//! * no allocation, no branches whose cost depends on signal content,
//! * parameters latched once per block ([`Synth::apply`]) then smoothed per
//!   sample with a one-pole (`SMOOTH_MS`) — no zipper noise,
//! * filter coefficients recomputed every `COEF_INTERVAL` samples with a
//!   single-precision rational `tan` approximation, and the sine uses a
//!   polynomial: no `f64` maths on the audio path (the nRF52840's FPU is
//!   single precision; `libm` trig functions evaluate in `f64`),
//! * output is always finite and inside i16 range.

use crate::mailbox::ControlSnapshot;
use crate::mapping::SynthParams;
use libm::expf;

/// Parameter smoothing time constant.
pub const SMOOTH_MS: f32 = 4.0;
/// Samples between filter coefficient updates.
pub const COEF_INTERVAL: usize = 8;
/// Envelope attack time.
pub const ATTACK_MS: f32 = 2.0;
/// Envelope decay time constant.
pub const DECAY_MS: f32 = 250.0;

#[derive(Clone, Copy, Debug)]
struct Smoothed {
    value: f32,
    target: f32,
}

impl Smoothed {
    fn new(v: f32) -> Self {
        Self {
            value: v,
            target: v,
        }
    }
    #[inline]
    fn next(&mut self, k: f32) -> f32 {
        self.value += k * (self.target - self.value);
        self.value
    }
}

/// One synth voice.
#[derive(Clone, Copy, Debug)]
pub struct Synth {
    fs: f32,
    k_smooth: f32,
    phase: f32,
    sub_phase: f32,
    freq: Smoothed,
    cutoff: Smoothed,
    reso: Smoothed,
    level: Smoothed,
    // TPT SVF state and coefficients
    ic1: f32,
    ic2: f32,
    a1: f32,
    a2: f32,
    a3: f32,
    k: f32,
    coef_count: usize,
    // envelope
    env: f32,
    env_target: f32,
    attacking: bool,
    attack_inc: f32,
    decay_k: f32,
    velocity: f32,
    triggers: u32,
}

impl Synth {
    /// New voice at `sample_rate` Hz, silent.
    pub fn new(sample_rate: u32) -> Self {
        let fs = sample_rate as f32;
        let p = SynthParams::default();
        let mut s = Self {
            fs,
            k_smooth: 1.0 - expf(-1.0 / (SMOOTH_MS * 1e-3 * fs)),
            phase: 0.0,
            sub_phase: 0.0,
            freq: Smoothed::new(p.freq_hz),
            cutoff: Smoothed::new(p.cutoff_hz),
            reso: Smoothed::new(p.resonance),
            level: Smoothed::new(0.0),
            ic1: 0.0,
            ic2: 0.0,
            a1: 0.0,
            a2: 0.0,
            a3: 0.0,
            k: 0.0,
            coef_count: 0,
            env: 0.0,
            env_target: 0.0,
            attacking: false,
            attack_inc: 1.0 / (ATTACK_MS * 1e-3 * fs),
            decay_k: expf(-1.0 / (DECAY_MS * 1e-3 * fs)),
            velocity: 0.0,
            triggers: 0,
        };
        s.update_coefs();
        s
    }

    /// Sample rate in Hz.
    pub fn sample_rate(&self) -> f32 {
        self.fs
    }

    /// Number of triggers applied so far.
    pub fn trigger_count(&self) -> u32 {
        self.triggers
    }

    /// Set new parameter targets (call at a block boundary).
    pub fn set_params(&mut self, p: &SynthParams) {
        let nyq = 0.45 * self.fs;
        self.freq.target = finite_or(p.freq_hz, self.freq.target).clamp(20.0, nyq * 0.5);
        self.cutoff.target = finite_or(p.cutoff_hz, self.cutoff.target).clamp(20.0, nyq);
        self.reso.target = finite_or(p.resonance, self.reso.target).clamp(0.0, 0.95);
        self.level.target = finite_or(p.level, self.level.target).clamp(0.0, 1.0);
        if let Some(v) = p.trigger {
            self.trigger(v);
        }
    }

    /// Apply one mailbox snapshot (params + merged trigger).
    pub fn apply(&mut self, s: &ControlSnapshot) {
        if let Some(p) = s.params {
            self.set_params(&p);
        }
        if let Some(v) = s.trigger {
            self.trigger(v);
        }
    }

    /// Start a pluck with velocity 0…1.
    pub fn trigger(&mut self, velocity: f32) {
        self.velocity = finite_or(velocity, 0.0).clamp(0.0, 1.0);
        self.env_target = 1.0;
        self.attacking = true;
        self.triggers = self.triggers.wrapping_add(1);
    }

    fn update_coefs(&mut self) {
        let g = tan_approx(core::f32::consts::PI * self.cutoff.value / self.fs);
        // resonance 0…0.95 → damping k = 2 … 0.1
        self.k = 2.0 - 1.9 * self.reso.value;
        self.a1 = 1.0 / (1.0 + g * (g + self.k));
        self.a2 = g * self.a1;
        self.a3 = g * self.a2;
    }

    #[inline]
    fn next_sample(&mut self) -> f32 {
        let ks = self.k_smooth;
        let f = self.freq.next(ks);
        self.cutoff.next(ks);
        self.reso.next(ks);
        let level = self.level.next(ks);
        if self.coef_count == 0 {
            self.update_coefs();
            self.coef_count = COEF_INTERVAL;
        }
        self.coef_count -= 1;

        // PolyBLEP saw
        let dt = f / self.fs;
        let t = self.phase;
        let mut saw = 2.0 * t - 1.0;
        saw -= poly_blep(t, dt);
        self.phase += dt;
        if self.phase >= 1.0 {
            self.phase -= 1.0;
        }
        let sub = sin_turns(self.sub_phase);
        self.sub_phase += 0.5 * dt;
        if self.sub_phase >= 1.0 {
            self.sub_phase -= 1.0;
        }
        let x = 0.6 * saw + 0.4 * sub;

        // TPT SVF low-pass (Zavalishin / Simper form)
        let v3 = x - self.ic2;
        let v1 = self.a1 * self.ic1 + self.a2 * v3;
        let v2 = self.ic2 + self.a2 * self.ic1 + self.a3 * v3;
        self.ic1 = 2.0 * v1 - self.ic1;
        self.ic2 = 2.0 * v2 - self.ic2;
        let lp = v2;

        // Envelope: linear attack, exponential decay
        if self.attacking {
            self.env += self.attack_inc;
            if self.env >= self.env_target {
                self.env = self.env_target;
                self.attacking = false;
            }
        } else {
            self.env *= self.decay_k;
        }
        let amp = (level * 0.7 + self.env * self.velocity).min(1.2);
        soft_clip(lp * amp)
    }

    /// Render one block of mono i16 samples. Cost is O(len), independent of
    /// parameters or signal content.
    pub fn render(&mut self, out: &mut [i16]) {
        for o in out.iter_mut() {
            let y = self.next_sample();
            *o = (y * 32767.0) as i16;
        }
        // Denormal / blow-up guard: state is always finite by construction,
        // but reset if a fault ever made it otherwise.
        if !(self.ic1.is_finite() && self.ic2.is_finite()) {
            self.ic1 = 0.0;
            self.ic2 = 0.0;
        }
    }

    /// Render into f32 (−1…1) for host analysis.
    pub fn render_f32(&mut self, out: &mut [f32]) {
        for o in out.iter_mut() {
            *o = self.next_sample();
        }
    }
}

#[inline]
fn finite_or(v: f32, fallback: f32) -> f32 {
    if v.is_finite() {
        v
    } else {
        fallback
    }
}

#[inline]
fn poly_blep(t: f32, dt: f32) -> f32 {
    if t < dt {
        let x = t / dt;
        x + x - x * x - 1.0
    } else if t > 1.0 - dt {
        let x = (t - 1.0) / dt;
        x * x + x + x + 1.0
    } else {
        0.0
    }
}

/// sin(2π·t) for t in [0, 1): parabola + one refinement step, |error| < 0.0011.
#[inline]
pub fn sin_turns(t: f32) -> f32 {
    let x = if t < 0.5 { t } else { t - 1.0 };
    let y = 8.0 * x - 16.0 * x * x.abs();
    0.225 * (y * y.abs() - y) + y
}

/// tan(x) for x in [0, 1.42] (cutoff up to 0.45·fs): [5/4] Padé-style
/// rational approximation in f32.
#[inline]
pub fn tan_approx(x: f32) -> f32 {
    let x2 = x * x;
    x * (945.0 - 105.0 * x2 + x2 * x2) / (945.0 - 420.0 * x2 + 15.0 * x2 * x2)
}

/// Cubic soft clipper, output in [−1, 1].
#[inline]
pub fn soft_clip(x: f32) -> f32 {
    let x = x.clamp(-1.5, 1.5);
    x - (4.0 / 27.0) * x * x * x
}

#[cfg(test)]
mod tests {
    use super::*;

    fn params(freq: f32, level: f32) -> SynthParams {
        SynthParams {
            freq_hz: freq,
            cutoff_hz: 8000.0,
            resonance: 0.0,
            level,
            trigger: None,
        }
    }

    fn settle(s: &mut Synth, n: usize) {
        let mut b = vec![0i16; n];
        s.render(&mut b);
    }

    /// Fundamental estimate: upward zero crossings of a render low-passed
    /// just above the fundamental (sub-oscillator at f/2 is weaker).
    fn est_freq(fs: u32, freq: f32) -> f32 {
        let mut s = Synth::new(fs);
        s.set_params(&SynthParams {
            freq_hz: freq,
            cutoff_hz: freq * 1.2,
            resonance: 0.0,
            level: 1.0,
            trigger: None,
        });
        settle(&mut s, fs as usize / 2);
        let n = fs as usize;
        let mut b = vec![0f32; n];
        s.render_f32(&mut b);
        let mut ups = Vec::new();
        for i in 1..n {
            if b[i - 1] < 0.0 && b[i] >= 0.0 {
                ups.push(i);
            }
        }
        let span = (ups[ups.len() - 1] - ups[0]) as f32;
        (ups.len() - 1) as f32 * fs as f32 / span
    }

    #[test]
    fn pitch_is_accurate_at_all_rates() {
        for fs in [16_000, 32_000, 48_000] {
            for f in [110.0f32, 220.0, 440.0] {
                let e = est_freq(fs, f);
                assert!((e - f).abs() / f < 0.01, "fs {fs} f {f} est {e}");
            }
        }
    }

    #[test]
    fn silent_until_level_or_trigger() {
        let mut s = Synth::new(32_000);
        let mut b = [0i16; 256];
        s.render(&mut b);
        assert!(b.iter().all(|&x| x == 0));
    }

    #[test]
    fn pluck_decays_exponentially() {
        let fs = 32_000;
        let mut s = Synth::new(fs);
        s.set_params(&params(220.0, 0.0));
        s.trigger(1.0);
        let block = |s: &mut Synth| {
            let mut b = vec![0f32; fs as usize / 20]; // 50 ms
            s.render_f32(&mut b);
            b.iter().fold(0f32, |m, x| m.max(x.abs()))
        };
        let p0 = block(&mut s);
        for _ in 0..4 {
            block(&mut s);
        }
        let p250 = block(&mut s); // 250–300 ms
        assert!(p0 > 0.3, "{p0}");
        let ratio = p250 / p0;
        // exp(-250/250)≈0.37 … exp(-300/250)≈0.30, allow filter/phase slack
        assert!(ratio > 0.2 && ratio < 0.45, "ratio {ratio}");
    }

    #[test]
    fn output_bounded_under_extreme_and_invalid_params() {
        let mut s = Synth::new(48_000);
        let mut b = [0i16; 64];
        let bad = [f32::NAN, f32::INFINITY, -1e9, 1e9, 0.0];
        for (i, &v) in bad.iter().enumerate() {
            s.set_params(&SynthParams {
                freq_hz: v,
                cutoff_hz: v,
                resonance: v,
                level: v,
                trigger: Some(v),
            });
            s.trigger(1.0);
            for _ in 0..50 {
                let mut f = [0f32; 64];
                s.render_f32(&mut f);
                assert!(
                    f.iter().all(|x| x.is_finite() && x.abs() <= 1.0),
                    "case {i}"
                );
                s.render(&mut b);
            }
        }
        s.set_params(&SynthParams {
            freq_hz: 20_000.0,
            cutoff_hz: 23_000.0,
            resonance: 1.0,
            level: 1.0,
            trigger: Some(1.0),
        });
        for _ in 0..1000 {
            let mut f = [0f32; 64];
            s.render_f32(&mut f);
            assert!(f.iter().all(|x| x.is_finite() && x.abs() <= 1.0));
        }
    }

    #[test]
    fn block_size_independent_and_deterministic() {
        let run = |block: usize| {
            let mut s = Synth::new(32_000);
            s.set_params(&params(330.0, 0.8));
            s.trigger(0.9);
            let mut out = Vec::new();
            let mut b = vec![0i16; block];
            while out.len() < 4096 {
                s.render(&mut b);
                out.extend_from_slice(&b);
            }
            out.truncate(4096);
            out
        };
        let a = run(32);
        assert_eq!(a, run(64));
        assert_eq!(a, run(128));
        assert_eq!(a, run(32));
    }

    #[test]
    fn parameter_steps_are_smoothed() {
        let fs = 32_000;
        let mut s = Synth::new(fs);
        s.set_params(&params(220.0, 0.0));
        settle(&mut s, 1024);
        s.set_params(&params(220.0, 1.0));
        let mut b = vec![0f32; 32];
        s.render_f32(&mut b);
        // After 1 ms with a 4 ms time constant level ≈ 0.22 → amplitude well below full.
        let peak = b.iter().fold(0f32, |m, x| m.max(x.abs()));
        assert!(peak < 0.4, "step not smoothed: {peak}");
        let mut b = vec![0f32; fs as usize / 10];
        s.render_f32(&mut b);
        let peak = b.iter().fold(0f32, |m, x| m.max(x.abs()));
        assert!(peak > 0.4, "level reached: {peak}");
    }

    #[test]
    fn fast_math_accuracy() {
        for i in 0..1000 {
            let t = i as f32 / 1000.0;
            let e = (sin_turns(t) - (core::f32::consts::TAU * t).sin()).abs();
            assert!(e < 0.0011, "sin t={t} err={e}");
        }
        let max_x = core::f32::consts::PI * 0.45;
        for i in 1..=1000 {
            let x = max_x * i as f32 / 1000.0;
            let rel = ((tan_approx(x) - x.tan()) / x.tan()).abs();
            assert!(rel < 0.01, "tan x={x} rel={rel}");
        }
    }

    #[test]
    fn soft_clip_is_monotonic_and_bounded() {
        let mut prev = soft_clip(-10.0);
        assert!((prev + 1.0).abs() < 1e-6);
        let mut x = -10.0;
        while x < 10.0 {
            let y = soft_clip(x);
            assert!(y >= prev - 1e-7 && y.abs() <= 1.0);
            prev = y;
            x += 0.01;
        }
    }
}
