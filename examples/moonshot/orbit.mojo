# ===----------------------------------------------------------------------=== #
# Moonshot — the integrator (sprint MC1).
#
# One integrator, two targets. `gravity` and `rk4_step` are written once,
# generic over the float type, and compiled twice: the CPU calls them in
# Float64 for the truth -- the plan the trench commits to -- and the GPU
# kernel at the bottom of this file calls the same functions in Float32
# for the sixteen thousand what-ifs of the dispersion cloud. Metal has no
# double, so the two arcs part company; `test_orbit.mojo` measures by how
# much at lunar arrival and prints it, because a number nobody measured
# is a number nobody should trust.
#
# The forces: Earth as a point mass plus J2 (the equatorial bulge, which
# turns a parking orbit's node by eight degrees a day and is left on
# everywhere because at the Moon it costs nothing and switching it off
# would put a step in the force); the Moon and the Sun as third bodies in
# the Earth-centred frame, which needs the INDIRECT term -- the frame's
# origin is itself falling toward them -- or the Moon would appear to
# pull the spacecraft twice.
#
# The Moon and Sun come from a table, not from the series: positions
# every 60 s over the mission, linearly interpolated. The chord error of
# a 60 s lunar arc is a millimetre, and a kernel that evaluated 120
# trigonometric terms four times a step would be a kernel that never
# finished.
#
# Beside the integrator, Kepler. `kepler` is the two-body problem in
# closed form (universal variables, so one function covers the parking
# orbit, the transfer ellipse and the hyperbolic flyby), and it is what
# proves the integrator: turn the Moon, the Sun and J2 off, and RK4 must
# reproduce Kepler to a metre over a day of low orbit.
# ===----------------------------------------------------------------------=== #

from std.gpu import global_idx
from std.math import sqrt, sin, cos, sinh, cosh, acos, atan2, floor
from astro import (
    Vec3, Ephemeris, MU_EARTH, MU_MOON, MU_SUN, R_EARTH, J2_EARTH, DEG, RAD,
)

comptime F_J2 = 1
comptime F_MOON = 2
comptime F_SUN = 4
comptime F_ALL = 7
comptime F_NONE = 0

comptime TABLE_STEP = 60.0
"""Seconds between ephemeris samples."""
comptime TABLE_STRIDE = 6
"""Floats per sample: Moon xyz, Sun xyz."""


# ── the shared core ──────────────────────────────────────────────────────
#
# Precision. A Float32 has 24 bits of mantissa: at the Moon's distance the
# last bit is 31 metres, and adding a step's motion to a position 3 300
# times loses a few kilometres by the time the Moon is reached -- which
# the Moon's gravity then multiplies by four (MC1 measured 25 km). The
# Apollo Guidance Computer had no floating point at all and kept its
# state in fixed point, and that is what the GPU does here: positions
# and velocities ACCUMULATE in 64-bit integers, 2⁻²⁴ km (6 cm) and
# 2⁻³² km/s per unit, where adding is exact. Float32 is used only for
# the arithmetic within a step -- the force, the Runge–Kutta combination
# -- on vectors that are small (a step's motion) or formed exactly from
# the wide state first (the Moon-relative position, which is where
# Float32's cancellation would otherwise do the most damage).
#
# `Acc` is that accumulator. Instantiated for Float64, on the CPU, it is
# a plain Float64 vector: the truth needs no such help, and the physics
# below is written once against `Acc` and never asks which it got.

comptime POS_BITS = 24
comptime VEL_BITS = 32


@fieldwise_init
struct Acc[dt: DType, bits: Int](ImplicitlyCopyable, Movable):
    """A wide accumulator vector: int64 fixed point with `bits` fraction
    bits when the narrow type is Float32, a Float64 vector otherwise."""

    comptime W = DType.int64 if Self.dt == DType.float32 else DType.float64
    comptime SCALE = Float64(1 << Self.bits) if Self.dt == DType.float32 else 1.0
    var v: SIMD[Self.W, 4]

    @staticmethod
    def of(x: SIMD[Self.dt, 4]) -> Self:
        """Widen a narrow vector, rounding to the nearest unit."""
        var y = x * Scalar[Self.dt](Self.SCALE)
        comptime if Self.dt == DType.float32:
            y = y + y.gt(SIMD[Self.dt, 4](0)).select(SIMD[Self.dt, 4](0.5), SIMD[Self.dt, 4](-0.5))
        return Self(y.cast[Self.W]())

    @staticmethod
    def of_fixed(x: SIMD[DType.int64, 4]) -> Self:
        """From the table's or the host's int64 units."""
        comptime if Self.dt == DType.float32:
            return Self(x.cast[Self.W]())
        else:
            return Self(x.cast[Self.W]() * Scalar[Self.W](1.0 / Float64(1 << Self.bits)))

    def narrow(self) -> SIMD[Self.dt, 4]:
        return self.v.cast[Self.dt]() * Scalar[Self.dt](1.0 / Self.SCALE)

    def add(self, delta: SIMD[Self.dt, 4]) -> Self:
        """self + delta, the add done wide."""
        return Self(self.v + Self.of(delta).v)

    def minus(self, other: Self) -> SIMD[Self.dt, 4]:
        """self − other, subtracted wide and exactly, then narrowed: the
        difference of two large positions to full narrow precision."""
        return (self.v - other.v).cast[Self.dt]() * Scalar[Self.dt](1.0 / Self.SCALE)


@fieldwise_init
struct RVd(ImplicitlyCopyable, Movable):
    """A Float64 state as two Vec3s -- the CPU's and Kepler's currency."""

    var r: Vec3
    var v: Vec3


@fieldwise_init
struct State[dt: DType](ImplicitlyCopyable, Movable):
    """Position (km) and velocity (km/s), wide."""

    var r: Acc[Self.dt, POS_BITS]
    var v: Acc[Self.dt, VEL_BITS]


@fieldwise_init
struct Sky[dt: DType](ImplicitlyCopyable, Movable):
    """The Moon and the Sun at one instant: positions wide (they are
    subtracted from the spacecraft's), the Moon's velocity narrow."""

    var moon: Acc[Self.dt, POS_BITS]
    var moon_v: SIMD[Self.dt, 4]
    var sun: Acc[Self.dt, POS_BITS]


@always_inline
def _norm2[dt: DType](a: SIMD[dt, 4]) -> Scalar[dt]:
    return (a * a).reduce_add()


@always_inline
def _load3[origin: Origin, //](tab: Pointer[Int64, origin], k: Int) -> SIMD[DType.int64, 4]:
    return SIMD[DType.int64, 4](tab[unsafe_offset=k], tab[unsafe_offset=k + 1], tab[unsafe_offset=k + 2], 0)


@always_inline
def bodies_at[dt: DType, origin: Origin, //](
    tab: Pointer[Int64, origin],
    n: Int,
    t: Scalar[dt],
) -> Sky[dt]:
    """The Moon and the Sun at t seconds from the table's start, by linear
    interpolation between the two samples around it; the Moon's velocity
    is the chord's slope. The table is int64 fixed point in POS_BITS for
    both targets, so the CPU and the GPU read the same numbers. Past
    either end the edge sample is held: a trajectory that runs off the
    table is a planning error, and it shows up as the Moon standing
    still."""
    var idx = t / Scalar[dt](TABLE_STEP)
    var i = Int(idx)
    if i < 0:
        i = 0
    if i > n - 2:
        i = n - 2
    var f = idx - Scalar[dt](i)
    if f < Scalar[dt](0):
        f = Scalar[dt](0)
    if f > Scalar[dt](1):
        f = Scalar[dt](1)
    var k = i * TABLE_STRIDE
    var m0 = Acc[dt, POS_BITS].of_fixed(_load3(tab, k))
    var s0 = Acc[dt, POS_BITS].of_fixed(_load3(tab, k + 3))
    var m1 = Acc[dt, POS_BITS].of_fixed(_load3(tab, k + 6))
    var s1 = Acc[dt, POS_BITS].of_fixed(_load3(tab, k + 9))
    var dm = m1.minus(m0)
    var ds = s1.minus(s0)
    return Sky[dt](m0.add(dm * f), dm * Scalar[dt](1.0 / TABLE_STEP), s0.add(ds * f))


@always_inline
def gravity[dt: DType](
    r_e: SIMD[dt, 4], r_m: SIMD[dt, 4], r_s: SIMD[dt, 4], flags: Int
) -> SIMD[dt, 4]:
    """Acceleration, km/s², in the Earth-centred frame, from the
    spacecraft's position relative to the Earth, to the Moon and to the
    Sun -- each formed by whoever calls, precisely."""
    var r2 = _norm2(r_e)
    var rn = sqrt(r2)
    var inv_r3 = Scalar[dt](1) / (r2 * rn)
    var a = r_e * (Scalar[dt](-MU_EARTH) * inv_r3)

    if flags & F_J2 != 0:
        # The bulge: (3/2) J2 μ R² / r⁵ · [x(5z²/r² − 1), y(5z²/r² − 1), z(5z²/r² − 3)]
        var k = Scalar[dt](1.5 * J2_EARTH * MU_EARTH * R_EARTH * R_EARTH) * inv_r3 / r2
        var zz = Scalar[dt](5) * r_e[2] * r_e[2] / r2
        var t = SIMD[dt, 4](zz - Scalar[dt](1), zz - Scalar[dt](1), zz - Scalar[dt](3), 0)
        a += r_e * t * k

    if flags & F_MOON != 0:
        # Direct pull on the spacecraft, minus the pull on the frame's origin.
        var moon = r_e - r_m
        var d2 = _norm2(r_m)
        var m2 = _norm2(moon)
        a += r_m * (Scalar[dt](-MU_MOON) / (d2 * sqrt(d2))) - moon * (Scalar[dt](MU_MOON) / (m2 * sqrt(m2)))

    if flags & F_SUN != 0:
        var sun = r_e - r_s
        var d2 = _norm2(r_s)
        var s2 = _norm2(sun)
        a += r_s * (Scalar[dt](-MU_SUN) / (d2 * sqrt(d2))) - sun * (Scalar[dt](MU_SUN) / (s2 * sqrt(s2)))

    return a


@always_inline
def _accel[dt: DType](
    s: State[dt], sky: Sky[dt], offset: SIMD[dt, 4], flags: Int
) -> SIMD[dt, 4]:
    """Gravity at the wide state displaced by a narrow offset (a Runge–Kutta
    stage): the relative vectors are formed wide first, then displaced."""
    var r_e = s.r.narrow() + offset
    var r_m = offset - sky.moon.minus(s.r)
    var r_s = offset - sky.sun.minus(s.r)
    return gravity(r_e, r_m, r_s, flags)


comptime STEP_ANGLE = 0.005
"""Radians of the dominant body's motion per step. The rule that sets the
step everywhere: 4 s at perigee and at perilune, 512 s in cruise, and the
same sequence on the CPU and the GPU because it is quantized to powers of
two rather than left to the last bit of a Float32."""


@always_inline
def step_size[dt: DType](
    s: State[dt], sky: Sky[dt], h_max: Scalar[dt]
) -> Scalar[dt]:
    """The largest power of two, in seconds, that keeps the spacecraft's
    angular motion about the Earth and about the Moon under STEP_ANGLE.
    The rate is the larger of the circular rate √(μ/r³) and the actual
    |v|/r: at the perigee of a transfer ellipse, and at the perilune of a
    flyby, the spacecraft moves half as fast again as a circular orbit
    there would, and those two places are where accuracy is bought."""
    var r = s.r.narrow()
    var v = s.v.narrow()
    var r2 = _norm2(r)
    var rn = sqrt(r2)
    var ne = sqrt(Scalar[dt](MU_EARTH) / (r2 * rn))
    var ve = sqrt(_norm2(v)) / rn
    if ve > ne:
        ne = ve
    var d = sky.moon.minus(s.r)
    var d2 = _norm2(d)
    var dn = sqrt(d2)
    var nm = sqrt(Scalar[dt](MU_MOON) / (d2 * dn))
    var vm = sqrt(_norm2(v - sky.moon_v)) / dn
    if vm > nm:
        nm = vm
    var n = ne if ne > nm else nm
    var h = Scalar[dt](STEP_ANGLE) / n
    var q = Scalar[dt](1)
    while q * Scalar[dt](2) <= h and q * Scalar[dt](2) <= h_max:
        q *= Scalar[dt](2)
    return q


@always_inline
def rk4_step[dt: DType, origin: Origin, //](
    s: State[dt],
    t: Scalar[dt],
    h: Scalar[dt],
    tab: Pointer[Int64, origin],
    n: Int,
    flags: Int,
) -> State[dt]:
    """One classical Runge–Kutta step of size h seconds from time t. The
    stages are narrow offsets from the wide state; only the final sums
    touch the accumulators, once each."""
    var b0 = bodies_at(tab, n, t)
    var bh = bodies_at(tab, n, t + h * Scalar[dt](0.5))
    var b1 = bodies_at(tab, n, t + h)
    var v0 = s.v.narrow()
    var zero = SIMD[dt, 4](0)

    var k1v = _accel(s, b0, zero, flags)
    var k1r = v0

    var k2v = _accel(s, bh, k1r * (h * Scalar[dt](0.5)), flags)
    var k2r = v0 + k1v * (h * Scalar[dt](0.5))

    var k3v = _accel(s, bh, k2r * (h * Scalar[dt](0.5)), flags)
    var k3r = v0 + k2v * (h * Scalar[dt](0.5))

    var k4v = _accel(s, b1, k3r * h, flags)
    var k4r = v0 + k3v * h

    var sixth = h / Scalar[dt](6)
    return State[dt](
        s.r.add((k1r + (k2r + k3r) * Scalar[dt](2) + k4r) * sixth),
        s.v.add((k1v + (k2v + k3v) * Scalar[dt](2) + k4v) * sixth),
    )


@always_inline
def propagate[dt: DType, origin: Origin, //](
    s: State[dt],
    t0: Scalar[dt],
    t1: Scalar[dt],
    h_max: Scalar[dt],
    tab: Pointer[Int64, origin],
    n: Int,
    flags: Int,
    mut steps: Int,
) -> State[dt]:
    """From t0 to t1, each step sized by `step_size` and capped at h_max,
    the last one shortened to land on t1 exactly -- burns happen at
    times, not at step boundaries. `steps` counts them."""
    var state = s
    var t = t0
    while t < t1:
        var sky = bodies_at(tab, n, t)
        var hh = step_size(state, sky, h_max)
        if t + hh > t1:
            hh = t1 - t
        state = rk4_step(state, t, hh, tab, n, flags)
        t += hh
        steps += 1
    return state


# ── the GPU side ─────────────────────────────────────────────────────────


def propagate_kernel(
    rx: Pointer[Int64, MutAnyOrigin],
    ry: Pointer[Int64, MutAnyOrigin],
    rz: Pointer[Int64, MutAnyOrigin],
    vx: Pointer[Int64, MutAnyOrigin],
    vy: Pointer[Int64, MutAnyOrigin],
    vz: Pointer[Int64, MutAnyOrigin],
    steps_out: Pointer[Int32, MutAnyOrigin],
    tab: Pointer[Int64, MutAnyOrigin],
    n_tab: Int32,
    t0: Float32,
    t1: Float32,
    h_max: Float32,
    flags: Int32,
    count: Int32,
):
    """One thread, one trajectory: the state in the six arrays at this
    thread's index -- int64 fixed point, POS_BITS and VEL_BITS -- is
    replaced by its state at t1. The same `propagate` the CPU runs, with
    Float32 for the arithmetic within a step."""
    var idx = Int(global_idx.x)
    if idx < Int(count):
        var s = State[DType.float32](
            Acc[DType.float32, POS_BITS](SIMD[DType.int64, 4](rx[unsafe_offset=idx], ry[unsafe_offset=idx], rz[unsafe_offset=idx], 0)),
            Acc[DType.float32, VEL_BITS](SIMD[DType.int64, 4](vx[unsafe_offset=idx], vy[unsafe_offset=idx], vz[unsafe_offset=idx], 0)),
        )
        var steps = 0
        var out = propagate(s, t0, t1, h_max, tab, Int(n_tab), Int(flags), steps)
        steps_out[unsafe_offset=idx] = Int32(steps)
        rx[unsafe_offset=idx] = out.r.v[0]
        ry[unsafe_offset=idx] = out.r.v[1]
        rz[unsafe_offset=idx] = out.r.v[2]
        vx[unsafe_offset=idx] = out.v.v[0]
        vy[unsafe_offset=idx] = out.v.v[1]
        vz[unsafe_offset=idx] = out.v.v[2]


# ── the CPU side ─────────────────────────────────────────────────────────


def v4(v: Vec3) -> SIMD[DType.float64, 4]:
    return SIMD[DType.float64, 4](v.x, v.y, v.z, 0.0)


def vec3(v: SIMD[DType.float64, 4]) -> Vec3:
    return Vec3(v[0], v[1], v[2])


def fixed(x: Float64, bits: Int) -> Int64:
    """A Float64 to int64 fixed point, rounded to the nearest unit."""
    return Int64(floor(x * Float64(1 << bits) + 0.5))


def unfixed(x: Int64, bits: Int) -> Float64:
    return Float64(x) / Float64(1 << bits)


def state64(r: Vec3, v: Vec3) -> State[DType.float64]:
    return State[DType.float64](
        Acc[DType.float64, POS_BITS].of(v4(r)), Acc[DType.float64, VEL_BITS].of(v4(v))
    )


struct Bodies(Movable):
    """The ephemeris table for one mission: Moon and Sun positions every
    60 s from `jde0`, int64 fixed point in POS_BITS, built once from the
    series in `astro.mojo` and read by the CPU and the GPU alike."""

    var jde0: Float64
    var n: Int
    var tab: List[Int64]

    def __init__(out self, eph: Ephemeris, jde0: Float64, days: Float64):
        self.jde0 = jde0
        self.n = Int(days * 86400.0 / TABLE_STEP) + 2
        self.tab = List[Int64](capacity=self.n * TABLE_STRIDE)
        for i in range(self.n):
            var jde = jde0 + Float64(i) * TABLE_STEP / 86400.0
            var m = eph.moon_position(jde)
            var s = eph.sun_position(jde)
            self.tab.append(fixed(m.x, POS_BITS))
            self.tab.append(fixed(m.y, POS_BITS))
            self.tab.append(fixed(m.z, POS_BITS))
            self.tab.append(fixed(s.x, POS_BITS))
            self.tab.append(fixed(s.y, POS_BITS))
            self.tab.append(fixed(s.z, POS_BITS))

    def moon_at(self, t: Float64) -> Vec3:
        return vec3(bodies_at(self.tab.unsafe_ptr(), self.n, t).moon.narrow())

    def sun_at(self, t: Float64) -> Vec3:
        return vec3(bodies_at(self.tab.unsafe_ptr(), self.n, t).sun.narrow())

    def run(self, r: Vec3, v: Vec3, t0: Float64, t1: Float64, h_max: Float64, flags: Int) -> RVd:
        """Propagate on the CPU, in Float64: the truth."""
        var steps = 0
        var out = propagate(state64(r, v), t0, t1, h_max, self.tab.unsafe_ptr(), self.n, flags, steps)
        return RVd(vec3(out.r.narrow()), vec3(out.v.narrow()))

    def run_recording(
        self,
        r: Vec3,
        v: Vec3,
        t0: Float64,
        t1: Float64,
        h_max: Float64,
        flags: Int,
        mut out: List[Float64],
    ) -> RVd:
        """The same, appending (t, x, y, z, vx, vy, vz) to `out` at every
        step -- the step rule already puts the samples where the arc
        bends, which is what the 3D plot wants and what closest approach
        is bracketed from."""
        var s = state64(r, v)
        var t = t0
        var tab = self.tab.unsafe_ptr()
        while True:
            var rr = s.r.narrow()
            var vv = s.v.narrow()
            out.append(t)
            out.append(rr[0])
            out.append(rr[1])
            out.append(rr[2])
            out.append(vv[0])
            out.append(vv[1])
            out.append(vv[2])
            if t >= t1:
                break
            var sky = bodies_at(tab, self.n, t)
            var hh = step_size(s, sky, h_max)
            if t + hh > t1:
                hh = t1 - t
            s = rk4_step(s, t, hh, tab, self.n, flags)
            t += hh
        return RVd(vec3(s.r.narrow()), vec3(s.v.narrow()))

    def closest_to_moon(self, samples: List[Float64]) -> Float64:
        """Minimum distance to the Moon over a recorded arc, km -- the
        sample nearest to perilune, which MC2 refines to the true minimum."""
        var best = 1.0e30
        var n = len(samples) // 7
        for i in range(n):
            var t = samples[i * 7]
            var r = Vec3(samples[i * 7 + 1], samples[i * 7 + 2], samples[i * 7 + 3])
            var d = (r - self.moon_at(t)).norm()
            if d < best:
                best = d
        return best


def hohmann_arc(eph: Ephemeris, jde_tli: Float64) -> RVd:
    """A transfer ellipse from 185 km whose apogee is placed where the
    Moon will be when the ellipse gets there, in the Moon's own orbital
    plane. Not targeted -- MC2 does that -- but it arrives in the Moon's
    neighbourhood, which is what a divergence measurement needs."""
    var rp = 185.0 + R_EARTH
    var t_arr = 0.0
    var aim = Vec3(1.0, 0.0, 0.0)
    var vp = 0.0
    for _ in range(4):
        var m = eph.moon_position(jde_tli + t_arr / 86400.0)
        var a = (rp + m.norm()) / 2.0
        t_arr = 3.141592653589793 * sqrt(a * a * a / MU_EARTH)
        vp = sqrt(MU_EARTH * (2.0 / rp - 1.0 / a))
        aim = m
    var mv = eph.moon_velocity(jde_tli + t_arr / 86400.0)
    var r0 = -(aim.unit()) * rp
    var normal = aim.cross(mv).unit()
    var vdir = normal.cross(r0.unit())
    return RVd(r0, vdir * vp)


# ── Kepler ───────────────────────────────────────────────────────────────


def stumpff_s(z: Float64) -> Float64:
    if z > 1e-3:
        var sz = sqrt(z)
        return (sz - sin(sz)) / (z * sz)
    if z < -1e-3:
        var sz = sqrt(-z)
        return (sinh(sz) - sz) / (-z * sz)
    return 1.0 / 6.0 - z / 120.0 + z * z / 5040.0 - z * z * z / 362880.0


def stumpff_c(z: Float64) -> Float64:
    if z > 1e-3:
        return (1.0 - cos(sqrt(z))) / z
    if z < -1e-3:
        return (cosh(sqrt(-z)) - 1.0) / (-z)
    return 0.5 - z / 24.0 + z * z / 720.0 - z * z * z / 40320.0


def kepler(r0: Vec3, v0: Vec3, dt: Float64, mu: Float64) -> RVd:
    """The two-body problem solved exactly: the state dt seconds later,
    by the universal variable χ (Bate, Mueller & White; Curtis 3.3–3.4),
    valid for ellipse, parabola and hyperbola alike. The integrator's
    oracle."""
    var rn = r0.norm()
    var vr0 = r0.dot(v0) / rn
    var alpha = 2.0 / rn - v0.dot(v0) / mu
    var smu = sqrt(mu)
    var chi = smu * (alpha if alpha > 0.0 else -alpha) * dt
    for _ in range(60):
        var z = alpha * chi * chi
        var c = stumpff_c(z)
        var s = stumpff_s(z)
        var f = (
            rn * vr0 / smu * chi * chi * c
            + (1.0 - alpha * rn) * chi * chi * chi * s
            + rn * chi
            - smu * dt
        )
        var fp = (
            rn * vr0 / smu * chi * (1.0 - z * s)
            + (1.0 - alpha * rn) * chi * chi * c
            + rn
        )
        var d = f / fp
        chi -= d
        if (d if d > 0.0 else -d) < 1e-12 * (chi if chi > 0.0 else -chi) + 1e-14:
            break
    var z = alpha * chi * chi
    var c = stumpff_c(z)
    var s = stumpff_s(z)
    var f = 1.0 - chi * chi / rn * c
    var g = dt - chi * chi * chi / smu * s
    var r = r0 * f + v0 * g
    var rr = r.norm()
    var fdot = smu / (rr * rn) * (alpha * chi * chi * chi * s - chi)
    var gdot = 1.0 - chi * chi / rr * c
    return RVd(r, r0 * fdot + v0 * gdot)


def specific_energy(r: Vec3, v: Vec3, mu: Float64) -> Float64:
    return v.dot(v) / 2.0 - mu / r.norm()


@fieldwise_init
struct Elements(ImplicitlyCopyable, Movable):
    """Classical orbital elements: a (km; negative for a hyperbola), e,
    and i, Ω, ω, ν in degrees. What the TRACK screen shows beside the
    state vector."""

    var a: Float64
    var e: Float64
    var i: Float64
    var node: Float64
    var argp: Float64
    var nu: Float64


def elements(r: Vec3, v: Vec3, mu: Float64) -> Elements:
    var h = r.cross(v)
    var hn = h.norm()
    var rn = r.norm()
    var n = Vec3(-h.y, h.x, 0.0)
    var nn = n.norm()
    var ev = (r * (v.dot(v) - mu / rn) - v * r.dot(v)) * (1.0 / mu)
    var e = ev.norm()
    var energy = specific_energy(r, v, mu)
    var a = -mu / (2.0 * energy)
    var i = acos(h.z / hn) * RAD
    var node = 0.0
    var argp = 0.0
    if nn > 1e-12:
        node = atan2(n.y, n.x) * RAD
        if node < 0.0:
            node += 360.0
        if e > 1e-12:
            var c = n.dot(ev) / (nn * e)
            c = 1.0 if c > 1.0 else (-1.0 if c < -1.0 else c)
            argp = acos(c) * RAD
            if ev.z < 0.0:
                argp = 360.0 - argp
    var nu = 0.0
    if e > 1e-12:
        var c = ev.dot(r) / (e * rn)
        c = 1.0 if c > 1.0 else (-1.0 if c < -1.0 else c)
        nu = acos(c) * RAD
        if r.dot(v) < 0.0:
            nu = 360.0 - nu
    return Elements(a, e, i, node, argp, nu)
