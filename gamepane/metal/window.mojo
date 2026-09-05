"""The game window: NSWindow, a CAMetalLayer, a key-capable view, and the
loop — the Cocoa half of Sprint G1.

The Rust engine hands the game a per-frame closure. Mojo's C-ABI `fn` cannot
capture, and `chip.mojo` already shows the better shape: the GAME owns the
loop, and the pane exposes the two halves of a frame.

    while pane.pump():          # drain events; False once the window closes
        ...                     # the game's own work
        pane.present()          # composite and show

`run(tick)` is offered for games that prefer one line; it is exactly
`while pump(): tick(); present()`.

The loop is hand-rolled rather than `[NSApp run]` for the reason every other
example in this tree gives: the thing that owns the resource has to be the
thing that drives the app, and here it will own an audio unit that must be
stopped before the process exits.
"""

from std.objc import (
    load_framework,
    Cls,
    Obj,
    ObjCObject,
    NSView,
    send,
    nsenum,
    nsstring,
    autoreleasepool,
    named_global,
    sel,
    MTLOrigin,
    MTLSize,
    MTLRegion,
    MTLClearColor,
)
from std.ffi import external_call
from std.memory import OpaquePointer, Pointer
from std.time import perf_counter_ns
from std.os import getenv

from max.gpu.host import DeviceContext

from gamepane.api import MAX_KEY_CODE, MouseState, GamepadState
from .device import metal_device

comptime P = OpaquePointer[MutUntrackedOrigin]


# ── Input state ─────────────────────────────────────────────────────────────
# A method the Objective-C runtime calls captures nothing, so the handlers
# have nowhere to write but a global -- the same reason the Rust engine used
# statics. One game window per process is the accepted limit, and it is the
# Rust's limit too.
comptime g_keys = named_global["gamepane.keys", List[Int]]
comptime g_mouse = named_global["gamepane.mouse", List[Float64]]
comptime g_view = named_global["gamepane.view", Int]

comptime M_X = 0
comptime M_Y = 1
comptime M_LEFT = 2
comptime M_RIGHT = 3


def _ensure_state():
    """The globals start empty; size them once."""
    if len(g_keys()[]) == 0:
        for _ in range(MAX_KEY_CODE):
            g_keys()[].append(0)
    if len(g_mouse()[]) == 0:
        for _ in range(4):
            g_mouse()[].append(0.0)


def key_held(code: Int) -> Bool:
    """Whether `code` is down right now. Out of range is False, never a trap.
    """
    if code < 0 or code >= len(g_keys()[]):
        return False
    return g_keys()[][code] != 0


def mouse_state() -> MouseState:
    let m = g_mouse()[]
    if len(m) < 4:
        return MouseState(0.0, 0.0, False, False)
    return MouseState(m[M_X], m[M_Y], m[M_LEFT] != 0.0, m[M_RIGHT] != 0.0)


def clear_input():
    """Release every key and button.

    A game should call this when its window gains or loses focus. Held state
    is only ever cleared by a keyUp: delivered to THIS view, so a key still
    physically down across a focus change -- an Escape that swaps the view
    out, whose keyUp: then goes elsewhere -- would otherwise stay held for
    the rest of the session. The mouse has the identical hazard: a mouseUp:
    that lands after the view is gone leaves the button reading down, and the
    next session starts painting without anyone touching the mouse.
    """
    _ensure_state()
    for i in range(len(g_keys()[])):
        g_keys()[][i] = 0
    g_mouse()[][M_LEFT] = 0.0
    g_mouse()[][M_RIGHT] = 0.0


def _record_position(view: ObjCObject, event: ObjCObject):
    """Store the mouse position, normalised and flipped to a top-left origin.

    `convertPoint:fromView:` with nil is the canonical window-to-view
    conversion. The content view's frame origin happens to equal the window
    origin today, but that stops being true the moment anyone adds
    NSFullSizeContentView, so this converts rather than assumes.
    """
    let loc = Obj["NSEvent"](event.addr()).locationInWindow()
    let p = Obj["NSView"](view.addr()).convertPoint_fromView(
        loc, ObjCObject(0)
    )
    let b = Obj["NSView"](view.addr()).bounds()
    if b.size.width <= 0.0 or b.size.height <= 0.0:
        return  # a zero-sized view would divide to NaN
    var fx = (p.x - b.origin.x) / b.size.width
    var fy = (p.y - b.origin.y) / b.size.height
    if fx < 0.0:
        fx = 0.0
    elif fx > 1.0:
        fx = 1.0
    if fy < 0.0:
        fy = 0.0
    elif fy > 1.0:
        fy = 1.0
    g_mouse()[][M_X] = fx
    g_mouse()[][M_Y] = 1.0 - fy  # AppKit's origin is bottom-left; ours is not


# ── The view ────────────────────────────────────────────────────────────────
# A plain NSView answers NO to acceptsFirstResponder, so keyDown:/keyUp:
# would never arrive. `class` declares the subclass that does.


class GameView(NSView):
    def acceptsFirstResponder(self) -> Bool:
        return True

    def acceptsFirstMouse_(self, event: ObjCObject) -> Bool:
        """YES, so a click on an inactive game window ACTS rather than merely
        activating it. AppKit's default swallows that first click to bring
        the window forward -- fine for a document, wrong for a game whose
        window sits beside an editor: the click the player aimed at a cell
        would silently do nothing."""
        return True

    def keyDown_(self, event: ObjCObject):
        let code = Int(Obj["NSEvent"](event.addr()).keyCode())
        if code >= 0 and code < len(g_keys()[]):
            g_keys()[][code] = 1

    def keyUp_(self, event: ObjCObject):
        let code = Int(Obj["NSEvent"](event.addr()).keyCode())
        if code >= 0 and code < len(g_keys()[]):
            g_keys()[][code] = 0

    def mouseDown_(self, event: ObjCObject):
        _record_position(ObjCObject(g_view()[]), event)
        g_mouse()[][M_LEFT] = 1.0

    def mouseUp_(self, event: ObjCObject):
        _record_position(ObjCObject(g_view()[]), event)
        g_mouse()[][M_LEFT] = 0.0

    def rightMouseDown_(self, event: ObjCObject):
        _record_position(ObjCObject(g_view()[]), event)
        g_mouse()[][M_RIGHT] = 1.0

    def rightMouseUp_(self, event: ObjCObject):
        _record_position(ObjCObject(g_view()[]), event)
        g_mouse()[][M_RIGHT] = 0.0

    def mouseDragged_(self, event: ObjCObject):
        # A drag is a held button that moves, so only the position changes:
        # painting into a grid is a drag, not a sequence of clicks.
        _record_position(ObjCObject(g_view()[]), event)

    def rightMouseDragged_(self, event: ObjCObject):
        _record_position(ObjCObject(g_view()[]), event)


# ── Gamepad ─────────────────────────────────────────────────────────────────
# GameController.framework has NO classes in cocoa.sqlite -- it was not loaded
# when the database was built -- so these go through `send` until it is. The
# selectors are Apple's long-stable public ones, used as documented rather
# than checked against metadata like everything else here.


def gamepad_state() -> GamepadState:
    if not load_framework["GameController"]():
        return GamepadState(False, False, False, 0.0, 0.0)
    let cls = ObjCObject(Cls["GCController"]().cls_id)
    if cls.addr() == 0:
        return GamepadState(False, False, False, 0.0, 0.0)
    let list = send[ObjCObject, "controllers"](cls)
    if list.addr() == 0:
        return GamepadState(False, False, False, 0.0, 0.0)
    let n = Int(send[Int, "count"](list))
    for i in range(n):
        let c = send[ObjCObject, "objectAtIndex:"](list, i)
        let pad = send[ObjCObject, "extendedGamepad"](c)
        if pad.addr() == 0:
            continue
        var a = False
        var b = False
        let ba = send[ObjCObject, "buttonA"](pad)
        if ba.addr() != 0:
            a = send[Bool, "isPressed"](ba)
        let bb = send[ObjCObject, "buttonB"](pad)
        if bb.addr() != 0:
            b = send[Bool, "isPressed"](bb)
        var sx = 0.0
        var sy = 0.0
        let stick = send[ObjCObject, "leftThumbstick"](pad)
        if stick.addr() != 0:
            sx = send[Float64, "xAxis"](stick)
            sy = send[Float64, "yAxis"](stick)
        return GamepadState(True, a, b, sx, sy)
    return GamepadState(False, False, False, 0.0, 0.0)


# The pane's ground, and the colour a cleared frame dumps as. Not black on
# purpose: a dump of pure zeroes proves only that a buffer was allocated,
# while a dump of THIS proves the value travelled all the way through the
# render pass and back out of the drawable's texture. A harness can compute
# the byte it expects -- round(c * 255) -- and compare.
comptime CLEAR_R = 0.05
comptime CLEAR_G = 0.05
comptime CLEAR_B = 0.09


# ── One frame ──────────────────────────────────────────


@fieldwise_init
struct Frame(Copyable, Movable):
    """The three Objective-C objects a layer needs to draw one frame, and
    whether there was a frame to draw at all.

    Plain `Int`s rather than retained handles: everything here lives inside
    the autorelease pool of the `begin_frame`/`end_frame` pair, and a layer
    that outlives that pair has already lost. `valid` is False when the
    compositor had no drawable ready -- a normal thing under load, and every
    layer's `render` returns immediately on it.
    """

    var drawable: Int
    var target: Int
    var cb: Int
    var valid: Bool


# ── The pane ────────────────────────────────────────────────────────────────


struct GamePane(Movable):
    """A window, a Metal layer, and the loop around them."""

    var window: Int
    var view: Int
    var layer: Int
    var ctx: DeviceContext
    var device: Int
    var queue: Int
    var app: Int
    var width: Int
    var height: Int
    var last_ns: Int
    var dt_secs: Float64
    var frames: Int
    var frame_limit: Int
    """GAMEPANE_FRAMES: render this many, then stop. 0 means run until
    closed."""
    var dump_path: String
    """GAMEPANE_DUMP: write the last frame here as raw BGRA."""

    def __init__(out self, title: String, width: Int, height: Int) raises:
        if not load_framework["AppKit"]():
            raise Error("could not load AppKit")
        if not load_framework["Metal"]():
            raise Error("could not load Metal")
        _ensure_state()

        self.width = width
        self.height = height
        self.frames = 0
        self.dt_secs = 1.0 / 60.0
        self.last_ns = Int(perf_counter_ns())

        var limit = 0
        let fenv = getenv("GAMEPANE_FRAMES")
        if fenv != "":
            limit = atol(fenv)
        self.frame_limit = limit
        self.dump_path = getenv("GAMEPANE_DUMP")

        with autoreleasepool():
            let app = Cls["NSApplication"]().sharedApplication()
            # A harness run must not take the screen from whoever is working,
            # so a frame-limited run is an unfocused Accessory -- the ferns'
            # idiom, which already behaves this way in CI.
            if limit > 0:
                _ = app.setActivationPolicy(
                    nsenum["NSApplicationActivationPolicyAccessory"]()
                )
            else:
                _ = app.setActivationPolicy(
                    nsenum["NSApplicationActivationPolicyRegular"]()
                )
            self.app = app.id

            # The RUNTIME's device, not MTLCreateSystemDefaultDevice's.
            # Every layer, pipeline, texture and kernel in the pane then
            # shares one MTLDevice, and a texture made by one and sampled by
            # another is impossible rather than merely unlikely. G0 found
            # them to be the same object here; this makes that irrelevant.
            self.ctx = DeviceContext(api="metal")
            let dev = ObjCObject(metal_device(self.ctx))
            if dev.addr() == 0:
                raise Error("no Metal device")
            _ = external_call["objc_retain", P](dev.ptr())
            self.device = dev.addr()
            let q = send[ObjCObject, "newCommandQueue"](dev)
            _ = external_call["objc_retain", P](q.ptr())
            self.queue = q.addr()

            var win = Obj["NSWindow"](
                contentRect=rect(0.0, 0.0, Float64(width), Float64(height)),
                styleMask=(
                    nsenum["NSWindowStyleMaskTitled"]()
                    | nsenum["NSWindowStyleMaskClosable"]()
                    | nsenum["NSWindowStyleMaskMiniaturizable"]()
                ),
                backing=nsenum["NSBackingStoreBuffered"](),
                defer=False,
            )
            _ = win.setTitle(nsstring(title).ptr())
            # Not optional. An NSWindow made this way is releasedWhenClosed
            # by default, so closing it frees the object the loop below is
            # still asking `isVisible` -- which the chip example's own review
            # caught the hard way.
            _ = win.setReleasedWhenClosed(False)
            _ = external_call["objc_retain", P](win.ptr())
            self.window = win.addr()

            let view = ObjCObject(GameView().__objc_id)
            _ = Obj["NSView"](view.addr()).setFrame(
                rect(0.0, 0.0, Float64(width), Float64(height))
            )
            # The Mojo wrapper owns the only reference until this line, and
            # releases at the end of the statement that made it -- after
            # which AppKit holds a freed object and the first event traps
            # somewhere with a stack that says nothing about ownership.
            _ = external_call["objc_retain", P](view.ptr())
            self.view = view.addr()
            g_view()[] = view.addr()

            let layer = ObjCObject(Cls["CAMetalLayer"]().layer().id)
            var mlayer = Obj["CAMetalLayer"](layer.addr())
            _ = send[ObjCObject, "setDevice:"](layer, dev.ptr())
            _ = mlayer.setPixelFormat(nsenum["MTLPixelFormatBGRA8Unorm"]())
            _ = mlayer.setFramebufferOnly(False)
            _ = mlayer.setDrawableSize(
                CGSize(Float64(width), Float64(height))
            )
            _ = external_call["objc_retain", P](layer.ptr())
            self.layer = layer.addr()

            var vt = Obj["NSView"](view.addr())
            _ = vt.setWantsLayer(True)
            _ = vt.setLayer(layer)
            _ = win.setContentView(view)
            _ = win.makeFirstResponder(view)
            _ = win.makeKeyAndOrderFront(ObjCObject(app.id))
            if limit == 0:
                _ = app.activateIgnoringOtherApps(True)

    def pump(mut self) -> Bool:
        """Drain every pending event, then say whether to keep going.

        False once the window is closed, or once GAMEPANE_FRAMES have been
        presented.
        """
        if self.frame_limit > 0 and self.frames >= self.frame_limit:
            return False
        with autoreleasepool():
            let app = Obj["NSApplication"](self.app)
            var mode = nsstring("kCFRunLoopDefaultMode")
            while True:
                var past = Cls["NSDate"]().distantPast()
                var ev = app.nextEventMatchingMask(
                    UInt64.MAX,
                    untilDate=ObjCObject(past.id),
                    inMode=mode,
                    dequeue=True,
                )
                if ev.id == 0:
                    break
                _ = app.sendEvent(ObjCObject(ev.id))
            if not Obj["NSWindow"](self.window).isVisible():
                return False
        let now = Int(perf_counter_ns())
        var elapsed = Float64(now - self.last_ns) / 1_000_000_000.0
        # A first frame, or a stall behind a breakpoint, must not hand the
        # game a dt it will integrate into a teleport.
        if elapsed <= 0.0 or elapsed > 0.25:
            elapsed = 1.0 / 60.0
        self.dt_secs = elapsed
        self.last_ns = now
        return True

    def dt(self) -> Float64:
        """Seconds since the previous frame, clamped to something sane."""
        return self.dt_secs

    def frame_count(self) -> Int:
        return self.frames

    def begin_frame(mut self) raises -> Frame:
        """Acquire the drawable and open one command buffer for the frame.

        Every layer encodes into THIS command buffer, in the order the game
        calls them, which is what makes the composite a composite: layer 0
        loads `Clear` and each layer above it loads `Load`, and the GPU sees
        one submission rather than a stack of them. A `Frame` whose `valid`
        is False means the compositor had no drawable ready -- skip the
        frame, it is not an error.
        """
        # THE ORDERING RULE. Blits are enqueued on the runtime's stream and
        # frames are encoded on the layer's command queue -- two submission
        # paths to the same device, with nothing implicitly ordering them.
        # So every enqueued blit is completed here, before the frame that
        # would show it is encoded. It is done automatically because the
        # failure mode is a frame late by one, which looks like a game bug
        # rather than a missing call; a game that wants to blit again
        # mid-frame can still say `finish` itself.
        self.ctx.synchronize()
        let mlayer = Obj["CAMetalLayer"](self.layer)
        let drawable = mlayer.nextDrawable()
        if drawable.id == 0:
            return Frame(0, 0, 0, False)
        let target = Obj["CAMetalDrawable"](drawable.addr()).texture()
        let cb = send[ObjCObject, "commandBuffer"](ObjCObject(self.queue))
        return Frame(drawable.addr(), target.addr(), cb.addr(), True)

    def end_frame(mut self, frame: Frame) raises:
        """Present and commit. Under GAMEPANE_DUMP the last frame is waited
        on and written out, which is the only thing that costs anything."""
        if not frame.valid:
            return
        let cb = ObjCObject(frame.cb)
        _ = send[ObjCObject, "presentDrawable:"](cb, ObjCObject(frame.drawable).ptr())
        _ = send[ObjCObject, "commit"](cb)

        self.frames += 1
        if (
            self.frame_limit > 0
            and self.frames >= self.frame_limit
            and len(self.dump_path.as_bytes()) > 0
        ):
            _ = send[ObjCObject, "waitUntilCompleted"](cb)
            self._dump(ObjCObject(frame.target))

    def clear(self, frame: Frame) raises:
        """The ground, and nothing else -- an empty render pass whose only
        job is its load action. This is layer 0 when there is no layer 0."""
        if not frame.valid:
            return
        let pass_desc = ObjCObject(
            Cls["MTLRenderPassDescriptor"]().renderPassDescriptor().id
        )
        let c0 = send[ObjCObject, "objectAtIndexedSubscript:"](
            send[ObjCObject, "colorAttachments"](pass_desc), Int(0)
        )
        _ = send[ObjCObject, "setTexture:"](c0, ObjCObject(frame.target).ptr())
        _ = send[ObjCObject, "setLoadAction:"](c0, nsenum["MTLLoadActionClear"]())
        _ = send[ObjCObject, "setStoreAction:"](
            c0, nsenum["MTLStoreActionStore"]()
        )
        _ = send[ObjCObject, "setClearColor:"](
            c0, MTLClearColor(CLEAR_R, CLEAR_G, CLEAR_B, 1.0)
        )
        let enc = send[ObjCObject, "renderCommandEncoderWithDescriptor:"](
            ObjCObject(frame.cb), pass_desc.ptr()
        )
        _ = send[ObjCObject, "endEncoding"](enc)

    def present(mut self) raises:
        """Show a frame with nothing in it -- begin, clear, end. Kept as the
        one-liner for a pane with no layers yet, and as G1's own test."""
        with autoreleasepool():
            let frame = self.begin_frame()
            self.clear(frame)
            self.end_frame(frame)

    def aspect(self) -> Float32:
        """Width over height, which is what a shader wants for `u.aspect`."""
        if self.height == 0:
            return 1.0
        return Float32(self.width) / Float32(self.height)

    def read_frame(self, frame: Frame) raises -> List[UInt8]:
        """The pixels of a frame that has been ended, as raw BGRA.

        This is how a test asserts about what was DRAWN rather than about
        what was built: a pipeline that compiles and a pipeline that puts
        the right colour on the drawable are different claims. It waits for
        the frame's command buffer, so it costs a stall and belongs in
        tests and in GAMEPANE_DUMP, not in a game loop. An invalid frame --
        the compositor had no drawable -- gives an empty list rather than an
        error, because skipping a frame is normal.
        """
        if not frame.valid:
            return List[UInt8]()
        _ = send[ObjCObject, "waitUntilCompleted"](ObjCObject(frame.cb))
        var px = List[UInt8](length=self.width * self.height * 4, fill=0)
        _ = send[ObjCObject, "getBytes:bytesPerRow:fromRegion:mipmapLevel:"](
            ObjCObject(frame.target),
            px.unsafe_ptr().unsafe_bitcast[NoneType](),
            Int(self.width * 4),
            MTLRegion(MTLOrigin(0, 0, 0), MTLSize(self.width, self.height, 1)),
            Int(0),
        )
        return px^

    def _dump(self, target: ObjCObject) raises:
        """Write the presented frame as raw BGRA, so a harness (or a
        reviewer) can see the composite with no screen involved."""
        var px = List[UInt8](length=self.width * self.height * 4, fill=0)
        _ = send[ObjCObject, "getBytes:bytesPerRow:fromRegion:mipmapLevel:"](
            target,
            px.unsafe_ptr().unsafe_bitcast[NoneType](),
            Int(self.width * 4),
            MTLRegion(MTLOrigin(0, 0, 0), MTLSize(self.width, self.height, 1)),
            Int(0),
        )
        # write_bytes, not write: a frame is arbitrary bytes and putting them
        # through a String means claiming they are UTF-8, which they are not.
        with open(self.dump_path, "w") as f:
            f.write_bytes(Span(px))

    def close(mut self):
        """Order the window out. The pane owns the window, so it is the pane
        that takes it down -- and later, the audio unit with it."""
        with autoreleasepool():
            if self.window != 0:
                _ = Obj["NSWindow"](self.window).orderOut(ObjCObject(0))
        clear_input()


# Geometry helpers, so a caller need not import CGRect/CGSize just to open a
# window. They are re-exported from std.objc rather than redefined.
from std.objc import CGPoint, CGSize, CGRect


fn rect(x: Float64, y: Float64, w: Float64, h: Float64) -> CGRect:
    return CGRect(CGPoint(x, y), CGSize(w, h))


