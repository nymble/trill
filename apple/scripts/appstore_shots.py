#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Capture App Store / TestFlight screenshots from the real app.

iPhone 6.9" (1320x2868 portrait), iPad 13" (2064x2752 portrait) and Mac
(2560x1600 or 2880x1800) from a macOS CI runner or a local Mac with Xcode.

Home/connect is captured without hardware. The other four shots use
`--demo-hardware` so Settings can show battery and Bluetooth, and Sensors
can show motion and linear-sensor charts.

Usage (from the repository root, or via `make apple-appstore-shots`):

    python3 apple/scripts/appstore_shots.py --out dist/appstore-screenshots \\
        --ios-app build/.../Debug-iphonesimulator/Trillium.app \\
        --mac-app build/.../Release/Trillium.app
"""
from __future__ import annotations

import argparse
import json
import shutil
import struct
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import pick_simulator as ps

IPHONE_SIZE = (1320, 2868)
IPAD_SIZE = (2064, 2752)
MAC_SIZES = ((2880, 1800), (2560, 1600))

SHOTS = (
    ("01-home-connect", ("--skip-splash", "--tab=home")),
    ("02-settings-hardware", ("--skip-splash", "--tab=settings", "--demo-hardware")),
    ("03-sensors-motion", ("--skip-splash", "--tab=sensors", "--sensors-page=charts", "--demo-hardware")),
    ("04-settings-mapping", ("--skip-splash", "--tab=settings", "--settings=mapping", "--demo-hardware")),
    ("05-sensors-linear", ("--skip-splash", "--tab=sensors", "--sensors-page=linear", "--demo-hardware")),
)

DEFAULT_BUNDLE = "com.nymble.trill"


def run(cmd: list[str], **kw) -> subprocess.CompletedProcess:
    print("+", " ".join(cmd), flush=True)
    return subprocess.run(cmd, **kw)


def run_ok(cmd: list[str], **kw) -> subprocess.CompletedProcess:
    return run(cmd, check=True, **kw)


def simctl(*args: str, check: bool = True, **kw) -> subprocess.CompletedProcess:
    return run(["xcrun", "simctl", *args], check=check, **kw)


def png_size(path: Path) -> tuple[int, int]:
    with path.open("rb") as f:
        sig = f.read(8)
        if sig != b"\x89PNG\r\n\x1a\n":
            raise ValueError(f"{path} is not a PNG")
        f.read(4)
        if f.read(4) != b"IHDR":
            raise ValueError(f"{path} has no IHDR")
        return struct.unpack(">II", f.read(8))


def boot(udid: str) -> None:
    r = simctl("boot", udid, check=False, capture_output=True, text=True)
    if r.returncode not in (0, 149) and "already booted" not in (r.stderr or "") + (r.stdout or ""):
        sys.stderr.write(r.stdout or "")
        sys.stderr.write(r.stderr or "")
        raise SystemExit(r.returncode or 1)
    run_ok(["xcrun", "simctl", "bootstatus", udid, "-b"])
    run(["open", "-a", "Simulator", "--args", "-CurrentDeviceUDID", udid], check=False)
    time.sleep(2)
    # Dark chrome to match the Stage look of the app itself.
    simctl("ui", udid, "appearance", "dark", check=False)
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


def capture_ios(kind: str, expected: tuple[int, int], app: Path, out: Path) -> list[dict]:
    chosen = ps.pick_or_create(kind)
    if not chosen:
        raise SystemExit(f"no {kind} simulator available (need a device that renders {expected[0]}x{expected[1]})")
    udid = chosen["udid"]
    name = str(chosen.get("name", kind))
    print(f"using {name} ({udid}) for {kind}", flush=True)
    boot(udid)
    bundle = bundle_id_from_app(app)
    simctl("install", udid, str(app))
    records = []
    out.mkdir(parents=True, exist_ok=True)
    for shot_name, args in SHOTS:
        dest = out / f"{shot_name}.png"
        simctl("terminate", udid, bundle, check=False, capture_output=True)
        time.sleep(0.4)
        launch = simctl("launch", udid, bundle, *args, capture_output=True, text=True)
        print(launch.stdout or "", end="", flush=True)
        if launch.stderr:
            print(launch.stderr, end="", file=sys.stderr, flush=True)
        # Let the first frame (and demo telemetry window) settle.
        time.sleep(2.2)
        simctl("io", udid, "screenshot", str(dest))
        w, h = png_size(dest)
        print(f"{dest} {w}x{h}", flush=True)
        if (w, h) != expected:
            raise SystemExit(
                f"{dest} is {w}x{h}, expected {expected[0]}x{expected[1]} "
                f"from {name}. Pick or create the matching simulator."
            )
        records.append({"file": str(dest), "name": shot_name, "platform": kind, "device": name, "width": w, "height": h})
    simctl("terminate", udid, bundle, check=False, capture_output=True)
    return records


def swift_eval(source: str) -> str:
    import tempfile
    with tempfile.NamedTemporaryFile("w", suffix=".swift", delete=False) as f:
        f.write(source)
        path = f.name
    try:
        r = run_ok(["swift", path], capture_output=True, text=True)
        return r.stdout.strip()
    finally:
        Path(path).unlink(missing_ok=True)


def mac_scale() -> float:
    try:
        out = swift_eval("import AppKit; print(NSScreen.main?.backingScaleFactor ?? 1)")
        return float(out)
    except (subprocess.CalledProcessError, ValueError):
        return 2.0


def mac_window_ids(app_name: str = "Trillium") -> list[int]:
    source = f'''
import CoreGraphics
let want = "{app_name}"
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
var ids: [Int] = []
for w in list {{
    let owner = w[kCGWindowOwnerName as String] as? String ?? ""
    let layer = w[kCGWindowLayer as String] as? Int ?? -1
    let bounds = w[kCGWindowBounds as String] as? [String: Any]
    let height = (bounds?["Height"] as? Double) ?? 0
    if owner == want, layer == 0, height > 80, let num = w[kCGWindowNumber as String] as? Int {{
        ids.append(num)
    }}
}}
print(ids.map(String.init).joined(separator: " "))
'''
    out = swift_eval(source)
    return [int(x) for x in out.split() if x.isdigit()]


def launch_mac(binary: Path, args: tuple[str, ...], point_size: tuple[int, int]) -> subprocess.Popen:
    cmd = [str(binary), *args, f"--window-size={point_size[0]}x{point_size[1]}"]
    print("+", " ".join(cmd), flush=True)
    return subprocess.Popen(cmd, start_new_session=True)


def capture_mac(app: Path, out: Path) -> list[dict]:
    binary = app / "Contents" / "MacOS" / "Trillium"
    if not binary.is_file():
        # Some builds may use a different executable name.
        exe = list((app / "Contents" / "MacOS").glob("*"))
        if not exe:
            raise SystemExit(f"no macOS executable in {app}")
        binary = exe[0]
    scale = mac_scale()
    print(f"mac display scale {scale}", flush=True)
    # Prefer 2880x1800 if the scaled window will fit; otherwise 2560x1600.
    visible = (4096, 2160)
    try:
        vis = swift_eval(
            "import AppKit; let f = NSScreen.main?.visibleFrame ?? .zero; print(\"\\(Int(f.width)) \\(Int(f.height))\")"
        )
        parts = [int(x) for x in vis.split()]
        if len(parts) == 2:
            visible = (parts[0], parts[1])
            print(f"mac visible frame {visible[0]}x{visible[1]} points", flush=True)
    except (subprocess.CalledProcessError, ValueError):
        pass

    pixel_target = None
    point_size = None
    for pw, ph in MAC_SIZES:
        pt = (int(round(pw / scale)), int(round(ph / scale)))
        if pt[0] <= visible[0] and pt[1] <= visible[1]:
            pixel_target = (pw, ph)
            point_size = pt
            break
    if pixel_target is None or point_size is None:
        # Last resort: use 2560x1600 points if the display is 1x and large enough,
        # or accept whatever 2560x1600 pixels would require.
        pixel_target = MAC_SIZES[1]
        point_size = (int(round(pixel_target[0] / max(scale, 1))), int(round(pixel_target[1] / max(scale, 1))))
        print(f"warning: visible frame may be tight for {pixel_target}; trying window {point_size} pt", flush=True)

    print(f"mac target {pixel_target[0]}x{pixel_target[1]} pixels, window {point_size[0]}x{point_size[1]} pt", flush=True)
    out.mkdir(parents=True, exist_ok=True)
    records = []
    for shot_name, args in SHOTS:
        dest = out / f"{shot_name}.png"
        proc = launch_mac(binary, args, point_size)
        try:
            deadline = time.time() + 20
            ids: list[int] = []
            while time.time() < deadline:
                if proc.poll() is not None:
                    raise SystemExit(f"Trillium exited early with code {proc.returncode}")
                ids = mac_window_ids("Trillium")
                if ids:
                    break
                time.sleep(0.4)
            if not ids:
                raise SystemExit("could not find a Trillium window to screenshot")
            time.sleep(1.6)
            # Recapture window id in case the first was a splash/transient.
            ids = mac_window_ids("Trillium") or ids
            run_ok(["screencapture", "-x", "-o", "-l", str(ids[0]), str(dest)])
            w, h = png_size(dest)
            print(f"{dest} {w}x{h} (window {ids[0]})", flush=True)
            if (w, h) != pixel_target:
                # Title bar / frame may add pixels; try once more by shrinking content.
                raise SystemExit(
                    f"{dest} is {w}x{h}, expected {pixel_target[0]}x{pixel_target[1]}. "
                    "The Mac display scale or window chrome did not match."
                )
            records.append({
                "file": str(dest),
                "name": shot_name,
                "platform": "mac",
                "device": "macOS window",
                "width": w,
                "height": h,
            })
        finally:
            if proc.poll() is None:
                proc.terminate()
                try:
                    proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    proc.kill()
            time.sleep(0.3)
    return records


def write_manifest(out: Path, records: list[dict]) -> None:
    manifest = out / "manifest.json"
    manifest.write_text(json.dumps({"shots": records}, indent=2) + "\n")
    print(f"wrote {manifest}", flush=True)


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--out", type=Path, required=True, help="Output directory (platform subfolders are created)")
    p.add_argument("--ios-app", type=Path, help="Built Trillium.app for the iOS Simulator")
    p.add_argument("--mac-app", type=Path, help="Built Trillium.app for macOS")
    p.add_argument("--skip-ios", action="store_true")
    p.add_argument("--skip-mac", action="store_true")
    args = p.parse_args()
    out = args.out
    out.mkdir(parents=True, exist_ok=True)
    records: list[dict] = []
    if not args.skip_ios:
        if not args.ios_app or not args.ios_app.is_dir():
            raise SystemExit("--ios-app is required unless --skip-ios")
        records += capture_ios("iphone-69", IPHONE_SIZE, args.ios_app, out / "iphone-6.9")
        records += capture_ios("ipad-13", IPAD_SIZE, args.ios_app, out / "ipad-13")
    if not args.skip_mac:
        if not args.mac_app or not args.mac_app.is_dir():
            raise SystemExit("--mac-app is required unless --skip-mac")
        records += capture_mac(args.mac_app, out / "mac")
    write_manifest(out, records)
    print("all App Store screenshots:", ", ".join(r["name"] + f" {r['width']}x{r['height']}" for r in records), flush=True)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        raise SystemExit(130)
