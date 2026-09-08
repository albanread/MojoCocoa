# ===----------------------------------------------------------------------=== #
# MC5's oracles. Apollo 11's plan flown to the second perilune: the burns
# happen at the sheet's seconds and make the orbits the sheet promised;
# the flown course reproduces the planned one; and the Moon takes the
# spacecraft out of the stations' sight and gives it back when the record
# says -- LOS 075:41:23, AOS 076:15:29 around LOI-1.
#
# Run: cocoamojo run examples/moonshot/test_track.mojo
# ===----------------------------------------------------------------------=== #

from astro import *
from orbit import *
from transfer import *
from window import *
from plan import *
from mission import *
from std.testing import *
from std.time import perf_counter_ns


def fly(mut m: Mission, to_get: Float64):
    m.warp = 3600.0
    while m.get < to_get and m.phase != PHASE_DONE:
        var chunk = to_get - m.get
        if chunk > 3600.0:
            chunk = 3600.0
        m.advance(chunk / m.warp)


def test_apollo_11_flown() raises:
    var eph = Ephemeris()
    var ch = apollo_11_choices()
    var wm = WindowMap(eph, ch.year, ch.month, launch_sites()[ch.pad], landing_sites()[ch.target], 60.0, 120.0, 48, 480)
    var sheet = make_plan(eph, wm, ch)
    assert_true(is_go(sheet))
    var m = Mission(eph, sheet, 0)
    m.perfect = True  # the plan as flown by a perfect vehicle with perfect tracking
    assert_equal(m.phase, PHASE_PRELAUNCH)

    # Through the parking orbit and TLI.
    var t0 = perf_counter_ns()
    fly(m, 3.0 * 3600.0)
    assert_equal(m.phase, PHASE_TRANSLUNAR)
    assert_true(m.events[m.event_index(EV_TLI)].done)
    # A day out: the flown state is the planned state.
    fly(m, 30.0 * 3600.0)
    # The same physics on a slightly different step sequence: the gap is
    # the integrator's truncation error, and it is metres.
    print("    at GET 030:00:00 the flown course is", fmt(m.divergence * 1000.0, 1), "m from the planned one; in contact:", m.in_contact)
    assert_true(m.divergence < 0.05)
    assert_true(m.in_contact)

    # Through LOI-1 and LOI-2.
    fly(m, 82.0 * 3600.0)
    var t1 = perf_counter_ns()
    print("    flown to GET 082:00:00 in", fmt(Float64(t1 - t0) / 1e6, 0), "ms of CPU")
    for i in range(len(m.log)):
        print("      " + m.log[i])
    assert_true(m.events[m.event_index(EV_LOI1)].done and m.events[m.event_index(EV_LOI2)].done)
    assert_equal(m.phase, PHASE_LUNAR_ORBIT)
    var el = m.rel_elements()
    var peri = el.a * (1.0 - el.e) - R_MOON
    var apo = el.a * (1.0 + el.e) - R_MOON
    print("    after LOI-2 the lunar orbit is", fmt(peri, 1), "x", fmt(apo, 1), "km, e =", fmt(el.e, 4))
    assert_almost_equal(peri, 111.0, atol=5.0)
    assert_true(el.e < 0.02)

    # The record: LOS 075:41:23, AOS 076:15:29.
    var loi1 = m.events[m.event_index(EV_LOI1)].get + 0.5 * m.events[m.event_index(EV_LOI1)].seconds
    var best_los = -1.0
    var best_aos = -1.0
    for k in range(len(m.los_aos) // 2):
        var los = m.los_aos[k * 2]
        var aos = m.los_aos[k * 2 + 1]
        if los < loi1 and aos > loi1:
            best_los = los
            best_aos = aos
    assert_true(best_los > 0.0 and best_aos > 0.0)
    var want_los = 75.0 * 3600.0 + 41.0 * 60.0 + 23.0
    var want_aos = 76.0 * 3600.0 + 15.0 * 60.0 + 29.0
    print("    behind the Moon at LOI-1: LOS", get_string(m.jd_launch + best_los / 86400.0, m.jd_launch), "(record 075:41:23), AOS", get_string(m.jd_launch + best_aos / 86400.0, m.jd_launch), "(record 076:15:29)")
    print("    differences:", fmt(best_los - want_los, 0), "s and", fmt(best_aos - want_aos, 0), "s")
    # LOS to the design's minute. AOS lands about a minute and a half
    # early: the post-burn limb crossing depends on how the orbit plane
    # sits against the Earth line, and ours is 3.8° to the lunar equator
    # where Apollo's was about 1.2°; MC7 targets that plane properly.
    assert_almost_equal(best_los, want_los, atol=60.0)
    assert_almost_equal(best_aos, want_aos, atol=150.0)


def test_dispersed_mission() raises:
    # Seed 1969: the S-IVB misses by a few m/s, tracking sees most of it,
    # the trench corrects under the 1 m/s rule, and the perilune lands in
    # the corridor. Then the same seed again, to the same log.
    var eph = Ephemeris()
    var ch = apollo_11_choices()
    var wm = WindowMap(eph, ch.year, ch.month, launch_sites()[ch.pad], landing_sites()[ch.target], 60.0, 120.0, 48, 480)
    var sheet = make_plan(eph, wm, ch)
    var m = Mission(eph, sheet, 1969)
    m.mcc_threshold = mcc_threshold(1)
    fly(m, 78.0 * 3600.0)
    print("    seed 1969: TLI missed by", fmt(m.tli_error, 2), "m/s; corrections", fmt(m.mcc_total * 1000.0, 1), "m/s; true perilune", fmt(m.truth_perilune_alt, 1), "km (planned 111)")
    for i in range(len(m.log)):
        if m.log[i].find("MCC") >= 0 or m.log[i].find("perilune") >= 0 or m.log[i].find("retimed") >= 0:
            print("      " + m.log[i])
    assert_true(m.tli_error > 0.1)
    assert_true(m.mcc_total > 0.0005 and m.mcc_total < 0.05)
    assert_true(m.truth_perilune_alt > CORRIDOR_LO and m.truth_perilune_alt < CORRIDOR_HI)
    assert_true(m.events[m.event_index(EV_LOI1)].done)
    # Left uncorrected, the same S-IVB error misses the corridor.
    var u = Mission(eph, sheet, 1969)
    u.mcc_threshold = 1.0e9
    fly(u, 78.0 * 3600.0)
    print("    the same seed uncorrected: true perilune", fmt(u.truth_perilune_alt, 1), "km")
    assert_true(abs(u.truth_perilune_alt - 111.0) > abs(m.truth_perilune_alt - 111.0))
    # Determinism: the seed is the whole story.
    var m2 = Mission(eph, sheet, 1969)
    m2.mcc_threshold = mcc_threshold(1)
    fly(m2, 78.0 * 3600.0)
    assert_equal(len(m2.log), len(m.log))
    for i in range(len(m.log)):
        assert_equal(m2.log[i], m.log[i])
    assert_almost_equal(m2.truth_perilune_alt, m.truth_perilune_alt, atol=1e-9)


def test_station_geometry() raises:
    # A spacecraft straight above Goldstone is at 90°; one on the far side
    # of the Earth is below the horizon; one behind the Moon is occulted.
    var eph = Ephemeris()
    var jd = julian_day(1969, 7, 19, 17, 21, 50.0)
    var gds = stations()[0]
    var p = site_position(gds.lat, gds.lon, jd)
    var moon = eph.moon_position(jde_from_ut(jd))
    var above = station_contact(0, jd, p * 3.0, moon)
    assert_almost_equal(above.elevation, 90.0, atol=1e-6)
    assert_true(above.visible)
    var below = station_contact(0, jd, -p * 3.0, moon)
    assert_true(below.elevation < 0.0 and not below.visible)
    var behind = station_contact(0, jd, moon + moon.unit() * 2000.0, moon)
    assert_true(behind.occulted)
    var beside = station_contact(0, jd, moon + moon.unit().cross(Vec3(0.0, 0.0, 1.0)).unit() * 3000.0, moon)
    assert_false(beside.occulted)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
