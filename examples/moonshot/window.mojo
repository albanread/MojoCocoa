# ===----------------------------------------------------------------------=== #
# Moonshot — the launch-window map (sprint MC3).
#
# One thread per candidate launch: a minute of the month and a flight
# time. Each thread asks the questions the trench asked of every minute
# of July 1969, and answers them with the same computations:
#
#   where will the Moon be when we arrive          (C3, the table)
#   which plane holds the pad now and the Moon then (C6, C7)
#   what azimuth is that, and is it in the corridor (C7, C9)
#   what does the transfer cost, and the capture    (C10, C11, C15)
#   what will the Sun be doing over the site        (C17)
#
# and writes eight numbers to its cell. The map is 31 day-columns wide;
# within a column the pixel's x is the flight time (60 to 120 hours)
# and its y the launch hour, so every pixel is one (day, hour, flight
# time) and the picture is the month's opportunities, whole.
#
# The corridor comes out as a band a few hours long every day -- the
# Earth turns the pad under the plane once a day, and the plane's
# azimuth sweeps through the range-safety limits over about four and a
# half hours. What picks a DAY is the Sun over the landing site: five to
# fourteen degrees, rising, which each site has for eighteen hours once
# a lunar month, sites further east earlier. That is why Tranquility was
# the 16th, Sinus Medii the 18th and Site 5 the 21st, and the map shows
# it without being told.
#
# `cell` is written once, generic over the float type: the tests call it
# in Float64 on the CPU for the numbers, the kernel calls it in Float32
# for the picture, and the two are compared.
# ===----------------------------------------------------------------------=== #

from std.gpu import global_idx
from std.math import sqrt, sin, cos, atan2, atan, tan, floor
from std.ffi import external_call
from std.memory import OpaquePointer, Pointer
from astro import (
    Vec3, Ephemeris, Site, MU_EARTH, MU_MOON, R_EARTH, R_MOON, MOON_SOI, OMEGA_EARTH,
    FLATTENING, MOON_TILT, DEG, RAD, gmst_deg, centuries, lunar_node_deg,
    moon_arg_latitude_deg, obliquity_deg, julian_day, jde_from_ut, spherical,
    site_position, site_velocity, lon_lat_of, fmt,
)
from orbit import Bodies, bodies_at, Sky, TABLE_STRIDE
from png import save_png

comptime P = OpaquePointer[MutUntrackedOrigin]

# ── the parameter block: one Float32 buffer, indexed by these ────────────

comptime N_PARAMS = 32
comptime P_GMST0 = 0  # GMST at the map's epoch, degrees
comptime P_LAT_GC = 1  # launch site geocentric latitude, degrees
comptime P_LAT_GD = 2  # and geodetic, for the local horizon
comptime P_LON = 3
comptime P_VROT = 4  # the site's eastward speed, km/s
comptime P_AZ_MIN = 5  # the corridor, pad azimuths
comptime P_AZ_MAX = 6
comptime P_PARK_R = 7  # parking orbit radius, km
comptime P_TLI_OFFSET = 8  # launch to TLI, s (ascent and the parking coast)
comptime P_LAND_OFFSET = 9  # perilune to touchdown, s (LOI, the orbits, the descent)
comptime P_RP_MOON = 10  # perilune radius targeted, km
comptime P_LOI_APO = 11  # apolune altitude after LOI-1, km
comptime P_OMEGA0 = 12  # lunar node at epoch, degrees, and its rate per day
comptime P_OMEGA_RATE = 13
comptime P_F0 = 14  # the Moon's argument of latitude at epoch, and its rate
comptime P_F_RATE = 15
comptime P_EPS = 16  # obliquity, degrees
comptime P_SX = 17  # the landing site as a unit vector in the Moon's body frame
comptime P_SY = 18
comptime P_SZ = 19
comptime P_TOF_MIN = 20  # flight-time range, s
comptime P_TOF_MAX = 21
comptime P_STEPS = 22  # pixels per day column
comptime P_ROWS = 23  # pixels per day of launch time
comptime P_SUN_LO = 24  # the lighting band, degrees
comptime P_SUN_HI = 25

# ── the eight fields a cell writes ───────────────────────────────────────

comptime FIELDS = 8
comptime F_DV_TLI = 0  # km/s
comptime F_DV_LOI = 1  # km/s, into r_p × (R_MOON + loi_apo)
comptime F_AZ = 2  # pad azimuth, degrees
comptime F_INC = 3  # the plane's inclination, degrees
comptime F_SUN = 4  # Sun elevation at the site at touchdown, degrees
comptime F_FLAGS = 5
comptime F_VINF = 6  # km/s
comptime F_ANGLE = 7  # transfer angle, degrees

comptime FLAG_CORRIDOR = 1
comptime FLAG_LIT = 2
comptime FLAG_RISING = 4
comptime FLAG_OK = 8  # the transfer solve converged


# ── small vector helpers on 4-lane SIMD ──────────────────────────────────


@always_inline
def _dot[dt: DType](a: SIMD[dt, 4], b: SIMD[dt, 4]) -> Scalar[dt]:
    return (a * b).reduce_add()


@always_inline
def _cross[dt: DType](a: SIMD[dt, 4], b: SIMD[dt, 4]) -> SIMD[dt, 4]:
    return SIMD[dt, 4](
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
        0,
    )


@always_inline
def _unit[dt: DType](a: SIMD[dt, 4]) -> SIMD[dt, 4]:
    return a * (Scalar[dt](1) / sqrt(_dot(a, a)))


@always_inline
def _wrap360[dt: DType](x: Scalar[dt]) -> Scalar[dt]:
    var q = x / Scalar[dt](360)
    var k = Int(q)
    if Scalar[dt](k) > q:
        k -= 1
    return x - Scalar[dt](360) * Scalar[dt](k)


# ── Stumpff functions, elliptic side and the series ─────────────────────
#
# No sinh or cosh on the device, and none needed: a transfer of sixty
# hours or more from a 185 km orbit is an ellipse (the parabola takes
# fifty-two), so z ≥ 0 and the series covers the near-parabolic edge.


@always_inline
def _stumpff_c[dt: DType](z: Scalar[dt]) -> Scalar[dt] where dt.is_floating_point():
    if z > Scalar[dt](1e-3):
        return (Scalar[dt](1) - cos(sqrt(z))) / z
    return Scalar[dt](0.5) - z / Scalar[dt](24) + z * z / Scalar[dt](720) - z * z * z / Scalar[dt](40320)


@always_inline
def _stumpff_s[dt: DType](z: Scalar[dt]) -> Scalar[dt] where dt.is_floating_point():
    if z > Scalar[dt](1e-3):
        var sz = sqrt(z)
        return (sz - sin(sz)) / (z * sz)
    return Scalar[dt](1.0 / 6.0) - z / Scalar[dt](120) + z * z / Scalar[dt](5040) - z * z * z / Scalar[dt](362880)


@always_inline
def _chi_for[dt: DType](k: Scalar[dt], r_p: Scalar[dt], alpha: Scalar[dt], smu_tau: Scalar[dt]) -> Scalar[dt] where dt.is_floating_point():
    """The universal anomaly χ after the flight time, for a tangential
    departure: the root of F(χ) = k χ³ S(αχ²) + r_p χ − √μ τ, which is
    increasing in χ, so a doubling bracket and forty bisections find it
    without a Newton guess that can go wrong near the parabola."""
    var lo = Scalar[dt](0)
    var hi = Scalar[dt](64)
    for _ in range(40):
        var z = alpha * hi * hi
        if k * hi * hi * hi * _stumpff_s(z) + r_p * hi - smu_tau > Scalar[dt](0):
            break
        lo = hi
        hi *= Scalar[dt](2)
    for _ in range(48):
        var mid = Scalar[dt](0.5) * (lo + hi)
        var z = alpha * mid * mid
        if k * mid * mid * mid * _stumpff_s(z) + r_p * mid - smu_tau > Scalar[dt](0):
            hi = mid
        else:
            lo = mid
    return Scalar[dt](0.5) * (lo + hi)


@always_inline
def _kepler_planar[dt: DType](r_p: Scalar[dt], v_p: Scalar[dt], tau: Scalar[dt]) -> SIMD[dt, 4] where dt.is_floating_point():
    """From perigee (r_p, 0) with velocity (0, v_p), the position and
    velocity tau seconds later, in the plane: (x, y, vx, vy). Universal
    variables."""
    var mu = Scalar[dt](MU_EARTH)
    var smu = sqrt(mu)
    var alpha = Scalar[dt](2) / r_p - v_p * v_p / mu
    var k = Scalar[dt](1) - alpha * r_p
    var chi = _chi_for(k, r_p, alpha, smu * tau)
    var z = alpha * chi * chi
    var c = _stumpff_c(z)
    var s = _stumpff_s(z)
    var f = Scalar[dt](1) - chi * chi * c / r_p
    var g = tau - chi * chi * chi * s / smu
    var x = f * r_p
    var y = g * v_p
    var r = sqrt(x * x + y * y)
    var fdot = smu / (r * r_p) * (alpha * chi * chi * chi * s - chi)
    var gdot = Scalar[dt](1) - chi * chi * c / r
    return SIMD[dt, 4](x, y, fdot * r_p, gdot * v_p)


@fieldwise_init
struct Transfer2D[dt: DType](ImplicitlyCopyable, Movable):
    var v_p: Scalar[Self.dt]  # perigee speed
    var angle: Scalar[Self.dt]  # transfer angle, radians
    var v_r: Scalar[Self.dt]  # arrival radial speed
    var v_t: Scalar[Self.dt]  # arrival tangential speed
    var ok: Bool


@always_inline
def _transfer[dt: DType](r_p: Scalar[dt], r_target: Scalar[dt], tau: Scalar[dt]) -> Transfer2D[dt] where dt.is_floating_point():
    """The tangential departure from r_p that reaches r_target in tau
    seconds: bisection on the perigee speed between circular and just
    under parabolic, forty rounds."""
    var mu = Scalar[dt](MU_EARTH)
    var lo = sqrt(mu / r_p)
    var top = sqrt(Scalar[dt](2) * mu / r_p) * Scalar[dt](0.9999)
    var hi = top
    for _ in range(40):
        var mid = Scalar[dt](0.5) * (lo + hi)
        var st = _kepler_planar(r_p, mid, tau)
        var r = sqrt(st[0] * st[0] + st[1] * st[1])
        if r < r_target:
            lo = mid
        else:
            hi = mid
    var v_p = Scalar[dt](0.5) * (lo + hi)
    var st = _kepler_planar(r_p, v_p, tau)
    var r = sqrt(st[0] * st[0] + st[1] * st[1])
    var angle = atan2(st[1], st[0])
    var v_r = (st[2] * st[0] + st[3] * st[1]) / r
    var v_t = (st[3] * st[0] - st[2] * st[1]) / r
    return Transfer2D[dt](v_p, angle, v_r, v_t, hi < top * Scalar[dt](0.999999))


# ── the Moon's body axes, from the node and the argument of latitude ─────


@fieldwise_init
struct Axes[dt: DType](ImplicitlyCopyable, Movable):
    var x: SIMD[Self.dt, 4]
    var y: SIMD[Self.dt, 4]
    var z: SIMD[Self.dt, 4]


@always_inline
def _moon_axes[dt: DType](omega_deg: Scalar[dt], f_deg: Scalar[dt], eps_deg: Scalar[dt]) -> Axes[dt] where dt.is_floating_point():
    """The same construction as `Ephemeris.moon_frame`, on scalars the
    kernel can be handed: Cassini's laws, then the obliquity rotation."""
    var om = omega_deg * Scalar[dt](DEG)
    var f = f_deg * Scalar[dt](DEG)
    var ci = cos(Scalar[dt](MOON_TILT * DEG))
    var si = sin(Scalar[dt](MOON_TILT * DEG))
    var pole = SIMD[dt, 4](-sin(om) * si, cos(om) * si, ci, 0)
    var node = SIMD[dt, 4](cos(om), sin(om), 0, 0)
    var along = SIMD[dt, 4](-ci * sin(om), ci * cos(om), -si, 0)
    var x = -(node * cos(f) + along * sin(f))
    var z = pole
    var y = _cross(z, x)
    var ce = cos(eps_deg * Scalar[dt](DEG))
    var se = sin(eps_deg * Scalar[dt](DEG))
    return Axes[dt](
        SIMD[dt, 4](x[0], x[1] * ce - x[2] * se, x[1] * se + x[2] * ce, 0),
        SIMD[dt, 4](y[0], y[1] * ce - y[2] * se, y[1] * se + y[2] * ce, 0),
        SIMD[dt, 4](z[0], z[1] * ce - z[2] * se, z[1] * se + z[2] * ce, 0),
    )


@always_inline
def _sun_elevation[dt: DType, o1: Origin, o2: Origin, //](
    t: Scalar[dt], tab: Pointer[Int64, o1], n: Int, p: Pointer[Scalar[dt], o2]
) -> Scalar[dt] where dt.is_floating_point():
    """The Sun's elevation over the landing site at t seconds from the
    epoch, degrees."""
    var sky = bodies_at(tab, n, t)
    var moon = sky.moon.narrow()
    var sun = sky.sun.narrow()
    var to_sun = _unit(sun - moon)
    var days = t / Scalar[dt](86400)
    var ax = _moon_axes(
        p[unsafe_offset=P_OMEGA0] + p[unsafe_offset=P_OMEGA_RATE] * days,
        p[unsafe_offset=P_F0] + p[unsafe_offset=P_F_RATE] * days,
        p[unsafe_offset=P_EPS],
    )
    var up = ax.x * p[unsafe_offset=P_SX] + ax.y * p[unsafe_offset=P_SY] + ax.z * p[unsafe_offset=P_SZ]
    var s = _dot(up, to_sun)
    var c = sqrt(_dot(_cross(up, to_sun), _cross(up, to_sun)))
    return atan2(s, c) * Scalar[dt](RAD)


# ── the cell ─────────────────────────────────────────────────────────────


@always_inline
def cell[dt: DType, o1: Origin, o2: Origin, //](
    t_launch: Scalar[dt],
    tof: Scalar[dt],
    tab: Pointer[Int64, o1],
    n: Int,
    p: Pointer[Scalar[dt], o2],
) -> SIMD[dt, FIELDS] where dt.is_floating_point():
    """Everything the map knows about one launch minute and one flight
    time. t_launch is seconds from the map's epoch (UT); the table is
    epoch-ed at the same instant in dynamical time, so the same seconds
    index it."""
    var zero = SIMD[dt, FIELDS](0)
    var t_tli = t_launch + p[unsafe_offset=P_TLI_OFFSET]
    var t_a = t_tli + tof
    var sky = bodies_at(tab, n, t_a)
    var m = sky.moon.narrow()
    var mn = sqrt(_dot(m, m))
    var m_hat = m * (Scalar[dt](1) / mn)

    # The pad now, and the local horizon.
    var theta = (
        p[unsafe_offset=P_GMST0]
        + Scalar[dt](360.98564736629) * t_launch / Scalar[dt](86400)
        + p[unsafe_offset=P_LON]
    ) * Scalar[dt](DEG)
    var pgc = p[unsafe_offset=P_LAT_GC] * Scalar[dt](DEG)
    var pgd = p[unsafe_offset=P_LAT_GD] * Scalar[dt](DEG)
    var s_hat = SIMD[dt, 4](cos(pgc) * cos(theta), cos(pgc) * sin(theta), sin(pgc), 0)
    var east = SIMD[dt, 4](-sin(theta), cos(theta), 0, 0)
    var north = SIMD[dt, 4](-sin(pgd) * cos(theta), -sin(pgd) * sin(theta), cos(pgd), 0)

    # The plane through both, prograde.
    var nvec = _cross(s_hat, m_hat)
    var nn = sqrt(_dot(nvec, nvec))
    if nn < Scalar[dt](1e-6):
        return zero
    var n_hat = nvec * (Scalar[dt](1) / nn)
    if n_hat[2] < Scalar[dt](0):
        n_hat = -n_hat
    var inc = atan2(sqrt(n_hat[0] * n_hat[0] + n_hat[1] * n_hat[1]), n_hat[2]) * Scalar[dt](RAD)

    # Its azimuth at the pad, Earth-relative: the inertial direction of
    # motion at orbital speed, less the ground's own eastward speed.
    var v_orb = sqrt(Scalar[dt](MU_EARTH) / p[unsafe_offset=P_PARK_R])
    var v_rel = _cross(n_hat, s_hat) * v_orb - east * p[unsafe_offset=P_VROT]
    var az = atan2(_dot(v_rel, east), _dot(v_rel, north)) * Scalar[dt](RAD)
    var az_min = p[unsafe_offset=P_AZ_MIN]
    var az_max = p[unsafe_offset=P_AZ_MAX]
    var in_corridor = (az >= az_min and az <= az_max) or (
        az + Scalar[dt](360) >= az_min and az + Scalar[dt](360) <= az_max
    )

    # The transfer, and what it costs at both ends.
    var tr = _transfer(p[unsafe_offset=P_PARK_R], mn, tof)
    var dv_tli = tr.v_p - v_orb
    var t_hat = _cross(n_hat, m_hat)
    var v_arr = m_hat * tr.v_r + t_hat * tr.v_t
    var rel = v_arr - sky.moon_v
    # The two-body relative speed at the Moon's position, less the energy
    # the Moon's own gravity has added by the time a real trajectory is
    # there: v∞² = v_rel² − 2μ/R_SOI, the patched-conic's correction. It
    # brings the estimate within about 1% of the targeted value.
    var vinf2 = _dot(rel, rel) - Scalar[dt](2 * MU_MOON / MOON_SOI)
    var v_inf = sqrt(vinf2) if vinf2 > Scalar[dt](0) else Scalar[dt](0)
    var r_pl = p[unsafe_offset=P_RP_MOON]
    var a_l = Scalar[dt](0.5) * (r_pl + Scalar[dt](R_MOON) + p[unsafe_offset=P_LOI_APO])
    var dv_loi = sqrt(v_inf * v_inf + Scalar[dt](2 * MU_MOON) / r_pl) - sqrt(
        Scalar[dt](MU_MOON) * (Scalar[dt](2) / r_pl - Scalar[dt](1) / a_l)
    )

    # The Sun over the site when the crew get there, and whether it is
    # morning.
    var t_land = t_a + p[unsafe_offset=P_LAND_OFFSET]
    var elev = _sun_elevation(t_land, tab, n, p)
    var later = _sun_elevation(t_land + Scalar[dt](3600), tab, n, p)
    var lit = elev >= p[unsafe_offset=P_SUN_LO] and elev <= p[unsafe_offset=P_SUN_HI]
    var rising = later > elev

    var flags = 0
    if in_corridor:
        flags |= FLAG_CORRIDOR
    if lit:
        flags |= FLAG_LIT
    if rising:
        flags |= FLAG_RISING
    if tr.ok:
        flags |= FLAG_OK
    return SIMD[dt, FIELDS](
        dv_tli, dv_loi, az, inc, elev, Scalar[dt](flags), v_inf, tr.angle * Scalar[dt](RAD)
    )


# ── the kernel ───────────────────────────────────────────────────────────


def window_kernel(
    cells: Pointer[Float32, MutAnyOrigin],
    tab: Pointer[Int64, MutAnyOrigin],
    n_tab: Int32,
    params: Pointer[Float32, MutAnyOrigin],
    width: Int32,
    height: Int32,
):
    """One thread per pixel: x picks the day and, within the day's column,
    the flight time; y the launch hour."""
    var idx = Int(global_idx.x)
    var w = Int(width)
    var h = Int(height)
    if idx < w * h:
        var x = idx % w
        var y = idx // w
        var steps = Int(params[unsafe_offset=P_STEPS])
        var day = x // steps
        var k = x % steps
        var tof = params[unsafe_offset=P_TOF_MIN] + (
            params[unsafe_offset=P_TOF_MAX] - params[unsafe_offset=P_TOF_MIN]
        ) * Float32(k) / Float32(steps - 1)
        var t_launch = Float32(day) * Float32(86400) + Float32(y) * Float32(86400) / Float32(h)
        var c = cell(t_launch, tof, tab, Int(n_tab), params)
        for f in range(FIELDS):
            cells[unsafe_offset=idx * FIELDS + f] = c[f]


# ── the map, on the host ─────────────────────────────────────────────────


def days_in_month(year: Int, month: Int) -> Int:
    if month == 2:
        var leap = (year % 4 == 0 and year % 100 != 0) or year % 400 == 0
        return 29 if leap else 28
    if month == 4 or month == 6 or month == 9 or month == 11:
        return 30
    return 31


struct WindowMap(Movable):
    """A month of launch opportunities for one pad and one landing site."""

    var year: Int
    var month: Int
    var days: Int
    var steps: Int  # pixels per day column (flight times)
    var rows: Int  # pixels per day (launch times)
    var width: Int
    var height: Int
    var jd0: Float64  # 0h UT on the 1st
    var tof_min: Float64  # s
    var tof_max: Float64
    var params: List[Float64]
    var bodies: Bodies
    var cells: List[Float32]

    def __init__(
        out self,
        eph: Ephemeris,
        year: Int,
        month: Int,
        pad: Site,
        target: Site,
        tof_min_h: Float64,
        tof_max_h: Float64,
        steps: Int,
        rows: Int,
    ):
        self.year = year
        self.month = month
        self.days = days_in_month(year, month)
        self.steps = steps
        self.rows = rows
        self.width = self.days * steps
        self.height = rows
        self.jd0 = julian_day(year, month, 1)
        self.tof_min = tof_min_h * 3600.0
        self.tof_max = tof_max_h * 3600.0
        var jde0 = jde_from_ut(self.jd0)
        self.bodies = Bodies(eph, jde0, Float64(self.days) + 8.0)
        self.cells = List[Float32]()

        var pr = List[Float64](capacity=N_PARAMS)
        for _ in range(N_PARAMS):
            pr.append(0.0)
        pr[P_GMST0] = gmst_deg(self.jd0)
        var pos = site_position(pad.lat, pad.lon, self.jd0)
        pr[P_LAT_GC] = lon_lat_of(pos).lat
        pr[P_LAT_GD] = pad.lat
        pr[P_LON] = pad.lon
        pr[P_VROT] = site_velocity(pos).norm()
        pr[P_AZ_MIN] = pad.az_min
        pr[P_AZ_MAX] = pad.az_max
        pr[P_PARK_R] = R_EARTH + 185.0
        pr[P_TLI_OFFSET] = 2.0 * 3600.0 + 44.0 * 60.0 + 16.0  # Apollo 11's GET of TLI
        pr[P_LAND_OFFSET] = 26.0 * 3600.0 + 55.0 * 60.0 + 50.0  # its LOI-1 to touchdown
        pr[P_RP_MOON] = R_MOON + 111.0
        pr[P_LOI_APO] = 314.0
        var t0 = centuries(jde0)
        pr[P_OMEGA0] = lunar_node_deg(t0)
        pr[P_OMEGA_RATE] = -1934.1362891 / 36525.0
        pr[P_F0] = moon_arg_latitude_deg(t0)
        pr[P_F_RATE] = 483202.0175233 / 36525.0
        pr[P_EPS] = obliquity_deg(t0)
        var sv = spherical(target.lon, target.lat, 1.0)
        pr[P_SX] = sv.x
        pr[P_SY] = sv.y
        pr[P_SZ] = sv.z
        pr[P_TOF_MIN] = self.tof_min
        pr[P_TOF_MAX] = self.tof_max
        pr[P_STEPS] = Float64(steps)
        pr[P_ROWS] = Float64(rows)
        pr[P_SUN_LO] = 5.0
        pr[P_SUN_HI] = 14.0
        self.params = pr^

    def cell_cpu(self, t_launch: Float64, tof: Float64) -> SIMD[DType.float64, FIELDS]:
        """The reference: the same cell, in Float64."""
        return cell(t_launch, tof, self.bodies.tab.unsafe_ptr(), self.bodies.n, self.params.unsafe_ptr())

    def t_of(self, day: Int, hour: Float64) -> Float64:
        """Seconds from the epoch for a day of the month and an hour."""
        return Float64(day - 1) * 86400.0 + hour * 3600.0

    def x_of(self, day: Int, tof_h: Float64) -> Int:
        var k = Int((tof_h * 3600.0 - self.tof_min) / (self.tof_max - self.tof_min) * Float64(self.steps - 1) + 0.5)
        if k < 0:
            k = 0
        if k > self.steps - 1:
            k = self.steps - 1
        return (day - 1) * self.steps + k

    def y_of(self, hour: Float64) -> Int:
        var y = Int(hour / 24.0 * Float64(self.rows))
        return y if y < self.rows else self.rows - 1

    def tof_at(self, x: Int) -> Float64:
        return self.tof_min + (self.tof_max - self.tof_min) * Float64(x % self.steps) / Float64(self.steps - 1)

    def t_at(self, x: Int, y: Int) -> Float64:
        return Float64(x // self.steps) * 86400.0 + Float64(y) * 86400.0 / Float64(self.rows)

    def field(self, x: Int, y: Int, f: Int) -> Float64:
        return Float64(self.cells[(y * self.width + x) * FIELDS + f])

    def flags(self, x: Int, y: Int) -> Int:
        return Int(self.cells[(y * self.width + x) * FIELDS + F_FLAGS])


def plane_normal(m: WindowMap, t_launch: Float64, tof: Float64) -> Vec3:
    """The cell's plane -- through the pad at launch and the Moon at
    arrival, prograde -- as a unit normal in the equatorial frame, in
    Float64, for the transfer planner to inject into."""
    var t_a = t_launch + m.params[P_TLI_OFFSET] + tof
    var theta = m.params[P_GMST0] + 360.98564736629 * t_launch / 86400.0 + m.params[P_LON]
    var s_hat = spherical(theta, m.params[P_LAT_GC], 1.0)
    var n = s_hat.cross(m.bodies.moon_at(t_a).unit()).unit()
    return n if n.z >= 0.0 else -n


def compute_map(mut m: WindowMap, ctx: DeviceContext) raises:
    """Run the kernel over the whole map and keep the cells."""
    var n = m.width * m.height
    var out = ctx.enqueue_create_buffer[DType.float32](n * FIELDS)
    var tab = ctx.enqueue_create_buffer[DType.int64](m.bodies.n * TABLE_STRIDE)
    var prm = ctx.enqueue_create_buffer[DType.float32](N_PARAMS)
    with tab.map_to_host() as ht:
        var pt = ht.unsafe_ptr()
        for i in range(m.bodies.n * TABLE_STRIDE):
            pt[unsafe_offset=i] = m.bodies.tab[i]
    with prm.map_to_host() as hp:
        var pp = hp.unsafe_ptr()
        for i in range(N_PARAMS):
            pp[unsafe_offset=i] = Float32(m.params[i])
    var kern = ctx.compile_function[window_kernel]()
    ctx.enqueue_function(
        kern, out, tab, Int32(m.bodies.n), prm, Int32(m.width), Int32(m.height),
        grid_dim=((n + 255) // 256), block_dim=(256),
    )
    ctx.synchronize()
    m.cells = List[Float32](capacity=n * FIELDS)
    with out.map_to_host() as ho:
        var po = ho.unsafe_ptr()
        for i in range(n * FIELDS):
            m.cells.append(po[unsafe_offset=i])


from max.gpu.host import DeviceContext


def lighting_bands(m: WindowMap, tof: Float64) -> List[Float64]:
    """Scan the month hourly, on the CPU, for the launch times whose
    touchdown has the Sun in the band and rising; return the centre of
    each contiguous run as a fractional day of the month (1.0 = 0h UT
    on the 1st)."""
    var out = List[Float64]()
    var in_run = False
    var start = 0.0
    var hours = m.days * 24
    for h in range(hours + 1):
        var t = Float64(h) * 3600.0
        var lit = False
        if h < hours:
            var c = m.cell_cpu(t, tof)
            var fl = Int(c[F_FLAGS])
            lit = (fl & FLAG_LIT) != 0 and (fl & FLAG_RISING) != 0
        if lit and not in_run:
            in_run = True
            start = t
        if not lit and in_run:
            in_run = False
            out.append(1.0 + 0.5 * (start + t) / 86400.0)
    return out^


def corridor_windows(m: WindowMap, day: Int, tof: Float64) -> List[Float64]:
    """Every run of launch minutes inside the corridor that day, scanned
    by the minute on the CPU: four numbers per run -- the first hour, the
    last, and the azimuth at each. There are normally two a day: the pad
    passes through the plane twice, once for each injection geometry
    (Apollo called them the Pacific and the Atlantic opportunities)."""
    var out = List[Float64]()
    var first = -1.0
    var last = -1.0
    var az_first = 0.0
    var az_last = 0.0
    for mnt in range(1441):
        var hour = Float64(mnt) / 60.0
        var inside = False
        var az = 0.0
        if mnt < 1440:
            var c = m.cell_cpu(m.t_of(day, hour), tof)
            inside = Int(c[F_FLAGS]) & FLAG_CORRIDOR != 0
            az = c[F_AZ]
        if inside:
            if first < 0.0:
                first = hour
                az_first = az
            last = hour
            az_last = az
        elif first >= 0.0:
            out.append(first)
            out.append(last)
            out.append(az_first)
            out.append(az_last)
            first = -1.0
    return out^


def save_map(m: WindowMap, path: String, mark_x: Int, mark_y: Int) -> Bool:
    """The picture: corridor-less pixels dark, dark-site pixels blue,
    good ones on a green-to-red ramp by total Δv above the month's best,
    day boundaries as faint lines, and a white cross where asked."""
    var n = m.width * m.height
    var bgra = Pointer[UInt32, MutUntrackedOrigin](
        unsafe_from_address=Int(external_call["calloc", P](Int(n), Int(4)))
    )
    var best = 1.0e30
    for i in range(n):
        var fl = Int(m.cells[i * FIELDS + F_FLAGS])
        if fl & FLAG_CORRIDOR != 0 and fl & FLAG_LIT != 0 and fl & FLAG_RISING != 0 and fl & FLAG_OK != 0:
            var dv = Float64(m.cells[i * FIELDS + F_DV_TLI]) + Float64(m.cells[i * FIELDS + F_DV_LOI])
            if dv < best:
                best = dv
    for y in range(m.height):
        for x in range(m.width):
            var i = y * m.width + x
            var fl = Int(m.cells[i * FIELDS + F_FLAGS])
            var dv = Float64(m.cells[i * FIELDS + F_DV_TLI]) + Float64(m.cells[i * FIELDS + F_DV_LOI])
            var r = 18
            var g = 18
            var b = 26
            if fl & FLAG_OK == 0:
                r = 40
                g = 10
                b = 10
            elif fl & FLAG_CORRIDOR != 0:
                var u = (dv - best) / 0.5
                u = 0.0 if u < 0.0 else (1.0 if u > 1.0 else u)
                if fl & FLAG_LIT != 0 and fl & FLAG_RISING != 0:
                    # green (cheap) through yellow to red (dear)
                    r = Int(255.0 * (u if u < 0.5 else 1.0) * 2.0 if u < 0.5 else 255)
                    g = Int(255.0 if u < 0.5 else 255.0 * (1.0 - (u - 0.5) * 2.0))
                    b = 40
                else:
                    r = 40 + Int(40.0 * (1.0 - u))
                    g = 60 + Int(50.0 * (1.0 - u))
                    b = 120 + Int(100.0 * (1.0 - u))
            if x % m.steps == 0:
                r = r // 2
                g = g // 2
                b = b // 2
            bgra[unsafe_offset=i] = UInt32(255 << 24) | UInt32(r << 16) | UInt32(g << 8) | UInt32(b)
    # the mark
    for d in range(-6, 7):
        for xx in range(mark_x + d, mark_x + d + 1):
            if xx >= 0 and xx < m.width and mark_y >= 0 and mark_y < m.height:
                bgra[unsafe_offset=mark_y * m.width + xx] = UInt32(0xFFFFFFFF)
        var yy = mark_y + d
        if yy >= 0 and yy < m.height and mark_x >= 0 and mark_x < m.width:
            bgra[unsafe_offset=yy * m.width + mark_x] = UInt32(0xFFFFFFFF)
    var ok = save_png(path, bgra, m.width, m.height)
    external_call["free", NoneType](bgra.unsafe_bitcast[NoneType]())
    return ok
