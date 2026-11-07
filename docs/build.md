# Building

## Requirements

| Purpose | Needs |
|---|---|
| Host build, tests, lint | Rust stable (edition 2021) with `rustfmt` and `clippy`. The driver MSRV is 1.81 |
| Cortex-M4F driver check (XIAO) | `rustup target add thumbv7em-none-eabihf` |
| Static Linux cross builds | the rustup target, [`cargo-zigbuild`](https://github.com/rust-cross/cargo-zigbuild), and Zig (`pip install ziglang` provides `python3 -m ziglang`) |
| `make` shortcuts | GNU make (optional; each target is a plain `cargo` command) |

None of the builds or tests needs a Trill sensor or `/dev/i2c-*`.

## Host checks

```sh
make ci                     # all of the following
cargo fmt --all -- --check
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace      # driver unit + protocol tests (mock I2C), CLI arg tests
cargo build -p trill-driver --target thumbv7em-none-eabihf
```

Cargo aliases in `.cargo/config.toml` provide the same checks: `cargo ci-fmt`, `cargo ci-clippy`, `cargo ci-test`, `cargo check-thumb`.

The CLI only works on Linux. On macOS it compiles to a stub that exits with an error, so `cargo test --workspace` still passes there.

## Targets

| Target triple | Hardware | Make target | Status |
|---|---|---|---|
| `x86_64-unknown-linux-gnu` / host | development machine | `make build` | built + tested in CI |
| `arm-unknown-linux-musleabihf` | **Pi Zero / Zero W / Pi 1** (ARMv6 + VFPv2, hard-float) | `make pi-zero` | cross-built in CI; static binary, `Tag_CPU_arch: v6`. Not run on hardware |
| `aarch64-unknown-linux-musl` | Pi 3/4/5, Zero 2 W running a 64-bit OS | `make pi-arm64` | cross-built in CI; not run on hardware |
| `x86_64-unknown-linux-musl` | Linux PCs (for example with a USB-I²C adapter exposing `/dev/i2c-N`) | `make x86-musl` | built in the release workflow |
| `thumbv7em-none-eabihf` | nRF52840 (XIAO) | `make check-thumb` | driver library only; no firmware binary |

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
crates/trill-driver   no_std library (embedded-hal 1.0)
crates/trill-cli      Linux binary `trill`
docs/                 designs, protocol, build, release, roadmap
.github/workflows     ci.yml, release.yml
```

`Cargo.lock` is committed so that application builds are reproducible.
