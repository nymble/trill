#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Tests for tools/release_notes.py (stdlib unittest)."""

import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(__file__))
import release_notes as rn  # noqa: E402

LOG = """# Changelog

## [Unreleased]

## [0.5.0] - 2026-11-09

### Added
- Strikes.

## [0.4.0]

- Old.
"""


class ReleaseNotesTests(unittest.TestCase):
    def test_extracts_only_that_version(self):
        s = rn.section(LOG, "0.5.0")
        self.assertIn("Strikes.", s)
        self.assertNotIn("Old.", s)
        self.assertTrue(rn.section(LOG, "0.4.0").endswith("Old."))

    def test_missing_or_empty_section_fails(self):
        with self.assertRaises(SystemExit):
            rn.section(LOG, "0.6.0")
        with self.assertRaises(SystemExit):
            rn.section(LOG, "Unreleased")

    def test_downloads_name_the_version(self):
        notes = rn.DOWNLOADS.format(v="1.2.3")
        self.assertIn("xiao-sense-fw-1.2.3.uf2", notes)
        self.assertIn("Trillium-iOS-Simulator-1.2.3.zip", notes)
        self.assertIn("Trillium-macOS-unsigned-dev-1.2.3.zip", notes)


if __name__ == "__main__":
    unittest.main()
