# ===----------------------------------------------------------------------=== #
# Moonshot — the 3D plot (sprint MC4).
#
# A perspective camera and a byte framebuffer, nothing else: the course is
# a polyline through the integrator's own samples, the bodies are discs
# shaded per pixel from the Sun's real direction, with a latitude and
# longitude grid so the Earth visibly turns and the Moon visibly faces.
# The CPU draws it in well under a millisecond, which is why there is no
# kernel here; the GPU's work in this project is the planning (design §1).
#
# Three frames, one function: the caller hands in points already
# expressed in the frame it wants -- Earth-centred inertial, Moon-centred,
# or rotating with the Earth–Moon line -- and this file projects them.
# `rotate_about` is the whole of the rotating frame.
# ===----------------------------------------------------------------------=== #

from std.math import sqrt, sin, cos, tan, atan2, asin
from std.memory import Pointer
from astro import Vec3, DEG, RAD

# ── the palette: who owns which indices ──────────────────────────────────

comptime C_BG = 0
comptime C_GRID = 1
comptime C_DIM = 2
comptime C_TEXT = 3
comptime C_WHITE = 4
comptime C_RED = 5
comptime C_AMBER = 6
comptime C_GREEN = 7
comptime C_EARTH0 = 8  # 32 shades
comptime C_MOON0 = 40  # 32 shades
comptime C_CYAN0 = 72  # 16: the planned course, depth-cued
comptime C_ORANGE0 = 88  # 16: the tracked course, later
comptime C_GREEN0 = 104  # 16: orbits
comptime C_MAGENTA0 = 120  # 16: markers
comptime C_MAP0 = 136  # the window map's colours: 16 corridor blues, 32 Δv ramp, then the flats
comptime C_MAP_DARK = 184
comptime C_MAP_BAD = 185
comptime C_MAP_MARK = 186
comptime SHADES = 32


def palette_rgb(i: Int) -> Vec3:
    """The colour of palette index i, as 0..255 components in a Vec3."""
    if i == C_BG:
        return Vec3(6.0, 8.0, 16.0)
    if i == C_GRID:
        return Vec3(34.0, 38.0, 52.0)
    if i == C_DIM:
        return Vec3(90.0, 96.0, 112.0)
    if i == C_TEXT:
        return Vec3(180.0, 190.0, 200.0)
    if i == C_WHITE:
        return Vec3(255.0, 255.0, 255.0)
    if i == C_RED:
        return Vec3(255.0, 70.0, 70.0)
    if i == C_AMBER:
        return Vec3(255.0, 190.0, 60.0)
    if i == C_GREEN:
        return Vec3(90.0, 230.0, 120.0)
    if i >= C_EARTH0 and i < C_EARTH0 + SHADES:
        var u = Float64(i - C_EARTH0) / Float64(SHADES - 1)
        return Vec3(20.0 + 60.0 * u, 40.0 + 120.0 * u, 70.0 + 185.0 * u)
    if i >= C_MOON0 and i < C_MOON0 + SHADES:
        var u = Float64(i - C_MOON0) / Float64(SHADES - 1)
        return Vec3(24.0 + 200.0 * u, 24.0 + 196.0 * u, 26.0 + 186.0 * u)
    if i >= C_CYAN0 and i < C_CYAN0 + 16:
        var u = 0.35 + 0.65 * Float64(i - C_CYAN0) / 15.0
        return Vec3(60.0 * u, 220.0 * u, 255.0 * u)
    if i >= C_ORANGE0 and i < C_ORANGE0 + 16:
        var u = 0.35 + 0.65 * Float64(i - C_ORANGE0) / 15.0
        return Vec3(255.0 * u, 170.0 * u, 50.0 * u)
    if i >= C_GREEN0 and i < C_GREEN0 + 16:
        var u = 0.3 + 0.7 * Float64(i - C_GREEN0) / 15.0
        return Vec3(70.0 * u, 200.0 * u, 110.0 * u)
    if i >= C_MAGENTA0 and i < C_MAGENTA0 + 16:
        var u = 0.4 + 0.6 * Float64(i - C_MAGENTA0) / 15.0
        return Vec3(255.0 * u, 80.0 * u, 200.0 * u)
    if i >= C_MAP0 and i < C_MAP0 + 16:
        var u = Float64(i - C_MAP0) / 15.0
        return Vec3(40.0 + 40.0 * u, 60.0 + 50.0 * u, 120.0 + 100.0 * u)
    if i >= C_MAP0 + 16 and i < C_MAP0 + 48:
        var u = Float64(i - C_MAP0 - 16) / 31.0
        var r = 255.0 * (u * 2.0 if u < 0.5 else 1.0)
        var g = 255.0 if u < 0.5 else 255.0 * (1.0 - (u - 0.5) * 2.0)
        return Vec3(r, g, 40.0)
    if i == C_MAP_DARK:
        return Vec3(18.0, 18.0, 26.0)
    if i == C_MAP_BAD:
        return Vec3(40.0, 10.0, 10.0)
    if i == C_MAP_MARK:
        return Vec3(255.0, 255.0, 255.0)
    return Vec3(0.0, 0.0, 0.0)


# ── the canvas ───────────────────────────────────────────────────────────


struct Canvas(Movable):
    """A rectangle of a byte framebuffer to draw into: rows `stride`
    apart, the drawable area `w × h` at `(x0, y0)`. Everything clips."""

    var px: Pointer[UInt8, MutUntrackedOrigin]
    var stride: Int
    var x0: Int
    var y0: Int
    var w: Int
    var h: Int

    def __init__(out self, px: Pointer[UInt8, MutUntrackedOrigin], stride: Int, x0: Int, y0: Int, w: Int, h: Int):
        self.px = px
        self.stride = stride
        self.x0 = x0
        self.y0 = y0
        self.w = w
        self.h = h

    def clear(self, index: Int):
        for y in range(self.h):
            var row = (self.y0 + y) * self.stride + self.x0
            for x in range(self.w):
                self.px[unsafe_offset=row + x] = UInt8(index)

    @always_inline
    def plot(self, x: Int, y: Int, index: Int):
        if x < 0 or y < 0 or x >= self.w or y >= self.h:
            return
        self.px[unsafe_offset=(self.y0 + y) * self.stride + self.x0 + x] = UInt8(index)

    def line(self, xa: Float64, ya: Float64, xb: Float64, yb: Float64, index: Int):
        """A line in canvas pixels, clipped to the canvas (Liang–Barsky),
        then Bresenham."""
        var x1 = xa
        var y1 = ya
        var x2 = xb
        var y2 = yb
        var dx = x2 - x1
        var dy = y2 - y1
        var t0 = 0.0
        var t1 = 1.0
        var p: List[Float64] = [-dx, dx, -dy, dy]
        var q: List[Float64] = [x1, Float64(self.w - 1) - x1, y1, Float64(self.h - 1) - y1]
        for k in range(4):
            if p[k] == 0.0:
                if q[k] < 0.0:
                    return
            else:
                var t = q[k] / p[k]
                if p[k] < 0.0:
                    if t > t1:
                        return
                    if t > t0:
                        t0 = t
                else:
                    if t < t0:
                        return
                    if t < t1:
                        t1 = t
        var cx1 = x1 + t0 * dx
        var cy1 = y1 + t0 * dy
        var cx2 = x1 + t1 * dx
        var cy2 = y1 + t1 * dy
        var ix1 = Int(cx1 + 0.5)
        var iy1 = Int(cy1 + 0.5)
        var ix2 = Int(cx2 + 0.5)
        var iy2 = Int(cy2 + 0.5)
        var adx = ix2 - ix1 if ix2 >= ix1 else ix1 - ix2
        var ady = iy2 - iy1 if iy2 >= iy1 else iy1 - iy2
        var sx = 1 if ix1 < ix2 else -1
        var sy = 1 if iy1 < iy2 else -1
        var err = adx - ady
        var x = ix1
        var y = iy1
        for _ in range(adx + ady + 1):
            self.plot(x, y, index)
            if x == ix2 and y == iy2:
                break
            var e2 = 2 * err
            if e2 > -ady:
                err -= ady
                x += sx
            if e2 < adx:
                err += adx
                y += sy

    def disc(self, cx: Float64, cy: Float64, r: Float64, index: Int):
        var ir = Int(r + 1.0)
        var icx = Int(cx + 0.5)
        var icy = Int(cy + 0.5)
        for y in range(icy - ir, icy + ir + 1):
            for x in range(icx - ir, icx + ir + 1):
                var dx = Float64(x) - cx
                var dy = Float64(y) - cy
                if dx * dx + dy * dy <= r * r:
                    self.plot(x, y, index)

    def box(self, x: Int, y: Int, w: Int, h: Int, index: Int):
        for i in range(w):
            self.plot(x + i, y, index)
            self.plot(x + i, y + h - 1, index)
        for j in range(h):
            self.plot(x, y + j, index)
            self.plot(x + w - 1, y + j, index)


# ── the camera ───────────────────────────────────────────────────────────


@fieldwise_init
struct Projected(ImplicitlyCopyable, Movable):
    var x: Float64  # canvas pixels
    var y: Float64
    var depth: Float64  # km along the view direction; behind the camera if ≤ 0
    var ok: Bool


struct Camera(ImplicitlyCopyable, Movable):
    """Orbits `centre` at `dist` km; yaw about the pole, pitch above the
    equator, both degrees; a vertical field of view."""

    var centre: Vec3
    var yaw: Float64
    var pitch: Float64
    var dist: Float64
    var fov: Float64
    var forward: Vec3
    var right: Vec3
    var up: Vec3
    var eye: Vec3

    def __init__(out self, centre: Vec3, yaw: Float64, pitch: Float64, dist: Float64, fov: Float64):
        self.centre = centre
        self.yaw = yaw
        self.pitch = pitch
        self.dist = dist
        self.fov = fov
        self.forward = Vec3(1.0, 0.0, 0.0)
        self.right = Vec3(0.0, 1.0, 0.0)
        self.up = Vec3(0.0, 0.0, 1.0)
        self.eye = Vec3(0.0, 0.0, 0.0)
        self.update()

    def update(mut self):
        var p = self.pitch
        if p > 89.0:
            p = 89.0
        if p < -89.0:
            p = -89.0
        self.pitch = p
        var back = Vec3(cos(p * DEG) * cos(self.yaw * DEG), cos(p * DEG) * sin(self.yaw * DEG), sin(p * DEG))
        self.eye = self.centre + back * self.dist
        self.forward = -back
        var pole = Vec3(0.0, 0.0, 1.0)
        self.right = self.forward.cross(pole).unit()
        self.up = self.right.cross(self.forward)

    def focal(self, h: Int) -> Float64:
        return Float64(h) * 0.5 / tan(self.fov * 0.5 * DEG)

    def project(self, p: Vec3, w: Int, h: Int) -> Projected:
        var q = p - self.eye
        var z = q.dot(self.forward)
        if z <= 1.0:
            return Projected(0.0, 0.0, z, False)
        var f = self.focal(h)
        return Projected(
            Float64(w) * 0.5 + f * q.dot(self.right) / z,
            Float64(h) * 0.5 - f * q.dot(self.up) / z,
            z,
            True,
        )


def rotate_about(p: Vec3, axis: Vec3, angle: Float64) -> Vec3:
    """Rodrigues: p turned by `angle` radians about the unit vector `axis`."""
    var c = cos(angle)
    var s = sin(angle)
    return p * c + axis.cross(p) * s + axis * (axis.dot(p) * (1.0 - c))


# ── drawing the world ────────────────────────────────────────────────────


def draw_polyline(
    canvas: Canvas,
    cam: Camera,
    pts: List[Float64],
    stride: Int,
    offset: Int,
    base: Int,
    shades: Int,
):
    """Segments between consecutive points (x, y, z at `offset` within
    each `stride`-long record), depth-cued: nearer the camera, brighter.
    A segment with an endpoint behind the camera is skipped."""
    var n = len(pts) // stride
    var prev = Projected(0.0, 0.0, 0.0, False)
    for i in range(n):
        var p = Vec3(pts[i * stride + offset], pts[i * stride + offset + 1], pts[i * stride + offset + 2])
        var cur = cam.project(p, canvas.w, canvas.h)
        if i > 0 and cur.ok and prev.ok:
            var u = (cam.dist - 0.5 * (cur.depth + prev.depth)) / cam.dist
            u = 0.5 + 0.5 * u
            u = 0.0 if u < 0.0 else (1.0 if u > 1.0 else u)
            canvas.line(prev.x, prev.y, cur.x, cur.y, base + Int(u * Float64(shades - 1)))
        prev = cur


def draw_body(
    canvas: Canvas,
    cam: Camera,
    centre: Vec3,
    radius: Float64,
    sun: Vec3,
    bx: Vec3,
    by: Vec3,
    bz: Vec3,
    base: Int,
):
    """A sphere: per pixel of its disc, the surface normal, its lighting
    from the unit vector `sun` (from the body toward the Sun), and a grid
    every 30° of latitude and longitude in the body frame (bx, by, bz).
    Too small to shade, it is a dot."""
    var c = cam.project(centre, canvas.w, canvas.h)
    if not c.ok:
        return
    var rpx = radius * cam.focal(canvas.h) / c.depth
    if rpx < 1.5:
        canvas.plot(Int(c.x + 0.5), Int(c.y + 0.5), base + SHADES - 1)
        canvas.plot(Int(c.x + 0.5) + 1, Int(c.y + 0.5), base + SHADES - 1)
        canvas.plot(Int(c.x + 0.5), Int(c.y + 0.5) + 1, base + SHADES - 1)
        canvas.plot(Int(c.x + 0.5) + 1, Int(c.y + 0.5) + 1, base + SHADES - 1)
        return
    var ir = Int(rpx) + 1
    var icx = Int(c.x + 0.5)
    var icy = Int(c.y + 0.5)
    var toward = -cam.forward
    for y in range(icy - ir, icy + ir + 1):
        if y < 0 or y >= canvas.h:
            continue
        for x in range(icx - ir, icx + ir + 1):
            if x < 0 or x >= canvas.w:
                continue
            var dx = (Float64(x) - c.x) / rpx
            var dy = (c.y - Float64(y)) / rpx
            var d2 = dx * dx + dy * dy
            if d2 > 1.0:
                continue
            var nz = sqrt(1.0 - d2)
            var n = cam.right * dx + cam.up * dy + toward * nz
            var light = n.dot(sun)
            var shade = 0.12 + 0.88 * (light if light > 0.0 else 0.0)
            var lon = atan2(n.dot(by), n.dot(bx)) * RAD
            var lat = asin(n.dot(bz)) * RAD
            var lonm = lon - 30.0 * Float64(Int((lon + 720.0) / 30.0) - 24)
            var latm = lat - 30.0 * Float64(Int((lat + 720.0) / 30.0) - 24)
            var on_grid = (lonm < 1.5 or lonm > 28.5) or (latm < 1.5 or latm > 28.5)
            var idx = Int(shade * Float64(SHADES - 1))
            if on_grid and rpx > 12.0:
                idx += 5
            if idx > SHADES - 1:
                idx = SHADES - 1
            canvas.plot(x, y, base + idx)


def body_point(cam: Camera, centre: Vec3, radius: Float64, dir: Vec3, w: Int, h: Int) -> Projected:
    """Where a point on a body's surface lands, and whether it faces the
    camera at all."""
    var p = cam.project(centre + dir * radius, w, h)
    if dir.dot(-cam.forward) <= 0.0:
        p.ok = False
    return p
