# Trill test kit (Mac app + matching XIAO firmware)

A development bundle attached to each GitHub Release, also built by CI
(`trillium-test-kit-unsigned-dev` artifact) or locally with `make test-kit`. Everything in it comes from one commit, named in
the folder (`Trillium-<version>-<commit>`) and in `MANIFEST.txt`. It is not
notarized, and the firmware has **not** been validated on
hardware. Check `SHA256SUMS` first (`shasum -a 256 -c SHA256SUMS`).

| File | What |
|---|---|
| `Trillium-macOS-unsigned-dev-<version>.zip` | Universal macOS 13+ app, ad-hoc signed only |
| `firmware/xiao-sense-fw-<version>.uf2` | Application-only UF2 (0x27000+, bootloader and SoftDevice untouched) |
| `tools/xiao_uf2.py` | Checks a UF2 and copies it to the XIAO drive only when asked |
| `docs/` | App, configuration/telemetry protocol, firmware and USB MIDI docs |

## Bring-up

1. **Firmware.** Use the firmware from the same kit: the app's newest
   features (directional strikes) need 0.5.0, sensor modes and gestures
   0.4.0, the Sensors tab 0.3.0; with older firmware those controls are
   disabled and never sent. To update: double-press RESET on the XIAO so the
   `XIAO-SENSE` drive appears, then
   `python3 tools/xiao_uf2.py info /Volumes/XIAO-SENSE` (note the Board-ID),
   `python3 tools/xiao_uf2.py flash --drive /Volumes/XIAO-SENSE --board-id <Board-ID> firmware/xiao-sense-fw-<version>.uf2`
   (dry run), and the same command with `--write` to copy it. The tool refuses
   full-flash dumps and anything outside the application region.
   Keep your own backup of the previous firmware outside this folder.
2. **App.** Unzip and open `Trillium.app`. Gatekeeper blocks unsigned apps: on
   macOS 15+ try once, then System Settings › Privacy & Security › Open Anyway.
3. **Connect.** Home shows "Trillium found": press Connect (or turn on
   *Connect automatically*). Ports can be checked under Settings › Connection.
4. **Presets.** Choose a sound; it is sent straight away. *Drum strikes*
   (firmware 0.5.0) plays a different drum for down, sideways and forward hits.
5. **Sensors tab.** Move the board: acceleration (g), rotation rate (°/s),
   pitch/roll, Trill touch and stream health update live. Charts show the last
   10 s; gaps and stale periods are left blank, never drawn through.
6. **Settings.** Sound & mapping is the full editor (mode, notes, controllers,
   taps and strikes, gestures). MIDI monitor logs what port 1 sends, with
   filtering, rates and CSV export.

### What to test on hardware with 0.4.0 (not yet done)

- Taps still make notes after more than 36 minutes connected (the 0.3.0 bug)
  and across 72 minutes (clock wrap).
- Tilt scale: gate opens about 15° forward, notes step cleanly while rolling,
  no stuck notes when switching preset, recalibrating or unplugging.
- Theremin: synth bend range ±24, continuous pitch, CC11 expression.
- Controller A/B source and number changes, deadzone, smoothing lag.
- Tap threshold/cooldown; flick gestures on each axis (which direction is
  "negative" depends on mounting), zig-zag, no repeat from a held rotation.
- Orientation zero, and that restore defaults clears it.
- Instrument (port 1) timing unaffected while the Sensors tab streams.

Microphone, battery level and heading (yaw) are not available with this
firmware and board, and the app says so instead of showing values.
