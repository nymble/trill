#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Print the UDID of an available iPhone or iPad simulator (newest iOS runtime first).

Usage:
  pick_simulator.py           # iPhone (default)
  pick_simulator.py iphone
  pick_simulator.py ipad
  pick_simulator.py iphone-69 # 6.9" (1320x2868), e.g. iPhone 16/17 Pro Max
  pick_simulator.py iphone-63 # 6.3"/6.1" (1206x2622 or 1179x2556), e.g. iPhone 16/17 Pro
  pick_simulator.py ipad-13   # 13" App Store size (2064x2752), e.g. iPad Pro 13-inch

Used by `make apple-test-ios-sim`, `make apple-test-ipad-sim`,
`make apple-ipad-sim` and `make apple-appstore-shots`. Read-only: it only
lists simulators.
"""
from __future__ import annotations

import json
import re
import subprocess
import sys
from typing import Any


# Preferred names, newest first. 15 Pro Max is 6.7" (1290x2796) and must not match.
IPHONE_69_NAMES = (
    "iPhone 17 Pro Max",
    "iPhone 16 Pro Max",
    "iPhone 17 Plus",
    "iPhone 16 Plus",
)

# Medium Dynamic Island iPhone (App Store Connect's required iPhone tab).
# "iPhone 17 Pro" must not also match "iPhone 17 Pro Max".
IPHONE_63_NAMES = (
    "iPhone 17 Pro",
    "iPhone 16 Pro",
    "iPhone 15 Pro",
    "iPhone 17",
    "iPhone 16",
    "iPhone 15",
)

IPAD_13_NAMES = (
    "iPad Pro 13-inch",
    "iPad Pro (13-inch)",
)


def runtime_version(runtime: str) -> tuple[int, ...]:
    tail = runtime.rsplit("iOS-", 1)[-1]
    return tuple(int(p) for p in tail.split("-") if p.isdigit())


def ipad_rank(name: str) -> int:
    """Prefer a larger iPad on the newest runtime for layout screenshots."""
    n = name.lower()
    if "ipad pro" in n:
        return 0
    if n.startswith("ipad ("):
        return 1
    if "ipad air" in n:
        return 2
    if "ipad mini" in n:
        return 3
    return 4


def available_on_runtime(devices: dict[str, list[dict[str, Any]]], runtime: str, prefix: str) -> list[dict[str, Any]]:
    return [
        d
        for d in devices.get(runtime, [])
        if d.get("isAvailable") and str(d.get("name", "")).startswith(prefix)
    ]


def _runtimes(devices: dict[str, list[dict[str, Any]]]) -> list[str]:
    return sorted((r for r in devices if ".iOS-" in r), key=runtime_version, reverse=True)


def pick(devices: dict[str, list[dict[str, Any]]], kind: str) -> dict[str, Any] | None:
    """Return the chosen device dict (with at least udid and name), or None."""
    kind = kind.lower()
    if kind not in ("iphone", "ipad", "iphone-69", "iphone-63", "ipad-13"):
        raise ValueError(f"kind must be iphone, ipad, iphone-69, iphone-63 or ipad-13, not {kind!r}")
    if kind == "iphone-69":
        return pick_named(devices, IPHONE_69_NAMES, "iPhone")
    if kind == "iphone-63":
        return pick_named(devices, IPHONE_63_NAMES, "iPhone")
    if kind == "ipad-13":
        return pick_named(devices, IPAD_13_NAMES, "iPad")
    prefix = "iPad" if kind == "ipad" else "iPhone"
    for runtime in _runtimes(devices):
        found = available_on_runtime(devices, runtime, prefix)
        if not found:
            continue
        if kind == "ipad":
            found = sorted(found, key=lambda d: (ipad_rank(str(d.get("name", ""))), str(d.get("name", ""))))
        return found[0]
    return None


def name_matches(name: str, want: str) -> bool:
    """Substring match that does not let 'iPhone 17 Pro' hit 'iPhone 17 Pro Max'."""
    n, w = name.lower(), want.lower()
    if w not in n:
        return False
    if "pro" in w and "max" not in w and "max" in n:
        return False
    return True


def pick_named(
    devices: dict[str, list[dict[str, Any]]],
    preferred_names: tuple[str, ...],
    prefix: str,
) -> dict[str, Any] | None:
    """Newest runtime, first preferred name that is available (substring match)."""
    for runtime in _runtimes(devices):
        found = available_on_runtime(devices, runtime, prefix)
        for want in preferred_names:
            want_l = want.lower()
            for d in found:
                name = str(d.get("name", ""))
                if name_matches(name, want):
                    return d
    return None


def list_available() -> dict[str, list[dict[str, Any]]]:
    out = subprocess.run(
        ["xcrun", "simctl", "list", "devices", "available", "-j"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    return json.loads(out)["devices"]


def list_runtimes() -> list[dict[str, Any]]:
    out = subprocess.run(
        ["xcrun", "simctl", "list", "runtimes", "-j"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    return json.loads(out).get("runtimes", [])


def list_devicetypes() -> list[dict[str, Any]]:
    out = subprocess.run(
        ["xcrun", "simctl", "list", "devicetypes", "-j"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    return json.loads(out).get("devicetypes", [])


def try_create(kind: str) -> dict[str, Any] | None:
    """Create a preferred simulator if the device type and a usable runtime exist."""
    names = (
        IPHONE_69_NAMES if kind == "iphone-69"
        else IPHONE_63_NAMES if kind == "iphone-63"
        else IPAD_13_NAMES if kind == "ipad-13"
        else ()
    )
    types = list_devicetypes()
    runtimes = [r for r in list_runtimes() if r.get("isAvailable") and "iOS" in str(r.get("name", ""))]
    if not runtimes:
        return None
    runtimes.sort(key=lambda r: tuple(int(p) for p in re.findall(r"\d+", str(r.get("version", "")))), reverse=True)
    runtime = runtimes[0]
    for want in names:
        dt = next((t for t in types if name_matches(str(t.get("name", "")), want)), None)
        if not dt:
            continue
        ident = f"App Store {dt['name']}"
        created = subprocess.run(
            ["xcrun", "simctl", "create", ident, dt["identifier"], runtime["identifier"]],
            capture_output=True,
            text=True,
        )
        if created.returncode != 0:
            print(created.stderr, file=sys.stderr, flush=True)
            continue
        udid = created.stdout.strip()
        print(f"created simulator {ident} ({udid}) on {runtime.get('name')}", flush=True)
        return {"udid": udid, "name": ident}
    return None


def pick_or_create(kind: str) -> dict[str, Any] | None:
    chosen = pick(list_available(), kind)
    if chosen:
        return chosen
    if kind in ("iphone-69", "iphone-63", "ipad-13"):
        return try_create(kind)
    return None


def main(argv: list[str] | None = None) -> int:
    args = list(sys.argv[1:] if argv is None else argv)
    kind = "iphone"
    if args:
        if args[0] in ("-h", "--help"):
            print(__doc__.strip(), file=sys.stderr)
            return 0
        kind = args[0].lower()
        if kind not in ("iphone", "ipad", "iphone-69", "iphone-63", "ipad-13") or len(args) != 1:
            print("usage: pick_simulator.py [iphone|ipad|iphone-69|iphone-63|ipad-13]", file=sys.stderr)
            return 2
    chosen = pick_or_create(kind)
    if not chosen:
        print(f"no available {kind} simulator", file=sys.stderr)
        return 1
    print(chosen["udid"])
    return 0


if __name__ == "__main__":
    sys.exit(main())
