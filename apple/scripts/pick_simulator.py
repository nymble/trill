#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Print the UDID of an available iPhone simulator (newest iOS runtime first).

Used by `make apple-test-ios-sim` because simulator names differ between
Xcode versions. Read-only: it only lists simulators.
"""
import json
import subprocess
import sys

out = subprocess.run(
    ["xcrun", "simctl", "list", "devices", "available", "-j"], check=True, capture_output=True, text=True
).stdout
devices = json.loads(out)["devices"]


def version(runtime: str) -> tuple:
    tail = runtime.rsplit("iOS-", 1)[-1]
    return tuple(int(p) for p in tail.split("-") if p.isdigit())


for runtime in sorted((r for r in devices if ".iOS-" in r), key=version, reverse=True):
    for d in devices[runtime]:
        if d.get("isAvailable") and d["name"].startswith("iPhone"):
            print(d["udid"])
            sys.exit(0)
sys.exit("no available iPhone simulator")
