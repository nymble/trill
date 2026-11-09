# Gesture, Gravity and Pitch: Mapping Inertial Sensors to Musical Action in a Wearable-Scale Controller

*A design study for **Trillium**, a USB-MIDI instrument built around a Bela Trill Flex touch sensor and a six-axis IMU*

**Status:** research report for review, November 2026. It proposes designs and **reports no new hardware results**. Statements about current firmware behaviour refer to firmware 0.4.0 and the repository documentation ([midi-mapping.md](../midi-mapping.md), [firmware-xiao-sense.md](../firmware-xiao-sense.md)). Features of 0.4.0 that have been verified only in simulation or unit tests are marked as such.

---

## Abstract

Trillium is a small USB-MIDI instrument. It pairs a capacitive touch strip (Bela Trill Flex) with a six-axis inertial measurement unit (IMU), an STMicroelectronics LSM6DS3TR-C accelerometer and gyroscope, on a Seeed XIAO nRF52840 Sense. Firmware 0.4.0 already maps tilt to pitch, rotation and tilt to continuous controllers, impacts to percussion and fast wrist rotations to "flick" and "zig-zag" events. This report examines how to go further through four questions. Can the direction of an impulse select among notes? Can orientation, or magnetic heading, select pitch? What have other instrument designers built with accelerometers over the past four decades? And how much gesture intelligence should run on the microcontroller itself? It reviews the mapping literature from Hunt, Wanderley and colleagues, surveys accelerometer-based instruments from Waisvisz's *The Hands* to machine-learning practice with the Wekinator, and sets these against the physics and limits of a low-cost MEMS IMU. The conclusions are:

1. **Impulse direction is a reliable note selector** for four to six classes, provided gravity is removed and the classifier is built around the first lobe of the acceleration impulse.
2. **Orientation is a good pitch selector when separated from articulation.** Let the hand choose the pitch by orientation and let a separate action, a tap, a touch or an impulse, decide *when* the note plays.
3. **Magnetic heading is unreliable on stage.** It is worth adding only as drift correction for a relative yaw estimate.
4. **The nRF52840 has ample headroom** for quaternion orientation tracking, a library of state-machine gesture detectors and small template classifiers. Note timing must stay causal: the device decides *that* a note happens at onset and may decide *what* it is only from the first few milliseconds.

**Keywords:** digital musical instruments, accelerometer, inertial sensing, gesture recognition, mapping, NIME, embedded systems

---

## 1. Introduction

Accelerometers have been in electronic instruments for as long as they have been cheap enough to buy. Michel Waisvisz's *The Hands* (1984) used mercury tilt switches and ultrasonic distance sensing [Waisvisz 1985]. Laetitia Sonami's *Lady's Glove* (1991 onward) added accelerometers to a glove covered in flex and Hall-effect sensors [Bongers 2000]. Two decades later the Nintendo Wii Remote and then the smartphone put a calibrated three-axis accelerometer in nearly every pocket. Musicians took them up quickly, and with mixed results [Kiefer et al. 2008; Essl & Rohs 2009; Wang 2009]. In a 2014 review of five years of NIME proceedings, Medeiros and Wanderley found accelerometers among the most-used sensors in the field. They also found that most instruments were built on "a few basic sensors" with simple signal processing, and they argued that better instrumentation and processing would give more responsive instruments [Medeiros & Wanderley 2014].

Trillium sits squarely in this tradition. It is small, held or worn, and speaks class-compliant USB-MIDI. Its touch strip gives a precise, tactile, one-dimensional control surface. Its IMU gives the gestures of the hand and arm that carry the device. The design question is not whether motion *can* be mapped to sound. Any number can be sent to any synthesiser parameter. The question is which mappings a performer can **learn, repeat and play expressively**. The mapping literature has long argued that this choice defines the instrument more than the sensors do [Hunt, Wanderley & Paradis 2003; Hunt & Kirk 2000].

The report is organised as follows. Section 2 sets out what an IMU of this kind can and cannot measure. Section 3 summarises the mapping principles that bear on the decisions here. Section 4 surveys earlier instruments. Sections 5 to 7 address the design questions on impulse direction, on orientation and heading, and on on-device gesture intelligence. Section 8 turns these into a prioritised plan for Trillium.

## 2. What the sensor measures

### 2.1 The measurement

The LSM6DS3TR-C reports **specific force** (acceleration minus gravity, as an accelerometer measures it) on three axes and **angular rate** on three axes. Firmware 0.4.0 samples both at a 416 Hz output data rate (2.4 ms period), with the accelerometer at ±4 g and the gyroscope at ±1000 °/s (`crates/lsm6ds3trc`, `Config::default`). Three facts follow, and they constrain every mapping in this report.

1. **At rest, the accelerometer measures gravity, not motion.** The 1 g vector indicates which way is down, so it gives pitch and roll. It says nothing about rotation around the vertical (yaw, or heading). When the device moves, gravity and linear acceleration add together and cannot be separated without another sensor. The gyroscope is the usual choice.
2. **Position is not observable.** Double-integrating acceleration turns a small bias into a position error that grows with the square of time. For consumer MEMS parts it becomes unusable within seconds [Woodman 2007]. Instruments that seem to "know where the hand is" use external references: ultrasound in *The Hands*, radio in Mathews's *Radio Baton* [Mathews 1991], magnetic tracking in the *AirSticks* [Ilsar, Havryliv & Johnston 2013], or cameras.
3. **Integrating the gyroscope gives orientation change, with drift.** After calibration at rest, the remaining bias makes yaw drift slowly. Pitch and roll can be corrected continuously against gravity. Yaw cannot be corrected without a magnetometer, and this board has none.

### 2.2 Bandwidth and clipping

A sharp tap on a hard object can exceed ±4 g at the sensor. Firmware 0.4.0 detects taps from a high-passed magnitude with a 0.8 g default threshold, and **velocity is taken from the strength above threshold**. With a ±4 g range, hard strikes saturate and every hard hit gets the same velocity. A percussion-oriented mode should switch to ±8 g or ±16 g; at ±16 g the resolution is still 0.488 mg/LSB, which is plenty. At 416 Hz a 5–20 ms impact spans 2–8 samples. That is enough to estimate onset, peak and the direction of the first lobe. The LSM6DS3TR-C supports accelerometer rates up to 6.66 kHz if finer impulse shape is ever needed.

### 2.3 Latency budget

Wessel and Wright proposed 10 ms as an upper bound on action-to-sound latency for intimate control, with jitter held to about 1 ms [Wessel & Wright 2002]. Controlled studies since then have found that both professional percussionists and amateurs rate an instrument with 0 ms latency as better than one with 10 ± 3 ms or 20 ms [Jack et al. 2018]. Many common DMI toolchains miss these figures [McPherson, Jack & Moro 2016]. For Trillium this means any gesture detector that triggers a *note* must decide within a few milliseconds of onset. A recogniser that waits for the gesture to *finish* is fine for changing modes or parameters, but too late for rhythm.

## 3. Mapping principles

Four results from the mapping literature guide what follows.

- **Mapping defines the instrument.** Hunt, Wanderley and Paradis found that users explored and learned more with mappings that coupled several parameters at once (one-to-many and many-to-one) than with direct one-to-one assignments. They found this even though the one-to-one mappings looked easier at first [Hunt, Wanderley & Paradis 2003; see also Rovan et al. 1997; Wanderley & Depalle 2004].
- **Gesture categories matter.** Following Cadoz and Wanderley, instrumental gestures fall into *excitation* (inject energy and start a sound), *modification* (shape a sound already sounding) and *selection* (choose among discrete options) [Miranda & Wanderley 2006]. Acoustic instruments usually give these to different body parts. A violinist selects pitch with the left hand and excites with the bow. An IMU-only mapping that makes one motion do all three fights the performer.
- **Perceptual spaces and embodiment.** Arfib and colleagues argue for mapping through intermediate perceptual layers rather than straight to synthesis parameters [Arfib et al. 2002]. Embodied music cognition proposes that listeners and players understand sound through action-like images: up and down, effort, impact [Leman 2008; Godøy 2006; Jensenius et al. 2010]. Mappings that respect these images, such as upward motion for rising pitch or effort for brightness and loudness, are easier to learn.
- **Mapping is a design surface, not a constant.** Tools such as libmapper [Malloch, Sinclair & Wanderley 2013], the Wekinator [Fiebrink & Cook 2010] and IRCAM's MuBu/XMM ecosystem [Françoise et al. 2014] treat mapping as something the performer edits and trains. The Trillium app already holds presets on the host, and the configuration protocol already moves parameters to the device. The architecture can support this approach.

## 4. Precedents: accelerometers in instrument design

The table lists instruments and systems that bear directly on Trillium's design questions. Peer-reviewed sources are cited. Commercial products are described from their manufacturers' public descriptions and are not independently verified here.

| Instrument / system | Sensing | Mapping idea relevant to Trillium |
|---|---|---|
| *The Hands*, Waisvisz, 1984 onward [Waisvisz 1985] | Tilt switches, ultrasonic distance, keys | Hand posture and distance select and shape sound. Tilt is used as a *switch* as much as a continuous control |
| *Lady's Glove*, Sonami [Bongers 2000]; later *Spring Spyre* [Fiebrink & Sonami 2020] | Accelerometers, flex, Hall sensors; later machine-learned mappings | Over eight years of use, trained mappings replaced hand-written ones. The performer re-trains for each piece |
| *Radio Baton*, Mathews [Mathews 1991] | Radio position of two batons | Separates *triggering* (beats) from *expression*. The score holds the pitches, so the player shapes timing and dynamics |
| *Digital Baton* / *Conductor's Jacket*, Marrin [Marrin & Paradiso 1997; Marrin Nakra 2000] | Accelerometers, EMG, IR | Beat detection from acceleration peaks. Conducting gestures as tempo and articulation control |
| Conducting systems [Lee, Nakra & Borchers 2004; Kolesnik & Wanderley 2004] | Accelerometer batons, vision | Recognises beat patterns and expressive variants. Tempo follows the hand |
| *T-Stick*, Malloch & Wanderley [Malloch & Wanderley 2007] | Accelerometers, capacitive touch along the body, pressure, piezo | **Touch plus motion on one object**, the closest relative of Trillium. Shaking, tilting and striking are combined with where the hand grips |
| *Electronic Sitar*, Kapur et al. [Kapur et al. 2004] | Accelerometer on the performer's head, among others | Secondary body motion as an expressive controller layered on a traditional technique |
| IRCAM *MO, Modular Musical Objects* [Rasamimanana et al. 2011] | Wireless IMUs in tangible objects | Gesture following and recognition drive sound. The same object can be a shaker, a bow or a strike surface |
| Nintendo Wii Remote as an instrument [Kiefer et al. 2008] | 3-axis accelerometer (later gyroscope), IR camera | A usability study found triggering and continuous control workable, and gesture recognition the weak point |
| Smartphone instruments [Essl & Rohs 2009; Wang 2009] | Accelerometer, gyroscope, touch, microphone | Ocarina uses breath for excitation, touch for selection and tilt for vibrato and modification, a clean split by gesture category |
| *Mi.Mu* gloves, Mitchell, Madgwick & Heap [Mitchell, Madgwick & Heap 2012] | Flex sensors plus IMU orientation per hand | **Posture selects, orientation controls.** A hand posture acts as a clutch that decides what orientation does. Orientation is quantised into zones and directions |
| *AirSticks*, Ilsar et al. [Ilsar, Havryliv & Johnston 2013] | Six-degree-of-freedom magnetic tracking, buttons | Air drumming in which strike position and direction select sounds, much like a virtual kit |
| Commercial rings and wearables: Genki *Wave*, Enhancia *Neova*, Source Audio *Hot Hand* (manufacturer descriptions) | IMU, buttons | Tilt and roll to CC, tap-to-trigger, vibrato from wrist shake. Mostly *modification* gestures layered on a keyboard or guitar |

Three patterns recur across these instruments:

1. **The best-loved designs keep selection apart from excitation**: Radio Baton, Ocarina and Mi.Mu.
2. **Touch or posture works as a clutch**, so the instrument does not respond to every incidental motion: the T-Stick's grip and Mi.Mu's postures.
3. **Long-term practitioners move toward trained or performer-authored mappings**, not fixed factory ones [Fiebrink & Sonami 2020; Caramiaux & Tanaka 2013].

## 5. Can the direction of an impulse select a note?

**Short answer: yes, readily, for four to six well-separated directions. Up to eight is possible with practice.** The direction of an impulse is one of the most informative and least drift-prone things a bare accelerometer can measure, because it is a short-time measurement. It also maps naturally to drumming, where the striking direction already means something to a percussionist [Ilsar, Havryliv & Johnston 2013].

### 5.1 Two physical cases

The sign convention depends on what produces the impulse, and a classifier has to choose deliberately:

- **Striking an object** (tapping the device on a table, the body or the other hand). The device decelerates sharply. The measured impulse points **opposite** to the direction of travel, toward the hand, away from the surface.
- **Striking the air** (a punch or flick that stops in mid-air). The arm accelerates the device toward the target, then muscles brake it. The braking lobe is often sharper and larger than the launch lobe. A naive peak picker therefore reads such a gesture as pointing *backwards*.

A robust detector uses the **first significant lobe** after onset (launch) for air gestures. For contact strikes it uses the dominant short impulse. Section 8 proposes making this a per-preset choice.

### 5.2 Algorithm

1. **Freeze orientation at onset.** Keep the gravity estimate from the orientation filter as it was a few samples *before* the onset. During the impact the accelerometer is corrupted and must not update the attitude.
2. **Remove gravity.** Linear acceleration = measured specific force minus the frozen gravity vector.
3. **Rotate into a gravity-referenced frame**, such as "toward the floor", "toward the player" or "sideways", so that "strike down" means down however the device is held. With pitch and roll known, this needs no magnetometer for up/down. Left/right/forward/back still depend on yaw, so the frame is *relative to the hand*. In practice that is what a performer expects.
4. **Integrate the linear acceleration over the first lobe**, typically 3–8 samples at 416 Hz. The result is a velocity-change vector Δv. Its direction is the class and its magnitude gives MIDI velocity. Integrating is more robust than taking a single peak sample.
5. **Classify by angle with a rejection margin.** Assign the nearest of *N* prototype directions. If the angle to the best prototype is not clearly smaller than to the second-best (for example by 15°), either play a configured default or play nothing. A silent miss is better than a wrong note. Gyroscope data from the same window helps: wrist strikes are largely rotational, and the sign of the dominant rotation axis (already used by the 0.4.0 flick detector) is a strong second opinion.
6. **Decide within 5–10 ms of onset**, inside the latency budget of §2.3.

The nRF52840's Cortex-M4F does this in a few microseconds per sample.

### 5.3 What the IMU hardware already offers

The LSM6DS3TR-C has an embedded tap engine. Its `TAP_SRC` register reports single and double taps together with **which axis fired and the sign** (`X_TAP`, `Y_TAP`, `Z_TAP`, `TAP_SIGN`) [STMicroelectronics, LSM6DS3TR-C datasheet; AN5130]. That is a six-way direction classifier in silicon, with adjustable threshold, shock and quiet windows. It is the quickest route to a demo. It has limits, though. It works in the sensor frame, not a gravity frame. It cannot use the first-lobe rule for air strikes. Its thresholds work per axis, not on the vector. **Recommendation:** use it to prototype, then ship the firmware classifier above, which is configurable and testable with the existing host-side test harness. The firmware-side approach also keeps working if the IMU changes.

### 5.4 Musical mappings for directional impulses

- **A virtual kit.** Down = kick, toward the body = snare, sideways = hi-hat or tom, up = cymbal. This matches the percussionist's instinct and the AirSticks' "strike position" logic.
- **Scale degrees.** The directions pick the root, third, fifth and octave of the current chord, with the chord chosen by the touch strip or by orientation (§6). This turns the instrument into a strummed or arpeggiated harmony controller.
- **Articulation.** In a sustained voice played from the touch strip, the impulse direction selects an articulation (accent, staccato, a pitch-bend "scoop" up or down) instead of a new note.

Human repeatability, not sensing, sets the class count. Kiefer et al. found gesture *recognition* the least reliable part of using the Wii Remote musically [Kiefer et al. 2008]. Start with four directions, validate them with recorded data from several players, and add classes only if confusion stays low.

## 6. Can orientation, or magnetic heading, select notes?

### 6.1 Orientation relative to gravity: yes, and Trillium already does it

The 0.4.0 *tilt notes* mode chooses the note from roll across a span of ±45° by default, quantised to the scale with hysteresis. Forward pitch acts as the gate, and theremin mode bends continuously. These modes were tested **in simulation and unit tests only, not on hardware**. The HCI literature supports the basic idea. In a controlled study of wrist tilt, Rahman et al. found that users could comfortably control **at least 16 distinct levels** of pronation and supination (forearm roll, the axis Trillium uses). A **quadratic** discretisation, with finer zones near neutral and wider zones at the extremes, improved performance on every axis [Rahman et al. 2009]. Two improvements follow:

1. **Use non-uniform note zones** that are narrow near neutral and wide near the limits of comfortable rotation, instead of equal steps across ±45°.
2. **Limit a span to about one octave of a diatonic or pentatonic scale**, 5–8 notes, within that 16-level ceiling. Use the touch strip or a gesture to shift octaves. The note range is already a parameter (range in semitones plus a scale choice) and the roll span is a separate parameter in degrees, so this is a preset decision rather than a firmware change.

### 6.2 Separate selection from excitation

The strongest design lesson of §4 applies here. **Tilt to choose and tap to play** is easier to play in time than tilt to choose plus tilt past a gate to play. In the current gate mode the same pitch-axis motion both selects and excites. Every note onset therefore costs a forward-tilt movement, and the roll angle that picks pitch can shift while the player crosses the gate. Better combinations:

- **Orientation selects pitch, touch strip excites.** A touch anywhere on the strip sounds the note chosen by orientation, and touch position or size shapes timbre or dynamics. This is the Ocarina split [Wang 2009].
- **Orientation selects pitch, an impulse excites.** A tap or directional strike (§5) plays the orientation-selected note, and impulse strength sets the velocity.
- **Orientation selects the chord, impulse direction selects the voice** (combining §5.4 and §6.1). A 6D "which face is up" classifier, which the LSM6DS3TR-C also implements in hardware (`D6D_SRC`), gives six coarse chord or register zones that are very easy to find without looking.

All three keep the existing hysteresis and the "release before change" stuck-note safety.

### 6.3 Heading (yaw): only relative, and only briefly

Facing direction is the dimension a performer most naturally imagines for "pointing at notes": a circle of pitches around the body. Without a magnetometer, yaw comes only from integrating the gyroscope. It is usable for **relative** pointing over a phrase lasting seconds to tens of seconds, then needs re-zeroing. Firmware 0.4.0 already has *orientation zero* (action 5) for pitch and roll. Extending it to a quaternion-based yaw zero, triggered by a touch-and-hold or a stillness detector, gives a practical "point to select" mode. The pitch circle is redefined around wherever the player is facing when they touch.

### 6.4 Magnetic heading: possible, but not on its own

The XIAO nRF52840 Sense has **no magnetometer**. Adding one, for example a small I²C breakout on the same bus as the Trill sensor, enables MARG (magnetic, angular rate and gravity) fusion with the Madgwick or Mahony filters [Madgwick, Harrison & Vaidyanathan 2011; Mahony, Hamel & Pflimlin 2008]. Mi.Mu-style systems use orientation from fused IMU data for "pointing" gestures [Mitchell, Madgwick & Heap 2012]. Absolute magnetic heading on stage is unreliable, however:

- Steel stage structures, amplifiers, speaker magnets, laptops and the USB cable all distort the local field. The distortion changes as the performer moves through the space.
- Calibration (hard- and soft-iron correction) must be done with the device in its final enclosure, and it shifts if anything magnetic is mounted nearby [Vasconcelos et al. 2011].
- A performer facing "north = C" must know where north is in each venue. Audiences and players experience this as arbitrary.

**Recommendation:** do not map notes to compass bearing. If a magnetometer is ever added, use it only to **bound gyroscope yaw drift** inside the fusion filter, so relative pointing (§6.3) stays stable over minutes instead of seconds. The mapping stays relative to a zero the player sets. This is optional hardware, so it belongs on the roadmap after the firmware-only work below.

## 7. Making the microcontroller smarter

### 7.1 Where Trillium stands

Firmware 0.4.0 has a complementary-filter tilt estimate (τ = 0.5 s), a rotation-speed magnitude and a tap detector. It also has a **flick** detector on one chosen gyroscope axis, with threshold, re-arm at 30% and cooldown. Two opposite flicks within a window count as a **zig-zag**. Circle and twirl recognition are documented as not implemented. Flick and zig-zag are covered by unit tests and are **not hardware-tested**.

### 7.2 Resource budget

The nRF52840 has a 64 MHz Cortex-M4 with single-precision FPU, 256 KB RAM and 1 MB flash. At 416 Hz the processor has about 150,000 cycles per IMU sample. A Madgwick update costs on the order of a few hundred floating-point operations, and a 64 × 64 dynamic-time-warping comparison about 4,000 multiply-adds. Small 1-D convolutional networks for gesture classification have been demonstrated on this exact SoC with TensorFlow Lite Micro [David et al. 2021]. **Compute is not the constraint. The constraints are latency (§2.3), labelled data, and the performer's ability to learn and trust the detectors.**

### 7.3 A layered architecture

The proposed architecture has five layers, each building on the one below.

**Layer 0: hardware event engines.** The LSM6DS3TR-C offers single and double tap with direction, 6D/4D orientation, free fall, wake-up (activity), tilt and significant motion. They are useful as low-latency, low-power triggers and for prototyping. This part does **not** have the programmable finite-state machine or machine-learning core of newer ST IMUs such as the LSM6DSOX family. That is worth considering if the hardware is ever revised.

**Layer 1: a proper attitude estimate.** Replace the separate pitch/roll complementary filters with a quaternion filter, Madgwick or Mahony in IMU-only mode. Benefits:

- **Gravity-free linear acceleration**, which §5 needs.
- **Relative yaw** for §6.3.
- **No gimbal artefacts** near ±90° pitch.

The 0.4.0 pitch and roll outputs can be derived from the quaternion, so existing presets keep working. Freeze the accelerometer correction during impacts and shakes, when |a| differs from 1 g by more than a margin, so the attitude does not jump.

**Layer 2: hand-built gesture detectors as small state machines.** Each one is explainable, unit-testable with synthetic traces (as the flick tests already are), and causal:

| Gesture | Detector sketch | Musical use |
|---|---|---|
| Directional strike | §5.2 | Kit pieces, chord voices, articulations |
| Shake / tremolo | Band-passed linear-acceleration energy and zero-crossing rate over a 100–200 ms window [cf. Williamson, Murray-Smith & Hughes 2007] | Continuous: rate → tremolo speed, energy → amount. Event: "shake started" |
| Zig-zag, generalised | Count alternating-sign flicks on an axis; report count and inter-flick period | Ratchets, rolls, tempo-synced repeats |
| Twirl | Sustained gyroscope rate about the device's long axis, integrated angle past N × 90° | Filter sweeps, "wind-up" gestures, octave shift per half-turn |
| Circle | Integrated rotation of the *horizontal* linear-acceleration (or gravity) vector with consistent sign through ≥ 300° | Loop or arpeggiator start, scene change |
| Toss / free fall | \|a\| < 0.3 g for > 60 ms (the LSM6DS3TR-C also detects this in hardware) | Dramatic one-shots, "release" effects |
| Stillness | Gyroscope magnitude and accelerometer variance below thresholds for 300 ms | Auto re-zero, gyroscope bias refresh, arming |
| Beat / tempo | Peak picking of vertical linear acceleration and inter-onset intervals, in the style of conducting systems [Marrin Nakra 2000; Lee, Nakra & Borchers 2004] | MIDI clock out, tempo-following arpeggiator |

Smooth continuous outputs with an adaptive filter such as the 1€ filter, which cuts lag during fast motion and jitter when nearly still [Casiez, Roussel & Vogel 2012]. It suits the CC outputs better than the current fixed one-pole smoothing.

**Layer 3: few-shot template recognition.** For gestures the performer invents, record 3–5 examples of each. Resample and normalise them, and compare live input by dynamic time warping [Sakoe & Chiba 1978]. This is the approach of *uWave*, which reported high accuracy from a single training example per gesture with a 3-axis accelerometer [Liu et al. 2009]. A related idea is the trivially implementable "$1" family of recognisers [Wobbrock, Wilson & Li 2007]. Templates take a few kilobytes and would be recorded in the app, then uploaded with the existing SysEx configuration protocol (new parameter pages; protocol work required). Because DTW needs the whole gesture, use template recognition for **selection and mode changes**, not for timing a note.

**Layer 4: learned and continuous recognition.** Two strands of research are relevant.

- **Interactive machine learning:** Wekinator-style regression and classification trained by demonstration [Fiebrink & Cook 2010; Fiebrink & Sonami 2020] and probabilistic motion–sound models [Françoise et al. 2014]. These can run in the host app first, where iteration is fast, with only the inference step later moved onto the device if latency demands it.
- **Gesture following:** estimating *how far through* a known gesture the performer is, continuously, while it happens [Bevilacqua et al. 2010]. This avoids the end-of-gesture latency of classification. Sound can unfold *with* the gesture, so a circle can play an arpeggio whose position follows the hand.

Caramiaux and Tanaka's review is a good map of the trade-offs [Caramiaux & Tanaka 2013]. TinyML classifiers on the device [David et al. 2021] are feasible but are the **last** step. They need a recorded, labelled data set from several players, which this project does not yet have.

### 7.4 Usability rules for "smart" detection

1. **Onset first, classification second.** When a gesture both triggers and selects, fix the time at onset and choose the sound from the first milliseconds (§5.2). Never delay a note to wait for a better classification.
2. **A clutch.** The "Midas touch" problem, where every motion is a command, kills gestural instruments. Use the touch strip as an enable: motion gestures are live only while a finger rests on a defined zone, or only after a stillness-then-tap arm gesture. This follows the T-Stick's grip and the Mi.Mu glove postures.
3. **Feedback.** Flash the status LED with a distinct colour per recognised class, and show the class in the app. Players learn the detector's boundaries much faster when they can see them.
4. **Per-player calibration.** Thresholds for tap, flick and shake differ widely between players and between wrist and arm technique. Offer a short "play five strikes" calibration in the app that sets thresholds from the player's own data.
5. **Graceful misses.** A rejected or ambiguous gesture produces nothing (or a configured default), never a random note.
6. **Record everything.** Gesture work needs data. The current telemetry stream (1–100 frames/s, 50 by default) is too slow to capture impulses. A triggered **burst capture**, for example 512 raw samples at 416 Hz around each detected event sent over the configuration cable, would let the app build the data set that Layers 3 and 4 need, and let any reported misfire be replayed against the detector in unit tests.

## 8. Recommendations for Trillium

Listed in order of value against effort. None of these changes is implemented, and none has been tested on hardware.

| # | Change | Firmware / app / hardware | Notes |
|---|---|---|---|
| 1 | **Accelerometer range for percussion**: ±8 g or ±16 g when tap or strike modes are on | Firmware | Stops velocity flattening on hard hits. Re-check the tap threshold scaling |
| 2 | **Quaternion attitude (Madgwick/Mahony, IMU-only)** with an accelerometer gate during impacts; derive the existing pitch and roll from it | Firmware | Foundation for 3–6. Keeps 0.4.0 behaviour as the default |
| 3 | **Directional strike detector** (§5.2), 4 classes, first-lobe or contact convention per preset, rejection margin | Firmware + app presets | Prototype first with the IMU's `TAP_SRC` |
| 4 | **"Select by orientation, play by touch or tap"** modes (§6.2) with quadratic note zones | Firmware + app | A small change to the existing tilt-mode state machine |
| 5 | **Touch-strip clutch** for motion gestures | Firmware + app | Cuts false triggers |
| 6 | **Gesture library**: shake, generalised zig-zag, twirl, toss, stillness (§7.3 Layer 2) | Firmware | Each with synthetic-trace unit tests, like the flick tests |
| 7 | **Burst capture over the config protocol** and recording in the app | Firmware + protocol + app | Requires a protocol revision and `make protocol-vectors` |
| 8 | **1€ filter option** for CC smoothing | Firmware | Drop-in alternative to the one-pole filter |
| 9 | **Template gestures (DTW)** trained in the app and uploaded | All three | After 7 has collected data |
| 10 | **Optional magnetometer** for yaw drift correction only | Hardware | Not for absolute-heading note maps (§6.4) |

**Hardware validation plan**, for when a firmware build containing any of the above is approved for hardware testing:

- Record five players × 20 strikes per direction and report a confusion matrix and onset-to-MIDI latency, measured with a contact microphone against USB-MIDI timestamps.
- Repeat over a 60-minute session to exercise the class of timer bug fixed in 0.4.0 (tap notes stopping after 35.8 minutes).
- Confirm on the board the physical axis signs that §5 relies on. The repository notes that tilt axis signs are still unverified on hardware.

## 9. Conclusion

A bare six-axis IMU cannot tell where a hand is or which way it faces. It is excellent at telling *how the hand moved just now*: which way it struck, how hard, how fast it turned, whether it shook or fell. It also knows which way is down. Forty years of instrument building point to the same design for such a sensor. Use orientation to select, let a separate action excite, protect against incidental motion with a clutch, and let performers author their own gestures. Trillium already has the parts: a precise touch strip, a capable IMU, an over-provisioned microcontroller and a host app with a configuration protocol. The work ahead is mostly mapping and signal processing. If it is done carefully and checked against real recorded gestures, this small controller can become an instrument players can actually learn.

---

## References

Arfib, D., Couturier, J.-M., Kessous, L., & Verfaille, V. (2002). Strategies of mapping between gesture data and synthesis model parameters using perceptual spaces. *Organised Sound, 7*(2), 127–144.

Bevilacqua, F., Zamborlin, B., Sypniewski, A., Schnell, N., Guédy, F., & Rasamimanana, N. (2010). Continuous realtime gesture following and recognition. In S. Kopp & I. Wachsmuth (Eds.), *Gesture in Embodied Communication and Human-Computer Interaction* (LNCS 5934, pp. 73–84). Springer.

Bongers, B. (2000). Physical interfaces in the electronic arts: Interaction theory and interfacing techniques for real-time performance. In M. M. Wanderley & M. Battier (Eds.), *Trends in Gestural Control of Music*. IRCAM – Centre Pompidou.

Caramiaux, B., & Tanaka, A. (2013). Machine learning of musical gestures. In *Proceedings of the International Conference on New Interfaces for Musical Expression (NIME)* (pp. 513–518). Daejeon, Korea.

Casiez, G., Roussel, N., & Vogel, D. (2012). 1€ filter: A simple speed-based low-pass filter for noisy input in interactive systems. In *Proceedings of the SIGCHI Conference on Human Factors in Computing Systems (CHI '12)* (pp. 2527–2530). ACM.

David, R., Duke, J., Jain, A., Janapa Reddi, V., Jeffries, N., Li, J., Kreeger, N., Nappier, I., Natraj, M., Wang, T., Warden, P., & Rhodes, R. (2021). TensorFlow Lite Micro: Embedded machine learning for TinyML systems. In *Proceedings of Machine Learning and Systems 3 (MLSys 2021)*.

Essl, G., & Rohs, M. (2009). Interactivity for mobile music-making. *Organised Sound, 14*(2), 197–207. https://doi.org/10.1017/S1355771809000302

Fiebrink, R., & Cook, P. R. (2010). The Wekinator: A system for real-time, interactive machine learning in music. In *Proceedings of the 11th International Society for Music Information Retrieval Conference (ISMIR 2010)*, late-breaking demo. Utrecht.

Fiebrink, R., & Sonami, L. (2020). Reflections on eight years of instrument creation with machine learning. In *Proceedings of the International Conference on New Interfaces for Musical Expression (NIME)* (pp. 237–242). Birmingham, UK. https://doi.org/10.5281/zenodo.4813334

Françoise, J., Schnell, N., Borghesi, R., & Bevilacqua, F. (2014). Probabilistic models for designing motion and sound relationships. In *Proceedings of the International Conference on New Interfaces for Musical Expression (NIME)* (pp. 287–292). London.

Godøy, R. I. (2006). Gestural-sonorous objects: Embodied extensions of Schaeffer's conceptual apparatus. *Organised Sound, 11*(2), 149–157.

Hunt, A., & Kirk, R. (2000). Mapping strategies for musical performance. In M. M. Wanderley & M. Battier (Eds.), *Trends in Gestural Control of Music*. IRCAM – Centre Pompidou.

Hunt, A., Wanderley, M. M., & Paradis, M. (2003). The importance of parameter mapping in electronic instrument design. *Journal of New Music Research, 32*(4), 429–440.

Ilsar, A., Havryliv, M., & Johnston, A. (2013). The AirSticks: A new interface for electronic percussionists. In *Proceedings of the Sound and Music Computing Conference (SMC 2013)* (pp. 220–226). Stockholm.

Jack, R. H., Mehrabi, A., Stockman, T., & McPherson, A. (2018). Action-sound latency and the perceived quality of digital musical instruments: Comparing professional percussionists and amateur musicians. *Music Perception, 36*(1), 109–128. https://doi.org/10.1525/mp.2018.36.1.109

Jensenius, A. R., Wanderley, M. M., Godøy, R. I., & Leman, M. (2010). Musical gestures: Concepts and methods in research. In R. I. Godøy & M. Leman (Eds.), *Musical Gestures: Sound, Movement, and Meaning* (pp. 12–35). Routledge.

Kapur, A., Lazier, A. J., Davidson, P., Wilson, R. S., & Cook, P. R. (2004). The electronic sitar controller. In *Proceedings of the International Conference on New Interfaces for Musical Expression (NIME)*. Hamamatsu, Japan.

Kiefer, C., Collins, N., & Fitzpatrick, G. (2008). Evaluating the Wiimote as a musical controller. In *Proceedings of the International Computer Music Conference (ICMC 2008)*. Belfast. (See also the companion paper: HCI methodology for evaluating musical controllers: A case study. *NIME 2008*, pp. 87–90.)

Kolesnik, P., & Wanderley, M. M. (2004). Recognition, analysis and performance with expressive conducting gestures. In *Proceedings of the International Computer Music Conference (ICMC 2004)*. Miami.

Lee, E., Nakra, T. M., & Borchers, J. (2004). You're the conductor: A realistic interactive conducting system for children. In *Proceedings of the International Conference on New Interfaces for Musical Expression (NIME)*. Hamamatsu, Japan.

Leman, M. (2008). *Embodied Music Cognition and Mediation Technology*. MIT Press.

Liu, J., Zhong, L., Wickramasuriya, J., & Vasudevan, V. (2009). uWave: Accelerometer-based personalized gesture recognition and its applications. *Pervasive and Mobile Computing, 5*(6), 657–675.

Madgwick, S. O. H., Harrison, A. J. L., & Vaidyanathan, R. (2011). Estimation of IMU and MARG orientation using a gradient descent algorithm. In *Proceedings of the IEEE International Conference on Rehabilitation Robotics (ICORR 2011)*. Zurich.

Mahony, R., Hamel, T., & Pflimlin, J.-M. (2008). Nonlinear complementary filters on the special orthogonal group. *IEEE Transactions on Automatic Control, 53*(5), 1203–1218.

Malloch, J., Sinclair, S., & Wanderley, M. M. (2013). Libmapper (a library for connecting things). In *CHI '13 Extended Abstracts on Human Factors in Computing Systems*. ACM.

Malloch, J., & Wanderley, M. M. (2007). The T-Stick: From musical interface to musical instrument. In *Proceedings of the International Conference on New Interfaces for Musical Expression (NIME)* (pp. 66–69). New York.

Marrin, T., & Paradiso, J. (1997). The Digital Baton: A versatile performance instrument. In *Proceedings of the International Computer Music Conference (ICMC 1997)*. Thessaloniki.

Marrin Nakra, T. (2000). *Inside the Conductor's Jacket: Analysis, interpretation and musical synthesis of expressive gesture* (Doctoral dissertation). Massachusetts Institute of Technology.

Mathews, M. V. (1991). The Radio Baton and Conductor program, or: Pitch, the most important and least expressive part of music. *Computer Music Journal, 15*(4), 37–46.

McPherson, A. P., Jack, R. H., & Moro, G. (2016). Action-sound latency: Are our tools fast enough? In *Proceedings of the International Conference on New Interfaces for Musical Expression (NIME)*. Brisbane.

Medeiros, C. B., & Wanderley, M. M. (2014). A comprehensive review of sensors and instrumentation methods in devices for musical expression. *Sensors, 14*(8), 13556–13591. https://doi.org/10.3390/s140813556

Miranda, E. R., & Wanderley, M. M. (2006). *New Digital Musical Instruments: Control and Interaction Beyond the Keyboard*. A-R Editions.

Mitchell, T., Madgwick, S., & Heap, I. (2012). Musical interaction with hand posture and orientation: A toolbox of gestural control mechanisms. In *Proceedings of the International Conference on New Interfaces for Musical Expression (NIME)*. Ann Arbor, MI. https://doi.org/10.5281/zenodo.1180543

Rahman, M., Gustafson, S., Irani, P., & Subramanian, S. (2009). Tilt techniques: Investigating the dexterity of wrist-based input. In *Proceedings of the SIGCHI Conference on Human Factors in Computing Systems (CHI '09)* (pp. 1943–1952). ACM. https://doi.org/10.1145/1518701.1518997

Rasamimanana, N., Bevilacqua, F., Schnell, N., Guédy, F., Fléty, E., Maestracci, C., Zamborlin, B., Frechin, J.-L., & Petrevski, U. (2011). Modular musical objects towards embodied control of digital music. In *Proceedings of the Fifth International Conference on Tangible, Embedded, and Embodied Interaction (TEI '11)* (pp. 9–12). ACM. https://doi.org/10.1145/1935701.1935704

Rovan, J. B., Wanderley, M. M., Dubnov, S., & Depalle, P. (1997). Instrumental gestural mapping strategies as expressivity determinants in computer music performance. In *Proceedings of the Kansei – The Technology of Emotion Workshop*. Genoa.

Sakoe, H., & Chiba, S. (1978). Dynamic programming algorithm optimization for spoken word recognition. *IEEE Transactions on Acoustics, Speech, and Signal Processing, 26*(1), 43–49.

STMicroelectronics. *LSM6DS3TR-C: iNEMO inertial module, always-on 3D accelerometer and 3D gyroscope* (datasheet), and *AN5130: LSM6DS3TR-C always-on 3D accelerometer and 3D gyroscope* (application note). Register details cited here (`TAP_SRC`, `D6D_SRC`, full-scale settings) should be checked against the current revisions before implementation.

Vasconcelos, J. F., Elkaim, G., Silvestre, C., Oliveira, P., & Cardeira, B. (2011). Geometric approach to strapdown magnetometer calibration in sensor frame. *IEEE Transactions on Aerospace and Electronic Systems, 47*(2), 1293–1306.

Waisvisz, M. (1985). THE HANDS, a set of remote MIDI-controllers. In *Proceedings of the International Computer Music Conference (ICMC 1985)*. Burnaby, BC.

Wang, G. (2009). Designing Smule's Ocarina: The iPhone's magic flute. In *Proceedings of the International Conference on New Interfaces for Musical Expression (NIME)* (pp. 303–307). Pittsburgh, PA. https://doi.org/10.5281/zenodo.1177697

Wanderley, M. M., & Depalle, P. (2004). Gestural control of sound synthesis. *Proceedings of the IEEE, 92*(4), 632–644.

Wessel, D., & Wright, M. (2002). Problems and prospects for intimate musical control of computers. *Computer Music Journal, 26*(3), 11–22.

Williamson, J., Murray-Smith, R., & Hughes, S. (2007). Shoogle: Excitatory multimodal interaction on mobile devices. In *Proceedings of the SIGCHI Conference on Human Factors in Computing Systems (CHI '07)*. ACM.

Wobbrock, J. O., Wilson, A. D., & Li, Y. (2007). Gestures without libraries, toolkits or training: A $1 recognizer for user interface prototypes. In *Proceedings of the 20th Annual ACM Symposium on User Interface Software and Technology (UIST '07)* (pp. 159–168). ACM.

Woodman, O. J. (2007). *An introduction to inertial navigation* (Technical Report UCAM-CL-TR-696). University of Cambridge Computer Laboratory.

---

*Bibliographic note.* The following references were checked against publisher, proceedings or repository records: Ilsar et al. 2013, Mitchell et al. 2012, Rahman et al. 2009, Fiebrink & Sonami 2020, Malloch & Wanderley 2007, Jack et al. 2018, Kiefer et al. 2008, Rasamimanana et al. 2011, Caramiaux & Tanaka 2013, Françoise et al. 2014, Medeiros & Wanderley 2014, Essl & Rohs 2009 and Wang 2009. The remaining references are standard works in the field; their page numbers and venue details should be confirmed before external publication.
