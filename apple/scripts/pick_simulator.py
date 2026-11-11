#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Print the UDID of an available iPhone or iPad simulator (newest iOS runtime first).

Usage:
  pick_simulator.py           # iPhone (default)
  pick_simulator.py iphone
  pick_simulator.py ipad

Used by `make apple-test-ios-sim`, `make apple-test-ipad-sim` and
`make apple-ipad-sim`. Read-only: it only lists simulators.
"""
from __future__ import annotations

import json
import subprocess
import sys
from typing import Any


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


def pick(devices: dict[str, list[dict[str, Any]]], kind: str) -> dict[str, Any] | None:
    """Return the chosen device dict (with at least udid and name), or None."""
    kind = kind.lower()
    if kind not in ("iphone", "ipad"):
        raise ValueError(f"kind must be iphone or ipad, not {kind!r}")
    prefix = "iPad" if kind == "ipad" else "iPhone"
    runtimes = sorted((r for r in devices if ".iOS-" in r), key=runtime_version, reverse=True)
    for runtime in runtimes:
        found = available_on_runtime(devices, runtime, prefix)
        if not found:
            continue
        if kind == "ipad":
            found = sorted(found, key=lambda d: (ipad_rank(str(d.get("name", ""))), str(d.get("name", ""))))
        return found[0]
    return None


def list_available() -> dict[str, list[dict[str, Any]]]:
    out = subprocess.run(
        ["xcrun", "simctl", "list", "devices", "available", "-j"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    return json.loads(out)["devices"]


def main(argv: list[str] | None = None) -> int:
    args = list(sys.argv[1:] if argv is None else argv)
    kind = "iphone"
    if args:
        if args[0] in ("-h", "--help"):
            print(__doc__.strip(), file=sys.stderr)
            return 0
        kind = args[0].lower()
        if kind not in ("iphone", "ipad") or len(args) != 1:
            print("usage: pick_simulator.py [iphone|ipad]", file=sys.stderr)
            return 2
    chosen = pick(list_available(), kind)
    if not chosen:
        print(f"no available {kind} simulator", file=sys.stderr)
        return 1
    print(chosen["udid"])
    return 0


if __name__ == "__main__":
    sys.exit(main())
