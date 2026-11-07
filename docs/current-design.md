# Current design and implementation status

Snapshot of what is on `main` after [PR #1](https://github.com/nymble/trill/pull/1) (merge `6aaa73d`, 2026-11-07). It describes the code as written; rates are the configured values read from the source, not measurements. **Nothing below has run on hardware yet.**

## Block diagram (XIAO nRF52840 Sense firmware)

```
                       ┌──────────────────────── nRF52840 (64 MHz Cortex-M4F) ─────────────────────────┐
 Trill Flex ──I²C 100k─┤ thread: trill_task  poll every 5 ms ─► TOUCH (latest touch, Cell)            │
 (0x48, D4/D5)         │                                            │ read only by imu_task           │
 LSM6DS3TR-C ─I²C 400k─┤ thread: imu_task  INT1 data-ready 416 Hz ─► MotionProcessor ─► map() ─────┐   │
 (internal, INT1 P0.11)│                       (gyro bias, tilt, rotation, tap)        │           │   │
                       │                                          LAST_MOTION (diag)   ▼           │   │
                       │ high P5: audio_task every 2 ms ◄── MAILBOX (latest params + tap count) ◄─┘   │
                       │   synth 32 kHz, 64-sample block ─► PCM queue (8 blocks) ─┐                    │
                       │ med P6: usb_task ── CDC 0: text diagnostics / debug keys  │                    │
                       │                   └ CDC 1: framed PCM test stream ◄──────┘                    │
                       │ thread: led_task (20 ms), health_task                                         │
                       └───────────────────────────────────────────────────────────────────────────────┘
                                 │ USB full speed (two CDC ACM ports, VID:PID 1209:0001 test ID)
                                 ▼
                     host: serial terminal, tools/pcm_capture.py → WAV
```

There is **no audible output on the device** today: no I²S/DAC/PWM audio, no USB Audio class, no USB-MIDI, no BLE. The synth output only leaves the board as a test stream on a CDC serial port, which DAWs do not see as audio.

## What runs, with real rates

| Path | What the code does | Rate / timing (configured, from source) |
|---|---|---|
| IMU read | Waits for INT1 data-ready (20 ms timeout, then polls anyway), one burst read per sample | 416 Hz ODR → 2.4 ms period; every sample is processed |
| Motion | Gyro bias from 400 still samples; complementary tilt filter τ = 0.5 s; rotation magnitude one-pole τ = 30 ms; tap = \|a\| above a 50 ms baseline by 0.8 g, 120 ms refractory | per IMU sample |
| Tilt | Pitch and roll come from gravity plus gyro. **Yaw is not observable**: the LSM6DS3TR-C has no magnetometer, so heading would drift | — |
| Trill | Centroid read of the first touch only (`location`, `size`), every 5 ms; retry with backoff when absent | 5 ms poll; ≈ 2.3 ms per 20-byte read at 100 kHz |
| Trill scan | Speed 0 (ultra fast), 12 bits, all 30 channels: 30 × 205 µs ≈ **6.2 ms nominal per scan** ([Bela scan table](https://learn.bela.io/using-trill/settings-and-sensitivity/)). The scan is longer than the 5 ms poll, so some reads probably return the previous frame (the frame-ID check is not implemented yet) | effective new-frame rate < 200 Hz |
| Mapping | `map()` runs **only inside the IMU task**. Touch affects sound only when an IMU sample arrives, and **not at all if the IMU is missing** | 416 Hz |
| Audio | Block render on a P5 interrupt executor, deadline from the sample count; late/resync counters | 32 kHz, 64 samples = 2 ms |
| Synth smoothing | One-pole on frequency/cutoff/level, τ = 4 ms; pluck attack 2 ms | per sample |
| USB | Two CDC ACM ports; the PCM port is active while the host holds DTR | full speed (12 Mbit/s) |
| LED | Priority status indication, 20 ms tick ([details](firmware-xiao-sense.md#status-led)) | 50 Hz |

## Status

| Item | Compiled | Host-tested | On hardware |
|---|---|---|---|
| `trill-driver` (Pi and MCU) | yes | mock-I²C byte vectors | no |
| `lsm6ds3trc` | yes (thumbv7em) | mock I²C | no |
| `motion-synth` (motion, mapping, synth, mailbox, stream) | yes | test vectors, WAV demo | no |
| `status-led` | yes | 18 tests | no |
| XIAO Sense firmware | links, UF2 checks in CI | — | **never flashed** |
| `trill` Linux CLI | x86, ARMv6, aarch64 | argument tests | no |
| USB-MIDI, BLE, I²S output, mic, MPE | not started | — | — |

## Known limitations found while reviewing (to fix before latency work)

1. **Touch is coupled to the IMU frame rate** and is lost without the IMU. Touch events should go straight to the event and transport layer.
2. **The Trill scan (≈ 6.2 ms) is longer than the poll period (5 ms).** Options from Bela: 9–10 bits (≈ 1.7–2.3 ms for 30 channels), a channel mask, timer-driven scanning, and the EVT pin to wake the reader ([Bela forum, 2026-10](https://forum.bela.io/d/8604-latency-and-jitter-for-trill-sensors)). Use the status-byte frame ID to detect stale frames.
3. **Only the first touch is used.** There is no multi-touch tracking or touch IDs, which MPE would need.
4. **The rotation-driven level/resonance lags** by the 30 ms smoothing (63 % after 30 ms). That is fine for swells, but too slow for attacks. Attacks come from taps, which are not smoothed.
5. The motion → audio latency budget in [motion-synth.md](motion-synth.md#latency-budget) is a calculation. On-device `ctl_age` measures only part of it.

The forward plan is in [music-connectivity.md](music-connectivity.md).
