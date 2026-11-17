// Trillium T1 enclosure: base, lid and two button caps (3D printed)
// ---------------------------------------------------------------------
// Parametric OpenSCAD source. Open in OpenSCAD 2021.01 or later, choose
// `part` in the Customizer, render (F6) and export STL.
// Geometry follows hardware/tools/mech_params.py (class T1); the drawing
// t1-enclosure-drawing.svg is generated from the same numbers.
//
// Coordinates: origin at the outer -X/-Y/bottom corner of the base.
// +X = right side (SW1 power switch), +Y = USB-C end, +Z = up.
// Board coordinates (bx, by) are measured on the perfboard from its
// top-left corner, component side, USB-C at the top (see layout drawing).
//
// Licence: GPL-3.0-only (see repository LICENSE).

/* [Output] */
part = "all"; // [all, base, lid, caps, assembly]

/* [Shell] */
wall      = 2.0;   // side wall thickness
floor_t   = 2.0;   // base floor thickness
lid_t     = 2.0;   // lid plate thickness (also sets the cap length)
corner_r  = 2.0;   // outer corner radius
clr       = 0.3;   // board edge to inner wall
lip_h     = 1.5;   // lid lip depth
lip_t     = 1.2;   // lid lip thickness
lip_clr   = 0.15;  // lid lip to wall clearance (press fit: 0.1-0.2)

/* [Contents] */
cell_t    = 5.0;   // LiPo thickness (502030)
cell_w    = 20.0;  // LiPo width  (across X)
cell_l    = 30.0;  // LiPo length (along Y)
batt_gap  = 2.0;   // cell top to board underside (foam + trimmed leads)
comp_clr  = 9.5;   // board top to lid underside (tallest part: LED on standoff)
tact_h    = 4.3;   // tactile switch height (Omron B3F-1000)
cap_gap   = 0.3;   // cap shoulder to lid underside
cap_proud = 1.0;   // cap above lid top

/* [Openings] */
usb_w     = 12.5;  // USB-C opening (fits common plug overmoulds)
usb_h     = 7.0;
sw1_l     = 6.0;   // power-switch slot length (along Y)
sw1_h     = 3.2;
led_d     = 5.3;
btn_d     = 5.2;
cap_big_d = 7.0;
cap_stem_d= 4.6;
aux_hole  = false; // hole in the -Y wall for J3 external-button wires
label     = true;  // debossed text on the lid

$fn = 48;

// ---- fixed board geometry (hardware/tools/hw_model.py) ----
pitch      = 2.54;
board_w    = 11 * pitch;          // 27.94
board_l    = 18 * pitch;          // 45.72
board_t    = 1.6;
usb_setback= 2.21;                // board top edge to USB-C face
usb_z      = 5.3;                 // USB-C centre above board top
xiao_cx    = 13.97;               // XIAO centre across the board
led_b      = [12.70, 29.21];      // D1 centre (board coords)
sw2_b      = [ 5.08, 36.83];      // SW2 centre
sw3_b      = [22.86, 36.83];      // SW3 centre
sw1_by     = 26.67;               // SW1 centre row
sw1_z      = 2.0;                 // SW1 actuator centre above board top
j3_bx      = 13.97;
// corner zones [x0, y0, x1, y1] in board coords: keep-out, used for support
zones = [[0, 0, 2.54, 5.08], [25.40, 0, 27.94, 5.08],
         [0, 40.64, 2.54, 45.72], [25.40, 40.64, 27.94, 45.72]];

// ---- derived ----
in_x      = board_w + 2 * clr;
in_y      = usb_setback + board_l + clr;
out_x     = in_x + 2 * wall;
out_y     = in_y + 2 * wall;
board_z0  = floor_t + cell_t + batt_gap;
board_top = board_z0 + board_t;
lid_under = board_top + comp_clr;      // = top of the base walls
out_z     = lid_under + lid_t;
cap_big_h = lid_under - cap_gap - (board_top + tact_h);
cap_stem_h= cap_gap + lid_t + cap_proud;

function X(bx) = wall + clr + bx;
function Y(by) = wall + in_y - (usb_setback + by);

echo(str("T1 outside: ", out_x, " x ", out_y, " x ", out_z, " mm"));
echo(str("LED standoff above board: ", out_z - 8.6 - board_top, " mm"));

module rbox(x, y, z, r) {
    hull() for (i = [r, x - r], j = [r, y - r]) translate([i, j, 0]) cylinder(r = r, h = z);
}

// board-coordinate rectangle -> enclosure footprint
module zone_block(z, z0, z1, grow = 0, to_wall_x = false, to_wall_y = false) {
    x0 = X(z[0]) + 0.2 - grow;  x1 = X(z[2]) - 0.2 + grow;
    ya = Y(z[3]) + 0.2 - grow;  yb = Y(z[1]) - 0.2 + grow;
    xl = to_wall_x ? (z[0] < 1 ? wall - 0.01 : x0) : x0;
    xr = to_wall_x ? (z[0] < 1 ? x1 : out_x - wall + 0.01) : x1;
    yl = to_wall_y ? (z[1] > 1 ? wall - 0.01 : ya) : ya;
    yr = to_wall_y ? (z[1] > 1 ? yb : out_y - wall + 0.01) : yb;
    translate([xl, yl, z0]) cube([xr - xl, yr - yl, z1 - z0]);
}

// --------------------------------------------------------------- base
module base() {
    difference() {
        union() {
            difference() {
                rbox(out_x, out_y, lid_under, corner_r);
                translate([wall, wall, floor_t]) cube([in_x, in_y, lid_under]);
            }
            // board supports at the four corner zones, tied to the walls
            for (z = zones) zone_block(z, floor_t - 0.01, board_z0, 0, true, true);
            // stops in front of the board's top edge (USB end), outside the XIAO
            for (z = [zones[0], zones[1]])
                translate([X(z[0]) + 0.2 - (z[0] < 1 ? clr + 0.2 : 0), Y(0) + 0.2, floor_t - 0.01])
                    cube([X(z[2]) - X(z[0]) - 0.4 + clr + 0.2, out_y - wall - Y(0) - 0.2 + 0.01,
                          board_top + 1.0 - floor_t]);
            // cell locating ribs (cell long axis along Y)
            cy = Y(board_l / 2);
            for (s = [-1, 1])
                translate([out_x / 2 + s * (cell_w / 2 + 0.4) - (s < 0 ? 1.2 : 0), cy - 12, floor_t - 0.01])
                    cube([1.2, 24, 3]);
        }
        // USB-C opening, +Y wall: a U-notch open to the top; the lid plate closes it
        // (a closed window would leave a fragile strip of wall under the lid)
        translate([X(xiao_cx) - usb_w / 2, out_y - wall - 1, board_top + usb_z - usb_h / 2])
            cube([usb_w, wall + 2, lid_under - (board_top + usb_z - usb_h / 2) + 1]);
        // power switch slot, +X wall
        translate([out_x - wall - 1, Y(sw1_by) - sw1_l / 2, board_top + sw1_z - sw1_h / 2])
            cube([wall + 2, sw1_l, sw1_h]);
        // pry notch for the lid, -Y wall
        translate([out_x / 2 - 4, -0.01, lid_under - 1.2]) cube([8, 1.0, 1.3]);
        if (aux_hole)
            translate([X(j3_bx), -1, board_top + 3]) rotate([-90, 0, 0]) cylinder(d = 4, h = wall + 2);
        // "PWR" next to the switch slot
        if (label)
            translate([out_x - 0.5, Y(sw1_by), board_top + sw1_z + 3.2]) rotate([90, 0, 90])
                linear_extrude(1) text("PWR", size = 2.4, halign = "center", valign = "bottom",
                                       font = "Liberation Sans:style=Bold");
    }
}

// ---------------------------------------------------------------- lid
// Modelled in assembly position (plate from lid_under to out_z).
module lid() {
    difference() {
        union() {
            translate([0, 0, lid_under]) rbox(out_x, out_y, lid_t, corner_r);
            // lip
            translate([0, 0, lid_under - lip_h]) difference() {
                translate([wall + lip_clr, wall + lip_clr, 0])
                    cube([in_x - 2 * lip_clr, in_y - 2 * lip_clr, lip_h + 0.01]);
                translate([wall + lip_clr + lip_t, wall + lip_clr + lip_t, -1])
                    cube([in_x - 2 * lip_clr - 2 * lip_t, in_y - 2 * lip_clr - 2 * lip_t, lip_h + 2]);
            }
            // clamp posts down to the board's corner zones
            for (z = zones) zone_block(z, board_top, lid_under + 0.01, -0.1);
        }
        // LED and button holes
        translate([X(led_b[0]), Y(led_b[1]), lid_under - 5]) cylinder(d = led_d, h = 10);
        for (b = [sw2_b, sw3_b]) translate([X(b[0]), Y(b[1]), lid_under - 5]) cylinder(d = btn_d, h = 10);
        // lip notch over the USB opening
        translate([X(xiao_cx) - usb_w / 2 - 0.5, out_y - wall - lip_t - 1, lid_under - lip_h - 1])
            cube([usb_w + 1, lip_t + 2, lip_h + 1]);
        if (label) {
            translate([out_x / 2, Y(9), out_z - 0.6]) linear_extrude(1)
                text("TRILLIUM", size = 3.2, halign = "center", valign = "center",
                     font = "Liberation Sans:style=Bold");
            translate([out_x / 2, Y(16), out_z - 0.6]) linear_extrude(1)
                text("T1", size = 3.0, halign = "center", valign = "center", font = "Liberation Sans");
            translate([X(sw2_b[0]), Y(sw2_b[1]) - 5.6, out_z - 0.6]) linear_extrude(1)
                text("A", size = 2.6, halign = "center", valign = "center", font = "Liberation Sans:style=Bold");
            translate([X(sw3_b[0]), Y(sw3_b[1]) - 5.6, out_z - 0.6]) linear_extrude(1)
                text("B", size = 2.6, halign = "center", valign = "center", font = "Liberation Sans:style=Bold");
        }
    }
}

// --------------------------------------------------------------- caps
module cap() {
    cylinder(d = cap_big_d, h = cap_big_h);
    translate([0, 0, cap_big_h - 0.01]) cylinder(d = cap_stem_d, h = cap_stem_h);
}

// ------------------------------------------------------------- output
if (part == "base") base();
if (part == "lid")  translate([0, out_y, out_z]) rotate([180, 0, 0]) lid();   // print plate-down
if (part == "caps") for (i = [0, 1]) translate([i * 10, 0, 0]) cap();
if (part == "all") {
    base();
    translate([out_x + 8, out_y, out_z]) rotate([180, 0, 0]) lid();
    for (i = [0, 1]) translate([2 * out_x + 20 + i * 10, 6, 0]) cap();
}
if (part == "assembly") {
    base();
    color("SteelBlue", 0.5) lid();
    for (b = [sw2_b, sw3_b]) translate([X(b[0]), Y(b[1]), board_top + tact_h]) color("Gold") cap();
    color("Green", 0.6) translate([X(0), Y(board_l), board_z0]) cube([board_w, board_l, board_t]);
    color("Silver", 0.6) translate([out_x / 2 - cell_w / 2, Y(board_l / 2) - cell_l / 2, floor_t])
        cube([cell_w, cell_l, cell_t]);
}
