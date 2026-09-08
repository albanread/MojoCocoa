# ===----------------------------------------------------------------------=== #
# MC8's oracles. A nominal Apollo 11 descent from a 15 km perilune 480 km
# short of Tranquility, on Tranquility's ground: it lands in twelve to
# thirteen minutes for about two kilometres a second with tens of seconds
# of hover left, having stepped past West Crater. The same descent with a
# thirty-second reserve over a boulder field aborts. And the terrain is
# the same ground every time.
#
# Run: cocoamojo run examples/moonshot/test_descent.mojo
# ===----------------------------------------------------------------------=== #

from astro import *
from orbit import *
from lunar import *
from descent import *
from plan import LM_MASS, DPS_PROP
from std.testing import *
from std.time import perf_counter_ns


def pdi_state(eph: Ephemeris, jde: Float64, site: Site) -> RVd:
    """The descent orbit's perilune, 15 km up, BRAKING_RANGE short of the
    site along a retrograde track a few degrees to the equator."""
    var frame = eph.moon_frame(jde)
    var s_dir = frame.to_inertial(site.lat, site.lon)
    var pole_ret = -frame.z
    var h = (pole_ret - s_dir * pole_ret.dot(s_dir)).unit()
    var ang = BRAKING_RANGE / R_MOON
    var pos_dir = rotate_about(s_dir, h, -ang)
    var r_d = R_MOON + 15.0
    var r_c = R_MOON + 111.0
    var a = 0.5 * (r_c + r_d)
    var vp = sqrt(MU_MOON * (2.0 / r_d - 1.0 / a))
    var vdir = h.cross(pos_dir).unit()
    return RVd(pos_dir * r_d, vdir * vp)


def run(mut d: Descent) -> Float64:
    var t0 = perf_counter_ns()
    while d.phase < LANDED and d.t < 1500.0:
        d.step(1.0)
    return Float64(perf_counter_ns() - t0) / 1e6


def report(name: String, d: Descent):
    var l = d.truth_local()
    print("    " + name + ": " + phase_label(d.phase) + " -- " + d.outcome_reason)
    print("      gates at " + fmt(d.t_high_gate, 0) + " s and " + fmt(d.t_low_gate, 0) + " s")
    print("      " + fmt(d.t / 60.0, 2) + " min, " + fmt(d.dv_used, 0) + " m/s, hover left " + fmt(d.hover_seconds(), 0) + " s, " + String(d.redesignations) + " redesignations, " + fmt(sqrt(d.landed_x * d.landed_x + d.landed_y * d.landed_y), 0) + " m from the site, contact " + fmt(d.contact_speed, 2) + " m/s, max throttle " + fmt(d.max_throttle, 2) + ", radar " + String(d.radar_locked))


def test_terrain() raises:
    var site = landing_sites()[0]
    var t1 = Terrain(site.lat, site.lon, False)
    var t2 = Terrain(site.lat, site.lon, False)
    assert_equal(len(t1.craters), len(t2.craters))
    for i in range(len(t1.craters)):
        assert_equal(t1.craters[i], t2.craters[i])
    # West Crater is a real hole with a rim, and its field has boulders.
    var wx = t1.craters[0]
    var wy = t1.craters[1]
    assert_true(t1.height(wx, wy) < -15.0)
    assert_true(t1.height(wx + 90.0, wy) > 2.0)
    assert_false(t1.safe(wx, wy))
    var n = 0
    for k in range(400):
        if t1.boulder(wx - 200.0 + Float64(k), wy):
            n += 1
    print("    West Crater at (" + fmt(wx, 0) + ", " + fmt(wy, 0) + ") m: " + String(n) + " boulder cells across 400 m of its field")
    assert_true(n > 20)
    var ns = t1.nearest_safe(wx, wy, 900.0)
    assert_true(ns.z > 0.5)
    assert_true(sqrt((ns.x - wx) ** 2 + (ns.y - wy) ** 2) > 100.0)
    assert_true(t1.safe(-3000.0, 3000.0) or t1.safe(-3100.0, 3000.0))


def test_nominal_apollo_11() raises:
    var eph = Ephemeris()
    var site = landing_sites()[0]
    var jde = jde_from_ut(julian_day(1969, 7, 20, 20, 5, 0.0))
    var s = pdi_state(eph, jde, site)
    var terrain = Terrain(site.lat, site.lon, False)
    var d = Descent(s.r, s.v, eph.moon_frame(jde).to_inertial(site.lat, site.lon), eph.moon_frame(jde).z, LM_MASS - 108.0, DPS_PROP - 108.0, 60.0, terrain^, Vec3(0.0, 0.0, 0.0), 9000.0)
    var ms = run(d)
    report(String("nominal, 60 s reserve"), d)
    print("      simulated in", fmt(ms, 0), "ms")
    assert_equal(d.phase, LANDED)
    assert_true(d.t > 12.0 * 60.0 and d.t < 13.5 * 60.0)
    assert_true(d.dv_used > 1900.0 and d.dv_used < 2300.0)
    assert_true(d.hover_seconds() > 20.0 and d.hover_seconds() < 120.0)
    assert_true(d.redesignations >= 1)
    assert_true(d.contact_speed < 2.5)
    assert_true(d.max_throttle > 0.99)
    assert_true(d.radar_locked)


def test_boulder_field_and_the_reserve() raises:
    # A boulder field nine hundred metres across on the aim point: the
    # nearest ground is most of a kilometre away, and flying there costs
    # a hundred seconds of hover. The policy decides the outcome: a
    # sixty-second reserve calls the abort before they are down; a
    # thirty-second reserve lets them land with less than that left.
    var eph = Ephemeris()
    var site = landing_sites()[0]
    var jde = jde_from_ut(julian_day(1969, 7, 20, 20, 5, 0.0))
    var s = pdi_state(eph, jde, site)
    var t60 = Terrain(site.lat, site.lon, True)
    var d60 = Descent(s.r, s.v, eph.moon_frame(jde).to_inertial(site.lat, site.lon), eph.moon_frame(jde).z, LM_MASS - 108.0, DPS_PROP - 108.0, 60.0, t60^, Vec3(0.0, 0.0, 0.0), 9000.0)
    _ = run(d60)
    report(String("boulder field, 60 s reserve"), d60)
    var t30 = Terrain(site.lat, site.lon, True)
    var d30 = Descent(s.r, s.v, eph.moon_frame(jde).to_inertial(site.lat, site.lon), eph.moon_frame(jde).z, LM_MASS - 108.0, DPS_PROP - 108.0, 30.0, t30^, Vec3(0.0, 0.0, 0.0), 9000.0)
    _ = run(d30)
    report(String("boulder field, 30 s reserve"), d30)
    assert_equal(d60.phase, ABORTED)
    assert_equal(d30.phase, LANDED)
    assert_true(d30.hover_seconds() < 60.0)
    assert_true(d30.redesignations >= 1)


def test_navigation_error_lands_long() raises:
    # A kilometre of navigation error: the LM lands a kilometre from the
    # site, as Apollo 11 landed seven, on whatever ground is there.
    var eph = Ephemeris()
    var site = landing_sites()[0]
    var jde = jde_from_ut(julian_day(1969, 7, 20, 20, 5, 0.0))
    var s = pdi_state(eph, jde, site)
    var terrain = Terrain(site.lat, site.lon, False)
    var d = Descent(s.r, s.v, eph.moon_frame(jde).to_inertial(site.lat, site.lon), eph.moon_frame(jde).z, LM_MASS - 108.0, DPS_PROP - 108.0, 60.0, terrain^, Vec3(-1000.0, 200.0, 300.0), 9000.0)
    _ = run(d)
    report(String("1 km navigation error"), d)
    assert_true(d.phase == LANDED or d.phase == ABORTED)
    if d.phase == LANDED:
        var off = sqrt(d.landed_x * d.landed_x + d.landed_y * d.landed_y)
        assert_true(off > 700.0 and off < 2000.0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
