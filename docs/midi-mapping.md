# MIDI mapping: sensor events → MIDI

What the firmware sends, derived from the implementation in [`crates/instrument-events`](../crates/instrument-events) (engine, MIDI encoder) and [`firmware/xiao-sense`](../firmware/xiao-sense) (sensor tasks, USB writer). Defaults are `instrument_events::Config::default()`. Every statement in **Implemented** is covered by a host test in `crates/instrument-events/tests/`, unless it is marked *firmware*. Firmware statements build and link but have **not been run on hardware**.

Transport and setup: [USB MIDI](usb-midi.md).

## Implemented

### Inputs

| Input | Source and rate | Units / normalisation | Filtering |
|---|---|---|---|
| Touch position | Trill Flex centroid mode, **first reported touch only**. Polled every 5 ms; only frames with a new Trill frame ID are used (*firmware*) | `location / 3712` → 0.0–1.0 along the strip, clamped | None (sensor centroid) |
| Touch size | Same frame | Raw size / 300 at 10-bit scan (Trill-Linux factor 1/1200 at 12 bits, × 2<sup>12−bits</sup>) → ≈ 0–1, not clamped above 1 (*firmware*) | Hysteresis thresholds; one-pole smoothing for pressure |
| Rotation | LSM6DS3TR-C gyro, every 833 Hz ODR sample (*firmware* 0.5.0; 416 Hz before) | Magnitude of the bias-corrected gyro vector, deg/s (sign-free) | One-pole τ = 30 ms in `motion-synth` |
| Tilt pitch | Same IMU sample | Degrees, −90…90: `atan2(−ax, √(ay² + az²))` in the IMU's own axes, complementary filter τ = 0.5 s. Which physical tilt is positive is **not yet verified** on a board ([bring-up step 5](firmware-xiao-sense.md#hardware-bring-up-checklist)) | As left |
| Tilt roll | Same IMU sample | Degrees, −180…180: `atan2(ay, az)`, complementary filter as pitch | As left |
| Angular rate per axis | Same IMU sample | Bias-corrected gyro X, Y, Z, deg/s, unsmoothed (used by flick gestures) | None |
| Tap | Same IMU sample | High-passed \|a\| above 0.8 g (50 ms baseline; settable 0.3–4 g from 0.4.0), 120 ms refractory (settable 50–1000 ms); strength = g above the threshold | Detector in `motion-synth` |

**What the sensors can and cannot tell.** Pitch and roll are tilt relative to gravity; rotation is how fast the board turns about any axis. There is no magnetometer, so **no heading/yaw**, and the IMU cannot track **position** (double-integrating acceleration drifts within a second). Turning flat on a table changes rotation speed but not pitch or roll.

**Touch size is a capacitive contact-area value, not force.** It grows with contact area and proximity and depends on finger, scan bits, prescaler and the sensor. It is sent as channel pressure only because that is the nearest standard MIDI message. No calibration to force exists.

Timestamps are `u32` microseconds from the firmware's monotonic clock (*firmware*: touch = start of the poll, motion = data-ready wake), wrapping every ~71.6 min. All comparisons wrap safely: elapsed times are `now.wrapping_sub(then)` as `u32` (correct for any interval under 71.6 min), and the 1 s tap/gesture arm delay is a latch set once when it first elapses, so it cannot expire again. Firmware 0.3.0 and earlier compared `before(now, since + 1 s)` with a signed difference, which flips after 2³¹ µs: **taps stopped making notes after 35.8 min of continuous calibration and came back 35.8 min later**, and a controller unchanged for over 35.8 min or a sensor returning after a 35.8 min gap could be held off the same way. Fixed in 0.4.0; tests cover 37, 60, 72, 100 and 150 min and a run across the u32 wrap. This explains tap notes stopping during long sessions; it does not explain every report of "missing" channel-10 notes, some of which were the notes being hidden among sensor SysEx in a monitor (see the [Apple app](apple-app.md) monitor notes). A sample older than the previous one of the same input is ignored and counted (`stale_in`). Non-finite values (NaN, ±∞) are rejected and counted (`invalid`). Out-of-range finite values are clamped.

### Output messages (channel 1 unless stated)

| Event | MIDI message | Status / CIN | Value mapping (defaults) |
|---|---|---|---|
| Touch onset | Pitch bend, then **Note On** | `E0` / `0xE`, then `90` / `0x9` | Note = 48 + quantised(position × 24). Velocity = 30 + 97 × clamp((size − 0.05) / 0.55): 30 at the onset threshold, 127 at size ≥ 0.6. Never 0 |
| Finger slides (bend mode) | Pitch bend, 14-bit | `E0` / `0xE` | 8192 + (s − note offset) / 24 × 8191, clamped to ±24 semitones (0…16383; extremes 1 and 16383). Sent LSB then MSB |
| Finger slides (steps mode) | Note Off old, then Note On new | `80`, `90` | When the finger is > 0.1 semitone past the midpoint towards the next scale note (hysteresis 0.2 in "distance difference") |
| Contact size while held | **Channel pressure** | `D0` / `0xD` (2-byte message, padded with 0 in the USB packet) | 127 × clamp((size − 0.025) / 0.575), smoothed τ = 15 ms |
| Lift (size < 0.025 or no touch) | **Note Off** (velocity 64), then pressure 0 | `80` / `0x8`, `D0` | Pitch bend is left where it was; the next onset sets it before its Note On |
| Controller A (default rotation) | **CC74** (brightness), configurable 0.4.0+ | `B0` / `0xB` | 127 × clamp(rotation / 360 dps) |
| Controller B (default forward tilt) | **CC1** (modulation), configurable 0.4.0+ | `B0` / `0xB` | 127 × clamp(pitch / 60°); backward tilt → 0 |
| Tilt-mode expression (0.4.0+, off by default) | CC chosen by param 24 | `B0` | Same value as channel pressure |
| Flick (0.4.0+, off by default) | Note On/Off on the percussion channel, notes n / n+1 / n+2 | `99`, `89` | Velocity 64 + 63 × clamp((rate − threshold) / threshold); Note Off 60 ms later |
| Tap (off by default, key `t`) | Note On / Note Off on **channel 10**, note 39 | `99`, `89` | Velocity 40 + 87 × clamp(strength / 3 g). Note Off 60 ms later. A new tap ends the previous one first |

USB-MIDI 1.0 packets: `[cable << 4 | CIN, status, data1, data2]`, cable 0. Every data byte is ≤ 127.

**Pitch.** Position s = location × 24 semitones. *Chromatic* rounds to the nearest semitone, *pentatonic* to the nearest of 0, 2, 4, 7, 9 (+ octaves) above note 48, both limited to the strip (notes 48–72). *Bend mode* (default) chooses the note at onset and then bends continuously, so pitch follows the finger. The synth's bend range must match: the engine sends RPN 0 = 24 semitones on connect (below), but not every synth honours RPN 0.

**Onset rules.** A note starts only when (1) the transport is connected, (2) the engine is *armed*, which needs one frame with no touch (or size < 0.025) since start-up, connect, panic, sensor loss or a mapping change, and (3) size ≥ 0.05. So nothing sounds at start-up or from a finger left on the strip across a reconnect. Motion never starts the touch voice.

**Motion gating.** CC74 and CC1 are sent only after gyro calibration (`calibrated`), while IMU frames keep arriving, and while motion controls are enabled (key `x`). Taps need calibration plus 1 s. If IMU frames stop for 100 ms, or the IMU task reports failure, any percussion note is released and CC74/CC1 go to 0. Touch is unaffected.

**Single voice.** One touch voice on one channel. With several fingers on the strip, the engine sees only the touch the Trill reports first. Its order is the sensor's, not "first finger down", so the voice can jump to another finger. This is a known limitation of this milestone.

### Sensor modes and controllers (firmware 0.4.0)

Set over SysEx (page 1, [configuration protocol](config-protocol.md#parameters)) or from the app's Settings › Sound & mapping; RAM only. **Simulated and unit-tested only; not yet run on hardware.**

- **Touch (default).** As above.
- **Tilt notes.** The Trill strip is ignored. A virtual touch is made from the IMU: tilting forward past the gate (default 15°, closes 3° lower) starts a note; roll picks the position across the note range (−span → lowest note, +span → highest, default ±45°), quantised to the scale with the step hysteresis (default 20% of a step), so the note does not flicker between neighbours. Velocity and channel pressure follow how far past the gate you tilt (40–100% of full). Always stepped notes.
- **Theremin.** Same gate and roll, but pitch is continuous: the note is chosen at the gate and roll then bends it (always bend mode). **Set the synth's pitch-bend range to the device's bend range** (param 6, default ±24, also sent as RPN 0, which not every synth honours). An optional expression CC (param 24, e.g. CC11) mirrors pressure for volume.
- **Controllers A and B.** Each has a source (rotation, pitch forward/back, roll right/left, pitch/roll centred) and a CC number 1–119. "Back" and "left" are inversions. A deadzone (0–50%) is applied around 0, or around the centre for centred sources, and the rest is rescaled to the full range. Smoothing is a one-pole filter with time constant 0–500 ms: lag is bounded by that constant (63% of a step after one constant, 95% after three). Changing a source or number, or switching controllers off, first sends 0 on the old number so nothing is left stuck. In tilt modes the controllers keep running, so a controller fed by the axis that plays pitch duplicates it; the presets switch them off or use rotation.
- **Orientation zero** (action 5). Pitch and roll are measured from the orientation at that moment instead of from flat. Cleared by restore defaults and lost on reset.
- **Stuck-note safety.** Any change to mode, channel, pitch mode, bend range or scale releases the voice, percussion and gesture notes. Calibration loss, IMU loss (100 ms) or disconnect release the tilt voice. A tilt note does not restart until the gate has been closed again.
- **Priority.** Tilt-mode and gesture notes use the same critical queue as touch notes. In every USB packet the firmware puts instrument messages (cable 0, Port 1) first; configuration replies and sensor telemetry (cable 1, Port 2) only fill the space left, and a telemetry frame is loaded only when no reply is waiting.

### Gestures (firmware 0.4.0, experimental, off by default)

Recognised from the bias-corrected angular rate about one chosen sensor axis (param 27). A **flick** fires on the first sample at or above the threshold (default 400 °/s) once the rate has dropped below 30% of the threshold since the previous flick and the cooldown (default 300 ms) has passed. So holding a fast rotation fires once, and the quick return swing after a flick is ignored. Negative rate plays note n, positive n + 1 (default 60/61, percussion channel). An opposite flick within cooldown + 400 ms of the previous one is a **zig-zag** and also plays n + 2. Gestures need calibration plus 1 s and a connected host. Unit tests cover thresholds, cooldown, return swing, held rotation and zig-zag. Which physical direction is "negative" depends on mounting. **Circle and twirl recognition is not implemented** (deferred: it needs orientation integration and a validated recorded data set).

### Priority, coalescing and backpressure

`next_message()` returns, in order:
1. an emergency CC123 if a Note Off ever failed to fit (should not happen; counted as `emerg_off`);
2. the **critical FIFO** (32 entries): Note On/Off, the bend that precedes a Note On, and the reset sequence;
3. **continuous slots**, in the order pressure, expression CC, bend, controller A (CC74), controller B (CC1). Each slot holds only its latest value, so updates **coalesce** (`coal`) instead of queueing. A slot is sent only if it moved past its deadband (0.75 of a 7-bit step; 4 counts of 14-bit bend) and at most once per 4 ms (≤ 250 Hz per controller). Pressure 0 at release bypasses the rate limit.

A Note On is queued only if **4 critical slots stay free** after it, so the matching Note Off always fits. If the queue is that full, the Note On is deferred and retried on the next frame (`defer`). The queue-flood test drives 400 frames while draining one message per 10 ms and checks that every Note On has its Note Off.

*Firmware:* the USB task fills packets of up to 15 events (60 bytes, always a short packet). A write is never abandoned while the host is slow: each 100 ms it is still pending counts as a `stall`. Meanwhile the sensor tasks keep running, controllers coalesce, and Note Ons are deferred. The writer wakes on new input or every 2 ms for timeouts.

### Connect, disconnect and panic

| Event | Engine action |
|---|---|
| Connect (host configured the device, not suspended; *firmware*) | Drop anything queued, disarm, then queue: CC123 0, CC120 0, bend 8192, pressure 0, RPN 0 = 24 semitones (CC101 0, CC100 0, CC6 24, CC38 0), RPN null (CC101 127, CC100 127). Then CC123, CC120, bend 8192 on channel 10 |
| Disconnect: unplug, bus reset, deconfigure or suspend (*firmware*), or write error | Drop the queue, forget the active note and percussion note, disarm. The engine holds nothing that could sound later |
| Panic (key `p`) | Same as connect, while connected |
| Touch sensor lost (4 read errors, *firmware*) or no new touch frame for 50 ms | Note Off for the active note, disarm |
| Mapping change (keys `k`, `q`, `t`, `x`) | Note Off for the active note, disarm. If the mode, bend range or channel changed: reset sequence for the channel |

**Host caveat.** Notes the host was holding when the cable was pulled can only be cleared by the host or by the reset sequence on the next connection. USB-MIDI has no way to send a Note Off after unplug.

### Example trace

From `cargo run -p instrument-events --example trace`, asserted byte for byte by the `documented_trace` test. Gesture: connect; motion calibrated and still; finger up; touch at the middle (location 0.5, size 0.3); slide to 0.625 while rotating at 90 dps and tilting 15°; lift.

```
 time us  USB-MIDI packet  message
       0  0B B0 7B 00      CC123 All Notes Off, ch 1
       0  0B B0 78 00      CC120 All Sound Off
       0  0E E0 00 40      Pitch bend 8192 (centre)
       0  0D D0 00 00      Channel pressure 0
       0  0B B0 65 00      CC101 0  ┐
       0  0B B0 64 00      CC100 0  │ RPN 0 (pitch-bend range)
       0  0B B0 06 18      CC6 24   │ = 24 semitones
       0  0B B0 26 00      CC38 0   ┘
       0  0B B0 65 7F      CC101 127 ┐ RPN null
       0  0B B0 64 7F      CC100 127 ┘
       0  0B B9 7B 00      CC123, ch 10
       0  0B B9 78 00      CC120, ch 10
       0  0E E9 00 40      Pitch bend 8192, ch 10
    1000  0B B0 4A 00      CC74 0 (rotation 0)
    1000  0B B0 01 00      CC1 0 (flat)
    5000  0E E0 00 40      Pitch bend 8192 (finger exactly on note 60)
    5000  09 90 3C 4A      Note On 60, velocity 74
    5000  0D D0 3D 00      Channel pressure 61
   10000  0E E0 00 48      Pitch bend 9216 (+3 semitones)
   10000  0B B0 4A 20      CC74 32 (90 dps)
   10000  0B B0 01 20      CC1 32 (15°)
   15000  08 80 3C 40      Note Off 60, velocity 64
   15000  0D D0 00 00      Channel pressure 0
```

### Not implemented in this milestone

- Circle / twirl gestures, yaw and position (see above).
- Battery and charge status are not reported (no MIDI or diagnostics field). See [XIAO power](design-xiao-nrf52840.md#power-usb-and-battery).
- Settings are not stored: map changes from keys or the configuration protocol are lost on reset.
- Host → device MIDI on the instrument cable is read and discarded.

## Proposed (not implemented)

- **MPE / multi-touch:** one channel per touch with persistent touch IDs (Trill reports touches in no stable order), per-note bend, pressure and CC74. Needs touch tracking first.
- **Touch calibration:** per-unit size scaling and thresholds from a recorded light and firm touch, stored in flash.
- **Stored settings.** All 30 map parameters, including controller numbers (0.4.0), are configurable over SysEx, RAM only: see [configuration protocol](config-protocol.md).
- **BLE-MIDI** transport (deferred until a licensing decision on the BLE stack, see [roadmap](roadmap.md)).

## Directional strikes (firmware 0.5.0)

**Simulated and unit-tested only; not yet run on hardware.** Off by default (parameter 31 = 0), so taps behave exactly as in 0.4.0.

When a tap fires, the motion processor also reports the direction the board was **travelling** when it was stopped: the acceleration at the detection sample minus the gravity estimate (pitch/roll from the complementary filter, which runs gyro-only during the impact because |a| is far from 1 g), negated and normalised, expressed as `[down, forward, right]`. Down follows gravity. Forward is the sensor X axis projected onto the horizontal plane (sensor −Y turned 90° when X points nearly straight up or down), and right completes the frame. Both a strike against a surface and a stroke stopped sharply in mid-air decelerate the board, so both report the direction of travel.

With 2, 4 or 6 directions, the engine picks the largest of the considered components (down/up; then left/right; then forward/back). It plays the note set for that direction on the percussion channel if that component is at least 0.55 (about 57° from the axis) and at least 1.2 times the next considered component. Otherwise the strike is ambiguous: it plays the plain percussion note (parameter 13) and counts `strikes_ambiguous`. Velocity is the tap velocity, as before. The decision is made on the detection sample, so it adds no latency. Which physical side is "left" or "forward" depends on how the board is mounted; swap the notes in the app if needed.

| Direction | Parameter | Default note (GM) |
|---|---|---|
| Down | 32 | 38 snare |
| Up | 33 | 49 crash |
| Left | 34 | 36 kick |
| Right | 35 | 42 closed hi-hat |
| Forward | 36 | 45 low tom |
| Back | 37 | 51 ride |

The accelerometer range is ±8 g from 0.5.0 (±4 g before), so hard taps no longer clip; clipping flattened velocity and would distort the direction.

