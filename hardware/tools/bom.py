"""Bills of materials for T1 and F1 (electrical + mechanical), from hw_model."""

from __future__ import annotations

import csv

import hw_model as hw

COMMON_EXTRA = [
    ("PB1", "1", "Perfboard", "2.54 mm pitch, single-sided pads, FR-4 1.6 mm, cut to 11 x 18 holes (27.9 x 45.7 mm)", "any"),
    ("H1", "2", "Male header 1x7", "2.54 mm, standard 2.5 mm plastic, for U1 (usually supplied with the XIAO)", "any"),
    ("W", "-", "Hook-up wire", "28-30 AWG insulated solid (wire-wrap) wire, several colours", "any"),
    ("SP1", "1", "LED standoff", "Plastic spacer for 5 mm LED, cut to length (see enclosure doc)", "any"),
    ("KT1", "-", "Insulating tape", "Polyimide (Kapton) tape over the board underside / cell", "any"),
]

MECH = {
    "T1": [
        ("M1", "1", "T1 enclosure base", "3D printed, PLA/PETG, t1-enclosure.scad part=\"base\"", "print"),
        ("M2", "1", "T1 enclosure lid", "3D printed, t1-enclosure.scad part=\"lid\"", "print"),
        ("M3", "2", "Button cap", "3D printed, t1-enclosure.scad part=\"caps\"", "print"),
        ("M4", "1", "Foam tape", "Double-sided foam tape ~0.5-1 mm, holds BT1 in the base", "any"),
    ],
    "F1p": [
        ("M1", "1", "F1p shell (top + walls)", "3D printed, f1p-body.scad part=\"shell\"", "print"),
        ("M2", "1", "F1p bottom plate", "3D printed, f1p-body.scad part=\"plate\"", "print"),
        ("M3", "2", "Button cap", "3D printed, f1p-body.scad part=\"caps\" (same as T1)", "print"),
        ("M4", "4", "Heat-set insert M3", "M3 x 5.7 mm OD x 4 mm long brass insert", "any"),
        ("M5", "4", "Screw M3 x 6", "Button-head or countersunk, through the bottom plate", "any"),
        ("M6", "1", "Foam tape", "Double-sided foam tape for BT1 and the Trill base", "any"),
    ],
    "F1w": [
        ("M1", "1", "Plywood sheet 3 mm", "Birch plywood, laser grade, >= 430 x 220 mm (f1w-sheet-3mm.svg)", "any"),
        ("M2", "1", "Plywood sheet 1.5 mm", "Birch plywood, >= 215 x 75 mm (f1w-sheet-1.5mm.svg)", "any"),
        ("M3", "8", "Screw M3 x 20", "Button head (ISO 7380) or socket head, through the stack from the top", "any"),
        ("M4", "8", "Hex nut M3", "Captured in layer L1", "any"),
        ("M5", "-", "Wood glue", "Only for the laminated button plungers (stack stays screw-assembled)", "any"),
        ("M6", "1", "Foam tape", "Double-sided foam tape for BT1 and the Trill base", "any"),
    ],
}


def rows(model: str):
    out = []
    for p in hw.PARTS:
        fitted = model in p.models
        if not fitted and model == "T1":
            continue
        out.append((p.ref, str(p.qty) if not p.optional else f"{p.qty} (opt.)", p.value, p.desc, p.example or "generic"))
    if model == "F1":
        for ref, val, desc, ex in hw.F1_EXTERNAL:
            out.append((ref, "1", val, desc, ex))
    for r in COMMON_EXTRA:
        out.append(r)
    return out


def write_csv(path, model, mech_key):
    with open(path, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["Ref", "Qty", "Value", "Description", "Example part"])
        for r in rows(model):
            w.writerow(r)
        for k in mech_key:
            for r in MECH[k]:
                w.writerow((f"{k}:{r[0]}",) + r[1:])


def md(model: str, mech_keys=()) -> str:
    out = ["| Ref | Qty | Value | Description | Example part |", "|---|---|---|---|---|"]
    for r in rows(model):
        out.append("| " + " | ".join(x.replace("|", "/") for x in r) + " |")
    for k in mech_keys:
        for r in MECH[k]:
            out.append("| " + " | ".join((f"{k} {r[0]}",) + tuple(x.replace("|", "/") for x in r[1:])) + " |")
    return "\n".join(out)


if __name__ == "__main__":
    print(md("T1", ("T1",)))
