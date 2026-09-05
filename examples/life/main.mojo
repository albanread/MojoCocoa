# ===----------------------------------------------------------------------=== #
# Conway's Game of Life — a native Cocoa version, in Mojo.
#
# What the pygame example doesn't do, and this does:
#   · pause and resume, and single-step while paused
#   · draw cells with the mouse (and erase with shift or the right button)
#   · colour cells by AGE — newborns burn white-hot, survivors settle through
#     green to deep blue, and cells that die leave a fading ember trail, so you
#     can see the structure of a pattern rather than a flat green mask
#   · clear, randomise, and speed control, with live stats in the title bar
#
# Rendering is a BGRA buffer blitted into a CAMetalLayer drawable, the same
# path the Mandelbrot uses. Every AppKit call goes through std.objc, and the
# view, the app delegate and the timer target are `class` declarations -- real
# Objective-C classes the compiler registers, whose methods the runtime calls
# directly.
# ===----------------------------------------------------------------------=== #

from std.objc import (
    load_framework,
    Cls,
    Obj,
    ObjCObject,
    send,
    nsenum,
    ns_to_string,
    CGPoint,
    CGSize,
    CGRect,
    autoreleasepool,
    named_global,
    sel,
)
from std.ffi import external_call, c_char
from std.memory import OpaquePointer, Pointer
from std.collections.string.string_span import _get_kgen_string
from std.random import random_ui64
from std.time import perf_counter_ns

comptime P = OpaquePointer[MutUntrackedOrigin]

comptime CELL = 6
comptime GRID_W = 180
comptime GRID_H = 120
comptime WIN_W = GRID_W * CELL  # 1080
comptime WIN_H = GRID_H * CELL  # 720
comptime CELLS = GRID_W * GRID_H
comptime PIXELS = WIN_W * WIN_H
comptime MAX_AGE = 64


@fieldwise_init
struct MTLOrigin(Copyable, Movable):
    var x: Int
    var y: Int
    var z: Int


@fieldwise_init
struct MTLSize(Copyable, Movable):
    var width: Int
    var height: Int
    var depth: Int


@fieldwise_init
struct MTLRegion(Copyable, Movable):
    var origin: MTLOrigin
    var size: MTLSize



@always_inline
def _sym[name: StaticString]() -> P:
    return P(
        _mlir_value=__mlir_op.`pop.extern_ptr_symbol`[
            name=_get_kgen_string[name](),
            alignment=Int(1).__mlir_index__(),
            _type=P._mlir_type,
        ]()
    )


def alloc_zeroed(count: Int, size: Int) -> Int:
    """Zeroed heap memory that nothing in Mojo owns.

    The buffers must outlive `main`'s locals: Mojo destroys a value at its LAST
    USE, not at end of scope, so a `List` whose `.unsafe_ptr()` we stash is
    freed immediately and every stored pointer dangles -- which shows up much
    later as a corrupted allocator, nowhere near the cause. Owning the memory
    outside Mojo makes the lifetime explicit and correct.
    """
    var sym = _sym["calloc"]()
    var call = Pointer(to=sym).unsafe_bitcast[
        def(Int, Int, /) thin abi("C") -> P
    ]()[]
    return Int(call(count, size))


# ── State (callbacks get no closure, so it lives in named globals) ───────────
comptime g_alive = named_global["life.alive", Int]  # UInt8*  per cell 0/1
comptime g_next = named_global["life.next", Int]  # UInt8*  scratch
comptime g_age = named_global["life.age", Int]  # UInt16* generations survived
comptime g_decay = named_global["life.decay", Int]  # UInt8*  ember trail
comptime g_frame = named_global["life.frame", Int]  # UInt32* BGRA pixels

comptime g_layer = named_global["life.layer", Int]
comptime g_queue = named_global["life.queue", Int]
comptime g_window = named_global["life.window", Int]
comptime g_running = named_global["life.running", Int]
comptime g_gen = named_global["life.gen", Int]
comptime g_speed = named_global["life.speed", Int]  # evolve every N ticks
comptime g_tick = named_global["life.tick", Int]
comptime g_dirty = named_global["life.dirty", Int]


@always_inline
def alive_ptr() -> Pointer[UInt8, MutUntrackedOrigin]:
    return Pointer[UInt8, MutUntrackedOrigin](
        unsafe_from_address=g_alive()[]
    )


@always_inline
def next_ptr() -> Pointer[UInt8, MutUntrackedOrigin]:
    return Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=g_next()[])


@always_inline
def age_ptr() -> Pointer[UInt16, MutUntrackedOrigin]:
    return Pointer[UInt16, MutUntrackedOrigin](unsafe_from_address=g_age()[])


@always_inline
def decay_ptr() -> Pointer[UInt8, MutUntrackedOrigin]:
    return Pointer[UInt8, MutUntrackedOrigin](
        unsafe_from_address=g_decay()[]
    )


@always_inline
def frame_ptr() -> Pointer[UInt32, MutUntrackedOrigin]:
    return Pointer[UInt32, MutUntrackedOrigin](
        unsafe_from_address=g_frame()[]
    )


# ── The simulation ──────────────────────────────────────────────────────────


def evolve():
    """One generation, with the neighbour count on a wrapped torus so gliders
    sail off one edge and back in the other."""
    var alive = alive_ptr()
    var nxt = next_ptr()
    var age = age_ptr()
    var decay = decay_ptr()

    for y in range(GRID_H):
        var up = (y + GRID_H - 1) % GRID_H * GRID_W
        var mid = y * GRID_W
        var dn = (y + 1) % GRID_H * GRID_W
        for x in range(GRID_W):
            var l = (x + GRID_W - 1) % GRID_W
            var r = (x + 1) % GRID_W
            var n = (
                Int(alive[unsafe_offset = up + l])
                + Int(alive[unsafe_offset = up + x])
                + Int(alive[unsafe_offset = up + r])
                + Int(alive[unsafe_offset = mid + l])
                + Int(alive[unsafe_offset = mid + r])
                + Int(alive[unsafe_offset = dn + l])
                + Int(alive[unsafe_offset = dn + x])
                + Int(alive[unsafe_offset = dn + r])
            )
            var i = mid + x
            var was = alive[unsafe_offset=i] != 0
            var now = (was and (n == 2 or n == 3)) or ((not was) and n == 3)
            nxt[unsafe_offset=i] = 1 if now else 0
            if now:
                var a = age[unsafe_offset=i]
                if a < UInt16(MAX_AGE):
                    age[unsafe_offset=i] = a + 1
            else:
                age[unsafe_offset=i] = 0
                if was:
                    decay[unsafe_offset=i] = 200  # fresh ember

    # Swap the buffers by swapping the globals -- no copying.
    var a = g_alive()[]
    g_alive()[] = g_next()[]
    g_next()[] = a

    # Fade the embers.
    var d = decay_ptr()
    for i in range(CELLS):
        var v = d[unsafe_offset=i]
        if v > UInt8(0):
            d[unsafe_offset=i] = v - 8 if v > UInt8(8) else UInt8(0)

    g_gen()[] += 1


@always_inline
def pack(b: Int, g: Int, r: Int) -> UInt32:
    return UInt32(b) | (UInt32(g) << 8) | (UInt32(r) << 16) | (
        UInt32(255) << 24
    )


def cell_color(age: UInt16, decay: UInt8) -> UInt32:
    """Colour tells you the cell's history.

    A newborn burns white; over its first generations it cools through cyan to
    green; a long survivor settles into deep blue. A cell that has just died
    leaves an ember that fades to the background. So a glider reads as a
    bright head with a warm tail, and a still life sits quiet and blue.
    """
    if age == UInt16(0):
        if decay == UInt8(0):
            return pack(22, 18, 16)  # background
        var d = Int(decay)
        # ember: dim orange-red fading out
        return pack(16 + d // 8, 24 + d // 4, 40 + d // 2)

    var a = Int(age)
    if a <= 2:
        return pack(235, 250, 255)  # newborn: white-hot
    if a <= 6:
        # cooling: white-cyan -> cyan
        var t = (a - 2) * 255 // 4
        return pack(235, 250 - t // 6, 255 - t)
    if a <= 20:
        # cyan -> green
        var t = (a - 6) * 255 // 14
        return pack(235 - t, 250, 40)
    # settled: green -> deep blue
    var t = (a - 20) * 255 // (MAX_AGE - 20)
    if t > 255:
        t = 255
    return pack(40 + t // 2, 250 - t, 40 + t // 3)


def render():
    """Paint the grid into the BGRA frame buffer, one CELL x CELL block per
    cell, leaving a one-pixel gutter so the lattice stays legible."""
    var alive = alive_ptr()
    var age = age_ptr()
    var decay = decay_ptr()
    var frame = frame_ptr()
    comptime bg = pack(14, 12, 11)

    for cy in range(GRID_H):
        for cx in range(GRID_W):
            var i = cy * GRID_W + cx
            var color = (
                cell_color(age[unsafe_offset=i], decay[unsafe_offset=i])
                if (alive[unsafe_offset=i] != 0)
                or decay[unsafe_offset=i] != UInt8(0)
                else bg
            )
            var px0 = cx * CELL
            var py0 = cy * CELL
            for dy in range(CELL - 1):
                var row = (py0 + dy) * WIN_W + px0
                for dx in range(CELL - 1):
                    frame[unsafe_offset = row + dx] = color
            # gutter column and row stay background
            for dy in range(CELL):
                frame[unsafe_offset = (py0 + dy) * WIN_W + px0 + CELL - 1] = bg
            for dx in range(CELL):
                frame[unsafe_offset = (py0 + CELL - 1) * WIN_W + px0 + dx] = bg


def randomize():
    var alive = alive_ptr()
    var age = age_ptr()
    var decay = decay_ptr()
    for i in range(CELLS):
        var on = random_ui64(0, 4) == 0
        alive[unsafe_offset=i] = 1 if on else 0
        age[unsafe_offset=i] = 1 if on else 0
        decay[unsafe_offset=i] = 0
    g_gen()[] = 0
    g_dirty()[] = 1


def clear_grid():
    var alive = alive_ptr()
    var age = age_ptr()
    var decay = decay_ptr()
    for i in range(CELLS):
        alive[unsafe_offset=i] = 0
        age[unsafe_offset=i] = 0
        decay[unsafe_offset=i] = 0
    g_gen()[] = 0
    g_dirty()[] = 1


def population() -> Int:
    var alive = alive_ptr()
    var n = 0
    for i in range(CELLS):
        if alive[unsafe_offset=i] != 0:
            n += 1
    return n


# ── Painting cells with the mouse ───────────────────────────────────────────


def paint_at(win_x: Float64, win_y: Float64, erase: Bool):
    """`win_*` is in window coordinates (origin bottom-left); the grid runs
    top-down, so the y axis is flipped here."""
    var cx = Int(win_x) // CELL
    var cy = (WIN_H - Int(win_y)) // CELL
    if cx < 0 or cx >= GRID_W or cy < 0 or cy >= GRID_H:
        return
    var alive = alive_ptr()
    var age = age_ptr()
    var decay = decay_ptr()
    # A 2x2 dab, so drawing feels like a pen rather than a pixel hunt.
    for dy in range(2):
        for dx in range(2):
            var x = cx + dx
            var y = cy + dy
            if x >= GRID_W or y >= GRID_H:
                continue
            var i = y * GRID_W + x
            if erase:
                alive[unsafe_offset=i] = 0
                age[unsafe_offset=i] = 0
            else:
                alive[unsafe_offset=i] = 1
                if age[unsafe_offset=i] == UInt16(0):
                    age[unsafe_offset=i] = 1
                decay[unsafe_offset=i] = 0
    g_dirty()[] = 1


def event_point(event: P) -> CGPoint:
    """-[NSEvent locationInWindow] -> NSPoint, typed through the kind ladder
    (two SSE registers, described to the ABI by the database)."""
    return Obj["NSEvent"](Int(event)).locationInWindow()


def event_has_shift(event: P) -> Bool:
    var flags = Obj["NSEvent"](Int(event)).modifierFlags()
    return (flags & nsenum["NSEventModifierFlagShift"]()) != 0


class LifeDelegate:
    def applicationShouldTerminateAfterLastWindowClosed_(
        self, app: ObjCObject
    ) -> Bool:
        return True


class LifeActions:
    """The timer's target.

    Named `lifeTick:` rather than `tick:` on the compiler's advice: the SDK
    declares a `tick:` on CASecureFlipBookLayer taking a double, and a
    selector we invent that collides with one the SDK knows would have been
    registered with that shape -- `v@:d` where we meant `v@:@`. The
    diagnostic said so. A selector nobody else declares gets its encoding
    derived, which is what happens here."""

    def lifeTick_(self, timer: ObjCObject):
        advance_tick()


# Key handling, kept a free function so the class body stays a list of
# selectors rather than a wall of logic.
def handle_key(event: P):
    # No pool here: this is called from AppKit's own event dispatch, which
    # already has one, and every object read is autoreleased by the caller.
    var s = ns_to_string(ObjCObject(
        Obj["NSEvent"](Int(event)).charactersIgnoringModifiers().id
    ))
    if len(s.as_bytes()) == 0:
        return
    var c = s.as_bytes()[0]

    if c == UInt8(ord(" ")):
        g_running()[] = 0 if g_running()[] != 0 else 1
    elif c == UInt8(ord("c")):
        clear_grid()
    elif c == UInt8(ord("r")):
        randomize()
    elif c == UInt8(ord(".")):
        evolve()  # single step (most useful while paused)
        g_dirty()[] = 1
    elif c == UInt8(ord("]")):
        if g_speed()[] > 1:
            g_speed()[] -= 1
    elif c == UInt8(ord("[")):
        if g_speed()[] < 30:
            g_speed()[] += 1


def update_title():
    var state = "running" if g_running()[] != 0 else "paused"
    var title = (
        "Life — gen "
        + String(g_gen()[])
        + "  ·  pop "
        + String(population())
        + "  ·  "
        + state
        + "  ·  speed "
        + String(31 - g_speed()[])
        + "   [space] pause  [drag] draw  [⇧drag] erase  [.] step  [r]"
        + " random  [c] clear  [ [ ] ] speed"
    )
    _ = Obj["NSWindow"](g_window()[]).setTitle(title)


def present():
    """Blit the frame buffer into the layer's next drawable.

    No early return: this runs inside the tick's autorelease pool, and
    returning out of a `with` block skips the pop.
    """
    var mlayer = Obj["CAMetalLayer"](g_layer()[])
    var drawable = mlayer.nextDrawable()
    if drawable.id != 0:
        var tex = Obj["CAMetalDrawable"](drawable.addr()).texture()
        var region = MTLRegion(
            MTLOrigin(0, 0, 0), MTLSize(WIN_W, WIN_H, 1)
        )
        _ = send[
            ObjCObject, "replaceRegion:mipmapLevel:withBytes:bytesPerRow:"
        ](
            tex,
            region,
            Int(0),
            P(unsafe_from_address=g_frame()[]),
            Int(WIN_W * 4),
        )
        var cb = send[ObjCObject, "commandBuffer"](ObjCObject(g_queue()[]))
        _ = send[ObjCObject, "presentDrawable:"](cb, drawable.ptr())
        _ = send[ObjCObject, "commit"](cb)


# ── The view, as a class ────────────────────────────────────────────────────
# Its mouse and key handlers are methods. An underscore in a method name is a
# colon in the selector, so `mouseDown_` answers `mouseDown:`; the encodings
# come from the SDK, and there is no IMP or `cmd` slot to write.


class LifeView(NSView):
    def mouseDown_(self, event: ObjCObject):
        var p = event_point(event.ptr())
        paint_at(p.x, p.y, event_has_shift(event.ptr()))

    def mouseDragged_(self, event: ObjCObject):
        var p = event_point(event.ptr())
        paint_at(p.x, p.y, event_has_shift(event.ptr()))

    def rightMouseDown_(self, event: ObjCObject):
        var p = event_point(event.ptr())
        paint_at(p.x, p.y, True)

    def rightMouseDragged_(self, event: ObjCObject):
        var p = event_point(event.ptr())
        paint_at(p.x, p.y, True)

    def acceptsFirstResponder(self) -> Bool:
        return True

    def keyDown_(self, event: ObjCObject):
        handle_key(event.ptr())


def advance_tick():
    with autoreleasepool():
        var stepped = False
        if g_running()[] != 0:
            g_tick()[] += 1
            if g_tick()[] >= g_speed()[]:
                g_tick()[] = 0
                evolve()
                stepped = True
        if stepped or g_dirty()[] != 0:
            g_dirty()[] = 0
            render()
            present()
            update_title()


def _unused_should_terminate() -> Bool:
    return True


def main() raises:
    # AppKit is not linked into a JIT-run process; without this the
    # NSApplication lookup is nil and the app exits silently.
    if not load_framework["AppKit"]():
        raise Error("could not load AppKit")
    # Buffers owned outside Mojo -- see alloc_zeroed for why a List would be
    # freed out from under these pointers.
    g_alive()[] = alloc_zeroed(CELLS, 1)
    g_next()[] = alloc_zeroed(CELLS, 1)
    g_age()[] = alloc_zeroed(CELLS, 2)
    g_decay()[] = alloc_zeroed(CELLS, 1)
    g_frame()[] = alloc_zeroed(PIXELS, 4)
    g_running()[] = 1
    g_speed()[] = 3
    randomize()

    with autoreleasepool():
        var app = Cls["NSApplication"]().sharedApplication()
        _ = app.setActivationPolicy(
            nsenum["NSApplicationActivationPolicyRegular"]()
        )

        # Instantiating a class is what registers it, so the delegate exists
        # in the runtime by the time it is handed over.
        var delegate = ObjCObject(LifeDelegate().__objc_id)
        _ = app.setDelegate(delegate)

        var view_instance = ObjCObject(LifeView().__objc_id)
        var actions = ObjCObject(LifeActions().__objc_id)
        _ = external_call["objc_retain", P](actions.ptr())

        var win = Obj["NSWindow"](
            contentRect=CGRect(
                CGPoint(100.0, 100.0), CGSize(Float64(WIN_W), Float64(WIN_H))
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
        g_window()[] = win.addr()

        # `LifeView()` is already allocated and initialised -- that is what
        # instantiating a class does -- so the frame is set rather than passed
        # to initWithFrame:.
        var view = view_instance
        _ = Obj["NSView"](view.addr()).setFrame(
            CGRect(CGPoint(0.0, 0.0), CGSize(Float64(WIN_W), Float64(WIN_H)))
        )
        _ = external_call["objc_retain", P](view.ptr())

        var display_dev = ObjCObject(
            Int(external_call["MTLCreateSystemDefaultDevice", P]())
        )
        var queue = send[ObjCObject, "newCommandQueue"](display_dev)
        _ = external_call["objc_retain", P](queue.ptr())
        g_queue()[] = queue.addr()

        # +layer's result class is not in the metadata, so CAMetalLayer is
        # stated once at the wrap and every call after it checks the class
        # that was meant.
        var layer = ObjCObject(Cls["CAMetalLayer"]().layer().id)
        var mlayer = Obj["CAMetalLayer"](layer.addr())
        _ = send[ObjCObject, "setDevice:"](layer, display_dev.ptr())
        _ = mlayer.setPixelFormat(nsenum["MTLPixelFormatBGRA8Unorm"]())
        _ = mlayer.setFramebufferOnly(False)
        _ = mlayer.setDrawableSize(CGSize(Float64(WIN_W), Float64(WIN_H)))
        _ = external_call["objc_retain", P](layer.ptr())
        g_layer()[] = layer.addr()

        var view_t = Obj["NSView"](view.addr())
        _ = view_t.setWantsLayer(True)
        _ = view_t.setLayer(layer)
        _ = win.setContentView(view)
        _ = win.makeFirstResponder(view)

        # The tick: a five-label factory, every part checked.
        comptime NSTimer = Obj["NSTimer"]
        _ = NSTimer(
            scheduledTimerWithTimeInterval=Float64(1.0 / 60.0),
            target=actions,
            selector=sel["lifeTick:"]().ptr(),
            userInfo=actions,
            repeats=True,
        )

        render()
        update_title()
        _ = win.makeKeyAndOrderFront(ObjCObject(app.id))
        _ = app.activateIgnoringOtherApps(True)

    _ = Cls["NSApplication"]().sharedApplication().run()
