# xiao-sense-fw

Embassy firmware for the Seeed XIAO nRF52840 Sense: USB CDC diagnostics and PCM test stream, LSM6DS3TR-C motion, optional Trill on D4/D5, and the audio-rate [motion synth](../../crates/motion-synth).

Not yet run on hardware. Build, safe loading (backup first, application-only UF2), pins, memory layout and the bring-up checklist: [docs/firmware-xiao-sense.md](../../docs/firmware-xiao-sense.md).

```sh
cargo build --release --locked      # ELF: target/thumbv7em-none-eabihf/release/xiao-sense-fw
make -C ../.. fw-uf2                # validated UF2 in dist/ (never written to a device)
```
