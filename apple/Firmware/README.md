# Firmware carried in the Trillium app

`make apple-firmware` copies the application-only UF2 for this version
(`dist/xiao-sense-fw-<version>.uf2`, from `make fw-uf2`) here as
`xiao-sense-fw.uf2`, with `firmware.json` (version, SHA-256, board). The app
bundles this folder as `Firmware/` and offers to install that image on a
Seeed Studio XIAO nRF52840 Sense. Nothing here is committed except this file
and `.gitignore`. The script refuses an image whose version differs from the
app's, so an app always carries the firmware of its own version.
