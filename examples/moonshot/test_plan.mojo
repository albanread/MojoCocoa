# ===----------------------------------------------------------------------=== #
# MC4's oracles for the sheet: Apollo 11's choices reproduce Apollo 11's
# timeline and burns; every margin is a number; a plan that breaks a rule
# says which one, in red.
#
# Run: cocoamojo run examples/moonshot/test_plan.mojo
# ===----------------------------------------------------------------------=== #

from astro import *
from orbit import *
from transfer import *
from window import *
from plan import *
from std.testing import *
from std.time import perf_counter_ns


def test_apollo_11_sheet() raises:
    var eph = Ephemeris()
    var ch = apollo_11_choices()
    var wm = WindowMap(eph, ch.year, ch.month, launch_sites()[ch.pad], landing_sites()[ch.target], 60.0, 120.0, 48, 480)
    var t0 = perf_counter_ns()
    var s = make_plan(eph, wm, ch)
    var t1 = perf_counter_ns()
    print("    plan in", fmt(Float64(t1 - t0) / 1e6, 0), "ms; GO:", is_go(s), "; red lines:", len(s.red), "; amber:", len(s.amber))
    for i in range(len(s.red)):
        print("      RED  ", s.red[i])
    for i in range(len(s.amber)):
        print("      AMBER", s.amber[i])
    print("    launch " + utc_string(s.jd_launch) + "  TLI " + get_string(s.jd_tli_ign, s.jd_launch) + "  LOI-1 " + get_string(s.jd_loi1_ign, s.jd_launch) + "  landing " + get_string(s.jd_landing, s.jd_launch) + " = " + utc_string(s.jd_landing))
    print("    TLI", fmt(s.dv_tli * 1000.0, 0), "m/s in", fmt(s.tli_seconds, 0), "s; LOI-1", fmt(s.dv_loi1 * 1000.0, 0), "m/s in", fmt(s.loi1_seconds, 0), "s; LOI-2", fmt(s.dv_loi2 * 1000.0, 0), "; DOI", fmt(s.dv_doi * 1000.0, 0), "; orbit", fmt(s.inc_equator, 1), "° to the lunar equator")
    print("    S-IVB used", fmt(s.sivb_used, 0), "kg, margin", fmt(s.sivb_margin_kg, 0), "kg =", fmt(s.sivb_margin_dv * 1000.0, 0), "m/s; SPS used", fmt(s.sps_used, 0), "+ TEI", fmt(s.sps_tei, 0), ", margin", fmt(s.sps_margin_kg, 0), "kg =", fmt(s.sps_margin_dv * 1000.0, 0), "m/s; DPS used", fmt(s.dps_used, 0), ", margin", fmt(s.dps_margin_kg, 0), "kg =", fmt(s.dps_margin_s, 0), "s of hover")
    assert_true(s.ok)
    assert_true(is_go(s))
    # Apollo 11: TLI at GET 002:44:16, LOI-1 at 075:49:50, touchdown at
    # 102:45:40 on 20 July 20:17:40 UTC.
    # Ignitions: TLI's is the chosen offset exactly; LOI-1's is half a
    # burn before the targeted perilune, so it lands on the record to
    # within the difference between our burn length and the SPS's.
    assert_equal(get_string(s.jd_tli_ign, s.jd_launch), String("002:44:16"))
    assert_almost_equal((s.jd_loi1_ign - s.jd_launch) * 86400.0, 75.0 * 3600.0 + 49.0 * 60.0 + 50.0, atol=30.0)
    assert_almost_equal((s.jd_landing - s.jd_launch) * 86400.0, 102.0 * 3600.0 + 45.0 * 60.0 + 40.0, atol=30.0)
    assert_equal(utc_string(s.jd_landing), String("Jul 20 20:17"))
    print("    TLI ignition " + get_string(s.jd_tli_ign, s.jd_launch) + ", impulse " + get_string(s.jd_tli, s.jd_launch) + "; LOI-1 ignition " + get_string(s.jd_loi1_ign, s.jd_launch) + ", perilune " + get_string(s.jd_loi1, s.jd_launch))
    assert_almost_equal(s.dv_tli, 3.182, rtol=0.01)
    assert_almost_equal(s.tli_seconds, 347.0, rtol=0.05)
    assert_almost_equal(s.dv_loi1, 0.889, rtol=0.03)
    assert_almost_equal(s.dv_loi2, 0.048, atol=0.01)
    assert_almost_equal(s.dv_doi, 0.023, atol=0.004)
    assert_almost_equal(s.sun_elev, 10.7, atol=0.3)
    assert_true(s.corridor and s.lit and s.sun_rising)
    assert_true(s.inc_equator > 170.0)
    assert_true(s.sivb_margin_kg > 0.0 and s.sps_margin_kg > 0.0 and s.dps_margin_kg > 0.0)
    assert_true(len(s.arc) > 7 * 100)
    assert_equal(len(s.windows), 8)


def test_rules_go_red() raises:
    var eph = Ephemeris()
    var ch = apollo_11_choices()
    var wm = WindowMap(eph, ch.year, ch.month, launch_sites()[ch.pad], landing_sites()[ch.target], 60.0, 120.0, 48, 480)
    # Launch at 08:00: outside the corridor.
    ch.hour = 8.0
    var s1 = make_plan(eph, wm, ch)
    assert_false(is_go(s1))
    assert_true(len(s1.red) >= 1)
    print("    08:00 launch:", s1.red[0])
    # Launch on the 24th at the window: the site is dark.
    ch.day = 24
    var w = corridor_windows(wm, 24, ch.tof_h * 3600.0)
    ch.hour = w[4] + 0.1 if len(w) >= 8 else w[0] + 0.1
    var s2 = make_plan(eph, wm, ch)
    assert_true(s2.corridor)
    assert_false(s2.lit)
    assert_false(is_go(s2))
    print("    24 July launch:", s2.red[0])
    # A 60-hour flight costs more than a 73-hour one, at both ends.
    var ch3 = apollo_11_choices()
    ch3.tof_h = 60.0
    var s3 = make_plan(eph, wm, ch3)
    var s0 = make_plan(eph, wm, apollo_11_choices())
    print("    60 h flight: TLI", fmt(s3.dv_tli * 1000.0, 0), "m/s, LOI-1", fmt(s3.dv_loi1 * 1000.0, 0), "m/s; S-IVB margin", fmt(s3.sivb_margin_dv * 1000.0, 0), "m/s; red lines", len(s3.red))
    assert_true(s3.dv_tli > s0.dv_tli and s3.dv_loi1 > s0.dv_loi1)
    # A three-minute hover reserve eats the DPS margin.
    var ch4 = apollo_11_choices()
    ch4.hover_s = 180.0
    var s4 = make_plan(eph, wm, ch4)
    assert_true(s4.dps_margin_s < s0.dps_margin_s - 100.0)


def test_get_strings() raises:
    var jd = julian_day(1969, 7, 16, 13, 32, 0.0)
    assert_equal(get_string(jd, jd), String("000:00:00"))
    assert_equal(get_string(jd + (75.0 * 3600.0 + 49.0 * 60.0 + 50.0) / 86400.0, jd), String("075:49:50"))
    assert_equal(get_string(jd - 90.0 / 86400.0, jd), String("-000:01:30"))
    assert_equal(utc_string(jd), String("Jul 16 13:32"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
