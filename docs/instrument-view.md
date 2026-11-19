# Instrument view (prototype)

The instrument view turns Trillium into a handpan you play by striking the sensor. Mount the board on a stick or hang it from a string, strike it in one of 8 horizontal directions, and each direction plays one tone field of a handpan scale. Tilt selects a second ring of notes or the ding. Feedback and every setting are on one screen.

It's a prototype. Detection runs **in the app** from the board's telemetry, and the notes come out of the app's own MIDI source. No firmware change is needed, and the board's own MIDI keeps working as before.

- Open it from **Presets › Handpan instrument (prototype) › Open instrument view**. It's optional and changes nothing else.
- Code: `apple/TrillKit/Sources/TrillKit/ImpulseEngine.swift` (detection), `Handpan.swift` (scales), `InstrumentRunner.swift` (engine to MIDI notes), `AppMIDISource.swift` (the app's MIDI source), and in the app `InstrumentView.swift` and `AppModel+Instrument.swift`.
- Tests: `apple/TrillKit/Tests/TrillKitTests/InstrumentTests.swift`, which use synthetic IMU traces.

## Handpan scales

Each scale is stored exactly as published: the ding, then the tone fields from low to high. You can move it to any ding from E2 to A3. Intervals are kept, and so is the spelling (one letter per step, so D Kurd moved to E reads B C D E F♯ G A B).

| Scale | Notes (ding \| tone fields) | Source |
|---|---|---|
| D Kurd 9 | D3 \| A3 B♭3 C4 D4 E4 F4 G4 A4 | [handpantuner.app, "The classic handpan scales"](https://handpantuner.app/handpan-scales.html); [BeatRise chart](https://beatrisemusic.com/pages/handpan-scales-chart) |
| D Celtic Minor 9 | D3 \| A3 C4 D4 E4 F4 G4 A4 C5 | handpantuner.app; BeatRise (listed as D Amara 9) |
| D Integral 9 | D3 \| A3 B♭3 C4 D4 E4 F4 A4 C5 | handpantuner.app |
| A Hijaz 9 | A2 \| E3 G3 A3 B♭3 C♯4 D4 E4 G4 | handpantuner.app; [Opsilon scales database](https://opsilon.de/en/pages/scales-database) (A2 Hijaz 9) |
| F Pygmy 9 | F3 \| G3 A♭3 C4 E♭4 F4 G4 A♭4 C5 | BeatRise (F Pygmy 9) |
| E Amara 9 | E3 \| B3 D4 E4 F♯4 G4 A4 B4 D5 | Opsilon (E Amara 9); BeatRise (E Amara 9) |
| F Equinox 10 | F3 \| A♭3 C4 D♭4 E♭4 F4 G4 A♭4 C5 E♭5 | handpantuner.app (F Equinox 10; it writes C♯4, spelled D♭4 here) |
| E La Sirena 10 | E3 \| G3 B3 C♯4 D4 E4 F♯4 G4 B4 C♯5 | Opsilon (E La Sirena 10); BeatRise (E La Sirena 10) |

Sources don't fully agree. Amara is also used as another name for Celtic Minor, and one source ends La Sirena 10 on E5 rather than C♯5. Where they differ, the table uses the version two sources share. Makers also tune "mutant" and bottom-note variants; those aren't included.

**Rings.** Ring 1 is the first 8 tone fields. Ring 2 is tone fields 9 and up, followed by the scale's own notes continued upward above the top tone field (D Kurd: B♭4 C5 D5 E5 F5 G5 A5 B♭5). The ding is the centre.

**Layouts.**
- **Clockwise:** the lowest tone field is at N, rising clockwise.
- **Alternating:** like a handpan seen from above with the player at S. The lowest is at S, and the notes then alternate right and left up to N (sectors S, SE, SW, E, W, NE, NW, N).

## How detection works

The engine takes one IMU sample per telemetry frame: acceleration in g, rotation rate in °/s, and the board's tap counter.

1. **Gravity.** A gravity estimate is rotated with the gyro each sample, then pulled toward the accelerometer while the reading is close to 1 g (time constant 0.4 s). This keeps "which way is down" steady through strikes and turns.
2. **Up, tilt and upside down.** "Up" is a device axis (±X, ±Y, ±Z) or a pose you capture. Tilt is the angle between that axis and vertical. Beyond 100° the device is **upside down** (back to upright below 80°, with hysteresis). The ring is chosen by tilt from the nearest vertical (0–90°), so the instrument plays the same hanging upside down.
3. **Directions from gravity, not device axes.** The horizontal plane is built from measured gravity. N is the board's forward mark (the next axis round from up: X→Y→Z→X) projected onto it, and E = N × up. Flipped over, a strike to the east still reads E. Using the device axes instead would swap E and W, which is what a fixed compass view gets wrong.
4. **Two strike signals.**
   - **Accelerometer transient:** acceleration minus gravity, horizontal part only, in multiples of the threshold. A transient mostly along up (vertical more than 2× horizontal) is ignored.
   - **Swing** (stick or string only): the sudden change of rotation rate turned into the velocity change of the sensor end, Δω × r. Here r points up on a stick (pivot below) and down on a string (pivot above). A swing lasts much longer than the accelerometer spike, so it's sampled reliably at the telemetry rate.
5. **State machine:** armed → debounce window → fire → refractory → re-arm.
   - The first sample at or above threshold opens a short **debounce** window. The peak inside it sets the direction (atan2 of E and N, so any angle within the window) and the strength.
   - The sector is that angle rounded to the nearest 45°. Velocity rises from the minimum at the threshold to 127 at the sensitivity ratio, with a 0.7 curve.
   - After a strike nothing plays for the **refractory** period. The detector re-arms only once the signal falls below the re-arm fraction of the threshold, which rejects the stick's rebound.
6. **Tap assist.** At 100 Hz a sharp tap can fall between two samples. When the board's own tap counter goes up but no threshold was crossed, the engine still plays. It takes the direction of the strongest recent sample, or the ding if there's no clear direction.
7. **Multi-turn roll.** The gyro rate about the up axis is integrated without wrapping (+495° reads "+1 turn +135°"). A small dead band limits drift. **Reset** zeroes it. With no magnetometer there's no absolute heading, so the roll slowly drifts. It's for feedback now and for future mappings.

### Tunables (defaults are starting points, not tuned on hardware)

| Setting | Default | Range in the app | What it does |
|---|---|---|---|
| Threshold | 0.60 g | 0.2–2.0 g | Horizontal acceleration that counts as a strike |
| Swing | 120 °/s | 40–400 °/s | Sudden swing that counts as a strike (stick or string) |
| Sensitivity | 127 at 4× | 1.5–8× | Strength (× threshold) that gives velocity 127; lower is more sensitive |
| Minimum velocity | 24 | (code) | Softest note |
| Debounce | 20 ms | 0–60 ms | Crossings within this window are one strike; the peak decides |
| Refractory | 150 ms | 50–500 ms | Dead time after a strike |
| Re-arm | 0.5 × threshold | (code) | The signal must fall this low before the next strike |
| Vertical rejection | 2× | (code) | Ignore taps mostly along up |
| Ring 2 from | 30° | 10–80° | Tilt where ring 2 starts |
| Ding from | 60° | 20–90° (90 = off) | Tilt where every strike plays the ding |
| Tap assist | on | switch | Play when the board counted a tap between samples |
| Mounting | On a stick | Stick / Hanging / Free | Sets the sign of the swing signal; Free uses the accelerometer only |
| Up | +Z | ±X ±Y ±Z or Set current pose | Which device direction is up |
| N offset | 0 | Make last strike N | Rotates the labels in 45° steps |

Settings are saved on the Mac, iPhone or iPad (not on the board).

## The screen

- **Ring.** There are 8 sectors with their compass point, the ring 1 note (large) and the ring 2 note (small). The ring that tilt selects is bright and the other is dimmed. The ding sits in the centre.
- **Live push.** A radial line shows direction and strength on a square-root scale. It's amber below threshold and turns orange, filling its sector, while it's over threshold: the only orange on the screen apart from the MIDI switch.
- **Threshold zones.** The dashed circle is the threshold, labelled in g. The dotted circle is the re-arm level, and the outer hairline is velocity 127.
- **Last hit.** Outlined in amber, bright for 1.5 s. Recent strikes are dots at their direction and strength. A notch on the inner edge shows which way the up axis leans.
- **Tilt strip.** Tilt from vertical on 0–90°, with the Ring 1, Ring 2 and Ding zones as areas and the current tilt as a line. **INVERTED** appears next to the scale name when the board is upside down.
- **Roll.** The multi-turn roll in degrees and turns, with a small dial and Reset.
- **Push, last 3 s.** The strength trace against the threshold, with a tick for each strike.
- **Controls.** Scale and ding, layout, mounting, threshold, swing, sensitivity, debounce, refractory, tap assist, ring tilts, up axis, Set current pose as up, Make last strike N, and the App-generated MIDI switch with channel and note length.

The design rules are those of `brand/BRAND.md`: black ground, graphite panels, warm-white values in a monospaced face, hairlines instead of boxes, labels in place of legends, and no decoration. It's built to be read from a distance on a dark stage.

## App-generated MIDI and latency

With **App-generated MIDI** on, the app creates a MIDI source called **Trillium Instrument**. Music apps on the same Mac, iPhone or iPad can pick it as an input. The app never connects its own inputs to it, so it can't loop. It sends note-on and, after the note length, note-off, on the chosen channel. While the switch is on, the app asks for telemetry at 100 Hz (the most the protocol allows) even if the view is closed.

**Latency caveat.** Telemetry is a snapshot of the IMU (833 Hz on the board) sent at 100 Hz over USB, at the lowest priority behind instrument MIDI. A strike is heard after:
- the next telemetry frame (up to 10 ms),
- USB and CoreMIDI delivery (a few ms),
- the debounce window (20 ms by default; 0 is allowed), and
- the music app's own buffer.

Expect roughly 10–40 ms, against a few ms for the board's own MIDI. Short accelerometer spikes can also fall between frames, which is why the swing signal and tap assist exist. On iOS the source only sends while the app is in the foreground.

The board keeps sending its own MIDI. Pick a preset without strikes, or ignore Trillium's own port in the music app, so notes aren't doubled.

**Later option: on the board.** Detection in firmware would see every 833 Hz sample, so it would catch the true peak, add no USB or telemetry delay, and work over Bluetooth MIDI with no app open. The engine is small: a gravity filter, two dot products, and a state machine. It could be ported to the `motion-synth` crate with the same test traces once the behaviour is settled here.

## Try it on hardware

1. Fix the XIAO Sense to the top of a stick, or hang it from a string, so it stands upright. Connect it over USB and press Connect on Home.
2. Open **Presets › Open instrument view**. With the board still, the tilt line should sit near 0° and INVERTED should be off. If not, choose the right up axis or press **Set current pose as up**.
3. Strike it once toward where you want N, then press **Make last strike N**.
4. Strike it in all 8 directions. Each sector should light orange while you strike and stay outlined in amber afterwards. Check that the direction and note are right. If light strikes are missed, lower Threshold (or Swing on a stick). If one strike plays twice, raise Refractory.
5. Tilt the stick past 30° (ring 2), then past 60° (ding).
6. Turn it over, or hang it upside down. INVERTED should appear and the directions should stay the same.
7. Roll it about its long axis through a few full turns. The roll readout keeps counting past 360°.
8. Turn on **App-generated MIDI**, pick **Trillium Instrument** in a music app and play.

## Open design questions

- **Heading.** N follows the board's forward mark, so a string that twists turns the compass with it. Should the view lock N to the room using the gyro (it drifts slowly without a magnetometer)?
- **Accel or swing first.** Which signal works better on a real stick and string? Should the user pick one, or should the app learn the thresholds from a few calibration strikes?
- **Ring 2 and ding by tilt.** Alternatives are roll steps (using the multi-turn roll) or the Linear sensor.
- **Note layout.** Clockwise or alternating, and should the user be able to drag notes between sectors?
- **Velocity curve and note length:** per scale, or per performer?
- **Firmware.** Move detection onto the board (lower latency, works without the app), or keep it in the app while the design moves?
- **The same screen for other configurations** (tilt and strike, touch): this view is a prototype for that.
