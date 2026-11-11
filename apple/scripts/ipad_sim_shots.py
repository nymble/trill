#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Boot an iPad Simulator, install Trillium, and capture screenshots.

Primary path: an XCUITest (`apple/UITests/SimulatorScreenshots.swift`) that
rotates the device and writes named PNGs into the test runner's Documents
folder. Those files are copied to the output directory.

Fallback: install and launch with `simctl`, take `simctl io screenshot`
portraits of each tab (via --skip-splash --tab=...), and try to rotate with
osascript for landscape. The Simulator has no USB MIDI device, so Home shows
the disconnected / plug-in prompt.

Usage (from the repository root, or via `make apple-ipad-sim`):

    python3 apple/scripts/ipad_sim_shots.py --out dist/ipad-screenshots
"""
from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
import time
from pathlib import Path

# Same directory as this script (not necessarily on sys.path when invoked as a file).
sys.path.insert(0, str(Path(__file__).resolve().parent))
import pick_simulator as ps

TABS = ("home", "presets", "sensors", "settings")
ORIENTATIONS = ("portrait", "landscape")
EXPECTED = [f"{tab}-{orient}.png" for tab in TABS for orient in ORIENTATIONS]
DEFAULT_BUNDLE = "com.nymble.trill"
RUNNER_BUNDLES = (
    "com.nymble.trill.uitests.xctrunner",
    "com.nymble.trill.uitests",
)


def repo_root() -> Path:
    return Path(__file__).resolve().parents[2]


def run(cmd: list[str], **kw) -> subprocess.CompletedProcess:
    print("+", " ".join(cmd), flush=True)
    return subprocess.run(cmd, **kw)


def run_ok(cmd: list[str], **kw) -> subprocess.CompletedProcess:
    return run(cmd, check=True, **kw)


def simctl(*args: str, check: bool = True, **kw) -> subprocess.CompletedProcess:
    return run(["xcrun", "simctl", *args], check=check, **kw)


def boot(udid: str) -> None:
    r = simctl("boot", udid, check=False, capture_output=True, text=True)
    # 0 = booted now; 149 / "already booted" is also fine.
    if r.returncode not in (0, 149) and "already booted" not in (r.stderr or "") + (r.stdout or ""):
        if r.stdout:
            print(r.stdout, end="", flush=True)
        if r.stderr:
            print(r.stderr, end="", file=sys.stderr, flush=True)
        raise SystemExit(r.returncode or 1)
    run_ok(["xcrun", "simctl", "bootstatus", udid, "-b"])
    # Open Simulator.app so the display is actually composited for screenshots.
    run(["open", "-a", "Simulator", "--args", "-CurrentDeviceUDID", udid], check=False)
    time.sleep(2)
    simctl("ui", udid, "appearance", "light", check=False)
    simctl(
        "status_bar",
        udid,
        "override",
        "--time",
        "9:41",
        "--batteryState",
        "charged",
        "--batteryLevel",
        "100",
        "--wifiBars",
        "3",
        "--cellularMode",
        "active",
        "--cellularBars",
        "4",
        check=False,
    )


def bundle_id_from_app(app: Path) -> str:
    r = run(
        ["defaults", "read", str(app / "Info"), "CFBundleIdentifier"],
        check=False,
        capture_output=True,
        text=True,
    )
    if r.returncode == 0 and r.stdout.strip():
        return r.stdout.strip()
    return DEFAULT_BUNDLE


def expected_paths(out: Path) -> list[Path]:
    return [out / name for name in EXPECTED]


def missing_shots(out: Path) -> list[str]:
    return [p.name for p in expected_paths(out) if not p.is_file() or p.stat().st_size < 100]


def copy_named_pngs(src: Path, dest: Path) -> int:
    dest.mkdir(parents=True, exist_ok=True)
    copied = 0
    if not src.exists():
        return 0
    for png in src.rglob("*.png"):
        if png.name in EXPECTED:
            shutil.copy2(png, dest / png.name)
            copied += 1
            print(f"copied {png} -> {dest / png.name}", flush=True)
    return copied


def runner_documents(udid: str) -> list[Path]:
    found: list[Path] = []
    for bundle in RUNNER_BUNDLES:
        r = simctl("get_app_container", udid, bundle, "data", check=False, capture_output=True, text=True)
        if r.returncode == 0 and r.stdout.strip():
            found.append(Path(r.stdout.strip()) / "Documents" / "ipad-shots")
    # Also scan listapps if the bundle id differs (custom TRILL_BUNDLE_ID).
    listed = simctl("listapps", udid, check=False, capture_output=True, text=True)
    if listed.returncode == 0 and listed.stdout:
        try:
            apps = json.loads(listed.stdout)
        except json.JSONDecodeError:
            apps = {}
        for bid, info in apps.items() if isinstance(apps, dict) else []:
            if "uitest" in bid.lower() or "xctrunner" in bid.lower():
                r = simctl("get_app_container", udid, bid, "data", check=False, capture_output=True, text=True)
                if r.returncode == 0 and r.stdout.strip():
                    path = Path(r.stdout.strip()) / "Documents" / "ipad-shots"
                    if path not in found:
                        found.append(path)
    return found


def run_ui_tests(udid: str, project: Path, derived: Path) -> int:
    cmd = [
        "xcodebuild",
        "test",
        "-project",
        str(project),
        "-scheme",
        "TrilliumIOS",
        "-destination",
        f"id={udid}",
        "-only-testing:TrilliumIOSUITests/SimulatorScreenshots",
        "-derivedDataPath",
        str(derived),
        "CODE_SIGNING_ALLOWED=NO",
        "-resultBundlePath",
        str(derived / "ipad-shots.xcresult"),
    ]
    result = run(cmd, check=False)
    return result.returncode


def harvest_from_runners(udid: str, out: Path) -> None:
    for docs in runner_documents(udid):
        copy_named_pngs(docs, out)


def harvest_from_xcresult(xcresult: Path, out: Path) -> None:
    if not xcresult.exists():
        return
    copy_named_pngs(xcresult, out)


def rotate_with_osascript(orientation: str) -> bool:
    names = {
        "portrait": ["Portrait"],
        "landscape": ["Landscape Left", "LandscapeLeft"],
    }[orientation]
    for name in names:
        script = f'''
tell application "Simulator" to activate
delay 0.3
tell application "System Events"
    tell process "Simulator"
        set frontmost to true
        try
            click menu item "{name}" of menu "Orientation" of menu item "Orientation" of menu "Device" of menu bar 1
            return "ok"
        end try
        try
            click menu item "{name}" of menu "I/O" of menu bar 1
            return "ok"
        end try
    end tell
end tell
return "no"
'''
        r = run(["osascript", "-e", script], check=False, capture_output=True, text=True)
        if "ok" in (r.stdout or ""):
            time.sleep(1.5)
            return True
    # Cmd+Left rotates; used when the Orientation submenu is missing.
    if orientation == "landscape":
        key = '''
tell application "Simulator" to activate
delay 0.3
tell application "System Events"
    key code 123 using command down
end tell
'''
        r = run(["osascript", "-e", key], check=False, capture_output=True, text=True)
        if r.returncode == 0:
            time.sleep(1.5)
            return True
    return False


def simctl_fallback(udid: str, app: Path, bundle: str, out: Path) -> None:
    print("simctl fallback: install, launch each tab, screenshot", flush=True)
    simctl("install", udid, str(app))
    for tab in TABS:
        simctl("terminate", udid, bundle, check=False)
        time.sleep(0.5)
        simctl("launch", udid, bundle, "--skip-splash", f"--tab={tab}")
        time.sleep(2.5)
        dest = out / f"{tab}-portrait.png"
        if dest.exists() and dest.stat().st_size >= 100:
            print(f"keep existing {dest.name}", flush=True)
        else:
            simctl("io", udid, "screenshot", str(dest))
            print(f"wrote {dest}", flush=True)
        land = out / f"{tab}-landscape.png"
        if land.exists() and land.stat().st_size >= 100:
            continue
        if rotate_with_osascript("landscape"):
            simctl("io", udid, "screenshot", str(land))
            print(f"wrote {land}", flush=True)
            rotate_with_osascript("portrait")
        else:
            print(f"could not rotate for {land.name}", file=sys.stderr, flush=True)


def parse_args(argv: list[str], root: Path) -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--out", type=Path, required=True, help="Directory for named PNG screenshots")
    p.add_argument("--project", type=Path, default=root / "apple" / "Trillium.xcodeproj")
    p.add_argument("--derived-data", type=Path, default=root / "build" / "apple")
    p.add_argument(
        "--app",
        type=Path,
        default=root / "build" / "apple" / "Build" / "Products" / "Debug-iphonesimulator" / "Trillium.app",
    )
    p.add_argument("--bundle-id", default=None)
    p.add_argument("--udid", default=None, help="Use this iPad simulator instead of picking one")
    p.add_argument("--skip-ui-tests", action="store_true", help="Only use the simctl fallback path")
    return p.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    if sys.platform != "darwin":
        raise SystemExit("apple-ipad-sim needs macOS with Xcode and the iOS Simulator")
    root = repo_root()
    args = parse_args(sys.argv[1:] if argv is None else argv, root)
    out = args.out
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True, exist_ok=True)

    if args.udid:
        udid = args.udid
    else:
        chosen = ps.pick(ps.list_available(), "ipad")
        if not chosen:
            raise SystemExit("no available iPad simulator")
        udid = chosen["udid"]
        print(f"using iPad simulator {chosen.get('name', '')} ({udid})", flush=True)

    boot(udid)

    ui_status = None
    if not args.skip_ui_tests:
        if not args.project.exists():
            raise SystemExit(f"missing {args.project}; run `make apple-project` first")
        xcresult = args.derived_data / "ipad-shots.xcresult"
        if xcresult.exists():
            shutil.rmtree(xcresult)
        ui_status = run_ui_tests(udid, args.project, args.derived_data)
        harvest_from_runners(udid, out)
        harvest_from_xcresult(xcresult, out)
        if ui_status != 0:
            print(f"warning: xcodebuild test exited {ui_status}", file=sys.stderr, flush=True)

    still = missing_shots(out)
    if still:
        if not args.app.exists():
            raise SystemExit(
                f"missing {args.app}; run `make apple-ios-sim` first "
                f"(still missing screenshots: {', '.join(still)})"
            )
        bundle = args.bundle_id or bundle_id_from_app(args.app)
        simctl_fallback(udid, args.app, bundle, out)

    still = missing_shots(out)
    print("Note: the iOS Simulator has no USB MIDI device, so Home shows the plug-in prompt.", flush=True)
    if still:
        print("captured:", ", ".join(p.name for p in out.glob("*.png") if p.stat().st_size >= 100) or "(none)", flush=True)
        raise SystemExit("missing screenshots: " + ", ".join(still))
    print("all screenshots:", ", ".join(EXPECTED), flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
