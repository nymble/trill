# SPDX-License-Identifier: GPL-3.0-only
# Host checks need only a Rust toolchain. Cross targets need the rustup target,
# cargo-zigbuild and Zig (see docs/build.md). Firmware needs the
# thumbv7em-none-eabihf target and python3 (see docs/firmware-xiao-sense.md).
# Apple targets need macOS with Xcode 16+ and XcodeGen (see docs/apple-app.md).
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

.PHONY: all ci fmt fmt-check clippy test tools-test check-thumb fw fw-check fw-uf2 fw-uf2-pcm synth-demo build pi-zero pi-arm64 x86-musl dist clean \
        protocol-vectors apple apple-project apple-test apple-test-ios-sim apple-mac apple-ios-sim apple-ios-device apple-dist test-kit

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
	$(CARGO) build -p trill-driver -p lsm6ds3trc -p motion-synth -p status-led -p instrument-events -p trill-usb -p trill-config --target thumbv7em-none-eabihf

# Regenerate the configuration-protocol test vectors shared with the Swift tests.
protocol-vectors:
	$(CARGO) run -q -p trill-config --example vectors > protocol/config-v1-vectors.txt
	$(CARGO) run -q -p trill-config --example vectors -- telemetry > protocol/telemetry-v1-frames.txt

# XIAO nRF52840 Sense firmware: lint + linked release ELF + UF2 safety check.
fw-check:
	cd $(FW_DIR) && $(CARGO) clippy --release --locked -- -D warnings
	cd $(FW_DIR) && $(CARGO) clippy --release --locked --features pcm-synth -- -D warnings
	$(MAKE) fw-uf2-pcm
	$(MAKE) fw-uf2

fw:
	cd $(FW_DIR) && $(CARGO) build --release --locked

# Application-only UF2 (0x27000..0xEC000), validated; written to dist/, never to a device.
fw-uf2: fw
	mkdir -p $(DIST)
	python3 tools/xiao_uf2.py convert $(FW_ELF) -o $(FW_UF2)
	python3 tools/xiao_uf2.py inspect $(FW_UF2)

# Optional debug build: on-board synth + PCM CDC port (USB PID 1209:0003).
fw-uf2-pcm:
	cd $(FW_DIR) && $(CARGO) build --release --locked --features pcm-synth
	mkdir -p $(DIST)
	python3 tools/xiao_uf2.py convert $(FW_ELF) -o $(DIST)/xiao-sense-fw-pcm-synth-$(VERSION).uf2
	python3 tools/xiao_uf2.py inspect $(DIST)/xiao-sense-fw-pcm-synth-$(VERSION).uf2

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

# ---- Apple (macOS host only) ---------------------------------------------
# Unsigned builds (CODE_SIGNING_ALLOWED=NO): the macOS app is linker
# ad-hoc signed only; the iOS device build is a compile check, not an
# installable IPA. Sign and install from Xcode with your own team instead.
APPLE    := apple
APPLE_DD := build/apple
XCODEGEN ?= xcodegen
XCB      := xcodebuild -project $(APPLE)/Trillium.xcodeproj -derivedDataPath $(APPLE_DD) CODE_SIGNING_ALLOWED=NO

apple: apple-test apple-mac apple-ios-sim apple-ios-device apple-dist

# Generate apple/Trillium.xcodeproj from apple/project.yml (not committed).
apple-project:
	cd $(APPLE) && $(XCODEGEN) generate --spec project.yml

# TrillKit tests on the host (macOS: also the CoreMIDI loopback tests;
# Linux: protocol/model/UF2 tests only).
apple-test:
	swift test --package-path $(APPLE)/TrillKit

apple-test-ios-sim:
	cd $(APPLE)/TrillKit && xcodebuild test -scheme TrillKit -destination "id=$$(python3 ../scripts/pick_simulator.py)" CODE_SIGNING_ALLOWED=NO

apple-mac: apple-project
	$(XCB) -scheme TrilliumMac -configuration Release -destination 'generic/platform=macOS' build

apple-ios-sim: apple-project
	$(XCB) -scheme TrilliumIOS -configuration Debug -destination 'generic/platform=iOS Simulator' build

apple-ios-device: apple-project
	$(XCB) -scheme TrilliumIOS -configuration Release -destination 'generic/platform=iOS' build

# Zip the built apps into dist/apple with SHA-256 sums.
apple-dist:
	rm -rf $(DIST)/apple && mkdir -p $(DIST)/apple
	ditto -c -k --keepParent $(APPLE_DD)/Build/Products/Release/Trillium.app $(DIST)/apple/Trillium-macOS-unsigned-dev-$(VERSION).zip
	ditto -c -k --keepParent $(APPLE_DD)/Build/Products/Debug-iphonesimulator/Trillium.app $(DIST)/apple/Trillium-iOS-Simulator-$(VERSION).zip
	cp $(APPLE)/DIST-README.txt $(DIST)/apple/README.txt
	cd $(DIST)/apple && shasum -a 256 *.zip > SHA256SUMS && cat SHA256SUMS

# ---- Test kit: Mac app + matching firmware for bring-up -------------------
# Packages already-built inputs (no build, no device access):
#   KIT_APP  macOS app zip   (make apple-mac apple-dist, macOS only)
#   KIT_UF2  application-only UF2 for the same commit (make fw-uf2)
# into dist/Trillium-<version>-<commit>/ plus a zip of it. The kit holds only
# repository build outputs, tools and docs; never add device backups.
KIT_SHA ?= $(shell git rev-parse --short=7 HEAD 2>/dev/null || echo unknown)
KIT_APP ?= $(DIST)/apple/Trillium-macOS-unsigned-dev-$(VERSION).zip
KIT_UF2 ?= $(FW_UF2)
KIT     := Trillium-$(VERSION)-$(KIT_SHA)
SHA256  := $(shell command -v sha256sum >/dev/null 2>&1 && echo sha256sum || echo shasum -a 256)

test-kit:
	@test -f "$(KIT_APP)" || { echo "missing $(KIT_APP) (make apple-mac apple-dist)"; exit 1; }
	@test -f "$(KIT_UF2)" || { echo "missing $(KIT_UF2) (make fw-uf2)"; exit 1; }
	@grep -q "^MARKETING_VERSION = $(VERSION)$$" $(APPLE)/Config/Base.xcconfig || { echo "app MARKETING_VERSION != $(VERSION)"; exit 1; }
	rm -rf $(DIST)/$(KIT) $(DIST)/$(KIT).zip
	mkdir -p $(DIST)/$(KIT)/firmware $(DIST)/$(KIT)/tools $(DIST)/$(KIT)/docs
	cp "$(KIT_APP)" $(DIST)/$(KIT)/Trillium-macOS-unsigned-dev-$(VERSION).zip
	cp "$(KIT_UF2)" $(DIST)/$(KIT)/firmware/xiao-sense-fw-$(VERSION).uf2
	python3 tools/xiao_uf2.py inspect $(DIST)/$(KIT)/firmware/xiao-sense-fw-$(VERSION).uf2
	cp tools/xiao_uf2.py $(DIST)/$(KIT)/tools/
	cp docs/test-kit.md $(DIST)/$(KIT)/README.md
	cp docs/apple-app.md docs/config-protocol.md docs/firmware-xiao-sense.md docs/usb-midi.md LICENSE $(DIST)/$(KIT)/docs/
	printf 'name=%s\nversion=%s\ncommit=%s\napp=Trillium-macOS-unsigned-dev-%s.zip (unsigned, ad-hoc)\nfirmware=firmware/xiao-sense-fw-%s.uf2 (application-only, 0x27000+)\nminimum_firmware_for_sensors=0.3.0\nminimum_firmware_for_modes_and_gestures=0.4.0\nhardware_validated=no\n' \
	  "$(KIT)" "$(VERSION)" "$(KIT_SHA)" "$(VERSION)" "$(VERSION)" > $(DIST)/$(KIT)/MANIFEST.txt
	cd $(DIST)/$(KIT) && find . -type f ! -name SHA256SUMS | LC_ALL=C sort | sed 's|^\./||' | xargs $(SHA256) > SHA256SUMS && cat SHA256SUMS
	cd $(DIST) && zip -qr $(KIT).zip $(KIT) && ls -l $(KIT).zip

clean:
	$(CARGO) clean
	cd $(FW_DIR) && $(CARGO) clean
	rm -rf $(DIST) $(APPLE_DD)
