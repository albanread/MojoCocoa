# ===----------------------------------------------------------------------=== #
# MC1's oracles: Kepler's closed form against the integrator, energy and
# angular momentum as invariants, J2's nodal regression against the
# textbook rate, and -- the number this sprint exists to produce -- the
# Float32 GPU arc against the Float64 CPU arc at the Moon, printed.
#
# Run: cocoamojo run examples/moonshot/test_orbit.mojo
# ===----------------------------------------------------------------------=== #

from astro import *
from orbit import *
from std.testing import *
from std.time import perf_counter_ns
from max.gpu.host import DeviceContext


def leo_circular() -> RVd:
    """185 km circular, 28.5° inclined, node at the equinox."""
    var r = 185.0 + R_EARTH
    var vc = sqrt(MU_EARTH / r)
    var i = 28.5 * DEG
    return RVd(Vec3(r, 0.0, 0.0), Vec3(0.0, vc * cos(i), vc * sin(i)))


def test_stumpff() raises:
    assert_almost_equal(stumpff_s(0.0), 1.0 / 6.0, atol=1e-15)
    assert_almost_equal(stumpff_c(0.0), 0.5, atol=1e-15)
    assert_almost_equal(stumpff_s(1.0), 1.0 - sin(1.0), atol=1e-15)
    assert_almost_equal(stumpff_c(1.0), 1.0 - cos(1.0), atol=1e-15)
    assert_almost_equal(stumpff_s(-1.0), sinh(1.0) - 1.0, atol=1e-15)
    assert_almost_equal(stumpff_c(-1.0), cosh(1.0) - 1.0, atol=1e-15)
    # The series and the closed forms agree where they hand over.
    assert_almost_equal(stumpff_s(0.00099), stumpff_s(0.00101), atol=1e-8)
    assert_almost_equal(stumpff_c(-0.00099), stumpff_c(-0.00101), atol=1e-8)


def test_kepler_circular() raises:
    var s = leo_circular()
    var period = 2.0 * 3.141592653589793 * sqrt(s.r.norm() ** 3 / MU_EARTH)
    var q = kepler(s.r, s.v, period / 4.0, MU_EARTH)
    # A quarter turn: r has rotated 90° in the plane, |r| unchanged.
    assert_almost_equal(q.r.norm(), s.r.norm(), atol=1e-6)
    assert_almost_equal(q.r.dot(s.r), 0.0, atol=1e-3)
    var full = kepler(s.r, s.v, period, MU_EARTH)
    assert_almost_equal((full.r - s.r).norm(), 0.0, atol=1e-6)
    assert_almost_equal((full.v - s.v).norm(), 0.0, atol=1e-9)


def test_kepler_hyperbolic() raises:
    # Faster than escape at 7000 km: a hyperbola. Energy and angular
    # momentum are exact invariants of the closed form.
    var r0 = Vec3(7000.0, 0.0, 0.0)
    var v0 = Vec3(0.0, 12.0, 1.0)
    var e0 = specific_energy(r0, v0, MU_EARTH)
    var h0 = r0.cross(v0).norm()
    assert_true(e0 > 0.0)
    var q = kepler(r0, v0, 86400.0, MU_EARTH)
    assert_almost_equal(specific_energy(q.r, q.v, MU_EARTH), e0, rtol=1e-10)
    assert_almost_equal(q.r.cross(q.v).norm(), h0, rtol=1e-10)
    assert_true(q.r.norm() > 500000.0)
    # And back again, which only works if the hyperbolic branch is right.
    var back = kepler(q.r, q.v, -86400.0, MU_EARTH)
    assert_almost_equal((back.r - r0).norm(), 0.0, atol=1e-3)


def test_elements() raises:
    var s = leo_circular()
    var el = elements(s.r, s.v, MU_EARTH)
    assert_almost_equal(el.a, s.r.norm(), atol=1e-6)
    assert_almost_equal(el.e, 0.0, atol=1e-12)
    assert_almost_equal(el.i, 28.5, atol=1e-9)
    assert_almost_equal(el.node, 0.0, atol=1e-9)
    # A transfer ellipse, perigee 185 km, apogee 384 400 km.
    var rp = 185.0 + R_EARTH
    var ra = 384400.0
    var a = (rp + ra) / 2.0
    var vp = sqrt(MU_EARTH * (2.0 / rp - 1.0 / a))
    var el2 = elements(Vec3(rp, 0.0, 0.0), Vec3(0.0, vp, 0.0), MU_EARTH)
    assert_almost_equal(el2.a, a, rtol=1e-12)
    assert_almost_equal(el2.e, (ra - rp) / (ra + rp), rtol=1e-12)
    assert_almost_equal(el2.nu, 0.0, atol=1e-9)


def test_rk4_matches_kepler_for_a_day() raises:
    # Two-body only: the integrator against the closed form, low orbit,
    # one day, 10 s steps. The design says a metre.
    var eph = Ephemeris()
    var bodies = Bodies(eph, julian_day(1969, 7, 16, 13, 32, 0.0), 1.1)
    var s = leo_circular()
    var got = bodies.run(s.r, s.v, 0.0, 86400.0, 1024.0, F_NONE)
    var want = kepler(s.r, s.v, 86400.0, MU_EARTH)
    var miss = (got.r - want.r).norm()
    print("    RK4 vs Kepler after a day of LEO, adaptive step:", fmt(miss * 1000.0, 3), "m")
    assert_true(miss < 0.001)


def test_energy_over_five_days() raises:
    # A transfer ellipse flown for five days in two-body gravity: energy
    # drift below 1e-9 relative, through the perigee passage at the start
    # and the fast leg near the end.
    var eph = Ephemeris()
    var bodies = Bodies(eph, julian_day(1969, 7, 16, 13, 32, 0.0), 5.1)
    var rp = 185.0 + R_EARTH
    var a = (rp + 384400.0) / 2.0
    var vp = sqrt(MU_EARTH * (2.0 / rp - 1.0 / a))
    var r0 = Vec3(rp, 0.0, 0.0)
    var v0 = Vec3(0.0, vp, 0.0)
    var e0 = specific_energy(r0, v0, MU_EARTH)
    var got = bodies.run(r0, v0, 0.0, 5.0 * 86400.0, 1024.0, F_NONE)
    var e1 = specific_energy(got.r, got.v, MU_EARTH)
    var drift = (e1 - e0) / e0
    drift = drift if drift > 0.0 else -drift
    print("    energy drift over 5 days of a transfer ellipse, adaptive step:", drift)
    assert_true(drift < 1e-9)
    # And Kepler agrees on where it ended up.
    var want = kepler(r0, v0, 5.0 * 86400.0, MU_EARTH)
    var miss = (got.r - want.r).norm()
    print("    RK4 vs Kepler at the end of it:", fmt(miss, 4), "km")
    assert_true(miss < 0.1)


def test_j2_regresses_the_node() raises:
    # Ω̇ = −(3/2) J2 (R/a)² n cos i for a circular orbit: −7.9°/day at
    # 185 km and 28.5°. The integrator with J2 on must reproduce the rate.
    var eph = Ephemeris()
    var bodies = Bodies(eph, julian_day(1969, 7, 16, 13, 32, 0.0), 1.1)
    var s = leo_circular()
    var a = s.r.norm()
    var n = sqrt(MU_EARTH / (a * a * a))
    var rate = -1.5 * J2_EARTH * (R_EARTH / a) * (R_EARTH / a) * n * cos(28.5 * DEG) * RAD * 86400.0
    var got = bodies.run(s.r, s.v, 0.0, 86400.0, 1024.0, F_J2)
    var el = elements(got.r, got.v, MU_EARTH)
    var node = el.node - 360.0 if el.node > 180.0 else el.node
    print("    node after a day with J2:", fmt(node, 3), "°  (secular theory", fmt(rate, 3), "°/day)")
    assert_almost_equal(node, rate, atol=0.15)


def test_third_body_terms() raises:
    # 10 000 km short of the Moon: the Moon's contribution, taken as the
    # difference from two-body gravity, is the pull toward the Moon less
    # the Moon's pull on the Earth (the indirect term).
    var eph = Ephemeris()
    var jde = jde_from_ut(julian_day(1969, 7, 19, 17, 21, 50.0))
    var bodies = Bodies(eph, jde, 0.1)
    var m = bodies.moon_at(0.0)
    var sun = bodies.sun_at(0.0)
    var mhat = m.unit()
    var r = m - mhat * 10000.0
    var base = vec3(gravity(v4(r), v4(m), v4(sun), F_NONE))
    var a = vec3(gravity(v4(r), v4(m), v4(sun), F_MOON)) - base
    var want = MU_MOON / (10000.0 * 10000.0) - MU_MOON / m.dot(m)
    assert_almost_equal(a.dot(mhat), want, rtol=1e-9)
    assert_almost_equal(a.cross(mhat).norm(), 0.0, atol=1e-15)
    # Two-body gravity alone points at the Earth with μ/r².
    assert_almost_equal(base.norm(), MU_EARTH / r.dot(r), rtol=1e-12)
    assert_almost_equal(base.unit().dot(r.unit()), -1.0, atol=1e-12)
    # The Sun's tidal acceleration out here is ~1e-8 km/s²: small, and
    # along the Earth–Sun line rather than toward the Sun.
    var s = vec3(gravity(v4(r), v4(m), v4(sun), F_SUN)) - base
    assert_true(s.norm() < 5e-8 and s.norm() > 1e-9)


def test_cpu_gpu_divergence_at_the_moon() raises:
    var eph = Ephemeris()
    var jde_tli = jde_from_ut(julian_day(1969, 7, 16, 16, 16, 16.0))
    var days = 5.2
    var b0 = perf_counter_ns()
    var bodies = Bodies(eph, jde_tli, days)
    var b1 = perf_counter_ns()
    print("    ephemeris table,", bodies.n, "samples:", fmt(Float64(b1 - b0) / 1e6, 1), "ms")
    var s = hohmann_arc(eph, jde_tli)
    var h_max = 1024.0

    # The truth: Float64 on the CPU, recorded for closest approach.
    var samples = List[Float64]()
    var t0 = perf_counter_ns()
    var cpu5 = bodies.run_recording(s.r, s.v, 0.0, 5.0 * 86400.0, h_max, F_ALL, samples)
    var t1 = perf_counter_ns()
    var closest = bodies.closest_to_moon(samples)
    print("    CPU Float64, 5 days,", len(samples) // 7 - 1, "steps:", fmt(Float64(t1 - t0) / 1e6, 2), "ms; closest approach to the Moon", fmt(closest, 0), "km")

    # The cloud: the same initial state in every thread, Float32 arithmetic
    # on int64 fixed-point accumulators on the GPU, flown to each of five
    # end times so the divergence can be watched grow.
    comptime N = 16384
    var c0 = perf_counter_ns()
    var ctx = DeviceContext(api="metal")
    var rx = ctx.enqueue_create_buffer[DType.int64](N)
    var ry = ctx.enqueue_create_buffer[DType.int64](N)
    var rz = ctx.enqueue_create_buffer[DType.int64](N)
    var vx = ctx.enqueue_create_buffer[DType.int64](N)
    var vy = ctx.enqueue_create_buffer[DType.int64](N)
    var vz = ctx.enqueue_create_buffer[DType.int64](N)
    var st = ctx.enqueue_create_buffer[DType.int32](N)
    var tab = ctx.enqueue_create_buffer[DType.int64](bodies.n * TABLE_STRIDE)
    with tab.map_to_host() as ht:
        var pt = ht.unsafe_ptr()
        for i in range(bodies.n * TABLE_STRIDE):
            pt[unsafe_offset=i] = bodies.tab[i]
    var c1 = perf_counter_ns()
    var kern = ctx.compile_function[propagate_kernel]()
    ctx.synchronize()
    var c2 = perf_counter_ns()
    print("    GPU setup", fmt(Float64(c1 - c0) / 1e6, 1), "ms; kernel compile", fmt(Float64(c2 - c1) / 1e6, 1), "ms")
    print("    days   CPU steps  GPU steps   Δr m      Δv mm/s   Moon km   GPU ms")
    var worst = 0.0
    for k in range(5):
        var t_end = Float64(k + 1) * 86400.0
        var cpu_steps = 0
        var cpu = propagate(state64(s.r, s.v), 0.0, t_end, h_max, bodies.tab.unsafe_ptr(), bodies.n, F_ALL, cpu_steps)
        with rx.map_to_host() as hx, ry.map_to_host() as hy, rz.map_to_host() as hz, vx.map_to_host() as hvx, vy.map_to_host() as hvy, vz.map_to_host() as hvz:
            var px = hx.unsafe_ptr()
            var py = hy.unsafe_ptr()
            var pz = hz.unsafe_ptr()
            var pvx = hvx.unsafe_ptr()
            var pvy = hvy.unsafe_ptr()
            var pvz = hvz.unsafe_ptr()
            for i in range(N):
                px[unsafe_offset=i] = fixed(s.r.x, POS_BITS)
                py[unsafe_offset=i] = fixed(s.r.y, POS_BITS)
                pz[unsafe_offset=i] = fixed(s.r.z, POS_BITS)
                pvx[unsafe_offset=i] = fixed(s.v.x, VEL_BITS)
                pvy[unsafe_offset=i] = fixed(s.v.y, VEL_BITS)
                pvz[unsafe_offset=i] = fixed(s.v.z, VEL_BITS)
        ctx.synchronize()
        var g0 = perf_counter_ns()
        ctx.enqueue_function(
            kern, rx, ry, rz, vx, vy, vz, st, tab,
            Int32(bodies.n), Float32(0.0), Float32(t_end), Float32(h_max), Int32(F_ALL), Int32(N),
            grid_dim=(N // 256), block_dim=(256),
        )
        ctx.synchronize()
        var g1 = perf_counter_ns()
        var gr = Vec3(0.0, 0.0, 0.0)
        var gv = Vec3(0.0, 0.0, 0.0)
        var gsteps = 0
        var spread = 0
        with rx.map_to_host() as hx, ry.map_to_host() as hy, rz.map_to_host() as hz, vx.map_to_host() as hvx, vy.map_to_host() as hvy, vz.map_to_host() as hvz, st.map_to_host() as hst:
            var px = hx.unsafe_ptr()
            var py = hy.unsafe_ptr()
            var pz = hz.unsafe_ptr()
            var pvx = hvx.unsafe_ptr()
            var pvy = hvy.unsafe_ptr()
            var pvz = hvz.unsafe_ptr()
            var pst = hst.unsafe_ptr()
            gr = Vec3(unfixed(px[unsafe_offset=0], POS_BITS), unfixed(py[unsafe_offset=0], POS_BITS), unfixed(pz[unsafe_offset=0], POS_BITS))
            gv = Vec3(unfixed(pvx[unsafe_offset=0], VEL_BITS), unfixed(pvy[unsafe_offset=0], VEL_BITS), unfixed(pvz[unsafe_offset=0], VEL_BITS))
            gsteps = Int(pst[unsafe_offset=0])
            # Every thread ran the same arithmetic on the same input: they
            # must agree to the unit, or the kernel is not deterministic.
            for i in range(N):
                if px[unsafe_offset=i] != px[unsafe_offset=0] or py[unsafe_offset=i] != py[unsafe_offset=0] or pz[unsafe_offset=i] != pz[unsafe_offset=0]:
                    spread += 1
        assert_equal(spread, 0)
        var dr = (gr - vec3(cpu.r.narrow())).norm()
        var dv = (gv - vec3(cpu.v.narrow())).norm()
        if dr > worst:
            worst = dr
        print(
            "    " + fmt(Float64(k + 1), 0) + "      " + fmt(Float64(cpu_steps), 0) + "        " + fmt(Float64(gsteps), 0)
            + "     " + fmt(dr * 1000.0, 1) + "     " + fmt(dv * 1.0e6, 3) + "    " + fmt((vec3(cpu.r.narrow()) - bodies.moon_at(t_end)).norm(), 0)
            + "    " + fmt(Float64(g1 - g0) / 1e6, 1)
        )
    print("    (the five-day arc ends", fmt((cpu5.r - bodies.moon_at(5.0 * 86400.0)).norm(), 0), "km from the Moon; the arc's closest approach was", fmt(closest, 0), "km)")
    assert_true(worst < 1.0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
