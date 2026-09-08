# ===----------------------------------------------------------------------=== #
# Moonshot — the checks: MC0 to MC3 as a report.
#
#   cocoamojo run examples/moonshot/checks.mojo
#
# The console is `main.mojo`; this is the sky and the sums it stands on,
# printed beside the record. It prints the week of Apollo 11 as the
# flight dynamics team would have had it: where the Moon was at launch and at landing, how far, what
# time it was on the sky, and the Sun over Tranquility Base at touchdown.
# Then the three Meeus examples the astronomy is tested against, printed
# beside the book's values so the match is visible without running the
# test suite. Then (MC1) the integrator's own report card: Kepler against
# Runge–Kutta, the energy it conserves, and the Float32 GPU cloud against
# the Float64 CPU truth on a five-day translunar arc. Then (MC2) Apollo
# 11's translunar injection re-planned from its parking orbit and its
# clock -- Lambert for the guess, differential correction to a far-side
# perilune at LOI-1's minute -- beside the burn the S-IVB actually made.
# Then (MC3) the month: July 1969's launch-window map, 714 240 candidate
# launches on the GPU, and the days the Sun over three landing sites
# picks, beside the days NASA picked.
# ===----------------------------------------------------------------------=== #

from astro import *
from orbit import *
from transfer import *
from window import *
from std.time import perf_counter_ns
from max.gpu.host import DeviceContext


def sky_line(eph: Ephemeris, label: String, jd_ut: Float64):
    var jde = jde_from_ut(jd_ut)
    var m = eph.moon_position(jde)
    var mll = lon_lat_of(m)
    var s = lon_lat_of(eph.sun_position(jde))
    print(
        "  " + label + "  " + civil_string(civil(jd_ut)) + " UTC   GMST "
        + hms(gmst_deg(jd_ut))
    )
    print(
        "      Moon  RA " + fmt(wrap360(mll.lon) / 15.0, 3) + "h  Dec "
        + fmt(mll.lat, 2) + "°  " + fmt(m.norm(), 0) + " km   Sun  RA "
        + fmt(wrap360(s.lon) / 15.0, 3) + "h  Dec " + fmt(s.lat, 2) + "°"
    )


def main() raises:
    var eph = Ephemeris()

    print("Moonshot MC0 — the almanac")
    print()
    print("Apollo 11's week (ΔT = " + fmt(delta_t_seconds(1969.55), 1) + " s)")
    var launch = julian_day(1969, 7, 16, 13, 32, 0.0)
    var tli = julian_day(1969, 7, 16, 16, 16, 16.0)
    var loi = julian_day(1969, 7, 19, 17, 21, 50.0)
    var landing = julian_day(1969, 7, 20, 20, 17, 40.0)
    sky_line(eph, "launch ", launch)
    sky_line(eph, "TLI    ", tli)
    sky_line(eph, "LOI-1  ", loi)
    sky_line(eph, "landing", landing)
    print()
    var jde = jde_from_ut(landing)
    var se = eph.sub_earth_point(jde)
    var ss = eph.sub_solar_point(jde)
    print("  at touchdown the Moon faces Earth from " + fmt(se.lon, 2) + "° E, " + fmt(se.lat, 2) + "° N (libration)")
    print("  sub-solar point " + fmt(ss.lon, 2) + "° E, " + fmt(ss.lat, 2) + "° N")
    print("  Sun elevation at the landing sites:")
    var sites = landing_sites()
    for i in range(len(sites)):
        var e = eph.sun_elevation_deg(jde, sites[i].lat, sites[i].lon)
        print("    " + fmt(e, 1) + "°   " + sites[i].name)
    print("  (Apollo 11 landed at Tranquility with the Sun at 10.8°)")
    print()

    print("Meeus's examples, ours beside the book's")
    var ms = eph.moon(2448724.5)
    print("  47.a  1992 April 12  λ " + fmt(ms.lon, 6) + " (133.162655)  β " + fmt(ms.lat, 6) + " (-3.229126)  Δ " + fmt(ms.dist, 1) + " (368409.7)")
    var su = eph.sun(2448908.5)
    print("  25.a  1992 Oct 13    ⊙ " + fmt(su.lon, 5) + " (199.90988)   R " + fmt(su.r, 5) + " (0.99766)")
    print("  12.a  1987 April 10  GMST " + hms(gmst_deg(2446895.5)) + " (13h 10m 46.3668s)")
    var se92 = eph.sub_earth_point(2448724.5)
    print("  53.a  1992 April 12  libration l′ " + fmt(se92.lon, 3) + " (-1.206)  b′ " + fmt(se92.lat, 3) + " (+4.194)")
    print()

    print("The integrator (MC1)")
    var jde_tli = jde_from_ut(tli)
    var bodies = Bodies(eph, jde_tli, 5.2)
    # Two-body only, against Kepler's closed form: a day of low orbit.
    var r = 185.0 + R_EARTH
    var vc = sqrt(MU_EARTH / r)
    var leo = bodies.run(Vec3(r, 0.0, 0.0), Vec3(0.0, vc, 0.0), 0.0, 86400.0, 1024.0, F_NONE)
    var kep = kepler(Vec3(r, 0.0, 0.0), Vec3(0.0, vc, 0.0), 86400.0, MU_EARTH)
    print("  RK4 vs Kepler, one day at 185 km:      " + fmt((leo.r - kep.r).norm() * 1000.0, 3) + " m")
    # The transfer ellipse, five days, energy conserved.
    var rp = 185.0 + R_EARTH
    var a = (rp + 384400.0) / 2.0
    var vp = sqrt(MU_EARTH * (2.0 / rp - 1.0 / a))
    var e0 = specific_energy(Vec3(rp, 0.0, 0.0), Vec3(0.0, vp, 0.0), MU_EARTH)
    var ell = bodies.run(Vec3(rp, 0.0, 0.0), Vec3(0.0, vp, 0.0), 0.0, 5.0 * 86400.0, 1024.0, F_NONE)
    var drift = (specific_energy(ell.r, ell.v, MU_EARTH) - e0) / e0
    print("  energy drift, five days of the transfer ellipse: " + String(drift if drift > 0.0 else -drift))
    # The real thing: Earth, J2, Moon and Sun, from Apollo 11's TLI epoch.
    var arc = hohmann_arc(eph, jde_tli)
    var samples = List[Float64]()
    var t0 = perf_counter_ns()
    var cpu = bodies.run_recording(arc.r, arc.v, 0.0, 5.0 * 86400.0, 1024.0, F_ALL, samples)
    var t1 = perf_counter_ns()
    print("  five-day translunar arc, Float64, " + String(len(samples) // 7 - 1) + " steps in " + fmt(Float64(t1 - t0) / 1e6, 2) + " ms; closest approach " + fmt(bodies.closest_to_moon(samples), 0) + " km")
    # And the cloud, sixteen thousand copies of it, on the GPU.
    comptime N = 16384
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
    with rx.map_to_host() as hx, ry.map_to_host() as hy, rz.map_to_host() as hz, vx.map_to_host() as hvx, vy.map_to_host() as hvy, vz.map_to_host() as hvz:
        var px = hx.unsafe_ptr()
        var py = hy.unsafe_ptr()
        var pz = hz.unsafe_ptr()
        var pvx = hvx.unsafe_ptr()
        var pvy = hvy.unsafe_ptr()
        var pvz = hvz.unsafe_ptr()
        for i in range(N):
            px[unsafe_offset=i] = fixed(arc.r.x, POS_BITS)
            py[unsafe_offset=i] = fixed(arc.r.y, POS_BITS)
            pz[unsafe_offset=i] = fixed(arc.r.z, POS_BITS)
            pvx[unsafe_offset=i] = fixed(arc.v.x, VEL_BITS)
            pvy[unsafe_offset=i] = fixed(arc.v.y, VEL_BITS)
            pvz[unsafe_offset=i] = fixed(arc.v.z, VEL_BITS)
    var kern = ctx.compile_function[propagate_kernel]()
    ctx.synchronize()
    var g0 = perf_counter_ns()
    ctx.enqueue_function(
        kern, rx, ry, rz, vx, vy, vz, st, tab,
        Int32(bodies.n), Float32(0.0), Float32(5.0 * 86400.0), Float32(1024.0), Int32(F_ALL), Int32(N),
        grid_dim=(N // 256), block_dim=(256),
    )
    ctx.synchronize()
    var g1 = perf_counter_ns()
    var gr = Vec3(0.0, 0.0, 0.0)
    with rx.map_to_host() as hx, ry.map_to_host() as hy, rz.map_to_host() as hz:
        gr = Vec3(unfixed(hx.unsafe_ptr()[unsafe_offset=0], POS_BITS), unfixed(hy.unsafe_ptr()[unsafe_offset=0], POS_BITS), unfixed(hz.unsafe_ptr()[unsafe_offset=0], POS_BITS))
    print("  the same arc on the GPU, " + String(N) + " threads, Float32 on int64 fixed point: " + fmt(Float64(g1 - g0) / 1e6, 1) + " ms; " + fmt((gr - cpu.r).norm() * 1000.0, 0) + " m from the Float64 truth at the Moon")
    print()

    print("The transfer (MC2) — Apollo 11's TLI, re-planned")
    var tof = (loi - tli) * 86400.0
    var tb = Bodies(eph, jde_tli, 4.0)
    var planes = planes_through(32.52, tb.moon_at(tof).unit())
    var pad = site_position(28.6083, -80.6041, launch).unit()
    var normal = planes[0]
    if len(planes) == 2 and abs(planes[1].dot(pad)) < abs(planes[0].dot(pad)):
        normal = planes[1]
    print("  parking orbit 185 km, 32.52°, in the plane holding the Moon at LOI-1 -- which passes " + fmt(asin(normal.dot(pad)) * RAD, 2) + "° from the pad at 13:32 UTC")
    var z_moon = eph.moon_frame(jde_tli + tof / 86400.0).z
    var free = plan_transfer(eph, tb, normal, 185.0, tof, R_MOON + 111.0, True, 314.0)
    var fa = free.correction.arrival
    print("  in-plane burn:  " + fmt(free.dv_tli * 1000.0, 1) + " m/s -> perilune " + fmt(fa.r_p - R_MOON, 1) + " km, far side, at " + fmt(fa.t_p / 3600.0, 2) + " h; orbit " + fmt(acos(fa.rho.cross(fa.rho_dot).unit().dot(z_moon)) * RAD, 1) + "° to the lunar equator")
    var x0 = perf_counter_ns()
    var steered = plan_transfer_oriented(eph, tb, normal, 185.0, tof, R_MOON + 111.0, -z_moon, 314.0)
    var x1 = perf_counter_ns()
    var sa = steered.correction.arrival
    print("  steered burn:   " + fmt(steered.dv_tli * 1000.0, 1) + " m/s -> orbit " + fmt(acos(sa.rho.cross(sa.rho_dot).unit().dot(z_moon)) * RAD, 1) + "° to the lunar equator (retrograde); v∞ " + fmt(sa.v_inf * 1000.0, 0) + " m/s; LOI-1 into 111 × 314 km " + fmt(steered.loi_dv * 1000.0, 0) + " m/s; " + String(steered.correction.iterations) + " rounds, " + fmt(Float64(x1 - x0) / 1e6, 0) + " ms")
    print("  Apollo 11:      3 182 m/s over 347 s; LOI-1 889 m/s")
    print()

    print("The window map (MC3) — July 1969, Kennedy to Tranquility")
    var wm = WindowMap(eph, 1969, 7, launch_sites()[0], landing_sites()[0], 60.0, 120.0, 48, 480)
    var w0 = perf_counter_ns()
    compute_map(wm, ctx)
    var w1 = perf_counter_ns()
    var good = 0
    for i in range(wm.width * wm.height):
        var fl = Int(wm.cells[i * FIELDS + F_FLAGS])
        if fl & FLAG_CORRIDOR != 0 and fl & FLAG_LIT != 0 and fl & FLAG_RISING != 0:
            good += 1
    print("  " + String(wm.width * wm.height) + " launch candidates (day × hour × flight time) on the GPU in " + fmt(Float64(w1 - w0) / 1e6, 0) + " ms; " + String(good) + " in the corridor with the site lit at touchdown")
    var wins = corridor_windows(wm, 16, 73.0927 * 3600.0)
    for k in range(len(wins) // 4):
        var oh = Int(wins[k * 4])
        var om = Int((wins[k * 4] - Float64(oh)) * 60.0 + 0.5)
        var ch = Int(wins[k * 4 + 1])
        var cm = Int((wins[k * 4 + 1] - Float64(ch)) * 60.0 + 0.5)
        print("  16 July window " + String(k + 1) + ": " + String(oh) + ":" + (String("0") if om < 10 else String("")) + String(om) + " to " + String(ch) + ":" + (String("0") if cm < 10 else String("")) + String(cm) + " UTC, azimuth " + fmt(wins[k * 4 + 2], 1) + "° to " + fmt(wins[k * 4 + 3], 1) + "°")
    print("  Apollo 11 launched 13:32 UTC at 72.06°; its window closed about 17:54")
    var names = List[String]()
    names.append(String("Tranquility  "))
    names.append(String("Sinus Medii  "))
    names.append(String("Site 5       "))
    for k in range(3):
        var wk = WindowMap(eph, 1969, 7, launch_sites()[0], landing_sites()[k], 60.0, 120.0, 48, 480)
        var bands = lighting_bands(wk, 73.0927 * 3600.0)
        var line = String("  the Sun picks day")
        for i in range(len(bands)):
            line += " " + fmt(bands[i], 1)
        print(line + " for " + names[k] + "(NASA planned the " + (String("16th") if k == 0 else (String("18th") if k == 1 else String("21st"))) + ")")
    var ax = wm.x_of(16, 73.0927)
    var ay = wm.y_of(13.0 + 32.0 / 60.0)
    var png = String("/tmp/moonshot-window-1969-07.png")
    if save_map(wm, png, ax, ay):
        print("  map saved: " + png + " (white cross: Apollo 11's launch minute)")
    print()
    print("Moonshot checks done")
