# ===----------------------------------------------------------------------=== #
# MC2's oracles. Lambert against Kepler (the closed form must be inverted
# exactly), the B-plane against its own algebra, perilune refinement
# against ρ⃗·ρ̇ = 0, and the acceptance test: Apollo 11's translunar
# injection, re-planned from its parking orbit and its clock, must reach
# a 111 km perilune behind the Moon at the time LOI-1 was lit, for a Δv
# within 3% of the burn the S-IVB actually made.
#
# Run: cocoamojo run examples/moonshot/test_transfer.mojo
# ===----------------------------------------------------------------------=== #

from astro import *
from orbit import *
from transfer import *
from std.testing import *
from std.time import perf_counter_ns


def transfer_ellipse() -> RVd:
    """Perigee 185 km, apogee 384 400 km, inclined 28.5°, node at 40°."""
    var rp = 185.0 + R_EARTH
    var a = (rp + 384400.0) / 2.0
    var vp = sqrt(MU_EARTH * (2.0 / rp - 1.0 / a))
    var i = 28.5 * DEG
    var om = 40.0 * DEG
    var node = Vec3(cos(om), sin(om), 0.0)
    var n = Vec3(sin(i) * sin(om), -sin(i) * cos(om), cos(i))
    var perp = n.cross(node)
    var r = node * rp
    var v = perp * vp
    return RVd(r, v)


def test_lambert_recovers_kepler() raises:
    var s = transfer_ellipse()
    var n = s.r.cross(s.v).unit()
    for k in range(1, 5):
        var dt = Float64(k) * 0.6 * 86400.0
        var q = kepler(s.r, s.v, dt, MU_EARTH)
        var lam = lambert(s.r, q.r, dt, MU_EARTH, n)
        assert_true(lam.ok)
        assert_almost_equal((lam.v1 - s.v).norm(), 0.0, atol=1e-8)
        assert_almost_equal((lam.v2 - q.v).norm(), 0.0, atol=1e-8)


def test_lambert_hyperbolic() raises:
    var r1 = Vec3(7000.0, 0.0, 0.0)
    var v1 = Vec3(0.0, 12.0, 1.0)
    var n = r1.cross(v1).unit()
    var dt = 0.5 * 86400.0
    var q = kepler(r1, v1, dt, MU_EARTH)
    var lam = lambert(r1, q.r, dt, MU_EARTH, n)
    assert_true(lam.ok)
    assert_almost_equal((lam.v1 - v1).norm(), 0.0, atol=1e-8)
    assert_almost_equal((lam.v2 - q.v).norm(), 0.0, atol=1e-8)


def test_lambert_hohmann_closed_form() raises:
    # Kepler to 175° of true anomaly on the Hohmann ellipse, then Lambert
    # from perigee to that point must return exactly the perigee speed.
    var s = transfer_ellipse()
    var n = s.r.cross(s.v).unit()
    var el = elements(s.r, s.v, MU_EARTH)
    var e = el.e
    var nu = 175.0 * DEG
    var ea = 2.0 * atan2(sqrt(1.0 - e) * sin(nu / 2.0), sqrt(1.0 + e) * cos(nu / 2.0))
    var mean = ea - e * sin(ea)
    var dt = mean * sqrt(el.a ** 3 / MU_EARTH)
    var q = kepler(s.r, s.v, dt, MU_EARTH)
    assert_almost_equal(elements(q.r, q.v, MU_EARTH).nu, 175.0, atol=1e-6)
    var lam = lambert(s.r, q.r, dt, MU_EARTH, n)
    assert_true(lam.ok)
    assert_almost_equal(lam.v1.norm(), s.v.norm(), atol=1e-8)
    assert_almost_equal((lam.v1 - s.v).norm(), 0.0, atol=1e-7)
    # Opposite points are refused rather than divided by zero.
    var bad = lambert(s.r, -s.r * 50.0, dt, MU_EARTH, n)
    assert_false(bad.ok)


def test_b_plane_closed_form() raises:
    # A Moon-relative hyperbola built at its perilune: r_p = 1848.4 km,
    # v∞ = 1 km/s, in the plane of the pole.
    var r_p = R_MOON + 111.0
    var v_inf = 1.0
    var v_p = sqrt(v_inf * v_inf + 2.0 * MU_MOON / r_p)
    var rho = Vec3(r_p, 0.0, 0.0)
    var rho_dot = Vec3(0.0, v_p, 0.0)
    var pole = Vec3(0.0, 0.0, 1.0)
    var a = b_plane(rho, rho_dot, pole)
    assert_almost_equal(a.v_inf, v_inf, atol=1e-12)
    assert_almost_equal(a.r_p, r_p, atol=1e-12)
    assert_almost_equal(a.b.norm(), b_from_perilune(r_p, v_inf), rtol=1e-12)
    assert_almost_equal(perilune_from_b(a.b.norm(), v_inf), r_p, rtol=1e-12)
    assert_almost_equal(a.b.dot(a.s_hat), 0.0, atol=1e-9)
    assert_almost_equal(a.inc, 0.0, atol=1e-9)
    # Ŝ is the INCOMING asymptote: far back along the hyperbola the
    # velocity points along it.
    var back = kepler(rho, rho_dot, -3.0e5, MU_MOON)
    assert_true(back.v.unit().dot(a.s_hat) > 0.99999)
    # |B| is the impact parameter, h/v∞ exactly; and the far-back position's
    # component perpendicular to Ŝ approaches it (a hyperbola only reaches
    # its asymptote asymptotically: 1% off at 300 000 km is the geometry).
    assert_almost_equal(a.b.norm(), rho.cross(rho_dot).norm() / v_inf, rtol=1e-12)
    var perp = back.r - a.s_hat * back.r.dot(a.s_hat)
    assert_almost_equal(perp.norm(), a.b.norm(), rtol=2e-2)
    assert_true(perp.unit().dot(a.b.unit()) > 0.9999)


def test_planes_through() raises:
    var m = spherical(50.0, 20.0, 1.0)
    assert_equal(len(planes_through(10.0, m)), 0)
    var ps = planes_through(32.5, m)
    assert_equal(len(ps), 2)
    for k in range(2):
        assert_almost_equal(ps[k].norm(), 1.0, atol=1e-12)
        assert_almost_equal(ps[k].dot(m), 0.0, atol=1e-12)
        assert_almost_equal(acos(ps[k].z) * RAD, 32.5, atol=1e-9)
    assert_true((ps[0] - ps[1]).norm() > 0.1)


def test_solve3() raises:
    var j: List[Float64] = [2.0, 1.0, -1.0, -3.0, -1.0, 2.0, -2.0, 1.0, 2.0]
    var b: List[Float64] = [8.0, -11.0, -3.0]
    var x = solve3(j, b)
    assert_almost_equal(x[0], 2.0, atol=1e-12)
    assert_almost_equal(x[1], 3.0, atol=1e-12)
    assert_almost_equal(x[2], -1.0, atol=1e-12)


def test_arrival_refines_perilune() raises:
    var eph = Ephemeris()
    var jde_tli = jde_from_ut(julian_day(1969, 7, 16, 16, 16, 16.0))
    var bodies = Bodies(eph, jde_tli, 5.5)
    var s = hohmann_arc(eph, jde_tli)
    var a = arrival(bodies, eph, s.r, s.v, 0.0, 5.2 * 86400.0)
    var samples = List[Float64]()
    _ = bodies.run_recording(s.r, s.v, 0.0, 5.2 * 86400.0, 1024.0, F_ALL, samples)
    var sampled = bodies.closest_to_moon(samples)
    print("    Hohmann arc: nearest sample", fmt(sampled, 3), "km, refined perilune", fmt(a.r_p, 3), "km at t =", fmt(a.t_p / 3600.0, 3), "h")
    assert_true(a.r_p <= sampled + 1e-6)
    var cosang = a.rho.dot(a.rho_dot) / (a.rho.norm() * a.rho_dot.norm())
    assert_almost_equal(cosang, 0.0, atol=1e-6)
    assert_true(a.v_inf > 0.3 and a.v_inf < 1.5)


def test_apollo_11_transfer() raises:
    var eph = Ephemeris()
    var launch = julian_day(1969, 7, 16, 13, 32, 0.0)
    var tli_ut = julian_day(1969, 7, 16, 16, 16, 16.0)
    var loi_ut = julian_day(1969, 7, 19, 17, 21, 50.0)
    var tof = (loi_ut - tli_ut) * 86400.0
    var jde_tli = jde_from_ut(tli_ut)
    var bodies = Bodies(eph, jde_tli, 4.0)

    # The parking orbit: 32.52° inclined, and its plane must hold the
    # Moon where it will be at arrival. Of the two such planes, the one
    # KSC was under at launch is Apollo's.
    var m_hat = bodies.moon_at(tof).unit()
    var planes = planes_through(32.52, m_hat)
    assert_equal(len(planes), 2)
    var ksc = site_position(28.6083, -80.6041, launch).unit()
    var pick = 0
    var miss0 = asin(planes[0].dot(ksc)) * RAD
    var miss1 = asin(planes[1].dot(ksc)) * RAD
    if abs(miss1) < abs(miss0):
        pick = 1
    var normal = planes[pick]
    print("    the plane through the Moon-at-arrival that KSC launched into misses the pad by", fmt(miss0 if pick == 0 else miss1, 2), "° (the other by", fmt(miss1 if pick == 0 else miss0, 1), "°)")

    # First the transfer the launch geometry gives for free: an in-plane
    # burn to a far-side perilune at LOI-1's time.
    var t0 = perf_counter_ns()
    var plan = plan_transfer(eph, bodies, normal, 185.0, tof, R_MOON + 111.0, True, 314.0)
    var t1 = perf_counter_ns()
    var a = plan.correction.arrival
    var z_moon = eph.moon_frame(jde_tli + tof / 86400.0).z
    var inc_eq = acos(a.rho.cross(a.rho_dot).unit().dot(z_moon)) * RAD
    print("    Lambert first guess:", fmt(plan.injection.dv * 1000.0, 1), "m/s at", fmt(plan.injection.true_lon, 1), "° from the node")
    print("    in-plane TLI:", fmt(plan.dv_tli * 1000.0, 1), "m/s,", plan.correction.iterations, "rounds in", fmt(Float64(t1 - t0) / 1e6, 0), "ms -> perilune", fmt(a.r_p - R_MOON, 2), "km at", fmt(a.t_p / 3600.0, 3), "h, far side:", a.far_side, "; v∞", fmt(a.v_inf * 1000.0, 1), "m/s; orbit", fmt(inc_eq, 1), "° to the lunar equator")
    assert_true(plan.correction.converged)
    assert_almost_equal(a.r_p, R_MOON + 111.0, atol=1.0)
    assert_almost_equal(a.t_p, tof, atol=0.5)
    assert_true(a.far_side)
    assert_almost_equal(plan.plane_change, 0.0, atol=1e-6)

    # Then Apollo's: the same, steered to a retrograde orbit as near the
    # lunar equator as the approach allows -- the pole is minus the Moon's
    # spin axis. Apollo 11's LOI-1 orbit was inclined about 1° to it.
    var t2 = perf_counter_ns()
    var ap = plan_transfer_oriented(eph, bodies, normal, 185.0, tof, R_MOON + 111.0, -z_moon, 314.0)
    var t3 = perf_counter_ns()
    var b = ap.correction.arrival
    var inc_eq2 = acos(b.rho.cross(b.rho_dot).unit().dot(z_moon)) * RAD
    print("    steered TLI:", fmt(ap.dv_tli * 1000.0, 1), "m/s (" + fmt(ap.plane_change, 2) + "° of it out of plane),", ap.correction.iterations, "rounds in", fmt(Float64(t3 - t2) / 1e6, 0), "ms -> perilune", fmt(b.r_p - R_MOON, 2), "km at", fmt(b.t_p / 3600.0, 3), "h, far side:", b.far_side)
    print("    v∞", fmt(b.v_inf * 1000.0, 1), "m/s; B·T", fmt(b.bt, 1), "B·R", fmt(b.br, 1), "km; orbit", fmt(inc_eq2, 1), "° to the lunar equator,", fmt(b.inc, 1), "° to the Moon's orbit (retrograde, as Apollo's was)")
    print("    LOI-1 into 111 × 314 km:", fmt(ap.loi_dv * 1000.0, 1), "m/s (Apollo 11: 889)")
    print("    Apollo 11 TLI: ΔV 3 182 m/s over 347 s (10 441 ft/s), cutoff 3 041 m/s faster than the parking orbit")
    assert_true(ap.correction.converged)
    assert_almost_equal(b.r_p, R_MOON + 111.0, atol=1.0)
    assert_almost_equal(b.t_p, tof, atol=0.5)
    assert_true(b.far_side)
    assert_almost_equal(ap.dv_tli, 3.182, rtol=0.03)
    assert_true(ap.loi_dv > 0.7 and ap.loi_dv < 1.1)
    assert_true(inc_eq2 > 170.0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
