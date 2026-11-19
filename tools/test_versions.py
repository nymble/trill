#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Workspace, firmware and app versions stay in agreement; export compliance is set."""

from __future__ import annotations

import plistlib
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def cargo_version(path: Path) -> str:
    text = path.read_text(encoding="utf-8")
    m = re.search(r'^version = "([^"]+)"', text, re.M)
    if not m:
        raise AssertionError(f"no version in {path}")
    return m.group(1)


def xcconfig_value(path: Path, key: str) -> str:
    text = path.read_text(encoding="utf-8")
    m = re.search(rf"^{re.escape(key)} = (\S+)$", text, re.M)
    if not m:
        raise AssertionError(f"no {key} in {path}")
    return m.group(1)


class VersionAgreementTests(unittest.TestCase):
    def test_cargo_firmware_and_app_versions_match(self) -> None:
        workspace = cargo_version(ROOT / "Cargo.toml")
        firmware = cargo_version(ROOT / "firmware" / "xiao-sense" / "Cargo.toml")
        app = xcconfig_value(ROOT / "apple" / "Config" / "Base.xcconfig", "MARKETING_VERSION")
        self.assertEqual(workspace, firmware)
        self.assertEqual(workspace, app)
        self.assertRegex(workspace, r"^\d+\.\d+\.\d+$")

    def test_bundle_id_is_net_nymbus_trillium(self) -> None:
        bundle = xcconfig_value(ROOT / "apple" / "Config" / "Base.xcconfig", "TRILL_BUNDLE_ID")
        self.assertEqual(bundle, "net.nymbus.trillium")
        yml = (ROOT / "apple" / "project.yml").read_text(encoding="utf-8")
        self.assertIn("PRODUCT_BUNDLE_IDENTIFIER: $(TRILL_BUNDLE_ID)", yml)
        self.assertIn("PRODUCT_BUNDLE_IDENTIFIER: $(TRILL_BUNDLE_ID).tests", yml)
        self.assertNotIn("$(TRILL_BUNDLE_ID).uitests", yml)

    def test_build_number_is_a_positive_integer(self) -> None:
        build = xcconfig_value(ROOT / "apple" / "Config" / "Base.xcconfig", "CURRENT_PROJECT_VERSION")
        self.assertGreater(int(build), 0)

    def test_changelog_has_a_section_for_the_current_version(self) -> None:
        version = cargo_version(ROOT / "Cargo.toml")
        log = (ROOT / "CHANGELOG.md").read_text(encoding="utf-8")
        self.assertRegex(log, re.compile(rf"^## \[{re.escape(version)}\] - \d{{4}}-\d{{2}}-\d{{2}}$", re.M))

    def test_export_compliance_is_false_on_ios_and_macos(self) -> None:
        for rel in ("apple/App/iOS/Info.plist", "apple/App/macOS/Info.plist"):
            with self.subTest(rel=rel):
                data = plistlib.loads((ROOT / rel).read_bytes())
                self.assertIn("ITSAppUsesNonExemptEncryption", data)
                self.assertIs(data["ITSAppUsesNonExemptEncryption"], False)


class TestFlightScriptTests(unittest.TestCase):
    def test_dry_run_writes_app_store_connect_export_options(self) -> None:
        import os
        import shutil
        import subprocess
        import tempfile

        script = ROOT / "apple" / "scripts" / "archive_testflight.sh"
        self.assertTrue(script.is_file())
        out = Path(tempfile.mkdtemp(prefix="tf-dry-"))
        try:
            env = os.environ.copy()
            env["TEAM_ID"] = "ABCD123456"
            env["DRY_RUN"] = "1"
            env["OUT_DIR"] = str(out)
            # Avoid leaving a Local.xcconfig if the script is interrupted.
            subprocess.run([str(script), "ios"], cwd=ROOT, env=env, check=True)
            opts = plistlib.loads((out / "ExportOptions-ios.plist").read_bytes())
            self.assertEqual(opts["method"], "app-store-connect")
            self.assertEqual(opts["teamID"], "ABCD123456")
            self.assertEqual(opts["signingStyle"], "automatic")
            self.assertEqual(opts["destination"], "export")
            self.assertIs(opts["manageAppVersionAndBuildNumber"], False)
            self.assertFalse((ROOT / "apple" / "Config" / "Local.xcconfig").exists())
        finally:
            shutil.rmtree(out, ignore_errors=True)

    def test_upload_dry_run_keeps_export_and_mentions_altool(self) -> None:
        import os
        import shutil
        import subprocess
        import tempfile

        out = Path(tempfile.mkdtemp(prefix="tf-up-"))
        try:
            env = os.environ.copy()
            env.update({"TEAM_ID": "ABCD123456", "DRY_RUN": "1", "UPLOAD": "1", "OUT_DIR": str(out)})
            proc = subprocess.run(
                [str(ROOT / "apple" / "scripts" / "archive_testflight.sh"), "both"],
                cwd=ROOT,
                env=env,
                check=True,
                capture_output=True,
                text=True,
            )
            self.assertIn("altool", proc.stdout)
            for name in ("ExportOptions-ios.plist", "ExportOptions-macos.plist"):
                opts = plistlib.loads((out / name).read_bytes())
                self.assertEqual(opts["destination"], "export")
                self.assertEqual(opts["method"], "app-store-connect")
        finally:
            shutil.rmtree(out, ignore_errors=True)

    def test_asc_key_p8_accepts_pem_and_base64(self) -> None:
        import base64
        import os
        import shutil
        import subprocess
        import tempfile

        pem = "-----BEGIN PRIVATE KEY-----\nTESTKEY\n-----END PRIVATE KEY-----"
        out = Path(tempfile.mkdtemp(prefix="tf-key-"))
        script = ROOT / "apple" / "scripts" / "archive_testflight.sh"
        try:
            for label, value in (("pem", pem), ("b64", base64.b64encode(pem.encode()).decode())):
                dest_dir = out / label
                dest_dir.mkdir()
                env = os.environ.copy()
                env.update({
                    "TEAM_ID": "ABCD123456",
                    "DRY_RUN": "1",
                    "KEEP_ASC_KEY": "1",
                    "OUT_DIR": str(dest_dir),
                    "ASC_KEY_ID": "TESTID12",
                    "ASC_ISSUER_ID": "00000000-0000-0000-0000-000000000000",
                    "ASC_KEY_P8": value,
                })
                subprocess.run([str(script), "ios"], cwd=ROOT, env=env, check=True, capture_output=True, text=True)
                written = (dest_dir / "AuthKey_TESTID12.p8").read_text()
                self.assertIn("BEGIN PRIVATE KEY", written)
                self.assertIn("TESTKEY", written)
        finally:
            shutil.rmtree(out, ignore_errors=True)


if __name__ == "__main__":
    unittest.main()
