# For AI agents (Claude, Grok, Codex, Cursor, …)

Before you make or change anything visual for Trillium (icons, UI colors, web pages, release notes, slides, social images, docs), **read `BRAND.md` in this folder.** Then:

1. **Use the files here instead of recreating them.** Marks: `icons/svg/`. Wordmark and lockups: `wordmark/`. Key visuals: `visuals/`. In-app icons: `ui-icons/`.
2. **Use the tokens, never hand-typed hex values.** Web: `tokens/tokens.css` (`--tr-*`). Swift: `tokens/TrilliumColors.swift`. Anything else: `tokens/tokens.json`.
3. **Orange (`#FF5A1F`) is a signal.** It's for the mark, the single active state, and one primary button per screen. Buttons are orange with **black** text. Never put white text on orange, and never use orange as text on light backgrounds (use Rust `#C23D0E`).
4. **Names.** In prose, "Trillium". In the wordmark, lowercase "trillium". The umbrella is "Ambient Lab". Don't name a parent company.
5. **Never redraw, rotate or recolor the Rhodonea mark.** One petal always points up.
6. **Fonts:** Outfit for headings, Inter for UI and body, IBM Plex Mono for technical values.

If something you need isn't covered here, follow the spirit of `BRAND.md` (mostly black, warm white for text, orange used sparingly) and flag the gap to a human rather than inventing new brand elements.
