# ===----------------------------------------------------------------------=== #
# Step 1 of the fluid spike: the solver, headless.
#
# Stable Fluids (Jos Stam, SIGGRAPH 1999) on the GPU, every kernel in Mojo.
# No window, no Cocoa -- just the physics, stepped a fixed number of times
# with diagnostics printed, so the kernels are proven before anything is
# asked to draw them.
#
# Why this demo and not another pretty picture: mandelbrot is ONE dispatch per
# frame and life is none, so neither says anything about launch cost. A stable
# fluids step is ~38 dependent dispatches -- advect three dye channels and the
# velocity, take the divergence, run 30 Jacobi iterations on the pressure,
# subtract its gradient, shade. At the measured 0.40 ms per synchronous
# dispatch that is ~15 ms of pure round-trip in a 16 ms frame budget, which is
# the difference between 60 fps and 30. Queued, command-buffer-batched launch
# is now the default; APPLEGPU_SYNC_LAUNCH=1 restores the bring-up behaviour.
#
# The physics, in one paragraph: velocity is advected along itself by tracing
# each cell backwards through the field and sampling where it came from
# (unconditionally stable, which is the point of the method), then made
# divergence-free by solving a Poisson equation for pressure and subtracting
# its gradient. Dye is passive -- it rides the corrected velocity and does not
# affect it.
# ===----------------------------------------------------------------------=== #

from std.gpu import global_idx
from max.gpu.host import DeviceContext
from std.time import perf_counter_ns

comptime W = 320
comptime H = 240
comptime N = W * H

comptime DT = Float32(0.125)
comptime JACOBI_ITERS = 30
comptime DISSIPATION = Float32(0.999)  # dye fades slowly, so it never saturates

comptime BLOCK = 256
comptime GRID = (N + BLOCK - 1) // BLOCK

comptime F32 = Pointer[Float32, MutAnyOrigin]
# `map_to_host` hands back an untracked-origin pointer, which is a different
# type from the device-side one even though it addresses the same floats.
comptime F32H = Pointer[Float32, MutUntrackedOrigin]


# ===----------------------------------------------------------------------=== #
# Sampling helpers. Shared by every kernel, so the boundary rule is stated
# once: clamp. A clamped sample at the wall means fluid slides along it rather
# than leaking through, which is free-slip and is all this demo needs.
# ===----------------------------------------------------------------------=== #


@always_inline
def _clampi(v: Int, lo: Int, hi: Int) -> Int:
    if v < lo:
        return lo
    if v > hi:
        return hi
    return v


@always_inline
def _at(f: F32, x: Int, y: Int) -> Float32:
    return f[unsafe_offset=_clampi(y, 0, H - 1) * W + _clampi(x, 0, W - 1)]


@always_inline
def _bilinear(f: F32, x: Float32, y: Float32) -> Float32:
    """Sample `f` at a fractional position, clamped at the edges."""
    var x0 = Int(x)
    var y0 = Int(y)
    if x < Float32(0):
        x0 = Int(x) - 1
    if y < Float32(0):
        y0 = Int(y) - 1
    var fx = x - Float32(x0)
    var fy = y - Float32(y0)
    var a = _at(f, x0, y0)
    var b = _at(f, x0 + 1, y0)
    var c = _at(f, x0, y0 + 1)
    var d = _at(f, x0 + 1, y0 + 1)
    var top = a + (b - a) * fx
    var bot = c + (d - c) * fx
    return top + (bot - top) * fy


# ===----------------------------------------------------------------------=== #
# Kernels
# ===----------------------------------------------------------------------=== #


def advect_kernel(
    dst: F32, src: F32, u: F32, v: F32, dt: Float32, dissipation: Float32
):
    """Semi-Lagrangian advection: where did the stuff in this cell come from?"""
    var idx = Int(global_idx.x)
    if idx < N:
        var x = idx % W
        var y = idx // W
        # Trace backwards down the velocity field, in cells per step.
        var px = Float32(x) - dt * u[unsafe_offset=idx]
        var py = Float32(y) - dt * v[unsafe_offset=idx]
        dst[unsafe_offset=idx] = _bilinear(src, px, py) * dissipation


def divergence_kernel(div: F32, u: F32, v: F32):
    """How much is flowing out of each cell -- what the pressure must cancel."""
    var idx = Int(global_idx.x)
    if idx < N:
        var x = idx % W
        var y = idx // W
        var du = _at(u, x + 1, y) - _at(u, x - 1, y)
        var dv = _at(v, x, y + 1) - _at(v, x, y - 1)
        div[unsafe_offset=idx] = Float32(0.5) * (du + dv)


def jacobi_kernel(p_next: F32, p: F32, div: F32):
    """One Jacobi sweep of the pressure Poisson equation.

    Ping-ponged rather than done in place: a Jacobi iteration reads the whole
    neighbourhood of the PREVIOUS iterate, and updating in place would feed
    half-new values back in and quietly turn this into Gauss-Seidel with a
    thread-order-dependent result.
    """
    var idx = Int(global_idx.x)
    if idx < N:
        var x = idx % W
        var y = idx // W
        var s = (
            _at(p, x - 1, y)
            + _at(p, x + 1, y)
            + _at(p, x, y - 1)
            + _at(p, x, y + 1)
        )
        p_next[unsafe_offset=idx] = (s - div[unsafe_offset=idx]) * Float32(0.25)


def project_kernel(u: F32, v: F32, p: F32):
    """Subtract the pressure gradient, leaving a divergence-free field."""
    var idx = Int(global_idx.x)
    if idx < N:
        var x = idx % W
        var y = idx // W
        u[unsafe_offset=idx] -= Float32(0.5) * (
            _at(p, x + 1, y) - _at(p, x - 1, y)
        )
        v[unsafe_offset=idx] -= Float32(0.5) * (
            _at(p, x, y + 1) - _at(p, x, y - 1)
        )


def splat_kernel(
    field: F32,
    cx: Float32,
    cy: Float32,
    radius: Float32,
    amount: Float32,
):
    """Add a soft Gaussian blob -- the mouse, or a starting puff."""
    var idx = Int(global_idx.x)
    if idx < N:
        var x = Float32(idx % W)
        var y = Float32(idx // W)
        var dx = x - cx
        var dy = y - cy
        var d2 = dx * dx + dy * dy
        var r2 = radius * radius
        if d2 < r2 * Float32(9.0):
            var falloff = _expf(-d2 / r2)
            field[unsafe_offset=idx] += amount * falloff


@always_inline
def _expf(x: Float32) -> Float32:
    """exp for the splat falloff.

    Written out rather than imported so this file has no math dependency and
    the same code compiles for host and device. Range here is only [-9, 0].
    """
    var t = x
    if t < Float32(-20.0):
        return Float32(0)
    # exp(t) = 2^(t/ln2), split into integer and fractional parts.
    var k = t * Float32(1.44269504)  # 1/ln 2
    var ki = Float32(Int(k) - (1 if k < Float32(0) else 0))
    var f = (k - ki) * Float32(0.69314718)  # ln 2 * fractional part
    # 5-term Taylor on the remaining |f| < ln2.
    var poly = Float32(1) + f * (
        Float32(1)
        + f
        * (
            Float32(0.5)
            + f * (Float32(0.16666667) + f * Float32(0.04166667))
        )
    )
    var n = Int(ki)
    var scale = Float32(1)
    var i = 0
    while i < -n:
        scale *= Float32(0.5)
        i += 1
    return poly * scale


comptime SCALE = 3
comptime WIN_W = W * SCALE
comptime WIN_H = H * SCALE
comptime PIXELS = WIN_W * WIN_H
comptime PIX_GRID = (PIXELS + BLOCK - 1) // BLOCK
comptime U32 = Pointer[UInt32, MutAnyOrigin]


def render_kernel(dst: U32, dye: F32):
    """Magnify the dye field to window size as packed BGRA8.

    The same kernel `fluid.mojo` presents, exercised here so a smoke run
    proves the magnification, the tone-map and the byte packing -- not just
    the physics. A render bug otherwise only shows up as a black window, which
    looks identical to a dead solver.
    """
    var idx = Int(global_idx.x)
    if idx < PIXELS:
        var sx = Float32(idx % WIN_W) / Float32(SCALE)
        var sy = Float32(idx // WIN_W) / Float32(SCALE)
        var d = _bilinear(dye, sx, sy)
        d = d / (Float32(1) + d)
        var c = UInt32(Int(d * Float32(255.0)))
        dst[unsafe_offset=idx] = c | (c << 8) | (c << 16) | (UInt32(255) << 24)


# ===----------------------------------------------------------------------=== #
# Diagnostics: reductions done on the host, because this file exists to check
# the kernels, not to be fast.
# ===----------------------------------------------------------------------=== #


def _stats(p: F32H) -> Tuple[Float32, Float32, Float32]:
    """(min, max, sum) over the grid, on the host.

    Takes a plain pointer rather than the buffer so the caller owns the
    `map_to_host` scope -- naming the device buffer type here buys nothing and
    ties this helper to one.
    """
    var lo = Float32(1.0e30)
    var hi = Float32(-1.0e30)
    var total = Float32(0)
    for i in range(N):
        var x = p[unsafe_offset=i]
        if x < lo:
            lo = x
        if x > hi:
            hi = x
        total += x
    return (lo, hi, total)


def main() raises:
    print("Stable Fluids —", W, "x", H, "  (", N, "cells )")

    var ctx = DeviceContext(api="metal")
    print("  GPU:", ctx.name())

    var u = ctx.enqueue_create_buffer[DType.float32](N)
    var v = ctx.enqueue_create_buffer[DType.float32](N)
    var u0 = ctx.enqueue_create_buffer[DType.float32](N)
    var v0 = ctx.enqueue_create_buffer[DType.float32](N)
    var dye = ctx.enqueue_create_buffer[DType.float32](N)
    var dye0 = ctx.enqueue_create_buffer[DType.float32](N)
    var div = ctx.enqueue_create_buffer[DType.float32](N)
    var p = ctx.enqueue_create_buffer[DType.float32](N)
    var p0 = ctx.enqueue_create_buffer[DType.float32](N)

    ctx.enqueue_memset(u, Float32(0))
    ctx.enqueue_memset(v, Float32(0))
    ctx.enqueue_memset(dye, Float32(0))
    ctx.enqueue_memset(p, Float32(0))
    ctx.synchronize()

    var advect = ctx.compile_function[advect_kernel]()
    var diverge = ctx.compile_function[divergence_kernel]()
    var jacobi = ctx.compile_function[jacobi_kernel]()
    var project = ctx.compile_function[project_kernel]()
    var splat = ctx.compile_function[splat_kernel]()

    # A puff of dye and a rightward shove, off-centre so it curls.
    ctx.enqueue_function(
        splat, dye, Float32(W // 4), Float32(H // 2), Float32(14), Float32(1.0),
        grid_dim=(GRID), block_dim=(BLOCK),
    )
    ctx.enqueue_function(
        splat, u, Float32(W // 4), Float32(H // 2 - 8), Float32(14), Float32(9.0),
        grid_dim=(GRID), block_dim=(BLOCK),
    )
    ctx.enqueue_function(
        splat, v, Float32(W // 4), Float32(H // 2 - 8), Float32(14), Float32(3.0),
        grid_dim=(GRID), block_dim=(BLOCK),
    )
    ctx.synchronize()

    var s0: Tuple[Float32, Float32, Float32]
    with dye.map_to_host() as h:
        s0 = _stats(h.unsafe_ptr())
    print("  seeded dye: min", s0[0], " max", s0[1], " sum", s0[2])

    var dispatches = 0
    var t0 = perf_counter_ns()
    for step in range(60):
        # --- advect velocity along itself -----------------------------------
        ctx.enqueue_function(
            advect, u0, u, u, v, DT, Float32(1.0),
            grid_dim=(GRID), block_dim=(BLOCK),
        )
        ctx.enqueue_function(
            advect, v0, v, u, v, DT, Float32(1.0),
            grid_dim=(GRID), block_dim=(BLOCK),
        )
        dispatches += 2

        # --- make it divergence-free ----------------------------------------
        ctx.enqueue_function(
            diverge, div, u0, v0, grid_dim=(GRID), block_dim=(BLOCK)
        )
        ctx.enqueue_memset(p, Float32(0))
        dispatches += 1
        for it in range(JACOBI_ITERS // 2):
            ctx.enqueue_function(
                jacobi, p0, p, div, grid_dim=(GRID), block_dim=(BLOCK)
            )
            ctx.enqueue_function(
                jacobi, p, p0, div, grid_dim=(GRID), block_dim=(BLOCK)
            )
            dispatches += 2
        ctx.enqueue_function(
            project, u0, v0, p, grid_dim=(GRID), block_dim=(BLOCK)
        )
        dispatches += 1

        # --- carry the dye on the corrected field ---------------------------
        ctx.enqueue_function(
            advect, dye0, dye, u0, v0, DT, DISSIPATION,
            grid_dim=(GRID), block_dim=(BLOCK),
        )
        dispatches += 1

        # swap: the scratch buffers are now the current state
        ctx.enqueue_copy(u, u0)
        ctx.enqueue_copy(v, v0)
        ctx.enqueue_copy(dye, dye0)
        ctx.synchronize()

    var t1 = perf_counter_ns()
    var ms = Float64(t1 - t0) / 1e6

    var s1: Tuple[Float32, Float32, Float32]
    var uv: Tuple[Float32, Float32, Float32]
    var dv: Tuple[Float32, Float32, Float32]
    with dye.map_to_host() as h:
        s1 = _stats(h.unsafe_ptr())
    with u.map_to_host() as h:
        uv = _stats(h.unsafe_ptr())
    with div.map_to_host() as h:
        dv = _stats(h.unsafe_ptr())

    print("  60 steps in", ms, "ms  (", ms / 60.0, "ms/step,",
          dispatches // 60, "dispatches/step )")
    print("  dye:  min", s1[0], " max", s1[1], " sum", s1[2])
    print("  u:    min", uv[0], " max", uv[1])
    print("  div:  min", dv[0], " max", dv[1], "  (should be near zero)")

    # The checks that would actually catch a broken kernel.
    if s1[2] <= Float32(0):
        raise Error("dye vanished entirely — advection or the splat is broken")
    if s1[1] > Float32(100):
        raise Error("dye blew up — advection is unstable, check the backtrace")
    if uv[1] == Float32(0) and uv[0] == Float32(0):
        raise Error("velocity is identically zero — the splat never landed")

    # Render the final state and write it out, so the image can be looked at
    # rather than inferred from three numbers.
    var shade = ctx.compile_function[render_kernel]()
    var frame = ctx.enqueue_create_buffer[DType.uint32](PIXELS)
    ctx.enqueue_function(shade, frame, dye, grid_dim=(PIX_GRID), block_dim=(BLOCK))
    ctx.synchronize()

    var nonzero = 0
    var out = String("P3\n") + String(WIN_W) + " " + String(WIN_H) + "\n255\n"
    with frame.map_to_host() as h:
        var q = h.unsafe_ptr()
        for i in range(PIXELS):
            var px = q[unsafe_offset=i]
            if (px & UInt32(0xFFFFFF)) != UInt32(0):
                nonzero += 1
            var r = Int((px >> 16) & UInt32(255))
            var g = Int((px >> 8) & UInt32(255))
            var b = Int(px & UInt32(255))
            out += String(r) + " " + String(g) + " " + String(b) + "\n"
    with open("/tmp/fluid_frame.ppm", "w") as f:
        f.write(out)
    print("  rendered", WIN_W, "x", WIN_H, "—", nonzero, "non-black pixels"
          " -> /tmp/fluid_frame.ppm")
    if nonzero == 0:
        raise Error("render produced an entirely black frame")
    print("  ok")
