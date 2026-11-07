# Motion-to-music engine

[`crates/motion-synth`](../crates/motion-synth) is a `no_std`, allocation-free library. It turns IMU motion (and optional Trill touch) into sound at audio rate. It runs unchanged on the host (tests, WAV demo) and in the [XIAO Sense firmware](firmware-xiao-sense.md). In the firmware, the `motion` module (orientation, rotation, taps) feeds the default [USB-MIDI](usb-midi.md) path. The synth, mapping and PCM stream are an optional debug build (`--features pcm-synth`): the instrument's sound normally comes from a host synth over MIDI.

> **Status:** implemented and host-tested. The audio path has been checked by disassembly to use no `f64` maths. On-target timing has **not** been measured: the firmware reports render time and control age, but no hardware run has been done yet.

## Two clocks

| Domain | Rate | Work | Code |
|---|---|---|---|
| Control | IMU ODR, 416 Hz default (104–833 Hz supported by the driver) | gyro bias calibration, complementary-filter pitch/roll, rotation speed, tap detection, mapping to synth parameters | `motion`, `mapping` |
| Audio | 16, 32 (firmware default) or 48 kHz, fixed blocks (64 samples = 2 ms at 32 kHz) | oscillators, filter, envelope, soft clip | `synth` |

Per-sample synthesis never waits on sensors. Control frames land in a fixed-size [`ControlMailbox`](../crates/motion-synth/src/mailbox.rs). The audio task takes one snapshot at each block boundary. Continuous parameters are latest-wins and then **smoothed per sample** (4 ms one-pole), so a 416 Hz control stream against 500 Hz blocks gives neither zipper noise nor clicks. Triggers (taps) accumulate between blocks, so none is lost. Render cost per block is O(block length) and independent of parameters and signal.

## Motion processing (`motion`)

- **Timestamps:** every sample carries a microsecond timestamp from the producer. A gap longer than 50 ms, or a timestamp that goes backwards, re-seeds orientation from gravity instead of integrating a bogus dt.
- **Gyro bias:** averaged over 400 consecutive stationary samples (|ω| < 3 dps and ||a| − 1 g| < 0.05 g, about 1 s at 416 Hz). Any motion restarts the run. After an IMU power cycle the bias is discarded, and the `c` diagnostics command forces recalibration.
- **Orientation:** complementary filter with τ = 0.5 s. Gravity is trusted only while |a| is within 0.3 g of 1 g, so shakes do not tilt the estimate. Roll is unwrapped across ±180°.
- **Rotation energy:** smoothed magnitude of bias-corrected angular rate (τ = 30 ms).
- **Taps:** |a| minus its slow baseline crossing 0.8 g, with a 120 ms refractory period. Strength is the excess in g.

## Mapping (`mapping`)

Default instrument, intended to be changed:

| Gesture | Parameter |
|---|---|
| Pitch tilt ±60° | note over 2 octaves from A2 (110 Hz), quantised to major pentatonic |
| Roll (0–90°), Trill touch size | low-pass cutoff 200 Hz – 6 kHz (exponential) |
| Rotation speed (0–360 dps) | sustained level ("bowing") and a little resonance |
| Tap | pluck, velocity from tap strength |
| Trill touch location (when touched) | continuous pitch over the same 2 octaves (overrides tilt) |

## Voice (`synth`)

PolyBLEP sawtooth plus a sine sub-oscillator one octave down, into a TPT state-variable low-pass (coefficients every 8 samples), then amplitude = 0.7 × sustained level + pluck envelope (2 ms linear attack, 250 ms exponential decay) × velocity, then a cubic soft clip to i16. Invalid parameters (NaN, ±∞, out of range) are clamped or ignored, so output is always finite.

The nRF52840 FPU is single precision, and `libm` trigonometry evaluates in `f64` (software emulated). The audio path therefore uses a polynomial sine (error < 0.0011) and a rational `tan` (error < 1 % up to 0.45·fs). Disassembly of the release firmware (before the USB-MIDI change; not re-checked for the `pcm-synth` build) showed `f64` helper calls only in the control-rate IMU task (for `exp2f`/`powf` in mapping), none in the audio task.

## Latency budget

Design estimates for motion → sound, derived from the configuration. **These are not measurements.** [Measurement procedure](firmware-xiao-sense.md#latency-measurement).

| Stage | Estimate | Basis |
|---|---|---|
| Wait for next IMU sample | 0–2.4 ms | 416 Hz ODR (plus sensor digital filter delay, not characterised here) |
| I²C burst read (14 bytes, 400 kHz) + wake | ≈ 0.4 ms | 17 bytes × 9 bits / 400 kHz |
| Processing + mapping | µs range | to be measured on target |
| Wait for next block boundary | 0–2.0 ms | 64 samples @ 32 kHz |
| Output buffer (I²S double buffer, future) | 2.0 ms | one block |
| **Total (I²S path)** | **≈ 2.5–7 ms** | under a 10 ms target for percussive gestures |

Parameter smoothing adds a 4 ms time constant to continuous changes, but not to the onset of a pluck. The USB PCM stream adds host-side buffering that the device does not control, so do not use it for latency claims. The firmware's `ctl_age` counter measures the first three stages on the device.

## Output paths

The XIAO Sense has no DAC or speaker. Options, in the order recommended:

| Path | State | Notes |
|---|---|---|
| USB CDC framed PCM → host (`tools/pcm_capture.py` → WAV) | **Implemented** (untested on hardware) | Verification and recording. Not a USB Audio device: phones and DAWs will not see it |
| I²S → class-D amp/DAC (for example MAX98357A) | Next | nRF52840 I²S clocks are 32 MHz divisions: 32 kHz needs MCK 32MDIV31 with ratio 32X → 32 258 Hz (+0.8 %, Nordic PS Table 54). The synth takes any rate, so run it at the actual LRCK. Omi DevKit 2 drives an I²S amp from A1–A3 (P0.03/P0.28/P0.29) |
| PWM + RC filter on a spare pin | Possible | Cheapest. Lower quality |
| USB Audio Class 1 (device → host "microphone") | Possible | Would be a class-compliant input on macOS and iPadOS/iOS (USB-C or camera adapter). `embassy-usb` 0.6 ships only a UAC1 *speaker* class, so the input side must be written and link-tested |
| USB-MIDI / BLE-MIDI (send control, phone synthesises) | Possible | `embassy-usb` has a MIDI class. BLE adds at least one connection interval (7.5 ms Bluetooth minimum; phones often use longer) |
| BLE audio stream (Omi-style GATT notifications) | Not recommended for live play | Connection interval + codec frames + phone buffering are far above 10 ms. See [omi-integration.md](omi-integration.md) |

## Tests and demo

```sh
cargo test -p motion-synth -p lsm6ds3trc
make synth-demo        # dist/motion-synth-demo.wav: scripted tilt sweep, rotation and taps
cargo run -p motion-synth --example render_wav -- out.wav 48000 128
```

Test vectors cover: oscillator pitch within 1 % at 16/32/48 kHz; pluck decay ratio; silence without input; bounded finite output under NaN/∞/extreme parameters; bit-identical output for block sizes 32/64/128; parameter-step smoothing; polynomial sine and `tan` accuracy; calibration, motion-reset of calibration, static tilt convergence, gyro integration, tap refractory, timestamp gaps, roll wrap; mailbox latest-wins/event accumulation; PCM frame golden bytes and CRC (shared with the Python parser tests).
