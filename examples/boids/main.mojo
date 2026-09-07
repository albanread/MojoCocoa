# ===----------------------------------------------------------------------=== #
# Boids — a flock, every bird computed on the Apple GPU. Three rules, and
# nothing else: steer away from whoever is too close, steer toward the
# average heading of whoever is near, steer toward the average position of
# whoever is near. No bird knows it is in a flock, and no bird is told to
# stay near the others -- the murmuration is what those three local rules
# look like from far enough away.
#
# `grayscott` was a field talking to itself. `physarum` was agents talking
# THROUGH a shared field -- an agent never senses another agent directly,
# only the trail it left. This is the third shape: agents sensing each
# OTHER, directly, with no field between them at all. That difference is
# also why it needs a discipline the other two didn't: a boid's update
# reads every OTHER boid's position and velocity, so updating in place
# would let boid 400's new position leak into boid 50's read of it purely
# by scheduling luck. Position and velocity are ping-ponged instead --
# `grayscott`'s u/v pair, applied to a flock instead of a chemical field --
# so every boid this frame sees the SAME frozen instant of everyone else.
#
#   hold      the flock steers toward the cursor while the button is down
#   1-4       jump to a named flocking character, live
#   r         reseed every boid at a fresh random position
#   space     pause
#   s         save the current frame as a PNG
#   q / esc   quit, as does closing the window
#
# BOIDS_FRAMES=N renders N frames and exits, unfocused, exactly like
# MANDEL_FRAMES, GRAYSCOTT_FRAMES and PHYSARUM_FRAMES.
# ===----------------------------------------------------------------------=== #

from std.gpu import global_idx
from std.math import cos, sin, sqrt
from max.gpu.host import DeviceContext
from std.time import perf_counter_ns
from std.os import getenv
from std.objc import (
    load_framework,
    Cls,
    Obj,
    ObjCObject,
    send,
    nsenum,
    nsstring,
    ns_to_string,
    autoreleasepool,
    named_global,
    CGPoint,
    CGSize,
    CGRect,
    MTLOrigin,
    MTLSize,
    MTLRegion,
    MTLClearColor,
)
from std.ffi import external_call, c_char
from std.memory import OpaquePointer, Pointer

comptime P = OpaquePointer[MutUntrackedOrigin]

comptime WIDTH = 768
comptime HEIGHT = 768
comptime CELLS = WIDTH * HEIGHT
comptime BOIDS = 2500

comptime BLOCK = 256
comptime GRID = (CELLS + BLOCK - 1) // BLOCK
comptime BOID_GRID = (BOIDS + BLOCK - 1) // BLOCK

comptime TAU = Float32(6.28318530718)
comptime GLOW_DECAY = Float32(0.90)
comptime SPLAT_BRIGHT = Float32(0.9)
comptime MAX_SPEED = Float32(3.4)
comptime MIN_SPEED = Float32(1.1)

# ── the parameter map ────────────────────────────────────────────────────
#
# Like Physarum and unlike Gray-Scott, there is no narrow sweet spot here
# either -- these four are this file's own tuning, named for the character
# they give the flock rather than looked up from a source.

comptime PRESET_COUNT = 4


def preset_name(i: Int) -> String:
    if i == 0:
        return String("flock")
    if i == 1:
        return String("swarm")
    if i == 2:
        return String("school")
    return String("scatter")


def preset_align(i: Int) -> Float32:
    if i == 0:
        return Float32(0.06)
    if i == 1:
        return Float32(0.02)
    if i == 2:
        return Float32(0.10)
    return Float32(0.01)


def preset_cohesion(i: Int) -> Float32:
    if i == 0:
        return Float32(0.0020)
    if i == 1:
        return Float32(0.0060)
    if i == 2:
        return Float32(0.0035)
    return Float32(0.0006)


def preset_separation(i: Int) -> Float32:
    if i == 0:
        return Float32(0.9)
    if i == 1:
        return Float32(0.5)
    if i == 2:
        return Float32(1.4)
    return Float32(2.2)


def preset_neighbor_r(i: Int) -> Float32:
    if i == 0:
        return Float32(46.0)
    if i == 1:
        return Float32(70.0)
    if i == 2:
        return Float32(34.0)
    return Float32(46.0)


# ===----------------------------------------------------------------------=== #
# A tiny integer hash for GPU-side scatter seeding -- `physarum`'s own,
# copied rather than shared (example folders are self-contained).
# ===----------------------------------------------------------------------=== #


@always_inline
def _hash_u32(x: UInt32) -> UInt32:
    var h = x
    h = (h ^ UInt32(61)) ^ (h >> UInt32(16))
    h = h + (h << UInt32(3))
    h = h ^ (h >> UInt32(4))
    h = h * UInt32(0x27D4EB2D)
    h = h ^ (h >> UInt32(15))
    return h


@always_inline
def _rand01(seed: UInt32) -> Float32:
    return Float32(_hash_u32(seed) & UInt32(0xFFFFFF)) / Float32(0xFFFFFF)


@always_inline
def _wrap(v: Int, n: Int) -> Int:
    var r = v % n
    if r < 0:
        r += n
    return r


def init_boids_kernel(
    px: Pointer[Float32, MutAnyOrigin],
    py: Pointer[Float32, MutAnyOrigin],
    vx: Pointer[Float32, MutAnyOrigin],
    vy: Pointer[Float32, MutAnyOrigin],
):
    """Scatter every boid to a random position with a random small
    velocity, hashing its own index rather than needing a host-side
    random call before the first frame can run."""
    var i = Int(global_idx.x)
    if i < BOIDS:
        var rx = _rand01(UInt32(i) * UInt32(2654435761) + UInt32(1))
        var ry = _rand01(UInt32(i) * UInt32(2246822519) + UInt32(2))
        var ra = _rand01(UInt32(i) * UInt32(3266489917) + UInt32(3))
        px[unsafe_offset=i] = rx * Float32(WIDTH)
        py[unsafe_offset=i] = ry * Float32(HEIGHT)
        vx[unsafe_offset=i] = cos(ra * TAU) * Float32(1.5)
        vy[unsafe_offset=i] = sin(ra * TAU) * Float32(1.5)


def boid_kernel(
    px_out: Pointer[Float32, MutAnyOrigin],
    py_out: Pointer[Float32, MutAnyOrigin],
    vx_out: Pointer[Float32, MutAnyOrigin],
    vy_out: Pointer[Float32, MutAnyOrigin],
    px_in: Pointer[Float32, MutAnyOrigin],
    py_in: Pointer[Float32, MutAnyOrigin],
    vx_in: Pointer[Float32, MutAnyOrigin],
    vy_in: Pointer[Float32, MutAnyOrigin],
    neighbor_r: Float32,
    align_w: Float32,
    cohesion_w: Float32,
    separation_w: Float32,
    seek_w: Float32,
    target_x: Float32,
    target_y: Float32,
):
    """Every boid against every other boid -- brute force, on purpose.
    2,500 is a visual choice, not a performance ceiling: this GPU held
    60fps up to 12,000 boids (144 million pairs a frame) and was still
    doing 24fps at 20,000 (400 million pairs), so the honest limit is far
    above what ships here. Past a few thousand, the glowing trails stop
    reading as individual birds and fuse into a continuous flow-field
    texture -- striking in its own right, but no longer showing the thing
    this demo is FOR: three simple rules, and enough negative space to
    still see each one's trail and the small flocks it belongs to. The
    interesting, harder trick -- bucketing boids into a grid so each one
    only checks its own neighbourhood -- is the right answer for pushing
    PAST tens of thousands; at a few thousand it is a real optimisation
    with nothing yet to optimise.

    Reads ONLY the `_in` arrays and writes ONLY the `_out` ones -- see the
    file header for why that split, not an in-place update, is the whole
    point: every boid this frame has to see the same frozen instant of
    everyone else, the same discipline `grayscott` uses for its u/v pair.
    """
    var i = Int(global_idx.x)
    if i < BOIDS:
        var x = px_in[unsafe_offset=i]
        var y = py_in[unsafe_offset=i]
        var vx = vx_in[unsafe_offset=i]
        var vy = vy_in[unsafe_offset=i]
        var sep_r = neighbor_r * Float32(0.35)

        var avg_vx = Float32(0.0)
        var avg_vy = Float32(0.0)
        var avg_px = Float32(0.0)
        var avg_py = Float32(0.0)
        var sep_x = Float32(0.0)
        var sep_y = Float32(0.0)
        var count = Float32(0.0)

        for j in range(BOIDS):
            if j == i:
                continue
            var dx = px_in[unsafe_offset=j] - x
            var dy = py_in[unsafe_offset=j] - y
            # The shortest way around a WRAPPED field, or a neighbour just
            # across the seam looks like it is on the far side of the
            # screen, and the flock tears itself apart at the edges.
            if dx > Float32(WIDTH) * Float32(0.5):
                dx -= Float32(WIDTH)
            elif dx < -Float32(WIDTH) * Float32(0.5):
                dx += Float32(WIDTH)
            if dy > Float32(HEIGHT) * Float32(0.5):
                dy -= Float32(HEIGHT)
            elif dy < -Float32(HEIGHT) * Float32(0.5):
                dy += Float32(HEIGHT)
            var d2 = dx * dx + dy * dy
            if d2 < neighbor_r * neighbor_r:
                avg_vx += vx_in[unsafe_offset=j]
                avg_vy += vy_in[unsafe_offset=j]
                avg_px += dx
                avg_py += dy
                count += Float32(1.0)
                if d2 < sep_r * sep_r and d2 > Float32(0.01):
                    var inv = Float32(1.0) / d2
                    sep_x -= dx * inv
                    sep_y -= dy * inv

        var new_vx = vx
        var new_vy = vy
        if count > Float32(0.0):
            avg_vx /= count
            avg_vy /= count
            avg_px /= count
            avg_py /= count
            new_vx += (avg_vx - vx) * align_w
            new_vy += (avg_vy - vy) * align_w
            new_vx += avg_px * cohesion_w
            new_vy += avg_py * cohesion_w
        new_vx += sep_x * separation_w
        new_vy += sep_y * separation_w

        if seek_w > Float32(0.0):
            new_vx += (target_x - x) * seek_w
            new_vy += (target_y - y) * seek_w

        var speed = sqrt(new_vx * new_vx + new_vy * new_vy) + Float32(1e-6)
        if speed > MAX_SPEED:
            new_vx = new_vx / speed * MAX_SPEED
            new_vy = new_vy / speed * MAX_SPEED
        elif speed < MIN_SPEED:
            new_vx = new_vx / speed * MIN_SPEED
            new_vy = new_vy / speed * MIN_SPEED

        var nx = x + new_vx
        var ny = y + new_vy
        if nx < Float32(0.0):
            nx += Float32(WIDTH)
        elif nx >= Float32(WIDTH):
            nx -= Float32(WIDTH)
        if ny < Float32(0.0):
            ny += Float32(HEIGHT)
        elif ny >= Float32(HEIGHT):
            ny -= Float32(HEIGHT)

        px_out[unsafe_offset=i] = nx
        py_out[unsafe_offset=i] = ny
        vx_out[unsafe_offset=i] = new_vx
        vy_out[unsafe_offset=i] = new_vy


def decay_kernel(
    gr: Pointer[Float32, MutAnyOrigin],
    gg: Pointer[Float32, MutAnyOrigin],
    gb: Pointer[Float32, MutAnyOrigin],
):
    """Every trail is a comet's tail: it only exists because something
    bright passed through recently. No neighbour is read here -- unlike
    Physarum's trail, which spreads, a boid's glow only ever fades -- so
    this runs safely in place, with no second buffer needed."""
    var idx = Int(global_idx.x)
    if idx < CELLS:
        gr[unsafe_offset=idx] = gr[unsafe_offset=idx] * GLOW_DECAY
        gg[unsafe_offset=idx] = gg[unsafe_offset=idx] * GLOW_DECAY
        gb[unsafe_offset=idx] = gb[unsafe_offset=idx] * GLOW_DECAY


def splat_kernel(
    gr: Pointer[Float32, MutAnyOrigin],
    gg: Pointer[Float32, MutAnyOrigin],
    gb: Pointer[Float32, MutAnyOrigin],
    px: Pointer[Float32, MutAnyOrigin],
    py: Pointer[Float32, MutAnyOrigin],
    vx: Pointer[Float32, MutAnyOrigin],
    vy: Pointer[Float32, MutAnyOrigin],
):
    """One thread per BOID, not per pixel -- the opposite direction from
    every other kernel in this file, because there are 4,000 boids and
    589,824 cells, and a boid painting the few pixels around itself is far
    cheaper than every pixel asking 4,000 boids whether it is the nearest
    one. The colour is the boid's own heading, through the same
    normalised velocity itself -- so two boids painted the same colour
    are, right now, flying the same way, and a flock turning together
    turns the SAME colour together. Aligned is not just a rule here; it
    is what you see. (Not a hue wheel through atan2: this fork's AIR
    backend has no atan2f, discovered as a metallib link failure rather
    than a Mojo-level error -- the direction vector's own components
    make just as good a colour key and need nothing but sqrt.)
    """
    var i = Int(global_idx.x)
    if i < BOIDS:
        var x = px[unsafe_offset=i]
        var y = py[unsafe_offset=i]
        var bvx = vx[unsafe_offset=i]
        var bvy = vy[unsafe_offset=i]
        var speed = sqrt(bvx * bvx + bvy * bvy) + Float32(1e-6)
        var nx = bvx / speed
        var ny = bvy / speed
        var r = Float32(0.55) + Float32(0.45) * nx
        var g = Float32(0.55) + Float32(0.45) * ny
        var b = Float32(0.55) - Float32(0.45) * nx
        var cx = Int(x)
        var cy = Int(y)
        for oy in range(-2, 3):
            for ox in range(-2, 3):
                var d2 = Float32(ox * ox + oy * oy)
                var falloff = Float32(1.0) - d2 / Float32(9.0)
                if falloff > Float32(0.0):
                    var wi = _wrap(cy + oy, HEIGHT) * WIDTH + _wrap(cx + ox, WIDTH)
                    var amt = falloff * SPLAT_BRIGHT
                    gr[unsafe_offset=wi] = gr[unsafe_offset=wi] + r * amt
                    gg[unsafe_offset=wi] = gg[unsafe_offset=wi] + g * amt
                    gb[unsafe_offset=wi] = gb[unsafe_offset=wi] + b * amt


@always_inline
def _pack(b: UInt32, g: UInt32, r: UInt32) -> UInt32:
    # BGRA8Unorm little-endian: byte0=B, byte1=G, byte2=R, byte3=A.
    return b | (g << 8) | (r << 16) | (UInt32(255) << 24)


def color_kernel(
    dst: Pointer[UInt32, MutAnyOrigin],
    gr: Pointer[Float32, MutAnyOrigin],
    gg: Pointer[Float32, MutAnyOrigin],
    gb: Pointer[Float32, MutAnyOrigin],
):
    """The glow buffers are already coloured -- `fluid`'s x/(1+x) tone-map
    per channel is all that is left, so a dense knot of overlapping boids
    compresses toward white instead of blowing out to a flat clip."""
    var idx = Int(global_idx.x)
    if idx < CELLS:
        var r = gr[unsafe_offset=idx]
        var g = gg[unsafe_offset=idx]
        var b = gb[unsafe_offset=idx]
        r = r / (Float32(1.0) + r)
        g = g / (Float32(1.0) + g)
        b = b / (Float32(1.0) + b)
        dst[unsafe_offset=idx] = _pack(
            UInt32(b * Float32(255)),
            UInt32(g * Float32(255)),
            UInt32(r * Float32(255)),
        )


# ===----------------------------------------------------------------------=== #
# Saving a frame -- `fluid`'s `save_png`, copied again (example folders are
# self-contained), WIN_W/WIN_H become WIDTH/HEIGHT as in `grayscott` and
# `physarum`.
# ===----------------------------------------------------------------------=== #


@always_inline
def _be32(v: UInt32) -> SIMD[DType.uint8, 4]:
    """PNG is big-endian throughout; arm64 is not."""
    return SIMD[DType.uint8, 4](
        UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF),
        UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF),
    )


def _put_chunk(
    fh: Int, tag: StaticString, data: Pointer[UInt8, MutUntrackedOrigin], n: Int
):
    """One PNG chunk: length, 4-char type, payload, CRC over type+payload."""
    var hdr_addr = Int(external_call["malloc", P](Int(8)))
    var hdr = Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=hdr_addr)
    var tail = Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=hdr_addr + 4)
    var L = _be32(UInt32(n))
    for i in range(4):
        hdr[unsafe_offset=i] = L[i]
    var t = tag.as_bytes()
    for i in range(4):
        hdr[unsafe_offset=4 + i] = t[i]
    _ = external_call["fwrite", Int](hdr.unsafe_bitcast[NoneType](), Int(1), Int(8), fh)
    if n > 0:
        _ = external_call["fwrite", Int](data.unsafe_bitcast[NoneType](), Int(1), n, fh)
    var crc = external_call["crc32", UInt64](
        UInt64(0), tail.unsafe_bitcast[NoneType](), UInt32(4)
    )
    if n > 0:
        crc = external_call["crc32", UInt64](
            crc, data.unsafe_bitcast[NoneType](), UInt32(n)
        )
    var C = _be32(UInt32(crc & UInt64(0xFFFFFFFF)))
    for i in range(4):
        hdr[unsafe_offset=i] = C[i]
    _ = external_call["fwrite", Int](hdr.unsafe_bitcast[NoneType](), Int(1), Int(4), fh)
    external_call["free", NoneType](hdr.unsafe_bitcast[NoneType]())


def save_png(path: String, bgra: Pointer[UInt32, MutUntrackedOrigin]) -> Bool:
    """Write the current frame. Returns False rather than raising: a failed
    screenshot must never take the demo down mid-drag."""
    var stride = WIDTH * 3 + 1
    var raw_n = stride * HEIGHT
    var raw_addr = Int(external_call["malloc", P](Int(raw_n)))
    if raw_addr == 0:
        return False
    var raw = Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=raw_addr)
    for y in range(HEIGHT):
        var row = y * stride
        raw[unsafe_offset=row] = UInt8(0)
        for x in range(WIDTH):
            var px = bgra[unsafe_offset=y * WIDTH + x]
            var o = row + 1 + x * 3
            raw[unsafe_offset=o] = UInt8((px >> 16) & UInt32(255))
            raw[unsafe_offset=o + 1] = UInt8((px >> 8) & UInt32(255))
            raw[unsafe_offset=o + 2] = UInt8(px & UInt32(255))

    var cap = UInt64(raw_n + raw_n // 100 + 4096)
    var comp = Pointer[UInt8, MutUntrackedOrigin](
        unsafe_from_address=Int(external_call["malloc", P](Int(cap)))
    )
    var clen = Pointer[UInt64, MutUntrackedOrigin](
        unsafe_from_address=Int(external_call["malloc", P](Int(8)))
    )
    clen[] = cap
    var rc = external_call["compress2", Int32](
        comp.unsafe_bitcast[NoneType](), clen,
        raw.unsafe_bitcast[NoneType](), UInt64(raw_n), Int32(6),
    )
    if rc != Int32(0):
        external_call["free", NoneType](raw.unsafe_bitcast[NoneType]())
        external_call["free", NoneType](comp.unsafe_bitcast[NoneType]())
        external_call["free", NoneType](clen.unsafe_bitcast[NoneType]())
        return False

    var mode = String("wb")
    var local_path = path
    var fh = Int(external_call["fopen", P](
        local_path.as_c_string_slice(), mode.as_c_string_slice()
    ))
    if fh == 0:
        external_call["free", NoneType](raw.unsafe_bitcast[NoneType]())
        external_call["free", NoneType](comp.unsafe_bitcast[NoneType]())
        external_call["free", NoneType](clen.unsafe_bitcast[NoneType]())
        return False

    var sig = Pointer[UInt8, MutUntrackedOrigin](
        unsafe_from_address=Int(external_call["malloc", P](Int(8)))
    )
    var sigbytes = SIMD[DType.uint8, 8](137, 80, 78, 71, 13, 10, 26, 10)
    for i in range(8):
        sig[unsafe_offset=i] = sigbytes[i]
    _ = external_call["fwrite", Int](sig.unsafe_bitcast[NoneType](), Int(1), Int(8), fh)

    var ihdr = Pointer[UInt8, MutUntrackedOrigin](
        unsafe_from_address=Int(external_call["malloc", P](Int(13)))
    )
    var wb = _be32(UInt32(WIDTH))
    var hb = _be32(UInt32(HEIGHT))
    for i in range(4):
        ihdr[unsafe_offset=i] = wb[i]
        ihdr[unsafe_offset=4 + i] = hb[i]
    ihdr[unsafe_offset=8] = UInt8(8)
    ihdr[unsafe_offset=9] = UInt8(2)
    ihdr[unsafe_offset=10] = UInt8(0)
    ihdr[unsafe_offset=11] = UInt8(0)
    ihdr[unsafe_offset=12] = UInt8(0)
    _put_chunk(fh, "IHDR", ihdr, 13)
    _put_chunk(fh, "IDAT", comp, Int(clen[]))
    _put_chunk(fh, "IEND", ihdr, 0)
    _ = external_call["fclose", Int32](fh)

    external_call["free", NoneType](sig.unsafe_bitcast[NoneType]())
    external_call["free", NoneType](ihdr.unsafe_bitcast[NoneType]())
    external_call["free", NoneType](raw.unsafe_bitcast[NoneType]())
    external_call["free", NoneType](comp.unsafe_bitcast[NoneType]())
    external_call["free", NoneType](clen.unsafe_bitcast[NoneType]())
    return True


# ===----------------------------------------------------------------------=== #
# Input arrives on Cocoa's schedule; frames happen on ours. One addition
# over `grayscott`/`physarum`'s scheme: HOLD state, not just a one-shot
# click, because "herd the flock toward the cursor" wants a continuous
# pull for as long as the button is down, not one pulse per drag event.
# ===----------------------------------------------------------------------=== #

comptime CMD_PAUSE = 2
comptime CMD_RESET = 4
comptime CMD_QUIT = 8
comptime CMD_PRESET = 16
comptime CMD_SAVE = 32

comptime g_cmd = named_global["boids.cmd", Int]
comptime g_mouse_x = named_global["boids.mouse.x", Int]
comptime g_mouse_y = named_global["boids.mouse.y", Int]
comptime g_mouse_down = named_global["boids.mouse.down", Int]
comptime g_want_preset = named_global["boids.preset", Int]


def _mark_mouse(view: ObjCObject, event: ObjCObject):
    var at = Obj["NSEvent"](event.addr()).locationInWindow()
    var local = Obj["NSView"](view.addr()).convertPoint(at, fromView=ObjCObject(0))
    g_mouse_x()[] = Int(local.x)
    g_mouse_y()[] = Int(local.y)


class BoidsView(NSView):
    """The window's content view. Cocoa calls these; they only set flags."""

    def acceptsFirstResponder(self) -> Bool:
        return True

    def isFlipped(self) -> Bool:
        return True

    def mouseDown_(self, event: ObjCObject):
        _mark_mouse(ObjCObject(self.__objc_id), event)
        g_mouse_down()[] = 1

    def mouseDragged_(self, event: ObjCObject):
        _mark_mouse(ObjCObject(self.__objc_id), event)

    def mouseUp_(self, event: ObjCObject):
        g_mouse_down()[] = 0

    def keyDown_(self, event: ObjCObject):
        var key = ns_to_string(
            ObjCObject(Obj["NSEvent"](event.addr()).charactersIgnoringModifiers().id)
        )
        if len(key.as_bytes()) == 0:
            return
        if key == " ":
            g_cmd()[] |= CMD_PAUSE
        elif key == "r":
            g_cmd()[] |= CMD_RESET
        elif key == "q" or key == "\x1b":
            g_cmd()[] |= CMD_QUIT
        elif key == "s":
            g_cmd()[] |= CMD_SAVE
        else:
            let kb = key.as_bytes()[0]
            if kb >= 49 and kb <= 52:            # '1'..'4'
                g_want_preset()[] = Int(kb) - 49
                g_cmd()[] |= CMD_PRESET


def main() raises:
    if not load_framework["AppKit"]():
        raise Error("could not load AppKit")

    var frame_limit = 0
    let door = getenv("BOIDS_FRAMES")
    if door != "":
        frame_limit = Int(door)

    var preset = 0
    var neighbor_r = preset_neighbor_r(preset)
    var align_w = preset_align(preset)
    var cohesion_w = preset_cohesion(preset)
    var separation_w = preset_separation(preset)

    print("Boids", WIDTH, "x", HEIGHT, "—", BOIDS, "boids — preset", preset_name(preset))

    var ctx = DeviceContext(api="metal")
    print("  GPU:", ctx.name())
    var px_a = ctx.enqueue_create_buffer[DType.float32](BOIDS)
    var py_a = ctx.enqueue_create_buffer[DType.float32](BOIDS)
    var vx_a = ctx.enqueue_create_buffer[DType.float32](BOIDS)
    var vy_a = ctx.enqueue_create_buffer[DType.float32](BOIDS)
    var px_b = ctx.enqueue_create_buffer[DType.float32](BOIDS)
    var py_b = ctx.enqueue_create_buffer[DType.float32](BOIDS)
    var vx_b = ctx.enqueue_create_buffer[DType.float32](BOIDS)
    var vy_b = ctx.enqueue_create_buffer[DType.float32](BOIDS)
    var gr = ctx.enqueue_create_buffer[DType.float32](CELLS)
    var gg = ctx.enqueue_create_buffer[DType.float32](CELLS)
    var gb = ctx.enqueue_create_buffer[DType.float32](CELLS)
    var dev = ctx.enqueue_create_buffer[DType.uint32](CELLS)

    var init_kern = ctx.compile_function[init_boids_kernel]()
    var boid_kern = ctx.compile_function[boid_kernel]()
    var decay_kern = ctx.compile_function[decay_kernel]()
    var splat_kern = ctx.compile_function[splat_kernel]()
    var color_kern = ctx.compile_function[color_kernel]()

    ctx.enqueue_function(init_kern, px_a, py_a, vx_a, vy_a, grid_dim=(BOID_GRID), block_dim=(BLOCK))
    ctx.enqueue_memset(gr, Float32(0.0))
    ctx.enqueue_memset(gg, Float32(0.0))
    ctx.enqueue_memset(gb, Float32(0.0))
    ctx.synchronize()

    var bgra = Pointer[UInt32, MutUntrackedOrigin](
        unsafe_from_address=Int(external_call["calloc", P](Int(CELLS), Int(4)))
    )

    with autoreleasepool():
        var app = Cls["NSApplication"]().sharedApplication()
        _ = app.setActivationPolicy(
            nsenum["NSApplicationActivationPolicyAccessory"]()
            if frame_limit != 0
            else nsenum["NSApplicationActivationPolicyRegular"]()
        )

        var win = Obj["NSWindow"](
            contentRect=CGRect(
                CGPoint(120.0, 120.0), CGSize(Float64(WIDTH), Float64(HEIGHT))
            ),
            styleMask=(
                nsenum["NSWindowStyleMaskTitled"]()
                | nsenum["NSWindowStyleMaskClosable"]()
                | nsenum["NSWindowStyleMaskMiniaturizable"]()
                | nsenum["NSWindowStyleMaskResizable"]()
            ),
            backing=nsenum["NSBackingStoreBuffered"](),
            defer=False,
        )
        win.title = "Boids — every bird is Mojo"

        var view = ObjCObject(BoidsView().__objc_id)
        _ = Obj["NSView"](view.addr()).setFrame(
            CGRect(CGPoint(0.0, 0.0), CGSize(Float64(WIDTH), Float64(HEIGHT)))
        )

        var display_dev = ObjCObject(
            Int(external_call["MTLCreateSystemDefaultDevice", P]())
        )
        var queue = send[ObjCObject, "newCommandQueue"](display_dev)
        _ = external_call["objc_retain", P](queue.ptr())

        var layer = ObjCObject(Cls["CAMetalLayer"]().layer().id)
        var mlayer = Obj["CAMetalLayer"](layer.addr())
        _ = send[ObjCObject, "setDevice:"](layer, display_dev.ptr())
        _ = mlayer.setPixelFormat(nsenum["MTLPixelFormatBGRA8Unorm"]())
        _ = mlayer.setFramebufferOnly(False)
        _ = mlayer.setDrawableSize(CGSize(Float64(WIDTH), Float64(HEIGHT)))
        _ = external_call["objc_retain", P](layer.ptr())

        var view_t = Obj["NSView"](view.addr())
        _ = view_t.setWantsLayer(True)
        _ = view_t.setLayer(layer)
        _ = win.setContentView(view)
        _ = win.makeFirstResponder(view)
        _ = win.makeKeyAndOrderFront(ObjCObject(app.id))
        if frame_limit == 0:
            _ = app.activateIgnoringOtherApps(True)
        _ = app.finishLaunching()

        var region = MTLRegion(MTLOrigin(0, 0, 0), MTLSize(WIDTH, HEIGHT, 1))
        var mode = "kCFRunLoopDefaultMode"

        print("Rendering. hold attracts · 1-4 presets · r reseeds · space pauses · q quits")
        var frames = 0
        var shots = 0
        var running = True
        var paused = False
        var save_wanted = False
        var parity = 0                       # which of the a/b sets is CURRENT
        var loop_start = perf_counter_ns()

        while running:
            while True:
                var past = Cls["NSDate"]().distantPast()
                var ev = app.nextEventMatchingMask(
                    UInt64.MAX, untilDate=ObjCObject(past.id),
                    inMode=mode, dequeue=True,
                )
                if ev.id == 0:
                    break
                _ = app.sendEvent(ObjCObject(ev.id))
            if not win.isVisible():
                break

            var pending = g_cmd()[]
            if pending != 0:
                g_cmd()[] = 0
                if (pending & CMD_PAUSE) != 0:
                    paused = not paused
                if (pending & CMD_RESET) != 0:
                    ctx.enqueue_function(
                        init_kern, px_a, py_a, vx_a, vy_a,
                        grid_dim=(BOID_GRID), block_dim=(BLOCK),
                    )
                    ctx.enqueue_memset(gr, Float32(0.0))
                    ctx.enqueue_memset(gg, Float32(0.0))
                    ctx.enqueue_memset(gb, Float32(0.0))
                    parity = 0
                if (pending & CMD_PRESET) != 0:
                    preset = g_want_preset()[]
                    neighbor_r = preset_neighbor_r(preset)
                    align_w = preset_align(preset)
                    cohesion_w = preset_cohesion(preset)
                    separation_w = preset_separation(preset)
                    win.title = "Boids — " + preset_name(preset)
                if (pending & CMD_SAVE) != 0:
                    save_wanted = True
                if (pending & CMD_QUIT) != 0:
                    running = False

            if not paused:
                var seek_w = Float32(0.0006) if g_mouse_down()[] != 0 else Float32(0.0)
                if parity == 0:
                    ctx.enqueue_function(
                        boid_kern, px_b, py_b, vx_b, vy_b, px_a, py_a, vx_a, vy_a,
                        neighbor_r, align_w, cohesion_w, separation_w,
                        seek_w, Float32(g_mouse_x()[]), Float32(g_mouse_y()[]),
                        grid_dim=(BOID_GRID), block_dim=(BLOCK),
                    )
                    ctx.enqueue_function(
                        splat_kern, gr, gg, gb, px_b, py_b, vx_b, vy_b,
                        grid_dim=(BOID_GRID), block_dim=(BLOCK),
                    )
                else:
                    ctx.enqueue_function(
                        boid_kern, px_a, py_a, vx_a, vy_a, px_b, py_b, vx_b, vy_b,
                        neighbor_r, align_w, cohesion_w, separation_w,
                        seek_w, Float32(g_mouse_x()[]), Float32(g_mouse_y()[]),
                        grid_dim=(BOID_GRID), block_dim=(BLOCK),
                    )
                    ctx.enqueue_function(
                        splat_kern, gr, gg, gb, px_a, py_a, vx_a, vy_a,
                        grid_dim=(BOID_GRID), block_dim=(BLOCK),
                    )
                ctx.enqueue_function(decay_kern, gr, gg, gb, grid_dim=(GRID), block_dim=(BLOCK))
                parity = 1 - parity

            ctx.enqueue_function(
                color_kern, dev, gr, gg, gb, grid_dim=(GRID), block_dim=(BLOCK)
            )
            ctx.synchronize()
            with dev.map_to_host() as pix:
                var src = pix.unsafe_ptr()
                for k in range(CELLS):
                    bgra[unsafe_offset=k] = src[unsafe_offset=k]

            if save_wanted:
                save_wanted = False
                var path = String("/tmp/boids-") + String(shots) + ".png"
                if save_png(path, bgra):
                    print("saved", path)
                else:
                    print("could not save", path)
                shots += 1

            var drawable = Obj["CAMetalLayer"](layer.addr()).nextDrawable()
            if drawable.id != 0:
                var tex = Obj["CAMetalDrawable"](drawable.addr()).texture()
                _ = send[
                    ObjCObject, "replaceRegion:mipmapLevel:withBytes:bytesPerRow:"
                ](tex, region, Int(0), bgra.unsafe_bitcast[NoneType](), Int(WIDTH * 4))
                var cb = send[ObjCObject, "commandBuffer"](queue)
                _ = send[ObjCObject, "presentDrawable:"](cb, drawable.ptr())
                _ = send[ObjCObject, "commit"](cb)

            if frame_limit != 0 and frames + 1 >= frame_limit:
                if save_png("/tmp/boids-headless.png", bgra):
                    print("saved /tmp/boids-headless.png")

            frames += 1
            if frames % 120 == 0:
                var now = perf_counter_ns()
                var fps = Float64(frames) / (Float64(now - loop_start) / 1e9)
                print("  frame", frames, "—", fps, "fps")
            if frame_limit != 0 and frames >= frame_limit:
                running = False

        var secs = Float64(perf_counter_ns() - loop_start) / 1e9
        if secs > 0.0:
            print(
                "Rendered", frames, "frames in", secs, "s (",
                Float64(frames) / secs, "fps )",
            )
