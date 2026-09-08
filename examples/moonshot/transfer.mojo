# ===----------------------------------------------------------------------=== #
# Moonshot — transfer design (sprint MC2).
#
# Getting from a parking orbit to a chosen point beside the Moon at a
# chosen time is three computations, and this file is them:
#
#   Lambert   two positions and a time of flight -> the two-body orbit
#             that connects them (universal variables, so one solver
#             serves ellipse and hyperbola). The first guess.
#   arrival   an integrated arc -> its perilune: the Moon-relative state
#             at closest approach, refined to the true minimum, and the
#             B-plane -- the flight-dynamics description of "where beside
#             the Moon, and how fast" that the whole approach reduces to.
#   correct   differential correction: perturb each component of the
#             injection velocity, see where the perilune goes, solve the
#             3×3 for the velocity that puts it where it is wanted, and
#             repeat until it stays. This is targeting, as the trench did
#             it, with the real n-body integrator from `orbit.mojo` in
#             the loop.
#
# The B-plane. Far from the Moon the approach is a straight line with
# velocity v∞ along Ŝ. The plane through the Moon's centre perpendicular
# to Ŝ is the B-plane, and B⃗ is where the line pierces it: |B| is the
# impact parameter, and its direction in the plane (B·T̂ along T̂ = Ŝ × N̂,
# B·R̂ along R̂ = Ŝ × T̂, with N̂ the Moon's orbit pole) sets the plane of the
# lunar orbit the flyby becomes. Perilune radius follows from |B| and v∞
# alone: r_p = a(e − 1) with a = μ/v∞², e = √(1 + (|B| v∞²/μ)²). Target
# B⃗ and you have targeted the orbit.
# ===----------------------------------------------------------------------=== #

from std.math import sqrt, sin, cos, acos, atan2, asin, floor
from astro import Vec3, Ephemeris, MU_EARTH, MU_MOON, R_EARTH, R_MOON, DEG, RAD, site_position
from orbit import (
    Bodies, RVd, kepler, stumpff_c, stumpff_s, specific_energy, elements,
    state64, propagate, F_ALL, POS_BITS, VEL_BITS,
)

comptime PI = 3.141592653589793


# ── Lambert ──────────────────────────────────────────────────────────────


@fieldwise_init
struct Lambert(ImplicitlyCopyable, Movable):
    var v1: Vec3
    var v2: Vec3
    var ok: Bool


def _lambert_y(z: Float64, r1n: Float64, r2n: Float64, a: Float64) -> Float64:
    return r1n + r2n + a * (z * stumpff_s(z) - 1.0) / sqrt(stumpff_c(z))


def _lambert_f(z: Float64, r1n: Float64, r2n: Float64, a: Float64, smu_dt: Float64) -> Float64:
    var y = _lambert_y(z, r1n, r2n, a)
    if y < 0.0:
        return -1.0e30
    var c = stumpff_c(z)
    var yc = y / c
    return yc * sqrt(yc) * stumpff_s(z) + a * sqrt(y) - smu_dt


def lambert(r1: Vec3, r2: Vec3, dt: Float64, mu: Float64, normal: Vec3) -> Lambert:
    """The orbit from r1 to r2 in dt seconds, prograde about `normal`
    (Curtis, Algorithm 5.2: bisection on the universal variable z, which
    is monotonic in the time of flight). Fails, with ok = False, only
    when the two positions are within 0.01° of opposite, where the
    transfer plane is undefined."""
    var r1n = r1.norm()
    var r2n = r2.norm()
    var cosd = r1.dot(r2) / (r1n * r2n)
    cosd = 1.0 if cosd > 1.0 else (-1.0 if cosd < -1.0 else cosd)
    var dtheta = acos(cosd)
    if r1.cross(r2).dot(normal) < 0.0:
        dtheta = 2.0 * PI - dtheta
    var bad = Vec3(0.0, 0.0, 0.0)
    if 1.0 - cosd < 1.5e-8 or (PI - dtheta < 0.01 * DEG and dtheta - PI < 0.01 * DEG):
        return Lambert(bad, bad, False)
    var a = sin(dtheta) * sqrt(r1n * r2n / (1.0 - cosd))
    var smu_dt = sqrt(mu) * dt

    # Bracket the root: F is increasing in z. Walk out from zero until the
    # sign changes, doubling, then bisect.
    var z_lo = 0.0
    var z_hi = 0.0
    var f0 = _lambert_f(0.0, r1n, r2n, a, smu_dt)
    if f0 > 0.0:
        z_hi = 0.0
        z_lo = -1.0
        for _ in range(60):
            if _lambert_f(z_lo, r1n, r2n, a, smu_dt) < 0.0:
                break
            z_hi = z_lo
            z_lo *= 2.0
    else:
        z_lo = 0.0
        z_hi = 1.0
        var top = 4.0 * PI * PI * (1.0 - 1e-9)
        for _ in range(60):
            if _lambert_f(z_hi, r1n, r2n, a, smu_dt) > 0.0:
                break
            z_lo = z_hi
            z_hi = z_hi * 2.0 if z_hi * 2.0 < top else top
    var z = 0.5 * (z_lo + z_hi)
    for _ in range(200):
        z = 0.5 * (z_lo + z_hi)
        if _lambert_f(z, r1n, r2n, a, smu_dt) > 0.0:
            z_hi = z
        else:
            z_lo = z
        if z_hi - z_lo < 1e-13:
            break
    var y = _lambert_y(z, r1n, r2n, a)
    var f = 1.0 - y / r1n
    var g = a * sqrt(y / mu)
    var gdot = 1.0 - y / r2n
    var v1 = (r2 - r1 * f) * (1.0 / g)
    var v2 = (r2 * gdot - r1) * (1.0 / g)
    return Lambert(v1, v2, True)


# ── arrival: perilune and the B-plane ────────────────────────────────────


@fieldwise_init
struct Arrival(ImplicitlyCopyable, Movable):
    """What an approach reduces to, at perilune."""

    var t_p: Float64  # seconds from the arc's epoch
    var rho: Vec3  # Moon-relative position at perilune, km
    var rho_dot: Vec3  # Moon-relative velocity, km/s
    var r_p: Float64  # perilune radius, km
    var v_inf: Float64  # hyperbolic excess speed, km/s
    var s_hat: Vec3  # incoming asymptote direction
    var b: Vec3  # the B vector
    var bt: Float64  # B · T̂
    var br: Float64  # B · R̂
    var far_side: Bool  # is perilune on the side of the Moon away from Earth?
    var inc: Float64  # inclination of the flyby plane to the Moon's orbit plane, deg
    var t_hat: Vec3
    var r_hat: Vec3


def b_plane(rho: Vec3, rho_dot: Vec3, moon_pole: Vec3) -> Arrival:
    """The B-plane of a Moon-relative hyperbolic state (any point on it;
    perilune is used). T̂ = Ŝ × N̂ with N̂ the Moon's orbit pole, R̂ = Ŝ × T̂."""
    var rn = rho.norm()
    var v2 = rho_dot.dot(rho_dot)
    var vinf2 = v2 - 2.0 * MU_MOON / rn
    var v_inf = sqrt(vinf2) if vinf2 > 0.0 else 0.0
    var h = rho.cross(rho_dot)
    var hn = h.norm()
    # Eccentricity vector, and the asymptote from it: Ŝ = (p̂ + √(e²−1) q̂)/e
    var ev = (rho * (v2 - MU_MOON / rn) - rho_dot * rho.dot(rho_dot)) * (1.0 / MU_MOON)
    var e = ev.norm()
    var p_hat = ev.unit()
    var q_hat = h.unit().cross(p_hat)
    var s_hat = rho_dot.unit()
    if e > 1.0:
        s_hat = p_hat * (1.0 / e) + q_hat * (sqrt(e * e - 1.0) / e)
    var b = Vec3(0.0, 0.0, 0.0)
    if v_inf > 0.0:
        b = s_hat.cross(h) * (1.0 / v_inf)
    var t_hat = s_hat.cross(moon_pole).unit()
    var r_hat = s_hat.cross(t_hat)
    var inc = acos(h.dot(moon_pole) / hn) * RAD
    return Arrival(
        0.0, rho, rho_dot, rn, v_inf, s_hat, b, b.dot(t_hat), b.dot(r_hat), False, inc, t_hat, r_hat
    )


def perilune_from_b(b_mag: Float64, v_inf: Float64) -> Float64:
    """r_p = a(e − 1), a = μ/v∞², e = √(1 + (b v∞²/μ)²)."""
    var a = MU_MOON / (v_inf * v_inf)
    var e = sqrt(1.0 + (b_mag / a) * (b_mag / a))
    return a * (e - 1.0)


def b_from_perilune(r_p: Float64, v_inf: Float64) -> Float64:
    """The inverse: |B| = r_p √(1 + 2μ/(r_p v∞²))."""
    return r_p * sqrt(1.0 + 2.0 * MU_MOON / (r_p * v_inf * v_inf))


def arrival(bodies: Bodies, eph: Ephemeris, r0: Vec3, v0: Vec3, t_start: Float64, t_end: Float64) -> Arrival:
    """Fly the arc from t_start (the table's seconds) and find its closest approach to the Moon:
    the nearest recorded step, a parabola through it and its neighbours
    for the time, a short re-propagation to that time, then one Newton
    step on ρ⃗·ρ̇ = 0 so the result is the true perilune, not the nearest
    sample."""
    var samples = List[Float64]()
    _ = bodies.run_recording(r0, v0, t_start, t_end, 1024.0, F_ALL, samples)
    var n = len(samples) // 7
    var best = 0
    var best_d = 1.0e30
    for i in range(n):
        var r = Vec3(samples[i * 7 + 1], samples[i * 7 + 2], samples[i * 7 + 3])
        var d = (r - bodies.moon_at(samples[i * 7])).norm()
        if d < best_d:
            best_d = d
            best = i
    var t_min = samples[best * 7]
    var i0 = best
    if best > 0 and best < n - 1:
        # Parabola through the three points around the minimum.
        var t0 = samples[(best - 1) * 7]
        var t1 = samples[best * 7]
        var t2 = samples[(best + 1) * 7]
        var d0 = (Vec3(samples[(best - 1) * 7 + 1], samples[(best - 1) * 7 + 2], samples[(best - 1) * 7 + 3]) - bodies.moon_at(t0)).norm()
        var d2 = (Vec3(samples[(best + 1) * 7 + 1], samples[(best + 1) * 7 + 2], samples[(best + 1) * 7 + 3]) - bodies.moon_at(t2)).norm()
        var denom = (t1 - t0) * (d2 - best_d) - (t1 - t2) * (d0 - best_d)
        if denom != 0.0:
            var num = (t1 - t0) * (t1 - t0) * (d2 - best_d) - (t1 - t2) * (t1 - t2) * (d0 - best_d)
            var tv = t1 - 0.5 * num / denom
            if tv > t0 and tv < t2:
                t_min = tv
        i0 = best - 1
    # Re-propagate from the sample before it, in 1 s steps, to t_min.
    var rs = Vec3(samples[i0 * 7 + 1], samples[i0 * 7 + 2], samples[i0 * 7 + 3])
    var vs = Vec3(samples[i0 * 7 + 4], samples[i0 * 7 + 5], samples[i0 * 7 + 6])
    var ts = samples[i0 * 7]
    var st = bodies.run(rs, vs, ts, t_min, 1.0, F_ALL)
    # One Newton step on ρ·ρ̇ = 0.
    var rho = st.r - bodies.moon_at(t_min)
    var rho_dot = st.v - eph.moon_velocity(bodies.jde0 + t_min / 86400.0)
    var rho_ddot = rho * (-MU_MOON / (rho.norm() ** 3))
    var dtn = -rho.dot(rho_dot) / (rho_dot.dot(rho_dot) + rho.dot(rho_ddot))
    if dtn > -60.0 and dtn < 60.0 and dtn != 0.0:
        var t2 = t_min + dtn
        if dtn > 0.0:
            st = bodies.run(st.r, st.v, t_min, t2, 1.0, F_ALL)
        else:
            st = bodies.run(rs, vs, ts, t2, 1.0, F_ALL)
        t_min = t2
        rho = st.r - bodies.moon_at(t_min)
        rho_dot = st.v - eph.moon_velocity(bodies.jde0 + t_min / 86400.0)
    var moon = bodies.moon_at(t_min)
    var pole = moon.cross(eph.moon_velocity(bodies.jde0 + t_min / 86400.0)).unit()
    var a = b_plane(rho, rho_dot, pole)
    # Far side: the perilune point lies on the hemisphere facing away from
    # the Earth, ρ̂ · m̂ > 0 with m̂ the Moon's direction from the Earth.
    var far = rho.unit().dot(moon.unit()) > 0.0
    return Arrival(t_min, a.rho, a.rho_dot, a.r_p, a.v_inf, a.s_hat, a.b, a.bt, a.br, far, a.inc, a.t_hat, a.r_hat)


# ── the corrector ────────────────────────────────────────────────────────


def solve3(j: List[Float64], b: List[Float64]) -> List[Float64]:
    """Gaussian elimination with partial pivoting on a 3×3 (row-major)."""
    var m = List[Float64]()
    for i in range(3):
        for k in range(3):
            m.append(j[i * 3 + k])
        m.append(b[i])
    for col in range(3):
        var piv = col
        for r in range(col + 1, 3):
            if abs(m[r * 4 + col]) > abs(m[piv * 4 + col]):
                piv = r
        if piv != col:
            for k in range(4):
                var tmp = m[col * 4 + k]
                m[col * 4 + k] = m[piv * 4 + k]
                m[piv * 4 + k] = tmp
        var d = m[col * 4 + col]
        if d == 0.0:
            d = 1e-300
        for r in range(3):
            if r != col:
                var f = m[r * 4 + col] / d
                for k in range(4):
                    m[r * 4 + k] -= f * m[col * 4 + k]
    var x = List[Float64]()
    for i in range(3):
        x.append(m[i * 4 + 3] / m[i * 4 + i])
    return x^


@fieldwise_init
struct Target(ImplicitlyCopyable, Movable):
    """Perilune radius (km), perilune time (s from injection), and the
    orbit normal wanted at the Moon -- signed: the Moon's spin axis for
    a prograde equatorial orbit, its negative for retrograde, which is
    also the far-side approach Apollo flew. Only the part of the pole
    perpendicular to the approach asymptote can be had; the rest is the
    inclination the geometry leaves."""

    var r_p: Float64
    var t_p: Float64
    var pole: Vec3


def b_for_pole(a: Arrival, pole: Vec3, bmag: Float64) -> Vec3:
    """The B vector of magnitude bmag whose flyby plane has the normal
    nearest `pole`: h ∝ B × Ŝ, so B̂ = Ŝ × ĥ with ĥ the pole's component
    perpendicular to Ŝ."""
    var hp = pole - a.s_hat * pole.dot(a.s_hat)
    return a.s_hat.cross(hp).unit() * bmag


@fieldwise_init
struct Correction(ImplicitlyCopyable, Movable):
    var v: Vec3  # the corrected injection velocity
    var arrival: Arrival
    var iterations: Int
    var converged: Bool


def correct(
    bodies: Bodies,
    eph: Ephemeris,
    r0: Vec3,
    v_guess: Vec3,
    target: Target,
    t_start: Float64,
    t_end: Float64,
) -> Correction:
    """Differential correction of the velocity at a fixed point and time
    (t_start, the table's seconds), to hit (B·T̂, B·R̂, t_p). The target B is
    recomputed each round from the current v∞ (for its size) and the
    current asymptote (for its direction), so what is really held is the
    perilune radius and the orbit plane. Converges in a few rounds; each
    costs four flights of the arc."""
    var v = v_guess
    var a = arrival(bodies, eph, r0, v, t_start, t_end)
    var it = 0
    var ok = False
    for round in range(12):
        it = round + 1
        var want = b_for_pole(a, target.pole, b_from_perilune(target.r_p, a.v_inf))
        var res = List[Float64]()
        res.append(a.bt - want.dot(a.t_hat))
        res.append(a.br - want.dot(a.r_hat))
        res.append(a.t_p - target.t_p)
        if abs(res[0]) < 0.01 and abs(res[1]) < 0.01 and abs(res[2]) < 0.5:
            ok = True
            break
        var j = List[Float64]()
        for _ in range(9):
            j.append(0.0)
        var delta = 1e-4  # 0.1 m/s
        for k in range(3):
            var dv = Vec3(delta if k == 0 else 0.0, delta if k == 1 else 0.0, delta if k == 2 else 0.0)
            var ak = arrival(bodies, eph, r0, v + dv, t_start, t_end)
            j[0 * 3 + k] = (ak.bt - a.bt) / delta
            j[1 * 3 + k] = (ak.br - a.br) / delta
            j[2 * 3 + k] = (ak.t_p - a.t_p) / delta
        var neg = List[Float64]()
        neg.append(-res[0])
        neg.append(-res[1])
        neg.append(-res[2])
        var step = solve3(j, neg)
        v = v + Vec3(step[0], step[1], step[2])
        a = arrival(bodies, eph, r0, v, t_start, t_end)
    return Correction(v, a, it, ok)


def correct_in_plane(
    bodies: Bodies,
    eph: Ephemeris,
    r0: Vec3,
    v_park: Vec3,
    v_guess: Vec3,
    r_p: Float64,
    far_side: Bool,
    t_p: Float64,
    t_start: Float64,
    t_end: Float64,
) -> Correction:
    """The realistic TLI: the plane is the parking orbit's, set by the
    launch, and the burn is in it. Two unknowns -- the tangential and
    radial components of the injection velocity -- for two targets, the
    perilune radius (through B·T̂, signed for the far or the near side,
    with B·R̂ left to be whatever the plane makes it) and the perilune
    time. A 2×2 finite-difference Newton; three flights of the arc a
    round."""
    var t_hat = v_park.unit()
    var r_hat = r0.unit()
    var v = v_guess
    var a = arrival(bodies, eph, r0, v, t_start, t_end)
    var it = 0
    var ok = False
    for round in range(12):
        it = round + 1
        var bmag = b_from_perilune(r_p, a.v_inf)
        var bt2 = bmag * bmag - a.br * a.br
        var want_bt = sqrt(bt2) if bt2 > 0.0 else 0.0
        if far_side:
            want_bt = -want_bt
        var res0 = a.bt - want_bt
        var res1 = a.t_p - t_p
        if abs(res0) < 0.01 and abs(res1) < 0.5:
            ok = True
            break
        var delta = 1e-4
        var a_t = arrival(bodies, eph, r0, v + t_hat * delta, t_start, t_end)
        var a_r = arrival(bodies, eph, r0, v + r_hat * delta, t_start, t_end)
        # Rows: bt, t_p; columns: tangential, radial.
        var j00 = (a_t.bt - a.bt) / delta
        var j01 = (a_r.bt - a.bt) / delta
        var j10 = (a_t.t_p - a.t_p) / delta
        var j11 = (a_r.t_p - a.t_p) / delta
        var det = j00 * j11 - j01 * j10
        if det == 0.0:
            break
        var du = (-res0 * j11 + res1 * j01) / det
        var dw = (-res1 * j00 + res0 * j10) / det
        v = v + t_hat * du + r_hat * dw
        a = arrival(bodies, eph, r0, v, t_start, t_end)
    return Correction(v, a, it, ok)


# ── the parking orbit and the injection point ────────────────────────────


def planes_through(inc_deg: Float64, m_hat: Vec3) -> List[Vec3]:
    """The normals of the (up to two) planes of inclination `inc` that
    contain the direction m̂: n = (n_x, n_y, cos i) with n · m̂ = 0. None
    when |declination of m̂| > i -- the site cannot reach that plane."""
    var out = List[Vec3]()
    var ci = cos(inc_deg * DEG)
    var si = sin(inc_deg * DEG)
    var rho = sqrt(m_hat.x * m_hat.x + m_hat.y * m_hat.y)
    if rho < 1e-12:
        return out^
    var along = -ci * m_hat.z / rho
    var perp2 = si * si - along * along
    if perp2 < 0.0:
        return out^
    var perp = sqrt(perp2)
    var ux = m_hat.x / rho
    var uy = m_hat.y / rho
    out.append(Vec3(along * ux - perp * uy, along * uy + perp * ux, ci))
    out.append(Vec3(along * ux + perp * uy, along * uy - perp * ux, ci))
    return out^


@fieldwise_init
struct Injection(ImplicitlyCopyable, Movable):
    var r: Vec3  # the injection point on the parking orbit
    var v_park: Vec3  # circular velocity there
    var v_tli: Vec3  # Lambert's first guess for the injection velocity
    var dv: Float64  # |v_tli − v_park|, km/s
    var true_lon: Float64  # where on the orbit, degrees from the node


def best_injection(normal: Vec3, alt_km: Float64, aim: Vec3, tof: Float64) -> Injection:
    """Walk the parking orbit in half-degree steps and Lambert each point
    to `aim` in `tof` seconds; keep the cheapest. The cheapest is where
    the burn is tangential -- the transfer's perigee sits on the parking
    orbit -- which is what a TLI opportunity is."""
    var r = R_EARTH + alt_km
    var vc = sqrt(MU_EARTH / r)
    var n = normal.unit()
    # The node line: where the plane meets the equator.
    var node = Vec3(-n.y, n.x, 0.0).unit()
    var perp = n.cross(node)
    var best = Injection(Vec3(0.0, 0.0, 0.0), Vec3(0.0, 0.0, 0.0), Vec3(0.0, 0.0, 0.0), 1.0e30, 0.0)
    for k in range(720):
        var u = Float64(k) * 0.5
        var rhat = node * cos(u * DEG) + perp * sin(u * DEG)
        var pos = rhat * r
        var vpark = n.cross(rhat) * vc
        var lam = lambert(pos, aim, tof, MU_EARTH, n)
        if not lam.ok:
            continue
        var dv = (lam.v1 - vpark).norm()
        if dv < best.dv:
            best = Injection(pos, vpark, lam.v1, dv, u)
    return best


# ── the whole transfer, planned ──────────────────────────────────────────


@fieldwise_init
struct Transfer(ImplicitlyCopyable, Movable):
    var injection: Injection
    var correction: Correction
    var dv_tli: Float64  # km/s, impulsive, corrected
    var plane_change: Float64  # deg, the out-of-plane part of the burn
    var loi_dv: Float64  # km/s, into an orbit with the target perilune and `loi_apo_alt`


def loi_delta_v(v_inf: Float64, r_p: Float64, apo_alt: Float64) -> Float64:
    """From the hyperbola at perilune into an ellipse with that perilune
    and the given apolune altitude: √(v∞² + 2μ/r_p) − √(μ(2/r_p − 1/a))."""
    var ra = R_MOON + apo_alt
    var a = (r_p + ra) / 2.0
    var v_hyp = sqrt(v_inf * v_inf + 2.0 * MU_MOON / r_p)
    var v_ell = sqrt(MU_MOON * (2.0 / r_p - 1.0 / a))
    return v_hyp - v_ell


def _finish(normal: Vec3, inj: Injection, corr: Correction, loi_apo_alt: Float64) -> Transfer:
    var dv_vec = corr.v - inj.v_park
    var dv = dv_vec.norm()
    var n = normal.unit()
    var out_of_plane = asin(dv_vec.dot(n) / dv) * RAD if dv > 0.0 else 0.0
    var loi = loi_delta_v(corr.arrival.v_inf, corr.arrival.r_p, loi_apo_alt)
    return Transfer(inj, corr, dv, out_of_plane, loi)


def plan_transfer(
    eph: Ephemeris,
    bodies: Bodies,
    normal: Vec3,
    alt_km: Float64,
    tof: Float64,
    r_p: Float64,
    far_side: Bool,
    loi_apo_alt: Float64,
) -> Transfer:
    """Lambert to the Moon's centre at arrival for the injection point,
    then correct, in the parking orbit's plane, to the perilune radius
    (on the far or the near side) at the arrival time: the transfer the
    launch geometry gives for free. `bodies` is epoch-ed at injection."""
    var aim = bodies.moon_at(tof)
    var inj = best_injection(normal, alt_km, aim, tof)
    var corr = correct_in_plane(bodies, eph, inj.r, inj.v_park, inj.v_tli, r_p, far_side, tof, 0.0, tof + 6.0 * 3600.0)
    return _finish(normal, inj, corr, loi_apo_alt)


def plan_transfer_oriented(
    eph: Ephemeris,
    bodies: Bodies,
    normal: Vec3,
    alt_km: Float64,
    tof: Float64,
    r_p: Float64,
    pole: Vec3,
    loi_apo_alt: Float64,
) -> Transfer:
    """The same, then steered: from the in-plane solution, the full
    three-component correction to the perilune radius, the arrival time
    and the lunar orbit plane nearest `pole`. The out-of-plane part of
    the burn adds in quadrature to three kilometres a second, which is
    why the trench could target the lunar orbit's inclination at TLI for
    a few metres a second, and did."""
    var base = plan_transfer(eph, bodies, normal, alt_km, tof, r_p, pole.dot(bodies.moon_at(tof).cross(eph.moon_velocity(bodies.jde0 + tof / 86400.0))) < 0.0, loi_apo_alt)
    var corr = correct(bodies, eph, base.injection.r, base.correction.v, Target(r_p, tof, pole), 0.0, tof + 6.0 * 3600.0)
    return _finish(normal, base.injection, corr, loi_apo_alt)


def plan_transfer_to_site(
    eph: Ephemeris,
    bodies: Bodies,
    normal: Vec3,
    alt_km: Float64,
    tof: Float64,
    r_p: Float64,
    site_dir: Vec3,
    retro_hint: Vec3,
    loi_apo_alt: Float64,
) -> Transfer:
    """The approach that lands: the flyby plane must hold the approach
    asymptote and the landing site's direction at the landing time, so
    its normal is Ŝ × ŝ_site, signed toward `retro_hint` (the Moon's spin
    axis negated, for the retrograde orbits Apollo flew). What is left
    free is nothing; the inclination follows."""
    var base = plan_transfer(eph, bodies, normal, alt_km, tof, r_p, True, loi_apo_alt)
    var pole = base.correction.arrival.s_hat.cross(site_dir).unit()
    if pole.dot(retro_hint) < 0.0:
        pole = -pole
    var corr = correct(bodies, eph, base.injection.r, base.correction.v, Target(r_p, tof, pole), 0.0, tof + 6.0 * 3600.0)
    return _finish(normal, base.injection, corr, loi_apo_alt)
