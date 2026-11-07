# SPDX-License-Identifier: GPL-3.0-only
# Host checks need only a Rust toolchain. Cross targets need the rustup target,
# cargo-zigbuild and Zig (see docs/build.md). Firmware needs the
# thumbv7em-none-eabihf target and python3 (see docs/firmware-xiao-sense.md).
# No target here talks to a device: loading firmware is a separate, explicit
# step with tools/xiao_uf2.py.

CARGO   ?= cargo
VERSION := $(shell sed -n 's/^version = "\(.*\)"/\1/p' Cargo.toml | head -1)
PI_ZERO := arm-unknown-linux-musleabihf
PI_A64  := aarch64-unknown-linux-musl
X86     := x86_64-unknown-linux-musl
DIST    := dist
FW_DIR  := firmware/xiao-sense
FW_ELF  := $(FW_DIR)/target/thumbv7em-none-eabihf/release/xiao-sense-fw
FW_UF2  := $(DIST)/xiao-sense-fw-$(VERSION).uf2

.PHONY: all ci fmt fmt-check clippy test tools-test check-thumb fw fw-check fw-uf2 synth-demo build pi-zero pi-arm64 x86-musl dist clean

all: ci

ci: fmt-check clippy test tools-test check-thumb fw-check

fmt:
	$(CARGO) fmt --all
	cd $(FW_DIR) && $(CARGO) fmt

fmt-check:
	$(CARGO) fmt --all -- --check
	cd $(FW_DIR) && $(CARGO) fmt -- --check

clippy:
	$(CARGO) clippy --workspace --all-targets -- -D warnings

test:
	$(CARGO) test --workspace

tools-test:
	python3 -m unittest discover -s tools -p 'test_*.py'

# no_std libraries for Cortex-M4F (nRF52840).
check-thumb:
	$(CARGO) build -p trill-driver -p lsm6ds3trc -p motion-synth --target thumbv7em-none-eabihf

# XIAO nRF52840 Sense firmware: lint + linked release ELF + UF2 safety check.
fw-check:
	cd $(FW_DIR) && $(CARGO) clippy --release --locked -- -D warnings
	$(MAKE) fw-uf2

fw:
	cd $(FW_DIR) && $(CARGO) build --release --locked

# Application-only UF2 (0x27000..0xEC000), validated; written to dist/, never to a device.
fw-uf2: fw
	mkdir -p $(DIST)
	python3 tools/xiao_uf2.py convert $(FW_ELF) -o $(FW_UF2)
	python3 tools/xiao_uf2.py inspect $(FW_UF2)

# Render the scripted motion demo to dist/motion-synth-demo.wav on the host.
synth-demo:
	mkdir -p $(DIST)
	$(CARGO) run --release -p motion-synth --example render_wav -- $(DIST)/motion-synth-demo.wav

build:
	$(CARGO) build --release -p trill-cli

# Raspberry Pi Zero / Zero W / Pi 1 (ARMv6, hard-float), static musl.
pi-zero:
	$(CARGO) zigbuild --release -p trill-cli --target $(PI_ZERO)

# Raspberry Pi 3/4/5 running a 64-bit OS, static musl.
pi-arm64:
	$(CARGO) zigbuild --release -p trill-cli --target $(PI_A64)

x86-musl:
	$(CARGO) zigbuild --release -p trill-cli --target $(X86)

# Package every built target into dist/ with SHA-256 checksums.
dist:
	rm -rf $(DIST) && mkdir -p $(DIST)
	for t in $(PI_ZERO) $(PI_A64) $(X86); do \
	  bin=target/$$t/release/trill; \
	  [ -f $$bin ] || continue; \
	  d=trill-$(VERSION)-$$t; mkdir -p $(DIST)/$$d; \
	  cp $$bin LICENSE COMMERCIAL-LICENSE.md README.md $(DIST)/$$d/; \
	  tar -C $(DIST) -czf $(DIST)/$$d.tar.gz $$d; rm -rf $(DIST)/$$d; \
	done
	cd $(DIST) && sha256sum *.tar.gz > SHA256SUMS && cat SHA256SUMS

clean:
	$(CARGO) clean
	cd $(FW_DIR) && $(CARGO) clean
	rm -rf $(DIST)
