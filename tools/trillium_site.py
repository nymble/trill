#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Trillium pages on m-of-n.com: brand assets and the full-site upload zip.

    trillium_site.py assets                  # refresh site/trillium/assets from brand/
    trillium_site.py bundle BASE OUT.zip     # BASE: deploy tree folder or upload zip

`site/trillium/` is served at /ambient-lab/trillium/. `bundle` copies BASE
(the rest of the site, unchanged) and replaces ambient-lab/trillium/ with
site/trillium/. It refuses to run if BASE lacks _headers or _redirects, and
never adds files outside ambient-lab/trillium/. Needs Pillow for `assets`.
"""

import io
import os
import shutil
import sys
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BRAND = os.path.join(ROOT, "brand")
SITE = os.path.join(ROOT, "site", "trillium")
ASSETS = os.path.join(SITE, "assets")
PREFIX = "ambient-lab/trillium/"

# Unchanged copies of brand files (checked by tools/test_trillium_site.py).
COPIES = {
    "tokens.css": "tokens/tokens.css",
    "lockup.svg": "wordmark/lockup-primary-transparent.svg",
    "icons/rhodonea-32.png": "icons/png/web/rhodonea-32.png",
    "icons/rhodonea-180.png": "icons/png/web/rhodonea-180.png",
    "icons/rhodonea-192.png": "icons/png/web/rhodonea-192.png",
    "icons/rhodonea-512.png": "icons/png/web/rhodonea-512.png",
}

# Web-size derivatives: (output, brand source, width or None, format, quality).
DERIVED = [
    ("og-image-1200x630.jpg", "visuals/png/og-image-1200x630.png", None, "JPEG", 86),
    ("hero-2400.webp", "visuals/png/hero-web-2400x1000.png", None, "WEBP", 80),
    ("hero-1600.webp", "visuals/png/hero-web-2400x1000.png", 1600, "WEBP", 80),
    ("hero-1600.jpg", "visuals/png/hero-web-2400x1000.png", 1600, "JPEG", 84),
]


def assets() -> None:
    from PIL import Image

    for out, src in COPIES.items():
        dst = os.path.join(ASSETS, out)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copyfile(os.path.join(BRAND, src), dst)
    for out, src, width, fmt, q in DERIVED:
        im = Image.open(os.path.join(BRAND, src)).convert("RGB")
        if width and im.width != width:
            im = im.resize((width, round(im.height * width / im.width)), Image.LANCZOS)
        kw = {"quality": q, "method": 6} if fmt == "WEBP" else {"quality": q, "optimize": True, "progressive": True}
        im.save(os.path.join(ASSETS, out), fmt, **kw)


def base_files(base: str) -> dict:
    files = {}
    if os.path.isdir(base):
        for d, _, names in os.walk(base):
            for n in names:
                p = os.path.join(d, n)
                with open(p, "rb") as f:
                    files[os.path.relpath(p, base).replace(os.sep, "/")] = f.read()
    else:
        with zipfile.ZipFile(base) as z:
            for i in z.infolist():
                if not i.is_dir():
                    files[i.filename] = z.read(i)
    return files


def bundle(base: str, out: str) -> None:
    files = base_files(base)
    for need in ("_headers", "_redirects", "index.html", PREFIX + "index.html"):
        if need not in files:
            raise SystemExit(f"{base}: missing {need}; not a full m-of-n.com deploy tree")
    files = {k: v for k, v in files.items() if not k.startswith(PREFIX)}
    for d, _, names in os.walk(SITE):
        for n in names:
            p = os.path.join(d, n)
            if n.startswith(".") or n == "README.md":
                continue
            with open(p, "rb") as f:
                files[PREFIX + os.path.relpath(p, SITE).replace(os.sep, "/")] = f.read()
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        for name in sorted(files):
            info = zipfile.ZipInfo(name, date_time=(2026, 11, 19, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            z.writestr(info, files[name])
    with open(out, "wb") as f:
        f.write(buf.getvalue())


def main() -> None:
    if sys.argv[1:2] == ["assets"] and len(sys.argv) == 2:
        assets()
    elif sys.argv[1:2] == ["bundle"] and len(sys.argv) == 4:
        bundle(sys.argv[2], sys.argv[3])
    else:
        raise SystemExit(__doc__)


if __name__ == "__main__":
    main()
