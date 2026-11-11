# Building

## Requirements

| Purpose | Needs |
|---|---|
| Host build, tests, lint | Rust stable (edition 2021) with `rustfmt` and `clippy`. The driver MSRV is 1.81 |
| Cortex-M4F libraries and XIAO Sense firmware | `rustup target add thumbv7em-none-eabihf`. The firmware's Embassy dependencies use edition 2024, so it needs Rust 1.85 or newer |
| Tool tests, UF2 conversion | `python3` (standard library only) |
| Static Linux cross builds | the rustup target, [`cargo-zigbuild`](https://github.com/rust-cross/cargo-zigbuild), and Zig (`pip install ziglang` provides `python3 -m ziglang`) |
| `make` shortcuts | GNU make (optional; each target is a plain `cargo` command) |
| Apple apps (macOS / iOS) | macOS with Xcode 16 or newer and XcodeGen 2.45.4. Details in [apple-app.md](apple-app.md) |

None of the builds or tests needs a Trill sensor or `/dev/i2c-*`.

## Host checks

```sh
make ci                     # all of the following
cargo fmt --all -- --check
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace      # driver, IMU, motion-synth, MIDI engine, USB descriptor tests; CLI arg tests
python3 -m unittest discover -s tools -p 'test_*.py'
cargo build -p trill-driver -p lsm6ds3trc -p motion-synth -p status-led -p instrument-events -p trill-usb -p trill-config --target thumbv7em-none-eabihf
make protocol-vectors       # regenerate protocol/config-v1-vectors.txt (CI fails if it is stale)
(cd firmware/xiao-sense && cargo clippy --release --locked -- -D warnings)
(cd firmware/xiao-sense && cargo clippy --release --locked --features pcm-synth -- -D warnings)
make fw-uf2                 # link default USB-MIDI firmware, convert + validate UF2 into dist/
make fw-uf2-pcm             # optional debug synth build (pcm-synth)
```

Cargo aliases in `.cargo/config.toml` provide the same checks: `cargo ci-fmt`, `cargo ci-clippy`, `cargo ci-test`, `cargo check-thumb`.

The CLI only works on Linux. On macOS it compiles to a stub that exits with an error, so `cargo test --workspace` still passes there.

## Apple and firmware: one place for each output

| Output | Command | Signed? | CI artifact |
|---|---|---|---|
| Default USB-MIDI firmware UF2 (application-only) | `make fw-uf2` → `dist/xiao-sense-fw-<version>.uf2` | n/a (SHA-256 only) | `xiao-sense-fw-unvalidated-on-hardware` (`xiao-sense-fw.uf2`) |
| `pcm-synth` debug firmware UF2 | `make fw-uf2-pcm` | n/a | same artifact (`xiao-sense-fw-pcm-synth.uf2`) |
| TrillKit tests (host / iPhone Simulator / iPad Simulator) | `make apple-test`, `make apple-test-ios-sim`, `make apple-test-ipad-sim` | no | – |
| macOS app (Release, universal) | `make apple-mac` | ad-hoc linker signature only | `trillium-apple-apps-unsigned-dev` (`Trillium-macOS-unsigned-dev-<version>.zip`) |
| iOS app for the iPhone and iPad Simulator | `make apple-ios-sim` | no | same artifact (`Trillium-iOS-Simulator-<version>.zip`) |
| iPad Simulator screenshots | `make apple-ipad-sim` | no | `trillium-ipad-simulator-screenshots` |
| iOS app for devices | `make apple-ios-device` | no: compile check only, **not installable** | – |
| Development IPA for a physical iPhone or iPad | `make apple-ios-ipa` (Mac with Xcode and `Local.xcconfig`; not used by regular CI) | signed with your team | – |
| Everything Apple (unsigned) | `make apple` (then `make apple-dist`) | | |
| Test kit: Mac app + iOS Simulator app + matching firmware UF2 + `xiao_uf2.py` + docs + `MANIFEST.txt` + `SHA256SUMS` | `make test-kit` after `apple-mac apple-ios-sim apple-dist fw-uf2` (or set `KIT_APP`, `KIT_IOS`, `KIT_UF2`) → `dist/Trillium-<version>-<commit>.zip` | app: ad-hoc only | `trillium-test-kit-unsigned-dev` |

Sign and install on your own devices from Xcode, or with `make apple-ios-ipa`, using your own team ([apple-app.md](apple-app.md#run-and-install)). No signing identity, team or profile is stored in the repository. Regular CI and release jobs never sign.

## Targets

| Target triple | Hardware | Make target | Status |
|---|---|---|---|
| `x86_64-unknown-linux-gnu` / host | development machine | `make build` | built + tested in CI |
| `arm-unknown-linux-musleabihf` | **Pi Zero / Zero W / Pi 1** (ARMv6 + VFPv2, hard-float) | `make pi-zero` | cross-built in CI; static binary, `Tag_CPU_arch: v6`. Not run on hardware |
| `aarch64-unknown-linux-musl` | Pi 3/4/5, Zero 2 W running a 64-bit OS | `make pi-arm64` | cross-built in CI; not run on hardware |
| `x86_64-unknown-linux-musl` | Linux PCs (for example with a USB-I²C adapter exposing `/dev/i2c-N`) | `make x86-musl` | built in the release workflow |
| `thumbv7em-none-eabihf` | nRF52840 (XIAO) | `make check-thumb` | `no_std` libraries |
| macOS 13+ (arm64 + x86_64) | Mac | `make apple-mac` | built in CI on macOS 15 / Xcode 16.4, unsigned. Not tested with hardware |
| iOS / iPadOS 16+ | iPhone, iPad, Simulator | `make apple-ios-sim`, `make apple-ios-device`, `make apple-ipad-sim`, `make apple-ios-ipa` | Simulator build, iPad launch/screenshots, and device compile check in CI, unsigned. A development IPA needs a local team; no physical iPad install has been tested |
| `thumbv7em-none-eabihf` | XIAO nRF52840 Sense firmware | `make fw-uf2`, `make fw-uf2-pcm` | default USB-MIDI and `pcm-synth` builds: linked ELFs + application-only UF2s in CI (artifact, not a release). Not run on hardware. See [firmware-xiao-sense.md](firmware-xiao-sense.md) |

**Pi Zero W is ARMv6.** Binaries for `armv7-*` targets fail on it with "Illegal instruction". Rust's `arm-unknown-linux-*` targets generate ARMv6 code, but many distribution cross-GCC packages (`arm-linux-gnueabihf-gcc`) default to ARMv7. For that reason this project links with Zig through `cargo-zigbuild` and checks the output with `readelf`. Binaries built for `arm-unknown-linux-musleabihf` also run on 32-bit Pi OS installs on newer Pis.

### Cross-building for the Pi Zero (ARMv6)

```sh
rustup target add arm-unknown-linux-musleabihf
cargo install --locked cargo-zigbuild
python3 -m pip install ziglang==0.17.0.post0   # in a venv/pipx if pip is externally managed; or install zig from ziglang.org
cargo zigbuild --release -p trill-cli --target arm-unknown-linux-musleabihf
readelf -A target/arm-unknown-linux-musleabihf/release/trill | grep Tag_CPU_arch   # v6
```

This matches the ZPOD project's toolchain (`arm-unknown-linux-musleabihf` + `cargo-zigbuild`). The binary is fully static, so it runs on Buildroot/BusyBox images as well as Raspberry Pi OS.

### Native build on a Pi

```sh
cargo build --release -p trill-cli     # produces target/release/trill
```

Building on a 512 MB Pi Zero is slow. Cross-compiling is recommended.

## Layout

```
crates/trill-driver   no_std Trill driver (embedded-hal 1.0)
crates/trill-cli      Linux binary `trill`
crates/lsm6ds3trc     no_std IMU driver
crates/motion-synth   no_std motion processing + synth (host demo: examples/render_wav.rs)
crates/status-led     no_std RGB status LED selection, timing and pin driver
crates/trill-config   no_std SysEx configuration protocol (device side + request encoders)
protocol/             protocol test vectors shared by Rust and Swift
apple/                Swift package TrillKit, SwiftUI app sources, XcodeGen spec (project.yml)
firmware/xiao-sense   Embassy firmware, own workspace + Cargo.lock (excluded from the root workspace)
tools/                xiao_uf2.py, pcm_capture.py, tests
docs/                 designs, firmware, protocol, build, release, roadmap, Omi integration
.github/workflows     ci.yml, release.yml
```

Both `Cargo.lock` files are committed so that application and firmware builds are reproducible. The firmware is not part of the tag-driven release workflow yet; CI publishes it only as a short-lived workflow artifact.
