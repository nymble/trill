# xiao-sense-fw

Embassy firmware for the Seeed XIAO nRF52840 Sense: class-compliant USB-MIDI 1.0 + CDC diagnostics, driven by a Trill on D4/D5 and the LSM6DS3TR-C IMU through the [`instrument-events`](../../crates/instrument-events) engine. Optional `pcm-synth` feature: the [motion synth](../../crates/motion-synth) and its PCM test stream.

Not yet run on hardware. Build, safe loading (backup first, application-only UF2), pins, memory layout and the bring-up checklist: [docs/firmware-xiao-sense.md](../../docs/firmware-xiao-sense.md). USB-MIDI setup and acceptance: [docs/usb-midi.md](../../docs/usb-midi.md); mapping: [docs/midi-mapping.md](../../docs/midi-mapping.md).

```sh
cargo build --release --locked      # ELF: target/thumbv7em-none-eabihf/release/xiao-sense-fw
cargo build --release --locked --features pcm-synth   # optional debug synth build
make -C ../.. fw-uf2                # validated UF2 in dist/ (never written to a device)
```
