# ===----------------------------------------------------------------------=== #
# MC6's oracles for the cloud: the generator is what it says; the exact
# copy of the plan lands where the CPU's corrector said, to the Float32
# gap MC1 measured; sixteen thousand copies fly in under a second; and
# the corridor probability rises after a correction, as it must.
#
# Run: cocoamojo run examples/moonshot/test_cloud.mojo
# ===----------------------------------------------------------------------=== #

from astro import *
from orbit import *
from transfer import *
from window import *
from plan import *
from cloud import *
from std.testing import *
from std.time import perf_counter_ns
from max.gpu.host import DeviceContext

comptime N = 16384


def test_rng() raises:
    var rng = Rng(1969)
    var s = 0.0
    var s2 = 0.0
    var k = 100000
    for _ in range(k):
        var g = rng.gauss()
        s += g
        s2 += g * g
    var mean = s / Float64(k)
    var sigma = sqrt(s2 / Float64(k) - mean * mean)
    print("    100 000 draws: mean", fmt(mean, 4), "sigma", fmt(sigma, 4))
    assert_almost_equal(mean, 0.0, atol=0.02)
    assert_almost_equal(sigma, 1.0, atol=0.02)
    var a = Rng(42)
    var b = Rng(42)
    for _ in range(100):
        assert_equal(a.next(), b.next())
    var c = Rng(43)
    var d = Rng(42)
    assert_true(c.next() != d.next())


def test_perturbations() raises:
    var rng = Rng(7)
    var dv = Vec3(0.0, 3.0, 1.0)
    var s = 0.0
    var s2 = 0.0
    var ang = 0.0
    var ang2 = 0.0
    var k = 20000
    for _ in range(k):
        var p = perturb_burn(rng, dv, 0.001, 0.1)
        var dm = (p.norm() - dv.norm()) / dv.norm()
        s += dm
        s2 += dm * dm
        var c = p.unit().dot(dv.unit())
        c = 1.0 if c > 1.0 else c
        var a = acos(c) * RAD
        ang += a
        ang2 += a * a
    var sig_m = sqrt(s2 / Float64(k) - (s / Float64(k)) * (s / Float64(k)))
    # Two independent angles of σ each: the total angle's RMS is σ√2.
    var rms_a = sqrt(ang2 / Float64(k))
    print("    burn errors: magnitude sigma", fmt(sig_m, 5), "(0.001), pointing rms", fmt(rms_a, 4), "° (0.1414)")
    assert_almost_equal(sig_m, 0.001, rtol=0.05)
    assert_almost_equal(rms_a, 0.1 * sqrt(2.0), rtol=0.05)


def test_cloud_at_tli() raises:
    var eph = Ephemeris()
    var ch = apollo_11_choices()
    var wm = WindowMap(eph, ch.year, ch.month, launch_sites()[ch.pad], landing_sites()[ch.target], 60.0, 120.0, 48, 480)
    var sheet = make_plan(eph, wm, ch)
    var bodies = Bodies(eph, sheet.jde_tli, ch.tof_h / 24.0 + 0.6)
    var inj = sheet.transfer.injection
    var v_tli = sheet.transfer.correction.v
    var a_cpu = sheet.transfer.correction.arrival
    var pole = bodies.moon_at(a_cpu.t_p).cross(eph.moon_velocity(sheet.jde_tli + a_cpu.t_p / 86400.0)).unit()

    var rng = Rng(1969)
    var cloud = tli_cloud(rng, inj.r, inj.v_park, v_tli, N)
    var ctx = DeviceContext(api="metal")
    var t0 = perf_counter_ns()
    fly_cloud(cloud, ctx, bodies, a_cpu.t_p + 6.0 * 3600.0)
    var t1 = perf_counter_ns()
    var ms = Float64(t1 - t0) / 1e6
    # The exact copy against the CPU's perilune.
    assert_true(cloud.found(0))
    var a0 = cloud.perilune(0)
    var b0 = b_plane(a0.rho, a0.rho_dot, pole)
    print("    exact copy on the GPU: perilune", fmt(b0.r_p - R_MOON, 2), "km at", fmt(a0.t_p / 3600.0, 4), "h; CPU:", fmt(a_cpu.r_p - R_MOON, 2), "km at", fmt(a_cpu.t_p / 3600.0, 4), "h; gap", fmt((b0.r_p - a_cpu.r_p), 3), "km,", fmt(a0.t_p - a_cpu.t_p, 1), "s, B", fmt(sqrt((b0.bt - a_cpu.bt) ** 2 + (b0.br - a_cpu.br) ** 2), 2), "km")
    assert_almost_equal(b0.r_p, a_cpu.r_p, atol=3.0)
    assert_almost_equal(a0.t_p, a_cpu.t_p, atol=30.0)
    var st = cloud_stats(cloud, pole)
    print("    " + String(N) + " copies with the S-IVB's errors in", fmt(ms, 0), "ms (compile and copies included):", st.found, "reached perilune; altitude", fmt(st.mean_alt, 1), "±", fmt(st.sigma_alt, 1), "km; B·T ±", fmt(st.sigma_bt, 1), "B·R ±", fmt(st.sigma_br, 1), "km; time ±", fmt(st.sigma_t / 60.0, 1), "min; P(corridor 60–200 km) =", fmt(st.p_corridor * 100.0, 1), "%")
    assert_true(ms < 1000.0)
    assert_true(st.found > N * 95 // 100)
    assert_true(st.sigma_alt > 1.0)
    assert_true(st.p_corridor > 0.05 and st.p_corridor <= 1.0)

    # After a correction at TLI + 24 h, what remains is tracking's error.
    var arc = List[Float64]()
    var t_mcc = 24.0 * 3600.0
    var at = bodies.run(inj.r, v_tli, 0.0, t_mcc, 1024.0, F_ALL)
    var rng2 = Rng(1970)
    var cloud2 = tracked_cloud(rng2, at.r, at.v, t_mcc, N, TRACK_POS_SIGMA, TRACK_VEL_SIGMA)
    var t2 = perf_counter_ns()
    fly_cloud(cloud2, ctx, bodies, a_cpu.t_p + 6.0 * 3600.0)
    var t3 = perf_counter_ns()
    var st2 = cloud_stats(cloud2, pole)
    print("    after MCC-2 (1 km, 0.1 m/s tracking): in", fmt(Float64(t3 - t2) / 1e6, 0), "ms: altitude", fmt(st2.mean_alt, 1), "±", fmt(st2.sigma_alt, 1), "km; B ±", fmt(st2.sigma_bt, 1), "/", fmt(st2.sigma_br, 1), "km; P(corridor) =", fmt(st2.p_corridor * 100.0, 1), "%")
    assert_true(st2.sigma_alt < st.sigma_alt)
    assert_true(st2.p_corridor >= st.p_corridor)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
