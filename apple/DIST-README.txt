Trill companion app: unsigned development builds
================================================

These files come from the CI workflow of https://github.com/nymble/trill.
They are development builds, not releases. Licence: GPL-3.0-only (see the
repository; commercial terms in COMMERCIAL-LICENSE.md).

Trill-macOS-unsigned-dev-<version>.zip
  Universal (Apple Silicon + Intel) macOS 13+ app. NOT notarized and NOT
  signed with a Developer ID: it carries only the linker's ad-hoc
  signature, so its entitlements (App Sandbox) are not applied.
  Gatekeeper will block it after download. Open it only if you trust the
  build and have checked SHA256SUMS:
    - macOS 15 or newer: try to open it once, then System Settings >
      Privacy & Security > "Open Anyway".
    - macOS 13/14: right-click Trill.app > Open.
    - or: xattr -dr com.apple.quarantine Trill.app
  For a sandboxed build signed by you, build it from source in Xcode with
  your own team (docs/apple-app.md).

Trill-iOS-Simulator-<version>.zip
  For the iOS Simulator only (xcrun simctl install booted Trill.app).
  It cannot be installed on an iPhone or iPad. For a device, build from
  source in Xcode with your own team.

The app talks to Trill firmware 0.2.0 or newer over USB MIDI; its Sensors
tab needs firmware 0.3.0 or newer. Firmware 0.2.0 has been checked on one
XIAO Sense from a Mac; firmware 0.3.0 telemetry and the Sensors tab have not
run on hardware yet. The app never
writes firmware: its Mac firmware page only checks a UF2 file and shows
commands for you to run.
