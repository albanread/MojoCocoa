# ===----------------------------------------------------------------------=== #
# Moonshot — the astronomy core (sprint MC0).
#
# Where the Moon and the Sun are on any date, what time it is on the sky,
# which way the Moon is facing, and where the launch pads, the landing
# sites and the tracking stations are. Everything the later sprints
# integrate, target or draw starts from a number that comes out of here,
# so every number here has an oracle that is not us: the worked examples
# in Jean Meeus, *Astronomical Algorithms* (2nd ed.), cited by chapter and
# example beside the code that reproduces them, and asserted to the book's
# own digits in `test_astro.mojo`.
#
# The frame. One Cartesian frame for everything: Earth-centred, mean
# equator and equinox OF DATE, kilometres and seconds. It precesses at
# 50 arcseconds a year, which over a five-day mission is 0.7 arcseconds --
# 1.3 km at the Moon, a third of the ephemeris's own accuracy -- so it is
# treated as inertial. Nutation is never applied: it moves the frame, not
# the bodies, and everything here is in the same mean frame, so it cancels.
#
# Time. Two clocks, deliberately kept apart in the names: `jd_ut` is
# Universal Time (what a launch clock and sidereal time use) and `jde` is
# dynamical time (what the ephemeris series were fitted in). They differ
# by ΔT -- 40 s in 1969, 70 s today -- and 40 s of the Moon's motion is
# 22 arcseconds, 40 km at its distance. `jde_from_ut` is the only bridge.
# ===----------------------------------------------------------------------=== #

from std.math import sin, cos, atan2, asin, sqrt, floor

# ── the constants ────────────────────────────────────────────────────────

comptime MU_EARTH = 398600.4418
"""Earth's gravitational parameter, km³/s²."""
comptime R_EARTH = 6378.137
"""Earth's equatorial radius, km (WGS 84)."""
comptime FLATTENING = 1.0 / 298.257223563
"""WGS 84 flattening: the pole is 21 km closer to the centre than the equator."""
comptime J2_EARTH = 1.08262668e-3
comptime OMEGA_EARTH = 7.2921150e-5
"""Earth's rotation rate, rad/s: 0.4651 km/s at the equator."""
comptime MU_MOON = 4902.800066
comptime R_MOON = 1737.4
comptime MOON_SOI = 66100.0
"""The Moon's sphere of influence, km -- where the integrator's centre changes."""
comptime MU_SUN = 1.32712440018e11
comptime AU = 149597870.7
comptime MOON_TILT = 1.54242
"""The lunar equator's inclination to the ecliptic, degrees (Meeus 53)."""

comptime J2000 = 2451545.0
comptime DEG = 0.017453292519943295
comptime RAD = 57.29577951308232


# ── vectors ──────────────────────────────────────────────────────────────


@fieldwise_init
struct Vec3(ImplicitlyCopyable, Movable):
    var x: Float64
    var y: Float64
    var z: Float64

    def __add__(self, o: Vec3) -> Vec3:
        return Vec3(self.x + o.x, self.y + o.y, self.z + o.z)

    def __sub__(self, o: Vec3) -> Vec3:
        return Vec3(self.x - o.x, self.y - o.y, self.z - o.z)

    def __mul__(self, k: Float64) -> Vec3:
        return Vec3(self.x * k, self.y * k, self.z * k)

    def __neg__(self) -> Vec3:
        return Vec3(-self.x, -self.y, -self.z)

    def dot(self, o: Vec3) -> Float64:
        return self.x * o.x + self.y * o.y + self.z * o.z

    def cross(self, o: Vec3) -> Vec3:
        return Vec3(
            self.y * o.z - self.z * o.y,
            self.z * o.x - self.x * o.z,
            self.x * o.y - self.y * o.x,
        )

    def norm(self) -> Float64:
        return sqrt(self.dot(self))

    def unit(self) -> Vec3:
        var n = self.norm()
        return Vec3(self.x / n, self.y / n, self.z / n)


def spherical(lon_deg: Float64, lat_deg: Float64, r: Float64) -> Vec3:
    """Longitude east, latitude north, radius -> a Cartesian vector."""
    var cl = cos(lat_deg * DEG)
    return Vec3(
        r * cl * cos(lon_deg * DEG),
        r * cl * sin(lon_deg * DEG),
        r * sin(lat_deg * DEG),
    )


def ecliptic_to_equatorial(v: Vec3, eps_deg: Float64) -> Vec3:
    """Rotate about the x axis (the equinox) by the obliquity."""
    var c = cos(eps_deg * DEG)
    var s = sin(eps_deg * DEG)
    return Vec3(v.x, v.y * c - v.z * s, v.y * s + v.z * c)


@fieldwise_init
struct LonLat(ImplicitlyCopyable, Movable):
    """A direction as longitude (east-positive, -180..180) and latitude, degrees."""

    var lon: Float64
    var lat: Float64


def lon_lat_of(v: Vec3) -> LonLat:
    var lon = atan2(v.y, v.x) * RAD
    var lat = asin(v.z / v.norm()) * RAD
    return LonLat(lon, lat)


# ── time ─────────────────────────────────────────────────────────────────


def wrap360(x: Float64) -> Float64:
    return x - 360.0 * floor(x / 360.0)


def wrap180(x: Float64) -> Float64:
    var w = wrap360(x)
    return w - 360.0 if w > 180.0 else w


def julian_day(
    year: Int,
    month: Int,
    day: Int,
    hour: Int = 0,
    minute: Int = 0,
    second: Float64 = 0.0,
) -> Float64:
    """Meeus 7.1, Gregorian calendar. 2000 January 1, 12:00 -> 2 451 545.0."""
    var y = year
    var m = month
    if m <= 2:
        y -= 1
        m += 12
    var a = y // 100
    var b = 2 - a + a // 4
    var frac = (Float64(hour) + Float64(minute) / 60.0 + second / 3600.0) / 24.0
    return (
        floor(365.25 * Float64(y + 4716))
        + floor(30.6001 * Float64(m + 1))
        + Float64(day)
        + frac
        + Float64(b)
        - 1524.5
    )


@fieldwise_init
struct Civil(ImplicitlyCopyable, Movable):
    var year: Int
    var month: Int
    var day: Int
    var hour: Int
    var minute: Int
    var second: Float64


def civil(jd: Float64) -> Civil:
    """Meeus 7, the inverse: a Julian Day back to a Gregorian date and time."""
    # Half a millisecond first, then truncate the seconds to milliseconds:
    # 13:32:00 must not come back as 13:31:59.999.
    var j = jd + 0.5 + 0.0005 / 86400.0
    var z = Int(floor(j))
    var f = floor((j - Float64(z)) * 86400000.0) / 86400000.0
    var a = z
    if z >= 2299161:
        var alpha = Int(floor((Float64(z) - 1867216.25) / 36524.25))
        a = z + 1 + alpha - alpha // 4
    var b = a + 1524
    var c = Int(floor((Float64(b) - 122.1) / 365.25))
    var d = Int(floor(365.25 * Float64(c)))
    var e = Int(floor(Float64(b - d) / 30.6001))
    var day = b - d - Int(floor(30.6001 * Float64(e)))
    var month = e - 1 if e < 14 else e - 13
    var year = c - 4716 if month > 2 else c - 4715
    var secs = f * 86400.0
    var hour = Int(floor(secs / 3600.0))
    secs -= Float64(hour) * 3600.0
    var minute = Int(floor(secs / 60.0))
    secs -= Float64(minute) * 60.0
    return Civil(year, month, day, hour, minute, secs)


def centuries(jd: Float64) -> Float64:
    """T: Julian centuries from J2000.0 -- the argument of every series here."""
    return (jd - J2000) / 36525.0


def delta_t_seconds(year: Float64) -> Float64:
    """TD − UT. Espenak & Meeus's polynomial fits, one per era; the pieces
    meet at their boundaries to a hundredth of a second. Below 1920 and
    beyond 2050 the nearest fit is used, and the game does not go there."""
    if year < 1941.0:
        var t = year - 1920.0
        return 21.20 + 0.84493 * t - 0.076100 * t * t + 0.0020936 * t * t * t
    if year < 1961.0:
        var t = year - 1950.0
        return 29.07 + 0.407 * t - t * t / 233.0 + t * t * t / 2547.0
    if year < 1986.0:
        var t = year - 1975.0
        return 45.45 + 1.067 * t - t * t / 260.0 - t * t * t / 718.0
    if year < 2005.0:
        var t = year - 2000.0
        var t2 = t * t
        return (
            63.86
            + 0.3345 * t
            - 0.060374 * t2
            + 0.0017275 * t2 * t
            + 0.000651814 * t2 * t2
            + 0.00002373599 * t2 * t2 * t
        )
    if year < 2050.0:
        var t = year - 2000.0
        return 62.92 + 0.32217 * t + 0.005589 * t * t
    var t = (year - 1820.0) / 100.0
    return -20.0 + 32.0 * t * t


def year_of(jd: Float64) -> Float64:
    return 2000.0 + (jd - J2000) / 365.25


def jde_from_ut(jd_ut: Float64) -> Float64:
    """The one bridge between the clocks: Universal Time to dynamical time."""
    return jd_ut + delta_t_seconds(year_of(jd_ut)) / 86400.0


def gmst_deg(jd_ut: Float64) -> Float64:
    """Greenwich mean sidereal time, degrees (Meeus 12.4).
    1987 April 10, 0h UT -> 197.693 195° = 13h 10m 46.3668s."""
    var d = jd_ut - J2000
    var t = d / 36525.0
    return wrap360(
        280.46061837
        + 360.98564736629 * d
        + 0.000387933 * t * t
        - t * t * t / 38710000.0
    )


def obliquity_deg(t: Float64) -> Float64:
    """Mean obliquity of the ecliptic (Meeus 22.2): 23°26′21.448″ − 46.8150″ T …"""
    return (
        23.439291111
        - 0.013004167 * t
        - 1.63889e-7 * t * t
        + 5.03611e-7 * t * t * t
    )


def lunar_node_deg(t: Float64) -> Float64:
    """Mean longitude of the Moon's ascending node, Ω (Meeus 47.7)."""
    return wrap360(
        125.0445479
        - 1934.1362891 * t
        + 0.0020754 * t * t
        + t * t * t / 467441.0
        - t * t * t * t / 60616000.0
    )


def moon_arg_latitude_deg(t: Float64) -> Float64:
    """The Moon's mean argument of latitude, F = L′ − Ω (Meeus 47.5) -- also
    the angle the Moon's prime meridian has turned from the node."""
    return wrap360(
        93.2720950
        + 483202.0175233 * t
        - 0.0036539 * t * t
        - t * t * t / 3526000.0
        + t * t * t * t / 863310000.0
    )


# ── the Moon and the Sun ─────────────────────────────────────────────────


@fieldwise_init
struct MoonState(ImplicitlyCopyable, Movable):
    """Everything Meeus 47 computes on the way to a position, kept so the
    test can check each stage against example 47.a rather than only the
    end -- when a 60-term table has one digit wrong, the end is what tells
    you nothing about where."""

    var lp: Float64  # L′ mean longitude
    var d: Float64  # mean elongation
    var m: Float64  # Sun's mean anomaly
    var mp: Float64  # Moon's mean anomaly
    var f: Float64  # argument of latitude
    var e: Float64  # eccentricity factor
    var sum_l: Float64
    var sum_b: Float64
    var sum_r: Float64
    var lon: Float64  # geometric ecliptic longitude, degrees, mean equinox of date
    var lat: Float64
    var dist: Float64  # km


@fieldwise_init
struct SunState(ImplicitlyCopyable, Movable):
    var l0: Float64
    var m: Float64
    var e: Float64
    var c: Float64
    var lon: Float64  # geometric longitude ⊙
    var nu: Float64
    var r: Float64  # AU


struct Ephemeris(Movable):
    """Meeus's abbreviated ELP-2000/82 for the Moon (chapter 47) and the
    low-precision Sun (chapter 25). The Moon to ~10″ and ~4 km; the Sun to
    0.01°. The tables are held here rather than rebuilt per call: a window
    map asks for the Moon several hundred thousand times."""

    # Table 47.A: D, M, M′, F multipliers, then the Σl and Σr coefficients.
    var lr: List[Int]
    # Table 47.B: D, M, M′, F multipliers, then the Σb coefficient.
    var b: List[Int]

    def __init__(out self):
        self.lr = [
            0, 0, 1, 0, 6288774, -20905355,
            2, 0, -1, 0, 1274027, -3699111,
            2, 0, 0, 0, 658314, -2955968,
            0, 0, 2, 0, 213618, -569925,
            0, 1, 0, 0, -185116, 48888,
            0, 0, 0, 2, -114332, -3149,
            2, 0, -2, 0, 58793, 246158,
            2, -1, -1, 0, 57066, -152138,
            2, 0, 1, 0, 53322, -170733,
            2, -1, 0, 0, 45758, -204586,
            0, 1, -1, 0, -40923, -129620,
            1, 0, 0, 0, -34720, 108743,
            0, 1, 1, 0, -30383, 104755,
            2, 0, 0, -2, 15327, 10321,
            0, 0, 1, 2, -12528, 0,
            0, 0, 1, -2, 10980, 79661,
            4, 0, -1, 0, 10675, -34782,
            0, 0, 3, 0, 10034, -23210,
            4, 0, -2, 0, 8548, -21636,
            2, 1, -1, 0, -7888, 24208,
            2, 1, 0, 0, -6766, 30824,
            1, 0, -1, 0, -5163, -8379,
            1, 1, 0, 0, 4987, -16675,
            2, -1, 1, 0, 4036, -12831,
            2, 0, 2, 0, 3994, -10445,
            4, 0, 0, 0, 3861, -11650,
            2, 0, -3, 0, 3665, 14403,
            0, 1, -2, 0, -2689, -7003,
            2, 0, -1, 2, -2602, 0,
            2, -1, -2, 0, 2390, 10056,
            1, 0, 1, 0, -2348, 6322,
            2, -2, 0, 0, 2236, -9884,
            0, 1, 2, 0, -2120, 5751,
            0, 2, 0, 0, -2069, 0,
            2, -2, -1, 0, 2048, -4950,
            2, 0, 1, -2, -1773, 4130,
            2, 0, 0, 2, -1595, 0,
            4, -1, -1, 0, 1215, -3958,
            0, 0, 2, 2, -1110, 0,
            3, 0, -1, 0, -892, 3258,
            2, 1, 1, 0, -810, 2616,
            4, -1, -2, 0, 759, -1897,
            0, 2, -1, 0, -713, -2117,
            2, 2, -1, 0, -700, 2354,
            2, 1, -2, 0, 691, 0,
            2, -1, 0, -2, 596, 0,
            4, 0, 1, 0, 549, -1423,
            0, 0, 4, 0, 537, -1117,
            4, -1, 0, 0, 520, -1571,
            1, 0, -2, 0, -487, -1739,
            2, 1, 0, -2, -399, 0,
            0, 0, 2, -2, -381, -4421,
            1, 1, 1, 0, 351, 0,
            3, 0, -2, 0, -340, 0,
            4, 0, -3, 0, 330, 0,
            2, -1, 2, 0, 327, 0,
            0, 2, 1, 0, -323, 1165,
            1, 1, -1, 0, 299, 0,
            2, 0, 3, 0, 294, 0,
            2, 0, -1, -2, 0, 8752,
        ]
        self.b = [
            0, 0, 0, 1, 5128122,
            0, 0, 1, 1, 280602,
            0, 0, 1, -1, 277693,
            2, 0, 0, -1, 173237,
            2, 0, -1, 1, 55413,
            2, 0, -1, -1, 46271,
            2, 0, 0, 1, 32573,
            0, 0, 2, 1, 17198,
            2, 0, 1, -1, 9266,
            0, 0, 2, -1, 8822,
            2, -1, 0, -1, 8216,
            2, 0, -2, -1, 4324,
            2, 0, 1, 1, 4200,
            2, 1, 0, -1, -3359,
            2, -1, -1, 1, 2463,
            2, -1, 0, 1, 2211,
            2, -1, -1, -1, 2065,
            0, 1, -1, -1, -1870,
            4, 0, -1, -1, 1828,
            0, 1, 0, 1, -1794,
            0, 0, 0, 3, -1749,
            0, 1, -1, 1, -1565,
            1, 0, 0, 1, -1491,
            0, 1, 1, 1, -1475,
            0, 1, 1, -1, -1410,
            0, 1, 0, -1, -1344,
            1, 0, 0, -1, -1335,
            0, 0, 3, 1, 1107,
            4, 0, 0, -1, 1021,
            4, 0, -1, 1, 833,
            0, 0, 1, -3, 777,
            4, 0, -2, 1, 671,
            2, 0, 0, -3, 607,
            2, 0, 2, -1, 596,
            2, -1, 1, -1, 491,
            2, 0, -2, 1, -451,
            0, 0, 3, -1, 439,
            2, 0, 2, 1, 422,
            2, 0, -3, -1, 421,
            2, 1, -1, 1, -366,
            2, 1, 0, 1, -351,
            4, 0, 0, 1, 331,
            2, -1, 1, 1, 315,
            2, -2, 0, -1, 302,
            0, 0, 1, 3, -283,
            2, 1, 1, -1, -229,
            1, 1, 0, -1, 223,
            1, 1, 0, 1, 223,
            0, 1, -2, -1, -220,
            2, 1, -1, -1, -220,
            1, 0, 1, 1, -185,
            2, -1, -2, -1, 181,
            0, 1, 2, 1, -177,
            4, 0, -2, -1, 176,
            4, -1, -1, -1, 166,
            1, 0, 1, -1, -164,
            4, 0, 1, -1, 132,
            1, 0, -1, -1, -119,
            4, -1, 0, -1, 115,
            2, -2, 0, 1, 107,
        ]

    def moon(self, jde: Float64) -> MoonState:
        """Meeus 47. Example 47.a: 1992 April 12, 0h TD ->
        λ = 133.162 655°, β = −3.229 126°, Δ = 368 409.7 km."""
        var t = centuries(jde)
        var t2 = t * t
        var t3 = t2 * t
        var t4 = t3 * t
        var lp = wrap360(
            218.3164477 + 481267.88123421 * t - 0.0015786 * t2
            + t3 / 538841.0 - t4 / 65194000.0
        )
        var d = wrap360(
            297.8501921 + 445267.1114034 * t - 0.0018819 * t2
            + t3 / 545868.0 - t4 / 113065000.0
        )
        var m = wrap360(
            357.5291092 + 35999.0502909 * t - 0.0001536 * t2 + t3 / 24490000.0
        )
        var mp = wrap360(
            134.9633964 + 477198.8675055 * t + 0.0087414 * t2
            + t3 / 69699.0 - t4 / 14712000.0
        )
        var f = moon_arg_latitude_deg(t)
        var a1 = wrap360(119.75 + 131.849 * t)
        var a2 = wrap360(53.09 + 479264.290 * t)
        var a3 = wrap360(313.45 + 481266.484 * t)
        var e = 1.0 - 0.002516 * t - 0.0000074 * t2

        var sum_l = 0.0
        var sum_r = 0.0
        for i in range(60):
            var k = i * 6
            var arg = (
                Float64(self.lr[k]) * d
                + Float64(self.lr[k + 1]) * m
                + Float64(self.lr[k + 2]) * mp
                + Float64(self.lr[k + 3]) * f
            ) * DEG
            var em = abs(self.lr[k + 1])
            var scale = 1.0 if em == 0 else (e if em == 1 else e * e)
            sum_l += Float64(self.lr[k + 4]) * scale * sin(arg)
            sum_r += Float64(self.lr[k + 5]) * scale * cos(arg)
        var sum_b = 0.0
        for i in range(60):
            var k = i * 5
            var arg = (
                Float64(self.b[k]) * d
                + Float64(self.b[k + 1]) * m
                + Float64(self.b[k + 2]) * mp
                + Float64(self.b[k + 3]) * f
            ) * DEG
            var em = abs(self.b[k + 1])
            var scale = 1.0 if em == 0 else (e if em == 1 else e * e)
            sum_b += Float64(self.b[k + 4]) * scale * sin(arg)

        # The additive terms: Venus (A1), Jupiter (A2), and the flattening
        # of the Earth (the L′ − F term).
        sum_l += 3958.0 * sin(a1 * DEG) + 1962.0 * sin((lp - f) * DEG) + 318.0 * sin(a2 * DEG)
        sum_b += (
            -2235.0 * sin(lp * DEG)
            + 382.0 * sin(a3 * DEG)
            + 175.0 * sin((a1 - f) * DEG)
            + 175.0 * sin((a1 + f) * DEG)
            + 127.0 * sin((lp - mp) * DEG)
            - 115.0 * sin((lp + mp) * DEG)
        )
        return MoonState(
            lp, d, m, mp, f, e, sum_l, sum_b, sum_r,
            wrap360(lp + sum_l / 1000000.0),
            sum_b / 1000000.0,
            385000.56 + sum_r / 1000.0,
        )

    def sun(self, jde: Float64) -> SunState:
        """Meeus 25, the low-precision Sun. Example 25.a: 1992 October 13,
        0h TD -> ⊙ = 199.909 88°, R = 0.997 66 AU."""
        var t = centuries(jde)
        var t2 = t * t
        var l0 = wrap360(280.46646 + 36000.76983 * t + 0.0003032 * t2)
        var m = wrap360(357.52911 + 35999.05029 * t - 0.0001537 * t2)
        var e = 0.016708634 - 0.000042037 * t - 0.0000001267 * t2
        var mr = m * DEG
        var c = (
            (1.914602 - 0.004817 * t - 0.000014 * t2) * sin(mr)
            + (0.019993 - 0.000101 * t) * sin(2.0 * mr)
            + 0.000289 * sin(3.0 * mr)
        )
        var lon = wrap360(l0 + c)
        var nu = m + c
        var r = 1.000001018 * (1.0 - e * e) / (1.0 + e * cos(nu * DEG))
        return SunState(l0, m, e, c, lon, nu, r)

    def moon_position(self, jde: Float64) -> Vec3:
        """The Moon, geocentric, km, mean equator and equinox of date."""
        var s = self.moon(jde)
        var eps = obliquity_deg(centuries(jde))
        return ecliptic_to_equatorial(spherical(s.lon, s.lat, s.dist), eps)

    def moon_velocity(self, jde: Float64) -> Vec3:
        """km/s, by a central difference over two minutes -- the series is
        smooth and the truncation error is far below its own accuracy."""
        var h = 1.0 / 1440.0
        var a = self.moon_position(jde - h)
        var b = self.moon_position(jde + h)
        return (b - a) * (1.0 / (2.0 * h * 86400.0))

    def sun_position(self, jde: Float64) -> Vec3:
        """The Sun, geocentric, km, same frame. Latitude is taken as zero
        (it is never more than 1.2″)."""
        var s = self.sun(jde)
        var eps = obliquity_deg(centuries(jde))
        return ecliptic_to_equatorial(spherical(s.lon, 0.0, s.r * AU), eps)

    # ── the Moon-fixed frame ─────────────────────────────────────────────

    def moon_frame(self, jde: Float64) -> MoonFrame:
        """The Moon's body axes in the equatorial frame, from Cassini's laws
        as Meeus 53 encodes them: the spin pole is tilted I = 1.5424° from
        the ecliptic pole toward longitude Ω + 90°; the prime meridian --
        the mean Earth-facing direction -- has turned F from the node.
        x faces the mean Earth, z is the pole, y = z × x points to 90° east
        (Mare Crisium's side), which is the selenographic convention."""
        var t = centuries(jde)
        var om = lunar_node_deg(t) * DEG
        var f = moon_arg_latitude_deg(t) * DEG
        var ci = cos(MOON_TILT * DEG)
        var si = sin(MOON_TILT * DEG)
        # In the ecliptic frame: the pole, the node line, and the direction
        # along the equator 90° past the node.
        var pole = Vec3(-sin(om) * si, cos(om) * si, ci)
        var node = Vec3(cos(om), sin(om), 0.0)
        var along = Vec3(-ci * sin(om), ci * cos(om), -si)
        var x = -(node * cos(f) + along * sin(f))
        var z = pole
        var y = z.cross(x)
        var eps = obliquity_deg(t)
        return MoonFrame(
            ecliptic_to_equatorial(x, eps),
            ecliptic_to_equatorial(y, eps),
            ecliptic_to_equatorial(z, eps),
        )

    def sub_earth_point(self, jde: Float64) -> LonLat:
        """Optical libration: the selenographic point under the Earth.
        Meeus 53 example a (1992 April 12): l′ = −1.206°, b′ = +4.194°."""
        var frame = self.moon_frame(jde)
        return frame.selenographic(-self.moon_position(jde))

    def sub_solar_point(self, jde: Float64) -> LonLat:
        var frame = self.moon_frame(jde)
        var to_sun = self.sun_position(jde) - self.moon_position(jde)
        return frame.selenographic(to_sun)

    def sun_elevation_deg(self, jde: Float64, site_lat: Float64, site_lon: Float64) -> Float64:
        """The Sun's elevation above a landing site's horizon, degrees.
        Apollo 11 landed with it at 10.8°: low, behind the approach, so the
        crew could read the ground. This is the lighting constraint."""
        var frame = self.moon_frame(jde)
        var up = frame.to_inertial(site_lat, site_lon)
        var to_sun = (self.sun_position(jde) - self.moon_position(jde)).unit()
        return asin(up.dot(to_sun)) * RAD


@fieldwise_init
struct MoonFrame(ImplicitlyCopyable, Movable):
    """Unit vectors of the Moon's body axes, in the equatorial frame."""

    var x: Vec3
    var y: Vec3
    var z: Vec3

    def selenographic(self, d: Vec3) -> LonLat:
        """Longitude and latitude of a direction from the Moon's centre."""
        var u = d.unit()
        return LonLat(atan2(u.dot(self.y), u.dot(self.x)) * RAD, asin(u.dot(self.z)) * RAD)

    def to_inertial(self, lat_deg: Float64, lon_deg: Float64) -> Vec3:
        """The unit vector, in the equatorial frame, of a selenographic point."""
        var cl = cos(lat_deg * DEG)
        return (
            self.x * (cl * cos(lon_deg * DEG))
            + self.y * (cl * sin(lon_deg * DEG))
            + self.z * sin(lat_deg * DEG)
        )


# ── the Earth's surface ──────────────────────────────────────────────────


@fieldwise_init
struct Site(ImplicitlyCopyable, Movable):
    """A place on a body: geodetic latitude, east longitude, degrees. For a
    launch site, the range-safety azimuth corridor; zero for the others."""

    var name: String
    var lat: Float64
    var lon: Float64
    var az_min: Float64
    var az_max: Float64


def launch_sites() -> List[Site]:
    var s = List[Site]()
    s.append(Site("Kennedy LC-39A", 28.6083, -80.6041, 72.0, 108.0))
    s.append(Site("Baikonur Site 1", 45.9203, 63.3420, 35.0, 90.0))
    s.append(Site("Kourou ELA-3", 5.2390, -52.7683, -10.5, 93.5))
    s.append(Site("Vandenberg SLC-6", 34.5813, -120.6266, 147.0, 201.0))
    return s^


def landing_sites() -> List[Site]:
    """Selenographic, east-positive. The six Apollo sites and a polar one."""
    var s = List[Site]()
    s.append(Site("Tranquility Base", 0.67408, 23.47297, 0.0, 0.0))
    # Apollo 11's own alternates for July 1969: Site 3 for the 18th, Site 5
    # for the 21st, each a lunar morning later.
    s.append(Site("Sinus Medii (Site 3)", 0.5, -1.33, 0.0, 0.0))
    s.append(Site("Site 5, Oceanus Procellarum", 1.67, -41.83, 0.0, 0.0))
    s.append(Site("Ocean of Storms", -3.01239, -23.42157, 0.0, 0.0))
    s.append(Site("Fra Mauro", -3.64530, -17.47136, 0.0, 0.0))
    s.append(Site("Hadley-Apennine", 26.13222, 3.63386, 0.0, 0.0))
    s.append(Site("Descartes", -8.97301, 15.50019, 0.0, 0.0))
    s.append(Site("Taurus-Littrow", 20.19080, 30.77168, 0.0, 0.0))
    s.append(Site("Shackleton rim", -89.9, 0.0, 0.0, 0.0))
    return s^


def stations() -> List[Site]:
    """The three 26 m Manned Space Flight Network dishes, 120° apart so one
    always sees the Moon."""
    var s = List[Site]()
    s.append(Site("Goldstone", 35.4267, -116.8900, 0.0, 0.0))
    s.append(Site("Madrid", 40.4552, -4.1683, 0.0, 0.0))
    s.append(Site("Honeysuckle Creek", -35.5836, 148.9775, 0.0, 0.0))
    return s^


def site_position(lat_deg: Float64, lon_deg: Float64, jd_ut: Float64) -> Vec3:
    """A site's geocentric position, km, in the equatorial frame at a UT --
    on the WGS 84 ellipsoid, because the 21 km of flattening moves a
    site's geocentric latitude by up to 0.19°, and the launch plane's
    inclination inherits that directly."""
    var theta = (gmst_deg(jd_ut) + lon_deg) * DEG
    var phi = lat_deg * DEG
    var e2 = FLATTENING * (2.0 - FLATTENING)
    var n = R_EARTH / sqrt(1.0 - e2 * sin(phi) * sin(phi))
    var rxy = n * cos(phi)
    return Vec3(rxy * cos(theta), rxy * sin(theta), n * (1.0 - e2) * sin(phi))


def site_velocity(pos: Vec3) -> Vec3:
    """ω × r: what the Earth's rotation gives a launch for free, km/s."""
    return Vec3(-OMEGA_EARTH * pos.y, OMEGA_EARTH * pos.x, 0.0)


# ── printing ─────────────────────────────────────────────────────────────


def fmt(x: Float64, decimals: Int) -> String:
    """Fixed decimals, rounded half up -- the book's numbers are printed
    this way and a comparison by eye needs the same."""
    var scale = 1.0
    for _ in range(decimals):
        scale *= 10.0
    var neg = x < 0.0
    var v = Int(floor((-x if neg else x) * scale + 0.5))
    var s = String(v // Int(scale))
    if decimals > 0:
        var f = String(v % Int(scale))
        while f.byte_length() < decimals:
            f = String("0") + f
        s = s + "." + f
    return (String("-") if neg else String("")) + s


def hms(deg: Float64) -> String:
    """Degrees of sidereal time as hours, minutes, seconds."""
    var h = deg / 15.0
    var hh = Int(floor(h))
    var mm = Int(floor((h - Float64(hh)) * 60.0))
    var ss = ((h - Float64(hh)) * 60.0 - Float64(mm)) * 60.0
    return String(hh) + "h " + String(mm) + "m " + fmt(ss, 4) + "s"


def civil_string(c: Civil) -> String:
    var s = String(c.year) + "-"
    s += (String("0") if c.month < 10 else String("")) + String(c.month) + "-"
    s += (String("0") if c.day < 10 else String("")) + String(c.day) + " "
    s += (String("0") if c.hour < 10 else String("")) + String(c.hour) + ":"
    s += (String("0") if c.minute < 10 else String("")) + String(c.minute) + ":"
    var sec = Int(floor(c.second + 0.5))
    s += (String("0") if sec < 10 else String("")) + String(sec)
    return s
