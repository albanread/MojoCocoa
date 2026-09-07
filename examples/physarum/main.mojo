# ===----------------------------------------------------------------------=== #
# Physarum — a slime-mould agent simulation, every agent and every cell of
# its trail computed on the Apple GPU. Three hundred thousand agents, each
# one looking three ways, turning toward whichever way smells strongest,
# and leaving a trace behind it. No agent knows about any other agent, and
# no cell of the map knows it is part of a network -- the branching,
# converging veins that a real slime mould grows to solve a maze emerge
# from that alone, the same way the reef in `grayscott` emerges from two
# numbers rather than being drawn.
#
#   drag     lay a strong trail under the cursor -- the network bends to it
#   1-4      jump to a named turning/sensing regime, live
#   r        reseed every agent at a fresh random position
#   space    pause
#   s        save the current frame as a PNG
#   q / esc  quit, as does closing the window
#
# Built on `grayscott`'s own three house rules (which came from `mandelbrot`
# and `fluid` before it): no shader anywhere, input as flags set by a class
# and acted on by the frame loop, and `_at`'s clamp-or-wrap discipline
# rather than a special-cased border. The one genuinely new idea is that
# THIS demo has two different kinds of thing running on the GPU at once --
# agents, addressed one-per-thread by agent index, and the trail map,
# addressed one-per-thread by pixel index -- where `grayscott` only ever
# had the one.
#
# PHYSARUM_FRAMES=N renders N frames and exits, unfocused, exactly like
# MANDEL_FRAMES and GRAYSCOTT_FRAMES.
# ===----------------------------------------------------------------------=== #

from std.gpu import global_idx
from std.math import cos, sin
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
comptime AGENTS = 300000

comptime BLOCK = 256
comptime GRID = (CELLS + BLOCK - 1) // BLOCK
comptime AGENT_GRID = (AGENTS + BLOCK - 1) // BLOCK

comptime TAU = Float32(6.28318530718)
comptime DEPOSIT = Float32(5.0)

# ── the parameter map ────────────────────────────────────────────────────
#
# Unlike Gray-Scott's feed/kill plane, Physarum has no narrow sweet spot --
# nearly any sensor angle, turn angle and sensor distance produce SOME
# branching network, so these four are this file's own tuning rather than
# values looked up from a paper: a balanced web, a tighter spiralling coil
# (small sensor angle, sharp turns), a sparse long-branched growth (wide
# sensors, gentle turns), and a dense fast-decaying mesh.

comptime PRESET_COUNT = 4


def preset_name(i: Int) -> String:
    if i == 0:
        return String("web")
    if i == 1:
        return String("coil")
    if i == 2:
        return String("sparse")
    return String("dense")


def preset_sensor_angle(i: Int) -> Float32:
    if i == 0:
        return Float32(0.45)
    if i == 1:
        return Float32(0.20)
    if i == 2:
        return Float32(0.60)
    return Float32(0.35)


def preset_turn_angle(i: Int) -> Float32:
    if i == 0:
        return Float32(0.30)
    if i == 1:
        return Float32(0.50)
    if i == 2:
        return Float32(0.25)
    return Float32(0.35)


def preset_sensor_dist(i: Int) -> Float32:
    if i == 0:
        return Float32(9.0)
    if i == 1:
        return Float32(6.0)
    if i == 2:
        return Float32(16.0)
    return Float32(5.0)


def preset_decay(i: Int) -> Float32:
    if i == 0:
        return Float32(0.94)
    if i == 1:
        return Float32(0.92)
    if i == 2:
        return Float32(0.96)
    return Float32(0.90)


# ===----------------------------------------------------------------------=== #
# A tiny integer hash, standing in for a per-thread random number generator.
# GPU threads have no shared RNG state to advance -- each one HASHES its own
# index (and the frame count, when the same agent needs a fresh number every
# step) instead, which is embarrassingly parallel by construction and needs
# no setup kernel of its own.
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


@always_inline
def _at(f: Pointer[Float32, MutAnyOrigin], x: Int, y: Int) -> Float32:
    """The trail map wraps, not clamps: an agent that walks off the right
    edge reappears on the left, so the map it senses and deposits into
    must wrap the same way or a trail would smear against a false wall
    the agents themselves never see."""
    return f[unsafe_offset=_wrap(y, HEIGHT) * WIDTH + _wrap(x, WIDTH)]


# ===----------------------------------------------------------------------=== #
# The two populations. Agents are addressed by agent index; the trail map,
# a completely separate GPU allocation, is addressed by pixel index -- two
# different kernels, two different grid sizes, one simulation.
# ===----------------------------------------------------------------------=== #


def init_agents_kernel(
    px: Pointer[Float32, MutAnyOrigin],
    py: Pointer[Float32, MutAnyOrigin],
    pa: Pointer[Float32, MutAnyOrigin],
):
    """Scatter every agent to a random position and heading -- entirely on
    the GPU, hashing each agent's own index rather than needing 300,000
    separate host-side random calls before the first frame can run."""
    var idx = Int(global_idx.x)
    if idx < AGENTS:
        var rx = _rand01(UInt32(idx) * UInt32(2654435761) + UInt32(1))
        var ry = _rand01(UInt32(idx) * UInt32(2246822519) + UInt32(2))
        var ra = _rand01(UInt32(idx) * UInt32(3266489917) + UInt32(3))
        px[unsafe_offset=idx] = rx * Float32(WIDTH)
        py[unsafe_offset=idx] = ry * Float32(HEIGHT)
        pa[unsafe_offset=idx] = ra * TAU


def agent_kernel(
    px: Pointer[Float32, MutAnyOrigin],
    py: Pointer[Float32, MutAnyOrigin],
    pa: Pointer[Float32, MutAnyOrigin],
    trail: Pointer[Float32, MutAnyOrigin],
    frame: UInt32,
    sensor_angle: Float32,
    turn_angle: Float32,
    sensor_dist: Float32,
):
    """Sense three points ahead, turn toward the strongest, step, deposit.
    That is the entire behaviour -- an agent holds no memory of where it
    has been, and reacts to nothing but the shared map every other agent
    is also reading and writing.

    The deposit at the end is a plain, non-atomic add: two agents landing
    on the same cell in the same step can lose one increment to the other,
    and at 300,000 agents over 589,824 cells that collision is rare and,
    once it happens, invisible -- a fraction of one step's trail on one
    pixel, immediately blurred and decayed with everything around it. An
    atomic add would buy correctness this demo has no way to show.
    """
    var idx = Int(global_idx.x)
    if idx < AGENTS:
        var x = px[unsafe_offset=idx]
        var y = py[unsafe_offset=idx]
        var a = pa[unsafe_offset=idx]

        var sl = _at(
            trail, Int(x + cos(a - sensor_angle) * sensor_dist),
            Int(y + sin(a - sensor_angle) * sensor_dist),
        )
        var sc = _at(
            trail, Int(x + cos(a) * sensor_dist), Int(y + sin(a) * sensor_dist)
        )
        var sr = _at(
            trail, Int(x + cos(a + sensor_angle) * sensor_dist),
            Int(y + sin(a + sensor_angle) * sensor_dist),
        )

        if sc > sl and sc > sr:
            pass
        elif sl > sr:
            a -= turn_angle
        elif sr > sl:
            a += turn_angle
        else:
            var r = _rand01(UInt32(idx) * UInt32(747796405) + frame)
            a += turn_angle if r > Float32(0.5) else -turn_angle

        var nx = x + cos(a) * Float32(1.2)
        var ny = y + sin(a) * Float32(1.2)
        if nx < Float32(0.0):
            nx += Float32(WIDTH)
        elif nx >= Float32(WIDTH):
            nx -= Float32(WIDTH)
        if ny < Float32(0.0):
            ny += Float32(HEIGHT)
        elif ny >= Float32(HEIGHT):
            ny -= Float32(HEIGHT)

        px[unsafe_offset=idx] = nx
        py[unsafe_offset=idx] = ny
        pa[unsafe_offset=idx] = a

        var cidx = _wrap(Int(ny), HEIGHT) * WIDTH + _wrap(Int(nx), WIDTH)
        trail[unsafe_offset=cidx] = trail[unsafe_offset=cidx] + DEPOSIT


def diffuse_kernel(
    out_t: Pointer[Float32, MutAnyOrigin],
    in_t: Pointer[Float32, MutAnyOrigin],
    decay: Float32,
):
    """A trail is a rumour: it spreads to its neighbours and fades unless
    agents keep repeating it. The nine-point box average IS the spreading;
    multiplying by `decay` afterward is the fading. Both happen to every
    cell whether or not an agent ever visited it -- there is no separate
    'has this pixel ever seen an agent' bit anywhere."""
    var idx = Int(global_idx.x)
    if idx < CELLS:
        var x = idx % WIDTH
        var y = idx // WIDTH
        var s = Float32(0.0)
        s += _at(in_t, x - 1, y - 1)
        s += _at(in_t, x, y - 1)
        s += _at(in_t, x + 1, y - 1)
        s += _at(in_t, x - 1, y)
        s += _at(in_t, x, y)
        s += _at(in_t, x + 1, y)
        s += _at(in_t, x - 1, y + 1)
        s += _at(in_t, x, y + 1)
        s += _at(in_t, x + 1, y + 1)
        out_t[unsafe_offset=idx] = (s / Float32(9.0)) * decay


def attract_kernel(
    trail: Pointer[Float32, MutAnyOrigin], cx: Int32, cy: Int32, r2: Int32
):
    """A strong trail laid down under the cursor. Nothing forces an agent
    toward it -- the network only bends here because sensing a bright
    patch and turning toward it is all an agent ever does anyway; this
    just gives it something bright to find."""
    var idx = Int(global_idx.x)
    if idx < CELLS:
        var x = Int32(idx % WIDTH)
        var y = Int32(idx // WIDTH)
        var dx = x - cx
        var dy = y - cy
        if dx * dx + dy * dy <= r2:
            trail[unsafe_offset=idx] = Float32(400.0)


@always_inline
def _pack(b: UInt32, g: UInt32, r: UInt32) -> UInt32:
    # BGRA8Unorm little-endian: byte0=B, byte1=G, byte2=R, byte3=A.
    return b | (g << 8) | (r << 16) | (UInt32(255) << 24)


def color_kernel(dst: Pointer[UInt32, MutAnyOrigin], trail: Pointer[Float32, MutAnyOrigin]):
    """Trail intensity, tone-mapped -- `fluid`'s own x/(1+x) curve, reused
    for the same reason it was needed there: raw deposit totals span a
    huge range between a cell one agent grazed once and a cell on a busy
    trunk route, and a linear map would blow the second one out to solid
    white while the first stayed too dark to see. A warm amber ramp on
    black reads as bioluminescence rather than a heat map."""
    var idx = Int(global_idx.x)
    if idx < CELLS:
        var t = trail[unsafe_offset=idx]
        var m = t / (Float32(1.0) + t)
        var r = m
        var g = m * m * Float32(0.85)
        var b = m * m * m * Float32(0.55)
        dst[unsafe_offset=idx] = _pack(
            UInt32(b * Float32(255)),
            UInt32(g * Float32(255)),
            UInt32(r * Float32(255)),
        )


# ===----------------------------------------------------------------------=== #
# Saving a frame -- `fluid`'s `save_png` again, copied rather than shared
# (example folders are self-contained by this tree's own convention), with
# WIN_W/WIN_H become WIDTH/HEIGHT exactly as in `grayscott`.
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
# Input arrives on Cocoa's schedule; frames happen on ours -- `grayscott`'s
# own scheme, unchanged.
# ===----------------------------------------------------------------------=== #

comptime CMD_CLICK = 1
comptime CMD_PAUSE = 2
comptime CMD_RESET = 4
comptime CMD_QUIT = 8
comptime CMD_PRESET = 16
comptime CMD_SAVE = 32

comptime g_cmd = named_global["physarum.cmd", Int]
comptime g_click_x = named_global["physarum.click.x", Int]
comptime g_click_y = named_global["physarum.click.y", Int]
comptime g_want_preset = named_global["physarum.preset", Int]


def _mark_click(view: ObjCObject, event: ObjCObject):
    var at = Obj["NSEvent"](event.addr()).locationInWindow()
    var local = Obj["NSView"](view.addr()).convertPoint(at, fromView=ObjCObject(0))
    g_click_x()[] = Int(local.x)
    g_click_y()[] = Int(local.y)
    g_cmd()[] |= CMD_CLICK


class PhysarumView(NSView):
    """The window's content view. Cocoa calls these; they only set flags."""

    def acceptsFirstResponder(self) -> Bool:
        return True

    def isFlipped(self) -> Bool:
        return True

    def mouseDown_(self, event: ObjCObject):
        _mark_click(ObjCObject(self.__objc_id), event)

    def mouseDragged_(self, event: ObjCObject):
        _mark_click(ObjCObject(self.__objc_id), event)

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
    let door = getenv("PHYSARUM_FRAMES")
    if door != "":
        frame_limit = Int(door)

    var preset = 0
    var sensor_angle = preset_sensor_angle(preset)
    var turn_angle = preset_turn_angle(preset)
    var sensor_dist = preset_sensor_dist(preset)
    var decay = preset_decay(preset)

    print("Physarum", WIDTH, "x", HEIGHT, "—", AGENTS, "agents — preset", preset_name(preset))

    var ctx = DeviceContext(api="metal")
    print("  GPU:", ctx.name())
    var px = ctx.enqueue_create_buffer[DType.float32](AGENTS)
    var py = ctx.enqueue_create_buffer[DType.float32](AGENTS)
    var pa = ctx.enqueue_create_buffer[DType.float32](AGENTS)
    var trail_a = ctx.enqueue_create_buffer[DType.float32](CELLS)
    var trail_b = ctx.enqueue_create_buffer[DType.float32](CELLS)
    var dev = ctx.enqueue_create_buffer[DType.uint32](CELLS)

    var init_kern = ctx.compile_function[init_agents_kernel]()
    var agent_kern = ctx.compile_function[agent_kernel]()
    var diffuse_kern = ctx.compile_function[diffuse_kernel]()
    var attract_kern = ctx.compile_function[attract_kernel]()
    var color_kern = ctx.compile_function[color_kernel]()

    ctx.enqueue_function(init_kern, px, py, pa, grid_dim=(AGENT_GRID), block_dim=(BLOCK))
    ctx.enqueue_memset(trail_a, Float32(0.0))
    ctx.enqueue_memset(trail_b, Float32(0.0))
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
        win.title = "Physarum — every agent is Mojo"

        var view = ObjCObject(PhysarumView().__objc_id)
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

        print("Rendering. drag attracts · 1-4 presets · r reseeds · space pauses · q quits")
        var frames = 0
        var shots = 0
        var running = True
        var paused = False
        var save_wanted = False
        var parity = 0                       # which of trail_a/trail_b is CURRENT
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

            var cur = trail_a if parity == 0 else trail_b
            var nxt = trail_b if parity == 0 else trail_a

            var pending = g_cmd()[]
            if pending != 0:
                g_cmd()[] = 0
                if (pending & CMD_CLICK) != 0:
                    ctx.enqueue_function(
                        attract_kern, cur,
                        Int32(g_click_x()[]), Int32(g_click_y()[]), Int32(12 * 12),
                        grid_dim=(GRID), block_dim=(BLOCK),
                    )
                if (pending & CMD_PAUSE) != 0:
                    paused = not paused
                if (pending & CMD_RESET) != 0:
                    ctx.enqueue_function(
                        init_kern, px, py, pa, grid_dim=(AGENT_GRID), block_dim=(BLOCK)
                    )
                    ctx.enqueue_memset(trail_a, Float32(0.0))
                    ctx.enqueue_memset(trail_b, Float32(0.0))
                if (pending & CMD_PRESET) != 0:
                    preset = g_want_preset()[]
                    sensor_angle = preset_sensor_angle(preset)
                    turn_angle = preset_turn_angle(preset)
                    sensor_dist = preset_sensor_dist(preset)
                    decay = preset_decay(preset)
                    win.title = "Physarum — " + preset_name(preset)
                if (pending & CMD_SAVE) != 0:
                    save_wanted = True
                if (pending & CMD_QUIT) != 0:
                    running = False

            if not paused:
                ctx.enqueue_function(
                    agent_kern, px, py, pa, cur, UInt32(frames),
                    sensor_angle, turn_angle, sensor_dist,
                    grid_dim=(AGENT_GRID), block_dim=(BLOCK),
                )
                ctx.enqueue_function(
                    diffuse_kern, nxt, cur, decay, grid_dim=(GRID), block_dim=(BLOCK)
                )
                parity = 1 - parity
                cur = trail_a if parity == 0 else trail_b

            ctx.enqueue_function(
                color_kern, dev, cur, grid_dim=(GRID), block_dim=(BLOCK)
            )
            ctx.synchronize()
            with dev.map_to_host() as pix:
                var src = pix.unsafe_ptr()
                for k in range(CELLS):
                    bgra[unsafe_offset=k] = src[unsafe_offset=k]

            if save_wanted:
                save_wanted = False
                var path = String("/tmp/physarum-") + String(shots) + ".png"
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
                if save_png("/tmp/physarum-headless.png", bgra):
                    print("saved /tmp/physarum-headless.png")

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
