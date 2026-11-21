# Vision (brainstorm)

This page collects ideas for later roadmap prioritization. **Priorities are TBD.** Nothing here is a commitment or a description of shipped features; see the [roadmap](roadmap.md) for current status.

## Direction

- **Trillium Music:** an emerging music company. The product is an app that opens new ways for people to create and interact with music.
- **Start simple:** Trillium Zero (one microcontroller board on a USB cable) is the public starting point. Other configurations follow.
- **Build toward the vision:** keep each release small, and choose work that moves toward the ideas below.

## Making music together

- Multi-player and nearby use: several people and instruments playing together in one room.
- **Weft** for local communications between nearby devices.
- A battery-powered BLE **T1** with a microphone input.

## The app as an instrument

- The app generates MIDI or audio itself, not only from attached hardware.
- **Phone-only mode:** play using the phone's own sensors, with no extra hardware.
- **Unified instrument view:** after choosing an instrument, one screen for feedback and adjustment, and optionally for settings. Prototype it first rather than replacing every view at once.
  - Build on the compass-style view, which shows the lines and areas where an action, event or condition happens.
  - Handle more than 360° of rotation (continued rolling) and an upside-down board.
  - Let the user set which direction counts as "up" on the device.
  - Handpan-style note sets, selectable by name.
  - A sensor on a stick or hanging from a string: sense impulses in 8 directions, with tilt selecting more notes.
- **AI assist** later.

## Publishing

- Publish music on the App Store and other venues.
- Or provide tooling that helps others publish their music.

## Devices and tools

- The **Pi Lab console** as a potentially powerful extension for managing many kinds of devices.

## Look and feel

- **Animated startup intro:** a short, fast pop-in or drawing of the hero Rhodonea and light-trails visual.
- **Themes,** or an alternative accent colour for users who dislike orange.
- **Dark-venue clarity:** controls and settings stay readable on a dark stage. Follow Tufte's data-ink principle: show the data and drop the decoration.
