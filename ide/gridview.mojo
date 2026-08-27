# GridView — the editor surface. A custom NSView that draws the rope.
#
# The whole speed argument lives here, and it is an argument about what the view
# refuses to do. A fixed-pitch font makes layout arithmetic:
#
#     x = column * advance          y = line * line_height
#     document height = line_count * line_height
#
# so there is no layout pass to run, ever, and no text storage to keep in sync.
# The view borrows the current rope root and draws the lines the scroll view is
# actually showing -- sixty of them, not two hundred and fifty thousand.
#
# A browser editor pays DOM mutation, style recalculation, layout, paint and
# composite on every keystroke, plus a JS heap and its collector. This pays a
# rope edit (measured: 2.4 us) and one line redrawn.
from rope import Rope
from std.objc import (
    ObjCClass,
    ObjCObject,
    msg_send,
    nsstring,
    autoreleasepool,
    ObjCClassBuilder,
    extern_object,
    new_instance,
    named_global,
)
from std.memory import OpaquePointer
from std.ffi import external_call

comptime P = OpaquePointer[MutUntrackedOrigin]


@fieldwise_init
struct CGPoint(Copyable, Movable):
    var x: Float64
    var y: Float64


@fieldwise_init
struct CGSize(Copyable, Movable):
    var width: Float64
    var height: Float64


@fieldwise_init
struct CGRect(Copyable, Movable):
    var origin: CGPoint
    var size: CGSize


def rect(x: Float64, y: Float64, w: Float64, h: Float64) -> CGRect:
    return CGRect(CGPoint(x, y), CGSize(w, h))


# ── State the draw callback can reach ────────────────────────────────────────
# drawRect: is a C-ABI fn with no closure, so the buffer it draws lives at a
# known address. The rope itself is heap-allocated once and replaced wholesale
# on edit -- which is cheap, because replacing it is a pointer swap.
# The buffer lives in a one-element global list rather than a raw heap slot.
# A zero-initialised global of any type is all zeros, and assigning a value
# with a destructor over zeros would run that destructor on garbage. A List is
# the exception worth using: zero-initialised it *is* a valid empty list, so
# the first buffer is appended and every later one replaces element zero --
# destroying a real Rope, which is correct.
comptime g_buffer = named_global["roast.buffer", List[Rope]]
comptime g_font = named_global["roast.font", Int]
comptime g_attrs = named_global["roast.attrs", Int]
comptime g_gutter_attrs = named_global["roast.gutter.attrs", Int]

# Metrics, measured once from the font and then treated as arithmetic.
comptime g_advance_x1000 = named_global["roast.advance", Int]
comptime g_line_h_x1000 = named_global["roast.lineh", Int]

comptime GUTTER_W = 62.0
comptime TEXT_PAD = 8.0


def advance() -> Float64:
    return Float64(g_advance_x1000()[]) / 1000.0


def line_height() -> Float64:
    return Float64(g_line_h_x1000()[]) / 1000.0


def set_rope(var r: Rope):
    """Install a new buffer. The old one is dropped, and any snapshot another
    queue is holding stays alive on its own -- which is the point of the rope."""
    let buf = g_buffer()
    if len(buf[]) == 0:
        buf[].append(r^)
    else:
        buf[][0] = r^


def has_rope() -> Bool:
    return len(g_buffer()[]) > 0


# ── Drawing ─────────────────────────────────────────────────────────────────
fn is_flipped(self_: P, cmd: P) -> Bool:
    # Origin at the top-left. Text goes down the page; the arithmetic should
    # not have to apologise for Cocoa's y-axis.
    return True


fn accepts_first_responder(self_: P, cmd: P) -> Bool:
    return True


fn draw_rect(self_: P, cmd: P):
    """Paint the visible lines.

    The dirty rect that AppKit passes is ignored in favour of `visibleRect`,
    which is what the design actually wants: draw the viewport, not the
    document. Declaring the IMP without the CGRect argument is ABI-safe on
    arm64 -- the caller passes it in registers the callee simply never reads.
    """
    try:
        with autoreleasepool():
            let view = ObjCObject(Int(self_))
            let vis = msg_send[CGRect, "NSView", "visibleRect"](view)

            # Background.
            let NSColor = ObjCClass.lookup["NSColor"]()
            let bg = msg_send[
                ObjCObject, "NSColor", "textBackgroundColor", is_class=True
            ](NSColor.as_object())
            _ = msg_send[ObjCObject, "NSColor", "setFill"](bg)
            _ = external_call["NSRectFill", NoneType](vis)

            let lh = line_height()
            if lh <= 0.0:
                return

            if not has_rope():
                return
            let buf = g_buffer()
            let total = buf[][0].line_count()

            # Exactly the lines the viewport covers, with one either side so a
            # partially scrolled line is not clipped away.
            var first = Int(vis.origin.y / lh) - 1
            if first < 0:
                first = 0
            var last = Int((vis.origin.y + vis.size.height) / lh) + 1
            if last > total:
                last = total

            let attrs = ObjCObject(g_attrs()[])
            let gutter_attrs = ObjCObject(g_gutter_attrs()[])

            var i = first
            while i < last:
                let y = Float64(i) * lh
                # Line number, right-aligned in the gutter.
                let num = String(i + 1)
                let num_w = Float64(num.byte_length()) * advance()
                _ = msg_send[
                    ObjCObject, "NSString", "drawAtPoint:withAttributes:"
                ](
                    nsstring(num),
                    CGPoint(GUTTER_W - num_w - TEXT_PAD, y),
                    gutter_attrs.ptr(),
                )
                # The line itself.
                let text = buf[][0].line(i)
                if text.byte_length() > 0:
                    _ = msg_send[
                        ObjCObject, "NSString", "drawAtPoint:withAttributes:"
                    ](
                        nsstring(text),
                        CGPoint(GUTTER_W + TEXT_PAD, y),
                        attrs.ptr(),
                    )
                i += 1
    except:
        pass


# ── Construction ────────────────────────────────────────────────────────────
def make_grid_view(frame: CGRect) -> ObjCObject:
    """Register the view class, measure the font, and return an instance."""
    # A monospaced face, and its advance measured once. Everything downstream
    # is multiplication.
    let NSFont = ObjCClass.lookup["NSFont"]()
    let font = msg_send[
        ObjCObject,
        "NSFont",
        "monospacedSystemFontOfSize:weight:",
        is_class=True,
    ](NSFont.as_object(), Float64(13.0), Float64(0.0))
    g_font()[] = font.addr()

    let NSMutableDictionary = ObjCClass.lookup["NSMutableDictionary"]()
    var attrs = msg_send[
        ObjCObject, "NSMutableDictionary", "dictionary", is_class=True
    ](NSMutableDictionary.as_object())
    _ = msg_send[ObjCObject, "NSMutableDictionary", "setObject:forKey:"](
        attrs, font.ptr(), extern_object["NSFontAttributeName"]().ptr()
    )
    let NSColor = ObjCClass.lookup["NSColor"]()
    let fg = msg_send[ObjCObject, "NSColor", "textColor", is_class=True](
        NSColor.as_object()
    )
    _ = msg_send[ObjCObject, "NSMutableDictionary", "setObject:forKey:"](
        attrs, fg.ptr(), extern_object["NSForegroundColorAttributeName"]().ptr()
    )
    _ = external_call["objc_retain", P](attrs.ptr())
    g_attrs()[] = attrs.addr()

    # The gutter, dimmer.
    var gattrs = msg_send[
        ObjCObject, "NSMutableDictionary", "dictionary", is_class=True
    ](NSMutableDictionary.as_object())
    _ = msg_send[ObjCObject, "NSMutableDictionary", "setObject:forKey:"](
        gattrs, font.ptr(), extern_object["NSFontAttributeName"]().ptr()
    )
    let dim = msg_send[
        ObjCObject, "NSColor", "tertiaryLabelColor", is_class=True
    ](NSColor.as_object())
    _ = msg_send[ObjCObject, "NSMutableDictionary", "setObject:forKey:"](
        gattrs, dim.ptr(), extern_object["NSForegroundColorAttributeName"]().ptr()
    )
    _ = external_call["objc_retain", P](gattrs.ptr())
    g_gutter_attrs()[] = gattrs.addr()

    # Advance: the width of one character in a face where they are all the
    # same width. Measured, not assumed.
    let probe = nsstring(String("0000000000"))
    let probe_size = msg_send[CGSize, "NSString", "sizeWithAttributes:"](
        probe, attrs.ptr()
    )
    g_advance_x1000()[] = Int(probe_size.width / 10.0 * 1000.0)

    # Line height from the font's own metrics, so descenders are not clipped.
    let ascender = msg_send[Float64, "NSFont", "ascender"](font)
    let descender = msg_send[Float64, "NSFont", "descender"](font)
    let leading = msg_send[Float64, "NSFont", "leading"](font)
    g_line_h_x1000()[] = Int((ascender - descender + leading + 2.0) * 1000.0)

    var b = ObjCClassBuilder["NSView"]("RoastGridView")
    b.add_method["drawRect:", encoding="v@:{CGRect={CGPoint=dd}{CGSize=dd}}"](
        draw_rect
    )
    b.add_method["isFlipped"](is_flipped)
    b.add_method["acceptsFirstResponder"](accepts_first_responder)
    let cls = b^.register()

    var view = msg_send[ObjCObject, "NSObject", "alloc", is_class=True](
        cls.as_object()
    )
    view = msg_send[ObjCObject, "NSView", "initWithFrame:"](view, frame)
    return view


def document_size(width: Float64) -> CGSize:
    """How tall the view must be for the scroll view to scroll it."""
    if not has_rope():
        return CGSize(width, 1.0)
    let h = Float64(g_buffer()[][0].line_count()) * line_height()
    return CGSize(max(width, GUTTER_W + 400.0), max(h, 1.0))
