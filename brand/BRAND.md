# Trillium brand guide

**Trillium** is the companion app for motion- and touch-sensing musical instruments, an **Ambient Lab** project. This file is the source of truth for anything visual: app icons, web pages, release notes, slides, social images and UI. People and AI agents should read it before making anything that represents Trillium.

Palette name: **Stage**. Black, signal orange and warm white, like a lit stage and a hardware LED.

---

## 1. Name

- In prose: **Trillium**. In the wordmark: lowercase **trillium**.
- Umbrella: **Ambient Lab**. Write it as "Trillium, an Ambient Lab project", or the endorsement line "Ambient Lab".
- Hardware models: T0 (Trillium Zero), T1, T2, F1. Write "Trillium Zero", not "Trillium 0".
- Don't name a parent company in brand materials.

## 2. Marks

| Mark | Use | Files |
|---|---|---|
| **Rhodonea** (primary) | App icon, wordmark lockup, favicon, avatar | `icons/svg/rhodonea-*`, `wordmark/lockup-*` |
| **Field lines** (secondary) | Firmware installer, document icons, the hardware enclosure, packaging details | `icons/svg/field-*` |

- **Rhodonea** is the rose curve *r = cos 3θ*, which draws exactly three petals in one continuous line, like a gesture traced in the air. It shows three lines: the main stroke and two fainter, slightly turned echoes.
- **Field lines** are four nested petal outlines in each of three directions, like the field around a theremin's antenna.
- Both rest on the trillium flower's threefold symmetry (three petals at 120°), which mirrors the instrument's three motion axes.

**Clear space:** keep at least 25% of the mark's height empty on every side.

**Minimum size:**
- App icon: 16 px.
- One-color glyph: 12 px.
- Horizontal lockup: 24 px tall.

**Don't:**
- Rotate the mark (one petal always points up).
- Add or remove petals or echo lines.
- Outline, emboss, add a drop shadow (outside the macOS icon file) or place it on busy photos.
- Recolor it outside the palette.
- Put the orange mark on the orange background. Use the reversed (black) version there.

## 3. Wordmark

- Lowercase "trillium" in **Outfit Light (300)**, tracking +0.02 em. Regular (400) is used for the reversed and one-color versions.
- The letters are already converted to outlines in `wordmark/`, so no font is needed to use them.
- In the lockup, the Rhodonea mark sits left of the word, centered vertically. The mark box is about 1.8 times the word's ascender height.
- Approved lockups:
  - `lockup-primary-on-black`: signal mark, warm-white word. This is the default.
  - `lockup-on-warm-white`: ember mark, black word.
  - `lockup-reversed-on-signal`: all black on orange.
  - `lockup-one-color`: `currentColor`, for print, engraving and single-color merchandise.

## 4. Color

| Token | Hex | Role | Share of layout |
|---|---|---|---|
| Black | `#0C0C0D` | Primary ground | ~58% |
| Graphite | `#232326` | Panels, cards, icon ground | ~20% |
| Warm white | `#F4F1EA` | Text on black; light ground | ~13% |
| **Signal** | `#FF5A1F` | Mark, active state, primary button | ~6% |
| Amber | `#FFB020` | Levels, meters, highlights only | ~3% |
| Ash | `#8A8580` | Secondary text on black | — |
| Ash light | `#B3ADA4` | Resting icons, captions | — |
| Ember | `#E8480F` | The mark on light grounds (not for text) | — |
| Rust | `#C23D0E` | Orange text on light grounds | — |
| Unavailable | `#55524D` | Disabled UI on black (not for text) | — |
| Connected | `#6FAE9A` | Connected / OK status | — |

Machine-readable versions:
- `tokens/tokens.json` (W3C design-token format)
- `tokens/tokens.css` (CSS custom properties, `--tr-*`)
- `tokens/TrilliumColors.swift` (SwiftUI)

**Orange is a signal, not a decoration.** Use it for the mark, the one thing that's live or active, and at most one call to action per screen.

### Contrast rules (measured, WCAG 2.x)

| Pair | Ratio | Rule |
|---|---|---|
| Warm white on Black | 17.3:1 | All body text |
| Ash on Black | 5.4:1 | Secondary text |
| Signal on Black | 6.3:1 | OK for the mark, active labels, short text |
| Black on Signal | 6.3:1 | **Buttons: orange with black text** |
| White on Signal | 2.8:1 | **Never.** No white text on orange |
| Signal on Warm white | 2.8:1 | **Never** as text. Use Rust (4.7:1) |
| Amber on Black | 10.7:1 | Meters and levels |

## 5. Type

| Role | Family | Weights | Use |
|---|---|---|---|
| Display | **Outfit** | 300–500 | Headings, the wordmark, large numbers |
| Interface | **Inter** | 400–600 | UI, body copy, release notes |
| Technical | **IBM Plex Mono** | 400–500 | Firmware versions, MIDI values (`CC 74 · ch 1`), sensor readouts |

All three are open source (SIL Open Font License) and available on Google Fonts. In the Apple apps, the system font (SF Pro) is fine for interface text. Keep Outfit for the wordmark and headings.

## 6. Interface

- Dark first: Black ground, Graphite surfaces, Warm-white text.
- In-app icons: 24 px grid, 1.75 px round stroke, `currentColor`. The 12 icons are in `ui-icons/`.
- Icon states:
  - Rest: Ash light.
  - Hover: Warm white.
  - **Active: Signal**, plus an underline or a tinted background.
  - Unavailable: `#55524D`.
- Only the live sensor mode is orange, so a performer can see what's active from across a stage.
- Status: connected uses the Connected green dot; battery and MIDI values use the mono font.
- Corner radius: 20 px for cards, 10 px for controls, pills for buttons.

## 7. Key visual: Light trails

- Layered rose curves, like a long exposure of the instrument moving.
- Dark is the default. The warm-white version is for release notes, print and docs.
- On wide formats, the trails sit off-center so text has room. The ready-made crops in `visuals/` show the placement.
- Text over the visual: warm white on dark; black, with Rust for the label, on light.
- Don't crop through the center point, place text over the trails, or tint them outside the palette.

## 8. Apple app icons

| Platform | Files | Notes |
|---|---|---|
| macOS | `apple/macOS-AppIcon.appiconset`, `apple/Trillium.icns` | Uses Apple's macOS icon grid: an 824 px body on a 1024 px canvas, with a soft shadow |
| iOS / iPadOS | `apple/iOS-AppIcon.appiconset` | Single 1024 px size, opaque and full bleed: any (dark Stage), dark, tinted (mono) |

To use them, replace the contents of `apple/App/Shared/Assets.xcassets/AppIcon.appiconset` with the matching set. That catalog is shared by both targets, so you may need to split it into per-platform catalogs. This hasn't been applied to the app yet.

## 9. File index

```
brand/
  BRAND.md                 this guide
  AGENTS.md                short instructions for AI agents
  README.md                what's here
  tokens/                  tokens.json · tokens.css · TrilliumColors.swift
  icons/svg/               rhodonea-* and field-*: app (dark/light/mono, rounded + square), macos, glyph (currentColor)
  icons/png/               512/1024 previews; web/ favicon and touch-icon sizes
  apple/                   macOS + iOS .appiconset, Trillium.icns
  wordmark/                outlined wordmark (300/400), 5 lockups (SVG) + png/@2x
  visuals/svg|png/         Light trails: portrait dark/light, web hero, OG image, social, iPhone launch, release header
  ui-icons/                12 in-app icons, 24 px, currentColor
```

## 10. Where this came from

Designed on the "Trillium — Brand Concepts" canvas (rounds 1–3). Every mark and visual comes from code: rose curves and scaled petal outlines. To change something, change the geometry, not hand-edited pixels.
