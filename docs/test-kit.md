# Trill test kit (Mac app + matching XIAO firmware)

A development bundle built by CI (`trill-test-kit-unsigned-dev` artifact) or
locally with `make test-kit`. Everything in it comes from one commit, named in
the folder (`Trill-<version>-<commit>`) and in `MANIFEST.txt`. It is not a
release, it is not notarized, and the firmware has **not** been validated on
hardware. Check `SHA256SUMS` first (`shasum -a 256 -c SHA256SUMS`).

| File | What |
|---|---|
| `Trill-macOS-unsigned-dev-<version>.zip` | Universal macOS 13+ app, ad-hoc signed only |
| `firmware/xiao-sense-fw-<version>.uf2` | Application-only UF2 (0x27000+, bootloader and SoftDevice untouched) |
| `tools/xiao_uf2.py` | Checks a UF2 and copies it to the XIAO drive only when asked |
| `docs/` | App, configuration/telemetry protocol, firmware and USB MIDI docs |

## Bring-up

1. **Firmware.** The Sensors tab needs firmware 0.3.0 or newer; older firmware
   still plays MIDI and the app says "Sensors unsupported until the firmware is
   updated". To update: double-press RESET on the XIAO so the `XIAO-SENSE`
   drive appears, then
   `python3 tools/xiao_uf2.py info /Volumes/XIAO-SENSE` (note the Board-ID),
   `python3 tools/xiao_uf2.py flash --drive /Volumes/XIAO-SENSE --board-id <Board-ID> firmware/xiao-sense-fw-<version>.uf2`
   (dry run), and the same command with `--write` to copy it. The tool refuses
   full-flash dumps and anything outside the application region.
   Keep your own backup of the previous firmware outside this folder.
2. **App.** Unzip and open `Trill.app`. Gatekeeper blocks unsigned apps: on
   macOS 15+ try once, then System Settings › Privacy & Security › Open Anyway.
3. **Connect.** Device tab: port 2 ("…Port 2") is the configuration port. Press
   Connect.
4. **Sensors tab.** Move the board: acceleration (g), rotation rate (°/s),
   pitch/roll, Trill touch and stream health update live. Charts show the last
   10 s; gaps and stale periods are left blank, never drawn through.
5. **MIDI tab.** Logs what port 1 sends (CoreMIDI time, channel, decoded
   message), with clock filtering, rates and CSV export.

Microphone, battery level and heading (yaw) are not available with this
firmware and board, and the app says so instead of showing values.
