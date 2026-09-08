# ===----------------------------------------------------------------------=== #
# MC7's oracles: the site pass rejects Hadley from a 1° orbit and accepts
# it from one inclined enough and placed right; the finite LOI-1 solution
# makes the orbit the plan intended to the kilometre; and Apollo 11's
# arrival, flown, gives its LOI numbers, a circular orbit, a pass over
# Tranquility, and DOI and PDI placed for it.
#
# Run: cocoamojo run examples/moonshot/test_arrival.mojo
# ===----------------------------------------------------------------------=== #

from astro import *
from orbit import *
from transfer import *
from window import *
from plan import *
from mission import *
from lunar import *
from std.testing import *


def fly(mut m: Mission, to_get: Float64):
    m.warp = 3600.0
    while m.get < to_get and m.phase != PHASE_DONE:
        var chunk = to_get - m.get
        if chunk > 3600.0:
            chunk = 3600.0
        m.advance(chunk / m.warp)


def circular_over(eph: Ephemeris, bodies: Bodies, t: Float64, site: Site, inc: Float64, through_site: Bool) -> RVd:
    """A 111 km circular lunar orbit of inclination `inc` to the lunar
    equator: through the site's direction at table time t, or with its
    node 90° away from it."""
    var frame = eph.moon_frame(bodies.jde0 + t / 86400.0)
    var s_body = spherical(site.lon, site.lat, 1.0)
    var normals = planes_through(inc, s_body) if through_site else planes_through(inc, Vec3(cos(inc * DEG), 0.0, sin(inc * DEG)))
    var nb = normals[0]
    var h = frame.x * nb.x + frame.y * nb.y + frame.z * nb.z
    var pos_dir = frame.to_inertial(site.lat, site.lon) if through_site else h.cross(frame.z).unit()
    var rr = R_MOON + 111.0
    var moon = bodies.moon_at(t)
    var mv = (bodies.moon_at(t + 30.0) - bodies.moon_at(t - 30.0)) * (1.0 / 60.0)
    var rho = pos_dir * rr
    var vdir = h.cross(pos_dir).unit()
    return RVd(moon + rho, mv + vdir * sqrt(MU_MOON / rr))


def test_site_pass_hadley() raises:
    var eph = Ephemeris()
    var jde0 = jde_from_ut(julian_day(1969, 7, 20, 0, 0, 0.0))
    var bodies = Bodies(eph, jde0, 2.0)
    var hadley = landing_sites()[5]
    assert_almost_equal(hadley.lat, 26.13222, atol=1e-6)
    var t0 = 6.0 * 3600.0
    # A near-equatorial orbit never gets near 26° N.
    var low = circular_over(eph, bodies, t0, hadley, 1.0, False)
    var p1 = site_pass(eph, bodies, low.r, low.v, t0, t0 + 6.0 * 3600.0, hadley.lat, hadley.lon, 20.0)
    print("    Hadley from a 1° orbit:", p1.crossings, "longitude crossings, nearest", fmt(p1.cross_km, 0), "km off the plane; found:", p1.found)
    assert_true(p1.crossings >= 2)
    assert_false(p1.found)
    assert_true(abs(p1.cross_km) > 500.0)
    # An orbit inclined past the site's latitude, whose plane holds the
    # site at t0, passes over it.
    var high = circular_over(eph, bodies, t0, hadley, 26.5, True)
    # An hour earlier, by Kepler about the Moon, so the search runs
    # through the moment the orbit is over the site.
    var mv0 = (bodies.moon_at(t0 + 30.0) - bodies.moon_at(t0 - 30.0)) * (1.0 / 60.0)
    var back = kepler(high.r - bodies.moon_at(t0), high.v - mv0, -3600.0, MU_MOON)
    var tb = t0 - 3600.0
    var mvb = (bodies.moon_at(tb + 30.0) - bodies.moon_at(tb - 30.0)) * (1.0 / 60.0)
    var p2 = site_pass(eph, bodies, bodies.moon_at(tb) + back.r, mvb + back.v, tb, t0 + 3.0 * 3600.0, hadley.lat, hadley.lon, 20.0)
    print("    Hadley from a 26.5° orbit through it:", p2.crossings, "crossings, nearest", fmt(p2.cross_km, 2), "km at t0 " + fmt((p2.t - t0) / 60.0, 1) + " min; found:", p2.found)
    assert_true(p2.found)
    assert_true(abs(p2.cross_km) < 5.0)
    assert_true(abs(p2.t - t0) < 600.0)


def test_loi_solution() raises:
    var eph = Ephemeris()
    var ch = apollo_11_choices()
    var wm = WindowMap(eph, ch.year, ch.month, launch_sites()[ch.pad], landing_sites()[ch.target], 60.0, 120.0, 48, 480)
    var sheet = make_plan(eph, wm, ch)
    var bodies = Bodies(eph, sheet.jde_tli, ch.tof_h / 24.0 + 1.0)
    var a = sheet.transfer.correction.arrival
    var t_now = a.t_p - 5.0 * 3600.0
    var st = bodies.run(sheet.transfer.injection.r, sheet.transfer.correction.v, 0.0, t_now, 1024.0, F_ALL)
    var t_ign0 = a.t_p - 0.5 * sheet.loi1_seconds
    var sol = target_loi(bodies, st.r, st.v, t_now, t_ign0, sheet.dv_loi1, sheet.loi1_seconds, 111.0, 314.0)
    print("    LOI-1 solution: ignition", fmt(sol.t_ign - t_ign0, 1), "s from the impulse plan's, Δv", fmt(sol.dv * 1000.0, 1), "m/s (impulse", fmt(sheet.dv_loi1 * 1000.0, 1) + "); makes", fmt(sol.peri_alt, 2), "x", fmt(sol.apo_alt, 2), "km")
    assert_true(sol.converged)
    assert_almost_equal(sol.peri_alt, 111.0, atol=0.5)
    assert_almost_equal(sol.apo_alt, 314.0, atol=1.0)
    assert_almost_equal(sol.dv, sheet.dv_loi1, rtol=0.03)


def test_apollo_11_arrival() raises:
    var eph = Ephemeris()
    var ch = apollo_11_choices()
    var wm = WindowMap(eph, ch.year, ch.month, launch_sites()[ch.pad], landing_sites()[ch.target], 60.0, 120.0, 48, 480)
    var sheet = make_plan(eph, wm, ch)
    print("    the plan: lunar orbit", fmt(180.0 - sheet.inc_equator, 2), "° retrograde to the equator; site", fmt(sheet.cross_range, 2), "km off the plane at landing; TLI", fmt(sheet.dv_tli * 1000.0, 0), "m/s; LOI-1", fmt(sheet.dv_loi1 * 1000.0, 0), "m/s")
    assert_true(is_go(sheet))
    assert_true(abs(sheet.cross_range) < 5.0)
    var m = Mission(eph, sheet, 0)
    m.perfect = True
    fly(m, 84.0 * 3600.0)
    for i in range(len(m.log)):
        if i >= 8:
            print("      " + m.log[i])
    assert_true(m.events[m.event_index(EV_LOI1)].done and m.events[m.event_index(EV_LOI2)].done)
    var el = m.rel_elements()
    var peri = el.a * (1.0 - el.e) - R_MOON
    var apo = el.a * (1.0 + el.e) - R_MOON
    print("    after LOI-2:", fmt(peri, 1), "x", fmt(apo, 1), "km; landing pass planned:", m.landing_planned, "cross-range", fmt(m.cross_range, 2), "km at", get_string(m.jd_launch + m.t_land / 86400.0, m.jd_launch), "(Apollo 11 landed 102:45:40)")
    assert_almost_equal(peri, 111.0, atol=2.0)
    assert_almost_equal(apo, 111.0, atol=2.0)
    assert_true(m.landing_planned)
    assert_true(abs(m.cross_range) < 10.0)
    assert_true(abs(m.t_land - (102.0 * 3600.0 + 45.0 * 60.0 + 40.0)) < 2.0 * 3600.0)
    var doi = m.events[m.event_index(EV_DOI)]
    var pdi = m.events[m.event_index(EV_PDI)]
    assert_true(pdi.get > doi.get and doi.get > m.get)
    # PDI comes a braking-range of orbital motion before the crossing.
    assert_true(pdi.get < m.t_land - 600.0)
    assert_almost_equal(m.t_land - pdi.get, BRAKING_SECONDS, atol=1.0)
    # The record around LOI-1, again, with the plane now over the site.
    var loi1 = m.events[m.event_index(EV_LOI1)].get + 0.5 * m.events[m.event_index(EV_LOI1)].seconds
    for k in range(len(m.los_aos) // 2):
        if m.los_aos[k * 2] < loi1 and m.los_aos[k * 2 + 1] > loi1:
            print("    behind the Moon: LOS", get_string(m.jd_launch + m.los_aos[k * 2] / 86400.0, m.jd_launch), "(075:41:23) AOS", get_string(m.jd_launch + m.los_aos[k * 2 + 1] / 86400.0, m.jd_launch), "(076:15:29)")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
