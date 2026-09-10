# ===----------------------------------------------------------------------=== #
# Mission Planner — the flight-planning console, as a Mac application.
#
# The same mission, the same physics, a different front end. `main.mojo`
# beside this file draws the trench's console the way 1969 drew it: a
# character grid, an indexed palette, a shader backdrop, one window that
# owns every pixel in it. That is the right answer for what it is, and it
# is the wrong answer for showing what Cocoa is.
#
# This is the other answer. A toolbar, a three-pane split, a source list,
# an inspector, a log, a menu bar with real key equivalents, and a plot
# drawn in vectors rather than in cells. Nothing is simulated: NSToolbar,
# NSSplitView, NSTableView with its data source, NSPopUpButton, NSSlider,
# NSTextView, NSMenu -- the ordinary AppKit an ordinary Mac application is
# made of, driven from Mojo.
#
# The physics is imported, not reimplemented. Every number on the screen
# comes from `astro`, `plan`, `transfer`, `orbit`, `mission` and `descent`
# exactly as the other console gets it, and the two front ends can be run
# side by side on the same choices and compared line for line. That is the
# point of keeping both: the interface is not the program.
#
#   cocoamojo run examples/moonshot/planner.mojo
#   PLANNER_FRAMES=120 cocoamojo run examples/moonshot/planner.mojo  (headless)
# ===----------------------------------------------------------------------=== #

from std.objc import (
    Obj,
    Cls,
    ObjCObject,
    load_framework,
    named_global,
    nsenum,
    nsstring,
    ns_to_string,
    sel,
    autoreleasepool,
    SEL,
    CGPoint,
    CGSize,
    CGRect,
)
from std.memory import OpaquePointer
from std.ffi import external_call
from std.os import getenv
from std.time import perf_counter_ns
from std.math import sqrt, sin, cos, atan2, floor

from astro import (
    Vec3, Ephemeris, Site, launch_sites, landing_sites, julian_day, civil,
    R_EARTH, R_MOON, MU_EARTH, MU_MOON, MOON_SOI, DEG, RAD, fmt,
)
from orbit import Bodies, RVd, F_ALL
from max.gpu.host import DeviceContext
from window import WindowMap, compute_map, FIELDS, F_DV_TLI, F_DV_LOI, F_FLAGS, FLAG_CORRIDOR, FLAG_LIT, FLAG_OK
from descent import Terrain, high_gate, low_gate, phase_label
from plan import Choices, PlanSheet, make_plan, apollo_11_choices
from mission import (
    Mission, PHASE_PARKING, PHASE_LUNAR_ORBIT, PHASE_DESCENT, PHASE_DONE,
    get_string,
)
from scene import Camera, rotate_about
import planner_ui as ui

comptime P = OpaquePointer[MutUntrackedOrigin]


# ── the model, as the callbacks can reach it ─────────────────────────────
#
# The pump owns the Mission and the PlanSheet on its own stack, the way
# `examples/othello` owns its board: a callback that fires during a draw
# cannot be handed a Mojo struct that lives in `main`. What the callbacks
# and the data sources read instead is a SNAPSHOT, rebuilt by the pump
# whenever the plan changes -- flat lists of strings and floats, which is
# all a table view and a plot ever wanted.

comptime g_rows = named_global["planner.rows", List[String]]
"""The inspector, four strings a row: kind, label, value, state.
kind: "h" a group header, "r" a row, "s" a spacer.
state: "n" normal, "r" red, "a" amber, "g" green, "b" bold."""

comptime g_log = named_global["planner.log", List[String]]
comptime g_phases = named_global["planner.phases", List[String]]
comptime g_arc = named_global["planner.arc", List[Float64]]
"""The planned course in kilometres, x y z per sample."""
comptime g_flown = named_global["planner.flown", List[Float64]]
comptime g_dtrail = named_global["planner.dtrail", List[Float64]]
"""The powered descent as flown: downrange and altitude in metres, a pair
per guidance cycle."""
comptime g_dstate = named_global["planner.dstate", List[Float64]]
"""And where it is now, by the D_* indices."""

comptime D_RANGE = 0
comptime D_ALT = 1
comptime D_RATE = 2
comptime D_GS = 3
comptime D_THR = 4
comptime D_HOVER = 5
comptime D_PHASE = 6
comptime D_LIVE = 7
comptime D_AIM = 8
comptime D_REDES = 9
comptime D_LANDX = 10
comptime D_CONTACT = 11
comptime D_ALARM = 12
comptime D_COUNT = 13
"""What the spacecraft has actually flown, same layout."""

comptime g_moon = named_global["planner.moon", List[Float64]]
"""The Moon's position at each arc sample -- so the plot can draw where it
was as well as where it is."""

# Scalars. Ints because a named_global slot is a word; the floats that
# need to survive are kept in `g_num`.
comptime g_view = named_global["planner.view", Int]
comptime g_table = named_global["planner.table", Int]
comptime g_sidebar = named_global["planner.sidebar", Int]
comptime g_logview = named_global["planner.logview", Int]
comptime g_window = named_global["planner.window", Int]
comptime g_actions = named_global["planner.actions", Int]
comptime g_status = named_global["planner.status", Int]
comptime g_spinner = named_global["planner.spinner", Int]
comptime g_seg = named_global["planner.seg", Int]
comptime g_speedpop = named_global["planner.speedpop", Int]
comptime g_flybtn = named_global["planner.flybtn", Int]

comptime g_mode = named_global["planner.mode", Int]
"""0 trajectory, 1 window map, 2 descent."""
comptime g_mission_phase = named_global["planner.missionphase", Int]
"""The flight's phase, so the scripting surface can refuse a call that
makes no sense where the mission actually is."""
comptime g_seenphase = named_global["planner.seenphase", Int]
"""The stage the view last reacted to, so the view follows the flight on
its TRANSITIONS and never fights a viewer who has chosen to look somewhere
else in between."""
comptime g_phase_sel = named_global["planner.phasesel", Int]
comptime g_cmd = named_global["planner.cmd", Int]
comptime g_flying = named_global["planner.flying", Int]
comptime g_dirty = named_global["planner.dirty", Int]
comptime g_frames = named_global["planner.frames", Int]

comptime g_group = named_global["planner.group", List[Int]]
"""The section each inspector row belongs to, so the source list can show
one of them. Parallel to `g_rows` rather than a fifth string in it: this is
structure, and the table never renders it."""
comptime g_visible = named_global["planner.visible", List[Int]]
"""The rows the current selection admits, as indices into `g_rows`. The
data source reads THIS and nothing else, so filtering is one rebuild rather
than a condition in three delegate methods."""
comptime g_cur_group = named_global["planner.curgroup", Int]
comptime g_exporting = named_global["planner.exporting", Int]
"""Set while the canvas is being drawn for a file rather than for the
screen. The only difference is the interaction hint along the bottom: it
tells a viewer what to do with the mouse, and an exported chart has no
mouse. Everything else about the two pictures is deliberately identical."""

comptime G_LAUNCH = 0
comptime G_TRANSLUNAR = 1
comptime G_ARRIVAL = 2
comptime G_DESCENT = 3
comptime G_MARGINS = 4
comptime G_RULES = 5
comptime G_FLIGHT = 6

comptime g_map = named_global["planner.map", List[Float64]]
"""The window map, aggregated to one cell per day and hour: the cheapest
total Delta-v in that hour, or 0 where nothing closes."""
comptime g_mapflag = named_global["planner.mapflag", List[Int]]
comptime g_map_days = named_global["planner.mapdays", Int]

comptime g_num = named_global["planner.num", List[Float64]]
"""Camera and plot scalars, by the N_* indices below."""

comptime N_YAW = 0
comptime N_PITCH = 1
comptime N_ZOOM = 2
comptime N_GET = 3
comptime N_WARP = 4
# Where the course view is looking and how wide, set by `frame_course` from
# the mission rather than fixed: a camera pinned to the Earth at a span that
# holds the whole transfer shows the interesting end of it as three pixels.
comptime N_CX = 5
comptime N_CY = 6
comptime N_CZ = 7
comptime N_SPAN = 8
# Where the Moon is NOW. The plot used to draw it at the last sample of its
# own path -- its position at the end of the planned arc -- so it hung
# still while the spacecraft moved, and once the camera followed the craft
# in, the disc sat a frame-width from where the craft actually was.
comptime N_MX = 9
comptime N_MY = 10
comptime N_MZ = 11
# And where it will be at the ARRIVAL -- perilune, not the end of the
# recorded arc, which runs six hours past it.
comptime N_AX = 12
comptime N_AY = 13
comptime N_AZ = 14
comptime N_COUNT = 15

comptime CMD_REPLAN = 1
comptime CMD_FLY = 2
comptime CMD_RESET = 4
comptime CMD_QUIT = 8
comptime CMD_EXPORT = 16
comptime CMD_ABORT = 32
comptime CMD_GO = 64
comptime CMD_NOGO = 128

fn speed_count() -> Int:
    return 7


fn speed_rate(i: Int) -> Float64:
    """Seconds of mission per second of wall clock. 900x flies Apollo 11's
    103 hours in about seven minutes, which is why it is the default; 1x is
    there because a burn lasting 336 seconds is worth watching once."""
    var r = List[Float64]()
    r.append(1.0)
    r.append(10.0)
    r.append(60.0)
    r.append(300.0)
    r.append(900.0)
    r.append(1800.0)
    r.append(3600.0)
    return r[i] if i >= 0 and i < len(r) else 900.0


fn set_speed(v: Float64):
    """The rate, and the control that shows it. The powered descent runs at
    10x whatever is asked (mission.advance caps it), so the menu carries a
    10x step and the descent selects it -- a popup reading 900x over a
    descent crawling at 10 is the control lying about the clock."""
    set_num(N_WARP, v)
    if g_speedpop()[] != 0:
        Obj["NSPopUpButton"](ObjCObject(g_speedpop()[]).addr()).selectItemAtIndex(
            speed_index_of(v)
        )


fn speed_label(i: Int) -> String:
    let v = speed_rate(i)
    return String("1×  real time") if v == 1.0 else (ui.f(v, 0) + "×")


fn speed_index_of(v: Float64) -> Int:
    for i in range(speed_count()):
        if speed_rate(i) == v:
            return i
    return 4


comptime MODE_TRAJECTORY = 0
comptime MODE_MAP = 1
comptime MODE_DESCENT = 2

# The choices, held as numbers so a control's action can move one without
# owning a Choices struct.
comptime g_choice = named_global["planner.choice", List[Int]]
comptime C_PAD = 0
comptime C_TARGET = 1
comptime C_MONTH = 2
comptime C_YEAR = 3
comptime C_TOF = 4  # tenths of an hour
comptime C_MCC = 5
comptime C_COUNT = 6


fn num(i: Int) -> Float64:
    return g_num()[][i]


fn set_num(i: Int, v: Float64):
    g_num()[][i] = v


fn choice(i: Int) -> Int:
    return g_choice()[][i]


fn set_choice(i: Int, v: Int):
    g_choice()[][i] = v


def current_choices() -> Choices:
    """The Choices struct the physics wants, from the controls' numbers."""
    var ch = apollo_11_choices()
    ch.pad = choice(C_PAD)
    ch.target = choice(C_TARGET)
    ch.month = choice(C_MONTH)
    ch.year = choice(C_YEAR)
    ch.tof_h = Float64(choice(C_TOF)) / 10.0
    ch.mcc_policy = choice(C_MCC)
    return ch


# ── the inspector's rows ─────────────────────────────────────────────────


fn add_header(title: String):
    g_group()[].append(g_cur_group()[])
    g_rows()[].append(String("h"))
    g_rows()[].append(title)
    g_rows()[].append(String(""))
    g_rows()[].append(String("n"))


fn add_row(label: String, value: String, state: String):
    g_group()[].append(g_cur_group()[])
    g_rows()[].append(String("r"))
    g_rows()[].append(label)
    g_rows()[].append(value)
    g_rows()[].append(state)


fn add_spacer():
    g_group()[].append(g_cur_group()[])
    g_rows()[].append(String("s"))
    g_rows()[].append(String(""))
    g_rows()[].append(String(""))
    g_rows()[].append(String("n"))


fn row_count() -> Int:
    return len(g_rows()[]) // 4


fn row_at(i: Int, field: Int) -> String:
    return g_rows()[][i * 4 + field]


fn shown_count() -> Int:
    return len(g_visible()[])


fn shown_at(i: Int, field: Int) -> String:
    if i < 0 or i >= len(g_visible()[]):
        return String("")
    return row_at(g_visible()[][i], field)


fn group_admits(sel: Int, g: Int) -> Bool:
    """Sidebar row 0 is every section; 1..4 are the four phases in order;
    5 gathers the margins, the flight rules and the live flight, which are
    read together and are too short to be worth a row each."""
    if sel <= 0:
        return True
    if sel == 5:
        return g == G_MARGINS or g == G_RULES or g == G_FLIGHT
    return g == sel - 1


fn rebuild_visible():
    """Which rows the source list's selection admits. A trailing spacer is
    dropped: a filtered section that ends in blank space reads as a table
    that failed to finish."""
    g_visible()[].clear()
    let sel = g_phase_sel()[]
    for i in range(row_count()):
        if i < len(g_group()[]) and group_admits(sel, g_group()[][i]):
            g_visible()[].append(i)
    while len(g_visible()[]) > 0:
        let last = g_visible()[][len(g_visible()[]) - 1]
        if row_at(last, 0) != "s":
            break
        _ = g_visible()[].pop()


def build_rows(sheet: PlanSheet, ch: Choices, get: Float64, flying: Bool):
    """The plan sheet, as the inspector shows it. Everything here is a
    number the physics computed; nothing is entered twice."""
    g_rows()[].clear()
    g_group()[].clear()

    g_cur_group()[] = G_LAUNCH
    add_header(String("Launch"))
    add_row(String("Site"), launch_sites()[ch.pad].name, "n")
    add_row(String("Date"), date_of(sheet.jd_launch), "n")
    add_row(String("Lift-off"), clock_of(sheet.jd_launch), "n")
    add_row(
        String("Azimuth"),
        ui.f(sheet.azimuth, 2) + "°",
        "n" if sheet.corridor else "r",
    )
    add_row(String("Inclination"), ui.f(sheet.inclination, 2) + "°", "n")
    add_spacer()

    g_cur_group()[] = G_TRANSLUNAR
    add_header(String("Translunar"))
    add_row(String("TLI"), clock_of(sheet.jd_tli_ign), "n")
    add_row(String("Δv"), ui.ms(sheet.dv_tli), "b")
    add_row(String("Burn"), ui.f(sheet.tli_seconds, 0) + " s", "n")
    add_row(String("Flight time"), ui.f(sheet.tof / 3600.0, 2) + " h", "n")
    add_row(String("Moon at arrival"), ui.f(sheet.moon_dist, 0) + " km", "n")
    add_row(
        String("Free return"),
        (ui.f(sheet.return_perigee_alt, 0) + " km") if sheet.free_return else String("no"),
        "g" if sheet.free_return else "a",
    )
    add_spacer()

    g_cur_group()[] = G_ARRIVAL
    add_header(String("Arrival"))
    add_row(String("Perilune"), ui.f(sheet.transfer.correction.arrival.r_p - R_MOON, 1) + " km", "n")
    add_row(String("v∞"), ui.ms(sheet.transfer.correction.arrival.v_inf), "n")
    add_row(String("Orbit to equator"), ui.f(sheet.inc_equator, 1) + "°", "n")
    add_row(String("LOI-1"), clock_of(sheet.jd_loi1_ign), "n")
    add_row(String("Δv"), ui.ms(sheet.dv_loi1), "b")
    add_row(String("LOI-2"), ui.ms(sheet.dv_loi2), "n")
    add_spacer()

    g_cur_group()[] = G_DESCENT
    add_header(String("Descent"))
    add_row(String("Site"), landing_sites()[ch.target].name, "n")
    add_row(String("Touchdown"), clock_of(sheet.jd_landing), "n")
    add_row(
        String("Sun elevation"),
        ui.f(sheet.sun_elev, 1) + "°",
        "n" if sheet.lit else "r",
    )
    add_row(String("Cross-range"), ui.f(sheet.cross_range, 1) + " km", "n")
    add_row(String("DOI"), ui.ms(sheet.dv_doi), "n")
    add_row(String("Descent Δv"), ui.ms(sheet.dv_descent), "n")
    add_spacer()

    g_cur_group()[] = G_MARGINS
    add_header(String("Margins"))
    add_row(
        String("S-IVB"),
        ui.f(sheet.sivb_margin_kg, 0) + " kg · " + ui.ms(sheet.sivb_margin_dv),
        "r" if sheet.sivb_margin_kg < 0.0 else ("a" if sheet.sivb_margin_dv < 0.05 else "g"),
    )
    add_row(
        String("SPS"),
        ui.f(sheet.sps_margin_kg, 0) + " kg · " + ui.ms(sheet.sps_margin_dv),
        "r" if sheet.sps_margin_kg < 0.0 else ("a" if sheet.sps_margin_dv < 0.05 else "g"),
    )
    add_row(
        String("DPS hover"),
        ui.f(sheet.dps_margin_s, 0) + " s",
        "r" if sheet.dps_margin_s < 0.0 else ("a" if sheet.dps_margin_s < 30.0 else "g"),
    )

    if len(sheet.red) > 0 or len(sheet.amber) > 0:
        add_spacer()
        g_cur_group()[] = G_RULES
        add_header(String("Flight rules"))
        for i in range(len(sheet.red)):
            add_row(String("NO-GO"), sheet.red[i], "r")
        for i in range(len(sheet.amber)):
            add_row(String("Caution"), sheet.amber[i], "a")

    if flying:
        g_cur_group()[] = G_FLIGHT
        add_spacer()
        g_cur_group()[] = G_FLIGHT
        add_header(String("Flight"))
        add_row(String("GET"), ui.get_hms(get), "b")

    rebuild_visible()


def date_of(jd: Float64) -> String:
    let c = civil(jd)
    var months = List[String]()
    for m in ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]:
        months.append(String(m))
    return String(c.day) + " " + months[c.month - 1] + " " + String(c.year)


def clock_of(jd: Float64) -> String:
    let c = civil(jd)
    var mm = String(c.minute)
    if c.minute < 10:
        mm = "0" + mm
    var hh = String(c.hour)
    if c.hour < 10:
        hh = "0" + hh
    return hh + ":" + mm + " UTC"


# ── the plot ─────────────────────────────────────────────────────────────


fn plot_camera(w: Float64, h: Float64) -> Camera:
    """The course frame. Where it looks and how far out it stands are the
    mission's business (`frame_course`); the drag and the scroll are the
    viewer's, and multiply what the mission asked for."""
    var span = num(N_SPAN)
    if span <= 0.0:
        span = 900000.0
    return Camera(
        Vec3(num(N_CX), num(N_CY), num(N_CZ)),
        num(N_YAW), num(N_PITCH), span / num(N_ZOOM), 42.0,
    )


def stage_of(m: Mission) -> Int:
    """Which of the four stages the mission is in. The journey has four
    subjects, not one, and each wants a different picture: the Earth it
    leaves, the gulf it crosses, the Moon it arrives at, and the ground it
    lands on."""
    if m.phase == PHASE_DESCENT:
        return 3
    # The sphere of influence is where the Moon takes over the trajectory,
    # so it is where the arrival begins -- a real boundary rather than a
    # number chosen to make the picture change.
    if (m.r - m.moon()).norm() < MOON_SOI or m.phase >= PHASE_LUNAR_ORBIT:
        return 2
    if m.phase <= PHASE_PARKING or m.r.norm() < 60000.0:
        return 0
    return 1


fn stage_name(k: Int) -> String:
    if k == 0:
        return String("Launch")
    if k == 1:
        return String("Translunar")
    if k == 2:
        return String("Lunar arrival")
    return String("Descent")


def frame_course(m: Mission):
    """Point the course view at the stage's subject.

    Three framings for the three stages the course view serves, and the
    camera slides between them rather than cutting, because the distances
    involved change by four orders of magnitude and a cut at that scale
    reads as a fault:

      launch      the Earth, close enough that the parking orbit is an
                  orbit and not a dot on it
      translunar  the midpoint of the Earth-Moon line, standing back far
                  enough to hold both ends and the craft between them
      arrival     the Moon, closing as the craft does, so the hyperbola
                  bending round it is the thing on screen

    A 42-degree field at distance d shows about 0.77 d across, so each
    framing names the extent it must hold and divides. The old fixed
    420 000 km camera on the Earth did neither, which is why the course
    climbed out of the top of the frame."""
    let moon = m.moon()
    let sc = m.r
    let r_earth = sc.norm()
    let d_moon = (sc - moon).norm()
    let reach = moon.norm() if moon.norm() > r_earth else r_earth

    # Leaving: the Earth and whatever orbit is around it.
    let earth_extent = 44000.0
    # Crossing: both bodies, and room round them.
    let cruise_centre = moon * 0.5
    let cruise_extent = reach * 1.25
    # Arriving: the Moon, and the craft beside it.
    let moon_extent = d_moon * 2.4 + 12000.0

    # Launch into the crossing, by how far out the craft has come. The
    # range ends not far past the stage boundary at 60 000 km: a view
    # labelled "Translunar" that does not yet hold the Moon is the label
    # and the picture disagreeing again.
    var a = (r_earth - 30000.0) / 50000.0
    if a < 0.0:
        a = 0.0
    if a > 1.0:
        a = 1.0
    let c1 = cruise_centre * a
    let e1 = earth_extent + (cruise_extent - earth_extent) * a
    # The crossing into the arrival, by how near the Moon it has got. The
    # range is set so the camera is already committed to the Moon as the
    # craft crosses the sphere of influence, and fully on it well before
    # perilune -- a label that says "arrival" over a picture of the whole
    # transfer is the two disagreeing.
    var b = (d_moon - 20000.0) / 80000.0
    if b < 0.0:
        b = 0.0
    if b > 1.0:
        b = 1.0
    let centre = moon + (c1 - moon) * b
    let extent = moon_extent + (e1 - moon_extent) * b

    set_num(N_CX, centre.x)
    set_num(N_CY, centre.y)
    set_num(N_CZ, centre.z)
    set_num(N_SPAN, extent / 0.77)
    set_num(N_MX, moon.x)
    set_num(N_MY, moon.y)
    set_num(N_MZ, moon.z)


def follow_mission(m: Mission):
    """Put the stage's own view in front of the viewer, without taking it
    from them. The camera is re-aimed every frame; the MODE only changes
    when the stage does, so someone who has deliberately opened the
    launch-window map keeps it until the mission moves on."""
    frame_course(m)
    g_mission_phase()[] = m.phase
    let k = stage_of(m)
    if k != g_seenphase()[]:
        g_seenphase()[] = k
        if k == 3:
            set_mode(MODE_DESCENT)
            # Twelve minutes of powered flight is the one part of this
            # worth watching at something near its own pace.
            set_speed(10.0)
        elif g_mode()[] != MODE_TRAJECTORY:
            set_mode(MODE_TRAJECTORY)
    g_dirty()[] = 1


fn draw_trajectory(b: CGRect):
    """Earth, Moon, the planned course and what has been flown of it."""
    let w = b.size.width
    let h = b.size.height
    let cam = plot_camera(w, h)
    let iw = Int(w)
    let ih = Int(h)

    # A frame of reference before anything else: concentric range rings at
    # 100 000 km, so a viewer can put a number on the picture without a
    # scale bar covering it.
    var ring = 100000.0
    while ring < 420000.0:
        var rp = ui.Path()
        var first = True
        for k in range(73):
            let a = Float64(k) * 5.0 * DEG
            let q = cam.project(Vec3(ring * cos(a), ring * sin(a), 0.0), iw, ih)
            if q.ok:
                rp.add(q.x, h - q.y)
            else:
                rp.lift()
        rp.stroke(0.5, ui.quaternary())
        ring += 100000.0

    # The Moon's own path across the plot, dotted -- it moves while the
    # spacecraft is in the air, and a still picture that hides that is
    # what makes lunar transfers look like they aim at where it is.
    if len(g_moon()[]) >= 6:
        var mp = ui.Path()
        var i = 0
        while i + 2 < len(g_moon()[]):
            let q = cam.project(
                Vec3(g_moon()[][i], g_moon()[][i + 1], g_moon()[][i + 2]), iw, ih
            )
            if q.ok:
                mp.add(q.x, h - q.y)
            else:
                mp.lift()
            i += 3
        mp.stroke(1.0, ui.tertiary())

    # The planned course.
    if len(g_arc()[]) >= 6:
        var ap = ui.Path()
        var i = 0
        while i + 2 < len(g_arc()[]):
            let q = cam.project(
                Vec3(g_arc()[][i], g_arc()[][i + 1], g_arc()[][i + 2]), iw, ih
            )
            if q.ok:
                ap.add(q.x, h - q.y)
            else:
                ap.lift()
            i += 3
        ap.stroke(1.5, ui.mix(ui.accent(), ui.control_bg(), 0.35))

    # What has actually been flown, over the top of the plan.
    if len(g_flown()[]) >= 6:
        var fp = ui.Path()
        var i = 0
        while i + 2 < len(g_flown()[]):
            let q = cam.project(
                Vec3(g_flown()[][i], g_flown()[][i + 1], g_flown()[][i + 2]), iw, ih
            )
            if q.ok:
                fp.add(q.x, h - q.y)
            else:
                fp.lift()
            i += 3
        fp.stroke(2.0, ui.orange())

    # The Earth, and the Moon where it is at arrival.
    let e = cam.project(Vec3(0.0, 0.0, 0.0), iw, ih)
    if e.ok:
        let r = cam.focal(ih) * R_EARTH / e.depth
        ui.fill_oval(
            ui.rect(e.x - r, h - e.y - r, 2.0 * r, 2.0 * r),
            ui.rgba(0.18, 0.38, 0.68, 1.0),
        )
        ui.stroke_oval(
            ui.rect(e.x - r, h - e.y - r, 2.0 * r, 2.0 * r), 1.0,
            ui.rgba(0.45, 0.68, 0.95, 0.7),
        )
        ui.text(String("Earth"), e.x + r + 6.0, h - e.y - 6.0, 10.0, ui.secondary())

    # Where the Moon will be when the spacecraft gets there, as an empty
    # ring: the point of the whole exercise is that the transfer is aimed
    # at a place the Moon has not reached yet, and a plot that draws only
    # the Moon's present position makes every lunar trajectory look like a
    # miss.
    let moon_now = Vec3(num(N_MX), num(N_MY), num(N_MZ))
    var craft_far = True
    if len(g_flown()[]) >= 3:
        let k = len(g_flown()[]) - 3
        let cv = Vec3(g_flown()[][k], g_flown()[][k + 1], g_flown()[][k + 2])
        craft_far = (cv - moon_now).norm() > MOON_SOI
    if craft_far:
        let av = Vec3(num(N_AX), num(N_AY), num(N_AZ))
        if av.norm() > 1.0:
            let a = cam.project(av, iw, ih)
            if a.ok:
                var r = cam.focal(ih) * R_MOON / a.depth
                if r < 3.0:
                    r = 3.0
                ui.stroke_oval(
                    ui.rect(a.x - r, h - a.y - r, 2.0 * r, 2.0 * r), 1.0,
                    ui.tertiary(),
                )

    # The Moon itself, where it is at the moment being shown -- it moves,
    # and the spacecraft is aiming ahead of it.
    if moon_now.norm() > 1.0:
        let m = cam.project(moon_now, iw, ih)
        if m.ok:
            var r = cam.focal(ih) * R_MOON / m.depth
            if r < 2.5:
                r = 2.5
            ui.fill_oval(
                ui.rect(m.x - r, h - m.y - r, 2.0 * r, 2.0 * r),
                ui.rgba(0.72, 0.72, 0.70, 1.0),
            )
            ui.text(String("Moon"), m.x + r + 6.0, h - m.y - 6.0, 10.0, ui.secondary())

    # The spacecraft, at the head of what has been flown.
    if len(g_flown()[]) >= 3:
        let n = len(g_flown()[]) - 3
        let s = cam.project(
            Vec3(g_flown()[][n], g_flown()[][n + 1], g_flown()[][n + 2]), iw, ih
        )
        if s.ok:
            ui.dot(s.x, h - s.y, 3.5, ui.orange())
            ui.stroke_oval(
                ui.rect(s.x - 7.0, h - s.y - 7.0, 14.0, 14.0), 1.0, ui.orange()
            )

    if g_exporting()[] == 0:
        ui.text(
            String("100 000 km rings · drag to turn · scroll to zoom"),
            14.0, 12.0, 10.0, ui.tertiary(),
        )
    else:
        ui.text(String("100 000 km rings"), 14.0, 12.0, 10.0, ui.tertiary())


fn draw_map(b: CGRect):
    """The launch window, one cell per day and hour.

    The GPU computes 714 240 candidates -- every launch minute of the month
    against every flight time -- and a chart with 714 240 cells in it is a
    picture of noise. So each cell here is the BEST of the candidates inside
    it: the cheapest total Delta-v over that hour's minutes and every flight
    time, which is the number a planner would actually take. Hatching says
    the corridor refuses the hour; a hollow cell says the site is dark when
    the crew would arrive."""
    let w = b.size.width
    let h = b.size.height
    let days = g_map_days()[]
    if days == 0 or len(g_map()[]) == 0:
        ui.text(String("Replan to compute the window map"), 24.0, h * 0.5, 12.0, ui.secondary())
        return

    let left = 46.0
    let bottom = 42.0
    let top = 34.0
    let right = 16.0
    let gw = w - left - right
    let gh = h - bottom - top
    let cw = gw / Float64(days)
    let ch = gh / 24.0

    ui.text_weight(
        String("Launch window · ") + month_name(choice(C_MONTH)) + " " + String(choice(C_YEAR)),
        left, h - 22.0, 12.0, ui.W_SEMIBOLD, ui.label(),
    )
    ui.text(
        String("cheapest TLI + LOI over every flight time, per hour · solid where the site is lit at touchdown"),
        left, h - 36.0, 10.0, ui.tertiary(),
    )

    # The Delta-v ramp. A literal palette on purpose: this is the picture,
    # not the interface, and a chart whose colours follow the system accent
    # is a chart nobody can describe to anyone else.
    var lo = 1.0e30
    var hi = -1.0e30
    for i in range(len(g_map()[])):
        let v = g_map()[][i]
        if v > 0.0:
            if v < lo:
                lo = v
            if v > hi:
                hi = v
    if hi <= lo:
        hi = lo + 1.0

    for d in range(days):
        for hr in range(24):
            let i = d * 24 + hr
            let v = g_map()[][i]
            let fl = g_mapflag()[][i]
            let x = left + Float64(d) * cw
            let y = bottom + Float64(hr) * ch
            let cell = ui.rect(x, y, cw - 0.5, ch - 0.5)
            if v <= 0.0:
                # No transfer at all from this hour: the plane is out of reach.
                ui.fill_rect(cell, ui.mix(ui.control_bg(), ui.label(), 0.04))
                continue
            let t = (v - lo) / (hi - lo)
            # Cheap is cool and saturated, dear is warm and pale: the eye
            # finds the minimum without reading the legend.
            let colour = ui.rgba(
                0.16 + 0.74 * t, 0.42 + 0.20 * t, 0.78 - 0.52 * t,
                0.32 + 0.55 * (1.0 - t),
            )
            let lit = (fl & 2) != 0
            if lit:
                ui.fill_rect(cell, colour)
            else:
                # Dark at the site when the crew would arrive. Faded rather
                # than hollowed: the Delta-v is still the answer to a real
                # question, and hollowing every unlit cell turned the chart
                # into an outline of itself.
                ui.fill_rect(cell, ui.rgba(0.55, 0.57, 0.60, 0.16))

    # Apollo 11's own cell, crossed.
    if choice(C_YEAR) == 1969 and choice(C_MONTH) == 7 and days >= 16:
        let ax = left + 15.0 * cw + cw * 0.5
        let ay = bottom + 13.0 * ch + ch * 0.5
        ui.line(ax - 7.0, ay - 7.0, ax + 7.0, ay + 7.0, 1.5, ui.label())
        ui.line(ax - 7.0, ay + 7.0, ax + 7.0, ay - 7.0, 1.5, ui.label())
        ui.text(String("Apollo 11"), ax + 10.0, ay - 4.0, 9.0, ui.label())

    # Axes. Every third day and every sixth hour, which is as much as the
    # space carries without the labels colliding.
    ui.hairline(left, bottom - 1.0, gw, 1.0)
    ui.hairline(left - 1.0, bottom, 1.0, gh)
    for d in range(days):
        if d % 3 == 0:
            ui.text_centre(String(d + 1), left + Float64(d) * cw - 6.0, bottom - 16.0, cw + 12.0, 9.0, ui.tertiary())
    for hr in range(0, 24, 6):
        ui.digits_right(
            String(hr) + ":00", 0.0, bottom + Float64(hr) * ch - 3.0, left - 8.0, 9.0, ui.tertiary()
        )
    ui.text(String("day of month"), left + gw * 0.5 - 30.0, 8.0, 9.0, ui.tertiary())

    # Legend.
    let lx = left + gw - 168.0
    ui.text(String("cheap"), lx - 34.0, h - 22.0, 9.0, ui.tertiary())
    for k in range(24):
        let t = Float64(k) / 23.0
        ui.fill_rect(
            ui.rect(lx + Float64(k) * 5.0, h - 22.0, 5.0, 8.0),
            ui.rgba(0.16 + 0.74 * t, 0.42 + 0.20 * t, 0.78 - 0.52 * t, 0.32 + 0.55 * (1.0 - t)),
        )
    ui.text(String("dear"), lx + 124.0, h - 22.0, 9.0, ui.tertiary())


fn month_name(m: Int) -> String:
    var names = List[String]()
    for s in ["January", "February", "March", "April", "May", "June", "July",
              "August", "September", "October", "November", "December"]:
        names.append(String(s))
    if m < 1 or m > 12:
        return String("?")
    return names[m - 1]


fn draw_descent(b: CGRect):
    """The powered descent, as a profile: altitude against the ground still
    to run, with the LM on it and the ground it is choosing between.

    The axes follow the LM down. Powered descent begins 480 km uprange at
    15 km and ends on the footpads, and no single scale serves both ends
    of that -- a chart fixed at the endgame shows nothing at all for ten
    of the twelve minutes, and one fixed at the start ends with the whole
    approach in a pixel. So the extents come from where the LM is, with
    floors, which walks the picture through braking, approach and the
    final descent.

    Close in it stops being a trajectory chart and becomes a landing
    chart: the craters and the boulder fields the guidance is steering
    between, the site, and the aim point the crew have chosen -- which
    moves when they redesignate, and every second of that costs hover."""
    let w = b.size.width
    let h = b.size.height
    let left = 54.0
    let bottom = 46.0
    let top = 54.0
    let gw = w - left - 20.0
    let gh = h - bottom - top

    let live = len(g_dstate()[]) >= D_COUNT and g_dstate()[][D_LIVE] > 0.5
    var x_max = 9000.0
    var y_max = 2600.0
    if live:
        let rr = -g_dstate()[][D_RANGE]
        let aa = g_dstate()[][D_ALT]
        x_max = rr * 1.20
        if x_max < 260.0:
            x_max = 260.0
        y_max = aa * 1.30
        if y_max < 60.0:
            y_max = 60.0
    # Ground BEYOND the site as well: what the crew are flying over is as
    # much the point as what they have crossed, and a redesignation is
    # usually forward.
    var x_ahead = x_max * 0.14
    if x_ahead < 30.0:
        x_ahead = 30.0
    let x_lo = -x_max
    let x_hi = x_ahead
    let close = x_max < 4000.0

    var head = String("Powered descent · ") + landing_name(choice(C_TARGET))
    if live:
        head += "  ·  " + phase_label(Int(g_dstate()[][D_PHASE]))
    ui.text_weight(head, left, h - 22.0, 12.0, ui.W_SEMIBOLD, ui.label())
    if live:
        var sub = String("alt ") + ui.f(g_dstate()[][D_ALT], 0) + " m   down "
        sub += ui.f(g_dstate()[][D_RATE], 1) + " m/s   ground "
        sub += ui.f(g_dstate()[][D_GS], 1) + " m/s   throttle "
        sub += ui.f(g_dstate()[][D_THR] * 100.0, 0) + "%   hover "
        sub += ui.f(g_dstate()[][D_HOVER], 0) + " s"
        if g_dstate()[][D_REDES] > 0.0:
            sub += "   redesignated " + ui.f(g_dstate()[][D_REDES], 0) + "×"
        ui.text(sub, left, h - 36.0, 10.0, ui.secondary())
    else:
        ui.text(
            String("P63 braking · P64 approach · P66 final, from high gate to the probes"),
            left, h - 36.0, 10.0, ui.tertiary(),
        )

    ui.hairline(left, bottom - 1.0, gw, 1.0)
    ui.hairline(left - 1.0, bottom, 1.0, gh)
    for k in range(0, 5):
        let a = Float64(k) / 4.0
        let av = y_max * a
        ui.digits_right(
            (ui.f(av, 0) + " m") if y_max < 3000.0 else (ui.f(av / 1000.0, 1) + " km"),
            0.0, bottom + gh * a - 4.0, left - 8.0, 9.0, ui.tertiary(),
        )
        if k > 0:
            ui.fill_rect(ui.rect(left, bottom + gh * a, gw, 0.5), ui.quaternary())
    for k in range(0, 4):
        let a = Float64(k) / 3.0
        let rv = -(x_lo + (x_hi - x_lo) * a)
        ui.text_centre(
            (ui.f(rv, 0) + " m") if x_max < 12000.0 else (ui.f(rv / 1000.0, 0) + " km"),
            left + gw * a - 24.0, bottom - 16.0, 48.0, 9.0, ui.tertiary(),
        )

    # The planned profile, over its own nine kilometres, through whatever
    # the axes currently are.
    let hg = high_gate()
    let lg = low_gate()
    var prof = ui.Path()
    let n = 140
    for k in range(n + 1):
        let along = x_lo + (x_hi - x_lo) * Float64(k) / Float64(n)
        let rng = -along
        var alt = 0.0
        if rng > 9000.0:
            prof.lift()
            continue
        if rng > -hg.x:
            let u = (rng + hg.x) / (9000.0 + hg.x)
            alt = hg.z + (2600.0 - hg.z) * u * u
        elif rng > -lg.x:
            let u = (rng + lg.x) / (-hg.x + lg.x)
            alt = lg.z + (hg.z - lg.z) * u * u
        elif rng > 0.0:
            let u = rng / (-lg.x)
            alt = lg.z * u * u
        if alt <= y_max * 1.05:
            prof.add(left + gw * Float64(k) / Float64(n), bottom + gh * alt / y_max)
        else:
            prof.lift()
    prof.stroke(1.5, ui.mix(ui.accent(), ui.control_bg(), 0.45) if live else ui.accent())

    for g in [hg, lg]:
        let rng = -g.x
        if rng <= x_max and g.z <= y_max:
            let gx = left + gw * (-g.x - x_lo) / (x_hi - x_lo)
            let gy = bottom + gh * g.z / y_max
            ui.dot(gx, gy, 3.0, ui.label())
            ui.line(gx, bottom, gx, gy, 0.5, ui.quaternary())
            ui.text(
                (String("high gate") if g.z > 1000.0 else String("low gate"))
                + "  " + ui.f(g.z, 0) + " m",
                gx + 6.0, gy + 8.0, 9.0, ui.secondary(),
            )

    # The ground, at the LM's own cross-range.
    let site = landing_sites()[choice(C_TARGET)]
    var ground = Terrain(site.lat, site.lon, False)
    let band = 34.0
    var exag = 0.28
    if live and y_max < 1200.0:
        exag = gh / y_max * 0.55
    var gp = ui.Path()
    for k in range(0, 241):
        let along = x_lo + (x_hi - x_lo) * Float64(k) / 240.0
        let hgt = ground.height(along, 0.0)
        gp.add(left + gw * Float64(k) / 240.0, bottom + band * 0.5 + hgt * exag)
    gp.stroke(1.25, ui.secondary())
    ui.fill_rect(ui.rect(left, bottom, gw, 0.5), ui.quaternary())

    # Close in, the hazards the guidance is steering between: the craters
    # as spans on the ground line, the boulder fields under them, the site
    # and the aim point the crew have settled on.
    if close:
        for i in range(len(ground.fields) // 4):
            let fx = ground.fields[i * 4]
            let fr = ground.fields[i * 4 + 2]
            if fx + fr > x_lo and fx - fr < x_hi:
                let ax = left + gw * (fx - fr - x_lo) / (x_hi - x_lo)
                let bx = left + gw * (fx + fr - x_lo) / (x_hi - x_lo)
                ui.fill_rect(ui.rect(ax, bottom + 3.0, bx - ax, 3.0), ui.mix(ui.orange(), ui.control_bg(), 0.5))
        for i in range(len(ground.craters) // 4):
            let cx = ground.craters[i * 4]
            let cr = ground.craters[i * 4 + 2]
            if cx + cr > x_lo and cx - cr < x_hi:
                let ax = left + gw * (cx - cr - x_lo) / (x_hi - x_lo)
                let bx = left + gw * (cx + cr - x_lo) / (x_hi - x_lo)
                ui.fill_rect(ui.rect(ax, bottom + 8.0, bx - ax, 2.5), ui.rgba(0.85, 0.25, 0.25, 0.85))
        ui.text(String("craters · boulder fields"), left + 6.0, bottom + 14.0, 9.0, ui.tertiary())
        let sx = left + gw * (0.0 - x_lo) / (x_hi - x_lo)
        ui.line(sx, bottom, sx, bottom + gh * 0.5, 1.0, ui.mix(ui.accent(), ui.control_bg(), 0.5))
        ui.text(landing_name(choice(C_TARGET)), sx + 5.0, bottom + gh * 0.5 - 10.0, 9.0, ui.secondary())
        if live:
            let aim = g_dstate()[][D_AIM]
            if aim > x_lo and aim < x_hi:
                let ax = left + gw * (aim - x_lo) / (x_hi - x_lo)
                ui.line(ax, bottom, ax, bottom + gh * 0.34, 1.5, ui.orange())
                ui.dot(ax, bottom + gh * 0.34, 3.0, ui.orange())
                ui.text(String("aim"), ax + 5.0, bottom + gh * 0.34 - 4.0, 9.0, ui.orange())

    # What has actually been flown, and the LM at the head of it.
    if live:
        var fp = ui.Path()
        var i = 0
        var started = False
        while i + 1 < len(g_dtrail()[]):
            let along = g_dtrail()[][i]
            let alt = g_dtrail()[][i + 1]
            if along >= x_lo and along <= x_hi and alt <= y_max * 1.2:
                fp.add(left + gw * (along - x_lo) / (x_hi - x_lo), bottom + gh * alt / y_max)
                started = True
            elif started:
                fp.lift()
            i += 2
        fp.stroke(2.0, ui.orange())
        let along = g_dstate()[][D_RANGE]
        let alt = g_dstate()[][D_ALT]
        if along >= x_lo and along <= x_hi:
            let lx = left + gw * (along - x_lo) / (x_hi - x_lo)
            var ly = bottom + gh * alt / y_max
            if ly > bottom + gh:
                ly = bottom + gh
            ui.dot(lx, ly, 3.5, ui.orange())
            ui.stroke_oval(ui.rect(lx - 7.0, ly - 7.0, 14.0, 14.0), 1.0, ui.orange())
            let fl = 8.0 + 26.0 * g_dstate()[][D_THR]
            ui.line(lx, ly, lx, ly - fl, 2.0, ui.mix(ui.orange(), ui.control_bg(), 0.35))
        if Int(g_dstate()[][D_ALARM]) == 1:
            ui.text_weight(
                String("1202 PROGRAM ALARM   ⌘G go   ⌘K abort"),
                left + 8.0, bottom + gh * 0.80, 12.0, ui.W_SEMIBOLD,
                ui.rgba(0.85, 0.22, 0.22, 1.0),
            )
        elif Int(g_dstate()[][D_PHASE]) < 3:
            ui.text(
                String("⌘. aborts the descent"),
                left + 8.0, bottom + gh * 0.80, 9.0, ui.tertiary(),
            )
        if Int(g_dstate()[][D_PHASE]) == 3:
            ui.text(
                String("down ") + ui.f(g_dstate()[][D_CONTACT], 2) + " m/s · "
                + ui.f(g_dstate()[][D_LANDX], 0) + " m from the site",
                left + 8.0, bottom + gh * 0.62, 10.0, ui.label(),
            )
    else:
        ui.text(
            String("terrain along the approach · ±60 m about the mean"),
            left + 8.0, bottom + band + 2.0, 9.0, ui.tertiary(),
        )


fn landing_name(i: Int) -> String:
    let sites = landing_sites()
    if i < 0 or i >= len(sites):
        return String("?")
    return sites[i].name


class PlannerPlotView(NSView):
    """The canvas. One view, three pictures, chosen by the toolbar."""

    def drawRect_(self, dirty: CGRect):
        let b = Obj["NSView"](ObjCObject(g_view()[]).addr()).bounds()
        ui.fill_rect(b, ui.control_bg())
        let mode = g_mode()[]
        if mode == MODE_TRAJECTORY:
            draw_trajectory(b)
        elif mode == MODE_MAP:
            draw_map(b)
        else:
            draw_descent(b)

    def isFlipped(self) -> Bool:
        return False

    def acceptsFirstResponder(self) -> Bool:
        return True

    def mouseDragged_(self, event: ObjCObject):
        let dx = Obj["NSEvent"](event.addr()).deltaX()
        let dy = Obj["NSEvent"](event.addr()).deltaY()
        set_num(N_YAW, num(N_YAW) + dx * 0.4)
        var p = num(N_PITCH) + dy * 0.4
        if p > 88.0:
            p = 88.0
        if p < -88.0:
            p = -88.0
        set_num(N_PITCH, p)
        g_dirty()[] = 1

    def scrollWheel_(self, event: ObjCObject):
        let dy = Obj["NSEvent"](event.addr()).deltaY()
        var z = num(N_ZOOM) * (1.0 + dy * 0.04)
        if z < 0.35:
            z = 0.35
        if z > 12.0:
            z = 12.0
        set_num(N_ZOOM, z)
        g_dirty()[] = 1


# ── the application's classes ────────────────────────────────────────────


class PlannerDelegate:
    def applicationShouldTerminateAfterLastWindowClosed_(
        self, sender: ObjCObject
    ) -> Bool:
        return True


comptime TB_REPLAN = "planner.replan"
comptime TB_FLY = "planner.fly"
comptime TB_VIEW = "planner.view"
comptime TB_SPEED = "planner.speed"
comptime TB_EXPORT = "planner.export"


def toolbar_ids_object() -> ObjCObject:
    let ids = Cls["NSMutableArray"]().array()
    for name in [
        String(TB_REPLAN),
        String(TB_FLY),
        String(TB_SPEED),
        String("NSToolbarFlexibleSpaceItem"),
        String(TB_VIEW),
        String("NSToolbarFlexibleSpaceItem"),
        String(TB_EXPORT),
    ]:
        Obj["NSMutableArray"](ids.addr()).addObject(nsstring(name).ptr())
    return ids


class PlannerActions:
    """Toolbar delegate, table data sources, and every control's target.

    A callback only ever sets a flag or a number; the pump does the work.
    Replanning takes tens of milliseconds and runs a GPU kernel, and doing
    that inside a control's action would do it on AppKit's stack, in the
    middle of a tracking loop."""

    # ── controls ──────────────────────────────────────────────────────

    def plannerReplan_(self, sender: ObjCObject):
        g_cmd()[] = g_cmd()[] | CMD_REPLAN

    def plannerFly_(self, sender: ObjCObject):
        g_cmd()[] = g_cmd()[] | CMD_FLY

    def plannerReset_(self, sender: ObjCObject):
        g_cmd()[] = g_cmd()[] | CMD_RESET

    def plannerExport_(self, sender: ObjCObject):
        g_cmd()[] = g_cmd()[] | CMD_EXPORT

    def plannerAbort_(self, sender: ObjCObject):
        g_cmd()[] = g_cmd()[] | CMD_ABORT

    def plannerGo_(self, sender: ObjCObject):
        g_cmd()[] = g_cmd()[] | CMD_GO

    def plannerNoGo_(self, sender: ObjCObject):
        g_cmd()[] = g_cmd()[] | CMD_NOGO

    def plannerSpeedChanged_(self, sender: ObjCObject):
        let i = Obj["NSPopUpButton"](sender.addr()).indexOfSelectedItem()
        set_num(N_WARP, speed_rate(i))

    def plannerViewChanged_(self, sender: ObjCObject):
        g_mode()[] = Obj["NSSegmentedControl"](sender.addr()).selectedSegment()
        g_dirty()[] = 1

    def plannerModeTrajectory_(self, sender: ObjCObject):
        set_mode(MODE_TRAJECTORY)

    def plannerModeMap_(self, sender: ObjCObject):
        set_mode(MODE_MAP)

    def plannerModeDescent_(self, sender: ObjCObject):
        set_mode(MODE_DESCENT)

    def plannerPadChanged_(self, sender: ObjCObject):
        set_choice(C_PAD, Obj["NSPopUpButton"](sender.addr()).indexOfSelectedItem())
        g_cmd()[] = g_cmd()[] | CMD_REPLAN

    def plannerTargetChanged_(self, sender: ObjCObject):
        set_choice(C_TARGET, Obj["NSPopUpButton"](sender.addr()).indexOfSelectedItem())
        g_cmd()[] = g_cmd()[] | CMD_REPLAN

    def plannerMccChanged_(self, sender: ObjCObject):
        set_choice(C_MCC, Obj["NSPopUpButton"](sender.addr()).indexOfSelectedItem())

    def plannerTofChanged_(self, sender: ObjCObject):
        let v = Obj["NSSlider"](sender.addr()).doubleValue()
        set_choice(C_TOF, Int(v * 10.0 + 0.5))
        # Live while dragging, replanned when the drag ends: a Lambert solve
        # per pixel of travel would make the slider stutter.
        if not Obj["NSEvent"](
            Cls["NSApplication"]().sharedApplication().currentEvent().addr()
        ).isARepeat():
            g_cmd()[] = g_cmd()[] | CMD_REPLAN

    # ── the sidebar and the inspector ─────────────────────────────────

    def numberOfRowsInTableView_(self, table: ObjCObject) -> Int:
        if table.addr() == g_sidebar()[]:
            return len(g_phases()[])
        return shown_count()

    def tableView_objectValueForTableColumn_row_(
        self, table: ObjCObject, column: ObjCObject, row: Int
    ) -> ObjCObject:
        if table.addr() == g_sidebar()[]:
            if row < 0 or row >= len(g_phases()[]):
                return nsstring(String(""))
            return nsstring(g_phases()[][row])
        if row < 0 or row >= shown_count():
            return nsstring(String(""))
        let ident = ns_to_string(
            ObjCObject(Obj["NSTableColumn"](column.addr()).identifier().id)
        )
        let kind = shown_at(row, 0)
        if ident == "label":
            return nsstring(shown_at(row, 1).upper() if kind == "h" else shown_at(row, 1))
        return nsstring(shown_at(row, 2))

    def tableView_willDisplayCell_forTableColumn_row_(
        self, table: ObjCObject, cell: ObjCObject, column: ObjCObject, row: Int
    ):
        """Typography carries the structure: a group header is small, semi-
        bold and tertiary; a value is monospaced-digit so the column lines
        up; a violated rule is the system red, which is also the red the
        user has configured for accessibility."""
        if table.addr() == g_sidebar()[]:
            Obj["NSCell"](cell.addr()).setFont(
                Cls["NSFont"]().systemFontOfSize_weight(12.0, ui.W_REGULAR).ptr()
            )
            return
        if row < 0 or row >= shown_count():
            return
        let kind = shown_at(row, 0)
        let state = shown_at(row, 3)
        let ident = ns_to_string(
            ObjCObject(Obj["NSTableColumn"](column.addr()).identifier().id)
        )
        if kind == "h":
            Obj["NSCell"](cell.addr()).setFont(
                Cls["NSFont"]().systemFontOfSize_weight(10.0, ui.W_SEMIBOLD).ptr()
            )
            Obj["NSTextFieldCell"](cell.addr()).setTextColor(ui.tertiary().ptr())
            return
        if ident == "label":
            Obj["NSCell"](cell.addr()).setFont(
                Cls["NSFont"]().systemFontOfSize_weight(11.0, ui.W_REGULAR).ptr()
            )
            Obj["NSTextFieldCell"](cell.addr()).setTextColor(ui.secondary().ptr())
            return
        var weight = ui.W_REGULAR
        if state == "b":
            weight = ui.W_SEMIBOLD
        Obj["NSCell"](cell.addr()).setFont(
            Cls["NSFont"]().monospacedDigitSystemFontOfSize_weight(11.0, weight).ptr()
        )
        var colour = ui.label()
        if state == "r":
            colour = ui.red()
        elif state == "a":
            colour = ui.orange()
        elif state == "g":
            colour = ui.green()
        Obj["NSTextFieldCell"](cell.addr()).setTextColor(colour.ptr())

    def tableViewSelectionDidChange_(self, note: ObjCObject):
        let table = Obj["NSNotification"](note.addr()).object()
        if table.addr() != g_sidebar()[]:
            return
        let row = Obj["NSTableView"](table.addr()).selectedRow()
        if row >= 0:
            g_phase_sel()[] = row
            rebuild_visible()
            if g_table()[] != 0:
                Obj["NSTableView"](ObjCObject(g_table()[]).addr()).reloadData()

    # ── toolbar delegate ──────────────────────────────────────────────

    def toolbarAllowedItemIdentifiers_(self, tb: ObjCObject) -> ObjCObject:
        return toolbar_ids_object()

    def toolbarDefaultItemIdentifiers_(self, tb: ObjCObject) -> ObjCObject:
        return toolbar_ids_object()

    def toolbar_itemForItemIdentifier_willBeInsertedIntoToolbar_(
        self, toolbar: ObjCObject, ident: ObjCObject, inserted: Bool
    ) -> ObjCObject:
        with autoreleasepool():
            var item = Cls["NSToolbarItem"]().alloc()
            item = Obj["NSToolbarItem"](item.addr()).initWithItemIdentifier(ident)
            let owner = ObjCObject(g_actions()[])

            # The view switcher is a segmented control, which is what every
            # Mac application with three views of one document uses -- Xcode's
            # editor modes, Preview's markup, Maps.
            if Obj["NSString"](ident.addr()).isEqualToString(
                nsstring(String(TB_VIEW)).ptr()
            ):
                var seg = Cls["NSSegmentedControl"]().alloc()
                seg = Obj["NSSegmentedControl"](seg.addr()).initWithFrame(
                    ui.rect(0.0, 0.0, 260.0, 24.0)
                )
                Obj["NSSegmentedControl"](seg.addr()).setSegmentCount(Int(3))
                Obj["NSSegmentedControl"](seg.addr()).setSegmentStyle(Int(8))
                Obj["NSSegmentedControl"](seg.addr()).setTrackingMode(Int(0))
                var labels = List[String]()
                labels.append(String("Trajectory"))
                labels.append(String("Window Map"))
                labels.append(String("Descent"))
                for k in range(3):
                    Obj["NSSegmentedControl"](seg.addr()).setLabel_forSegment(
                        nsstring(labels[k]).ptr(), k
                    )
                    Obj["NSSegmentedControl"](seg.addr()).setWidth_forSegment(
                        Float64(86.0), k
                    )
                Obj["NSSegmentedControl"](seg.addr()).setSelectedSegment(
                    g_mode()[]
                )
                Obj["NSControl"](seg.addr()).setTarget(owner.ptr())
                Obj["NSControl"](seg.addr()).setAction(
                    sel["plannerViewChanged:"]().ptr()
                )
                Obj["NSToolbarItem"](item.addr()).setView(seg.ptr())
                Obj["NSToolbarItem"](item.addr()).setLabel(
                    nsstring(String("View")).ptr()
                )
                _ = external_call["objc_retain", P](seg.ptr())
                g_seg()[] = seg.addr()
                return item

            # The playback rate. A pop-up rather than a slider: the useful
            # rates are decades apart, and a slider would spend most of its
            # travel on values nobody wants.
            if Obj["NSString"](ident.addr()).isEqualToString(
                nsstring(String(TB_SPEED)).ptr()
            ):
                var pop = Cls["NSPopUpButton"]().alloc()
                pop = Obj["NSPopUpButton"](pop.addr()).initWithFrame_pullsDown(
                    ui.rect(0.0, 0.0, 124.0, 24.0), False
                )
                for k in range(speed_count()):
                    Obj["NSPopUpButton"](pop.addr()).addItemWithTitle(
                        nsstring(speed_label(k)).ptr()
                    )
                Obj["NSPopUpButton"](pop.addr()).selectItemAtIndex(
                    speed_index_of(num(N_WARP))
                )
                Obj["NSControl"](pop.addr()).setControlSize(Int(1))
                Obj["NSPopUpButton"](pop.addr()).setFont(
                    Cls["NSFont"]().monospacedDigitSystemFontOfSize_weight(
                        11.0, ui.W_REGULAR
                    ).ptr()
                )
                Obj["NSControl"](pop.addr()).setTarget(owner.ptr())
                Obj["NSControl"](pop.addr()).setAction(
                    sel["plannerSpeedChanged:"]().ptr()
                )
                Obj["NSToolbarItem"](item.addr()).setView(pop.ptr())
                Obj["NSToolbarItem"](item.addr()).setLabel(
                    nsstring(String("Speed")).ptr()
                )
                _ = external_call["objc_retain", P](pop.ptr())
                g_speedpop()[] = pop.addr()
                return item

            var title = String("")
            var symbol = String("")
            var action = sel["plannerReplan:"]()
            if Obj["NSString"](ident.addr()).isEqualToString(
                nsstring(String(TB_REPLAN)).ptr()
            ):
                title = String("Replan")
                symbol = String("arrow.triangle.2.circlepath")
                action = sel["plannerReplan:"]()
            elif Obj["NSString"](ident.addr()).isEqualToString(
                nsstring(String(TB_FLY)).ptr()
            ):
                title = String("Fly")
                symbol = String("play.fill")
                action = sel["plannerFly:"]()
            elif Obj["NSString"](ident.addr()).isEqualToString(
                nsstring(String(TB_EXPORT)).ptr()
            ):
                title = String("Export")
                symbol = String("square.and.arrow.up")
                action = sel["plannerExport:"]()
            else:
                return item

            Obj["NSToolbarItem"](item.addr()).setLabel(nsstring(title).ptr())
            Obj["NSToolbarItem"](item.addr()).setToolTip(nsstring(title).ptr())
            let image = Cls["NSImage"]().imageWithSystemSymbolName_accessibilityDescription(
                nsstring(symbol).ptr(), nsstring(title).ptr()
            )
            if image.addr() != 0:
                Obj["NSToolbarItem"](item.addr()).setImage(image.ptr())
            Obj["NSToolbarItem"](item.addr()).setTarget(owner.ptr())
            Obj["NSToolbarItem"](item.addr()).setAction(action.ptr())
            if Obj["NSString"](ident.addr()).isEqualToString(
                nsstring(String(TB_FLY)).ptr()
            ):
                _ = external_call["objc_retain", P](item.ptr())
                g_flybtn()[] = item.addr()
            return item


fn set_mode(m: Int):
    g_mode()[] = m
    if g_seg()[] != 0:
        Obj["NSSegmentedControl"](ObjCObject(g_seg()[]).addr()).setSelectedSegment(m)
    g_dirty()[] = 1


# ── the menu bar ─────────────────────────────────────────────────────────
#
# A Mac application without one is a window that happens to be running. It
# is also where the keyboard lives: ⌘R replans, ⌘⏎ flies, ⌘1..3 switch the
# view. None of that is drawn anywhere, and all of it is discoverable,
# which is the whole argument for menus over a legend along the bottom.


def add_item(menu: ObjCObject, title: String, action: SEL, key: String, target: Int):
    var item = Cls["NSMenuItem"]().alloc()
    item = Obj["NSMenuItem"](item.addr()).initWithTitle_action_keyEquivalent(
        nsstring(title).ptr(), action.ptr(), nsstring(key).ptr()
    )
    if target != 0:
        Obj["NSMenuItem"](item.addr()).setTarget(ObjCObject(target).ptr())
    Obj["NSMenu"](menu.addr()).addItem(item.ptr())


def add_separator(menu: ObjCObject):
    Obj["NSMenu"](menu.addr()).addItem(
        Cls["NSMenuItem"]().separatorItem().ptr()
    )


def add_submenu(bar: ObjCObject, title: String) -> ObjCObject:
    var item = Cls["NSMenuItem"]().alloc()
    item = Obj["NSMenuItem"](item.addr()).initWithTitle_action_keyEquivalent(
        nsstring(title).ptr(), ObjCObject(0).ptr(), nsstring(String("")).ptr()
    )
    var menu = Cls["NSMenu"]().alloc()
    menu = Obj["NSMenu"](menu.addr()).initWithTitle(nsstring(title).ptr())
    Obj["NSMenuItem"](item.addr()).setSubmenu(menu.ptr())
    Obj["NSMenu"](bar.addr()).addItem(item.ptr())
    _ = external_call["objc_retain", P](menu.ptr())
    return menu


def build_menu_bar(app: ObjCObject, actions: Int):
    var bar = Cls["NSMenu"]().alloc()
    bar = Obj["NSMenu"](bar.addr()).initWithTitle(nsstring(String("MainMenu")).ptr())

    let appmenu = add_submenu(bar, String("Mission Planner"))
    add_item(appmenu, String("About Mission Planner"), sel["orderFrontStandardAboutPanel:"](), String(""), 0)
    add_separator(appmenu)
    add_item(appmenu, String("Hide Mission Planner"), sel["hide:"](), String("h"), 0)
    add_separator(appmenu)
    add_item(appmenu, String("Quit Mission Planner"), sel["terminate:"](), String("q"), 0)

    let filemenu = add_submenu(bar, String("File"))
    add_item(filemenu, String("Export Plot…"), sel["plannerExport:"](), String("e"), actions)

    let mission = add_submenu(bar, String("Mission"))
    add_item(mission, String("Replan"), sel["plannerReplan:"](), String("r"), actions)
    add_item(mission, String("Fly / Hold"), sel["plannerFly:"](), String("\r"), actions)
    add_separator(mission)
    add_item(mission, String("Reset to Launch"), sel["plannerReset:"](), String("R"), actions)
    add_separator(mission)
    # The calls the trench actually makes once the LM is on the way down.
    add_item(mission, String("Alarm: GO"), sel["plannerGo:"](), String("g"), actions)
    add_item(mission, String("Alarm: NO-GO"), sel["plannerNoGo:"](), String("k"), actions)
    add_item(mission, String("ABORT Descent"), sel["plannerAbort:"](), String("."), actions)

    let view = add_submenu(bar, String("View"))
    add_item(view, String("Trajectory"), sel["plannerModeTrajectory:"](), String("1"), actions)
    add_item(view, String("Launch Window Map"), sel["plannerModeMap:"](), String("2"), actions)
    add_item(view, String("Powered Descent"), sel["plannerModeDescent:"](), String("3"), actions)

    _ = add_submenu(bar, String("Window"))

    Obj["NSApplication"](app.addr()).setMainMenu(bar.ptr())
    _ = external_call["objc_retain", P](bar.ptr())


# ── controls ─────────────────────────────────────────────────────────────


def make_label(s: String, r: CGRect) -> ObjCObject:
    let f = Cls["NSTextField"]().labelWithString(nsstring(s).ptr())
    Obj["NSView"](f.addr()).setFrame(r)
    Obj["NSTextField"](f.addr()).setFont(
        Cls["NSFont"]().systemFontOfSize_weight(10.0, ui.W_SEMIBOLD).ptr()
    )
    Obj["NSTextField"](f.addr()).setTextColor(ui.tertiary().ptr())
    return f


def make_popup(r: CGRect, items: List[String], selected: Int, action: SEL, owner: Int) -> ObjCObject:
    var p = Cls["NSPopUpButton"]().alloc()
    p = Obj["NSPopUpButton"](p.addr()).initWithFrame_pullsDown(r, False)
    for i in range(len(items)):
        Obj["NSPopUpButton"](p.addr()).addItemWithTitle(nsstring(items[i]).ptr())
    Obj["NSPopUpButton"](p.addr()).selectItemAtIndex(selected)
    Obj["NSControl"](p.addr()).setTarget(ObjCObject(owner).ptr())
    Obj["NSControl"](p.addr()).setAction(action.ptr())
    Obj["NSControl"](p.addr()).setControlSize(Int(1))
    Obj["NSPopUpButton"](p.addr()).setFont(
        Cls["NSFont"]().systemFontOfSize_weight(11.0, ui.W_REGULAR).ptr()
    )
    return p


# ── the window ───────────────────────────────────────────────────────────


comptime STATUS_H = 26.0
comptime SIDEBAR_W = 186.0
comptime INSPECTOR_W = 292.0
comptime CONTROLS_H = 164.0
comptime LOG_H = 168.0


def make_table(frame: CGRect, actions: Int, sidebar: Bool) -> ObjCObject:
    """A cell-based table: one column for a source list, two for the plan
    sheet. Cell-based because the delegate does not implement
    tableView:viewForTableColumn:row:, which is what AppKit looks for to
    decide -- and a column built in code with no data cell crashes on the
    first draw, a long way from the column that lacks one."""
    var t = Cls["NSTableView"]().alloc()
    t = Obj["NSTableView"](t.addr()).initWithFrame(frame)
    Obj["NSTableView"](t.addr()).setStyle(Int(1) if sidebar else Int(0))
    Obj["NSTableView"](t.addr()).setHeaderView(ObjCObject(0).ptr())
    Obj["NSTableView"](t.addr()).setRowHeight(Float64(22.0) if sidebar else Float64(19.0))
    Obj["NSTableView"](t.addr()).setIntercellSpacing(CGSize(6.0, 1.0))
    Obj["NSTableView"](t.addr()).setAllowsEmptySelection(True)
    Obj["NSView"](t.addr()).setFocusRingType(Int(1))
    if sidebar:
        # A source list draws on the window's own material, so the table must
        # not paint a background over it -- that opaque rectangle is what
        # made the sidebar read as a box sitting in the window rather than
        # as part of it.
        Obj["NSTableView"](t.addr()).setBackgroundColor(
            Cls["NSColor"]().clearColor().ptr()
        )
        Obj["NSTableView"](t.addr()).setGridStyleMask(Int(0))
    if not sidebar:
        Obj["NSTableView"](t.addr()).setSelectionHighlightStyle(Int(-1))
        Obj["NSTableView"](t.addr()).setBackgroundColor(ui.control_bg().ptr())
        Obj["NSTableView"](t.addr()).setGridStyleMask(Int(0))

    var names = List[String]()
    var widths = List[Float64]()
    if sidebar:
        names.append(String("name"))
        widths.append(frame.size.width - 16.0)
    else:
        names.append(String("label"))
        widths.append(126.0)
        names.append(String("value"))
        widths.append(frame.size.width - 126.0 - 26.0)
    for i in range(len(names)):
        var col = Cls["NSTableColumn"]().alloc()
        col = Obj["NSTableColumn"](col.addr()).initWithIdentifier(
            nsstring(names[i]).ptr()
        )
        Obj["NSTableColumn"](col.addr()).setWidth(widths[i])
        var cell = Cls["NSTextFieldCell"]().alloc()
        cell = Obj["NSTextFieldCell"](cell.addr()).initTextCell(
            nsstring(String("")).ptr()
        )
        Obj["NSCell"](cell.addr()).setEditable(False)
        if names[i] == "value":
            Obj["NSTextFieldCell"](cell.addr()).setAlignment(Int(1))
        Obj["NSTableColumn"](col.addr()).setDataCell(cell.ptr())
        Obj["NSTableView"](t.addr()).addTableColumn(col.ptr())
    Obj["NSTableView"](t.addr()).setDataSource(ObjCObject(actions).ptr())
    Obj["NSTableView"](t.addr()).setDelegate(ObjCObject(actions).ptr())
    _ = external_call["objc_retain", P](t.ptr())
    return t


def build_controls(frame: CGRect, actions: Int) -> ObjCObject:
    """The choices, as a group at the top of the inspector -- where Xcode,
    Pages and Sketch all keep the thing you change, above the thing it
    changes."""
    var box = Cls["NSView"]().alloc()
    box = Obj["NSView"](box.addr()).initWithFrame(frame)
    Obj["NSView"](box.addr()).setAutoresizingMask(Int(2 | 8))

    let w = frame.size.width
    var y = frame.size.height - 22.0

    Obj["NSView"](box.addr()).addSubview(
        make_label(String("LAUNCH SITE"), ui.rect(16.0, y, w - 32.0, 14.0)).ptr()
    )
    y -= 24.0
    var pads = List[String]()
    for s in launch_sites():
        pads.append(s.name)
    let pad = make_popup(
        ui.rect(14.0, y, w - 28.0, 22.0), pads, choice(C_PAD),
        sel["plannerPadChanged:"](), actions,
    )
    Obj["NSView"](box.addr()).addSubview(pad.ptr())

    y -= 30.0
    Obj["NSView"](box.addr()).addSubview(
        make_label(String("LANDING SITE"), ui.rect(16.0, y, w - 32.0, 14.0)).ptr()
    )
    y -= 24.0
    var targets = List[String]()
    for s in landing_sites():
        targets.append(s.name)
    let tgt = make_popup(
        ui.rect(14.0, y, w - 28.0, 22.0), targets, choice(C_TARGET),
        sel["plannerTargetChanged:"](), actions,
    )
    Obj["NSView"](box.addr()).addSubview(tgt.ptr())

    y -= 30.0
    Obj["NSView"](box.addr()).addSubview(
        make_label(String("FLIGHT TIME"), ui.rect(16.0, y, 100.0, 14.0)).ptr()
    )
    y -= 22.0
    var sl = Cls["NSSlider"]().alloc()
    sl = Obj["NSSlider"](sl.addr()).initWithFrame(ui.rect(14.0, y, w - 28.0, 20.0))
    Obj["NSSlider"](sl.addr()).setMinValue(Float64(60.0))
    Obj["NSSlider"](sl.addr()).setMaxValue(Float64(120.0))
    Obj["NSSlider"](sl.addr()).setDoubleValue(Float64(choice(C_TOF)) / 10.0)
    Obj["NSSlider"](sl.addr()).setNumberOfTickMarks(Int(13))
    Obj["NSSlider"](sl.addr()).setAllowsTickMarkValuesOnly(False)
    Obj["NSControl"](sl.addr()).setControlSize(Int(1))
    Obj["NSControl"](sl.addr()).setTarget(ObjCObject(actions).ptr())
    Obj["NSControl"](sl.addr()).setAction(sel["plannerTofChanged:"]().ptr())
    Obj["NSView"](box.addr()).addSubview(sl.ptr())

    _ = external_call["objc_retain", P](box.ptr())
    return box


def build_window(actions: Int) -> ObjCObject:
    """Toolbar, three panes, a log under the plot, a status line.

    Toolbar FIRST: installing one changes the content view's height, and
    every frame below is computed from that height."""
    let screen = Cls["NSScreen"]().mainScreen()
    var vis = ui.rect(0.0, 0.0, 1440.0, 900.0)
    if screen.addr() != 0:
        vis = Obj["NSScreen"](screen.addr()).visibleFrame()
    let iw = min(1320.0, vis.size.width * 0.80)
    let ih = min(860.0, vis.size.height * 0.86)

    let wnd = Obj["NSWindow"](
        contentRect=ui.rect(0.0, 0.0, iw, ih),
        styleMask=(
            nsenum["NSWindowStyleMaskTitled"]()
            | nsenum["NSWindowStyleMaskClosable"]()
            | nsenum["NSWindowStyleMaskMiniaturizable"]()
            | nsenum["NSWindowStyleMaskResizable"]()
        ),
        backing=nsenum["NSBackingStoreBuffered"](),
        defer=False,
    )
    var win = ObjCObject(wnd.id)
    wnd.setMinSize(CGSize(980.0, 620.0))
    wnd.setTitle(nsstring(String("Mission Planner")).ptr())
    # The subtitle is where a Mac window says which document it is: the
    # title stays the application, the subtitle carries the mission.
    wnd.setSubtitle(nsstring(String("Apollo 11 · Tranquility Base")).ptr())
    wnd.setReleasedWhenClosed(False)
    let restored = wnd.setFrameUsingName(nsstring(String("planner.main")).ptr())
    if not restored:
        wnd.center()
    _ = wnd.setFrameAutosaveName(nsstring(String("planner.main")).ptr())
    g_window()[] = win.addr()

    var toolbar = Cls["NSToolbar"]().alloc()
    toolbar = Obj["NSToolbar"](toolbar.addr()).initWithIdentifier(
        nsstring(String("planner.toolbar")).ptr()
    )
    Obj["NSToolbar"](toolbar.addr()).setDelegate(ObjCObject(actions).ptr())
    Obj["NSToolbar"](toolbar.addr()).setDisplayMode(Int(0))
    Obj["NSWindow"](win.addr()).setToolbar(toolbar.ptr())

    let content = Obj["NSWindow"](win.addr()).contentView()
    let bounds = Obj["NSView"](content.addr()).bounds()
    let w = bounds.size.width
    let h = bounds.size.height
    let body_h = h - STATUS_H

    # Status line, pinned to the bottom, with the hairline every Mac
    # application draws above one.
    let status = Cls["NSTextField"]().labelWithString(
        nsstring(String("Ready")).ptr()
    )
    Obj["NSView"](status.addr()).setFrame(ui.rect(14.0, 5.0, w - 200.0, 16.0))
    Obj["NSView"](status.addr()).setAutoresizingMask(Int(2))
    Obj["NSTextField"](status.addr()).setFont(
        Cls["NSFont"]().systemFontOfSize_weight(11.0, ui.W_REGULAR).ptr()
    )
    Obj["NSTextField"](status.addr()).setTextColor(ui.secondary().ptr())
    Obj["NSView"](content.addr()).addSubview(status.ptr())
    _ = external_call["objc_retain", P](status.ptr())
    g_status()[] = status.addr()

    var rule = Cls["NSBox"]().alloc()
    rule = Obj["NSBox"](rule.addr()).initWithFrame(ui.rect(0.0, STATUS_H, w, 1.0))
    Obj["NSBox"](rule.addr()).setBoxType(Int(2))
    Obj["NSView"](rule.addr()).setAutoresizingMask(Int(2))
    Obj["NSView"](content.addr()).addSubview(rule.ptr())

    var spin = Cls["NSProgressIndicator"]().alloc()
    spin = Obj["NSProgressIndicator"](spin.addr()).initWithFrame(
        ui.rect(w - 28.0, 5.0, 16.0, 16.0)
    )
    Obj["NSProgressIndicator"](spin.addr()).setStyle(Int(1))
    Obj["NSProgressIndicator"](spin.addr()).setIndeterminate(True)
    Obj["NSProgressIndicator"](spin.addr()).setControlSize(Int(1))
    Obj["NSProgressIndicator"](spin.addr()).setDisplayedWhenStopped(False)
    Obj["NSView"](spin.addr()).setAutoresizingMask(Int(1))
    Obj["NSView"](content.addr()).addSubview(spin.ptr())
    _ = external_call["objc_retain", P](spin.ptr())
    g_spinner()[] = spin.addr()

    # The outer split: sidebar, work area, inspector.
    var split = Cls["NSSplitView"]().alloc()
    split = Obj["NSSplitView"](split.addr()).initWithFrame(
        ui.rect(0.0, STATUS_H + 1.0, w, body_h - 1.0)
    )
    Obj["NSSplitView"](split.addr()).setVertical(True)
    Obj["NSSplitView"](split.addr()).setDividerStyle(Int(2))
    Obj["NSView"](split.addr()).setAutoresizingMask(Int(18))
    Obj["NSView"](content.addr()).addSubview(split.ptr())

    # 1. The source list.
    var side_scroll = Cls["NSScrollView"]().alloc()
    side_scroll = Obj["NSScrollView"](side_scroll.addr()).initWithFrame(
        ui.rect(0.0, 0.0, SIDEBAR_W, body_h)
    )
    Obj["NSScrollView"](side_scroll.addr()).setHasVerticalScroller(True)
    Obj["NSScrollView"](side_scroll.addr()).setDrawsBackground(False)
    Obj["NSScrollView"](side_scroll.addr()).setBorderType(Int(0))
    Obj["NSView"](side_scroll.addr()).setAutoresizingMask(Int(18))
    let side = make_table(ui.rect(0.0, 0.0, SIDEBAR_W, body_h), actions, True)
    g_sidebar()[] = side.addr()
    Obj["NSScrollView"](side_scroll.addr()).setDocumentView(side.ptr())
    Obj["NSSplitView"](split.addr()).addSubview(side_scroll.ptr())

    # 2. The work area: the plot, and the flight log beneath it.
    let divider = 1.0
    let mid_w = w - SIDEBAR_W - INSPECTOR_W - 2.0 * divider
    var vsplit = Cls["NSSplitView"]().alloc()
    vsplit = Obj["NSSplitView"](vsplit.addr()).initWithFrame(
        ui.rect(SIDEBAR_W + divider, 0.0, mid_w, body_h)
    )
    Obj["NSView"](vsplit.addr()).setAutoresizingMask(Int(18))
    Obj["NSSplitView"](vsplit.addr()).setVertical(False)
    Obj["NSSplitView"](vsplit.addr()).setDividerStyle(Int(2))

    let plot = ObjCObject(PlannerPlotView().__objc_id)
    Obj["NSView"](plot.addr()).setFrame(ui.rect(0.0, LOG_H + divider, mid_w, body_h - LOG_H - divider))
    Obj["NSView"](plot.addr()).setAutoresizingMask(Int(18))
    _ = external_call["objc_retain", P](plot.ptr())
    g_view()[] = plot.addr()
    Obj["NSSplitView"](vsplit.addr()).addSubview(plot.ptr())

    var log_scroll = Cls["NSScrollView"]().alloc()
    log_scroll = Obj["NSScrollView"](log_scroll.addr()).initWithFrame(
        ui.rect(0.0, 0.0, mid_w, LOG_H)
    )
    Obj["NSScrollView"](log_scroll.addr()).setHasVerticalScroller(True)
    Obj["NSScrollView"](log_scroll.addr()).setBorderType(Int(0))
    Obj["NSView"](log_scroll.addr()).setAutoresizingMask(Int(18))
    var logv = Cls["NSTextView"]().alloc()
    logv = Obj["NSTextView"](logv.addr()).initWithFrame(
        ui.rect(0.0, 0.0, mid_w, LOG_H)
    )
    Obj["NSTextView"](logv.addr()).setEditable(False)
    Obj["NSTextView"](logv.addr()).setRichText(False)
    Obj["NSTextView"](logv.addr()).setFont(
        Cls["NSFont"]().monospacedSystemFontOfSize_weight(11.0, ui.W_REGULAR).ptr()
    )
    Obj["NSTextView"](logv.addr()).setTextColor(ui.label().ptr())
    Obj["NSTextView"](logv.addr()).setBackgroundColor(ui.control_bg().ptr())
    Obj["NSTextView"](logv.addr()).setTextContainerInset(CGSize(12.0, 10.0))
    # A text view built in code has a text container of no size, and lays
    # out nothing into it: the pane comes up blank with the string set and
    # no error anywhere. These four lines are what a nib does for you.
    Obj["NSTextView"](logv.addr()).setMinSize(CGSize(0.0, 0.0))
    Obj["NSTextView"](logv.addr()).setMaxSize(CGSize(1.0e7, 1.0e7))
    Obj["NSTextView"](logv.addr()).setVerticallyResizable(True)
    Obj["NSTextView"](logv.addr()).setHorizontallyResizable(False)
    let container = Obj["NSTextView"](logv.addr()).textContainer()
    if container.addr() != 0:
        Obj["NSTextContainer"](container.addr()).setWidthTracksTextView(True)
        Obj["NSTextContainer"](container.addr()).setContainerSize(
            CGSize(mid_w, 1.0e7)
        )
    Obj["NSView"](logv.addr()).setAutoresizingMask(Int(2))
    Obj["NSScrollView"](log_scroll.addr()).setDocumentView(logv.ptr())
    _ = external_call["objc_retain", P](logv.ptr())
    g_logview()[] = logv.addr()
    Obj["NSSplitView"](vsplit.addr()).addSubview(log_scroll.ptr())
    Obj["NSSplitView"](split.addr()).addSubview(vsplit.ptr())

    # 3. The inspector: the choices above, the plan sheet below.
    var insp = Cls["NSView"]().alloc()
    insp = Obj["NSView"](insp.addr()).initWithFrame(
        ui.rect(w - INSPECTOR_W, 0.0, INSPECTOR_W, body_h)
    )
    Obj["NSView"](insp.addr()).setAutoresizingMask(Int(18))
    let controls = build_controls(
        ui.rect(0.0, body_h - CONTROLS_H, INSPECTOR_W, CONTROLS_H), actions
    )
    Obj["NSView"](insp.addr()).addSubview(controls.ptr())

    var insp_rule = Cls["NSBox"]().alloc()
    insp_rule = Obj["NSBox"](insp_rule.addr()).initWithFrame(
        ui.rect(0.0, body_h - CONTROLS_H, INSPECTOR_W, 1.0)
    )
    Obj["NSBox"](insp_rule.addr()).setBoxType(Int(2))
    Obj["NSView"](insp_rule.addr()).setAutoresizingMask(Int(2 | 8))
    Obj["NSView"](insp.addr()).addSubview(insp_rule.ptr())

    var tab_scroll = Cls["NSScrollView"]().alloc()
    tab_scroll = Obj["NSScrollView"](tab_scroll.addr()).initWithFrame(
        ui.rect(0.0, 0.0, INSPECTOR_W, body_h - CONTROLS_H - 1.0)
    )
    Obj["NSScrollView"](tab_scroll.addr()).setHasVerticalScroller(True)
    Obj["NSScrollView"](tab_scroll.addr()).setDrawsBackground(False)
    Obj["NSScrollView"](tab_scroll.addr()).setBorderType(Int(0))
    Obj["NSView"](tab_scroll.addr()).setAutoresizingMask(Int(2 | 16))
    let table = make_table(
        ui.rect(0.0, 0.0, INSPECTOR_W, body_h - CONTROLS_H - 1.0), actions, False
    )
    g_table()[] = table.addr()
    Obj["NSScrollView"](tab_scroll.addr()).setDocumentView(table.ptr())
    Obj["NSView"](insp.addr()).addSubview(tab_scroll.ptr())
    Obj["NSSplitView"](split.addr()).addSubview(insp.ptr())

    # adjustSubviews before setPosition: the split has just been handed
    # three subviews whose frames it has never reconciled, and a position
    # set against an unlaid-out split is measured from the wrong origin --
    # which is what collapsed the inspector to nothing.
    Obj["NSSplitView"](split.addr()).adjustSubviews()
    Obj["NSSplitView"](vsplit.addr()).adjustSubviews()
    Obj["NSSplitView"](split.addr()).setPosition_ofDividerAtIndex(
        SIDEBAR_W, Int(0)
    )
    Obj["NSSplitView"](split.addr()).setPosition_ofDividerAtIndex(
        w - INSPECTOR_W - divider, Int(1)
    )
    Obj["NSSplitView"](vsplit.addr()).setPosition_ofDividerAtIndex(
        body_h - LOG_H - divider, Int(0)
    )

    Obj["NSTableView"](side.addr()).reloadData()
    Obj["NSTableView"](side.addr()).selectRowIndexes_byExtendingSelection(
        Cls["NSIndexSet"]().indexSetWithIndex(Int(0)).ptr(), False
    )
    Obj["NSWindow"](win.addr()).makeKeyAndOrderFront(ObjCObject(0).ptr())
    return win


# ── the snapshots the views read ─────────────────────────────────────────


def refresh_arc(m: Mission):
    """The planned course and the Moon's path beside it, sampled for the
    plot rather than for the physics: three thousand integrator steps is
    more than any screen can show, and every tenth is plenty."""
    g_arc()[].clear()
    g_moon()[].clear()
    let n = len(m.arc) // 7
    var i = 0
    while i < n:
        g_arc()[].append(m.arc[i * 7 + 1])
        g_arc()[].append(m.arc[i * 7 + 2])
        g_arc()[].append(m.arc[i * 7 + 3])
        let mp = m.bodies.moon_at(m.arc[i * 7] + m.tli_offset - m.tab0)
        g_moon()[].append(mp.x)
        g_moon()[].append(mp.y)
        g_moon()[].append(mp.z)
        i += 8
    # Where the Moon is at the moment the transfer is aimed at, which is
    # perilune -- the arc itself carries on for six hours past it.
    let aim = m.bodies.moon_at(m.target_t_p)
    set_num(N_AX, aim.x)
    set_num(N_AY, aim.y)
    set_num(N_AZ, aim.z)


def refresh_map(wm: WindowMap):
    """Fold the GPU's cells into one per day and hour: the cheapest total
    Delta-v among every launch minute in that hour and every flight time."""
    g_map()[].clear()
    g_mapflag()[].clear()
    g_map_days()[] = 0
    if len(wm.cells) < wm.width * wm.height * FIELDS:
        # The GPU pass has not run, or this machine has no GPU. The view says
        # so rather than drawing a chart of zeroes.
        return
    g_map_days()[] = wm.days
    for _ in range(wm.days * 24):
        g_map()[].append(0.0)
        g_mapflag()[].append(0)
    for y in range(wm.height):
        let hour = y * 24 // wm.height
        for x in range(wm.width):
            let day = x // wm.steps
            if day >= wm.days:
                continue
            let base = (y * wm.width + x) * FIELDS
            let fl = Int(wm.cells[base + F_FLAGS])
            if (fl & FLAG_OK) == 0 or (fl & FLAG_CORRIDOR) == 0:
                continue
            let dv = Float64(wm.cells[base + F_DV_TLI]) + Float64(wm.cells[base + F_DV_LOI])
            if dv <= 0.0:
                continue
            let i = day * 24 + hour
            if g_map()[][i] == 0.0 or dv < g_map()[][i]:
                g_map()[][i] = dv
            g_mapflag()[][i] = g_mapflag()[][i] | (fl & FLAG_LIT) | FLAG_CORRIDOR


def refresh_flown(m: Mission):
    g_flown()[].clear()
    let n = len(m.track) // 4
    var i = 0
    while i < n:
        g_flown()[].append(m.track[i * 4 + 1])
        g_flown()[].append(m.track[i * 4 + 2])
        g_flown()[].append(m.track[i * 4 + 3])
        i += 1


def refresh_descent(m: Mission):
    """The powered descent as the plot needs it: the flown profile in
    downrange and altitude, and where the LM is now."""
    g_dtrail()[].clear()
    let n = len(m.descent.trail) // 4
    var i = 0
    while i < n:
        g_dtrail()[].append(m.descent.trail[i * 4 + 1])
        g_dtrail()[].append(m.descent.trail[i * 4 + 3])
        i += 1
    g_dstate()[].clear()
    for _ in range(D_COUNT):
        g_dstate()[].append(0.0)
    g_dstate()[][D_RANGE] = m.descent.downrange()
    g_dstate()[][D_ALT] = m.descent.altitude()
    g_dstate()[][D_RATE] = m.descent.descent_rate()
    g_dstate()[][D_GS] = m.descent.ground_speed()
    g_dstate()[][D_THR] = m.descent.throttle
    g_dstate()[][D_HOVER] = m.descent.hover_seconds()
    g_dstate()[][D_PHASE] = Float64(m.descent.phase)
    g_dstate()[][D_LIVE] = 1.0
    # Where the crew are aiming, in the frame the chart is drawn in: the
    # aim is held in the site frame, and what the LM will actually reach
    # is that aim displaced by the navigation error it does not know it
    # has.
    g_dstate()[][D_AIM] = m.descent.aim_x - m.descent.nav_err.x
    g_dstate()[][D_REDES] = Float64(m.descent.redesignations)
    g_dstate()[][D_LANDX] = m.descent.landed_x
    g_dstate()[][D_CONTACT] = m.descent.contact_speed
    g_dstate()[][D_ALARM] = Float64(m.descent.alarm_state)


def plan_log(sheet: PlanSheet, ch: Choices):
    """The flight plan as the log's opening entry, so the pane carries the
    timeline before there is a flight to report. Ground Elapsed Time from
    lift-off, which is the only clock a plan is written in."""
    let t0 = sheet.jd_launch
    var out = String("FLIGHT PLAN  ") + launch_sites()[ch.pad].name + "  to  "
    out += landing_sites()[ch.target].name + "\n"
    out += "seed " + String(ch.seed) + "   flight time " + ui.f(ch.tof_h, 2) + " h\n\n"
    out += "   GET         EVENT                 dv\n"
    var rows = List[String]()
    var times = List[Float64]()
    var dvs = List[Float64]()
    for name in ["Lift-off", "Orbit insertion", "TLI ignition", "MCC-2",
                 "LOI-1 ignition", "LOI-2", "DOI", "PDI", "Touchdown"]:
        rows.append(String(name))
    times.append(sheet.jd_launch)
    times.append(sheet.jd_insertion)
    times.append(sheet.jd_tli_ign)
    times.append(sheet.jd_mcc2)
    times.append(sheet.jd_loi1_ign)
    times.append(sheet.jd_loi2)
    times.append(sheet.jd_doi)
    times.append(sheet.jd_pdi)
    times.append(sheet.jd_landing)
    dvs.append(0.0)
    dvs.append(0.0)
    dvs.append(sheet.dv_tli)
    dvs.append(0.0)
    dvs.append(sheet.dv_loi1)
    dvs.append(sheet.dv_loi2)
    dvs.append(sheet.dv_doi)
    dvs.append(0.0)
    dvs.append(sheet.dv_descent)
    for i in range(len(rows)):
        var line = String("   ") + ui.get_hms((times[i] - t0) * 86400.0) + "   " + rows[i]
        while line.byte_length() < 40:
            line += " "
        if dvs[i] > 0.0:
            line += ui.ms(dvs[i])
        out += line + "\n"
    out += "\nMARGINS   S-IVB " + ui.f(sheet.sivb_margin_kg, 0) + " kg"
    out += "   SPS " + ui.f(sheet.sps_margin_kg, 0) + " kg"
    out += "   DPS hover " + ui.f(sheet.dps_margin_s, 0) + " s\n"
    for i in range(len(sheet.red)):
        out += "NO-GO     " + sheet.red[i] + "\n"
    for i in range(len(sheet.amber)):
        out += "CAUTION   " + sheet.amber[i] + "\n"
    set_log_text(out)


fn set_log_text(s: String):
    if g_logview()[] != 0:
        Obj["NSTextView"](ObjCObject(g_logview()[]).addr()).setString(
            nsstring(s).ptr()
        )


def refresh_log(m: Mission):
    var s = String("")
    let n = len(m.log)
    var i = 0
    while i < n:
        s += m.log[i] + "\n"
        i += 1
    if g_logview()[] != 0:
        Obj["NSTextView"](ObjCObject(g_logview()[]).addr()).setString(
            nsstring(s).ptr()
        )
        Obj["NSTextView"](ObjCObject(g_logview()[]).addr()).scrollRangeToVisible(
            _range(s.byte_length(), 0)
        )


fn _range(loc: Int, length: Int) -> CGPoint:
    """NSRange is two words; CGPoint is two words with the same layout, and
    scrollRangeToVisible: only ever reads them as (location, length)."""
    return CGPoint(Float64(loc), Float64(length))


fn set_status(s: String):
    if g_status()[] != 0:
        _ = Obj["NSTextField"](ObjCObject(g_status()[]).addr()).setStringValue(s)


fn reload():
    if g_table()[] != 0:
        Obj["NSTableView"](ObjCObject(g_table()[]).addr()).reloadData()
    if g_sidebar()[] != 0:
        Obj["NSTableView"](ObjCObject(g_sidebar()[]).addr()).reloadData()


fn redraw():
    if g_view()[] != 0:
        Obj["NSView"](ObjCObject(g_view()[]).addr()).setNeedsDisplay(True)


# ── the pump ─────────────────────────────────────────────────────────────


def main() raises:
    if not load_framework["AppKit"]():
        raise Error("could not load AppKit")

    # State before anything that can call back into it.
    for _ in range(N_COUNT):
        g_num()[].append(0.0)
    set_num(N_YAW, 34.0)
    set_num(N_PITCH, 26.0)
    set_num(N_ZOOM, 1.0)
    set_num(N_WARP, 900.0)

    let a11 = apollo_11_choices()
    for _ in range(C_COUNT):
        g_choice()[].append(0)
    set_choice(C_PAD, a11.pad)
    set_choice(C_TARGET, a11.target)
    set_choice(C_MONTH, a11.month)
    set_choice(C_YEAR, a11.year)
    set_choice(C_TOF, Int(a11.tof_h * 10.0 + 0.5))
    set_choice(C_MCC, a11.mcc_policy)

    for s in ["All Sections", "Launch", "Translunar", "Arrival", "Descent",
              "Margins & Rules"]:
        g_phases()[].append(String(s))

    let headless = getenv("PLANNER_FRAMES")
    var frame_budget = 0
    if headless != "":
        frame_budget = atol(headless)

    var win = ObjCObject(0)
    with autoreleasepool():
        var app = Cls["NSApplication"]().sharedApplication()
        _ = app.setActivationPolicy(
            nsenum["NSApplicationActivationPolicyRegular"]()
        )
        let delegate = ObjCObject(PlannerDelegate().__objc_id)
        _ = app.setDelegate(delegate.ptr())
        _ = external_call["objc_retain", P](delegate.ptr())

        let actions = ObjCObject(PlannerActions().__objc_id)
        _ = external_call["objc_retain", P](actions.ptr())
        g_actions()[] = actions.addr()

        build_menu_bar(ObjCObject(app.id), actions.addr())
        win = build_window(actions.addr())
        install_apple_events()
        _ = app.activateIgnoringOtherApps(True)
        _ = app.finishLaunching()

    # The first plan, before the loop, so the window is never empty.
    var eph = Ephemeris()
    var ch = current_choices()
    var ctx = DeviceContext(api="metal")
    set_status(String("Planning…"))
    var wm = WindowMap(
        eph, ch.year, ch.month, launch_sites()[ch.pad],
        landing_sites()[ch.target], 60.0, 120.0, 48, 480,
    )
    try:
        compute_map(wm, ctx)
    except:
        print("mission planner: the window map needs a GPU; the other views are unaffected")
    var sheet = make_plan(eph, wm, ch)
    var m = Mission(eph, sheet, ch.seed)
    build_rows(sheet, ch, 0.0, False)
    refresh_map(wm)
    refresh_arc(m)
    refresh_flown(m)
    plan_log(sheet, ch)
    reload()
    redraw()
    set_status(
        String("Plan ready · TLI ") + ui.ms(sheet.dv_tli)
        + " · LOI-1 " + ui.ms(sheet.dv_loi1)
        + (String("") if sheet.ok else String(" · NO-GO"))
    )

    let mode = "kCFRunLoopDefaultMode"
    var running = True
    var frames = 0
    var last = perf_counter_ns()

    while running:
        with autoreleasepool():
            # Drain everything AppKit has, then do our own work: a hand
            # rolled pump, the same shape `examples/othello` uses, because
            # the mission clock is ours and not a timer's.
            while True:
                let past = Cls["NSDate"]().distantPast()
                let ev = Cls["NSApplication"]().sharedApplication().nextEventMatchingMask(
                    UInt64.MAX,
                    untilDate=ObjCObject(past.id),
                    inMode=mode,
                    dequeue=True,
                )
                if ev.id == 0:
                    break
                _ = Cls["NSApplication"]().sharedApplication().sendEvent(
                    ObjCObject(ev.id)
                )

            if frame_budget == 0 and not Obj["NSWindow"](win.addr()).isVisible():
                break

            if g_cmd()[] != 0:
                let want_replan = (g_cmd()[] & CMD_REPLAN) != 0
                let want_fly = (g_cmd()[] & CMD_FLY) != 0
                let want_reset = (g_cmd()[] & CMD_RESET) != 0
                let want_quit = (g_cmd()[] & CMD_QUIT) != 0
                let want_export = (g_cmd()[] & CMD_EXPORT) != 0
                let want_abort = (g_cmd()[] & CMD_ABORT) != 0
                let want_go = (g_cmd()[] & CMD_GO) != 0
                let want_nogo = (g_cmd()[] & CMD_NOGO) != 0
                g_cmd()[] = 0
                if m.phase == PHASE_DESCENT:
                    if want_abort:
                        m.descent.call_abort(String("abort called from the ground"))
                        refresh_descent(m)
                        g_dirty()[] = 1
                    if want_go:
                        m.descent.call_alarm(True)
                    if want_nogo:
                        m.descent.call_alarm(False)
                        refresh_descent(m)
                        g_dirty()[] = 1
                if want_export:
                    export_with_panel()
                if want_quit:
                    running = False
                    continue
                if want_replan or want_reset:
                    g_flying()[] = 0
                    set_status(String("Planning…"))
                    if g_spinner()[] != 0:
                        Obj["NSProgressIndicator"](
                            ObjCObject(g_spinner()[]).addr()
                        ).startAnimation(ObjCObject(0).ptr())
                    ch = current_choices()
                    wm = WindowMap(
                        eph, ch.year, ch.month, launch_sites()[ch.pad],
                        landing_sites()[ch.target], 60.0, 120.0, 48, 480,
                    )
                    try:
                        compute_map(wm, ctx)
                    except:
                        pass
                    sheet = make_plan(eph, wm, ch)
                    m = Mission(eph, sheet, ch.seed)
                    build_rows(sheet, ch, 0.0, False)
                    refresh_map(wm)
                    refresh_arc(m)
                    refresh_flown(m)
                    g_seenphase()[] = stage_of(m)
                    frame_course(m)
                    plan_log(sheet, ch)
                    reload()
                    redraw()
                    if g_spinner()[] != 0:
                        Obj["NSProgressIndicator"](
                            ObjCObject(g_spinner()[]).addr()
                        ).stopAnimation(ObjCObject(0).ptr())
                    set_status(
                        String("Plan ready · TLI ") + ui.ms(sheet.dv_tli)
                        + " · LOI-1 " + ui.ms(sheet.dv_loi1)
                        + (String("") if sheet.ok else String(" · NO-GO"))
                    )
                if want_fly:
                    g_flying()[] = 0 if g_flying()[] != 0 else 1

            if g_flying()[] != 0 and m.phase != PHASE_DONE:
                let now = perf_counter_ns()
                var dt = Float64(now - last) / 1.0e9
                last = now
                if dt > 0.1:
                    dt = 0.1
                # Headless there is no wall clock worth reading: the loop
                # runs as fast as it can and a real dt would advance the
                # mission by microseconds. A fixed tick makes a headless
                # flight both quick and repeatable, which is what lets the
                # suite fly one at all.
                if frame_budget != 0:
                    dt = 1.0
                m.warp = num(N_WARP)
                m.advance(dt)
                follow_mission(m)
                refresh_flown(m)
                if m.descent.t > 0.0:
                    refresh_descent(m)
                refresh_log(m)
                build_rows(sheet, ch, m.get, True)
                reload()
                redraw()
                set_status(
                    String("Flying · GET ") + ui.get_hms(m.get)
                    + " · " + ui.f(num(N_WARP), 0) + "× · "
                    + (m.outcome if m.phase == PHASE_DONE else stage_name(stage_of(m)))
                )
            else:
                last = perf_counter_ns()

            if g_dirty()[] != 0:
                g_dirty()[] = 0
                redraw()

        frames += 1
        if frame_budget != 0 and frames >= frame_budget:
            running = False

    if frame_budget != 0:
        # The self-test: drive the console through its own Apple Event
        # surface and photograph each view. An event a process sends itself
        # needs no Automation grant, so this exercises registration, unpack,
        # dispatch and reply exactly as an external script would.
        print("Mission Planner: ran", frames, "frames headless;", row_count(), "plan rows,",
              len(g_arc()[]) // 3, "course samples")
        print("  TLI", ui.ms(sheet.dv_tli), " LOI-1", ui.ms(sheet.dv_loi1),
              " sun", ui.f(sheet.sun_elev, 1) + "°")
        let shots = getenv("PLANNER_SHOTS")
        if shots != "":
            print("  ae status:", send_self(String("status")))
            for name in ["trajectory", "map", "descent"]:
                print("  ae mode:", send_self(String("mode ") + String(name)))
                print("  ae shot:", send_self(
                    String("screenshot ") + shots + "/planner-" + String(name) + ".png"
                ))
            for sec in ["launch", "descent", "margins", "all"]:
                print("  ae section:", send_self(String("section ") + String(sec)))
            # One picture of the console with a section selected, so the
            # filtered inspector is checked and not just counted.
            _ = send_self(String("mode trajectory"))
            _ = send_self(String("section descent"))
            print("  ae shot:", send_self(
                String("screenshot ") + shots + "/planner-section.png"
            ))
            _ = send_self(String("section all"))
            print("  ae export:", send_self(
                String("export ") + shots + "/planner-export.png"
            ))
            print("  ae help:", send_self(String("help")))

            # The view is supposed to follow the flight: Earth at launch,
            # the gulf on the way, the Moon on arrival, and the descent
            # profile when the LM lights. Nothing above proves that,
            # because nothing above FLIES -- which is exactly how a
            # console that never changed view shipped. So fly one, and
            # photograph the stage each time it turns over.
            _ = send_self(String("mode trajectory"))
            g_flying()[] = 1
            set_num(N_WARP, 3600.0)
            var seen = List[Int]()
            var in_orbit = False
            var shot_at = 0
            var descent_marks = List[Float64]()
            for v in [120.0, 480.0, 660.0, 735.0]:
                descent_marks.append(Float64(v))
            var guard = 0
            while m.phase != PHASE_DONE and guard < 4000:
                m.warp = num(N_WARP)
                m.advance(1.0)
                follow_mission(m)
                let k = stage_of(m)
                var known = False
                for j in range(len(seen)):
                    if seen[j] == k:
                        known = True
                if not known:
                    seen.append(k)
                    refresh_flown(m)
                    print("  stage:", stage_name(k), "at GET", ui.get_hms(m.get),
                          "· view", mode_name(g_mode()[]),
                          "· centre", ui.f(Vec3(num(N_CX), num(N_CY), num(N_CZ)).norm(), 0),
                          "km · span", ui.f(num(N_SPAN), 0), "km")
                    _ = send_self(
                        String("screenshot ") + shots + "/planner-stage-"
                        + String(k) + ".png"
                    )
                # A stage flip is caught the instant it happens, when the
                # camera has only started moving. One more picture once
                # the craft is in lunar orbit shows where it ended up,
                # which is the claim: the Moon, filling the frame.
                # The descent is the part that has to look alive, so it is
                # photographed as it runs: braking, approach, and the last
                # of it with the ground and the aim point in frame.
                if m.phase == PHASE_DESCENT:
                    refresh_descent(m)
                    while shot_at < 4 and m.descent.t >= descent_marks[shot_at]:
                        let mk = shot_at
                        shot_at += 1
                        print("  descent t+", ui.f(m.descent.t, 0),
                              "·", phase_label(m.descent.phase),
                              "· alt", ui.f(m.descent.altitude(), 0),
                              "m · range", ui.f(-m.descent.downrange(), 0),
                              "m · throttle", ui.f(m.descent.throttle * 100.0, 0),
                              "% · hover", ui.f(m.descent.hover_seconds(), 0), "s")
                        _ = send_self(
                            String("screenshot ") + shots + "/planner-descent-"
                            + String(mk) + ".png"
                        )
                if m.phase == PHASE_LUNAR_ORBIT and not in_orbit:
                    in_orbit = True
                    refresh_flown(m)
                    print("  in lunar orbit at GET", ui.get_hms(m.get),
                          "· view", mode_name(g_mode()[]),
                          "· Moon", ui.f((m.r - m.moon()).norm(), 0),
                          "km away · centre", ui.f(Vec3(num(N_CX), num(N_CY), num(N_CZ)).norm(), 0),
                          "km · span", ui.f(num(N_SPAN), 0), "km")
                    _ = send_self(
                        String("screenshot ") + shots + "/planner-stage-2-orbit.png"
                    )
                guard += 1
            print("  flight:", m.outcome, "at GET", ui.get_hms(m.get),
                  "· stages seen", len(seen))


# ── Apple Events: the console, scriptable ────────────────────────────────
#
# One verb with a string argument and a string reply, which is the shape
# `ide/roast.mojo` arrived at and the right one: the surface is a small
# command language rather than a dozen four-character codes, so it can grow
# a verb without an sdef change and `do command "help"` documents itself.
#
#   osascript -e 'tell application "Mission Planner" to do command "status"'
#   osascript -e 'tell application "Mission Planner" to do command "mode map"'
#   osascript -e 'tell application "Mission Planner" to do command "screenshot /tmp/t.png"'
#
# The name resolves because the binary carries a __TEXT,__info_plist with a
# bundle identifier and NSAppleScriptEnabled, exactly as `bin/roast` does;
# `MissionPlanner.sdef` in this directory supplies the words. An event a process
# sends ITSELF needs no Automation grant, which is what `--selftest` uses
# to exercise the whole path -- registration, unpack, dispatch, reply --
# without a TCC dialog in the way.

comptime AE_CLASS = 0x4D504C4E  # 'MPLN'
comptime AE_CMD = 0x636D6E64  # 'cmnd'
comptime AE_DIRECT = 0x2D2D2D2D  # '----', keyDirectObject


def capture_view(view_addr: Int, path: String) -> String:
    """One view, drawn into a bitmap and written as a PNG. This is the view
    drawing ITSELF, not the screen being read, so it needs no screen
    recording permission and works while the window is behind another."""
    if view_addr == 0:
        return String("error: no view")
    with autoreleasepool():
        let b = Obj["NSView"](view_addr).bounds()
        if b.size.width < 1.0 or b.size.height < 1.0:
            return String("error: view has no size")
        let r = ui.rect(0.0, 0.0, b.size.width, b.size.height)
        let rep = Obj["NSView"](view_addr).bitmapImageRepForCachingDisplayInRect(r)
        if rep.addr() == 0:
            return String("error: could not make a bitmap")
        Obj["NSView"](view_addr).cacheDisplayInRect_toBitmapImageRep(r, rep.ptr())
        # 4 is NSBitmapImageFileTypePNG; an empty dictionary rather than nil,
        # because the parameter is typed as one.
        let props = Cls["NSMutableDictionary"]().dictionary()
        let data = Obj["NSBitmapImageRep"](rep.addr()).representationUsingType_properties(
            UInt64(4), props.ptr()
        )
        if data.addr() == 0:
            return String("error: PNG encoding failed")
        if not Obj["NSData"](data.addr()).writeToFile_atomically(
            nsstring(path).ptr(), True
        ):
            return String("error: could not write ") + path
        let w = Obj["NSBitmapImageRep"](rep.addr()).pixelsWide()
        let h = Obj["NSBitmapImageRep"](rep.addr()).pixelsHigh()
        return path + " (" + String(w) + "x" + String(h) + " px)"


def export_plot(path: String) -> String:
    """Just the canvas: an export is the picture, not a photograph of an
    application. The window shot is what `screenshot` is for."""
    g_exporting()[] = 1
    if g_view()[] != 0:
        Obj["NSView"](ObjCObject(g_view()[]).addr()).display()
    let answer = capture_view(g_view()[], path)
    g_exporting()[] = 0
    if g_view()[] != 0:
        Obj["NSView"](ObjCObject(g_view()[]).addr()).display()
    return answer


def suggested_name() -> String:
    let base = String("Mission Planner ") + mode_name(g_mode()[])
    return base + ".png"


def export_with_panel():
    """The Mac way to write a file: NSSavePanel, with a name already filled
    in from the view being exported and the extension it will actually be."""
    with autoreleasepool():
        let panel = Cls["NSSavePanel"]().savePanel()
        Obj["NSSavePanel"](panel.addr()).setNameFieldStringValue(
            nsstring(suggested_name()).ptr()
        )
        Obj["NSSavePanel"](panel.addr()).setTitle(
            nsstring(String("Export ") + mode_name(g_mode()[])).ptr()
        )
        Obj["NSSavePanel"](panel.addr()).setCanCreateDirectories(True)
        if Obj["NSSavePanel"](panel.addr()).runModal() != 1:
            set_status(String("Export cancelled"))
            return
        let url = Obj["NSSavePanel"](panel.addr()).URL()
        if url.addr() == 0:
            set_status(String("Export cancelled"))
            return
        let where = ns_to_string(Obj["NSURL"](url.addr()).path())
        let answer = export_plot(where)
        if answer.startswith("error"):
            set_status(String("Export failed: ") + answer)
        else:
            set_status(String("Exported ") + answer)


def capture_window(path: String) -> String:
    """The whole window, titlebar and toolbar included: `contentView`'s
    superview is the frame view, which is what puts the chrome in the
    picture."""
    if g_window()[] == 0:
        return String("error: no window")
    let content = Obj["NSWindow"](ObjCObject(g_window()[]).addr()).contentView()
    var view_addr = content.addr()
    let above = Obj["NSView"](content.addr()).superview()
    if above.addr() != 0:
        view_addr = above.addr()
    return capture_view(view_addr, path)

def run_command(cmd: String) -> String:
    """The whole scripting surface, in one place."""
    let c = String(cmd.strip())
    if c == "help":
        return String(
            "status · replan · fly · hold · reset · mode "
            "trajectory|map|descent · speed <n> · section <name> · "
            "export [path] · screenshot [path] · quit"
        )
    if c == "status":
        return (
            String("mode ") + mode_name(g_mode()[])
            + "; " + (String("flying") if g_flying()[] != 0 else String("held"))
            + " at " + ui.f(num(N_WARP), 0) + "×"
            + "; section " + g_phases()[][g_phase_sel()[]]
            + "; " + String(shown_count()) + " of " + String(row_count())
            + " plan rows shown; "
            + String(len(g_arc()[]) // 3) + " course samples"
        )
    if c.startswith("screenshot"):
        var where = String("/tmp/mission-planner.png")
        if c.byte_length() > 11:
            where = String(c[byte=11:].strip())
        return capture_window(where)
    if c.startswith("speed"):
        let arg = String(c[byte=5:].strip())
        if arg == "":
            return String("speed ") + speed_label(speed_index_of(num(N_WARP)))
        var want = 0.0
        try:
            want = Float64(atof(arg))
        except:
            return String("error: speed <seconds of mission per second>")
        if want < 1.0:
            want = 1.0
        if want > 3600.0:
            want = 3600.0
        set_speed(want)
        return String("speed ") + ui.f(num(N_WARP), 0) + "×"
    if c == "abort":
        if g_mission_phase()[] != PHASE_DESCENT:
            return String("abort: nothing to abort -- not in powered descent")
        g_cmd()[] = g_cmd()[] | CMD_ABORT
        return String("abort called")
    if c == "go":
        g_cmd()[] = g_cmd()[] | CMD_GO
        return String("GO")
    if c == "nogo":
        g_cmd()[] = g_cmd()[] | CMD_NOGO
        return String("NO-GO")
    if c.startswith("section"):
        let which = String(c[byte=7:].strip())
        var idx = -1
        for i in range(len(g_phases()[])):
            if g_phases()[][i].lower().startswith(which.lower()) and which != "":
                idx = i
                break
        if idx < 0:
            return String("error: section all|launch|translunar|arrival|descent|margins")
        select_section(idx)
        return (
            String("section ") + g_phases()[][idx] + " · "
            + String(shown_count()) + " of " + String(row_count()) + " rows"
        )
    if c.startswith("export"):
        var where = String("/tmp/mission-planner-plot.png")
        if c.byte_length() > 7:
            where = String(c[byte=7:].strip())
        return export_plot(where)
    if c == "replan":
        g_cmd()[] = g_cmd()[] | CMD_REPLAN
        return String("replanning")
    if c == "fly":
        g_flying()[] = 1
        return String("flying")
    if c == "hold":
        g_flying()[] = 0
        return String("held")
    if c == "reset":
        g_cmd()[] = g_cmd()[] | CMD_RESET
        return String("reset")
    if c.startswith("mode"):
        let which = String(c[byte=4:].strip())
        if which == "trajectory":
            set_mode(MODE_TRAJECTORY)
        elif which == "map":
            set_mode(MODE_MAP)
        elif which == "descent":
            set_mode(MODE_DESCENT)
        else:
            return String("error: mode trajectory|map|descent")
        redraw()
        # Drawn now rather than at the next pump tick, so a script that
        # switches the view and screenshots it in the next line gets the
        # view it asked for.
        if g_view()[] != 0:
            Obj["NSView"](ObjCObject(g_view()[]).addr()).display()
        return String("mode ") + mode_name(g_mode()[])
    if c == "quit":
        g_cmd()[] = g_cmd()[] | CMD_QUIT
        return String("quitting")
    return String("error: unknown command '") + c + "' -- try help"


def select_section(idx: Int):
    """Move the source list and the inspector together, whether the click
    came from a mouse or from a script: the selection is the model, and the
    table is shown it rather than being the place it lives."""
    g_phase_sel()[] = idx
    rebuild_visible()
    if g_sidebar()[] != 0:
        Obj["NSTableView"](ObjCObject(g_sidebar()[]).addr()).selectRowIndexes_byExtendingSelection(
            Cls["NSIndexSet"]().indexSetWithIndex(idx).ptr(), False
        )
    if g_table()[] != 0:
        Obj["NSTableView"](ObjCObject(g_table()[]).addr()).reloadData()
        Obj["NSView"](ObjCObject(g_table()[]).addr()).display()


fn mode_name(m: Int) -> String:
    if m == MODE_TRAJECTORY:
        return String("trajectory")
    if m == MODE_MAP:
        return String("map")
    return String("descent")


class PlannerAEHandler:
    """The Apple Event target. `handleEvent:withReplyEvent:` is not an SDK
    selector, so its `v@:@@` encoding is derived from the two object
    arguments rather than looked up."""

    def handleEvent_withReplyEvent_(self, event: ObjCObject, reply: ObjCObject):
        let arg = Obj["NSAppleEventDescriptor"](event.addr()).paramDescriptorForKeyword(
            UInt32(AE_DIRECT)
        )
        var cmd = String("help")
        if arg.addr() != 0:
            cmd = ns_to_string(
                ObjCObject(Obj["NSAppleEventDescriptor"](arg.addr()).stringValue().id)
            )
        let answer = run_command(cmd)
        if reply.addr() != 0:
            Obj["NSAppleEventDescriptor"](reply.addr()).setParamDescriptor_forKeyword(
                Cls["NSAppleEventDescriptor"]().descriptorWithString(
                    nsstring(answer).ptr()
                ).ptr(),
                UInt32(AE_DIRECT),
            )


def install_apple_events():
    let handler = ObjCObject(PlannerAEHandler().__objc_id)
    _ = external_call["objc_retain", P](handler.ptr())
    let mgr = Cls["NSAppleEventManager"]().sharedAppleEventManager()
    Obj["NSAppleEventManager"](mgr.addr()).setEventHandler_andSelector_forEventClass_andEventID(
        handler.ptr(),
        sel["handleEvent:withReplyEvent:"]().ptr(),
        UInt32(AE_CLASS),
        UInt32(AE_CMD),
    )


def send_self(command: String) -> String:
    """Post `command` to this process and return the reply. The same
    transport an external script uses, minus the cross-process hop that TCC
    gates -- registration, unpack, dispatch and reply are the same code."""
    with autoreleasepool():
        let me = Cls["NSAppleEventDescriptor"]().descriptorWithProcessIdentifier(
            Int32(external_call["getpid", Int32]())
        )
        let ev = Cls["NSAppleEventDescriptor"]().appleEventWithEventClass_eventID_targetDescriptor_returnID_transactionID(
            UInt32(AE_CLASS), UInt32(AE_CMD), me.ptr(), Int16(-1), Int32(0)
        )
        Obj["NSAppleEventDescriptor"](ev.addr()).setParamDescriptor_forKeyword(
            Cls["NSAppleEventDescriptor"]().descriptorWithString(
                nsstring(command).ptr()
            ).ptr(),
            UInt32(AE_DIRECT),
        )
        var err = ObjCObject(0)
        let reply = Obj["NSAppleEventDescriptor"](ev.addr()).sendEventWithOptions_timeout_error(
            UInt64(0x00000003), Float64(5.0),
            Pointer(to=err).unsafe_bitcast[P]()[],
        )
        if reply.addr() == 0:
            return String("error: no reply")
        let back = Obj["NSAppleEventDescriptor"](reply.addr()).paramDescriptorForKeyword(
            UInt32(AE_DIRECT)
        )
        if back.addr() == 0:
            return String("error: reply had no result")
        return ns_to_string(
            ObjCObject(Obj["NSAppleEventDescriptor"](back.addr()).stringValue().id)
        )
