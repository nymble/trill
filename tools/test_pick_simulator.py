#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Tests for apple/scripts/pick_simulator.py (stdlib unittest)."""

import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "apple", "scripts"))
import pick_simulator as ps  # noqa: E402


def devices(**runtimes):
    """Build a simctl-like devices map: runtime suffix -> list of (name, udid, available)."""
    out = {}
    for runtime, entries in runtimes.items():
        key = f"com.apple.CoreSimulator.SimRuntime.{runtime}"
        out[key] = [
            {"name": name, "udid": udid, "isAvailable": available}
            for name, udid, available in entries
        ]
    return out


class PickSimulatorTests(unittest.TestCase):
    def test_iphone_prefers_newest_runtime(self):
        d = devices(
            **{
                "iOS-17-0": [("iPhone 15", "old", True)],
                "iOS-18-4": [("iPhone 16", "new", True), ("iPad Pro 13-inch (M4)", "pad", True)],
            }
        )
        chosen = ps.pick(d, "iphone")
        self.assertEqual(chosen["udid"], "new")

    def test_ipad_prefers_pro_on_newest_runtime(self):
        d = devices(
            **{
                "iOS-18-4": [
                    ("iPad mini (A17 Pro)", "mini", True),
                    ("iPad Pro 13-inch (M4)", "pro", True),
                    ("iPad (10th generation)", "std", True),
                ],
                "iOS-17-5": [("iPad Pro 12.9-inch (6th generation)", "old-pro", True)],
            }
        )
        chosen = ps.pick(d, "ipad")
        self.assertEqual(chosen["udid"], "pro")
        self.assertEqual(chosen["name"], "iPad Pro 13-inch (M4)")

    def test_skips_unavailable_and_empty_runtimes(self):
        d = devices(
            **{
                "iOS-18-4": [("iPad Pro 13-inch (M4)", "busy", False)],
                "iOS-18-2": [("iPad Air 11-inch (M2)", "air", True)],
            }
        )
        self.assertEqual(ps.pick(d, "ipad")["udid"], "air")

    def test_missing_kind_returns_none(self):
        d = devices(**{"iOS-18-4": [("iPhone 16", "ph", True)]})
        self.assertIsNone(ps.pick(d, "ipad"))
        self.assertIsNone(ps.pick(devices(), "iphone"))

    def test_rejects_unknown_kind(self):
        with self.assertRaises(ValueError):
            ps.pick({}, "watch")


if __name__ == "__main__":
    unittest.main()
