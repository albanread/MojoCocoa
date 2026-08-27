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
    ns_to_string,
    new_instance,
    named_global,
)
from std.memory import OpaquePointer
from std.ffi import external_call, c_char

comptime P = OpaquePointer[MutUntrackedOrigin]


@fieldwise_init
struct CGPoint(ImplicitlyCopyable, Movable):
    var x: Float64
    var y: Float64


@fieldwise_init
struct CGSize(ImplicitlyCopyable, Movable):
    var width: Float64
    var height: Float64


@fieldwise_init
struct CGRect(ImplicitlyCopyable, Movable):
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
    add_text_input(b)
    # Responding to the selectors is not conformance, and AppKit asks.
    if not b.add_protocol["NSTextInputClient"]():
        print("roast: NSTextInputClient protocol not registered")
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


# ── Text input ───────────────────────────────────────────────────────────────
# NSTextInputClient, implemented in full rather than in part.
#
# This is the protocol that decides whether an editor is real. Typing ASCII
# works with almost any half of it; dead keys, option-e composition and every
# CJK input method go through marked text, and a client that answers
# `hasMarkedText` without maintaining a marked range corrupts the buffer in a
# way that only shows up for people using those input methods. So all eleven
# methods are here, and the class declares conformance rather than merely
# responding to the selectors -- AppKit asks `conformsToProtocol:`.
#
# Offsets are UTF-16 at this boundary, because that is what Cocoa counts in,
# and bytes inside the rope. The two conversions live in one place each.


@fieldwise_init
struct NSRange(ImplicitlyCopyable, Movable):
    """Cocoa's range: location and length, both counted in UTF-16 units."""

    var location: Int
    var length: Int


comptime NOT_FOUND = 0x7FFFFFFFFFFFFFFF

# Caret and selection, in byte offsets. anchor == caret means no selection.
comptime g_caret = named_global["roast.caret", Int]
comptime g_anchor = named_global["roast.anchor", Int]
# The composing region, in bytes; length 0 means nothing is being composed.
comptime g_marked_at = named_global["roast.marked.at", Int]
comptime g_marked_len = named_global["roast.marked.len", Int]


def sel_start() -> Int:
    return min(g_caret()[], g_anchor()[])


def sel_end() -> Int:
    return max(g_caret()[], g_anchor()[])


def set_caret(at: Int):
    g_caret()[] = at
    g_anchor()[] = at


def _utf16_len(s: String) -> Int:
    """UTF-16 units in a string. Cocoa counts these; the rope counts bytes."""
    var n = 0
    for c in s.codepoints():
        n += 2 if Int(c) > 0xFFFF else 1
    return n


def byte_to_utf16(offset: Int) -> Int:
    """A byte offset in the buffer as a UTF-16 offset, for Cocoa."""
    if not has_rope():
        return 0
    return _utf16_len(g_buffer()[][0].slice(0, offset))


def utf16_to_byte(u16: Int) -> Int:
    """The inverse. Walks the buffer once; the ranges Cocoa asks about are
    near the caret, so this is short in practice."""
    if not has_rope():
        return 0
    let text = g_buffer()[][0].to_string()
    var seen = 0
    var at = 0
    for c in text.codepoints():
        if seen >= u16:
            break
        seen += 2 if Int(c) > 0xFFFF else 1
        at += len(String(c).as_bytes())
    return at


def replace_selection(text: String):
    """The one place the buffer changes. Everything else routes through here so
    the caret, the marked range and the view are updated together."""
    if not has_rope():
        return
    let a = sel_start()
    let b = sel_end()
    set_rope(g_buffer()[][0].replace(a, b, text))
    set_caret(a + text.byte_length())
    g_marked_at()[] = 0
    g_marked_len()[] = 0


fn accepts_first_mouse(self_: P, cmd: P, event: P) -> Bool:
    return True


fn key_down(self_: P, cmd: P, event: P):
    """Every key goes to the input context, never straight to the buffer.

    Interpreting the event ourselves would work for ASCII and break every
    input method: it is `interpretKeyEvents:` that turns a keystroke into
    `insertText:`, a command selector, or marked text mid-composition.
    """
    try:
        with autoreleasepool():
            let view = ObjCObject(Int(self_))
            let NSArray = ObjCClass.lookup["NSArray"]()
            let one = msg_send[
                ObjCObject, "NSArray", "arrayWithObject:", is_class=True
            ](NSArray.as_object(), event)
            _ = msg_send[ObjCObject, "NSView", "interpretKeyEvents:"](
                view, one.ptr()
            )
    except:
        pass


fn insert_text(self_: P, cmd: P, text: P, replacement: NSRange):
    """Committed text: a character, a pasted run, or a finished composition."""
    try:
        with autoreleasepool():
            let obj = ObjCObject(Int(text))
            # Either an NSString or an NSAttributedString; ask for the string.
            var s = obj
            if msg_send[Bool, "NSObject", "isKindOfClass:"](
                obj, ObjCClass.lookup["NSAttributedString"]().as_object().ptr()
            ):
                s = msg_send[ObjCObject, "NSAttributedString", "string"](obj)
            # A composition being committed replaces what it was composing.
            if g_marked_len()[] > 0:
                g_anchor()[] = g_marked_at()[]
                g_caret()[] = g_marked_at()[] + g_marked_len()[]
            replace_selection(ns_to_string(s))
            _refresh(self_)
    except:
        pass


fn set_marked_text(
    self_: P, cmd: P, text: P, selected: NSRange, replacement: NSRange
):
    """Text mid-composition: shown, not committed. Replacing the previous
    marked run is what keeps a CJK candidate window from duplicating input."""
    try:
        with autoreleasepool():
            let obj = ObjCObject(Int(text))
            var s = obj
            if msg_send[Bool, "NSObject", "isKindOfClass:"](
                obj, ObjCClass.lookup["NSAttributedString"]().as_object().ptr()
            ):
                s = msg_send[ObjCObject, "NSAttributedString", "string"](obj)
            let str = ns_to_string(s)

            # Replace whatever was marked before, or the selection if nothing.
            let at = g_marked_at()[] if g_marked_len()[] > 0 else sel_start()
            let upto = (
                g_marked_at()[] + g_marked_len()[]
                if g_marked_len()[] > 0
                else sel_end()
            )
            if has_rope():
                set_rope(g_buffer()[][0].replace(at, upto, str))
            g_marked_at()[] = at
            g_marked_len()[] = str.byte_length()
            set_caret(at + str.byte_length())
            _refresh(self_)
    except:
        pass


fn unmark_text(self_: P, cmd: P):
    g_marked_at()[] = 0
    g_marked_len()[] = 0


fn has_marked_text(self_: P, cmd: P) -> Bool:
    return g_marked_len()[] > 0


fn marked_range(self_: P, cmd: P) -> NSRange:
    try:
        if g_marked_len()[] == 0:
            return NSRange(NOT_FOUND, 0)
        let a = byte_to_utf16(g_marked_at()[])
        let b = byte_to_utf16(g_marked_at()[] + g_marked_len()[])
        return NSRange(a, b - a)
    except:
        return NSRange(NOT_FOUND, 0)


fn selected_range(self_: P, cmd: P) -> NSRange:
    try:
        let a = byte_to_utf16(sel_start())
        let b = byte_to_utf16(sel_end())
        return NSRange(a, b - a)
    except:
        return NSRange(0, 0)


fn valid_attributes(self_: P, cmd: P) -> Int:
    """No marked-text styling is honoured, so the list is empty -- which is a
    legitimate answer, and an empty array rather than nil."""
    try:
        with autoreleasepool():
            let NSArray = ObjCClass.lookup["NSArray"]()
            return msg_send[ObjCObject, "NSArray", "array", is_class=True](
                NSArray.as_object()
            ).addr()
    except:
        return 0


fn attributed_substring(
    self_: P, cmd: P, range: NSRange, actual: P
) -> Int:
    """The text an input method wants to reconsider -- used by dictionary
    lookup and by some candidate windows."""
    try:
        with autoreleasepool():
            if not has_rope():
                return 0
            let a = utf16_to_byte(range.location)
            let b = utf16_to_byte(range.location + range.length)
            let s = g_buffer()[][0].slice(a, b)
            let NSAttributedString = ObjCClass.lookup["NSAttributedString"]()
            var att = msg_send[
                ObjCObject, "NSAttributedString", "alloc", is_class=True
            ](NSAttributedString.as_object())
            # Named for the concrete class, not the facade. NSAttributedString
            # is a class cluster: `[NSAttributedString alloc]` hands back an
            # NSConcreteAttributedString, and the database is a runtime dump,
            # so initWithString: is recorded on the concrete member and not on
            # the public name. The class parameter only chooses which metadata
            # to read -- dispatch happens on the receiver either way -- so this
            # names where the selector actually lives.
            att = msg_send[
                ObjCObject, "NSConcreteAttributedString", "initWithString:"
            ](att, nsstring(s).ptr())
            return att.addr()
    except:
        return 0


fn first_rect(self_: P, cmd: P, range: NSRange, actual: P) -> CGRect:
    """Where to put the candidate window: screen coordinates of the composing
    text. Getting this wrong parks the CJK candidate list in a corner."""
    try:
        with autoreleasepool():
            let view = ObjCObject(Int(self_))
            let at = utf16_to_byte(range.location)
            let line = g_buffer()[][0].line_of_offset(at) if has_rope() else 0
            let col = at - (
                g_buffer()[][0].line_start(line) if has_rope() else 0
            )
            let local = rect(
                GUTTER_W + TEXT_PAD + Float64(col) * advance(),
                Float64(line) * line_height(),
                advance(),
                line_height(),
            )
            # View -> window -> screen. `convertRect:toView:` with a nil view
            # means "to the window", which is the conversion wanted here.
            let in_window = msg_send[
                CGRect, "NSView", "convertRect:toView:"
            ](view, local, ObjCObject(0).ptr())
            let w = msg_send[ObjCObject, "NSView", "window"](view)
            if w.addr() == 0:
                return in_window
            return msg_send[CGRect, "NSWindow", "convertRectToScreen:"](
                w, in_window
            )
    except:
        return rect(0.0, 0.0, 0.0, 0.0)


fn character_index_for_point(self_: P, cmd: P, point: CGPoint) -> Int:
    """Hit testing, for click-to-place-caret from the input system."""
    try:
        if not has_rope():
            return 0
        let line = max(0, Int(point.y / line_height()))
        let col = max(0, Int((point.x - GUTTER_W - TEXT_PAD) / advance()))
        let start = g_buffer()[][0].line_start(line)
        return byte_to_utf16(start + col)
    except:
        return 0


fn do_command(self_: P, cmd: P, selector: P):
    """Movement and deletion arrive as selectors, not characters."""
    try:
        let raw = external_call["sel_getName", P](selector)
        if Int(raw) == 0:
            return
        let name = String(unsafe_from_utf8_ptr=raw.unsafe_bitcast[c_char]())
        apply_command(name)
        _refresh(self_)
    except:
        pass


def apply_command(name: String):
    """Movement and deletion, separated from the plumbing that delivers it.

    Everything here is buffer arithmetic, which is where the bugs live -- a
    backspace that eats half a UTF-8 sequence, an up-arrow that forgets which
    column it started in. ide/edit_test.mojo drives this directly, with no
    window and no event loop.
    """
    try:
        if not has_rope():
            return
        let buf = g_buffer()[][0]
        let n = buf.byte_length()

        if name == "insertNewline:":
            replace_selection(String("\n"))
        elif name == "insertTab:":
            replace_selection(String("    "))
        elif name == "deleteBackward:":
            if sel_start() != sel_end():
                replace_selection(String())
            elif g_caret()[] > 0:
                # One codepoint, not one byte: deleting half a character is
                # how a buffer stops being valid UTF-8.
                var back = g_caret()[] - 1
                let bytes = buf.to_string().as_bytes()
                while back > 0 and (Int(bytes[back]) & 0xC0) == 0x80:
                    back -= 1
                set_rope(buf.replace(back, g_caret()[], String()))
                set_caret(back)
        elif name == "deleteForward:":
            if sel_start() != sel_end():
                replace_selection(String())
            elif g_caret()[] < n:
                set_rope(buf.replace(g_caret()[], g_caret()[] + 1, String()))
        elif name == "moveLeft:":
            set_caret(max(0, g_caret()[] - 1))
        elif name == "moveRight:":
            set_caret(min(n, g_caret()[] + 1))
        elif name == "moveUp:" or name == "moveDown:":
            let line = buf.line_of_offset(g_caret()[])
            let col = g_caret()[] - buf.line_start(line)
            let target = line - 1 if name == "moveUp:" else line + 1
            if target >= 0 and target < buf.line_count():
                let ls = buf.line_start(target)
                let ll = buf.line(target).byte_length()
                set_caret(ls + min(col, ll))
        elif name == "moveToBeginningOfLine:":
            set_caret(buf.line_start(buf.line_of_offset(g_caret()[])))
        elif name == "moveToEndOfLine:":
            let line = buf.line_of_offset(g_caret()[])
            set_caret(buf.line_start(line) + buf.line(line).byte_length())
    except:
        pass


def _refresh(view_ptr: P):
    """Redraw, and keep the document tall enough for the buffer."""
    try:
        with autoreleasepool():
            let view = ObjCObject(Int(view_ptr))
            let frame = msg_send[CGRect, "NSView", "frame"](view)
            let want = document_size(frame.size.width)
            if want.height != frame.size.height:
                _ = msg_send[ObjCObject, "NSView", "setFrameSize:"](view, want)
            _ = msg_send[ObjCObject, "NSView", "setNeedsDisplay:"](view, True)
    except:
        pass


def add_text_input(mut b: ObjCClassBuilder["NSView"]):
    """Attach the input client to a view class under construction."""
    b.add_method["keyDown:", encoding="v@:@"](key_down)
    b.add_method["acceptsFirstMouse:", encoding="B@:@"](accepts_first_mouse)
    b.add_method["doCommandBySelector:", encoding="v@::"](do_command)
    b.add_method["unmarkText", encoding="v@:"](unmark_text)
    b.add_method["hasMarkedText", encoding="B@:"](has_marked_text)
    b.add_method_unchecked[
        "insertText:replacementRange:", encoding="v@:@{_NSRange=QQ}"
    ](insert_text)
    b.add_method_unchecked[
        "setMarkedText:selectedRange:replacementRange:",
        encoding="v@:@{_NSRange=QQ}{_NSRange=QQ}",
    ](set_marked_text)
    b.add_method_unchecked["markedRange", encoding="{_NSRange=QQ}@:"](
        marked_range
    )
    b.add_method_unchecked["selectedRange", encoding="{_NSRange=QQ}@:"](
        selected_range
    )
    b.add_method_unchecked["validAttributesForMarkedText", encoding="@@:"](
        valid_attributes
    )
    b.add_method_unchecked[
        "attributedSubstringForProposedRange:actualRange:",
        encoding="@@:{_NSRange=QQ}^{_NSRange=QQ}",
    ](attributed_substring)
    b.add_method_unchecked[
        "firstRectForCharacterRange:actualRange:",
        encoding="{CGRect={CGPoint=dd}{CGSize=dd}}@:{_NSRange=QQ}^{_NSRange=QQ}",
    ](first_rect)
    b.add_method_unchecked[
        "characterIndexForPoint:", encoding="Q@:{CGPoint=dd}"
    ](character_index_for_point)
