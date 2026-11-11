#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Archive and export a development IPA of Trillium for a physical iPhone or iPad.

Requires macOS with Xcode, a generated apple/Trillium.xcodeproj
(`make apple-project`), and apple/Config/Local.xcconfig (git-ignored) with
DEVELOPMENT_TEAM set to your team. Team IDs, certificates and profiles are
never committed. CI does not run this script.

Usage (from the repository root, or via `make apple-ios-ipa`):

    python3 apple/scripts/export_ipa.py

The IPA is written to dist/apple/Trillium-iOS-dev-<version>.ipa. Install it
with Xcode, Apple Configurator, or:

    xcrun devicectl device install app --device <udid> dist/apple/Trillium-iOS-dev-<version>.ipa
"""
from __future__ import annotations

import argparse
import plistlib
import re
import shutil
import subprocess
import sys
from pathlib import Path

EXAMPLE_TEAM = "ABCDE12345"
ASSIGN = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$")


def parse_xcconfig(text: str) -> dict[str, str]:
    """Parse simple KEY = VALUE lines. Last assignment wins. Ignores includes and comments."""
    values: dict[str, str] = {}
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("//") or line.startswith("#"):
            continue
        if line.startswith("#include"):
            continue
        m = ASSIGN.match(line)
        if not m:
            continue
        values[m.group(1)] = m.group(2).strip()
    return values


def load_xcconfig(path: Path) -> dict[str, str]:
    return parse_xcconfig(path.read_text(encoding="utf-8"))


def development_team(local: dict[str, str]) -> str:
    team = local.get("DEVELOPMENT_TEAM", "").strip()
    if not team:
        raise SystemExit(
            "apple/Config/Local.xcconfig has no DEVELOPMENT_TEAM.\n"
            "Copy apple/Config/Local.xcconfig.example to Local.xcconfig "
            "and set DEVELOPMENT_TEAM to your team ID (Xcode > Settings > Accounts)."
        )
    if team == EXAMPLE_TEAM:
        raise SystemExit(
            "apple/Config/Local.xcconfig still has the example DEVELOPMENT_TEAM "
            f"({EXAMPLE_TEAM}). Replace it with your team ID."
        )
    return team


def export_options(team: str) -> dict:
    return {
        "method": "development",
        "teamID": team,
        "signingStyle": "automatic",
        "compileBitcode": False,
        "destination": "export",
        "signingCertificate": "Apple Development",
        "stripSwiftSymbols": True,
    }


def repo_root() -> Path:
    return Path(__file__).resolve().parents[2]


def run(cmd: list[str], **kw) -> None:
    print("+", " ".join(cmd), flush=True)
    subprocess.run(cmd, check=True, **kw)


def parse_args(argv: list[str], root: Path) -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--project", type=Path, default=root / "apple" / "Trillium.xcodeproj")
    p.add_argument("--local-xcconfig", type=Path, default=root / "apple" / "Config" / "Local.xcconfig")
    p.add_argument("--base-xcconfig", type=Path, default=root / "apple" / "Config" / "Base.xcconfig")
    p.add_argument("--archive-path", type=Path, default=root / "build" / "apple" / "Trillium.xcarchive")
    p.add_argument("--export-path", type=Path, default=root / "build" / "apple" / "ipa")
    p.add_argument("--derived-data", type=Path, default=root / "build" / "apple")
    p.add_argument("--output", type=Path, default=None)
    p.add_argument("--dry-run", action="store_true", help="Write ExportOptions and stop (no xcodebuild)")
    return p.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    root = repo_root()
    args = parse_args(sys.argv[1:] if argv is None else argv, root)

    if not args.local_xcconfig.is_file():
        raise SystemExit(
            f"missing {args.local_xcconfig}. Copy apple/Config/Local.xcconfig.example "
            "to that path and set DEVELOPMENT_TEAM. The file is git-ignored."
        )
    if not args.project.exists():
        raise SystemExit(f"missing {args.project}; run `make apple-project` first")

    local = load_xcconfig(args.local_xcconfig)
    team = development_team(local)
    version = load_xcconfig(args.base_xcconfig).get("MARKETING_VERSION", "0.0.0")
    output = args.output or (root / "dist" / "apple" / f"Trillium-iOS-dev-{version}.ipa")

    options_path = args.derived_data / "ExportOptions.plist"
    options_path.parent.mkdir(parents=True, exist_ok=True)
    with options_path.open("wb") as f:
        plistlib.dump(export_options(team), f)
    print(f"wrote {options_path} (team {team}, method development)", flush=True)

    if args.dry_run:
        return 0

    if sys.platform != "darwin":
        raise SystemExit("make apple-ios-ipa needs macOS with Xcode")

    archive = args.archive_path
    if archive.exists():
        shutil.rmtree(archive)
    if args.export_path.exists():
        shutil.rmtree(args.export_path)
    args.export_path.mkdir(parents=True, exist_ok=True)

    run(
        [
            "xcodebuild",
            "-project",
            str(args.project),
            "-scheme",
            "TrilliumIOS",
            "-configuration",
            "Release",
            "-destination",
            "generic/platform=iOS",
            "-archivePath",
            str(archive),
            "-derivedDataPath",
            str(args.derived_data),
            "-allowProvisioningUpdates",
            "archive",
        ]
    )
    run(
        [
            "xcodebuild",
            "-exportArchive",
            "-archivePath",
            str(archive),
            "-exportPath",
            str(args.export_path),
            "-exportOptionsPlist",
            str(options_path),
            "-allowProvisioningUpdates",
        ]
    )

    ipas = sorted(args.export_path.glob("*.ipa"))
    if not ipas:
        raise SystemExit(f"export succeeded but no .ipa in {args.export_path}")
    output.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(ipas[0], output)
    print(f"copied {ipas[0].name} -> {output}", flush=True)
    print(
        "Install on a device with Developer Mode enabled, registered to this team:\n"
        f"  xcrun devicectl device install app --device <udid> {output}\n"
        "Or drag the IPA onto the device in Xcode or Apple Configurator.\n"
        "This path has not been run against a physical iPad in this repository's CI.",
        flush=True,
    )
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except subprocess.CalledProcessError as e:
        raise SystemExit(e.returncode) from e
