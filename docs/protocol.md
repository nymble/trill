# Trill I²C protocol notes

This is a summary of the parts of the Trill Rev C protocol (datasheet v1.3, §7) that `trill-driver` implements, with behaviour cross-checked against Bela's Trill-Linux and Trill-Arduino libraries.

## Transactions

- **Write:** the first byte sets the memory offset, and the remaining bytes are written from that offset. A 1-byte write only moves the read pointer.
- **Read:** reads start at the offset set by the last write.
- An offset outside the R/W region (writes) or outside memory (reads) is NACKed.

| Offset | Access | Content |
|---|---|---|
| 0–2 | R/W | Command code + up to 2 args (write); acknowledgement `[0xFE, b0, b1]` (read) |
| 3 | R/O | Status: bits 5:0 frame ID, bit 6 activity, bit 7 initialised (firmware ≥ 3) |
| 4–63 | R/O | Payload |

## Commands used

| Code | Name | Args | Driver |
|---|---|---|---|
| 1 | Mode | mode (0 centroid, 1 raw, 2 baseline, 3 diff) | `set_mode` |
| 2 | ScanSettings | speed 0–3, bits 9–16 | `set_scan_settings` |
| 3 | Prescaler | 0–8 (÷1 … ÷256) | `set_prescaler` |
| 4 | NoiseThreshold | u8 counts | `set_noise_threshold` |
| 5 | Idac | u8 | `set_idac` |
| 6 | UpdateBaseline | — | `update_baseline` |
| 7 | MinimumSize | u16 BE | `set_minimum_size` |
| 12 | Reset | — (no ACK; wait 500 ms) | `reset` (firmware ≥ 3) |
| 255 | Identify | — → `[0xFE, type, firmware]` | `identify` |

Not implemented yet: 8 AdjacentCentroidNoiseThreshold, 9 EventMode, 10/11 ChannelMask, 13 Format, 14 AutoScanTimer, 15 ScanTrigger.

## Timing

| Situation | Behaviour | Origin |
|---|---|---|
| After Identify | wait 25 ms, then poll 3 bytes at offset 0 until byte 0 = 0xFE | Trill-Arduino delay; datasheet listing 1 |
| Command, firmware ≥ 3 | poll offset 0 at 1, 2, 4 … 64 ms intervals until 0xFE; give up after ≥ 200 ms (`Error::NoAck`) | Trill-Linux `waitForAck` |
| Command, firmware < 3 | fixed 15 ms, no ACK | Trill-Arduino `interCommandDelay` |
| Read-pointer move | wait 1 ms after the 1-byte offset write | Trill-Linux |

All waits use `embedded_hal::delay::DelayNs`. Firmware < 3 is detected when Identify never returns 0xFE but byte 1 is a valid type and byte 2 is 1 or 2. This path is best-effort and untested; Rev C sensors report firmware 3.

## Device types and defaults

| Code | Device | Default address | Channels | Library default mode / prescaler |
|---|---|---|---|---|
| 1 | Bar | 0x20 | 26 | centroid / 2 |
| 2 | Square | 0x28 | 30 | centroid / 1 |
| 3 | Craft | 0x30 | 30 | diff / 1 |
| 4 | Ring | 0x38 | 30 | centroid / 2 |
| 5 | Hex | 0x40 | 30 | centroid / 1 |
| 6 | Flex | 0x48 | 30 | centroid / 4 |

`Config::for_device` uses the Trill-Linux defaults: speed 0, 12 bits, and a noise threshold of 40/4096 of full scale (Flex: 0.03, i.e. 123 counts at 12 bits). The Trill-Arduino library uses diff mode for Flex. The datasheet lists centroid as the default for Flex.

## Centroid payload (1-axis: Bar, Craft, Ring, Flex)

The payload is 20 bytes (Ring: 24, including 2 extra pad values): five big-endian u16 **locations**, then five u16 **sizes**. The touch list ends at the first location equal to `0xFFFF`, so a frame of all `0xFFFF` means no touch. The decoder never reads past the buffer or beyond 5 touches.

- **Location:** `0 ..= 128 × (pads − 1)`. Flex: 30 pads → **0–3712**. `Touch::normalised(Device::Flex)` = `location / 3712`, clamped to 0.0–1.0. The datasheet figures for each sensor show where 0 is and which way values increase.
- **Size:** the sum of the differential readings of the pads in the touch. It is relative and uncalibrated, and it grows with contact area (≈ pressure). It scales with the bit depth and prescaler. Trill-Linux divides Flex size by 1200 (at 12 bits) to get a rough 0–1 value; `trill-driver` reports the raw value.

2-axis centroid data (Square, Hex: 32 bytes, Y then X) is not decoded yet.

## Raw / Baseline / Diff payload

With the default Format (16-bit, shift 0) and all channels enabled, each channel is a big-endian u16, contiguous from offset 4. Flex: 30 channels = **60 bytes**. Values range from 0 to 2^bits − 1 (12-bit default: 0–4095). In diff mode a value is the activation above the baseline. The noise threshold zeroes small values. Values are relative counts, not capacitance in farads.

## Practical notes

- Update the baseline (done by `init`) with nothing touching the sensor.
- Trill firmware ≥ 3 starts a new scan after every I²C transaction by default (ScanTrigger 1). Reading faster than a scan completes returns the previous frame, which the status byte's frame ID can detect.
