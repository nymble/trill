# SPDX-License-Identifier: GPL-3.0-only
# Host checks need only a Rust toolchain. Cross targets need the rustup target,
# cargo-zigbuild and Zig (see docs/build.md).

CARGO   ?= cargo
VERSION := $(shell sed -n 's/^version = "\(.*\)"/\1/p' Cargo.toml | head -1)
PI_ZERO := arm-unknown-linux-musleabihf
PI_A64  := aarch64-unknown-linux-musl
X86     := x86_64-unknown-linux-musl
DIST    := dist

.PHONY: all ci fmt fmt-check clippy test check-thumb build pi-zero pi-arm64 x86-musl dist clean

all: ci

ci: fmt-check clippy test check-thumb

fmt:
	$(CARGO) fmt --all

fmt-check:
	$(CARGO) fmt --all -- --check

clippy:
	$(CARGO) clippy --workspace --all-targets -- -D warnings

test:
	$(CARGO) test --workspace

# Driver only: Cortex-M4F (nRF52840). No firmware binary is produced.
check-thumb:
	$(CARGO) build -p trill-driver --target thumbv7em-none-eabihf

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
	rm -rf $(DIST)
