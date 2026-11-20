#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Capture App Store / TestFlight screenshots from the real app.

iPhone 6.9" (1320x2868) and the required App Store Connect iPhone tab sizes
(1206x2622 or 1179x2556), iPad 13" (2064x2752) and Mac (2880x1800) from a
macOS CI runner or a local Mac with Xcode.

Home/connect is captured without hardware. The other four shots use
`--demo-hardware` so Settings can show battery and Bluetooth, and Sensors
can show motion and linear-sensor charts.

Each PNG is flattened to opaque sRGB RGB. Near-black frames are rejected
and the shot is retried with a longer settle wait.

Usage (from the repository root, or via `make apple-appstore-shots`):

    python3 apple/scripts/appstore_shots.py --out dist/appstore-screenshots \\
        --ios-app build/.../Debug-iphonesimulator/Trillium.app \\
        --mac-app build/.../Release/Trillium.app
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import pick_simulator as ps
import pngutil

IPHONE_69_SIZES = ((1320, 2868), (1290, 2796), (1260, 2736))
IPHONE_63_SIZES = ((1206, 2622), (1179, 2556))
IPAD_SIZES = ((2064, 2752), (2048, 2732))
MAC_PREFERRED = (2880, 1800)
MAC_ACCEPTED = ((2880, 1800), (2560, 1600), (1440, 900), (1280, 800))
# Point size for a 16:10 Retina window; the app renders this offscreen at @2x.
MAC_POINT_SIZE = (1440, 900)

SHOTS = (
    ("01-home-connect", ("--skip-splash", "--tab=home")),
    ("02-settings-hardware", ("--skip-splash", "--tab=settings", "--demo-hardware")),
    ("03-sensors-motion", ("--skip-splash", "--tab=sensors", "--sensors-page=charts", "--demo-hardware")),
    ("04-settings-mapping", ("--skip-splash", "--tab=settings", "--settings=mapping", "--demo-hardware")),
    ("05-sensors-linear", ("--skip-splash", "--tab=sensors", "--sensors-page=linear", "--demo-hardware")),
)

# Seconds to wait after launch before capturing. Each failed (blank) attempt
# moves to the next, longer settle.
SETTLE_SECONDS = (3.0, 5.0, 8.0)

DEFAULT_BUNDLE = "net.nymbus.trillium"


# Upper bound for a single simctl/helper call. A hung `simctl terminate` once
# stalled the CI job for most of an hour.
CMD_TIMEOUT = 180


def run(cmd: list[str], **kw) -> subprocess.CompletedProcess:
    print("+", " ".join(cmd), flush=True)
    kw.setdefault("timeout", CMD_TIMEOUT)
    check = kw.pop("check", False)
    try:
        r = subprocess.run(cmd, **kw)
    except subprocess.TimeoutExpired:
        print(f"timed out after {kw['timeout']}s: {' '.join(cmd)}", file=sys.stderr, flush=True)
        r = subprocess.CompletedProcess(cmd, 124, "" if kw.get("text") else b"", "timeout")
    if check and r.returncode != 0:
        raise subprocess.CalledProcessError(r.returncode, cmd)
    return r


def run_ok(cmd: list[str], **kw) -> subprocess.CompletedProcess:
    return run(cmd, check=True, **kw)


def simctl(*args: str, check: bool = True, **kw) -> subprocess.CompletedProcess:
    return run(["xcrun", "simctl", *args], check=check, **kw)


def png_size(path: Path) -> tuple[int, int]:
    w, h, _ = pngutil.png_ihdr(path)
    return w, h


def apply_status_bar(udid: str) -> None:
    """Clean 9:41 status bar: full signal, charged battery, no iPad weekday/date."""
    simctl("status_bar", udid, "clear", check=False, capture_output=True)
    r = simctl(
        "status_bar",
        udid,
        "override",
        "--time",
        "9:41",
        "--batteryState",
        "charged",
        "--batteryLevel",
        "100",
        "--wifiMode",
        "active",
        "--wifiBars",
        "3",
        "--cellularMode",
        "active",
        "--cellularBars",
        "4",
        "--dataNetwork",
        "wifi",
        check=False,
        capture_output=True,
        text=True,
    )
    if r.returncode != 0:
        err = ((r.stderr or "") + (r.stdout or "")).strip()
        print(f"status_bar override warning ({r.returncode}): {err}", file=sys.stderr, flush=True)
    # Hide the date/weekday that iPad shows next to the time. SpringBoard
    # may need a restart for this to take (see boot()).
    simctl(
        "spawn",
        udid,
        "defaults",
        "write",
        "com.apple.UIKit",
        "StatusBarHidesDate",
        "-bool",
        "YES",
        check=False,
        capture_output=True,
    )


def boot(udid: str, respring_for_date: bool = False) -> None:
    r = simctl("boot", udid, check=False, capture_output=True, text=True)
    if r.returncode not in (0, 149) and "already booted" not in (r.stderr or "") + (r.stdout or ""):
        sys.stderr.write(r.stdout or "")
        sys.stderr.write(r.stderr or "")
        raise SystemExit(r.returncode or 1)
    run_ok(["xcrun", "simctl", "bootstatus", udid, "-b"], timeout=1800)
    run(["open", "-a", "Simulator", "--args", "-CurrentDeviceUDID", udid], check=False)
    time.sleep(2)
    # Dark chrome to match the Stage look of the app itself.
    simctl("ui", udid, "appearance", "dark", check=False)
    apply_status_bar(udid)
    if respring_for_date:
        print("respringing SpringBoard so StatusBarHidesDate takes effect", flush=True)
        simctl("spawn", udid, "killall", "SpringBoard", check=False, capture_output=True)
        time.sleep(4)
        run_ok(["xcrun", "simctl", "bootstatus", udid, "-b"], timeout=1800)
        apply_status_bar(udid)
        time.sleep(1)


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


def finish_shot(dest: Path, accepted: tuple[tuple[int, int], ...], *, mac: bool) -> str | None:
    """Flatten to opaque RGB and return a reject reason, or None if the shot is good."""
    if not dest.is_file() or dest.stat().st_size < 1000:
        return "missing or tiny PNG"
    w, h = png_size(dest)
    wanted = " or ".join(f"{a}x{b}" for a, b in accepted)
    if (w, h) not in accepted:
        return f"{w}x{h}, expected {wanted}"
    pngutil.flatten_to_rgb(dest)
    w, h = png_size(dest)
    stats = pngutil.luma_stats(dest)
    print(f"{dest} {pngutil.format_stats(stats)}", flush=True)
    if (w, h) not in accepted:
        return f"after flatten {w}x{h}, expected {wanted}"
    return pngutil.reject_reason(stats, mac=mac)


def capture_ios(kind: str, accepted: tuple[tuple[int, int], ...], app: Path, out: Path) -> list[dict]:
    wanted = " or ".join(f"{w}x{h}" for w, h in accepted)
    chosen = ps.pick_or_create(kind)
    if not chosen:
        raise SystemExit(f"no {kind} simulator available (need a device that renders {wanted})")
    udid = chosen["udid"]
    name = str(chosen.get("name", kind))
    print(f"using {name} ({udid}) for {kind}", flush=True)
    boot(udid, respring_for_date=kind.startswith("ipad"))
    bundle = bundle_id_from_app(app)
    simctl("install", udid, str(app))
    # First launch after a fresh boot (and iPad data migration) needs extra settle.
    time.sleep(2)
    records = []
    failed: list[str] = []
    out.mkdir(parents=True, exist_ok=True)
    for shot_name, args in SHOTS:
        dest = out / f"{shot_name}.png"
        last_reason = "not captured"
        for attempt, settle in enumerate(SETTLE_SECONDS, start=1):
            if dest.exists():
                dest.unlink()
            simctl("terminate", udid, bundle, check=False, capture_output=True)
            time.sleep(0.6)
            launch = simctl("launch", udid, bundle, *args, check=False, capture_output=True, text=True)
            print(launch.stdout or "", end="", flush=True)
            if launch.stderr:
                print(launch.stderr, end="", file=sys.stderr, flush=True)
            if launch.returncode != 0:
                last_reason = f"launch failed ({launch.returncode})"
                print(f"{dest} attempt {attempt}: {last_reason}, retrying", flush=True)
                time.sleep(1)
                continue
            print(f"{dest} attempt {attempt}: settling {settle:.1f}s", flush=True)
            time.sleep(settle)
            apply_status_bar(udid)
            time.sleep(0.3)
            shot = simctl("io", udid, "screenshot", str(dest), check=False, capture_output=True, text=True)
            if shot.returncode != 0:
                last_reason = f"simctl io screenshot failed ({shot.returncode}): {(shot.stderr or shot.stdout or '').strip()}"
                print(f"{dest} attempt {attempt}: {last_reason}, retrying", flush=True)
                continue
            reason = finish_shot(dest, accepted, mac=False)
            if reason is None:
                w, h = png_size(dest)
                records.append({
                    "file": str(dest),
                    "name": shot_name,
                    "platform": kind,
                    "device": name,
                    "width": w,
                    "height": h,
                })
                break
            last_reason = reason
            print(f"{dest} attempt {attempt}: {reason}; retrying", flush=True)
        else:
            # Keep going so one bad shot does not lose the rest of the set.
            failed.append(f"{dest}: {last_reason}")
            print(f"{dest} still unusable after {len(SETTLE_SECONDS)} attempts: {last_reason}", flush=True)
    simctl("terminate", udid, bundle, check=False, capture_output=True)
    if failed:
        raise SystemExit(f"{len(failed)} unusable shot(s) from {name}: " + "; ".join(failed))
    return records


def capture_mac(app: Path, out: Path) -> list[dict]:
    binary = app / "Contents" / "MacOS" / "Trillium"
    if not binary.is_file():
        exe = list((app / "Contents" / "MacOS").glob("*"))
        if not exe:
            raise SystemExit(f"no macOS executable in {app}")
        binary = exe[0]
    print(
        f"mac offscreen target {MAC_PREFERRED[0]}x{MAC_PREFERRED[1]} pixels "
        f"from {MAC_POINT_SIZE[0]}x{MAC_POINT_SIZE[1]} pt @2x",
        flush=True,
    )
    out.mkdir(parents=True, exist_ok=True)
    records = []
    failed: list[str] = []
    for shot_name, args in SHOTS:
        dest = out / f"{shot_name}.png"
        last_reason = "not captured"
        for attempt, settle in enumerate(SETTLE_SECONDS, start=1):
            if dest.exists():
                dest.unlink()
            cmd = [
                str(binary),
                *args,
                f"--window-size={MAC_POINT_SIZE[0]}x{MAC_POINT_SIZE[1]}",
                f"--screenshot-out={dest}",
                f"--screenshot-delay={settle}",
            ]
            print("+", " ".join(cmd), flush=True)
            proc = subprocess.Popen(cmd, start_new_session=True)
            try:
                deadline = time.time() + 45
                while time.time() < deadline:
                    if dest.is_file() and dest.stat().st_size > 1000:
                        time.sleep(0.3)
                        break
                    if proc.poll() is not None and not dest.is_file():
                        last_reason = f"Trillium exited with code {proc.returncode} without writing {dest}"
                        break
                    time.sleep(0.2)
                else:
                    last_reason = f"timed out waiting for {dest}"
            finally:
                if proc.poll() is None:
                    proc.terminate()
                    try:
                        proc.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        proc.kill()
                time.sleep(0.3)
            if not dest.is_file():
                print(f"{dest} attempt {attempt}: {last_reason}; retrying", flush=True)
                continue
            reason = finish_shot(dest, MAC_ACCEPTED, mac=True)
            if reason is None:
                w, h = png_size(dest)
                records.append({
                    "file": str(dest),
                    "name": shot_name,
                    "platform": "mac",
                    "device": "macOS window",
                    "width": w,
                    "height": h,
                })
                break
            last_reason = reason
            print(f"{dest} attempt {attempt}: {reason}; retrying", flush=True)
        else:
            failed.append(f"{dest}: {last_reason}")
            print(f"{dest} still unusable after {len(SETTLE_SECONDS)} attempts: {last_reason}", flush=True)
    if failed:
        raise SystemExit(f"{len(failed)} unusable Mac shot(s): " + "; ".join(failed))
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
    errors: list[str] = []

    def try_capture(label: str, fn) -> None:
        try:
            records.extend(fn())
        except (Exception, SystemExit) as e:
            errors.append(f"{label}: {e}")
            print(f"ERROR {label}: {e}", file=sys.stderr, flush=True)

    # Mac first (no simulator), then the required iPhone 6.3" and iPad 13"
    # sets, then the optional iPhone 6.9" set.
    if not args.skip_mac:
        if not args.mac_app or not args.mac_app.is_dir():
            raise SystemExit("--mac-app is required unless --skip-mac")
        try_capture("mac", lambda: capture_mac(args.mac_app, out / "mac"))
        write_manifest(out, records)
    if not args.skip_ios:
        if not args.ios_app or not args.ios_app.is_dir():
            raise SystemExit("--ios-app is required unless --skip-ios")
        for label, kind, sizes in (
            ("iphone-6.3", "iphone-63", IPHONE_63_SIZES),
            ("ipad-13", "ipad-13", IPAD_SIZES),
            ("iphone-6.9", "iphone-69", IPHONE_69_SIZES),
        ):
            try_capture(label, lambda k=kind, s=sizes, l=label: capture_ios(k, s, args.ios_app, out / l))
            write_manifest(out, records)
    write_manifest(out, records)
    print("all App Store screenshots:", ", ".join(r["name"] + f" {r['width']}x{r['height']}" for r in records), flush=True)
    if errors:
        print("failed platforms:\n" + "\n".join(errors), file=sys.stderr, flush=True)
        return 1
    expected = 0 if args.skip_ios else 15
    if not args.skip_mac:
        expected += 5
    if len(records) != expected:
        print(f"expected {expected} shots, got {len(records)}", file=sys.stderr, flush=True)
        return 1
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        raise SystemExit(130)
