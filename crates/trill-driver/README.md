# trill-driver

A `no_std` Rust driver for Bela Trill capacitive touch sensors, generic over the `embedded-hal` 1.0 `I2c` and `DelayNs` traits. It runs on Linux (`linux-embedded-hal`) and on microcontrollers (for example nRF52840).

- Identify with acknowledgement polling. Errors are typed: `NoAck`, `NotDetected`, `WrongDevice`, and others.
- Configuration: mode, scan settings, prescaler, noise threshold, IDAC, minimum size, baseline, reset.
- Bounded decoding of 1-axis centroid frames (Flex, Bar, Ring, Craft) and 16-bit Raw/Baseline/Diff frames.

See [docs/protocol.md](../../docs/protocol.md) for the wire format and value scaling. This is an independent implementation, not affiliated with Bela. Licence: GPL-3.0-only, with commercial terms available (see the repository root).
