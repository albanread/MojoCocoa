# ===----------------------------------------------------------------------=== #
# Moonshot — the powered descent (sprint MC8).
#
# Twelve minutes, flown by the guidance law Apollo flew (Klumpp's quartic,
# C19): the commanded acceleration is
#
#     a⃗_C = a⃗_T + 12 (r⃗_T − r⃗)/t_go² − 6 (v⃗_T + v⃗)/t_go
#
# with the target (r⃗_T, v⃗_T, a⃗_T) a "gate" -- high gate at the end of the
# braking phase, low gate at the end of the approach -- and t_go from the
# terminal-jerk condition solved every two-second guidance cycle. The
# vectors are inertial, Moon-centred, so the Moon's curvature costs
# nothing; the site frame is only for the gates, the terrain and the
# screen. Below low gate the law gives way to a rate-of-descent phase:
# horizontal velocity nulled, a descent rate that eases to a metre a
# second, contact at the probes.
#
# The engine is the DPS: throttleable between 10% and 60%, or full. The
# guidance's demand above 60% gets full thrust -- that is the braking
# phase's throttle-down, when the demand falls through it. The mass falls
# with every second; the propellant is the number the trench watches, in
# seconds of hover at the low-gate throttle.
#
# The crew know only their estimate: the truth offset by a navigation
# error until the landing radar sees the ground. They land where the
# estimate says the target is. The terrain there is whatever it is:
# craters as bowls with rims, boulder fields around the young ones, seeded
# from the site so Tranquility's West Crater is always in the same place.
# A target in a crater is redesignated -- the approach shifts, the final
# phase translates -- and every second of that is hover. The rules: at
# the reserve with the ground not at hand, abort on the ascent stage; a
# tank run dry above fifty metres is an abort; below it is a crew lost.
# ===----------------------------------------------------------------------=== #

from std.math import sqrt, sin, cos, atan2, acos, asin, exp
from astro import Vec3, R_MOON, MU_MOON, DEG, RAD, fmt
from scene import rotate_about
from cloud import Rng

comptime DPS_MAX_N = 45040.0
comptime DPS_MIN_FRAC = 0.10
comptime DPS_THROTTLE_MAX_FRAC = 0.60
comptime DPS_ISP_S = 311.0
comptime G0_MS2 = 9.80665
comptime DPS_UNUSABLE_KG = 164.0
comptime HOVER_RATE_KGS = 3.72
"""kg/s at the low-gate throttle: what a second of hover costs."""
comptime OMEGA_MOON_RS = 2.6617e-6
comptime G_MOON = 1.622
comptime GUIDANCE_CYCLE = 2.0
comptime PHYSICS_STEP = 0.25
comptime PROBE_HEIGHT = 1.7
"""m: the contact probes touch, the engine stops."""
comptime TRANSLATE_SPEED = 3.0
"""m/s: how fast a redesignation is flown out in the final phase."""

comptime P63 = 0  # braking
comptime P64 = 1  # approach
comptime P66 = 2  # rate of descent
comptime LANDED = 3
comptime ABORTED = 4
comptime LOST = 5


def phase_label(p: Int) -> String:
    if p == P63:
        return String("P63 BRAKING")
    if p == P64:
        return String("P64 APPROACH")
    if p == P66:
        return String("P66 FINAL")
    if p == LANDED:
        return String("LANDED")
    if p == ABORTED:
        return String("ABORTED")
    return String("LOST")


@fieldwise_init
struct Gate(ImplicitlyCopyable, Movable):
    """A guidance target in the site frame: x toward the site along the
    approach, z up. Metres, m/s, m/s²."""

    var x: Float64
    var z: Float64
    var vx: Float64
    var vz: Float64
    var ax: Float64
    var az: Float64


def high_gate() -> Gate:
    return Gate(-7900.0, 2286.0, 150.0, -44.0, -3.4, 0.0)


def low_gate() -> Gate:
    return Gate(-600.0, 152.0, 8.0, -3.0, -0.8, 0.0)


# ── the terrain ──────────────────────────────────────────────────────────


struct Terrain(Movable):
    """Craters (x, y, radius, depth) and boulder fields (x, y, radius,
    density), in metres from the site, seeded from the site's coordinates
    so a site always has the same ground."""

    var craters: List[Float64]
    var fields: List[Float64]

    def __init__(out self, site_lat: Float64, site_lon: Float64, big_field: Bool):
        self.craters = List[Float64]()
        self.fields = List[Float64]()
        var seed = UInt64(Int((site_lat + 90.0) * 1000.0) * 7919 + Int((site_lon + 180.0) * 1000.0))
        var rng = Rng(seed)
        # The site's own young crater, with its ejecta: "West Crater".
        var wx = 180.0 + rng.gauss() * 30.0
        var wy = 30.0 + rng.gauss() * 20.0
        self.craters.append(wx)
        self.craters.append(wy)
        self.craters.append(90.0)
        self.craters.append(20.0)
        self.fields.append(wx)
        self.fields.append(wy)
        self.fields.append(700.0 if big_field else 300.0)
        self.fields.append(0.6 if big_field else 0.35)
        # A scattering of others within five kilometres.
        for _ in range(40):
            var x = (rng.next() - 0.5) * 10000.0
            var y = (rng.next() - 0.5) * 10000.0
            var r = 25.0 + rng.next() * 200.0
            if sqrt(x * x + y * y) < 400.0:
                continue
            self.craters.append(x)
            self.craters.append(y)
            self.craters.append(r)
            self.craters.append(r * 0.2)
            if r > 120.0 and rng.next() < 0.5:
                self.fields.append(x)
                self.fields.append(y)
                self.fields.append(r * 1.8)
                self.fields.append(0.3)

    def height(self, x: Float64, y: Float64) -> Float64:
        """Metres above the reference sphere."""
        var h = 0.0
        for i in range(len(self.craters) // 4):
            var dx = x - self.craters[i * 4]
            var dy = y - self.craters[i * 4 + 1]
            var rr = self.craters[i * 4 + 2]
            var depth = self.craters[i * 4 + 3]
            var d = sqrt(dx * dx + dy * dy)
            if d < rr:
                h -= depth * (1.0 - (d / rr) * (d / rr))
            var rim = (d - rr) / (0.3 * rr)
            h += 0.06 * rr * exp(-rim * rim)
        return h

    def slope_deg(self, x: Float64, y: Float64) -> Float64:
        var e = 2.0
        var gx = (self.height(x + e, y) - self.height(x - e, y)) / (2.0 * e)
        var gy = (self.height(x, y + e) - self.height(x, y - e)) / (2.0 * e)
        return atan2(sqrt(gx * gx + gy * gy), 1.0) * RAD

    def boulder(self, x: Float64, y: Float64) -> Bool:
        """Is there a boulder a footpad could not take within a few metres?
        Hashed per five-metre cell against the field's density."""
        for i in range(len(self.fields) // 4):
            var dx = x - self.fields[i * 4]
            var dy = y - self.fields[i * 4 + 1]
            var rr = self.fields[i * 4 + 2]
            if dx * dx + dy * dy < rr * rr:
                var cx = Int((x + 100000.0) / 5.0)
                var cy = Int((y + 100000.0) / 5.0)
                var h = UInt32(cx) * UInt32(2654435761) ^ UInt32(cy) * UInt32(2246822519)
                h ^= h >> UInt32(13)
                h *= UInt32(0x27D4EB2D)
                h ^= h >> UInt32(15)
                var u = Float64(h & UInt32(0xFFFF)) / 65536.0
                var fall = 1.0 - sqrt(dx * dx + dy * dy) / rr
                if u < self.fields[i * 4 + 3] * fall:
                    return True
        return False

    def density_at(self, x: Float64, y: Float64) -> Float64:
        """The boulder fields' density here: what the crew see out of the
        window as a field, before any one rock."""
        var best = 0.0
        for i in range(len(self.fields) // 4):
            var dx = x - self.fields[i * 4]
            var dy = y - self.fields[i * 4 + 1]
            var rr = self.fields[i * 4 + 2]
            var d = sqrt(dx * dx + dy * dy)
            if d < rr:
                var v = self.fields[i * 4 + 3] * (1.0 - d / rr)
                if v > best:
                    best = v
        return best

    def in_bowl(self, x: Float64, y: Float64) -> Bool:
        for i in range(len(self.craters) // 4):
            var dx = x - self.craters[i * 4]
            var dy = y - self.craters[i * 4 + 1]
            var rr = self.craters[i * 4 + 2]
            if dx * dx + dy * dy < 0.81 * rr * rr:
                return True
        return False

    def safe(self, x: Float64, y: Float64) -> Bool:
        """Flat enough, out of the bowls, out of the fields, and no rock in
        any of the nine five-metre cells a footpad might come down in."""
        if self.slope_deg(x, y) >= 12.0 or self.in_bowl(x, y) or self.density_at(x, y) >= 0.08:
            return False
        for i in range(-1, 2):
            for j in range(-1, 2):
                if self.boulder(x + 5.0 * Float64(i), y + 5.0 * Float64(j)):
                    return False
        return True

    def nearest_safe(self, x: Float64, y: Float64, max_r: Float64) -> Vec3:
        """The best safe spot within max_r: near, and preferably ahead --
        the crew are looking forward, and Armstrong flew over West Crater
        rather than back from it. z = 1 if found, 0 if not."""
        if self.safe(x, y):
            return Vec3(x, y, 1.0)
        var best_cost = 1.0e30
        var bx = x
        var by = y
        var r = 20.0
        while r <= max_r:
            var n = Int(r / 8.0) + 8
            for k in range(n):
                var a = 6.283185307179586 * Float64(k) / Float64(n)
                var px = x + r * cos(a)
                var py = y + r * sin(a)
                if self.safe(px, py):
                    var cost = r * (1.3 - 0.6 * cos(a))
                    if cost < best_cost:
                        best_cost = cost
                        bx = px
                        by = py
            if best_cost < 1.0e30 and r > best_cost:
                break
            r += 20.0
        if best_cost < 1.0e30:
            return Vec3(bx, by, 1.0)
        return Vec3(x, y, 0.0)


# ── the descent ──────────────────────────────────────────────────────────


struct Descent(Movable):
    var rho: Vec3  # Moon-centred inertial, km
    var rho_dot: Vec3  # km/s
    var t: Float64  # s since PDI
    var mass: Float64  # kg
    var prop: Float64  # kg, including the unusable
    var site0: Vec3  # the site's inertial position at PDI, km
    var pole: Vec3  # the Moon's spin axis
    var x_hat: Vec3  # site frame at PDI: along the approach, cross, up
    var y_hat: Vec3
    var z_hat: Vec3
    var phase: Int
    var t_go: Float64
    var throttle: Float64  # 0..1 of DPS_MAX_N
    var thrust_dir: Vec3
    var cycle_due: Float64
    var aim_x: Float64  # the target point on the ground, site frame, as redesignated
    var aim_y: Float64
    var nav_err: Vec3  # the estimate's error, site-frame metres (x, y, z)
    var radar_alt: Float64  # m: where the radar will see the ground
    var radar_locked: Bool
    var dv_used: Float64  # m/s
    var redesignations: Int
    var reserve_s: Float64
    var terrain: Terrain
    var outcome_reason: String
    var contact_speed: Float64
    var landed_x: Float64  # truth, site frame
    var landed_y: Float64
    var trail: List[Float64]  # t, x, y, z (truth, site frame)
    var alarm_at: Float64  # s: a 1202-style alarm, or -1
    var alarm_seen: Bool
    var alarm_recur_at: Float64
    var alarm_state: Int  # 0 none, 1 fired and the call is open, 2 GO, 3 recurring
    var alarm_logged: Bool
    var max_throttle: Float64
    var damaged: Bool
    var t_high_gate: Float64
    var t_low_gate: Float64
    var hold_until: Float64  # s: the crew are looking, and hovering
    var residual: Float64  # s of requested time not yet a whole step

    def __init__(
        out self,
        rho: Vec3,
        rho_dot: Vec3,
        site_dir: Vec3,
        pole: Vec3,
        lm_mass: Float64,
        prop_kg: Float64,
        reserve_s: Float64,
        var terrain: Terrain,
        nav_err: Vec3,
        radar_alt: Float64,
    ):
        self.rho = rho
        self.rho_dot = rho_dot
        self.t = 0.0
        self.mass = lm_mass
        self.prop = prop_kg
        self.site0 = site_dir.unit() * R_MOON
        self.pole = pole
        self.z_hat = site_dir.unit()
        var horiz = rho_dot - self.z_hat * rho_dot.dot(self.z_hat)
        self.x_hat = horiz.unit()
        self.y_hat = self.z_hat.cross(self.x_hat)
        self.phase = P63
        self.t_go = 0.0
        self.throttle = 0.0
        self.thrust_dir = -rho_dot.unit()
        self.cycle_due = 0.0
        self.aim_x = 0.0
        self.aim_y = 0.0
        self.nav_err = nav_err
        self.radar_alt = radar_alt
        self.radar_locked = False
        self.dv_used = 0.0
        self.redesignations = 0
        self.reserve_s = reserve_s
        self.terrain = terrain^
        self.outcome_reason = String("")
        self.contact_speed = 0.0
        self.landed_x = 0.0
        self.landed_y = 0.0
        self.trail = List[Float64]()
        self.alarm_at = -1.0
        self.alarm_seen = False
        self.alarm_recur_at = -1.0
        self.alarm_state = 0
        self.alarm_logged = False
        self.max_throttle = 0.0
        self.damaged = False
        self.t_high_gate = 0.0
        self.t_low_gate = 0.0
        self.hold_until = -1.0
        self.residual = 0.0

    # ── the site, moving with the Moon ───────────────────────────────────

    def site_at(self, t: Float64) -> Vec3:
        return rotate_about(self.site0, self.pole, OMEGA_MOON_RS * t)

    def site_vel_at(self, t: Float64) -> Vec3:
        return self.pole.cross(self.site_at(t)) * OMEGA_MOON_RS

    def axes_at(self, t: Float64) -> Vec3:
        """x̂ turned with the Moon (ẑ follows the site; ŷ = ẑ × x̂)."""
        return rotate_about(self.x_hat, self.pole, OMEGA_MOON_RS * t)

    def local(self, p: Vec3, t: Float64) -> Vec3:
        """Site-frame metres of an inertial point, relative to the site now."""
        var d = (p - self.site_at(t)) * 1000.0
        var xh = self.axes_at(t)
        var zh = self.site_at(t).unit()
        var yh = zh.cross(xh)
        return Vec3(d.dot(xh), d.dot(yh), d.dot(zh))

    def truth_local(self) -> Vec3:
        return self.local(self.rho, self.t)

    def downrange(self) -> Float64:
        """Metres along the ground to the site, negative uprange: the arc,
        which the tangent plane's x is not once the LM is far enough away
        for the Moon to curve under it."""
        var p = self.rho.unit()
        var zh = self.site_at(self.t).unit()
        var xh = self.axes_at(self.t)
        var along = p.dot(xh)
        var up = p.dot(zh)
        return R_MOON * 1000.0 * atan2(along, up)

    def altitude(self) -> Float64:
        """Metres above the terrain under the LM."""
        var l = self.truth_local()
        return (self.rho.norm() - R_MOON) * 1000.0 - self.terrain.height(l.x, l.y)

    def est_rho(self) -> Vec3:
        """The estimate: the truth offset by the navigation error."""
        var xh = self.axes_at(self.t)
        var zh = self.site_at(self.t).unit()
        var yh = zh.cross(xh)
        var e = self.nav_err
        if self.radar_locked:
            e = Vec3(e.x, e.y, 0.0)
        return self.rho + (xh * e.x + yh * e.y + zh * e.z) * 0.001

    def hover_seconds(self) -> Float64:
        return (self.prop - DPS_UNUSABLE_KG) / HOVER_RATE_KGS

    def descent_rate(self) -> Float64:
        """m/s, positive downward, against the LM's own vertical, relative
        to the ground turning under it."""
        var v = (self.rho_dot - self.site_vel_at(self.t)) * 1000.0
        return -v.dot(self.rho.unit())

    def ground_speed(self) -> Float64:
        var v = (self.rho_dot - self.site_vel_at(self.t)) * 1000.0
        var up = self.rho.unit()
        var h = v - up * v.dot(up)
        return h.norm()

    # ── guidance ─────────────────────────────────────────────────────────

    def gate_inertial(self, g: Gate, t_at: Float64) -> Vec3:
        """The gate's inertial position at t_at, km (aim offsets included)."""
        var xh = self.axes_at(t_at)
        var s = self.site_at(t_at)
        var zh = s.unit()
        var yh = zh.cross(xh)
        return s + (xh * (g.x + self.aim_x) + yh * self.aim_y + zh * g.z) * 0.001

    def gate_velocity(self, g: Gate, t_at: Float64) -> Vec3:
        var xh = self.axes_at(t_at)
        var zh = self.site_at(t_at).unit()
        return self.site_vel_at(t_at) + (xh * g.vx + zh * g.vz) * 0.001

    def gate_accel(self, g: Gate, t_at: Float64) -> Vec3:
        var xh = self.axes_at(t_at)
        var zh = self.site_at(t_at).unit()
        return (xh * g.ax + zh * g.az) * 0.001

    def solve_t_go(self, g: Gate, r_est: Vec3) -> Float64:
        """The terminal-jerk condition with zero jerk along the approach:
        −6 a_Tx T² + (6 v_x + 18 v_Tx) T − 24 Δ = 0, the positive root."""
        var xh = self.axes_at(self.t)
        var vx = (self.rho_dot - self.site_vel_at(self.t)).dot(xh) * 1000.0
        var delta = (self.gate_inertial(g, self.t) - r_est).dot(xh) * 1000.0
        var a = -6.0 * g.ax
        var b = 6.0 * vx + 18.0 * g.vx
        var c = -24.0 * delta
        if abs(a) < 1e-9:
            return -c / b if b != 0.0 else 1.0
        var disc = b * b - 4.0 * a * c
        if disc < 0.0:
            return 1.0
        return (-b + sqrt(disc)) / (2.0 * a)

    def guide(mut self):
        """One guidance cycle: the phase's law, the throttle, the direction."""
        var r_est = self.est_rho()
        var g_vec = self.rho * (-MU_MOON / (self.rho.norm() ** 3))  # km/s²
        var a_c = Vec3(0.0, 0.0, 0.0)
        if self.phase == P63 or self.phase == P64:
            var gate = high_gate() if self.phase == P63 else low_gate()
            var tg = self.solve_t_go(gate, r_est)
            if tg < 1.0:
                tg = 1.0
            self.t_go = tg
            var t_at = self.t + tg
            var r_t = self.gate_inertial(gate, t_at)
            var v_t = self.gate_velocity(gate, t_at)
            var a_t = self.gate_accel(gate, t_at)
            a_c = a_t + (r_t - r_est) * (12.0 / (tg * tg)) - (v_t + self.rho_dot) * (6.0 / tg)
            if self.phase == P64 and tg <= GUIDANCE_CYCLE + 0.5:
                self.phase = P66
                self.t_low_gate = self.t
            if self.phase == P63 and tg <= GUIDANCE_CYCLE + 0.5:
                self.phase = P64
                self.t_high_gate = self.t
        else:
            # Rate of descent, and a translation to the aim point.
            var l = self.local(r_est, self.t)
            var zh = self.site_at(self.t).unit()
            var xh = self.axes_at(self.t)
            var yh = zh.cross(xh)
            var v = (self.rho_dot - self.site_vel_at(self.t)) * 1000.0
            var vz = v.dot(zh)
            var vx = v.dot(xh)
            var vy = v.dot(yh)
            var alt = l.z
            var dx = self.aim_x - l.x
            var dy = self.aim_y - l.y
            var dist = sqrt(dx * dx + dy * dy)
            # Fly to the aim at a speed that shrinks with the distance, and
            # come down at a rate that arrives with it; the last forty
            # metres at a metre a second, straight down.
            var want_vx = 0.0
            var want_vy = 0.0
            var sp = 0.0
            if dist > 2.0:
                sp = dist / 25.0
                if sp > 12.0:
                    sp = 12.0
                if sp < 1.0:
                    sp = 1.0
                want_vx = dx / dist * sp
                want_vy = dy / dist * sp
            var t_arrive = dist / sp if sp > 0.0 else 0.0
            var want_vz = -1.0
            if alt > 20.0:
                var t_down = t_arrive + 25.0
                want_vz = -(alt - 20.0) / t_down - 1.5
                if want_vz < -9.0:
                    want_vz = -9.0
            if dist > 3.0 and alt < 25.0:
                want_vz = -0.15
            if self.t < self.hold_until:
                want_vz = 0.0
                want_vx = 0.0
                want_vy = 0.0
            var ax = (want_vx - vx) / 3.0
            var ay = (want_vy - vy) / 3.0
            var az = (want_vz - vz) / 2.0
            a_c = (xh * ax + yh * ay + zh * az) * 0.001
        var thrust_acc = a_c - g_vec  # km/s²
        var mag = thrust_acc.norm() * 1000.0  # m/s²
        var demand = self.mass * mag  # N
        var thr = demand / DPS_MAX_N
        if thr > DPS_THROTTLE_MAX_FRAC:
            thr = 1.0
        if thr < DPS_MIN_FRAC:
            thr = DPS_MIN_FRAC
        self.throttle = thr
        if thr > self.max_throttle:
            self.max_throttle = thr
        if mag > 1e-9:
            self.thrust_dir = thrust_acc.unit()

    def pitch_deg(self) -> Float64:
        """The thrust axis from the local vertical."""
        var zh = self.site_at(self.t).unit()
        var c = self.thrust_dir.dot(zh)
        c = 1.0 if c > 1.0 else (-1.0 if c < -1.0 else c)
        return acos(c) * RAD

    # ── the crew's decisions, and the rules ──────────────────────────────

    def consider_redesignation(mut self):
        """The crew see the aim point: from the approach, craters and
        slopes; only in the final phase, the rocks. If it is no place to
        land, the nearest place that is becomes it."""
        var err = self.nav_err
        # Where the LM will actually come down if it flies its estimate to
        # the aim: the aim, displaced by the navigation error.
        var tx = self.aim_x - err.x
        var ty = self.aim_y - err.y
        var bad = False
        if self.phase == P64:
            bad = self.terrain.in_bowl(tx, ty) or self.terrain.slope_deg(tx, ty) >= 12.0
        else:
            bad = not self.terrain.safe(tx, ty)
        if bad:
            # What the crew can see and reach: a kilometre from the
            # approach, six hundred metres once they are down in the final.
            var reach = 1000.0 if self.phase == P64 else 600.0
            var ns = self.terrain.nearest_safe(tx, ty, reach)
            if ns.z > 0.5:
                self.aim_x = ns.x + err.x
                self.aim_y = ns.y + err.y
                self.redesignations += 1
                # Nobody redesignates without looking first: forty seconds
                # of hover, which is where Apollo 11's margin went.
                if self.phase == P66:
                    self.hold_until = self.t + 40.0
            else:
                self.phase = ABORTED
                self.outcome_reason = String("no place to land within reach: abort")

    def call_abort(mut self, reason: String):
        """The call nobody wants to make. Staging on the ascent engine is
        survivable at any altitude the DPS still has; what it costs is the
        landing, and the mission."""
        if self.phase >= LANDED:
            return
        self.phase = ABORTED
        self.outcome_reason = reason

    def call_alarm(mut self, go: Bool):
        """The trench's answer to the alarm."""
        if self.alarm_state != 1:
            return
        if go:
            self.alarm_state = 2
        else:
            self.phase = ABORTED
            self.outcome_reason = String("abort called on the program alarm")

    def check_rules(mut self):
        var alt = self.altitude()
        var hover = self.hover_seconds()
        # The program alarm: it fires, the call is open for thirty seconds
        # and defaults to GO -- the rule was GO unless it recurs -- and a
        # recurrence is the rule's abort.
        if self.alarm_at >= 0.0 and self.t >= self.alarm_at and self.alarm_state == 0:
            self.alarm_state = 1
            self.alarm_seen = True
        if self.alarm_state == 1 and self.t >= self.alarm_at + 30.0:
            self.alarm_state = 2
        if self.alarm_recur_at >= 0.0 and self.t >= self.alarm_recur_at and self.alarm_state == 2:
            self.alarm_state = 3
            self.phase = ABORTED
            self.outcome_reason = String("program alarms recurring: abort")
            return
        # No landing radar below ten thousand feet: the rule.
        if not self.radar_locked and alt < 3048.0 and self.phase >= P64:
            self.phase = ABORTED
            self.outcome_reason = String("no landing radar below 10 000 ft: abort")
            return
        if self.prop <= DPS_UNUSABLE_KG:
            if alt > 50.0:
                self.phase = ABORTED
                self.outcome_reason = String("DPS ran dry at ") + fmt(alt, 0) + " m: abort stage"
            else:
                self.phase = LOST
                self.outcome_reason = String("DPS ran dry at ") + fmt(alt, 0) + " m, falling"
            return
        if (self.phase == P64 or self.phase == P66) and hover <= self.reserve_s:
            var l = self.truth_local()
            var dx = self.aim_x - self.nav_err.x - l.x
            var dy = self.aim_y - self.nav_err.y - l.y
            if alt < 15.0 and dx * dx + dy * dy < 100.0 and self.descent_rate() < 3.0:
                return  # the ground is at hand: land
            self.phase = ABORTED
            self.outcome_reason = String("at the ") + fmt(self.reserve_s, 0) + " s reserve with " + fmt(alt, 0) + " m to go: abort"

    def step(mut self, dt: Float64):
        """Advance dt seconds of the descent."""
        if self.phase >= LANDED:
            return
        # Whole steps only, whatever slices the caller asks in: the same
        # seed must fly the same descent however the clock is driven.
        self.residual += dt
        while self.residual >= PHYSICS_STEP - 1e-9 and self.phase < LANDED:
            self.residual -= PHYSICS_STEP
            var h = PHYSICS_STEP
            if self.t >= self.cycle_due:
                if not self.radar_locked and self.radar_alt > 0.0 and self.altitude() < self.radar_alt:
                    self.radar_locked = True
                if self.phase == P64 or self.phase == P66:
                    self.consider_redesignation()
                self.guide()
                self.check_rules()
                self.cycle_due = self.t + GUIDANCE_CYCLE
                if self.phase >= LANDED:
                    break
                self.trail.append(self.t)
                var l = self.truth_local()
                self.trail.append(self.downrange())
                self.trail.append(l.y)
                self.trail.append(self.altitude())
            # RK4 on the Moon-relative state with the thrust held for the step.
            var thrust_n = self.throttle * DPS_MAX_N
            var acc_t = self.thrust_dir * (thrust_n / self.mass * 0.001)  # km/s²
            var r = self.rho
            var v = self.rho_dot
            var k1v = r * (-MU_MOON / (r.norm() ** 3)) + acc_t
            var r2 = r + v * (0.5 * h)
            var v2 = v + k1v * (0.5 * h)
            var k2v = r2 * (-MU_MOON / (r2.norm() ** 3)) + acc_t
            var r3 = r + v2 * (0.5 * h)
            var v3 = v + k2v * (0.5 * h)
            var k3v = r3 * (-MU_MOON / (r3.norm() ** 3)) + acc_t
            var r4 = r + v3 * h
            var v4 = v + k3v * h
            var k4v = r4 * (-MU_MOON / (r4.norm() ** 3)) + acc_t
            self.rho = r + (v + (v2 + v3) * 2.0 + v4) * (h / 6.0)
            self.rho_dot = v + (k1v + (k2v + k3v) * 2.0 + k4v) * (h / 6.0)
            var mdot = thrust_n / (DPS_ISP_S * G0_MS2)
            self.mass -= mdot * h
            self.prop -= mdot * h
            self.dv_used += thrust_n / self.mass * h
            self.t += h
            # Contact.
            var alt = self.altitude()
            if alt <= PROBE_HEIGHT:
                var vrel = (self.rho_dot - self.site_vel_at(self.t)) * 1000.0
                var zh = self.site_at(self.t).unit()
                var vdown = -vrel.dot(zh)
                var vh = (vrel - zh * vrel.dot(zh)).norm()
                self.contact_speed = vrel.norm()
                var l = self.truth_local()
                self.landed_x = l.x
                self.landed_y = l.y
                self.throttle = 0.0
                if vdown > 4.0 or vh > 2.5:
                    self.phase = LOST
                    self.outcome_reason = String("hit the ground at ") + fmt(vdown, 1) + " m/s down, " + fmt(vh, 1) + " across"
                elif vdown > 2.5 or vh > 1.2:
                    self.phase = LANDED
                    self.damaged = True
                    self.outcome_reason = String("hard landing: ") + fmt(vdown, 1) + " m/s down, " + fmt(vh, 1) + " across"
                elif self.terrain.slope_deg(l.x, l.y) >= 15.0 or self.terrain.in_bowl(l.x, l.y) or self.terrain.density_at(l.x, l.y) >= 0.12 or self.terrain.boulder(l.x, l.y):
                    self.phase = LANDED
                    self.damaged = True
                    self.outcome_reason = String("down on bad ground: ") + fmt(self.terrain.slope_deg(l.x, l.y), 0) + " deg slope, or rocks"
                else:
                    self.phase = LANDED
                    self.outcome_reason = String("touchdown at ") + fmt(vdown, 1) + " m/s"
                break
