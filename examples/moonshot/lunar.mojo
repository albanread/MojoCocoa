# ===----------------------------------------------------------------------=== #
# Moonshot — the lunar phase (sprint MC7).
#
# Three computations the trench makes once the Moon is close:
#
#   the LOI solution   a finite burn -- ignition second and Δv, attitude
#                      held fixed at the midpoint's retrograde -- that
#                      turns the approach hyperbola into the orbit the
#                      plan intended, found by a 2×2 Newton on the burn
#                      simulated from the tracked state (C15).
#   the site pass      when, if ever, the orbit's ground track crosses
#                      the landing site's longitude, and how far the site
#                      then lies from the plane: the cross-range the LM
#                      would have to fly out (C16). The Moon turns under
#                      the plane thirteen degrees a day, so this is a
#                      question about a time, not just an orbit.
#   the descent orbit  DOI half a descent-orbit before a PDI point set a
#                      braking-phase's travel short of the site (C18).
#
# `finite_burn` is the burn model the mission flies with, so a solution
# found here is a solution the crew get.
# ===----------------------------------------------------------------------=== #

from std.math import sqrt, asin, acos, atan2, sin, cos
from astro import *
from orbit import *
from transfer import *

comptime BRAKING_SECONDS = 12.0 * 60.0 + 35.0
"""PDI to touchdown, Apollo 11's; the guidance makes its own."""
comptime BRAKING_RANGE = 480.0
"""km uprange of the site at PDI: the braking phase's ground distance."""
comptime OMEGA_MOON = 2.6617e-6
"""The Moon's rotation, rad/s."""


@fieldwise_init
struct BurnResult(ImplicitlyCopyable, Movable):
    var r: Vec3
    var v: Vec3
    var t_end: Float64  # table seconds at cutoff


def finite_burn(bodies: Bodies, r0: Vec3, v0: Vec3, t_ign: Float64, seconds: Float64, dv: Float64) -> BurnResult:
    """The burn as flown: Δv in pieces no more than ten seconds apart,
    each along one inertial direction -- the retrograde of the burn's
    midpoint, found by coasting there first -- with the integrator
    between pieces. From the state at t_ign (table seconds)."""
    var n = Int(seconds / 10.0) + 1
    var piece = dv / Float64(n)
    var slice = seconds / Float64(n)
    var t_mid = t_ign + 0.5 * seconds
    var mid = bodies.run(r0, v0, t_ign, t_mid, 1024.0, F_ALL)
    var v_moon_mid = (bodies.moon_at(t_mid + 30.0) - bodies.moon_at(t_mid - 30.0)) * (1.0 / 60.0)
    var dir = -(mid.v - v_moon_mid).unit()
    var r = r0
    var v = v0
    var t = t_ign
    for _ in range(n):
        if slice > 0.0:
            var a = bodies.run(r, v, t, t + 0.5 * slice, 1024.0, F_ALL)
            r = a.r
            v = a.v
            t += 0.5 * slice
        v = v + dir * piece
        if slice > 0.0:
            var b = bodies.run(r, v, t, t + 0.5 * slice, 1024.0, F_ALL)
            r = b.r
            v = b.v
            t += 0.5 * slice
    return BurnResult(r, v, t)


def moon_orbit(bodies: Bodies, r: Vec3, v: Vec3, t: Float64) -> Elements:
    """The osculating orbit about the Moon at table time t."""
    var mv = (bodies.moon_at(t + 30.0) - bodies.moon_at(t - 30.0)) * (1.0 / 60.0)
    return elements(r - bodies.moon_at(t), v - mv, MU_MOON)


@fieldwise_init
struct LoiSolution(ImplicitlyCopyable, Movable):
    var t_ign: Float64  # table seconds
    var dv: Float64  # km/s
    var peri_alt: Float64  # what the burn makes, km
    var apo_alt: Float64
    var converged: Bool


def target_loi(
    bodies: Bodies,
    r_now: Vec3,
    v_now: Vec3,
    t_now: Float64,
    t_ign0: Float64,
    dv0: Float64,
    seconds: Float64,
    peri_alt: Float64,
    apo_alt: Float64,
) -> LoiSolution:
    """Ignition time and Δv of the finite LOI-1 that makes an orbit of the
    wanted perilune and apolune altitudes, from the state tracking
    reports now: two unknowns, two targets, Newton by finite differences
    with the burn itself as the model."""
    var t_ign = t_ign0
    var dv = dv0
    var peri = 0.0
    var apo = 0.0
    var ok = False
    for _ in range(8):
        var coast = bodies.run(r_now, v_now, t_now, t_ign, 1024.0, F_ALL)
        var b = finite_burn(bodies, coast.r, coast.v, t_ign, seconds, dv)
        var el = moon_orbit(bodies, b.r, b.v, b.t_end)
        peri = el.a * (1.0 - el.e) - R_MOON
        apo = el.a * (1.0 + el.e) - R_MOON
        var f0 = peri - peri_alt
        var f1 = apo - apo_alt
        if abs(f0) < 0.2 and abs(f1) < 0.5:
            ok = True
            break
        var dt = 10.0
        var ddv = 0.002
        var c1 = bodies.run(r_now, v_now, t_now, t_ign + dt, 1024.0, F_ALL)
        var b1 = finite_burn(bodies, c1.r, c1.v, t_ign + dt, seconds, dv)
        var e1 = moon_orbit(bodies, b1.r, b1.v, b1.t_end)
        var b2 = finite_burn(bodies, coast.r, coast.v, t_ign, seconds, dv + ddv)
        var e2 = moon_orbit(bodies, b2.r, b2.v, b2.t_end)
        var j00 = (e1.a * (1.0 - e1.e) - R_MOON - peri) / dt
        var j10 = (e1.a * (1.0 + e1.e) - R_MOON - apo) / dt
        var j01 = (e2.a * (1.0 - e2.e) - R_MOON - peri) / ddv
        var j11 = (e2.a * (1.0 + e2.e) - R_MOON - apo) / ddv
        var det = j00 * j11 - j01 * j10
        if det == 0.0:
            break
        t_ign += (-f0 * j11 + f1 * j01) / det
        dv += (-f1 * j00 + f0 * j10) / det
    return LoiSolution(t_ign, dv, peri, apo, ok)


def next_perilune(bodies: Bodies, eph: Ephemeris, r: Vec3, v: Vec3, t_now: Float64, horizon: Float64) -> Float64:
    """Table seconds of the next passage through perilune: ρ⃗·ρ̇ turning
    positive, refined the way `arrival` refines it."""
    var a = arrival(bodies, eph, r, v, t_now, t_now + horizon)
    return a.t_p


@fieldwise_init
struct SitePass(ImplicitlyCopyable, Movable):
    var found: Bool
    var t: Float64  # table seconds of the crossing
    var cross_km: Float64  # signed: the site's distance from the orbit plane
    var track_lat: Float64  # the ground track's latitude at the site's longitude
    var crossings: Int  # how many times the track crossed the site's longitude


def site_pass(
    eph: Ephemeris,
    bodies: Bodies,
    r0: Vec3,
    v0: Vec3,
    t0: Float64,
    t1: Float64,
    site_lat: Float64,
    site_lon: Float64,
    budget_km: Float64,
) -> SitePass:
    """Fly the lunar orbit from t0 to t1 and find the crossing of the
    site's longitude at which the site lies nearest the orbit plane."""
    var samples = List[Float64]()
    _ = bodies.run_recording(r0, v0, t0, t1, 1024.0, F_ALL, samples)
    var n = len(samples) // 7
    var best = SitePass(False, 0.0, 1.0e9, 0.0, 0)
    var prev_d = 0.0
    var have_prev = False
    for i in range(n):
        var t = samples[i * 7]
        var r = Vec3(samples[i * 7 + 1], samples[i * 7 + 2], samples[i * 7 + 3])
        var v = Vec3(samples[i * 7 + 4], samples[i * 7 + 5], samples[i * 7 + 6])
        var m = bodies.moon_at(t)
        var rho = r - m
        var frame = eph.moon_frame(bodies.jde0 + t / 86400.0)
        var ll = frame.selenographic(rho)
        var d = wrap180(ll.lon - site_lon)
        if have_prev and ((prev_d > 0.0 and d <= 0.0) or (prev_d < 0.0 and d >= 0.0)) and abs(d - prev_d) < 180.0:
            var mv = (bodies.moon_at(t + 30.0) - bodies.moon_at(t - 30.0)) * (1.0 / 60.0)
            var h = rho.cross(v - mv).unit()
            var site_dir = frame.to_inertial(site_lat, site_lon)
            var cross = asin(site_dir.dot(h)) * R_MOON
            best.crossings += 1
            if abs(cross) < abs(best.cross_km):
                best.cross_km = cross
                best.t = t
                best.track_lat = ll.lat
        prev_d = d
        have_prev = True
    best.found = best.crossings > 0 and abs(best.cross_km) <= budget_km
    return best


@fieldwise_init
struct DescentPlan(ImplicitlyCopyable, Movable):
    var t_land: Float64  # table seconds
    var t_pdi: Float64
    var t_doi: Float64
    var dv_doi: Float64  # km/s
    var period_desc: Float64  # s


def plan_descent(circ_alt: Float64, desc_peri: Float64, t_cross: Float64) -> DescentPlan:
    """From a circular orbit whose ground track crosses the site at
    t_cross. The descent orbit is faster than the circular one, so the
    burns are placed by ANGLE: DOI where the LM, still circular, is a
    half-turn plus the braking range short of the site; PDI half an
    ellipse later, at the perilune, BRAKING_RANGE short; touchdown a
    braking phase after that -- after the orbit itself would have passed
    over, because the LM decelerates all the way."""
    var r_c = R_MOON + circ_alt
    var r_d = R_MOON + desc_peri
    var a = 0.5 * (r_c + r_d)
    var period = 2.0 * 3.141592653589793 * sqrt(a * a * a / MU_MOON)
    var dv = sqrt(MU_MOON / r_c) - sqrt(MU_MOON * (2.0 / r_c - 1.0 / a))
    var v_ground = sqrt(MU_MOON / r_c) + OMEGA_MOON * R_MOON  # retrograde: the Moon turns toward it
    var n_ground = v_ground / r_c  # rad/s over the ground
    var braking_angle = BRAKING_RANGE / R_MOON
    var t_doi = t_cross - (3.141592653589793 + braking_angle) / n_ground
    var t_pdi = t_doi + 0.5 * period
    return DescentPlan(t_pdi + BRAKING_SECONDS, t_pdi, t_doi, dv, period)
