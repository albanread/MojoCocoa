# ===----------------------------------------------------------------------=== #
# Moonshot — the console (sprint MC4: the PLAN screen).
#
# One window, three layers: a direct pane the plot is drawn into a byte
# at a time, a text plane for the sheet, and the pane's own clear behind
# them. The player is the flight dynamics team. The choices on the right
# are theirs; every number under them is computed from those choices by
# the modules before this one, and the lines that are red are the rules.
#
#   ↑ ↓          choose a line          ← →   change it
#   E  M  R      the course, Earth-centred / Moon-centred / rotating
#   W            the month's launch-window map (← → ↑ ↓ then pick a minute)
#   drag         orbit the camera        Z / X  zoom out / in
#   return       GO: fly the plan (TRACK)  P  back to PLAN
#   1 2 3 4      time warp 1x 60x 600x 3600x   space  pause
#   esc          quit
#
# Headless, for the checker and for screenshots:
#   GAMEPANE_FRAMES=3 MOONSHOT_SHOT=/tmp/plan.png cocoamojo run examples/moonshot/main.mojo
# ===----------------------------------------------------------------------=== #

from std.math import sqrt, sin, cos, atan2
from std.os import getenv

from std.objc import load_framework, autoreleasepool
from std.time import perf_counter_ns
from max.gpu.host import DeviceContext
from std.ffi import external_call
from std.memory import OpaquePointer, Pointer
from gamepane.api import (
    KEY_LEFT, KEY_RIGHT, KEY_UP, KEY_DOWN, KEY_ESCAPE, KEY_Z, KEY_X, KEY_SPACE,
    KEY_RETURN, KEY_1, KEY_2, KEY_3, KEY_4, letter_key, FLAG_TRANSPARENT_BG,
)
from gamepane.metal import GamePane, DirectPane, TextPlane, key_held, mouse_state
from astro import *
from orbit import *
from transfer import *
from window import *
from plan import *
from scene import *
from mission import *
from cloud import *
from descent import *
from sound import Sound
from png import save_png

comptime P = OpaquePointer[MutUntrackedOrigin]

comptime WIN_W = 1280
comptime WIN_H = 800
comptime PW = 640  # the direct pane, scaled ×2
comptime PH = 400
comptime PLOT_W = 384  # 64 text columns
comptime PLOT_H = 400
comptime PANEL_COL = 65
comptime PANEL_COLS = 41

# text palette
comptime T_BG = 39
comptime T_TEXT = 32
comptime T_DIM = 33
comptime T_HI = 34
comptime T_RED = 35
comptime T_AMBER = 36
comptime T_GREEN = 37
comptime T_HEAD = 38
comptime T_BLACK = 40

comptime VIEW_EARTH = 0
comptime VIEW_MOON = 1
comptime VIEW_ROT = 2
comptime VIEW_MAP = 3

comptime MODE_PLAN = 0
comptime MODE_TRACK = 1

comptime ROW_PAD = 0
comptime ROW_TARGET = 1
comptime ROW_MONTH = 2
comptime ROW_DAY = 3
comptime ROW_HOUR = 4
comptime ROW_TOF = 5
comptime ROW_REV = 6
comptime ROW_PERI = 7
comptime ROW_ORIENT = 8
comptime ROW_DESCENT = 9
comptime ROW_HOVER = 10
comptime ROW_MCC = 11
comptime ROW_SEED = 12
comptime ROW_COUNT = 13


struct Keys(Movable):
    """Edge detection over the pane's polled keys: `pressed` is true on
    the frame a key goes down."""

    var codes: List[Int]
    var prev: List[Bool]
    var now: List[Bool]

    def __init__(out self):
        self.codes = List[Int]()
        self.prev = List[Bool]()
        self.now = List[Bool]()
        var c: List[Int] = [KEY_LEFT, KEY_RIGHT, KEY_UP, KEY_DOWN, KEY_ESCAPE, KEY_Z, KEY_X, KEY_SPACE, KEY_RETURN, KEY_1, KEY_2, KEY_3, KEY_4]
        for i in range(len(c)):
            self.codes.append(c[i])
        # E M R W P G N
        self.codes.append(letter_key(4))
        self.codes.append(letter_key(12))
        self.codes.append(letter_key(17))
        self.codes.append(letter_key(22))
        self.codes.append(letter_key(15))
        self.codes.append(letter_key(6))
        self.codes.append(letter_key(13))
        for _ in range(len(self.codes)):
            self.prev.append(False)
            self.now.append(False)

    def poll(mut self):
        for i in range(len(self.codes)):
            self.prev[i] = self.now[i]
            self.now[i] = key_held(self.codes[i])

    def pressed(self, code: Int) -> Bool:
        for i in range(len(self.codes)):
            if self.codes[i] == code:
                return self.now[i] and not self.prev[i]
        return False

    def held(self, code: Int) -> Bool:
        for i in range(len(self.codes)):
            if self.codes[i] == code:
                return self.now[i]
        return False


struct Console(Movable):
    """Everything the screen shows and the state behind it."""

    var eph: Ephemeris
    var ch: Choices
    var wm: WindowMap
    var sheet: PlanSheet
    var map_ready: Bool
    var map_best: Float64
    var view: Int
    var row: Int
    var yaw: Float64
    var pitch: Float64
    var dist: Float64
    var drag_x: Float64
    var drag_y: Float64
    var dragging: Bool
    # the scene, in each frame
    var moon_path: List[Float64]
    var arc_moon: List[Float64]
    var arc_rot: List[Float64]
    var park: List[Float64]
    var park_moon: List[Float64]
    var moon_p: Vec3
    var moon_rot: Vec3
    var earth_rot_path: List[Float64]
    var sun_e: Vec3
    var sun_m: Vec3
    var mf: MoonFrame
    var site_dir: Vec3
    var ex: Vec3
    var ey: Vec3
    var t_p: Float64
    var rot_pole: Vec3
    var rot_ref0: Vec3
    var mode: Int
    var mission: Mission
    var cloud_tli: CloudStats
    var cloud_mcc: CloudStats
    var cloud_ms: Float64

    def __init__(out self, var eph: Ephemeris, ch: Choices):
        self.eph = eph^
        self.ch = ch
        self.wm = WindowMap(self.eph, ch.year, ch.month, launch_sites()[ch.pad], landing_sites()[ch.target], 60.0, 120.0, 48, 480)
        self.sheet = PlanSheet()
        self.map_ready = False
        self.map_best = 0.0
        self.view = VIEW_EARTH
        self.row = ROW_DAY
        self.yaw = 35.0
        self.pitch = 28.0
        self.dist = 560000.0
        self.drag_x = 0.0
        self.drag_y = 0.0
        self.dragging = False
        self.moon_path = List[Float64]()
        self.arc_moon = List[Float64]()
        self.arc_rot = List[Float64]()
        self.park = List[Float64]()
        self.park_moon = List[Float64]()
        self.moon_p = Vec3(0.0, 0.0, 0.0)
        self.moon_rot = Vec3(0.0, 0.0, 0.0)
        self.earth_rot_path = List[Float64]()
        self.sun_e = Vec3(1.0, 0.0, 0.0)
        self.sun_m = Vec3(1.0, 0.0, 0.0)
        self.mf = MoonFrame(Vec3(1.0, 0.0, 0.0), Vec3(0.0, 1.0, 0.0), Vec3(0.0, 0.0, 1.0))
        self.site_dir = Vec3(1.0, 0.0, 0.0)
        self.ex = Vec3(1.0, 0.0, 0.0)
        self.ey = Vec3(0.0, 1.0, 0.0)
        self.t_p = 0.0
        self.rot_pole = Vec3(0.0, 0.0, 1.0)
        self.rot_ref0 = Vec3(1.0, 0.0, 0.0)
        self.mode = MODE_PLAN
        self.mission = Mission(self.eph, self.sheet, ch.seed)
        self.cloud_tli = CloudStats()
        self.cloud_mcc = CloudStats()
        self.cloud_ms = 0.0

    def clouds(mut self, ctx: DeviceContext) raises:
        """Two clouds of 4 096: the S-IVB's errors flown to the Moon, and
        what tracking leaves after a correction at TLI + 24 h."""
        if not self.sheet.ok:
            return
        var t0 = perf_counter_ns()
        var jde_tli = self.sheet.jde_tli
        var a = self.sheet.transfer.correction.arrival
        var r_inj = self.sheet.transfer.injection.r
        var v_park = self.sheet.transfer.injection.v_park
        var v_tli = self.sheet.transfer.correction.v
        var bodies = Bodies(self.eph, jde_tli, self.ch.tof_h / 24.0 + 0.6)
        var pole = bodies.moon_at(a.t_p).cross(self.eph.moon_velocity(jde_tli + a.t_p / 86400.0)).unit()
        var rng = Rng(UInt64(self.ch.seed))
        var c1 = tli_cloud(rng, r_inj, v_park, v_tli, 4096)
        fly_cloud(c1, ctx, bodies, a.t_p + 6.0 * 3600.0)
        self.cloud_tli = cloud_stats(c1, pole)
        var t_mcc = 24.0 * 3600.0
        var at = bodies.run(r_inj, v_tli, 0.0, t_mcc, 1024.0, F_ALL)
        var f = 1.0 / sqrt(1.0 + 24.0 / 12.0)
        var c2 = tracked_cloud(rng, at.r, at.v, t_mcc, 4096, TRACK_POS_SIGMA * f, TRACK_VEL_SIGMA * f)
        fly_cloud(c2, ctx, bodies, a.t_p + 6.0 * 3600.0)
        self.cloud_mcc = cloud_stats(c2, pole)
        self.cloud_ms = Float64(perf_counter_ns() - t0) / 1e6

    def rebuild_map(mut self):
        self.wm = WindowMap(self.eph, self.ch.year, self.ch.month, launch_sites()[self.ch.pad], landing_sites()[self.ch.target], 60.0, 120.0, 48, 480)
        self.map_ready = False
        if self.ch.day > self.wm.days:
            self.ch.day = self.wm.days

    def compute_map_on(mut self, ctx: DeviceContext) raises:
        compute_map(self.wm, ctx)
        self.map_best = 1.0e30
        for i in range(self.wm.width * self.wm.height):
            var fl = Int(self.wm.cells[i * FIELDS + F_FLAGS])
            if fl & FLAG_CORRIDOR != 0 and fl & FLAG_LIT != 0 and fl & FLAG_RISING != 0 and fl & FLAG_OK != 0:
                var dv = Float64(self.wm.cells[i * FIELDS + F_DV_TLI]) + Float64(self.wm.cells[i * FIELDS + F_DV_LOI])
                if dv < self.map_best:
                    self.map_best = dv
        self.map_ready = True

    def replan(mut self, ctx: DeviceContext) raises:
        """The sheet, the plot's geometry in every frame, and the clouds."""
        self.sheet = make_plan(self.eph, self.wm, self.ch)
        self.clouds(ctx)
        var bodies = Bodies(self.eph, self.sheet.jde_tli, self.ch.tof_h / 24.0 + 4.0)
        self.t_p = self.sheet.transfer.correction.arrival.t_p
        var jde_p = self.sheet.jde_tli + self.t_p / 86400.0
        self.moon_p = bodies.moon_at(self.t_p)
        self.sun_e = self.eph.sun_position(self.sheet.jde_tli).unit()
        self.sun_m = (self.eph.sun_position(jde_p) - self.eph.moon_position(jde_p)).unit()
        self.mf = self.eph.moon_frame(jde_p)
        var site = landing_sites()[self.ch.target]
        self.site_dir = self.mf.to_inertial(site.lat, site.lon)
        var theta = gmst_deg(self.sheet.jd_tli) * DEG
        self.ex = Vec3(cos(theta), sin(theta), 0.0)
        self.ey = Vec3(-sin(theta), cos(theta), 0.0)
        # The Moon's path, hourly, from a day before TLI to three after perilune.
        self.moon_path = List[Float64]()
        var hours = Int(self.t_p / 3600.0) + 72
        for hh in range(-24, hours):
            var m = bodies.moon_at(Float64(hh) * 3600.0)
            self.moon_path.append(m.x)
            self.moon_path.append(m.y)
            self.moon_path.append(m.z)
        # The parking orbit: a circle in the plane through the injection point.
        self.park = List[Float64]()
        var inj = self.sheet.transfer.injection
        var rhat = inj.r.unit()
        var n = self.sheet.plane.unit()
        var that = n.cross(rhat)
        var rr = inj.r.norm()
        for k in range(73):
            var a = Float64(k) * 5.0 * DEG
            var p = rhat * (rr * cos(a)) + that * (rr * sin(a))
            self.park.append(p.x)
            self.park.append(p.y)
            self.park.append(p.z)
        # Moon-centred: the arc relative to the Moon at each sample's time.
        self.arc_moon = List[Float64]()
        var cnt = len(self.sheet.arc) // 7
        for i in range(cnt):
            var t = self.sheet.arc[i * 7]
            var m = bodies.moon_at(t)
            self.arc_moon.append(self.sheet.arc[i * 7 + 1] - m.x)
            self.arc_moon.append(self.sheet.arc[i * 7 + 2] - m.y)
            self.arc_moon.append(self.sheet.arc[i * 7 + 3] - m.z)
        # Rotating: each sample turned back by the Moon's travel since TLI.
        var pole = self.moon_p.cross(self.eph.moon_velocity(jde_p)).unit()
        var ref0 = bodies.moon_at(0.0)
        self.rot_pole = pole
        self.rot_ref0 = ref0
        self.arc_rot = List[Float64]()
        for i in range(cnt):
            var t = self.sheet.arc[i * 7]
            var m = bodies.moon_at(t)
            var ang = atan2(pole.dot(ref0.cross(m)), ref0.dot(m))
            var p = rotate_about(Vec3(self.sheet.arc[i * 7 + 1], self.sheet.arc[i * 7 + 2], self.sheet.arc[i * 7 + 3]), pole, -ang)
            self.arc_rot.append(p.x)
            self.arc_rot.append(p.y)
            self.arc_rot.append(p.z)
        self.moon_rot = rotate_about(self.moon_p, pole, -atan2(pole.dot(ref0.cross(self.moon_p)), ref0.dot(self.moon_p)))
        self.earth_rot_path = List[Float64]()

    # ── input ────────────────────────────────────────────────────────────

    def adjust(mut self, delta: Int) -> Int:
        """Change the selected choice by one step. Returns 1 for a replan,
        2 for a map rebuild too, 0 for nothing."""
        var r = self.row
        if r == ROW_PAD:
            self.ch.pad = (self.ch.pad + delta + len(launch_sites())) % len(launch_sites())
            return 2
        if r == ROW_TARGET:
            self.ch.target = (self.ch.target + delta + len(landing_sites())) % len(landing_sites())
            return 2
        if r == ROW_MONTH:
            self.ch.month += delta
            if self.ch.month > 12:
                self.ch.month = 1
                self.ch.year += 1
            if self.ch.month < 1:
                self.ch.month = 12
                self.ch.year -= 1
            return 2
        if r == ROW_DAY:
            self.ch.day += delta
            if self.ch.day < 1:
                self.ch.day = 1
            if self.ch.day > self.wm.days:
                self.ch.day = self.wm.days
            return 1
        if r == ROW_HOUR:
            self.ch.hour += Float64(delta) * 0.25
            if self.ch.hour < 0.0:
                self.ch.hour = 0.0
            if self.ch.hour > 23.75:
                self.ch.hour = 23.75
            return 1
        if r == ROW_TOF:
            self.ch.tof_h += Float64(delta) * 1.0
            if self.ch.tof_h < 60.0:
                self.ch.tof_h = 60.0
            if self.ch.tof_h > 120.0:
                self.ch.tof_h = 120.0
            return 1
        if r == ROW_REV:
            self.ch.revs = 3 if self.ch.revs == 2 else 2
            return 1
        if r == ROW_PERI:
            self.ch.peri_alt += Float64(delta) * 10.0
            if self.ch.peri_alt < 60.0:
                self.ch.peri_alt = 60.0
            if self.ch.peri_alt > 300.0:
                self.ch.peri_alt = 300.0
            return 1
        if r == ROW_ORIENT:
            self.ch.orient = 1 - self.ch.orient
            return 1
        if r == ROW_DESCENT:
            self.ch.descent_peri += Float64(delta) * 5.0
            if self.ch.descent_peri < 10.0:
                self.ch.descent_peri = 10.0
            if self.ch.descent_peri > 30.0:
                self.ch.descent_peri = 30.0
            return 1
        if r == ROW_HOVER:
            self.ch.hover_s += Float64(delta) * 30.0
            if self.ch.hover_s < 0.0:
                self.ch.hover_s = 0.0
            if self.ch.hover_s > 300.0:
                self.ch.hover_s = 300.0
            return 1
        if r == ROW_MCC:
            self.ch.mcc_policy = (self.ch.mcc_policy + delta + 4) % 4
            return 1
        if r == ROW_SEED:
            self.ch.seed += delta
            return 1
        return 0

    def go(mut self):
        """Commit the plan: the mission starts on the pad at GET 0."""
        self.mission = Mission(self.eph, self.sheet, self.ch.seed)
        self.mission.mcc_threshold = mcc_threshold(self.ch.mcc_policy)
        self.mission.warp = 60.0
        self.mode = MODE_TRACK

    def rot(self, p: Vec3, get: Float64) -> Vec3:
        """A position at that GET, in the rotating frame."""
        var m = self.mission.bodies.moon_at(get - self.mission.tab0)
        var ang = atan2(self.rot_pole.dot(self.rot_ref0.cross(m)), self.rot_ref0.dot(m))
        return rotate_about(p, self.rot_pole, -ang)

    def draw_track(self, cv: Canvas):
        """The flown course and the spacecraft, in the current frame."""
        let ms = self.mission
        var pts = List[Float64]()
        var n = len(ms.track) // 4
        for i in range(n):
            var g = ms.track[i * 4]
            var p = Vec3(ms.track[i * 4 + 1], ms.track[i * 4 + 2], ms.track[i * 4 + 3])
            if self.view == VIEW_MOON:
                p = p - ms.bodies.moon_at(g - ms.tab0)
            elif self.view == VIEW_ROT:
                p = self.rot(p, g)
            pts.append(p.x)
            pts.append(p.y)
            pts.append(p.z)
        var here = ms.r
        if self.view == VIEW_MOON:
            here = here - ms.moon()
        elif self.view == VIEW_ROT:
            here = self.rot(here, ms.get)
        var centre = Vec3(0.0, 0.0, 0.0)
        if self.view == VIEW_EARTH:
            centre = self.moon_p * 0.5
        elif self.view == VIEW_ROT:
            centre = self.moon_rot * 0.5
        var cam = Camera(centre, self.yaw, self.pitch, self.dist, 40.0)
        draw_polyline(cv, cam, pts, 3, 0, C_ORANGE0, 16)
        var sp = cam.project(here, cv.w, cv.h)
        if sp.ok:
            cv.disc(sp.x, sp.y, 2.5, C_ORANGE0 + 15)
            cv.box(Int(sp.x) - 5, Int(sp.y) - 5, 11, 11, C_ORANGE0 + 8)

    def default_camera(mut self):
        if self.view == VIEW_MOON:
            self.dist = 24000.0
        elif self.view == VIEW_ROT:
            self.dist = 560000.0
        else:
            self.dist = 560000.0
        self.yaw = 35.0
        self.pitch = 28.0

    # ── the plot ─────────────────────────────────────────────────────────

    def draw_descent(self, cv: Canvas):
        """The side view: downrange along the ground across, altitude up,
        the ground as it is along the approach, the trail, the LM and its
        thrust. The view closes in as the LM does."""
        let d = self.mission.descent
        var l = d.truth_local()
        var dr = d.downrange()
        var alt = d.altitude()
        var span = -dr * 1.15 + 600.0
        if span < 1500.0:
            span = 1500.0
        var x0 = -span + 400.0
        var x1 = 400.0
        var top = alt * 1.25 + 60.0
        if top < 250.0:
            top = 250.0
        var sx = Float64(cv.w) / (x1 - x0)
        # The surface sits clear of the legend band at the foot of the
        # pane: the text plane's rows are 8 px, and the two legend lines
        # start at row 46, so nothing may be drawn below 46 * 8.
        var legend_y = (cv.h // 8 - 4) * 8
        var base = Float64(legend_y - 12)
        var sy = base / top
        # The ground along the approach line, at the LM's cross-range.
        var prev_py = base
        for i in range(cv.w):
            var gx = x0 + Float64(i) / sx
            var gh = d.terrain.height(gx, l.y)
            var py = base - gh * sy
            if i > 0:
                cv.line(Float64(i - 1), prev_py, Float64(i), py, C_MOON0 + 20)
            var yy = Int(py) + 1
            while yy < legend_y - 2:
                cv.plot(i, yy, C_MOON0 + 5)
                yy += 1
            prev_py = py
        # Craters and boulder fields, as marks under the ground line.
        for i in range(len(d.terrain.craters) // 4):
            var cx = d.terrain.craters[i * 4]
            var cr = d.terrain.craters[i * 4 + 2]
            var ax = (cx - cr - x0) * sx
            var bx = (cx + cr - x0) * sx
            if bx >= 0.0 and ax <= Float64(cv.w):
                cv.line(ax, base + 6.0, bx, base + 6.0, C_RED)
        for i in range(len(d.terrain.fields) // 4):
            var fx = d.terrain.fields[i * 4]
            var fr = d.terrain.fields[i * 4 + 2]
            var ax = (fx - fr - x0) * sx
            var bx = (fx + fr - x0) * sx
            if bx >= 0.0 and ax <= Float64(cv.w):
                cv.line(ax, base + 10.0, bx, base + 10.0, C_AMBER)
        # The site and the aim.
        cv.line((0.0 - x0) * sx, 0.0, (0.0 - x0) * sx, base, C_MAGENTA0 + 5)
        cv.line((d.aim_x - x0) * sx, base - 30.0, (d.aim_x - x0) * sx, base, C_MAGENTA0 + 15)
        # The trail.
        var n = len(d.trail) // 4
        var ppx = 0.0
        var ppy = 0.0
        for i in range(n):
            var px = (d.trail[i * 4 + 1] - x0) * sx
            var py = base - d.trail[i * 4 + 3] * sy
            if i > 0:
                cv.line(ppx, ppy, px, py, C_ORANGE0 + 8)
            ppx = px
            ppy = py
        # The LM, and where its engine points.
        var lx = (dr - x0) * sx
        var ly = base - alt * sy
        cv.disc(lx, ly, 3.0, C_ORANGE0 + 15)
        var zh = d.site_at(d.t).unit()
        var xh = d.axes_at(d.t)
        var tx = d.thrust_dir.dot(xh)
        var tz = d.thrust_dir.dot(zh)
        var flame = 12.0 + 24.0 * d.throttle
        cv.line(lx, ly, lx - tx * flame, ly + tz * flame, C_AMBER)
        # Scale marks: the altitude at the top, the range at the left.
        cv.line(0.0, 2.0, 0.0, base, C_GRID)
        cv.line(0.0, base, Float64(cv.w), base, C_GRID)

    def draw_plot(self, cv: Canvas):
        cv.clear(C_BG)
        if self.mode == MODE_TRACK and (self.mission.phase == PHASE_DESCENT or (self.mission.phase == PHASE_DONE and self.mission.descent.t > 0.0)):
            self.draw_descent(cv)
            return
        if self.view == VIEW_MAP:
            self.draw_map(cv)
            return
        let s = self.sheet
        # The bodies are drawn where they are at the moment shown: the
        # planned perilune in PLAN, the mission's clock in TRACK.
        var moon_now = self.moon_p
        var mf_now = self.mf
        var sun_m_now = self.sun_m
        var sun_e_now = self.sun_e
        var ex_now = self.ex
        var ey_now = self.ey
        var site_now = self.site_dir
        if self.mode == MODE_TRACK:
            var jd_now = self.mission.jd()
            var jde_now = jde_from_ut(jd_now)
            moon_now = self.mission.moon()
            mf_now = self.eph.moon_frame(jde_now)
            sun_m_now = (self.eph.sun_position(jde_now) - moon_now).unit()
            sun_e_now = self.eph.sun_position(jde_now).unit()
            var th = gmst_deg(jd_now) * DEG
            ex_now = Vec3(cos(th), sin(th), 0.0)
            ey_now = Vec3(-sin(th), cos(th), 0.0)
            var site = landing_sites()[self.ch.target]
            site_now = mf_now.to_inertial(site.lat, site.lon)
        if self.view == VIEW_EARTH:
            var cam = Camera(self.moon_p * 0.5, self.yaw, self.pitch, self.dist, 40.0)
            draw_polyline(cv, cam, self.moon_path, 3, 0, C_GREEN0, 16)
            draw_polyline(cv, cam, self.park, 3, 0, C_GREEN0, 16)
            draw_polyline(cv, cam, s.arc, 7, 1, C_CYAN0, 16)
            draw_body(cv, cam, Vec3(0.0, 0.0, 0.0), R_EARTH, sun_e_now, ex_now, ey_now, Vec3(0.0, 0.0, 1.0), C_EARTH0)
            draw_body(cv, cam, moon_now, R_MOON, sun_m_now, mf_now.x, mf_now.y, mf_now.z, C_MOON0)
            var sp = body_point(cam, moon_now, R_MOON, site_now, cv.w, cv.h)
            if sp.ok:
                cv.disc(sp.x, sp.y, 2.0, C_MAGENTA0 + 15)
        elif self.view == VIEW_MOON:
            var cam = Camera(Vec3(0.0, 0.0, 0.0), self.yaw, self.pitch, self.dist, 40.0)
            draw_polyline(cv, cam, self.arc_moon, 3, 0, C_CYAN0, 16)
            draw_body(cv, cam, Vec3(0.0, 0.0, 0.0), R_MOON, sun_m_now, mf_now.x, mf_now.y, mf_now.z, C_MOON0)
            var sp = body_point(cam, Vec3(0.0, 0.0, 0.0), R_MOON, site_now, cv.w, cv.h)
            if sp.ok:
                cv.disc(sp.x, sp.y, 2.5, C_MAGENTA0 + 15)
            # The Earth, far off.
            var ep = cam.project(-moon_now, cv.w, cv.h)
            if ep.ok:
                cv.disc(ep.x, ep.y, 2.0, C_EARTH0 + SHADES - 1)
        else:
            var centre = self.moon_rot * 0.5
            var cam = Camera(centre, self.yaw, self.pitch, self.dist, 40.0)
            draw_polyline(cv, cam, self.arc_rot, 3, 0, C_CYAN0, 16)
            draw_body(cv, cam, Vec3(0.0, 0.0, 0.0), R_EARTH, sun_e_now, ex_now, ey_now, Vec3(0.0, 0.0, 1.0), C_EARTH0)
            var mr = self.moon_rot if self.mode == MODE_PLAN else self.rot(moon_now, self.mission.get)
            draw_body(cv, cam, mr, R_MOON, sun_m_now, mf_now.x, mf_now.y, mf_now.z, C_MOON0)
        if self.mode == MODE_TRACK:
            self.draw_track(cv)

    def draw_map(self, cv: Canvas):
        """The month at the chosen flight time: a column per day, launch
        hour down the column, and a box on the chosen minute."""
        if not self.map_ready:
            return
        let wm = self.wm
        var colw = Float64(cv.w) / Float64(wm.days)
        var k = wm.x_of(1, self.ch.tof_h) % wm.steps
        for y in range(cv.h):
            var my = y * wm.height // cv.h
            for x in range(cv.w):
                var day = Int(Float64(x) / colw)
                if day >= wm.days:
                    day = wm.days - 1
                var mx = day * wm.steps + k
                var i = my * wm.width + mx
                var fl = Int(wm.cells[i * FIELDS + F_FLAGS])
                var idx = C_MAP_DARK
                if fl & FLAG_OK == 0:
                    idx = C_MAP_BAD
                elif fl & FLAG_CORRIDOR != 0:
                    var dv = Float64(wm.cells[i * FIELDS + F_DV_TLI]) + Float64(wm.cells[i * FIELDS + F_DV_LOI])
                    var u = (dv - self.map_best) / 0.5
                    u = 0.0 if u < 0.0 else (1.0 if u > 1.0 else u)
                    if fl & FLAG_LIT != 0 and fl & FLAG_RISING != 0:
                        idx = C_MAP0 + 16 + Int(u * 31.0)
                    else:
                        idx = C_MAP0 + Int((1.0 - u) * 15.0)
                if Int(Float64(x) - Float64(day) * colw) == 0:
                    idx = C_GRID
                cv.plot(x, y, idx)
        var bx = Int(Float64(self.ch.day - 1) * colw)
        var by = Int(self.ch.hour / 24.0 * Float64(cv.h))
        cv.box(bx - 1, by - 3, Int(colw) + 2, 7, C_MAP_MARK)


def write_line(text: TextPlane, row: Int, s: String, fg: Int):
    """One panel line, padded to the panel's width."""
    var n = 0
    for c in s.codepoints():
        if n < PANEL_COLS:
            text.put(PANEL_COL + n, row, Int(c.to_u32()), fg, T_BG)
        n += 1
    while n < PANEL_COLS:
        text.put(PANEL_COL + n, row, 32, fg, T_BG)
        n += 1


def pad_to(s: String, n: Int) -> String:
    var out = s
    while out.byte_length() < n:
        out += " "
    return out


def main() raises:
    if not load_framework["Metal"]():
        raise Error("could not load Metal")
    var headless = getenv("GAMEPANE_FRAMES") != ""
    var shot = getenv("MOONSHOT_SHOT")

    var pane = GamePane(String("Moonshot — Flight Dynamics"), WIN_W, WIN_H)
    var screen = DirectPane(pane.device, PW, PH)
    var text = TextPlane(pane.device, PW, PH)
    for i in range(256):
        var c = palette_rgb(i)
        screen.set_rgb(i, Int(c.x), Int(c.y), Int(c.z))
    text.set_rgb(T_BG, 10, 12, 22)
    text.set_rgb(T_TEXT, 190, 200, 210)
    text.set_rgb(T_DIM, 100, 110, 125)
    text.set_rgb(T_HI, 255, 255, 255)
    text.set_rgb(T_RED, 255, 80, 80)
    text.set_rgb(T_AMBER, 255, 190, 60)
    text.set_rgb(T_GREEN, 90, 230, 120)
    text.set_rgb(T_HEAD, 90, 210, 255)
    text.set_rgb(T_BLACK, 0, 0, 0)

    var snd = Sound(not headless)
    var log_seen = 0
    var tick_at = 0.0
    var eph = Ephemeris()
    var con = Console(eph^, apollo_11_choices())
    con.replan(pane.ctx)
    con.compute_map_on(pane.ctx)
    var want_view = getenv("MOONSHOT_VIEW")
    if want_view == "moon":
        con.view = VIEW_MOON
        con.default_camera()
    elif want_view == "rot":
        con.view = VIEW_ROT
        con.default_camera()
    elif want_view == "map":
        con.view = VIEW_MAP
    if getenv("MOONSHOT_MODE") == "track":
        var pol = getenv("MOONSHOT_POLICY")
        if pol != "":
            con.ch.mcc_policy = atol(pol)
            con.replan(pane.ctx)
        con.go()
        var hours = getenv("MOONSHOT_GET")
        var minutes = getenv("MOONSHOT_GETM")
        if hours != "" or minutes != "":
            var target = Float64(atol(hours)) * 3600.0 if hours != "" else Float64(atol(minutes)) * 60.0
            con.mission.warp = 3600.0
            while target - con.mission.get > 0.5 and con.mission.phase != PHASE_DONE:
                var chunk = target - con.mission.get
                if chunk > 3600.0:
                    chunk = 3600.0
                con.mission.advance(chunk / con.mission.warp)
        con.mission.warp = 600.0
    var keys = Keys()
    var stride = screen.stride_bytes()
    var choice_names = List[String]()
    for nm in ["pad", "target", "month", "day", "hour UTC", "flight", "TLI rev", "LOI orbit", "orient", "descent", "hover", "MCC", "seed"]:
        choice_names.append(String(nm))
    var orient_names = List[String]()
    orient_names.append(String("as launched"))
    orient_names.append(String("over the site, retro"))
    var mcc_names = List[String]()
    for nm in ["correct > 0.3 m/s", "correct > 1 m/s", "correct > 3 m/s", "never correct"]:
        mcc_names.append(String(nm))
    var month_names = List[String]()
    for nm in ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]:
        month_names.append(String(nm))

    while pane.pump():
        keys.poll()
        if not headless and keys.pressed(KEY_ESCAPE):
            break
        # choices, or the mission's clock
        var need = 0
        if con.mode == MODE_PLAN:
            if keys.pressed(KEY_UP):
                con.row = (con.row + ROW_COUNT - 1) % ROW_COUNT
            if keys.pressed(KEY_DOWN):
                con.row = (con.row + 1) % ROW_COUNT
            if keys.pressed(KEY_LEFT):
                need = con.adjust(-1)
            if keys.pressed(KEY_RIGHT):
                need = con.adjust(1)
            if need == 2:
                con.rebuild_map()
                con.compute_map_on(pane.ctx)
            if need >= 1:
                con.replan(pane.ctx)
            if keys.pressed(KEY_RETURN) and is_go(con.sheet):
                con.go()
                log_seen = 0
                if con.view == VIEW_MAP:
                    con.view = VIEW_EARTH
                    con.default_camera()
        else:
            if keys.pressed(KEY_1):
                con.mission.warp = 1.0
            if keys.pressed(KEY_2):
                con.mission.warp = 60.0
            if keys.pressed(KEY_3):
                con.mission.warp = 600.0
            if keys.pressed(KEY_4):
                con.mission.warp = 3600.0
            if keys.pressed(KEY_SPACE):
                con.mission.paused = not con.mission.paused
            if keys.pressed(letter_key(15)):
                con.mode = MODE_PLAN
            if keys.pressed(letter_key(6)):
                con.mission.descent.call_alarm(True)
            if keys.pressed(letter_key(13)):
                con.mission.descent.call_alarm(False)
            con.mission.advance(pane.dt())
            # Every new line in the log is a call from the trench.
            while log_seen < len(con.mission.log):
                var line = con.mission.log[log_seen]
                log_seen += 1
                if line.find("ALARM") >= 0 or line.find("LOST") >= 0 or line.find("NO LOI") >= 0 or line.find("abort") >= 0 or line.find("ABORTED") >= 0:
                    snd.alarm()
                elif line.find("LANDED") >= 0:
                    snd.touchdown()
                else:
                    snd.quindar()
            if con.mission.warp <= 1.0 and not con.mission.paused:
                tick_at += pane.dt()
                if tick_at >= 1.0:
                    tick_at = 0.0
                    snd.tick()
        # views
        if keys.pressed(letter_key(4)):
            con.view = VIEW_EARTH
            con.default_camera()
        if keys.pressed(letter_key(12)):
            con.view = VIEW_MOON
            con.default_camera()
        if keys.pressed(letter_key(17)):
            con.view = VIEW_ROT
            con.default_camera()
        if keys.pressed(letter_key(22)) and con.mode == MODE_PLAN:
            con.view = VIEW_MAP
        if keys.held(KEY_Z):
            con.dist *= 1.03
        if keys.held(KEY_X):
            con.dist /= 1.03
        # the camera, by mouse
        var ms = mouse_state()
        if ms.left and ms.x < Float64(PLOT_W) / Float64(PW):
            if con.dragging:
                con.yaw += (ms.x - con.drag_x) * 360.0
                con.pitch += (ms.y - con.drag_y) * 180.0
            con.dragging = True
            con.drag_x = ms.x
            con.drag_y = ms.y
        else:
            con.dragging = False

        # draw
        var cv = Canvas(screen.backbuffer_ptr(), stride, 0, 0, PLOT_W, PLOT_H)
        con.draw_plot(cv)
        # the panel's background column
        var rest = Canvas(screen.backbuffer_ptr(), stride, PLOT_W, 0, PW - PLOT_W, PH)
        rest.clear(C_BG)

        text.clear()
        let s = con.sheet
        var ch = con.ch
        # over the plot
        var view_name = String("EARTH-CENTRED") if con.view == VIEW_EARTH else (String("MOON-CENTRED") if con.view == VIEW_MOON else (String("ROTATING FRAME") if con.view == VIEW_ROT else String("LAUNCH WINDOWS  ") + month_names[ch.month - 1] + " " + String(ch.year)))
        text.write(1, 0, String("MOONSHOT  FLIGHT DYNAMICS   ") + view_name, T_HEAD, T_BG, FLAG_TRANSPARENT_BG)
        text.write(1, 48, String("E M R course  W windows  drag orbit  Z/X zoom  arrows choose"), T_DIM, T_BG, FLAG_TRANSPARENT_BG)
        if con.view == VIEW_MAP:
            text.write(1, 46, String("day across, hour down, ") + fmt(ch.tof_h, 0) + " h flight: blue corridor, green lit", T_DIM, T_BG, FLAG_TRANSPARENT_BG)
        elif con.mode == MODE_TRACK and (con.mission.phase == PHASE_DESCENT or con.mission.descent.t > 0.0):
            text.write(1, 46, String("downrange across, altitude up: ground profile, craters red, site and aim magenta"), T_DIM, T_BG, FLAG_TRANSPARENT_BG)
        else:
            text.write(1, 46, String("cyan course   green Moon path, parking orbit   magenta site"), T_DIM, T_BG, FLAG_TRANSPARENT_BG)

        # the panel
        var r = 0
        if con.mode == MODE_TRACK:
            let ms = con.mission
            write_line(text, r, String(" TRACK   GET ") + get_string(ms.jd(), ms.jd_launch) + "  " + utc_string(ms.jd()), T_HEAD)
            r += 1
            write_line(text, r, String("  warp ") + fmt(ms.warp, 0) + "x  seed " + String(ms.seed) + "  " + (String("PAUSED") if ms.paused else phase_name(ms.phase)), T_TEXT)
            r += 1
            var ni = ms.next_event()
            if ni >= 0:
                var togo = ms.events[ni].get - ms.get
                write_line(text, r, String("  next  ") + ms.events[ni].name + " in " + get_string(ms.jd_launch + togo / 86400.0, ms.jd_launch), T_HI)
            else:
                write_line(text, r, String("  next  --"), T_DIM)
            r += 2
            if ms.phase == PHASE_DESCENT or (ms.outcome != "" and ms.descending == False and ms.descent.t > 0.0):
                let d = ms.descent
                var alt = d.altitude()
                write_line(text, r, String(" DESCENT  ") + phase_label(d.phase) + "  t+" + fmt(d.t, 0) + " s", T_HEAD)
                r += 1
                write_line(text, r, String("  altitude ") + fmt(alt, 0) + " m   rate " + fmt(d.descent_rate(), 1) + " m/s down", T_TEXT)
                r += 1
                write_line(text, r, String("  ground speed ") + fmt(d.ground_speed(), 1) + " m/s   pitch " + fmt(d.pitch_deg(), 0) + " deg", T_TEXT)
                r += 1
                write_line(text, r, String("  throttle ") + fmt(d.throttle * 100.0, 0) + " pct   t-go " + fmt(d.t_go, 0) + " s", T_TEXT)
                r += 1
                var hov = d.hover_seconds()
                write_line(text, r, String("  hover ") + fmt(hov, 0) + " s   reserve " + fmt(d.reserve_s, 0) + " s   dv " + fmt(d.dv_used, 0) + " m/s", T_RED if hov < d.reserve_s else (T_AMBER if hov < d.reserve_s + 30.0 else T_TEXT))
                r += 1
                write_line(text, r, String("  radar ") + (String("locked") if d.radar_locked else String("--")) + "   redesignated " + String(d.redesignations) + "x   aim " + fmt(d.aim_x, 0) + " m", T_TEXT)
                r += 1
                if d.alarm_state == 1:
                    write_line(text, r, String("  1202 PROGRAM ALARM   G go   N abort"), T_RED)
                    r += 1
                elif d.alarm_state == 2:
                    write_line(text, r, String("  1202 alarm: GO (the rule: unless it recurs)"), T_AMBER)
                    r += 1
                if ms.outcome != "":
                    r += 1
                    write_line(text, r, String(" DEBRIEF  ") + ms.outcome, T_GREEN if d.phase == LANDED and not d.damaged else (T_AMBER if d.phase == LANDED else T_RED))
                    r += 1
                    write_line(text, r, String("  ") + d.outcome_reason, T_TEXT)
                    r += 1
                    write_line(text, r, String("  ") + fmt(d.t / 60.0, 1) + " min, " + fmt(d.dv_used, 0) + " m/s, " + fmt(hov, 0) + " s hover left", T_TEXT)
                    r += 1
                    write_line(text, r, String("  ") + fmt(sqrt(d.landed_x * d.landed_x + d.landed_y * d.landed_y), 0) + " m from the site", T_TEXT)
                    r += 1
                    write_line(text, r, String("  TLI missed ") + fmt(ms.tli_error, 1) + " m/s, corrections " + fmt(ms.mcc_total * 1000.0, 1) + " m/s", T_TEXT)
                    r += 1
                    write_line(text, r, String("  why: ") + responsible(ms, ch), T_HI)
                    r += 1
                    write_line(text, r, String("  seed ") + String(ms.seed) + ": same seed, same luck", T_DIM)
                    r += 1
                r += 1
            elif ms.outcome != "":
                write_line(text, r, String(" DEBRIEF  ") + ms.outcome, T_GREEN if ms.outcome == "HOME" else T_RED)
                r += 1
                write_line(text, r, String("  ") + ms.outcome_reason, T_TEXT)
                r += 1
                write_line(text, r, String("  LOI was off: ") + ms.loi_off_reason, T_TEXT)
                r += 1
                if ms.return_dv != 0.0:
                    write_line(text, r, String("  DPS burn home ") + fmt(ms.return_dv * 1000.0, 0) + " m/s", T_TEXT)
                    r += 1
                write_line(text, r, String("  why: ") + responsible(ms, ch), T_HI)
                r += 1
                write_line(text, r, String("  seed ") + String(ms.seed) + ": same seed, same luck", T_DIM)
                r += 2
            var about = String("Moon") if ms.near_moon() else String("Earth")
            write_line(text, r, String(" TRACKED STATE  (about the ") + about + ")", T_HEAD)
            r += 1
            var rr = ms.est_r - ms.moon() if ms.near_moon() else ms.est_r
            var vv = ms.est_v - ms.moon_v() if ms.near_moon() else ms.est_v
            var body_r = R_MOON if ms.near_moon() else R_EARTH
            write_line(text, r, String("  r ") + fmt(rr.norm(), 0) + " km   alt " + fmt(rr.norm() - body_r, 0) + " km", T_TEXT)
            r += 1
            write_line(text, r, String("  v ") + fmt(vv.norm(), 3) + " km/s", T_TEXT)
            r += 1
            write_line(text, r, String("  x ") + fmt(rr.x, 0) + "  y " + fmt(rr.y, 0) + "  z " + fmt(rr.z, 0), T_DIM)
            r += 1
            write_line(text, r, String("  vx ") + fmt(vv.x, 4) + " vy " + fmt(vv.y, 4) + " vz " + fmt(vv.z, 4), T_DIM)
            r += 1
            if ms.phase >= PHASE_PARKING:
                var el = ms.rel_elements()
                if el.e < 1.0:
                    var inc = ms.lunar_inclination() if ms.near_moon() else el.i
                    write_line(text, r, String("  orbit ") + fmt(el.a * (1.0 - el.e) - body_r, 0) + " x " + fmt(el.a * (1.0 + el.e) - body_r, 0) + " km  i " + fmt(inc, 1) + "  e " + fmt(el.e, 3), T_TEXT)
                else:
                    write_line(text, r, String("  hyperbolic, e ") + fmt(el.e, 3) + "  incl " + fmt(el.i, 1), T_TEXT)
            r += 1
            write_line(text, r, String("  Earth ") + fmt(ms.r.norm(), 0) + " km   Moon " + fmt((ms.r - ms.moon()).norm(), 0) + " km", T_TEXT)
            r += 1
            if ms.phase == PHASE_TRANSLUNAR:
                write_line(text, r, String("  vs plan ") + fmt(ms.divergence, 1) + " km   MCC spent " + fmt(ms.mcc_total * 1000.0, 1) + " m/s", T_GREEN if ms.divergence < 20.0 else T_AMBER)
            else:
                write_line(text, r, String("  MCC spent ") + fmt(ms.mcc_total * 1000.0, 1) + " m/s   SPS left " + fmt(ms.sps_kg, 0) + " kg", T_DIM)
            r += 2
            write_line(text, r, String(" MSFN COVERAGE"), T_HEAD)
            r += 1
            var names = List[String]()
            names.append(String("GDS"))
            names.append(String("MAD"))
            names.append(String("HSK"))
            var cov = String(" ")
            for i in range(3):
                var c = ms.contact[i]
                var e = c.elevation if c.elevation >= 0.0 else -c.elevation
                cov += " " + names[i] + " " + (String("+") if c.visible else (String("m") if c.occulted else String("-"))) + fmt(e, 0) + " "
            write_line(text, r, cov + (String("  IN CONTACT") if ms.in_contact else String("  NO CONTACT")), T_TEXT if ms.in_contact else T_AMBER)
            r += 2
            write_line(text, r, String(" BURNS       GET        m/s"), T_HEAD)
            r += 1
            for i in range(len(ms.events)):
                var ev = ms.events[i]
                if ev.kind == EV_INSERTION:
                    continue
                var dvs = fmt(ev.dv * 1000.0, 0) if ev.dv > 0.0 else String("--")
                write_line(text, r, String("  ") + pad_to(ev.name, 7) + get_string(ms.jd_launch + ev.get / 86400.0, ms.jd_launch) + "  " + pad_to(dvs, 5) + (String("  done") if ev.done else String("")), T_DIM if ev.done else T_TEXT)
                r += 1
            r += 1
            write_line(text, r, String(" LOG"), T_HEAD)
            r += 1
            var first = len(ms.log) - 14
            if first < 0:
                first = 0
            for i in range(first, len(ms.log)):
                write_line(text, r, String("  ") + ms.log[i], T_TEXT)
                r += 1
            while r < 48:
                write_line(text, r, String(""), T_TEXT)
                r += 1
            write_line(text, r, String(" 1-4 warp  space pause  P back to plan"), T_DIM)
            r += 1
            write_line(text, r, String(""), T_TEXT)
        else:
            write_line(text, r, String(" PLAN"), T_HEAD)
            r += 1
            for i in range(ROW_COUNT):
                var v = String("")
                if i == ROW_PAD:
                    v = launch_sites()[ch.pad].name
                elif i == ROW_TARGET:
                    v = landing_sites()[ch.target].name
                elif i == ROW_MONTH:
                    v = month_names[ch.month - 1] + " " + String(ch.year)
                elif i == ROW_DAY:
                    v = String(ch.day)
                elif i == ROW_HOUR:
                    var hh = Int(ch.hour)
                    var mm = Int((ch.hour - Float64(hh)) * 60.0 + 0.5)
                    v = (String("0") if hh < 10 else String("")) + String(hh) + ":" + (String("0") if mm < 10 else String("")) + String(mm)
                elif i == ROW_TOF:
                    v = fmt(ch.tof_h, 0) + " h to the Moon"
                elif i == ROW_REV:
                    v = String("revolution ") + String(ch.revs)
                elif i == ROW_PERI:
                    v = fmt(ch.peri_alt, 0) + " x " + fmt(ch.apo_alt, 0) + " km"
                elif i == ROW_ORIENT:
                    v = orient_names[ch.orient]
                elif i == ROW_DESCENT:
                    v = fmt(ch.descent_peri, 0) + " km perilune"
                elif i == ROW_HOVER:
                    v = fmt(ch.hover_s, 0) + " s reserve"
                elif i == ROW_MCC:
                    v = mcc_names[ch.mcc_policy]
                elif i == ROW_SEED:
                    v = String(ch.seed)
                var mark = String("> ") if i == con.row else String("  ")
                write_line(text, r, mark + pad_to(choice_names[i], 10) + v, T_HI if i == con.row else T_TEXT)
                r += 1
            r += 1
            write_line(text, r, String(" GEOMETRY"), T_HEAD)
            r += 1
            write_line(text, r, String("  azimuth ") + fmt(s.azimuth, 1) + "  incl " + fmt(s.inclination, 1) + "  " + (String("corridor") if s.corridor else String("NO corridor")), T_TEXT if s.corridor else T_RED)
            r += 1
            var wline = String("  windows")
            for k in range(len(s.windows) // 4):
                var oh = Int(s.windows[k * 4])
                var om = Int((s.windows[k * 4] - Float64(oh)) * 60.0 + 0.5)
                var chh = Int(s.windows[k * 4 + 1])
                var cm = Int((s.windows[k * 4 + 1] - Float64(chh)) * 60.0 + 0.5)
                wline += " " + (String("0") if oh < 10 else String("")) + String(oh) + ":" + (String("0") if om < 10 else String("")) + String(om) + "-" + (String("0") if chh < 10 else String("")) + String(chh) + ":" + (String("0") if cm < 10 else String("")) + String(cm)
            write_line(text, r, wline, T_TEXT)
            r += 1
            write_line(text, r, String("  Sun at site ") + fmt(s.sun_elev, 1) + (String(" rising") if s.sun_rising else String(" setting")) + (String("   lit") if s.lit else String("   DARK")), T_TEXT if s.lit and s.sun_rising else T_RED)
            r += 1
            var a = s.transfer.correction.arrival
            write_line(text, r, String("  v-inf ") + fmt(a.v_inf * 1000.0, 0) + " m/s  perilune " + fmt(a.r_p - R_MOON, 0) + " km " + (String("far") if a.far_side else String("NEAR")), T_TEXT)
            r += 1
            write_line(text, r, String("  lunar orbit ") + fmt(180.0 - s.inc_equator, 1) + " deg retro  Moon " + fmt(s.moon_dist, 0) + " km", T_TEXT)
            r += 1
            var crx = s.cross_range if s.cross_range >= 0.0 else -s.cross_range
            write_line(text, r, String("  site ") + fmt(crx, 1) + " km off the orbit plane at landing", T_TEXT if crx <= 5.0 else (T_AMBER if crx <= 20.0 else T_RED))
            r += 1
            if s.free_return:
                write_line(text, r, String("  free return: unburned perigee ") + fmt(s.return_perigee_alt, 0) + " km", T_TEXT)
            else:
                write_line(text, r, String("  NO free return: perigee ") + fmt(s.return_perigee_alt, 0) + " km", T_AMBER)
            r += 1
            var pc = con.cloud_mcc.p_corridor
            write_line(text, r, String("  corridor P ") + fmt(con.cloud_tli.p_corridor, 2) + " TLI  " + fmt(pc, 2) + " MCC-2 +-" + fmt(con.cloud_mcc.sigma_alt, 0) + " km", T_TEXT if pc >= 0.9 else T_AMBER)
            r += 2
            write_line(text, r, String(" TIMELINE  GET        UTC        m/s"), T_HEAD)
            r += 1
            write_line(text, r, String("  launch  ") + get_string(s.jd_launch, s.jd_launch) + "  " + utc_short(s.jd_launch), T_TEXT)
            r += 1
            write_line(text, r, String("  orbit   ") + get_string(s.jd_insertion, s.jd_launch) + "  " + utc_short(s.jd_insertion), T_TEXT)
            r += 1
            write_line(text, r, String("  TLI     ") + get_string(s.jd_tli_ign, s.jd_launch) + "  " + utc_short(s.jd_tli_ign) + "  " + fmt(s.dv_tli * 1000.0, 0) + " " + fmt(s.tli_seconds, 0) + "s", T_TEXT)
            r += 1
            write_line(text, r, String("  MCC-2   ") + get_string(s.jd_mcc2, s.jd_launch) + "  " + utc_short(s.jd_mcc2) + "   <" + fmt(MCC_BUDGET * 1000.0, 0), T_TEXT)
            r += 1
            write_line(text, r, String("  LOI-1   ") + get_string(s.jd_loi1_ign, s.jd_launch) + "  " + utc_short(s.jd_loi1_ign) + "   " + fmt(s.dv_loi1 * 1000.0, 0) + " " + fmt(s.loi1_seconds, 0) + "s", T_TEXT)
            r += 1
            write_line(text, r, String("  LOI-2   ") + get_string(s.jd_loi2, s.jd_launch) + "  " + utc_short(s.jd_loi2) + "    " + fmt(s.dv_loi2 * 1000.0, 0), T_TEXT)
            r += 1
            write_line(text, r, String("  DOI     ") + get_string(s.jd_doi, s.jd_launch) + "  " + utc_short(s.jd_doi) + "    " + fmt(s.dv_doi * 1000.0, 0), T_TEXT)
            r += 1
            write_line(text, r, String("  PDI     ") + get_string(s.jd_pdi, s.jd_launch) + "  " + utc_short(s.jd_pdi) + "  " + fmt(s.dv_descent * 1000.0, 0) + " est", T_TEXT)
            r += 1
            write_line(text, r, String("  landing ") + get_string(s.jd_landing, s.jd_launch) + "  " + utc_string(s.jd_landing), T_HI)
            r += 2
            write_line(text, r, String(" MASS & MARGINS          used   margin"), T_HEAD)
            r += 1
            write_line(text, r, String("  S-IVB  ") + fmt(SIVB_PROP, 0) + " kg  " + pad_to(fmt(s.sivb_used, 0), 7) + "  " + fmt(s.sivb_margin_dv * 1000.0, 0) + " m/s", T_RED if s.sivb_margin_kg < 0.0 else (T_AMBER if s.sivb_margin_dv < 0.02 else T_TEXT))
            r += 1
            write_line(text, r, String("  SPS    ") + fmt(SPS_PROP, 0) + " kg  " + pad_to(fmt(s.sps_used + s.sps_tei, 0), 7) + "  " + fmt(s.sps_margin_dv * 1000.0, 0) + " m/s", T_RED if s.sps_margin_kg < 0.0 else (T_AMBER if s.sps_margin_dv < 0.15 else T_TEXT))
            r += 1
            write_line(text, r, String("         of which TEI kept ") + fmt(s.sps_tei, 0) + " kg", T_DIM)
            r += 1
            write_line(text, r, String("  DPS      ") + fmt(DPS_PROP, 0) + " kg  " + pad_to(fmt(s.dps_used, 0), 7) + " " + fmt(s.dps_margin_s, 0) + " s hover", T_RED if s.dps_margin_kg < 0.0 else (T_AMBER if s.dps_margin_s < 30.0 else T_TEXT))
            r += 1
            write_line(text, r, String("  stack after TLI ") + fmt(s.mass_after_tli, 0) + " kg", T_DIM)
            r += 2
            if is_go(s):
                write_line(text, r, String(" FLIGHT DYNAMICS: GO"), T_GREEN)
            else:
                write_line(text, r, String(" FLIGHT DYNAMICS: NO GO"), T_RED)
            r += 1
            for i in range(len(s.red)):
                if r < 49:
                    write_line(text, r, String("  ") + s.red[i], T_RED)
                    r += 1
            for i in range(len(s.amber)):
                if r < 49:
                    write_line(text, r, String("  ") + s.amber[i], T_AMBER)
                    r += 1
            while r < 50:
                write_line(text, r, String(""), T_TEXT)
                r += 1
            if is_go(s):
                write_line(text, 49, String(" RETURN: GO -- fly it"), T_GREEN)

        with autoreleasepool():
            var frame = pane.begin_frame()
            screen.render(frame)
            text.render(frame)
            pane.end_frame(frame)
            if shot != "" and pane.frame_count() >= 2:
                var px = pane.read_frame(frame)
                if len(px) > 0:
                    var dw = pane.width * pane.zoom
                    var dh = pane.height * pane.zoom
                    var bgra = Pointer[UInt32, MutUntrackedOrigin](unsafe_from_address=Int(px.unsafe_ptr()))
                    if save_png(shot, bgra, dw, dh):
                        print("screenshot saved:", shot)
                shot = String("")

    snd.close()
    pane.close()
    print("presented", pane.frame_count(), "frames")
