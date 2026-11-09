Trillium (companion app for the Trill instrument): unsigned development builds
=============================================================================

These files come from the CI workflow of https://github.com/nymble/trill.
They are development builds, not releases. Licence: GPL-3.0-only (see the
repository; commercial terms in COMMERCIAL-LICENSE.md).

Trillium-macOS-unsigned-dev-<version>.zip
  Universal (Apple Silicon + Intel) macOS 13+ app. NOT notarized and NOT
  signed with a Developer ID: it carries only the linker's ad-hoc
  signature, so its entitlements (App Sandbox) are not applied.
  Gatekeeper will block it after download. Open it only if you trust the
  build and have checked SHA256SUMS:
    - macOS 15 or newer: try to open it once, then System Settings >
      Privacy & Security > "Open Anyway".
    - macOS 13/14: right-click Trillium.app > Open.
    - or: xattr -dr com.apple.quarantine Trillium.app
  For a sandboxed build signed by you, build it from source in Xcode with
  your own team (docs/apple-app.md).

Trillium-iOS-Simulator-<version>.zip
  For the iOS Simulator only (xcrun simctl install booted Trillium.app).
  It cannot be installed on an iPhone or iPad. For a device, build from
  source in Xcode with your own team.

The app talks to Trill firmware 0.2.0 or newer over USB MIDI; its Sensors
tab needs firmware 0.3.0 or newer, and the sensor modes (tilt notes,
theremin), controller assignment, tap sensitivity and flick gestures on the
Mapping tab need firmware 0.4.0. With older firmware those controls are
disabled and never sent. Firmware 0.3.0 (telemetry, Sensors tab, tap
percussion) has been checked on one XIAO Sense from a Mac; the firmware 0.4.0
modes and gestures have only been tested in simulation, not on hardware.
The app never
writes firmware: its Mac firmware page only checks a UF2 file and shows
commands for you to run.
