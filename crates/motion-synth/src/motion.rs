// SPDX-License-Identifier: GPL-3.0-only
//! Control-rate motion processing: gyro bias calibration, complementary
//! orientation filter, rotation energy and tap detection.

use libm::{atan2f, sqrtf};

/// One IMU sample in board axes, timestamped by the producer.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct MotionSample {
    /// Timestamp in microseconds (monotonic).
    pub t_us: u64,
    /// Acceleration in g.
    pub accel_g: [f32; 3],
    /// Angular rate in degrees per second.
    pub gyro_dps: [f32; 3],
}

/// Output of [`MotionProcessor::update`].
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct MotionFrame {
    /// Timestamp of the sample that produced this frame (µs).
    pub t_us: u64,
    /// Pitch in degrees (rotation about Y), −90…90.
    pub pitch_deg: f32,
    /// Roll in degrees (rotation about X), −180…180.
    pub roll_deg: f32,
    /// Smoothed bias-corrected rotation speed magnitude (dps).
    pub rotation_dps: f32,
    /// Detected tap strength in g above threshold, if a tap fired on this sample.
    pub tap: Option<f32>,
    /// True once the gyro bias has been estimated.
    pub calibrated: bool,
}

/// Tunables. Defaults suit a hand-held instrument at 416 Hz.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct MotionConfig {
    /// Complementary filter time constant in seconds (gyro trusted below it).
    pub orientation_tau_s: f32,
    /// Stationary samples needed to estimate gyro bias.
    pub calib_samples: u16,
    /// Max |gyro| (dps) and max ||a|−1| (g) considered stationary.
    pub still_gyro_dps: f32,
    /// See `still_gyro_dps`.
    pub still_accel_g: f32,
    /// High-passed |a| threshold for a tap (g).
    pub tap_threshold_g: f32,
    /// Refractory time after a tap (µs).
    pub tap_refractory_us: u64,
    /// One-pole smoothing time constant for rotation energy (s).
    pub rotation_tau_s: f32,
    /// Largest dt accepted for integration (µs); larger gaps re-seed from accel.
    pub max_dt_us: u64,
}

impl Default for MotionConfig {
    fn default() -> Self {
        Self {
            orientation_tau_s: 0.5,
            calib_samples: 400,
            still_gyro_dps: 3.0,
            still_accel_g: 0.05,
            tap_threshold_g: 0.8,
            tap_refractory_us: 120_000,
            rotation_tau_s: 0.03,
            max_dt_us: 50_000,
        }
    }
}

/// Gyro bias estimator: averages a run of consecutive stationary samples.
#[derive(Clone, Copy, Debug, Default)]
pub struct GyroCalibrator {
    sum: [f32; 3],
    n: u16,
    bias: Option<[f32; 3]>,
}

impl GyroCalibrator {
    /// Feed a sample. Motion restarts the current run.
    pub fn update(&mut self, s: &MotionSample, cfg: &MotionConfig) {
        if self.bias.is_some() {
            return;
        }
        let g = norm(s.gyro_dps);
        let a = norm(s.accel_g);
        if g < cfg.still_gyro_dps && (a - 1.0).abs() < cfg.still_accel_g {
            for i in 0..3 {
                self.sum[i] += s.gyro_dps[i];
            }
            self.n += 1;
            if self.n >= cfg.calib_samples {
                let n = self.n as f32;
                self.bias = Some([self.sum[0] / n, self.sum[1] / n, self.sum[2] / n]);
            }
        } else {
            self.sum = [0.0; 3];
            self.n = 0;
        }
    }
    /// Estimated bias, once available.
    pub fn bias(&self) -> Option<[f32; 3]> {
        self.bias
    }
    /// Forget the estimate (e.g. after a sensor power cycle).
    pub fn reset(&mut self) {
        *self = Self::default();
    }
}

/// Complementary filter + tap detector + calibration.
#[derive(Clone, Copy, Debug)]
pub struct MotionProcessor {
    cfg: MotionConfig,
    calib: GyroCalibrator,
    last_t: Option<u64>,
    pitch: f32,
    roll: f32,
    rotation: f32,
    mag_lp: f32,
    last_tap_t: Option<u64>,
}

impl MotionProcessor {
    /// New processor.
    pub fn new(cfg: MotionConfig) -> Self {
        Self {
            cfg,
            calib: GyroCalibrator::default(),
            last_t: None,
            pitch: 0.0,
            roll: 0.0,
            rotation: 0.0,
            mag_lp: 1.0,
            last_tap_t: None,
        }
    }

    /// Restart filters (keeps calibration unless `forget_bias`).
    pub fn reset(&mut self, forget_bias: bool) {
        let calib = self.calib;
        *self = Self::new(self.cfg);
        if !forget_bias {
            self.calib = calib;
        }
    }

    /// Process one sample.
    pub fn update(&mut self, s: &MotionSample) -> MotionFrame {
        self.calib.update(s, &self.cfg);
        let bias = self.calib.bias().unwrap_or([0.0; 3]);
        let gyro = [
            s.gyro_dps[0] - bias[0],
            s.gyro_dps[1] - bias[1],
            s.gyro_dps[2] - bias[2],
        ];
        let [ax, ay, az] = s.accel_g;
        let acc_pitch = atan2f(-ax, sqrtf(ay * ay + az * az)).to_degrees();
        let acc_roll = atan2f(ay, az).to_degrees();
        let a_mag = norm(s.accel_g);

        let dt_us = match self.last_t {
            Some(t) if s.t_us > t && s.t_us - t <= self.cfg.max_dt_us => Some(s.t_us - t),
            _ => None,
        };
        self.last_t = Some(s.t_us);

        let mut tap = None;
        match dt_us {
            None => {
                // First sample or gap/clock fault: re-seed from gravity.
                self.pitch = acc_pitch;
                self.roll = acc_roll;
                self.mag_lp = a_mag;
            }
            Some(dt_us) => {
                let dt = dt_us as f32 * 1e-6;
                let k = self.cfg.orientation_tau_s / (self.cfg.orientation_tau_s + dt);
                // Only trust accel tilt when |a| is near 1 g.
                let k = if (a_mag - 1.0).abs() > 0.3 { 1.0 } else { k };
                self.pitch = k * (self.pitch + gyro[1] * dt) + (1.0 - k) * acc_pitch;
                self.roll =
                    wrap180(k * (self.roll + gyro[0] * dt) + (1.0 - k) * near(acc_roll, self.roll));
                let kr = dt / (self.cfg.rotation_tau_s + dt);
                self.rotation += kr * (norm(gyro) - self.rotation);

                // Tap: |a| above its slow baseline (≈ 20 ms high-pass corner).
                let hp = a_mag - self.mag_lp;
                self.mag_lp += (dt / (0.05 + dt)) * (a_mag - self.mag_lp);
                let ready = match self.last_tap_t {
                    Some(t) => s.t_us.saturating_sub(t) >= self.cfg.tap_refractory_us,
                    None => true,
                };
                if ready && hp > self.cfg.tap_threshold_g {
                    tap = Some(hp - self.cfg.tap_threshold_g);
                    self.last_tap_t = Some(s.t_us);
                }
            }
        }
        self.pitch = self.pitch.clamp(-90.0, 90.0);

        MotionFrame {
            t_us: s.t_us,
            pitch_deg: self.pitch,
            roll_deg: self.roll,
            rotation_dps: self.rotation,
            tap,
            calibrated: self.calib.bias().is_some(),
        }
    }

    /// Current gyro bias estimate.
    pub fn gyro_bias(&self) -> Option<[f32; 3]> {
        self.calib.bias()
    }
}

fn norm(v: [f32; 3]) -> f32 {
    sqrtf(v[0] * v[0] + v[1] * v[1] + v[2] * v[2])
}

fn wrap180(mut a: f32) -> f32 {
    while a > 180.0 {
        a -= 360.0;
    }
    while a < -180.0 {
        a += 360.0;
    }
    a
}

/// Unwrap `target` to the representation closest to `reference`.
fn near(target: f32, reference: f32) -> f32 {
    let d = wrap180(target - reference);
    reference + d
}

#[cfg(test)]
mod tests {
    use super::*;

    const DT: u64 = 2404; // ≈416 Hz

    fn still(t: u64, accel: [f32; 3], bias: [f32; 3]) -> MotionSample {
        MotionSample {
            t_us: t,
            accel_g: accel,
            gyro_dps: bias,
        }
    }

    #[test]
    fn calibrates_bias_when_still() {
        let mut p = MotionProcessor::new(MotionConfig::default());
        let bias = [0.8, -1.2, 0.3];
        let mut f = MotionFrame::default();
        for i in 0..600 {
            f = p.update(&still(i * DT, [0.0, 0.0, 1.0], bias));
        }
        assert!(f.calibrated);
        let b = p.gyro_bias().unwrap();
        for i in 0..3 {
            assert!((b[i] - bias[i]).abs() < 1e-4);
        }
        assert!(f.rotation_dps < 0.01, "bias removed: {}", f.rotation_dps);
    }

    #[test]
    fn motion_restarts_calibration_run() {
        let mut p = MotionProcessor::new(MotionConfig::default());
        for i in 0..300 {
            p.update(&still(i * DT, [0.0, 0.0, 1.0], [0.0; 3]));
        }
        p.update(&still(300 * DT, [0.0, 0.0, 1.0], [50.0, 0.0, 0.0]));
        for i in 301..600 {
            p.update(&still(i * DT, [0.0, 0.0, 1.0], [0.0; 3]));
        }
        assert!(p.gyro_bias().is_none());
        for i in 600..800 {
            p.update(&still(i * DT, [0.0, 0.0, 1.0], [0.0; 3]));
        }
        assert!(p.gyro_bias().is_some());
    }

    #[test]
    fn static_tilt_converges_to_accel_angles() {
        let mut p = MotionProcessor::new(MotionConfig::default());
        let th = 30f32.to_radians();
        // pitch +30°: ax = -sin, az = cos
        let a = [-libm::sinf(th), 0.0, libm::cosf(th)];
        let mut f = MotionFrame::default();
        for i in 0..2000 {
            f = p.update(&still(i * DT, a, [0.0; 3]));
        }
        assert!((f.pitch_deg - 30.0).abs() < 0.1, "{}", f.pitch_deg);
        assert!(f.roll_deg.abs() < 0.1);
    }

    #[test]
    fn gyro_integration_tracks_fast_rotation() {
        let mut p = MotionProcessor::new(MotionConfig::default());
        // Rotate about X at 90 dps for 0.5 s; accel left flat (lagging), so
        // the short-term estimate must come from the gyro.
        let mut f = p.update(&still(0, [0.0, 0.0, 1.0], [0.0; 3]));
        let n = 208u64;
        for i in 1..=n {
            f = p.update(&MotionSample {
                t_us: i * DT,
                accel_g: [0.0, 0.0, 1.0],
                gyro_dps: [90.0, 0.0, 0.0],
            });
        }
        // Pure integration would give 45°, accel correction pulls back.
        assert!(f.roll_deg > 25.0 && f.roll_deg < 45.0, "{}", f.roll_deg);
        assert!((f.rotation_dps - 90.0).abs() < 1.0);
    }

    #[test]
    fn tap_detection_and_refractory() {
        let mut p = MotionProcessor::new(MotionConfig::default());
        let mut taps = 0;
        for i in 0..400u64 {
            let mut a = [0.0, 0.0, 1.0];
            // Two spikes 40 ms apart (second inside refractory), one 300 ms later.
            if i == 100 || i == 117 || i == 225 {
                a[2] = 3.0;
            }
            if p.update(&still(i * DT, a, [0.0; 3])).tap.is_some() {
                taps += 1;
            }
        }
        assert_eq!(taps, 2);
    }

    #[test]
    fn time_gap_reseeds_instead_of_integrating() {
        let mut p = MotionProcessor::new(MotionConfig::default());
        p.update(&still(0, [0.0, 0.0, 1.0], [0.0; 3]));
        // 1 s gap with huge gyro value would be 500° if integrated.
        let f = p.update(&MotionSample {
            t_us: 1_000_000,
            accel_g: [0.0, 0.0, 1.0],
            gyro_dps: [500.0, 0.0, 0.0],
        });
        assert!(f.roll_deg.abs() < 1e-3);
        // Non-monotonic timestamp also re-seeds.
        let f = p.update(&MotionSample {
            t_us: 10,
            accel_g: [0.0, 0.0, 1.0],
            gyro_dps: [500.0, 0.0, 0.0],
        });
        assert!(f.roll_deg.abs() < 1e-3);
    }

    #[test]
    fn roll_wraps_without_jump() {
        let mut p = MotionProcessor::new(MotionConfig::default());
        let th = 179f32.to_radians();
        let a = [0.0, libm::sinf(th), libm::cosf(th)];
        let mut f = MotionFrame::default();
        for i in 0..1000 {
            f = p.update(&still(i * DT, a, [0.0; 3]));
        }
        assert!(f.roll_deg.abs() > 178.0, "{}", f.roll_deg);
    }
}
