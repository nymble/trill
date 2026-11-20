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

PAGES = ["index.html", "zero/index.html", "sense/index.html", "privacy/index.html"]


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

    def test_pages_name_no_third_party_sensor(self):
        # Current pages speak only about the board on a cable; sensor brands stay out.
        for p in PAGES:
            html = read(p)
            self.assertNotRegex(html, r"\bTrill\b|\bBela\b|Trill Flex", p)
            self.assertNotRegex(html, r"\bF1\b|\bT2\b|\bT1\b", p)

    def test_pages_lead_with_the_trillium_lockup(self):
        # The M-of-N site header and nav are gone; pages open on the lockup.
        # Titles and share text lead with Trillium. M-of-N stays a footer credit,
        # and the privacy page still names who operates the app.
        for p in PAGES:
            html = read(p)
            # Exactly one trefoil mark per page: the lockup (mark left of the name).
            self.assertEqual(len(re.findall(r'<img[^>]*lockup\.svg', html)), 1, p)
            if p == "index.html":
                # The top page has no header; its one lockup is the hero h1.
                self.assertNotIn('class="site-header"', html)
                self.assertRegex(html, r'<h1><img class="hero-lockup"[^>]*alt="Trillium"></h1>')
                header = '<a class="tr-lockup">'
            else:
                header = re.search(r'<header class="site-header">.*?</header>', html, re.S).group(0)
            footer = re.search(r'<footer class="site-footer">.*?</footer>', html, re.S).group(0)
            title = re.search(r"<title>([^<]+)</title>", html).group(1)
            og = re.search(r'property="og:title" content="([^"]+)"', html).group(1)
            self.assertIn('class="tr-lockup"', header, p)
            self.assertNotIn("M-of-N", header, p)
            self.assertNotRegex(header, r'class="brand"|class="nav"|aria-label="Primary"', p)
            self.assertIn("Trillium", title, p)
            self.assertIn("Trillium", og, p)
            self.assertNotIn("M-of-N", title, p)
            self.assertNotIn("M-of-N", og, p)
            self.assertNotIn("og:site_name", html, p)
            self.assertIn("&copy; 2026", footer, p)
            self.assertIn("M-of-N", footer, p)
            self.assertIn('href="/"', footer, p)
            self.assertIn("trillium.css?v=9", html, p)
            self.assertIn("Trillium privacy", footer, p)
        privacy = read("privacy/index.html")
        self.assertIn("a project of M-of-N", privacy)
        self.assertIn("Effective 19 November 2026", privacy)
        self.assertIn("Bluetooth permission", privacy)
        self.assertIn("does not use your device", privacy)

    def test_downloads_point_at_the_current_release(self):
        html = read("sense/index.html")
        base = "https://github.com/nymble/trillium/releases/download/v0.7.0/"
        self.assertIn(base + "Trillium-macOS-0.7.0.dmg", html)
        self.assertIn(base + "xiao-sense-fw-0.7.0.uf2", html)
        for p in PAGES:
            self.assertNotRegex(read(p), r"v0\.[0-6]\.|\b0\.[0-6]\.0\b", p)

    def test_cheatsheet_names_its_sources(self):
        html = read("sense/index.html")
        for src in ("BuiltInPresets.swift", "ConfigProtocol.swift", "MappingSummary.swift",
                    "instrument-events/src/engine.rs", "docs/releasing.md", "v0.7.0"):
            self.assertIn(src, html, src)

    def test_assets_carry_no_provenance_metadata(self):
        for d, _, names in os.walk(ts.ASSETS):
            for n in names:
                if n.endswith((".svg", ".png", ".jpg", ".webp", ".css")):
                    with open(os.path.join(d, n), "rb") as f:
                        data = f.read()
                    for marker in (b"c2pa", b"Claude", b"Anthropic"):
                        self.assertNotIn(marker, data, f"{n}: {marker!r}")

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
