#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Tests for apple/scripts/export_ipa.py helpers (stdlib unittest)."""

import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "apple", "scripts"))
import export_ipa as ex  # noqa: E402


XC = """\
// comment
TRILL_BUNDLE_ID = com.example.trill
DEVELOPMENT_TEAM =
#include? "Local.xcconfig"
DEVELOPMENT_TEAM = TEAMID1234
MARKETING_VERSION = 0.5.0
"""


class ExportIpaTests(unittest.TestCase):
    def test_parse_last_assignment_wins_and_skips_includes(self):
        v = ex.parse_xcconfig(XC)
        self.assertEqual(v["DEVELOPMENT_TEAM"], "TEAMID1234")
        self.assertEqual(v["TRILL_BUNDLE_ID"], "com.example.trill")
        self.assertEqual(v["MARKETING_VERSION"], "0.5.0")
        self.assertNotIn("#include?", v)

    def test_development_team_rejects_empty_and_example(self):
        with self.assertRaises(SystemExit):
            ex.development_team({})
        with self.assertRaises(SystemExit):
            ex.development_team({"DEVELOPMENT_TEAM": ""})
        with self.assertRaises(SystemExit):
            ex.development_team({"DEVELOPMENT_TEAM": ex.EXAMPLE_TEAM})
        self.assertEqual(ex.development_team({"DEVELOPMENT_TEAM": "AB1234CDE5"}), "AB1234CDE5")

    def test_export_options_are_development_and_automatic(self):
        opts = ex.export_options("AB1234CDE5")
        self.assertEqual(opts["method"], "development")
        self.assertEqual(opts["teamID"], "AB1234CDE5")
        self.assertEqual(opts["signingStyle"], "automatic")
        self.assertFalse(opts["compileBitcode"])


if __name__ == "__main__":
    unittest.main()
