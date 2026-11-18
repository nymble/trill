#!/usr/bin/env python3
"""Regenerate every Trillium hardware drawing, list and laser file.

    python3 hardware/tools/gen_hw.py          # from the repository root

Outputs (overwritten):
  hardware/t2/  t2-schematic.svg  t2-layout.svg  t2-bom.csv  t2-enclosure-drawing.svg
  hardware/f1/  f1-schematic.svg  f1-layout.svg  f1-bom.csv  f1p-body-drawing.svg
                f1w-body-drawing.svg  f1w-sheet-3mm.svg  f1w-sheet-1.5mm.svg
The .scad sources are hand-maintained; this script lints them and checks
that the key numbers in them match mech_params.py.
Requires Python 3.10+ and matplotlib (text outlines for laser engraving).
"""

from __future__ import annotations

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import bom  # noqa: E402
import hw_model as hw  # noqa: E402
import layout  # noqa: E402
import mech  # noqa: E402
import mech_params as mp  # noqa: E402
import schematic  # noqa: E402

ROOT = os.path.dirname(HERE)
T1 = os.path.join(ROOT, "t2")  # revision-A "T1" design is the planned T2 model
FILE = {"T1": "t2", "F1": "f1"}
F1 = os.path.join(ROOT, "f1")


def lint_scad(path: str) -> list[str]:
    """Structural checks only (no OpenSCAD available): brackets, strings, used vs defined modules."""
    src = open(path).read()
    code = re.sub(r"//.*", "", src)
    code = re.sub(r"/\*.*?\*/", "", code, flags=re.S)
    code_ns = re.sub(r'"(?:[^"\\]|\\.)*"', '""', code)
    problems = []
    pairs = {")": "(", "]": "[", "}": "{"}
    stack = []
    for i, ch in enumerate(code_ns):
        if ch in "([{":
            stack.append((ch, i))
        elif ch in ")]}":
            if not stack or stack[-1][0] != pairs[ch]:
                line = code_ns[:i].count("\n") + 1
                problems.append(f"{os.path.basename(path)}:{line}: unbalanced '{ch}'")
                break
            stack.pop()
    if stack:
        problems.append(f"{os.path.basename(path)}: unclosed '{stack[-1][0]}'")
    builtin = {"cube", "cylinder", "sphere", "translate", "rotate", "scale", "mirror", "union", "difference",
               "intersection", "hull", "minkowski", "linear_extrude", "rotate_extrude", "text", "color", "echo",
               "polygon", "polyhedron", "circle", "square", "offset", "projection", "children", "for", "if", "else",
               "let", "assert", "str", "function", "module"}
    defined = set(re.findall(r"\bmodule\s+(\w+)", code_ns)) | set(re.findall(r"\bfunction\s+(\w+)", code_ns))
    calls = set(re.findall(r"\b([A-Za-z_]\w*)\s*\(", code_ns))
    variables = set(re.findall(r"\b([A-Za-z_]\w*)\s*=", code_ns))
    for c in sorted(calls - builtin - defined - variables):
        if c not in {"len", "abs", "max", "min", "sqrt", "sin", "cos", "concat", "floor", "ceil", "round"}:
            problems.append(f"{os.path.basename(path)}: '{c}(' is called but not defined")
    return problems


def scad_number(path: str, name: str) -> float | None:
    m = re.search(rf"^\s*{name}\s*=\s*([-0-9.]+)\s*;", open(path).read(), re.M)
    return float(m.group(1)) if m else None


def check_constants() -> list[str]:
    p = []
    t1s = os.path.join(T1, "t2-enclosure.scad")
    f1s = os.path.join(F1, "f1p-body.scad")
    t, f = mp.T1(), mp.F1p()
    for path, name, val in [
        (t1s, "wall", t.wall), (t1s, "floor_t", t.floor), (t1s, "lid_t", t.lid), (t1s, "clr", t.clr),
        (t1s, "batt_gap", t.batt_gap), (t1s, "comp_clr", hw.COMP_CLEAR), (t1s, "tact_h", hw.TACT_H),
        (t1s, "usb_setback", round(hw.USB_SETBACK, 2)), (t1s, "usb_z", round(hw.USB_Z_ABOVE_BOARD, 2)),
        (f1s, "wall", f.wall), (f1s, "plate_t", f.plate), (f1s, "top_t", f.top), (f1s, "standoff", f.standoff),
        (f1s, "in_w", f.in_w), (f1s, "tail_len", f.tail_len), (f1s, "slot_x", f.slot_x),
        (f1s, "base_x0", f.base_x0), (f1s, "cell_x0", f.batt_x0), (f1s, "sensor_l", hw.TRILL_SENSOR_L),
    ]:
        got = scad_number(path, name)
        if got is None or abs(got - val) > 1e-6:
            p.append(f"{os.path.basename(path)}: {name} = {got}, mech_params says {val}")
    # board feature positions
    for path in (t1s, f1s):
        src = open(path).read()
        for label, (x, y) in (("led_b", mp.LED_B), ("sw2_b", mp.SW2_B), ("sw3_b", mp.SW3_B)):
            m = re.search(rf"{label}\s*=\s*\[\s*([-0-9.]+)\s*,\s*([-0-9.]+)\s*\]", src)
            if not m or abs(float(m.group(1)) - x) > 0.01 or abs(float(m.group(2)) - y) > 0.01:
                p.append(f"{os.path.basename(path)}: {label} mismatch")
    return p


def main() -> int:
    problems = hw.check_layout()
    for m, d in (("T1", T1), ("F1", F1)):
        schematic.draw(m).save(os.path.join(d, f"{FILE[m]}-schematic.svg"))
        layout.draw(m).save(os.path.join(d, f"{FILE[m]}-layout.svg"))
    bom.write_csv(os.path.join(T1, "t2-bom.csv"), "T1", ("T1",))
    bom.write_csv(os.path.join(F1, "f1-bom.csv"), "F1", ("F1p", "F1w"))
    mech.t1_drawing(os.path.join(T1, "t2-enclosure-drawing.svg"))
    mech.f1p_drawing(os.path.join(F1, "f1p-body-drawing.svg"))
    mech.f1w_drawing(os.path.join(F1, "f1w-body-drawing.svg"))
    s3, s15 = mech.f1w_sheets(F1)
    problems += lint_scad(os.path.join(T1, "t2-enclosure.scad"))
    problems += lint_scad(os.path.join(F1, "f1p-body.scad"))
    problems += check_constants()
    t, f, w = mp.T1(), mp.F1p(), mp.F1w()
    print(f"T1  enclosure {t.out_x:.2f} x {t.out_y:.2f} x {t.out_z:.2f} mm")
    print(f"F1p body      {f.out_l:.2f} x {f.out_w:.2f} x {f.out_z:.2f} mm, visible sensor {f.vis_len:.1f} mm")
    print(f"F1w body      {w.out_l:.2f} x {w.out_w:.2f} x {w.out_z:.2f} mm, visible sensor {w.vis_len:.1f} mm")
    print(f"F1w sheets    3 mm {s3[0]} x {s3[1]} mm, 1.5 mm {s15[0]} x {s15[1]} mm")
    if problems:
        print("PROBLEMS:")
        for x in problems:
            print("  -", x)
        return 1
    print("checks: OK (layout, scad structure, scad constants)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
