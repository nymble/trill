# Connecting to Mac and iPhone for music: research, trade-offs and plan

Question: how should the Trill + XIAO nRF52840 Sense instrument talk to a Mac or iPhone for music creation, with the best practical latency and expressiveness? Options covered: USB-MIDI, Bluetooth LE MIDI, custom BLE messages, custom USB, and where the sound should be generated.

Sources were checked on **2026-11-07** and are listed at the end as [S1]…[S22]. Every latency figure here is labelled as one of:

- *calculation*: arithmetic from a spec or configuration;
- *manufacturer claim*;
- *third-party measurement*;
- *target*: a goal for our tests.

**No figure is our own measurement.** Nothing has run on hardware yet; see [current-design.md](current-design.md).

## Recommendation in brief

1. **Make the host the primary sound engine.** Mac or iPhone/iPad instruments, DAWs and AUv3 synths are far richer than a Cortex-M4 voice, and they already own a low-latency audio path to wired headphones or an interface. Keep the MCU synth as an optional standalone and test path. It is not needed for the main workflow.
2. **USB-MIDI 1.0 first** (class-compliant, composite with the existing CDC diagnostics port):
   - Its timing is typically more consistent than wireless, it is powered by the cable, and it needs no driver on macOS or iOS [S1][S2][S5]. Host and endpoint scheduling still have to be measured.
   - USB-C iPhones connect directly. Lightning devices need Apple's camera adapter [S6][S7].
   - The firmware's pinned `embassy-usb` 0.6.0 already contains a USB-MIDI class.
3. **BLE-MIDI second**, after USB is measured:
   - It gives wireless freedom with standard Audio MIDI Setup / CoreAudioKit pairing [S3][S4].
   - New events wait for the next connection event: a scheduling window of 0 up to one negotiated connection interval (CI), about CI/2 on average for randomly timed events. Queuing and retries add to that, and the PHY rate does not remove the wait [S8][S9][S10]. The interval actually granted must be measured.
   - Before starting, resolve the GPL vs Nordic-controller licensing question (below).
4. **For this project, we recommend against a custom BLE protocol as the music path.** It needs our own iOS/macOS app (Safari has no Web Bluetooth [S18]) and gives up DAW interoperability. Its only use would be an *optional* diagnostics/raw-sensor characteristic later.
5. **We recommend against a custom USB protocol or USB Audio as the first step.** CDC stays for diagnostics only. USB Audio class output only helps if on-device synthesis becomes a product goal.
6. **Fix the sensor path before any transport work:**
   - Shorten the Trill scan and make reads event-driven.
   - Decouple touch from the IMU frame.
   - Add a transport-independent, timestamped event layer with priorities and stuck-note handling.

| | USB-MIDI 1.0 | BLE-MIDI | Custom BLE GATT | Custom USB (CDC + bridge) |
|---|---|---|---|---|
| Works with DAWs/AUv3 without our app | **Yes** (CoreMIDI) [S1] | **Yes**, after pairing in Audio MIDI Setup or in-app [S3][S4] | No: needs our CoreBluetooth app or bridge | No: needs our bridge to a virtual MIDI port |
| Mac | Yes | Yes | App needed | Bridge needed |
| iPhone/iPad | USB-C direct; Lightning via camera adapter [S6][S7] | Yes; pairing UI must be offered by the app (CoreAudioKit) [S3] | App needed | Not practical on iOS |
| Transport scheduling | USB full-speed 1 ms frames; bulk transfers, several per frame possible; host/OS polling varies, so no guaranteed per-event bound [S2]. Measure | Wait for the next connection event: 0 to one CI (≈ CI/2 average), plus queuing/retries. BLE-MIDI requires the device to request ≤ 15 ms [S8]; Apple *guidance* asks for Interval Min ≥ 15 ms [S9], while 7.5 ms was *observed* with an iPhone as Central [S20]. Measure the granted CI | Same radio scheduling as BLE-MIDI | Same as USB-MIDI, plus bridge scheduling |
| Jitter control | Host polling + CoreMIDI | 13-bit ms timestamps in every packet [S8] | Our own timestamps | Our own timestamps |
| Expressiveness | MIDI 1.0: 7-bit CC, 14-bit pitch bend, MPE per-note [S11] | Same messages as USB-MIDI | Unlimited (raw floats) | Unlimited |
| Power | Bus-powered; iPhone USB-C supplies up to 900 mA (4.5 W) [S5] | Battery (XIAO has a charger) | Battery | Bus-powered |
| Effort and risk | Low; library support exists | Medium; BLE stack + licence decision + radio scheduling next to audio | High; two apps | Medium; bridge app per OS |

## 1. What the sound path really is

End-to-end latency is the sum of the following stages; transport is only one of them.

| Stage | USB-MIDI to host synth | Notes |
|---|---|---|
| Sensor acquisition | IMU: 0–2.4 ms wait + ≈ 0.4 ms read. Trill today: up to ≈ 6.2 ms scan + 0–5 ms poll + ≈ 2.3 ms read | *Calculation* from the configuration ([current-design.md](current-design.md)); the IMU's internal filter delay is not characterised |
| Event generation (onset detection, mapping) | µs on the MCU | To measure with a GPIO toggle |
| Transport | Assumed ≈ 0–1 ms frame scheduling, plus host stack | *Provisional scheduling assumption*, not a spec bound: bulk scheduling depends on the host controller and OS. Measure it |
| Host MIDI → synth | App-dependent; most synths apply events at the next audio buffer | Unmeasured |
| Host audio output buffer | Table below | *Calculation* of one buffer only |
| Converter and headphones | Interface-specific | Use wired output. Bluetooth headphones add codec buffering that varies by device; we make no numeric claim |

One host audio buffer (*calculation*: samples ÷ rate). This is not the end-to-end latency: drivers usually run at least one input and one output buffer, plus converter delay.

| Buffer | 44.1 kHz | 48 kHz |
|---|---|---|
| 32 samples | 0.73 ms | 0.67 ms |
| 64 samples | 1.45 ms | 1.33 ms |
| 128 samples | 2.90 ms | 2.67 ms |

**The audio engine choice is about the workflow, not the transport.** A host synth fed by MIDI gives the DAW workflow, recording, presets and wired low-latency monitoring. An MCU synth only beats that if:

- the device has its own analog output (I²S DAC, not built yet), and
- the use case is standalone or wearable.

Streaming MCU audio to the phone over BLE is not a viable monitoring path:

- the nRF52840 has no classic Bluetooth, so no A2DP;
- BLE Audio/LC3 is out of scope here;
- the current USB PCM stream is a test port, not USB Audio.

## 2. USB-MIDI (recommended first)

- **Standard.** USB Device Class Definition for MIDI Devices 1.0: 32-bit event packets on bulk endpoints [S2].
- **Apple.**
  - Accessory Design Guidelines R32 §43 requires USB-MIDI 1.0 or 2.0 with a MIDI Streaming IN endpoint, verified with Audio MIDI Setup [S1].
  - CoreMIDI then exposes the device to every MIDI app with no driver.
  - LinnStrument is a real-world example: "fully USB Class Compliant, using the standard Mac, Windows and Linux drivers" [S15].
- **Silicon.**
  - The nRF52840 has a USB 2.0 full-speed (12 Mbit/s) device controller [S12].
  - `embassy-usb` 0.6.0 (already in our lockfile) ships `class::midi` (AudioControl + MIDIStreaming interfaces on bulk endpoints). It can be combined with the existing CDC diagnostics port as a composite device.
  - Keep the PCM test port behind a feature flag so the default enumeration stays simple.
- **iPhone/iPad.**
  - USB-C iPhones connect standard USB-C accessories directly and may supply accessory power up to 900 mA / 4.5 W, depending on the model [S5][S6].
  - Lightning devices use the Lightning to USB (3) Camera Adapter, which Apple lists for "Audio/MIDI interfaces and devices". The USB 3 version can take external power [S7].
  - The XIAO's on-board charger (BQ25101) will try to charge a connected LiPo from the phone's VBUS. Budget for that, or disconnect the battery when tethered.
- **Expressiveness limits and the fix.**
  - MIDI 1.0 CC values are 7-bit: 128 steps. Over a 60° tilt span that is ≈ 0.47° per step (*calculation*), which is audible as zipper noise on filters unless the synth smooths it.
  - For the main continuous axes, use 14-bit pitch bend and 14-bit CC pairs (MSB CC n + LSB CC n+32), where the host supports them.
  - Pitch bend is 14-bit (16 384 steps):
    - ±2 semitones → ≈ 0.024 cent per step;
    - MPE's ±48 semitone default for member channels [S11] → ≈ 0.59 cent per step (*calculation*).
    - Both are finer than a Trill Flex location step mapped over 2 octaves (2400 cents / 3712 counts ≈ 0.65 cent).
  - MPE (MIDI Polyphonic Expression v1.1) gives each note its own channel, so each note gets its own pitch bend, CC74 timbre and channel pressure [S11]. LinnStrument, Orba and Seaboard all use it [S15][S16].
  - Cost of MPE: bandwidth and synth support. LinnStrument documents stuck notes on overloaded hosts and sends USB-MIDI "at 3.7 times the rate of the MIDI OUT jack", with a data-reduction setting [S15].
  - MIDI 2.0/UMP: Apple accepts USB-MIDI 2.0 devices [S1]. It adds 32-bit controllers and per-note controllers, but host and synth support varies. Defer it until MIDI 1.0 + MPE is measured.

## 3. Bluetooth LE MIDI (recommended second)

- **Standard.** MIDI Association BLE-MIDI 1.0(a) [S8]:
  - one GATT service and one characteristic;
  - 13-bit millisecond timestamps in every packet;
  - the device "must request a connection interval of 15 ms or less".
  - The spec says, as a general statement about the transport, that the connection interval "places a lower bound on latency" and that delivery delays "may occur unexpectedly at any time". This is quoted, not a per-event minimum; see the scheduling-window explanation below.
- **Apple.**
  - ADG R32 §43 requires BLE-MIDI 1.0a [S1].
  - §57.6 gives general connection-parameter *guidance*: requests may be rejected unless Interval Min is ≥ 15 ms and a multiple of 15 ms; it also notes that with BLE HID connected, "a connection interval down to 11.25 ms may be accepted by some devices" [S9]. QA1931 states the same rules [S10].
  - This is request policy, not a guaranteed or universal negotiated minimum. The Central decides; Microsoft *observed* an iPhone as Central negotiating 7.5 ms [S20]. Nothing here implies that HID is required for MIDI.
  - An older Apple MIDI-specific recommendation (try 11.25 ms, then fall back to 15 ms) is quoted by Silicon Labs [S19]; we did not find that text in R32. **Log the interval actually granted** by each Mac/iPhone during tests.
  - Pairing:
    - macOS: Audio MIDI Setup → MIDI Studio → Configure Bluetooth [S4].
    - iOS: the music app must present `CABTMIDICentralViewController`, and many apps do. Connections are always paired/secure and drop after several idle minutes [S3].
- **Connection interval: a scheduling window, not a per-event floor.** The spec quote above ("places a lower bound on latency") describes the transport in general. It is not a minimum latency for every event.
  - An event generated just before a connection event can go out almost immediately.
  - Events arriving at random times wait 0 up to one CI before transmission, about CI/2 on average (*calculation*), then host overhead.
  - The wait grows with queuing (more data than fits in one event), retransmissions under interference, and missed events.
  - If the receiver schedules by timestamp, it may deliberately add delay to even out jitter. Whether a given iOS/macOS app does this is untested.
  - BLE 2M PHY (supported by the nRF52840 [S12]) shortens air time per packet and helps with queued data. It does not change the connection-event timing.
  - Several packets per connection event raise throughput and reduce queuing, not the base scheduling wait.
  - So wireless options cannot be ranked from PHY rate alone. Measure the distribution (p50/p95/p99).
  - Microsoft's BLE-MIDI notes (*third-party measurement*, one Windows PC): Windows as Central settled at 15 ms; an iPhone as Central negotiated 7.5 ms with a Windows peripheral [S20]. These are not Apple-Mac numbers.
- **Products.**
  - Genki states 7–20 ms overall over BLE MIDI and recommends a USB dongle for jittery systems (*manufacturer claim*) [S13].
  - CME claims "as low as 3 ms" between two of its own WIDI devices in "low latency mode", and sells a USB dongle to "bypass wireless MIDI limitations of iOS/macOS" (*manufacturer claim*) [S17].
  - Observation from the products reviewed here: the lowest claimed wireless figures come from vendors that control **both ends** of the link.
- **Firmware cost on nRF52840.**
  - A BLE controller (Nordic SoftDevice Controller via `nrf-sdc` + `trouble-host`, or the S140 SoftDevice already on the board via `nrf-softdevice`) reserves the highest interrupt priority for radio timing [S21]. Our P5 audio executor would be preempted by radio events, so check the audio late/resync counters under BLE load.
  - Use the IMU and Trill paths unchanged. Only the transport changes.
- **Licensing.** See the licensing section below; decide before writing BLE code.

## 4. Custom BLE messages (GATT)

Pros:

- full-resolution floats;
- raw IMU and touch frames with device timestamps;
- batching several frames per connection event.

Cons:

- every user needs **our** app: CoreBluetooth on iOS/macOS, a bridge to a virtual CoreMIDI port, or an AUv3. Safari/WebKit opposes Web Bluetooth, so a web app cannot do it on iPhone [S18];
- the same connection-event scheduling window and jitter as BLE-MIDI;
- a second GATT service shares connection events with MIDI if both run.

Omi's accelerometer service is not a precedent: it notifies at 1 Hz and is off by default ([omi-integration.md](omi-integration.md)).

**Project recommendation:** an optional, later, diagnostics-only characteristic (raw frames for calibration and research) next to standard BLE-MIDI, rather than the primary music path.

## 5. Custom USB (current CDC) vs USB-MIDI vs USB Audio

- **CDC + host bridge** works on macOS but not on iOS without MFi-style work, and no DAW sees it. Keep it for diagnostics and the PCM test.
- **USB Audio (UAC)** carries the MCU synth's sound into the host as an audio input. That is only worth doing if the MCU synth becomes a product feature. It also adds isochronous scheduling on the same USB device. Apple's ADG references UAC 2.0 codecs for USB-C audio accessories [S1].
- **Order:** USB-MIDI first, then (optionally) UAC1 out for a standalone or "hear the device" mode. Not all transports at once.

## 6. Existing products: design precedent

Precedent only, not buying advice. Latency evidence is quoted exactly as found.

| Product | Sensing → musical mapping | Actual link path | Mac / iOS workflow | Reuse / avoid | Latency evidence |
|---|---|---|---|---|---|
| **Genki Wave** (ring) [S13] | IMU gestures and buttons → CC/notes, configured in the Softwave app | BLE-MIDI to the host. Genki also states "Wave and Wavefront use a proprietary protocol instead of BLE, that achieves under 1 ms latency". | macOS/Windows via Softwave (desktop only, also hosts plugins); iOS/Android in standalone mode as a BLE-MIDI device | Reuse: standard BLE-MIDI plus an optional companion app. Avoid: dependence on the app for core use | *Manufacturer claim*: 7–20 ms over BLE; < 1 ms proprietary |
| **Enhancia Neova** (ring + hub) [S14] | Hand-motion gestures (up to 4 at once, customisable) → MIDI | Ring ↔ hub over proprietary 2.4 GHz (FCC filing 2402–2479 MHz, 2 m range); hub → computer over USB-C ("appears … as a MIDI controller") plus 3.5 mm MIDI in/out | Computer over USB; tablets need a separate wireless MIDI adapter | Reuse: a dedicated receiver gives a controlled link. Avoid: extra hardware for phone use | None found in the manual |
| **Artiphon Orba 2** [S16] | Pads, motion and touch → notes + MPE (pitch bend, aftertouch, vibrato per note); modes MPE / single channel / channel-per-part | USB-C MIDI (macOS, Windows, Android) and BLE-MIDI (macOS, iOS, Android) | Mac: USB or Audio MIDI Setup Bluetooth; iOS: via the Orba app's BLE device list | Reuse: offer both USB and BLE-MIDI, and MPE plus a single-channel fallback | None found |
| **LinnStrument** [S15] | Pads with X (pitch bend), Y (CC74), Z (pressure) → MPE "Channel Per Note" or One Channel | Class-compliant USB-MIDI and DIN MIDI | Mac and iPad over USB, bus-powered (Lightning noted) | Reuse: class compliance, single-channel default, user-selectable MPE, data-reduction setting. Avoid: unthrottled MPE streams (documented stuck notes on overloaded hosts) | No latency number; documents the USB data rate vs DIN |
| **CME WIDI Master** (adapter) [S17] | Transport only | BLE-MIDI (Bluetooth 5) between DIN gear, hosts and other WIDI units; WIDI Bud Pro is a USB dongle for hosts | Pairs with iOS/macOS native BLE-MIDI | Reuse idea: an optional USB BLE dongle on the host side, which CME positions as its lower-latency option (unverified by us) | *Manufacturer claim*: "as low as 3 ms" and "sub 1 ms" jitter between two WIDI devices; 20 m range |

ROLI Seaboard and Artiphon support pages blocked our fetcher (HTTP 302/500) on 2026-11-07. The Orba data comes from Artiphon's manual PDF [S16]. The Seaboard was dropped from the table because its pages could not be verified.

## 7. Plan: minimum viable order

**Stage A: sensor path and event layer (no new transport).**

1. Trill:
   - 9–10 bit scans (≈ 1.7–2.3 ms for 30 channels, from the Bela table), or a channel mask;
   - timer-driven scanning, with the EVT pin waking the reader;
   - check the frame ID;
   - multi-touch with persistent IDs.
2. Move `map()` out of the IMU task. Touch and motion each publish **timestamped events** to one queue.
3. New `no_std` crate (for example `instrument-events`), transport-independent:
   - *Discrete* events (note on/off, tap): a bounded queue with reserved space. **Never dropped.** Note-off has the highest priority.
   - *Continuous* values (bend, pressure, CC): latest-wins per controller, coalesced, sent on change beyond a deadband, rate-limited (*target*: ≤ 250 Hz per controller over USB, ≤ 1 per connection interval over BLE).
   - Stuck-note safety: track active notes; on USB suspend/reset or BLE disconnect, clear local state; on (re)connect send Note Off for tracked notes, CC123 All Notes Off and a pitch-bend reset on every used channel. Never send discrete events while disconnected. Host behaviour on device removal is app-specific and must be tested.
   - Gating: suppress gyro-derived controllers until `calibrated` is true (send neutral values instead). Rate-limit retriggers from taps.

**Stage B: USB-MIDI (class-compliant MIDI 1.0) + CDC diagnostics composite.** Default mapping, single channel:

| Input | MIDI | Notes |
|---|---|---|
| Trill touch onset / release (size threshold with hysteresis) | Note On / Off | Note from location quantised to a scale; velocity from early size growth or a coincident IMU tap |
| Trill location while held | Pitch bend, 14-bit | Glide/vibrato; bend range sent via RPN 0 |
| Trill size | Channel pressure | 7-bit |
| Gyro rotation rate | CC74 (timbre) or CC1, 7-bit or 14-bit pair | 30 ms smoothing today; revisit |
| Tilt pitch/roll (gravity) | CC11 / CC2 | No yaw |
| Accel tap | Percussive note on its own channel, or retrigger | 120 ms refractory |

Then an **MPE mode** (zone with member channels, per-note bend/CC74/pressure [S11]) once multi-touch tracking exists. Keep single-channel as the default for compatibility, as LinnStrument does.

**Stage C: measure** with the acceptance tests below on Mac and iPhone (USB-C and Lightning).

**Stage D: BLE-MIDI**, after the licence decision. Same event layer; request the shortest interval Apple allows, log the granted interval, use timestamps. Optionally add a diagnostics GATT characteristic later.

**Later:** I²S DAC or UAC output for standalone use; PDM microphone; Omi coexistence. The mic stream is high-bandwidth and must not share the event queue. Give it its own buffer and its own BLE/USB endpoint budget, and keep Omi on its own board as decided in [omi-integration.md](omi-integration.md).

## 8. Acceptance tests (targets, not results)

Clocks: never subtract a device timestamp from a host timestamp. Use one of:

- a logic analyzer on device GPIOs (one clock);
- an audio interface recording two channels (one ADC clock);
- a round-trip echo, halved, with the asymmetry stated.

| Test | Method | Target (p95 / p99) |
|---|---|---|
| Sensor → event (device) | GPIO high at IMU INT1 or Trill EVT, GPIO high when the MIDI packet is queued; logic analyzer | motion ≤ 3 / 4 ms; touch ≤ 5 / 7 ms (after Stage A) |
| Transport only (USB, BLE) | Device toggles a GPIO into audio input L as it sends Note On; host plays a click on that Note On into input R (simple patch, 32/64-sample buffer); subtract the known host buffer | USB ≤ 2 / 3 ms; BLE ≤ measured CI + 3 ms / measured CI + 8 ms (*targets*) |
| Gesture → sound | Piezo/contact mic on the board on input L, host synth output on input R, ≥ 200 taps; report p50/p95/p99 and jitter (p95 − p5) | USB + 64 samples @ 48 kHz: ≤ 10 / 12 ms, jitter ≤ 2 ms; BLE: ≤ 20 / 30 ms, jitter ≤ 5 ms |
| Hosts | MacBook (USB-C); USB-C iPhone; Lightning iPhone/iPad + camera adapter; record OS versions and the granted BLE interval | all pass |
| Stress | 10 touches + full motion; BLE with Wi-Fi traffic, 1 m and 5 m, a body in the path; 30 min run | 0 lost Note Offs (count On = Off), 0 audio-late, queue-overflow counters recorded |
| Recovery | Unplug/replug USB, BLE out of range and back, host app restart | no stuck notes after the panic sequence |
| CPU | DWT render time and queue high-water marks in the status line | render < 50 % of the 2 ms block |

## Licensing notes for BLE (engineering analysis, not legal advice)

- All code in this repository is Nymble's, offered under GPL-3.0-only or a commercial licence. This document changes no licence.
- Rust BLE options on the nRF52840:
  - **`trouble-host`** (Apache-2.0 OR MIT) [S22], with the controller from **`nrf-sdc`**. The `nrf-sdc` bindings are Apache-2.0 OR MIT, but they link Nordic's SoftDevice Controller and MPSL libraries, which are under LicenseRef-Nordic-5-Clause (binary-only, Nordic ICs only) [S21].
  - **`nrf-softdevice`**, which calls the S140 SoftDevice binary that the factory bootloader setup already keeps below `0x27000`. It is a separate binary in flash reached through supervisor calls, still Nordic-licensed.
  - **Zephyr's open-source BLE controller** (Apache-2.0, C). It would mean moving away from the pure-Rust Embassy stack.
- GPL-3.0 requires Corresponding Source for the whole conveyed work and forbids further restrictions (§§1, 7, 10). Whether a binary-only Nordic controller linked into the same image, or the separately flashed SoftDevice, is compatible with distributing that image under GPL-3.0-only depends on facts and interpretation (System Library, aggregate vs combined work).
- Options for the copyright holder to choose from:
  - (a) add a narrowly scoped GPL §7 additional permission for linking Nordic BLE controller libraries;
  - (b) distribute BLE builds under the commercial licence;
  - (c) use an open-source controller.
- Get advice before shipping BLE binaries. [omi-integration.md](omi-integration.md) has been reworded to match.

## Research gaps

- No hardware measurements of any kind yet.
- Trill Flex scan time with our pad geometry and prescaler (the Bela table gives nominal per-channel times only).
- The LSM6DS3TR-C digital filter group delay at 416 Hz with our register settings.
- The BLE intervals actually granted by current macOS/iOS to a BLE-MIDI peripheral without HID.
- Whether iOS/macOS honour BLE-MIDI timestamps for scheduling.
- Host synth MIDI-to-buffer scheduling for the apps we target.
- iPhone accessory current available through the Lightning camera adapters (not in the public ADG).

## Sources (checked 2026-11-07)

- [S1] Apple, *Accessory Design Guidelines for Apple Devices*, Release R32 Update 1 (2026-10-30): §43 MIDI, §24 Accessory Power (USB-C), §57.6 BLE connection parameters. <https://developer.apple.com/accessories/Accessory-Design-Guidelines.pdf>
- [S2] USB-IF, *Universal Serial Bus Device Class Definition for MIDI Devices*, Release 1.0. <https://www.usb.org/sites/default/files/midi10.pdf>
- [S3] Apple, Technical Q&A QA1831 *Adding Bluetooth LE MIDI Support*. <https://developer.apple.com/library/archive/qa/qa1831/_index.html>
- [S4] Apple Support, *Set up Bluetooth MIDI devices in Audio MIDI Setup on Mac*. <https://support.apple.com/guide/audio-midi-setup/set-up-bluetooth-midi-devices-ams33f013765/mac>
- [S5] Apple ADG §24.1 *Available Current* (iPhone USB-C: 900 mA / 4.5 W), in [S1].
- [S6] Apple Support 105099, *Charge and connect with the USB-C connector on your iPhone* (2026-10-22). <https://support.apple.com/en-us/105099>
- [S7] Apple Support 111811, *Use Apple USB-A camera adapters with USB-A devices* (2026-06-05). <https://support.apple.com/en-us/111811>
- [S8] MIDI Association, *MIDI over Bluetooth Low Energy (BLE-MIDI)* v1.0 (2015) and spec page. <https://midi.org/midi-over-bluetooth-low-energy-ble-midi>
- [S9] Apple ADG §57.6, in [S1].
- [S10] Apple, Technical Q&A QA1931 *Bluetooth LE advertising and connection parameters*. <https://developer.apple.com/library/archive/qa/qa1931/_index.html>
- [S11] MIDI Association, *M1-100-UM MIDI Polyphonic Expression v1.1*. <https://midi.org/mpe-midi-polyphonic-expression>
- [S12] Nordic, *nRF52840 Product Specification v1.5* (USB 2.0 full speed; Bluetooth 5 2 Mbps/1 Mbps/coded). <https://files.seeedstudio.com/wiki/XIAO-BLE/nRF52840_PS_v1.5.pdf>
- [S13] Genki Instruments docs, *Wave for Music FAQ* and *Connecting Wave*. <https://docs.genki.is/general/faq/wave-for-music/>, <https://docs.genki.is/wave-for-music/softwave-basics/connecting-wave/>. The FAQ returned HTTP 522/timeout to our direct fetch on 2026-11-07; its content was read through the search index the same day.
- [S14] Enhancia, *Neova user manual* (FCC ID 2AUJX-R1 filing). <https://fccid.io/2AUJX-R1/User-Manual/User-manual-4655249>; product site <https://www.enhancia-music.com/>
- [S15] Roger Linn Design, *LinnStrument FAQs* and *What is MPE?* <https://www.rogerlinndesign.com/support/support-linnstrument-faqs>, <https://www.rogerlinndesign.com/support/support-linnstrument-what-is-mpe>
- [S16] Artiphon, *Orba 2 manual* (PDF) and support article *Connect Orba via MIDI over Bluetooth*. <https://images.equipboard.com/uploads/item/manual/110959/artiphon-orba-2-manual.pdf>, <https://support.artiphon.com/support/solutions/articles/44002197535-how-do-i-connect-orba-to-my-computer-using-midi-over-bluetooth-> (support site returned HTTP 500 to our fetcher; read through the search index)
- [S17] CME, *WIDI Master* product and specification page. <https://www.cme-pro.com/widi-master/>
- [S18] WebKit standards positions, *Web Bluetooth* (position: oppose). <https://github.com/WebKit/standards-positions/issues/570>
- [S19] Silicon Labs, *MIDI over BLE* application note (quotes Apple's earlier MIDI interval recommendation). <https://docs.silabs.com/bluetooth/2.13/bluetooth-code-examples-applications/midi-over-ble>
- [S20] Microsoft, *Bluetooth Low Energy MIDI Transport Architecture* (Windows MIDI Services). <https://microsoft.github.io/MIDI/kb/ble-midi-transport-architecture/>
- [S21] Nordic, *MPSL integration notes* (priority 0 reserved for RADIO/RTC0/TIMER0) <https://nrfconnectdocs.nordicsemi.com/ncs/latest/nrfxlib/mpsl/doc/mpsl.html> (returns HTTP 403 to scripted fetches; content read through the search index on 2026-11-07); `nrf-sdc` licence statement <https://github.com/alexmoon/nrf-sdc>; Nordic licence <https://github.com/nrfconnect/sdk-nrf/blob/main/LICENSE>
- [S22] Embassy, *TrouBLE* BLE host. <https://github.com/embassy-rs/trouble>
- Trill scan timing: Bela, *Settings and sensitivity* <https://learn.bela.io/using-trill/settings-and-sensitivity/>; Bela forum, *Latency and jitter for Trill sensors* (Oct 2026) <https://forum.bela.io/d/8604-latency-and-jitter-for-trill-sensors>
