# ===----------------------------------------------------------------------=== #
# Trench — the drawing toolkit.
#
# Everything the console draws by hand goes through here, and every colour
# in it is a SEMANTIC system colour rather than a value: `labelColor`,
# `separatorColor`, `controlBackgroundColor`, `systemRed`. That is one
# decision doing a lot of work -- the window is correct in light mode, in
# dark mode, under Increase Contrast and under a changed accent colour,
# without a second palette or a single `if dark`. The gamepane console
# opposite this one owns its 256 entries and cannot do any of that; it is
# also the reason it looks like 1969, which is the point of it.
#
# The one place a literal colour is allowed is the plot's own data: the
# course, the corridor bands, the Δv ramp. Those are not interface, they
# are the picture, and a chart that changed hue with the system accent
# would be a chart nobody could describe to anyone else.
# ===----------------------------------------------------------------------=== #

from std.objc import (
    Obj,
    Cls,
    ObjCObject,
    nsstring,
    extern_object,
    autoreleasepool,
    CGPoint,
    CGSize,
    CGRect,
)
from std.ffi import external_call
from std.math import floor, sqrt


# ── geometry ─────────────────────────────────────────────────────────────


fn rect(x: Float64, y: Float64, w: Float64, h: Float64) -> CGRect:
    return CGRect(CGPoint(x, y), CGSize(w, h))


fn pt(x: Float64, y: Float64) -> CGPoint:
    return CGPoint(x, y)


fn inset(r: CGRect, dx: Float64, dy: Float64) -> CGRect:
    return rect(
        r.origin.x + dx, r.origin.y + dy, r.size.width - 2.0 * dx, r.size.height - 2.0 * dy
    )


# ── colour ───────────────────────────────────────────────────────────────
#
# Named for the role, not the hue. `separator()` is a hairline in both
# appearances and neither of them is a grey anybody typed.


fn label() -> ObjCObject:
    return Cls["NSColor"]().labelColor()


fn secondary() -> ObjCObject:
    return Cls["NSColor"]().secondaryLabelColor()


fn tertiary() -> ObjCObject:
    return Cls["NSColor"]().tertiaryLabelColor()


fn quaternary() -> ObjCObject:
    return Cls["NSColor"]().quaternaryLabelColor()


fn separator() -> ObjCObject:
    return Cls["NSColor"]().separatorColor()


fn control_bg() -> ObjCObject:
    return Cls["NSColor"]().controlBackgroundColor()


fn window_bg() -> ObjCObject:
    return Cls["NSColor"]().windowBackgroundColor()


fn under_page() -> ObjCObject:
    return Cls["NSColor"]().underPageBackgroundColor()


fn accent() -> ObjCObject:
    return Cls["NSColor"]().controlAccentColor()


fn red() -> ObjCObject:
    return Cls["NSColor"]().systemRedColor()


fn orange() -> ObjCObject:
    return Cls["NSColor"]().systemOrangeColor()


fn green() -> ObjCObject:
    return Cls["NSColor"]().systemGreenColor()


fn blue() -> ObjCObject:
    return Cls["NSColor"]().systemBlueColor()


fn teal() -> ObjCObject:
    return Cls["NSColor"]().systemTealColor()


fn purple() -> ObjCObject:
    return Cls["NSColor"]().systemPurpleColor()


fn yellow() -> ObjCObject:
    return Cls["NSColor"]().systemYellowColor()


fn rgba(r: Float64, g: Float64, b: Float64, a: Float64) -> ObjCObject:
    """A literal colour, for the picture rather than the interface."""
    return Cls["NSColor"]().colorWithSRGBRed_green_blue_alpha(r, g, b, a)


fn mix(c: ObjCObject, over: ObjCObject, f: Float64) -> ObjCObject:
    """`f` of the way from c to over, in sRGB."""
    let a = Obj["NSColor"](c.addr()).colorUsingColorSpace(
        Cls["NSColorSpace"]().sRGBColorSpace().ptr()
    )
    let b = Obj["NSColor"](over.addr()).colorUsingColorSpace(
        Cls["NSColorSpace"]().sRGBColorSpace().ptr()
    )
    if a.addr() == 0 or b.addr() == 0:
        return c
    let ar = Obj["NSColor"](a.addr()).redComponent()
    let ag = Obj["NSColor"](a.addr()).greenComponent()
    let ab = Obj["NSColor"](a.addr()).blueComponent()
    let br = Obj["NSColor"](b.addr()).redComponent()
    let bg = Obj["NSColor"](b.addr()).greenComponent()
    let bb = Obj["NSColor"](b.addr()).blueComponent()
    return rgba(
        ar + (br - ar) * f, ag + (bg - ag) * f, ab + (bb - ab) * f, 1.0
    )


# ── fills and strokes ────────────────────────────────────────────────────


fn fill_rect(r: CGRect, colour: ObjCObject):
    Obj["NSColor"](colour.addr()).setFill()
    _ = external_call["NSRectFill", NoneType](r)


fn fill_round(r: CGRect, radius: Float64, colour: ObjCObject):
    Obj["NSColor"](colour.addr()).setFill()
    let p = Cls["NSBezierPath"]().bezierPathWithRoundedRect_xRadius_yRadius(
        r, radius, radius
    )
    Obj["NSBezierPath"](p.addr()).fill()


fn stroke_round(r: CGRect, radius: Float64, width: Float64, colour: ObjCObject):
    Obj["NSColor"](colour.addr()).setStroke()
    let p = Cls["NSBezierPath"]().bezierPathWithRoundedRect_xRadius_yRadius(
        r, radius, radius
    )
    Obj["NSBezierPath"](p.addr()).setLineWidth(width)
    Obj["NSBezierPath"](p.addr()).stroke()


fn fill_oval(r: CGRect, colour: ObjCObject):
    Obj["NSColor"](colour.addr()).setFill()
    let p = Cls["NSBezierPath"]().bezierPathWithOvalInRect(r)
    Obj["NSBezierPath"](p.addr()).fill()


fn stroke_oval(r: CGRect, width: Float64, colour: ObjCObject):
    Obj["NSColor"](colour.addr()).setStroke()
    let p = Cls["NSBezierPath"]().bezierPathWithOvalInRect(r)
    Obj["NSBezierPath"](p.addr()).setLineWidth(width)
    Obj["NSBezierPath"](p.addr()).stroke()


fn dot(x: Float64, y: Float64, r: Float64, colour: ObjCObject):
    fill_oval(rect(x - r, y - r, 2.0 * r, 2.0 * r), colour)


fn line(x0: Float64, y0: Float64, x1: Float64, y1: Float64, width: Float64, colour: ObjCObject):
    Obj["NSColor"](colour.addr()).setStroke()
    var p = Cls["NSBezierPath"]().bezierPath()
    Obj["NSBezierPath"](p.addr()).setLineWidth(width)
    Obj["NSBezierPath"](p.addr()).moveToPoint(pt(x0, y0))
    Obj["NSBezierPath"](p.addr()).lineToPoint(pt(x1, y1))
    Obj["NSBezierPath"](p.addr()).stroke()


fn hairline(x: Float64, y: Float64, w: Float64, h: Float64):
    """A one-pixel rule in the system's separator colour."""
    fill_rect(rect(x, y, w, h), separator())


# ── a polyline, built up and stroked once ────────────────────────────────


struct Path(Movable):
    """An NSBezierPath with the moveTo/lineTo bookkeeping done: `add` is
    the only call, and the first one starts the path. Stroking a course of
    three thousand samples as one path rather than three thousand separate
    lines is the difference between a plot that draws in a millisecond and
    one that does not."""

    var p: ObjCObject
    var started: Bool

    fn __init__(out self):
        self.p = Cls["NSBezierPath"]().bezierPath()
        self.started = False

    fn add(mut self, x: Float64, y: Float64):
        if self.started:
            Obj["NSBezierPath"](self.p.addr()).lineToPoint(pt(x, y))
        else:
            Obj["NSBezierPath"](self.p.addr()).moveToPoint(pt(x, y))
            self.started = True

    fn lift(mut self):
        """End the current run; the next `add` starts a new one."""
        self.started = False

    fn stroke(self, width: Float64, colour: ObjCObject):
        if not self.started:
            return
        Obj["NSColor"](colour.addr()).setStroke()
        Obj["NSBezierPath"](self.p.addr()).setLineWidth(width)
        Obj["NSBezierPath"](self.p.addr()).setLineJoinStyle(Int(1))
        Obj["NSBezierPath"](self.p.addr()).setLineCapStyle(Int(1))
        Obj["NSBezierPath"](self.p.addr()).stroke()

    fn stroke_dashed(self, width: Float64, colour: ObjCObject):
        Obj["NSColor"](colour.addr()).setStroke()
        Obj["NSBezierPath"](self.p.addr()).setLineWidth(width)
        var pattern = InlineArray[Float64, 2](3.0, 4.0)
        Obj["NSBezierPath"](self.p.addr()).setLineDash_count_phase(
            pattern.unsafe_ptr(), Int(2), Float64(0.0)
        )
        Obj["NSBezierPath"](self.p.addr()).stroke()


# ── type ─────────────────────────────────────────────────────────────────
#
# Three faces and four weights, which is the whole typographic system: the
# interface face for labels, the monospaced-DIGIT face for numbers that sit
# in columns (so 1 and 7 are the same width and a changing readout does not
# shuffle sideways), and the fully monospaced face for the log.

comptime W_REGULAR = 0.0
comptime W_MEDIUM = 0.23
comptime W_SEMIBOLD = 0.3
comptime W_BOLD = 0.4

comptime ALIGN_LEFT = 0
comptime ALIGN_RIGHT = 1
comptime ALIGN_CENTRE = 2


fn _attrs(font: ObjCObject, colour: ObjCObject) -> ObjCObject:
    var a = Cls["NSMutableDictionary"]().dictionary()
    Obj["NSMutableDictionary"](a.addr()).setObject_forKey(
        font.ptr(), extern_object["NSFontAttributeName"]().ptr()
    )
    Obj["NSMutableDictionary"](a.addr()).setObject_forKey(
        colour.ptr(), extern_object["NSForegroundColorAttributeName"]().ptr()
    )
    return a


fn _measure(s: String, size: Float64) -> Float64:
    """An estimate, deliberately. `-[NSString sizeWithAttributes:]` returns a
    struct by value through a path this bridge gets wrong, and it took AppKit
    down from inside a draw. Nothing here needs the typesetter's answer:
    these are captions to centre and numbers to right-align in a plot, and
    the system face averages about 0.52 em at interface sizes. The inspector's
    columns do not come through here at all -- NSTextFieldCell aligns those,
    and it measures properly."""
    return Float64(s.byte_length()) * size * 0.52


fn text(s: String, x: Float64, y: Float64, size: Float64, colour: ObjCObject):
    """Interface type, drawn from its bottom-left."""
    with autoreleasepool():
        let font = Cls["NSFont"]().systemFontOfSize_weight(size, W_REGULAR)
        Obj["NSString"](nsstring(s).addr()).drawAtPoint_withAttributes(
            pt(x, y), _attrs(font, colour).ptr()
        )


fn text_weight(
    s: String, x: Float64, y: Float64, size: Float64, weight: Float64, colour: ObjCObject
):
    with autoreleasepool():
        let font = Cls["NSFont"]().systemFontOfSize_weight(size, weight)
        Obj["NSString"](nsstring(s).addr()).drawAtPoint_withAttributes(
            pt(x, y), _attrs(font, colour).ptr()
        )


fn digits(s: String, x: Float64, y: Float64, size: Float64, colour: ObjCObject):
    """Monospaced-digit interface type: a readout that does not shuffle."""
    with autoreleasepool():
        let font = Cls["NSFont"]().monospacedDigitSystemFontOfSize_weight(
            size, W_REGULAR
        )
        Obj["NSString"](nsstring(s).addr()).drawAtPoint_withAttributes(
            pt(x, y), _attrs(font, colour).ptr()
        )


fn digits_right(
    s: String, x: Float64, y: Float64, w: Float64, size: Float64, colour: ObjCObject
):
    """The same, right-aligned in a box of width w -- how a number column
    is set, so the units line up and the eye can scan down them."""
    with autoreleasepool():
        let font = Cls["NSFont"]().monospacedDigitSystemFontOfSize_weight(
            size, W_REGULAR
        )
        let tw = _measure(s, size)
        Obj["NSString"](nsstring(s).addr()).drawAtPoint_withAttributes(
            pt(x + w - tw, y), _attrs(font, colour).ptr()
        )


fn text_centre(
    s: String, x: Float64, y: Float64, w: Float64, size: Float64, colour: ObjCObject
):
    with autoreleasepool():
        let font = Cls["NSFont"]().systemFontOfSize_weight(size, W_REGULAR)
        let tw = _measure(s, size)
        Obj["NSString"](nsstring(s).addr()).drawAtPoint_withAttributes(
            pt(x + (w - tw) * 0.5, y), _attrs(font, colour).ptr()
        )


fn mono(s: String, x: Float64, y: Float64, size: Float64, colour: ObjCObject):
    with autoreleasepool():
        let font = Cls["NSFont"]().monospacedSystemFontOfSize_weight(
            size, W_REGULAR
        )
        Obj["NSString"](nsstring(s).addr()).drawAtPoint_withAttributes(
            pt(x, y), _attrs(font, colour).ptr()
        )


fn text_width(s: String, size: Float64) -> Float64:
    with autoreleasepool():
        let font = Cls["NSFont"]().systemFontOfSize_weight(size, W_REGULAR)
        return _measure(s, size)


# ── the section header, as the sidebar and the inspector both draw it ────


fn section(title: String, x: Float64, y: Float64):
    """An uppercase secondary caption -- the Mac's group header since the
    Finder's sidebar, and what tells the eye that what follows is a set."""
    text_weight(title.upper(), x, y, 10.0, W_SEMIBOLD, tertiary())


# ── formatting ───────────────────────────────────────────────────────────


fn f(x: Float64, places: Int) -> String:
    """Fixed-point, without the exponent notation `String(Float64)` reaches
    for -- a plan sheet that prints 3.1812e3 has stopped being a plan sheet."""
    if x != x:
        return String("--")
    var neg = x < 0.0
    var v = -x if neg else x
    var scale = 1.0
    for _ in range(places):
        scale *= 10.0
    var n = Int(floor(v * scale + 0.5))
    var whole = n // Int(scale)
    var frac = n - whole * Int(scale)
    var s = String(whole)
    if places > 0:
        var fs = String(frac)
        while fs.byte_length() < places:
            fs = String("0") + fs
        s += "." + fs
    return ("-" + s) if neg else s


fn ms(dv_kms: Float64) -> String:
    """A Δv in km/s, shown in the metres a second the trench speaks."""
    return f(dv_kms * 1000.0, 0) + " m/s"


fn get_hms(seconds: Float64) -> String:
    """Ground Elapsed Time, hhh:mm:ss -- the only clock a flight plan uses."""
    var t = seconds
    var neg = t < 0.0
    if neg:
        t = -t
    let h = Int(t / 3600.0)
    let m = Int((t - Float64(h) * 3600.0) / 60.0)
    let s = Int(t - Float64(h) * 3600.0 - Float64(m) * 60.0)
    var mm = String(m)
    if m < 10:
        mm = "0" + mm
    var ss = String(s)
    if s < 10:
        ss = "0" + ss
    var hh = String(h)
    while hh.byte_length() < 3:
        hh = "0" + hh
    return ("-" if neg else "") + hh + ":" + mm + ":" + ss
