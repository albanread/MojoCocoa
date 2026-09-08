# ===----------------------------------------------------------------------=== #
# Moonshot — the dispersion cloud (sprint MC6).
#
# "Will the crew make it" is not a number the plan can give: the plan is
# one trajectory, and the crew fly one with the burn a little hot and the
# platform a little off. What the trench can give is a probability, and
# this is how: sixteen thousand copies of the plan, each with the errors
# real hardware has (design §6), each flown to the Moon by the same
# integrator the plan was made with, each reporting where beside the
# Moon it arrived. The spread is the answer; the fraction inside the LOI
# corridor is the number on the screen.
#
# The errors are drawn on the host from one seeded generator, so a cloud
# is reproducible and so the mission's own draws come from the same
# source. The GPU does only what it is good at: the flying. Each thread
# runs the fixed-point Float32 integrator of `orbit.mojo` step by step
# and watches ρ⃗·ρ̇, the Moon-relative radial speed; the step where it
# turns positive inside the sphere of influence is perilune, refined by
# the crossing's linear interpolation and one short re-step from the
# previous state -- the same idea `transfer.arrival` uses on the CPU.
# ===----------------------------------------------------------------------=== #

from std.gpu import global_idx
from std.math import sqrt, log, cos, sin, acos
from max.gpu.host import DeviceContext
from astro import Vec3, Ephemeris, MU_MOON, R_MOON, MOON_SOI, DEG, RAD, fmt
from orbit import (
    Bodies, RVd, State, Acc, Sky, bodies_at, step_size, rk4_step, POS_BITS, VEL_BITS,
    fixed, unfixed, F_ALL, TABLE_STRIDE,
)
from transfer import b_plane, Arrival

# ── the error models, design §6 ──────────────────────────────────────────

comptime TLI_MAG_SIGMA = 0.0005
"""Fraction of the burn's Δv: the S-IVB's cutoff accuracy."""
comptime TLI_POINT_SIGMA = 0.03
"""Degrees: the platform's alignment."""
comptime TRACK_POS_SIGMA = 1.0
"""km, the state estimate's position error at the start of an arc."""
comptime TRACK_VEL_SIGMA = 0.0001
"""km/s (0.1 m/s), its velocity error."""
comptime MCC_MAG_SIGMA = 0.02
"""Fraction of a small SPS burn's Δv."""
comptime MCC_POINT_SIGMA = 0.5
"""Degrees, a small burn's pointing."""
comptime PROP_SIGMA = 0.005
"""Fraction of a stage's load."""
comptime CORRIDOR_LO = 60.0
"""km of perilune altitude: below this LOI is unsafe."""
comptime CORRIDOR_HI = 200.0
"""km: above this LOI costs more than the SPS has."""

comptime CLOUD_FIELDS = 8  # t_p, rho xyz, rho_dot xyz, flag


struct Rng(Movable):
    """xorshift64*, seeded; uniform in [0, 1) and standard normal draws.
    One instance per mission, so the seed on the debrief is the whole
    story."""

    var state: UInt64
    var spare: Float64
    var has_spare: Bool

    def __init__(out self, seed: UInt64):
        self.state = seed * 0x9E3779B97F4A7C15 + 0x2545F4914F6CDD1D
        if self.state == 0:
            self.state = 0x2545F4914F6CDD1D
        self.spare = 0.0
        self.has_spare = False

    def next(mut self) -> Float64:
        self.state ^= self.state >> 12
        self.state ^= self.state << 25
        self.state ^= self.state >> 27
        var x = self.state * 2685821657736338717
        return Float64(x >> 11) / Float64(1 << 53)

    def gauss(mut self) -> Float64:
        """Box–Muller, one of each pair kept for the next call."""
        if self.has_spare:
            self.has_spare = False
            return self.spare
        var u1 = self.next()
        while u1 < 1e-300:
            u1 = self.next()
        var u2 = self.next()
        var m = sqrt(-2.0 * log(u1))
        self.spare = m * sin(6.283185307179586 * u2)
        self.has_spare = True
        return m * cos(6.283185307179586 * u2)


def perturb_burn(mut rng: Rng, dv: Vec3, mag_sigma: Float64, point_sigma_deg: Float64) -> Vec3:
    """A burn as it comes out: the magnitude off by a fraction, the
    direction off by two small angles about axes perpendicular to it."""
    var n = dv.norm()
    if n == 0.0:
        return dv
    var d = dv * (1.0 / n)
    var a = Vec3(0.0, 0.0, 1.0)
    if abs(d.z) > 0.9:
        a = Vec3(1.0, 0.0, 0.0)
    var e1 = d.cross(a).unit()
    var e2 = d.cross(e1)
    var t1 = rng.gauss() * point_sigma_deg * DEG
    var t2 = rng.gauss() * point_sigma_deg * DEG
    var dir = (d + e1 * t1 + e2 * t2).unit()
    return dir * (n * (1.0 + rng.gauss() * mag_sigma))


def perturb_state(mut rng: Rng, r: Vec3, v: Vec3, pos_sigma: Float64, vel_sigma: Float64) -> RVd:
    """A state as tracking knows it: isotropic errors."""
    return RVd(
        Vec3(r.x + rng.gauss() * pos_sigma, r.y + rng.gauss() * pos_sigma, r.z + rng.gauss() * pos_sigma),
        Vec3(v.x + rng.gauss() * vel_sigma, v.y + rng.gauss() * vel_sigma, v.z + rng.gauss() * vel_sigma),
    )


# ── the kernel ───────────────────────────────────────────────────────────


def cloud_kernel(
    rx: Pointer[Int64, MutAnyOrigin],
    ry: Pointer[Int64, MutAnyOrigin],
    rz: Pointer[Int64, MutAnyOrigin],
    vx: Pointer[Int64, MutAnyOrigin],
    vy: Pointer[Int64, MutAnyOrigin],
    vz: Pointer[Int64, MutAnyOrigin],
    cells: Pointer[Float32, MutAnyOrigin],
    tab: Pointer[Int64, MutAnyOrigin],
    n_tab: Int32,
    t0: Float32,
    t_max: Float32,
    h_max: Float32,
    soi: Float32,
    count: Int32,
):
    """One thread, one copy of the plan, flown to its perilune."""
    var idx = Int(global_idx.x)
    if idx >= Int(count):
        return
    var n = Int(n_tab)
    var s = State[DType.float32](
        Acc[DType.float32, POS_BITS](SIMD[DType.int64, 4](rx[unsafe_offset=idx], ry[unsafe_offset=idx], rz[unsafe_offset=idx], 0)),
        Acc[DType.float32, VEL_BITS](SIMD[DType.int64, 4](vx[unsafe_offset=idx], vy[unsafe_offset=idx], vz[unsafe_offset=idx], 0)),
    )
    var t = t0
    var sky = bodies_at(tab, n, t)
    var rho = -sky.moon.minus(s.r)
    var rho_dot = s.v.narrow() - sky.moon_v
    var d_prev = (rho * rho_dot).reduce_add()
    var found = False
    var out_t = t
    var out_rho = rho
    var out_rd = rho_dot
    var steps = 0
    while t < t_max and steps < 60000:
        var h = step_size(s, sky, h_max)
        if t + h > t_max:
            h = t_max - t
        var s2 = rk4_step(s, t, h, tab, n, F_ALL)
        var t2 = t + h
        var sky2 = bodies_at(tab, n, t2)
        var rho2 = -sky2.moon.minus(s2.r)
        var rd2 = s2.v.narrow() - sky2.moon_v
        var d2 = (rho2 * rd2).reduce_add()
        var dist2 = (rho2 * rho2).reduce_add()
        if d_prev < Float32(0) and d2 >= Float32(0) and dist2 < soi * soi:
            # Perilune lies in this step: where ρ·ρ̇ crossed zero.
            var f = d_prev / (d_prev - d2)
            var hp = h * f
            var sp = rk4_step(s, t, hp, tab, n, F_ALL) if hp > Float32(0) else s
            var tp = t + hp
            var skyp = bodies_at(tab, n, tp)
            out_rho = -skyp.moon.minus(sp.r)
            out_rd = sp.v.narrow() - skyp.moon_v
            out_t = tp
            found = True
            break
        s = s2
        t = t2
        sky = sky2
        d_prev = d2
        out_rho = rho2
        out_rd = rd2
        out_t = t2
        steps += 1
    var k = idx * CLOUD_FIELDS
    cells[unsafe_offset=k] = out_t
    cells[unsafe_offset=k + 1] = out_rho[0]
    cells[unsafe_offset=k + 2] = out_rho[1]
    cells[unsafe_offset=k + 3] = out_rho[2]
    cells[unsafe_offset=k + 4] = out_rd[0]
    cells[unsafe_offset=k + 5] = out_rd[1]
    cells[unsafe_offset=k + 6] = out_rd[2]
    cells[unsafe_offset=k + 7] = Float32(1) if found else Float32(0)


# ── the host side ────────────────────────────────────────────────────────


struct CloudStats(ImplicitlyCopyable, Movable):
    """What a cloud tells the trench."""

    var n: Int
    var found: Int
    var p_corridor: Float64
    var mean_alt: Float64
    var sigma_alt: Float64
    var sigma_bt: Float64
    var sigma_br: Float64
    var sigma_t: Float64  # s
    var mean_vinf: Float64
    var millis: Float64

    def __init__(out self):
        self.n = 0
        self.found = 0
        self.p_corridor = 0.0
        self.mean_alt = 0.0
        self.sigma_alt = 0.0
        self.sigma_bt = 0.0
        self.sigma_br = 0.0
        self.sigma_t = 0.0
        self.mean_vinf = 0.0
        self.millis = 0.0


struct Cloud(Movable):
    """N perturbed states, flown on the GPU to their perilunes."""

    var n: Int
    var starts: List[Float64]  # 6 per sample: r, v at t0
    var results: List[Float32]  # CLOUD_FIELDS per sample
    var t0: Float64

    def __init__(out self, n: Int, t0: Float64):
        self.n = n
        self.starts = List[Float64](capacity=n * 6)
        self.results = List[Float32]()
        self.t0 = t0

    def add(mut self, r: Vec3, v: Vec3):
        self.starts.append(r.x)
        self.starts.append(r.y)
        self.starts.append(r.z)
        self.starts.append(v.x)
        self.starts.append(v.y)
        self.starts.append(v.z)

    def sample(self, i: Int) -> RVd:
        return RVd(
            Vec3(self.starts[i * 6], self.starts[i * 6 + 1], self.starts[i * 6 + 2]),
            Vec3(self.starts[i * 6 + 3], self.starts[i * 6 + 4], self.starts[i * 6 + 5]),
        )

    def perilune(self, i: Int) -> Arrival:
        """Sample i's arrival, from the kernel's Moon-relative state."""
        var k = i * CLOUD_FIELDS
        var rho = Vec3(Float64(self.results[k + 1]), Float64(self.results[k + 2]), Float64(self.results[k + 3]))
        var rd = Vec3(Float64(self.results[k + 4]), Float64(self.results[k + 5]), Float64(self.results[k + 6]))
        var a = b_plane(rho, rd, Vec3(0.0, 0.0, 1.0))
        a.t_p = Float64(self.results[k])
        return a

    def found(self, i: Int) -> Bool:
        return self.results[i * CLOUD_FIELDS + 7] > 0.5


def fly_cloud(mut cloud: Cloud, ctx: DeviceContext, bodies: Bodies, t_max: Float64) raises:
    """Every sample from cloud.t0 to its perilune (or t_max), on the GPU.
    Times are the table's seconds."""
    var n = cloud.n
    var rx = ctx.enqueue_create_buffer[DType.int64](n)
    var ry = ctx.enqueue_create_buffer[DType.int64](n)
    var rz = ctx.enqueue_create_buffer[DType.int64](n)
    var vx = ctx.enqueue_create_buffer[DType.int64](n)
    var vy = ctx.enqueue_create_buffer[DType.int64](n)
    var vz = ctx.enqueue_create_buffer[DType.int64](n)
    var out = ctx.enqueue_create_buffer[DType.float32](n * CLOUD_FIELDS)
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
        for i in range(n):
            px[unsafe_offset=i] = fixed(cloud.starts[i * 6], POS_BITS)
            py[unsafe_offset=i] = fixed(cloud.starts[i * 6 + 1], POS_BITS)
            pz[unsafe_offset=i] = fixed(cloud.starts[i * 6 + 2], POS_BITS)
            pvx[unsafe_offset=i] = fixed(cloud.starts[i * 6 + 3], VEL_BITS)
            pvy[unsafe_offset=i] = fixed(cloud.starts[i * 6 + 4], VEL_BITS)
            pvz[unsafe_offset=i] = fixed(cloud.starts[i * 6 + 5], VEL_BITS)
    var kern = ctx.compile_function[cloud_kernel]()
    ctx.enqueue_function(
        kern, rx, ry, rz, vx, vy, vz, out, tab,
        Int32(bodies.n), Float32(cloud.t0), Float32(t_max), Float32(1024.0), Float32(MOON_SOI), Int32(n),
        grid_dim=((n + 255) // 256), block_dim=(256),
    )
    ctx.synchronize()
    cloud.results = List[Float32](capacity=n * CLOUD_FIELDS)
    with out.map_to_host() as ho:
        var po = ho.unsafe_ptr()
        for i in range(n * CLOUD_FIELDS):
            cloud.results.append(po[unsafe_offset=i])


def cloud_stats(cloud: Cloud, moon_pole: Vec3) -> CloudStats:
    """The spread of a flown cloud: perilune altitude, B-plane, time."""
    var st = CloudStats()
    st.n = cloud.n
    var alts = List[Float64]()
    var bts = List[Float64]()
    var brs = List[Float64]()
    var ts = List[Float64]()
    var inside = 0
    var vsum = 0.0
    for i in range(cloud.n):
        if not cloud.found(i):
            continue
        var k = i * CLOUD_FIELDS
        var rho = Vec3(Float64(cloud.results[k + 1]), Float64(cloud.results[k + 2]), Float64(cloud.results[k + 3]))
        var rd = Vec3(Float64(cloud.results[k + 4]), Float64(cloud.results[k + 5]), Float64(cloud.results[k + 6]))
        var a = b_plane(rho, rd, moon_pole)
        var alt = a.r_p - R_MOON
        alts.append(alt)
        bts.append(a.bt)
        brs.append(a.br)
        ts.append(Float64(cloud.results[k]))
        vsum += a.v_inf
        if alt >= CORRIDOR_LO and alt <= CORRIDOR_HI:
            inside += 1
    st.found = len(alts)
    if st.found == 0:
        return st
    st.p_corridor = Float64(inside) / Float64(cloud.n)
    st.mean_vinf = vsum / Float64(st.found)
    var ma = 0.0
    var mbt = 0.0
    var mbr = 0.0
    var mt = 0.0
    for i in range(st.found):
        ma += alts[i]
        mbt += bts[i]
        mbr += brs[i]
        mt += ts[i]
    ma /= Float64(st.found)
    mbt /= Float64(st.found)
    mbr /= Float64(st.found)
    mt /= Float64(st.found)
    var va = 0.0
    var vbt = 0.0
    var vbr = 0.0
    var vt = 0.0
    for i in range(st.found):
        va += (alts[i] - ma) * (alts[i] - ma)
        vbt += (bts[i] - mbt) * (bts[i] - mbt)
        vbr += (brs[i] - mbr) * (brs[i] - mbr)
        vt += (ts[i] - mt) * (ts[i] - mt)
    var dn = Float64(st.found - 1) if st.found > 1 else 1.0
    st.mean_alt = ma
    st.sigma_alt = sqrt(va / dn)
    st.sigma_bt = sqrt(vbt / dn)
    st.sigma_br = sqrt(vbr / dn)
    st.sigma_t = sqrt(vt / dn)
    return st


def tli_cloud(mut rng: Rng, r_inj: Vec3, v_park: Vec3, v_tli: Vec3, n: Int) -> Cloud:
    """N copies of the injection, the first one exact, the rest with the
    S-IVB's errors."""
    var c = Cloud(n, 0.0)
    var dv = v_tli - v_park
    c.add(r_inj, v_tli)
    for _ in range(n - 1):
        c.add(r_inj, v_park + perturb_burn(rng, dv, TLI_MAG_SIGMA, TLI_POINT_SIGMA))
    return c^


def tracked_cloud(mut rng: Rng, r: Vec3, v: Vec3, t0: Float64, n: Int, pos_sigma: Float64, vel_sigma: Float64) -> Cloud:
    """N copies of a state as tracking knows it, the first exact: what is
    left to worry about after a correction."""
    var c = Cloud(n, t0)
    c.add(r, v)
    for _ in range(n - 1):
        var s = perturb_state(rng, r, v, pos_sigma, vel_sigma)
        c.add(s.r, s.v)
    return c^
