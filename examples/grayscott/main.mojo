# ===----------------------------------------------------------------------=== #
# Gray-Scott — a reaction-diffusion simulation, every cell computed on the
# Apple GPU. Two chemicals, U and V: U feeds itself back toward 1, V is a
# catalyst that eats U wherever both are present and is itself removed at a
# fixed rate. That is the whole model -- two numbers, `feed` and `kill` --
# and depending on where those two numbers sit, the SAME four-line kernel
# produces spots that divide like cells, worms that wriggle forever,
# spinning spirals, or a coral reef that never stops growing. Nothing else
# in the kernel changes; the six presets below are six points on one map.
#
#   drag     paint catalyst under the cursor -- feed the pattern by hand
#   1-6      jump to a named region of the parameter plane, live
#   r        reseed with fresh blobs at the current parameters
#   space    pause
#   q / esc  quit, as does closing the window
#
# Built on the same three house rules `mandelbrot` and `fluid` established:
# no shader anywhere (the colour kernel packs BGRA directly, and the frame
# lands on the drawable via `replaceRegion:`, not a sampler); input arrives
# through a `class` whose handlers only set flags, so every Metal and GPU
# call still happens on the one thread that owns them; and edge cells are
# never special-cased, only the neighbour READS they make are clamped.
#
# GRAYSCOTT_FRAMES=N renders N frames and exits, unfocused, exactly like
# MANDEL_FRAMES -- a harness run must never steal the screen.
# ===----------------------------------------------------------------------=== #

from std.gpu import global_idx
from std.math import cos
from std.random import random_ui64
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

comptime BLOCK = 256
comptime GRID = (CELLS + BLOCK - 1) // BLOCK

comptime DU = Float32(1.0)
comptime DV = Float32(0.5)
comptime DT = Float32(1.0)
comptime SUBSTEPS = 20
"""Simulation steps per drawn frame. Kept EVEN on purpose: the ping-pong
below always leaves the settled state back in (u, v), so the colour
kernel never has to ask which buffer is current."""

comptime SEED_BLOBS = 6
comptime SEED_R2 = Int32(14 * 14)

comptime TAU = Float32(6.28318530718)

# ── the parameter map ────────────────────────────────────────────────────
#
# Six named regions of the Gray-Scott (feed, kill) plane -- the widely
# reproduced values this model is usually shown with, not a guess: get
# these even a few thousandths wrong and the field relaxes to a uniform
# grey instead of staying alive. Diffusion (Du=1, Dv=0.5) and the nine-
# point weighted Laplacian below are the standard discrete form; only
# feed and kill change between presets.

comptime PRESET_COUNT = 6


def preset_name(i: Int) -> String:
    if i == 0:
        return String("gliders")
    if i == 1:
        return String("bubbles")
    if i == 2:
        return String("maze")
    if i == 3:
        return String("worms")
    if i == 4:
        return String("spirals")
    return String("spots")


def preset_feed(i: Int) -> Float32:
    if i == 0:
        return Float32(0.014)
    if i == 1:
        return Float32(0.098)
    if i == 2:
        return Float32(0.029)
    if i == 3:
        return Float32(0.058)
    if i == 4:
        return Float32(0.018)
    return Float32(0.030)


def preset_kill(i: Int) -> Float32:
    if i == 0:
        return Float32(0.054)
    if i == 1:
        return Float32(0.057)
    if i == 2:
        return Float32(0.057)
    if i == 3:
        return Float32(0.065)
    if i == 4:
        return Float32(0.051)
    return Float32(0.062)


# ===----------------------------------------------------------------------=== #
# The stencil. Every cell runs the identical kernel; only the neighbour
# reads clamp at the edge, exactly the discipline `fluid`'s `_at` uses.
# ===----------------------------------------------------------------------=== #


@always_inline
def _clampi(v: Int, lo: Int, hi: Int) -> Int:
    if v < lo:
        return lo
    if v > hi:
        return hi
    return v


@always_inline
def _at(f: Pointer[Float32, MutAnyOrigin], x: Int, y: Int) -> Float32:
    return f[
        unsafe_offset=_clampi(y, 0, HEIGHT - 1) * WIDTH + _clampi(x, 0, WIDTH - 1)
    ]


@always_inline
def _laplacian(f: Pointer[Float32, MutAnyOrigin], x: Int, y: Int) -> Float32:
    """The standard nine-point weighted Laplacian: corners a twentieth,
    edges a fifth, the centre minus one whole. The weights sum to zero,
    which is what makes this a rate of CHANGE rather than a blur -- a
    perfectly flat field produces zero here no matter what value it is
    flat at."""
    var s = Float32(0.0)
    s += _at(f, x - 1, y - 1) * Float32(0.05)
    s += _at(f, x, y - 1) * Float32(0.2)
    s += _at(f, x + 1, y - 1) * Float32(0.05)
    s += _at(f, x - 1, y) * Float32(0.2)
    s += _at(f, x, y) * Float32(-1.0)
    s += _at(f, x + 1, y) * Float32(0.2)
    s += _at(f, x - 1, y + 1) * Float32(0.05)
    s += _at(f, x, y + 1) * Float32(0.2)
    s += _at(f, x + 1, y + 1) * Float32(0.05)
    return s


def grayscott_kernel(
    u_out: Pointer[Float32, MutAnyOrigin],
    v_out: Pointer[Float32, MutAnyOrigin],
    u_in: Pointer[Float32, MutAnyOrigin],
    v_in: Pointer[Float32, MutAnyOrigin],
    feed: Float32,
    kill: Float32,
):
    """One reaction-diffusion step, one cell, reading the OLD pair and
    writing the NEW one -- never in place, since every neighbour read
    needs last step's values, not whatever this thread has already
    written this step.

    The reaction term `u*v*v` is the whole model's personality: V can
    only eat U where both are already present, which is why a single
    catalyst speck grows outward along its own edge rather than consuming
    everything at once. `feed` replenishes U everywhere, `kill` (added to
    `feed`) removes V everywhere -- balance those two rates differently
    and the same equation stops making spots and starts making worms.
    """
    var idx = Int(global_idx.x)
    if idx < CELLS:
        var x = idx % WIDTH
        var y = idx // WIDTH
        var u = _at(u_in, x, y)
        var v = _at(v_in, x, y)
        var uvv = u * v * v
        var du = DU * _laplacian(u_in, x, y) - uvv + feed * (Float32(1.0) - u)
        var dv = DV * _laplacian(v_in, x, y) + uvv - (feed + kill) * v
        var nu = u + du * DT
        var nv = v + dv * DT
        if nu < Float32(0.0):
            nu = Float32(0.0)
        elif nu > Float32(1.0):
            nu = Float32(1.0)
        if nv < Float32(0.0):
            nv = Float32(0.0)
        elif nv > Float32(1.0):
            nv = Float32(1.0)
        u_out[unsafe_offset=idx] = nu
        v_out[unsafe_offset=idx] = nv


def seed_kernel(
    u: Pointer[Float32, MutAnyOrigin],
    v: Pointer[Float32, MutAnyOrigin],
    cx: Int32,
    cy: Int32,
    r2: Int32,
):
    """Paint a disc of catalyst: U half-consumed, V present -- exactly
    what a real drop of the second chemical looks like the instant after
    it lands. Used both for the initial seeding and for the mouse.

    Int32, not Int: a kernel argument must be fixed-width to conform to
    DevicePassable -- plain Int (and UInt) do not, a constraint that only
    bites here because this is the one kernel in the file passing a bare
    integer rather than a Pointer or a Float32."""
    var idx = Int(global_idx.x)
    if idx < CELLS:
        var x = Int32(idx % WIDTH)
        var y = Int32(idx // WIDTH)
        var dx = x - cx
        var dy = y - cy
        if dx * dx + dy * dy <= r2:
            u[unsafe_offset=idx] = Float32(0.5)
            v[unsafe_offset=idx] = Float32(1.0)


@always_inline
def _pack(b: UInt32, g: UInt32, r: UInt32) -> UInt32:
    # BGRA8Unorm little-endian: byte0=B, byte1=G, byte2=R, byte3=A.
    return b | (g << 8) | (r << 16) | (UInt32(255) << 24)


def color_kernel(
    dst: Pointer[UInt32, MutAnyOrigin],
    v: Pointer[Float32, MutAnyOrigin],
    phase: Float32,
):
    """V alone carries the picture: everywhere U has not been eaten sits
    at the same becalmed 1.0, so V's shape IS the pattern. A cosine
    palette -- three cosines a third of a cycle apart, Mandelbrot's own
    trick here tuned to a different register -- turns the 0..1 field into
    deep water climbing through coral toward bone, and a separate shade
    term darkens the untouched sea toward black rather than letting the
    cosines paint a colour where nothing is actually happening.
    """
    var idx = Int(global_idx.x)
    if idx < CELLS:
        var t = v[unsafe_offset=idx]
        var tt = t * Float32(2.2) + phase
        var r = Float32(0.5) + Float32(0.5) * cos(TAU * (tt + Float32(0.10)))
        var g = Float32(0.5) + Float32(0.5) * cos(TAU * (tt + Float32(0.45)))
        var b = Float32(0.5) + Float32(0.5) * cos(TAU * (tt + Float32(0.65)))
        var shade = t * Float32(3.0)
        if shade > Float32(1.0):
            shade = Float32(1.0)
        dst[unsafe_offset=idx] = _pack(
            UInt32(b * shade * Float32(255)),
            UInt32(g * shade * Float32(255)),
            UInt32(r * shade * Float32(255)),
        )


# ===----------------------------------------------------------------------=== #
# Saving a frame -- `fluid`'s own `save_png`, carried over verbatim except
# for WIN_W/WIN_H becoming WIDTH/HEIGHT: example folders are self-contained
# by this tree's own convention, so this is a copy, not an import. libz's
# `compress2`/`crc32` do the real work; a PNG is otherwise four chunks.
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
# Input arrives on Cocoa's schedule; frames happen on ours. Flags and two
# payload globals (a click position, a requested preset), read and cleared
# once a frame on the thread that owns the GPU -- Mandelbrot's own scheme.
# ===----------------------------------------------------------------------=== #

comptime CMD_CLICK = 1
comptime CMD_PAUSE = 2
comptime CMD_RESET = 4
comptime CMD_QUIT = 8
comptime CMD_PRESET = 16
comptime CMD_SAVE = 32

comptime g_cmd = named_global["grayscott.cmd", Int]
comptime g_click_x = named_global["grayscott.click.x", Int]
comptime g_click_y = named_global["grayscott.click.y", Int]
comptime g_want_preset = named_global["grayscott.preset", Int]


def _mark_click(view: ObjCObject, event: ObjCObject):
    """Record where a click or drag landed, in the view's own (flipped)
    coordinates -- a free function, not a class method, matching how
    `gamepane/metal/window.mojo`'s `_record_position` is called FROM a
    handful of selector methods rather than living inside the class."""
    var at = Obj["NSEvent"](event.addr()).locationInWindow()
    var local = Obj["NSView"](view.addr()).convertPoint(at, fromView=ObjCObject(0))
    g_click_x()[] = Int(local.x)
    g_click_y()[] = Int(local.y)
    g_cmd()[] |= CMD_CLICK


class GrayScottView(NSView):
    """The window's content view. Cocoa calls these; they only set flags."""

    def acceptsFirstResponder(self) -> Bool:
        return True

    def isFlipped(self) -> Bool:
        # Origin at the top-left, exactly as the kernel counts cells.
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
            # Digit keys, by byte value rather than a String ordering
            # comparison -- ASCII '1' is 49, '6' is 54.
            let kb = key.as_bytes()[0]
            if kb >= 49 and kb <= 54:
                g_want_preset()[] = Int(kb) - 49
                g_cmd()[] |= CMD_PRESET


def main() raises:
    if not load_framework["AppKit"]():
        raise Error("could not load AppKit")

    var frame_limit = 0
    let door = getenv("GRAYSCOTT_FRAMES")
    if door != "":
        frame_limit = Int(door)

    var preset = 2                       # start on "maze" -- an easy, busy one
    var feed = preset_feed(preset)
    var kill = preset_kill(preset)
    var phase = Float32(0.0)

    print("Gray-Scott", WIDTH, "x", HEIGHT, "— preset", preset_name(preset))

    var ctx = DeviceContext(api="metal")
    print("  GPU:", ctx.name())
    var u = ctx.enqueue_create_buffer[DType.float32](CELLS)
    var v = ctx.enqueue_create_buffer[DType.float32](CELLS)
    var u2 = ctx.enqueue_create_buffer[DType.float32](CELLS)
    var v2 = ctx.enqueue_create_buffer[DType.float32](CELLS)
    var dev = ctx.enqueue_create_buffer[DType.uint32](CELLS)

    var gs_kern = ctx.compile_function[grayscott_kernel]()
    var seed_kern = ctx.compile_function[seed_kernel]()
    var color_kern = ctx.compile_function[color_kernel]()

    # Not a nested function: a DeviceContext and its buffers captured by a
    # closure is untested ground, and this is called from exactly two
    # places, so inlining both times is the safer six lines.
    ctx.enqueue_memset(u, Float32(1.0))
    ctx.enqueue_memset(v, Float32(0.0))
    for _i in range(SEED_BLOBS):
        var rx0 = Int32(random_ui64(60, WIDTH - 60))
        var ry0 = Int32(random_ui64(60, HEIGHT - 60))
        ctx.enqueue_function(
            seed_kern, u, v, rx0, ry0, SEED_R2,
            grid_dim=(GRID), block_dim=(BLOCK),
        )
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
        win.title = "Gray-Scott — every cell is Mojo"

        var view = ObjCObject(GrayScottView().__objc_id)
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

        print("Rendering. drag paints · 1-6 presets · r reseeds · space pauses · q quits")
        var frames = 0
        var shots = 0
        var running = True
        var paused = False
        var save_wanted = False
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
                if (pending & CMD_CLICK) != 0:
                    ctx.enqueue_function(
                        seed_kern, u, v,
                        Int32(g_click_x()[]), Int32(g_click_y()[]), SEED_R2,
                        grid_dim=(GRID), block_dim=(BLOCK),
                    )
                if (pending & CMD_PAUSE) != 0:
                    paused = not paused
                if (pending & CMD_RESET) != 0:
                    ctx.enqueue_memset(u, Float32(1.0))
                    ctx.enqueue_memset(v, Float32(0.0))
                    for _i in range(SEED_BLOBS):
                        var rx1 = Int32(random_ui64(60, WIDTH - 60))
                        var ry1 = Int32(random_ui64(60, HEIGHT - 60))
                        ctx.enqueue_function(
                            seed_kern, u, v, rx1, ry1, SEED_R2,
                            grid_dim=(GRID), block_dim=(BLOCK),
                        )
                if (pending & CMD_PRESET) != 0:
                    preset = g_want_preset()[]
                    feed = preset_feed(preset)
                    kill = preset_kill(preset)
                    win.title = "Gray-Scott — " + preset_name(preset)
                if (pending & CMD_SAVE) != 0:
                    save_wanted = True
                if (pending & CMD_QUIT) != 0:
                    running = False

            if not paused:
                for _step in range(SUBSTEPS // 2):
                    ctx.enqueue_function(
                        gs_kern, u2, v2, u, v, feed, kill,
                        grid_dim=(GRID), block_dim=(BLOCK),
                    )
                    ctx.enqueue_function(
                        gs_kern, u, v, u2, v2, feed, kill,
                        grid_dim=(GRID), block_dim=(BLOCK),
                    )

            ctx.enqueue_function(
                color_kern, dev, v, phase, grid_dim=(GRID), block_dim=(BLOCK)
            )
            ctx.synchronize()
            with dev.map_to_host() as pix:
                var src = pix.unsafe_ptr()
                for k in range(CELLS):
                    bgra[unsafe_offset=k] = src[unsafe_offset=k]

            # Save here, not later: `bgra` is exactly what is about to be
            # presented, so the file and the window cannot disagree.
            if save_wanted:
                save_wanted = False
                var path = String("/tmp/grayscott-") + String(shots) + ".png"
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

            # A headless run (GRAYSCOTT_FRAMES) leaves one PNG of its last
            # frame behind -- a CI run produces something a person can
            # actually look at, not just an exit code.
            if frame_limit != 0 and frames + 1 >= frame_limit:
                if save_png("/tmp/grayscott-headless.png", bgra):
                    print("saved /tmp/grayscott-headless.png")

            frames += 1
            phase += Float32(0.0015)
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
