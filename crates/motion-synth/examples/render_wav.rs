// SPDX-License-Identifier: GPL-3.0-only
//! Host demo: run the full control→audio pipeline on a scripted gesture and
//! write a 16-bit mono WAV. Same code path as the firmware (416 Hz control,
//! fixed audio blocks, mailbox at block boundaries).
//!
//! `cargo run -p motion-synth --example render_wav -- out.wav [32000] [64]`

use motion_synth::mailbox::ControlMailbox;
use motion_synth::mapping::{map, MappingConfig, TouchInput};
use motion_synth::motion::{MotionConfig, MotionProcessor, MotionSample};
use motion_synth::synth::Synth;
use std::io::Write;

const IMU_HZ: f64 = 416.0;

/// Scripted gesture: 1.2 s still (gyro bias calibration), 2.4 s slow forward
/// tilt sweep while rotating, taps every 400 ms, then hold.
fn gesture(t: f64) -> MotionSample {
    let bias = [0.7f32, -0.4, 0.2];
    let t_us = (t * 1e6) as u64;
    if t < 1.2 {
        return MotionSample {
            t_us,
            accel_g: [0.0, 0.0, 1.0],
            gyro_dps: bias,
        };
    }
    let u = ((t - 1.2) / 2.4).min(1.0);
    let pitch = (-45.0 + 90.0 * u).to_radians();
    let rate = if u < 1.0 { 90.0 / 2.4 } else { 0.0 };
    let wobble = 200.0 * (std::f64::consts::TAU * 1.5 * t).sin().abs();
    let mut az = pitch.cos() as f32;
    let tap_phase = ((t - 1.2) * 1000.0) as u64 % 400;
    if tap_phase < 3 {
        az += 2.5;
    }
    MotionSample {
        t_us,
        accel_g: [-(pitch.sin() as f32), 0.0, az],
        gyro_dps: [bias[0] + wobble as f32, bias[1] + rate as f32, bias[2]],
    }
}

fn main() -> std::io::Result<()> {
    let args: Vec<String> = std::env::args().collect();
    let path = args
        .get(1)
        .map(String::as_str)
        .unwrap_or("motion-synth-demo.wav");
    let fs: u32 = args.get(2).and_then(|s| s.parse().ok()).unwrap_or(32_000);
    let block: usize = args.get(3).and_then(|s| s.parse().ok()).unwrap_or(64);
    assert!(
        [16_000, 32_000, 48_000].contains(&fs),
        "fs must be 16000, 32000 or 48000"
    );
    let seconds = 4.5;

    let mut motion = MotionProcessor::new(MotionConfig::default());
    let mapping = MappingConfig::default();
    let mut mailbox = ControlMailbox::new();
    let mut synth = Synth::new(fs);

    let total = (seconds * fs as f64) as usize;
    let mut pcm: Vec<i16> = Vec::with_capacity(total);
    let mut next_imu = 0.0f64;
    let mut buf = vec![0i16; block];
    let mut starved = 0u32;
    while pcm.len() < total {
        let block_start = pcm.len() as f64 / fs as f64;
        // Deliver all IMU samples that arrived before this block starts.
        while next_imu <= block_start {
            let f = motion.update(&gesture(next_imu));
            mailbox.post(map(&mapping, &f, &TouchInput::default()), f.t_us);
            next_imu += 1.0 / IMU_HZ;
        }
        let snap = mailbox.take();
        if snap.frames == 0 {
            starved += 1;
        }
        synth.apply(&snap);
        synth.render(&mut buf);
        pcm.extend_from_slice(&buf);
    }
    pcm.truncate(total);

    let mut f = std::fs::File::create(path)?;
    let data_len = (pcm.len() * 2) as u32;
    f.write_all(b"RIFF")?;
    f.write_all(&(36 + data_len).to_le_bytes())?;
    f.write_all(b"WAVEfmt ")?;
    f.write_all(&16u32.to_le_bytes())?;
    f.write_all(&1u16.to_le_bytes())?; // PCM
    f.write_all(&1u16.to_le_bytes())?; // mono
    f.write_all(&fs.to_le_bytes())?;
    f.write_all(&(fs * 2).to_le_bytes())?;
    f.write_all(&2u16.to_le_bytes())?;
    f.write_all(&16u16.to_le_bytes())?;
    f.write_all(b"data")?;
    f.write_all(&data_len.to_le_bytes())?;
    for s in &pcm {
        f.write_all(&s.to_le_bytes())?;
    }
    let peak = pcm.iter().map(|s| s.unsigned_abs()).max().unwrap_or(0);
    println!(
        "wrote {path}: {} samples @ {fs} Hz, block {block} ({:.2} ms), triggers {}, blocks without new control {starved}, peak {peak}, gyro bias {:?}",
        pcm.len(),
        block as f64 * 1000.0 / fs as f64,
        synth.trigger_count(),
        motion.gyro_bias()
    );
    Ok(())
}
