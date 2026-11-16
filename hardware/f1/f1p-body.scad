// Trillium F1p: 3D-printed Flex instrument body (shell, bottom plate, caps)
// ---------------------------------------------------------------------
// Parametric OpenSCAD source. Open in OpenSCAD 2021.01 or later, choose
// `part` in the Customizer, render (F6) and export STL.
// Geometry follows hardware/tools/mech_params.py (class F1p); the drawing
// f1p-body-drawing.svg is generated from the same numbers.
//
// Layout: a slim bar. The core board sits at the USB end (control zone);
// the Trill Flex sensor lies in a shallow channel on the top surface; its
// tail drops through a slot into the Trill base underneath; the cell sits
// further along. Buttons, LED and USB are shared with T1 (same caps).
//
// Coordinates: X along the bar from the INNER face of the USB end wall,
// Y across (centred), Z up from the bottom. The shell is modelled in
// assembly position and flipped for printing (top surface on the bed).
//
// Licence: GPL-3.0-only (see repository LICENSE).

/* [Output] */
part = "all"; // [all, shell, plate, caps, assembly]

/* [Body] */
wall      = 2.4;
plate_t   = 2.4;    // bottom plate
top_t     = 2.0;    // top surface (keep 2.0 to share the T1 caps)
in_w      = 31.2;   // inner width (cell is 30 mm wide)
corner_r  = 3.0;
standoff  = 3.5;    // plate top to board underside
side_clr  = 0.3;    // board edge to the SW1-side wall
plate_clr = 0.2;    // plate to wall clearance

/* [Trill Flex sensor] */
sensor_l  = 145.5;  // overall length of your sensor (measure!)
sensor_w  = 21.6;
tail_len  = 17.0;   // length consumed by slot + S-bend + FFC insertion (measure on a dry fit)
channel_d = 0.4;    // recess depth so the strip sits flush
slot_x    = 50.0;   // tail slot start (X)
slot_w    = 2.5;
end_margin= 6.0;

/* [Parts inside] */
base_x0   = 57.0;   // Trill base FFC edge (X)
base_l    = 36.3;
base_w    = 22.4;
cell_x0   = 104.0;
cell_t    = 5.0;    // 503035
cell_w    = 30.0;
cell_l    = 35.0;

/* [Openings and fasteners] */
usb_w     = 12.5;
usb_h     = 7.0;
sw1_l     = 6.0;
sw1_h     = 3.2;
led_d     = 5.3;
btn_d     = 5.2;
insert_d  = 4.0;    // M3 heat-set insert pilot hole
insert_h  = 5.5;
boss_d    = 7.0;
screw_d   = 3.4;
label     = true;

/* [Caps (same as T1)] */
comp_clr  = 9.5;
tact_h    = 4.3;
cap_gap   = 0.3;
cap_proud = 1.0;
cap_big_d = 7.0;
cap_stem_d= 4.6;

$fn = 48;

// ---- fixed board geometry ----
board_w = 27.94; board_l = 45.72; board_t = 1.6;
usb_setback = 2.21; usb_z = 5.3; xiao_cx = 13.97;
led_b = [12.70, 29.21]; sw2_b = [5.08, 36.83]; sw3_b = [22.86, 36.83];
sw1_by = 26.67; sw1_z = 2.0;
zones = [[0, 0, 2.54, 5.08], [25.40, 0, 27.94, 5.08],
         [0, 40.64, 2.54, 45.72], [25.40, 40.64, 27.94, 45.72]];

// ---- derived ----
out_w     = in_w + 2 * wall;
board_z0  = plate_t + standoff;
board_top = board_z0 + board_t;
top_under = board_top + comp_clr;
out_z     = top_under + top_t;
vis_len   = sensor_l - tail_len;
ch_x0     = slot_x;
ch_x1     = slot_x + slot_w + vis_len + 1.0;
in_l      = ch_x1 + end_margin;
out_l     = in_l + 2 * wall;
y_left    = in_w / 2 - side_clr - board_w;
boss_x    = [98.5, in_l - 4.5];
boss_y    = in_w / 2 - 1.5;
cap_big_h = top_under - cap_gap - (board_top + tact_h);
cap_stem_h= cap_gap + top_t + cap_proud;

// board (bx, by) -> body (X, Y): a 90-degree rotation, not a mirror
function BX(by) = usb_setback + by;
function BY(bx) = y_left + bx;

echo(str("F1p outside: ", out_l, " x ", out_w, " x ", out_z, " mm"));
echo(str("Visible sensor length: ", vis_len, " mm"));

module rbox(x0, y0, x, y, z, r) {
    translate([x0, y0, 0]) hull() for (i = [r, x - r], j = [r, y - r]) translate([i, j, 0]) cylinder(r = r, h = z);
}

// zone (board coords) -> body rectangle [X0, Y0, X1, Y1]
function zr(z, g = 0) = [BX(z[1]) - g, BY(z[0]) - g, BX(z[3]) + g, BY(z[2]) + g];

module zone_cube(z, z0, z1, g = 0) {
    r = zr(z, g);
    translate([r[0], r[1], z0]) cube([r[2] - r[0], r[3] - r[1], z1 - z0]);
}

// -------------------------------------------------------------- shell
module shell() {
    difference() {
        union() {
            difference() {
                rbox(-wall, -out_w / 2, out_l, out_w, out_z, corner_r);
                translate([0, -in_w / 2, -1]) cube([in_l, in_w, top_under + 1]);
            }
            // screw bosses (merged into the side walls)
            for (x = boss_x, s = [-1, 1])
                translate([x, s * boss_y, plate_t]) cylinder(d = boss_d, h = top_under - plate_t + 0.01);
            // clamp posts onto the board's corner zones
            for (z = zones) zone_cube(z, board_top, top_under + 0.01, -0.3);
        }
        // insert pilot holes
        for (x = boss_x, s = [-1, 1]) translate([x, s * boss_y, plate_t - 0.01]) cylinder(d = insert_d, h = insert_h);
        // sensor channel and tail slot
        translate([ch_x0, -(sensor_w + 0.8) / 2, out_z - channel_d]) cube([ch_x1 - ch_x0, sensor_w + 0.8, 1]);
        translate([slot_x, -11.5, top_under - 1]) cube([slot_w, 23, top_t + 2]);
        // LED and button holes
        translate([BX(led_b[1]), BY(led_b[0]), top_under - 5]) cylinder(d = led_d, h = 10);
        for (b = [sw2_b, sw3_b]) translate([BX(b[1]), BY(b[0]), top_under - 5]) cylinder(d = btn_d, h = 10);
        // USB-C opening, X = 0 end wall
        translate([-wall - 1, BY(xiao_cx) - usb_w / 2, board_top + usb_z - usb_h / 2]) cube([wall + 2, usb_w, usb_h]);
        // power switch slot, +Y wall
        translate([BX(sw1_by) - sw1_l / 2, in_w / 2 - 1, board_top + sw1_z - sw1_h / 2]) cube([sw1_l, wall + 2, sw1_h]);
        // plate tongue slot in the USB end wall
        translate([-1.2, -8.2, 1.0]) cube([1.21, 16.4, 1.6]);
        if (label) {
            translate([11.5, BY(xiao_cx), out_z - 0.6]) linear_extrude(1)
                text("TRILLIUM", size = 3.4, halign = "center", valign = "center", font = "Liberation Sans:style=Bold");
            translate([26, BY(xiao_cx), out_z - 0.6]) linear_extrude(1)
                text("F1", size = 3.0, halign = "center", valign = "center", font = "Liberation Sans");
            translate([BX(sw2_b[1]) + 5.6, BY(sw2_b[0]), out_z - 0.6]) linear_extrude(1)
                text("A", size = 2.6, halign = "center", valign = "center", font = "Liberation Sans:style=Bold");
            translate([BX(sw3_b[1]) + 5.6, BY(sw3_b[0]), out_z - 0.6]) linear_extrude(1)
                text("B", size = 2.6, halign = "center", valign = "center", font = "Liberation Sans:style=Bold");
            translate([BX(sw1_by), out_w / 2 - 0.5, board_top + sw1_z + 3.2]) rotate([90, 0, 180])
                linear_extrude(1) text("PWR", size = 2.4, halign = "center", valign = "bottom",
                                       font = "Liberation Sans:style=Bold");
        }
    }
}

// -------------------------------------------------------------- plate
module plate() {
    difference() {
        union() {
            translate([plate_clr, -in_w / 2 + plate_clr, 0]) cube([in_l - 2 * plate_clr, in_w - 2 * plate_clr, plate_t]);
            // tongue into the USB end wall
            translate([-1.0, -8.0, 1.0]) cube([1.0 + plate_clr + 0.01, 16, plate_t - 1.0]);
            // board support posts at the corner zones, with locating lips outside the board edge
            for (z = zones) {
                zone_cube(z, plate_t - 0.01, board_z0, -0.2);
                r = zr(z, -0.2);
                // lip on the outer side (towards the nearer side wall) and towards the USB wall
                left = z[0] < 1;
                ly0 = left ? BY(0) - 1.6 : r[1];
                ly1 = left ? BY(0) - 0.15 : r[3];
                if (left) translate([r[0], ly0, plate_t - 0.01]) cube([r[2] - r[0], ly1 - ly0, board_top + 1 - plate_t]);
                if (z[1] < 1) translate([0.4, r[1], plate_t - 0.01]) cube([BX(0) - 0.55, r[3] - r[1], board_top + 1 - plate_t]);
            }
            // Trill base locators
            for (s = [-1, 1]) translate([base_x0 + 8, s * (base_w / 2 + 0.4) - (s < 0 ? 1.2 : 0), plate_t - 0.01])
                cube([20, 1.2, 2.0]);
            translate([base_x0 + base_l + 0.4, -8, plate_t - 0.01]) cube([1.2, 16, 2.0]);
            // cell locators
            for (x = [cell_x0 - 1.6, cell_x0 + cell_l + 0.4]) translate([x, -10, plate_t - 0.01]) cube([1.2, 20, 3.0]);
        }
        for (x = boss_x, s = [-1, 1]) translate([x, s * boss_y, -1]) cylinder(d = screw_d, h = plate_t + 2);
        for (x = boss_x, s = [-1, 1]) translate([x, s * boss_y, -0.01]) cylinder(d1 = 6.4, d2 = screw_d, h = 1.5);
    }
}

module cap() {
    cylinder(d = cap_big_d, h = cap_big_h);
    translate([0, 0, cap_big_h - 0.01]) cylinder(d = cap_stem_d, h = cap_stem_h);
}

// ------------------------------------------------------------- output
if (part == "shell") translate([0, 0, out_z]) rotate([180, 0, 0]) shell();   // top surface on the bed
if (part == "plate") plate();
if (part == "caps")  for (i = [0, 1]) translate([i * 10, 0, 0]) cap();
if (part == "all") {
    translate([0, 0, out_z]) rotate([180, 0, 0]) shell();
    translate([0, out_w + 10, 0]) plate();
    for (i = [0, 1]) translate([i * 10, -out_w, 0]) cap();
}
if (part == "assembly") {
    color("SteelBlue", 0.45) shell();
    plate();
    color("Green", 0.6) translate([BX(0), BY(0), board_z0]) cube([board_l, board_w, board_t]);
    color("DarkGreen", 0.6) translate([base_x0, -base_w / 2, plate_t + 1]) cube([base_l, base_w, 1.6]);
    color("Silver", 0.6) translate([cell_x0, -cell_w / 2, plate_t]) cube([cell_l, cell_w, cell_t]);
    color("Orange", 0.7) translate([ch_x0 + slot_w, -sensor_w / 2, out_z - channel_d]) cube([vis_len, sensor_w, 0.3]);
    for (b = [sw2_b, sw3_b]) translate([BX(b[1]), BY(b[0]), board_top + tact_h]) color("Gold") cap();
}
