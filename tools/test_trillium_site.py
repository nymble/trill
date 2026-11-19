#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Checks for site/trillium (the Trillium pages on m-of-n.com). Stdlib unittest."""

import filecmp
import os
import re
import sys
import tempfile
import unittest
import zipfile

sys.path.insert(0, os.path.dirname(__file__))
import trillium_site as ts  # noqa: E402

PAGES = ["index.html", "zero/index.html", "privacy/index.html"]


def read(rel: str) -> str:
    with open(os.path.join(ts.SITE, rel), encoding="utf-8") as f:
        return f.read()


class TrilliumSiteTests(unittest.TestCase):
    def test_brand_copies_are_unchanged(self):
        for out, src in ts.COPIES.items():
            self.assertTrue(filecmp.cmp(os.path.join(ts.ASSETS, out), os.path.join(ts.BRAND, src), shallow=False), out)

    def test_derived_images_exist(self):
        for out, *_ in ts.DERIVED:
            self.assertGreater(os.path.getsize(os.path.join(ts.ASSETS, out)), 1000, out)

    def test_fonts_ship_with_their_licence(self):
        fonts = os.path.join(ts.ASSETS, "fonts")
        names = os.listdir(fonts)
        for family in ("Outfit", "Inter", "IBM-Plex-Mono"):
            self.assertIn(f"OFL-{family}.txt", names)
            with open(os.path.join(fonts, f"OFL-{family}.txt"), encoding="utf-8") as f:
                self.assertIn("SIL Open Font License", f.read())

    def test_pages_follow_the_csp_and_stay_noindex(self):
        for p in PAGES:
            html = read(p)
            self.assertIn('<meta name="robots" content="noindex">', html, p)
            self.assertNotRegex(html, r"<script|<style|\sstyle=|\son[a-z]+=|data:", p)
            # No external assets: stylesheets, icons and images load from this site only.
            for tag in re.findall(r"<(?:img|link)\b[^>]*>", html):
                if "<link" in tag and not re.search(r'rel="(?:stylesheet|icon|apple-touch-icon|preload)"', tag):
                    continue
                ref = re.search(r'(?:href|src)="([^"]+)"', tag).group(1)
                self.assertTrue(ref.startswith("/") or not re.match(r"[a-z]+:|//", ref), f"{p}: {ref}")
            for rel in ("tokens.css?v=", "trillium.css?v=", "icons/rhodonea-32.png", "icons/rhodonea-180.png",
                        "og-image-1200x630.jpg", "lockup.svg"):
                self.assertIn(rel, html, f"{p}: {rel}")

    def test_css_is_self_contained(self):
        for name in ("trillium.css", "tokens.css"):
            css = read(f"assets/{name}")
            self.assertNotIn("data:", css)
            self.assertNotRegex(css, r"url\(\s*[\"']?(https?:)?//", name)
            self.assertNotRegex(css, r"@import")
        # Colours come from the tokens only.
        self.assertNotRegex(read("assets/trillium.css"), r"#[0-9A-Fa-f]{3,8}\b|rgba?\(")

    def test_bundle_replaces_only_the_trillium_pages(self):
        base = {"_headers": b"h", "_redirects": b"r", "index.html": b"i", "style.css": b"s",
                "ambient-lab/index.html": b"a", "ambient-lab/trillium/index.html": b"old",
                "ambient-lab/trillium/old.txt": b"gone"}
        with tempfile.TemporaryDirectory() as d:
            src, out = os.path.join(d, "base.zip"), os.path.join(d, "out.zip")
            with zipfile.ZipFile(src, "w") as z:
                for k, v in base.items():
                    z.writestr(k, v)
            ts.bundle(src, out)
            with zipfile.ZipFile(out) as z:
                got = {n: z.read(n) for n in z.namelist()}
        for k in ("_headers", "_redirects", "index.html", "style.css", "ambient-lab/index.html"):
            self.assertEqual(got[k], base[k], k)
        self.assertNotIn("ambient-lab/trillium/old.txt", got)
        self.assertIn("ambient-lab/trillium/assets/trillium.css", got)
        self.assertNotIn("ambient-lab/trillium/README.md", got)
        self.assertTrue(all(not n.startswith("/") and ".." not in n for n in got))

    def test_bundle_refuses_a_partial_tree(self):
        with tempfile.TemporaryDirectory() as d:
            src = os.path.join(d, "base.zip")
            with zipfile.ZipFile(src, "w") as z:
                z.writestr("index.html", b"i")
            with self.assertRaises(SystemExit):
                ts.bundle(src, os.path.join(d, "out.zip"))


if __name__ == "__main__":
    unittest.main()
