# Instructions for Claude (and other coding agents)

Start with [docs/CLAUDE_HANDOFF.md](docs/CLAUDE_HANDOFF.md): current checkpoint, architecture, build/test commands, hardware evidence, flashing rules and App Store status.

Naming: the app is **Trillium**; **Trill** is the Bela sensor (and the firmware, USB device, protocol, crates, `TrillKit` and the repo keep that name).

Hard rules:
- No firmware flashing, publishing, tags, releases, merges, App Store Connect submissions or Apple account changes without the user's explicit approval for that specific step.
- Never force-push or rewrite pushed history.
- Keep GPL-3.0-only + commercial licensing; no incompatible or ambiguous third-party code.
- No credentials, team IDs, device serials or firmware backups in the repository.
- Say exactly what was tested on hardware versus only in CI or simulation.

Before committing: `make ci` (Rust + firmware), `make apple-test` (TrillKit), and `make protocol-vectors` if the protocol changed.
