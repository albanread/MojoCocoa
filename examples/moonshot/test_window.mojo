# ===----------------------------------------------------------------------=== #
# MC3's oracles: the geometry of Apollo 11's launch minute, the daily
# corridor window against the recorded one, the lighting bands against
# the three launch dates NASA planned for July 1969, and the Float32
# map on the GPU against the Float64 cell on the CPU.
#
# Run: cocoamojo run examples/moonshot/test_window.mojo
# ===----------------------------------------------------------------------=== #

from astro import *
from orbit import *
from window import *
from std.testing import *
from std.time import perf_counter_ns
from max.gpu.host import DeviceContext

comptime TOF_A11 = 73.0927  # hours, TLI to LOI-1


def ksc() -> Site:
    return launch_sites()[0]


def site(name_index: Int) -> Site:
    return landing_sites()[name_index]


def july_1969(target: Site) -> WindowMap:
    var eph = Ephemeris()
    return WindowMap(eph, 1969, 7, ksc(), target, 60.0, 120.0, 48, 480)


def test_apollo_11_launch_minute() raises:
    # 16 July 1969, 13:32 UTC, 73.09 h to the Moon: the plane through the
    # pad and the Moon-at-arrival is 32.5° inclined, its pad azimuth is
    # 72°, in the corridor; the transfer costs what MC2 found; and the
    # Sun is 10.7° over Tranquility at touchdown.
    var m = july_1969(site(0))
    var c = m.cell_cpu(m.t_of(16, 13.0 + 32.0 / 60.0), TOF_A11 * 3600.0)
    print("    Apollo 11's minute: azimuth", fmt(c[F_AZ], 2), "°, inclination", fmt(c[F_INC], 2), "°, TLI", fmt(c[F_DV_TLI] * 1000.0, 1), "m/s, v∞", fmt(c[F_VINF] * 1000.0, 0), "m/s, LOI", fmt(c[F_DV_LOI] * 1000.0, 1), "m/s, Sun", fmt(c[F_SUN], 1), "°, flags", Int(c[F_FLAGS]))
    var fl = Int(c[F_FLAGS])
    assert_true(fl & FLAG_OK != 0)
    assert_true(fl & FLAG_CORRIDOR != 0)
    assert_true(fl & FLAG_LIT != 0)
    assert_true(fl & FLAG_RISING != 0)
    assert_almost_equal(c[F_INC], 32.52, atol=0.6)
    assert_almost_equal(c[F_AZ], 72.06, atol=1.5)
    assert_almost_equal(c[F_DV_TLI], 3.163, atol=0.02)
    # MC2's targeted values: v∞ 1 078 m/s, LOI-1 873 m/s. The map is an
    # estimate and is held to 3%.
    assert_almost_equal(c[F_VINF], 1.078, rtol=0.03)
    assert_almost_equal(c[F_DV_LOI], 0.873, rtol=0.03)
    assert_almost_equal(c[F_SUN], 10.7, atol=0.3)


def test_daily_corridor_window() raises:
    # Apollo 11's window on the 16th ran from 13:32 to about 17:54 UTC,
    # opening at 72° and closing at 108°. The day has a second opportunity
    # around 00:15–04:40, the other injection geometry.
    var m = july_1969(site(0))
    var w = corridor_windows(m, 16, TOF_A11 * 3600.0)
    print("    16 July has", len(w) // 4, "corridor windows:")
    var pick = -1
    for k in range(len(w) // 4):
        var open_h = Int(w[k * 4])
        var open_m = Int((w[k * 4] - Float64(open_h)) * 60.0 + 0.5)
        var close_h = Int(w[k * 4 + 1])
        var close_m = Int((w[k * 4 + 1] - Float64(close_h)) * 60.0 + 0.5)
        print("      " + String(open_h) + ":" + (String("0") if open_m < 10 else String("")) + String(open_m) + " UTC at " + fmt(w[k * 4 + 2], 1) + "° to " + String(close_h) + ":" + (String("0") if close_m < 10 else String("")) + String(close_m) + " UTC at " + fmt(w[k * 4 + 3], 1) + "°")
        if w[k * 4] <= 14.0 and w[k * 4 + 1] >= 14.0:
            pick = k
    print("    (Apollo 11: 13:32 UTC at 72.06° to about 17:54)")
    assert_true(pick >= 0)
    assert_almost_equal(w[pick * 4], 13.0 + 32.0 / 60.0, atol=0.5)
    assert_true(w[pick * 4 + 1] - w[pick * 4] > 3.8 and w[pick * 4 + 1] - w[pick * 4] < 5.2)
    assert_almost_equal(w[pick * 4 + 2], 72.0, atol=0.7)
    assert_almost_equal(w[pick * 4 + 3], 108.0, atol=0.7)


def test_lighting_picks_the_days() raises:
    # NASA's July 1969 launch dates: the 16th for Tranquility (Site 2),
    # the 18th for Sinus Medii (Site 3), the 21st for Site 5. With the
    # flight time and the orbital stay Apollo 11 actually used, the Sun
    # band over each site picks those days by itself.
    var names = List[String]()
    names.append(String("Tranquility"))
    names.append(String("Sinus Medii"))
    names.append(String("Site 5"))
    var want = List[Float64]()
    want.append(16.5)
    want.append(18.5)
    want.append(21.5)
    for k in range(3):
        var m = july_1969(site(k))
        var bands = lighting_bands(m, TOF_A11 * 3600.0)
        var s = String("    ") + names[k] + ": lit launch band centred on day"
        for i in range(len(bands)):
            s += " " + fmt(bands[i], 2)
        print(s + " (NASA planned day " + fmt(want[k] - 0.5, 0) + ")")
        assert_true(len(bands) >= 1)
        var nearest = 1.0e30
        for i in range(len(bands)):
            var d = abs(bands[i] - want[k])
            if d < nearest:
                nearest = d
        assert_true(nearest < 1.0)
    # And Apollo 11's own minute is inside Tranquility's band.
    var m0 = july_1969(site(0))
    var c = m0.cell_cpu(m0.t_of(16, 13.0 + 32.0 / 60.0), TOF_A11 * 3600.0)
    assert_true(Int(c[F_FLAGS]) & FLAG_LIT != 0)


def test_gpu_map_matches_cpu() raises:
    var m = july_1969(site(0))
    var ctx = DeviceContext(api="metal")
    var t0 = perf_counter_ns()
    compute_map(m, ctx)
    var t1 = perf_counter_ns()
    print("    map", m.width, "x", m.height, "=", m.width * m.height, "cells on the GPU in", fmt(Float64(t1 - t0) / 1e6, 0), "ms (with compile and copies)")
    # Sampled cells against the Float64 reference.
    var worst_dv = 0.0
    var worst_az = 0.0
    var worst_sun = 0.0
    var flag_mismatch = 0
    var checked = 0
    for yi in range(0, m.height, 37):
        for xi in range(0, m.width, 53):
            var cpu = m.cell_cpu(m.t_at(xi, yi), m.tof_at(xi))
            var d_dv = abs(m.field(xi, yi, F_DV_TLI) + m.field(xi, yi, F_DV_LOI) - cpu[F_DV_TLI] - cpu[F_DV_LOI])
            var d_az = abs(m.field(xi, yi, F_AZ) - cpu[F_AZ])
            var d_sun = abs(m.field(xi, yi, F_SUN) - cpu[F_SUN])
            if d_dv > worst_dv:
                worst_dv = d_dv
            if d_az > worst_az:
                worst_az = d_az
            if d_sun > worst_sun:
                worst_sun = d_sun
            if m.flags(xi, yi) != Int(cpu[F_FLAGS]):
                flag_mismatch += 1
            checked += 1
    print("    " + String(checked) + " cells vs Float64: worst Δv", fmt(worst_dv * 1000.0, 2), "m/s, azimuth", fmt(worst_az, 4), "°, Sun", fmt(worst_sun, 4), "°; flag mismatches", flag_mismatch)
    assert_true(worst_dv < 0.002)
    assert_true(worst_az < 0.05)
    assert_true(worst_sun < 0.05)
    assert_true(flag_mismatch <= checked // 50)
    # The good cells: some exist, and Apollo's is among them.
    var good = 0
    var not_ok = 0
    for i in range(m.width * m.height):
        var fl = Int(m.cells[i * FIELDS + F_FLAGS])
        if fl & FLAG_CORRIDOR != 0 and fl & FLAG_LIT != 0 and fl & FLAG_RISING != 0:
            good += 1
        if fl & FLAG_OK == 0:
            not_ok += 1
    print("    cells whose transfer solve did not converge:", not_ok)
    assert_equal(not_ok, 0)
    var ax = m.x_of(16, TOF_A11)
    var ay = m.y_of(13.0 + 32.0 / 60.0)
    var afl = m.flags(ax, ay)
    print("    good cells (corridor, lit, morning):", good, "of", m.width * m.height, "; Apollo 11's pixel flags", afl, "at TLI", fmt(m.field(ax, ay, F_DV_TLI) * 1000.0, 0), "m/s")
    assert_true(good > 1000)
    assert_true(afl & FLAG_CORRIDOR != 0 and afl & FLAG_LIT != 0)
    var path = String("/tmp/moonshot-window-1969-07.png")
    if save_map(m, path, ax, ay):
        print("    saved", path)
    else:
        print("    could not save", path)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
