#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""The app's brand assets are unchanged copies of the kit in brand/ (stdlib unittest)."""

import filecmp
import json
import os
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BRAND = os.path.join(ROOT, "brand")
APP = os.path.join(ROOT, "apple", "App")
CATALOG = os.path.join(APP, "Shared", "Assets.xcassets", "Brand")


def same(a: str, b: str) -> bool:
    return filecmp.cmp(a, b, shallow=False)


class BrandAssetTests(unittest.TestCase):
    def test_app_icon_sets_match_the_kit(self):
        for platform in ("macOS", "iOS"):
            kit = os.path.join(BRAND, "apple", f"{platform}-AppIcon.appiconset")
            app = os.path.join(APP, platform, "AppIcon.xcassets", "AppIcon.appiconset")
            self.assertEqual(sorted(os.listdir(kit)), sorted(os.listdir(app)), platform)
            for name in os.listdir(kit):
                self.assertTrue(same(os.path.join(kit, name), os.path.join(app, name)), f"{platform}/{name}")

    def test_no_shared_app_icon(self):
        self.assertFalse(os.path.exists(os.path.join(APP, "Shared", "Assets.xcassets", "AppIcon.appiconset")))

    def test_ui_icons_and_marks_match_the_kit(self):
        pairs = {f"icon-{n[:-4]}": os.path.join(BRAND, "ui-icons", n)
                 for n in os.listdir(os.path.join(BRAND, "ui-icons")) if n.endswith(".svg")}
        pairs["rhodonea-glyph"] = os.path.join(BRAND, "icons", "svg", "rhodonea-glyph.svg")
        pairs["lockup-primary"] = os.path.join(BRAND, "wordmark", "lockup-primary-transparent.svg")
        for asset, src in pairs.items():
            d = os.path.join(CATALOG, f"{asset}.imageset")
            copy = os.path.join(d, os.path.basename(src))
            self.assertTrue(os.path.isfile(copy), asset)
            self.assertTrue(same(src, copy), asset)
            with open(os.path.join(d, "Contents.json"), encoding="utf-8") as f:
                props = json.load(f)["properties"]
            want = "original" if asset == "lockup-primary" else "template"
            self.assertEqual(props["template-rendering-intent"], want, asset)

    def test_no_embedded_provenance_metadata(self):
        """No C2PA manifests (PNG caBX chunks, SVG <metadata>) or PNG text chunks."""
        for top in (BRAND, APP):
            for root, _, files in os.walk(top):
                for name in files:
                    path = os.path.join(root, name)
                    if name.endswith(".svg"):
                        with open(path, encoding="utf-8") as f:
                            text = f.read()
                        self.assertNotIn("<metadata", text, path)
                        self.assertNotIn("c2pa", text, path)
                    elif name.endswith(".png"):
                        with open(path, "rb") as f:
                            data = f.read()
                        i = 8
                        while i < len(data):
                            n = int.from_bytes(data[i:i + 4], "big")
                            kind = data[i + 4:i + 8]
                            self.assertNotIn(kind, (b"caBX", b"tEXt", b"iTXt", b"zTXt", b"eXIf"), path)
                            i += 12 + n


if __name__ == "__main__":
    unittest.main()
