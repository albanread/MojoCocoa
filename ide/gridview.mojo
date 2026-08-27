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
from lsp import (
    completion_count,
    clear_completions,
    g_comp_label,
    g_comp_detail,
    g_comp_insert,
    diagnostic_count,
    g_diag_line,
    g_diag_col,
    g_diag_end,
    g_diag_sev,
    g_diag_msg,
)
from std.objc import (
    ObjCClass,
    ObjCObject,
    msg_send,
    nsstring,
    autoreleasepool,
    extern_object,
    ns_to_string,
    named_global,
    sel,
    CGPoint,
    CGSize,
    CGRect,
    NSRange,
)
from std.memory import OpaquePointer
from std.ffi import external_call, c_char

comptime P = OpaquePointer[MutUntrackedOrigin]


# The geometry comes from std.objc now, declared TrivialRegisterPassable there
# because that is what the C ABI says these are -- and what lets a `class`
# method return one (COCOA_CLASS_DESIGN.md, struct returns).
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
    g_revision()[] += 1


def has_rope() -> Bool:
    return len(g_buffer()[]) > 0


# ── Drawing ─────────────────────────────────────────────────────────────────
# ── Completion popup ────────────────────────────────────────────────────────
def ensure_popup():
    """Build the popup window once."""
    if g_popup()[] != 0:
        return
    let NSWindow = ObjCClass.lookup["NSWindow"]()
    var win = msg_send[ObjCObject, "NSWindow", "alloc", is_class=True](
        NSWindow.as_object()
    )
    # Borderless, non-activating: showing candidates must not take focus away
    # from the text being typed.
    win = msg_send[
        ObjCObject, "NSWindow", "initWithContentRect:styleMask:backing:defer:"
    ](win, rect(0.0, 0.0, POPUP_W, POPUP_ROW_H), Int(0), Int(2), Bool(False))
    _ = msg_send[ObjCObject, "NSWindow", "setLevel:"](win, Int(101))
    _ = msg_send[ObjCObject, "NSWindow", "setOpaque:"](win, False)
    _ = msg_send[ObjCObject, "NSWindow", "setHasShadow:"](win, True)

    var view = ObjCObject(RoastCompletionView().__objc_id)
    _ = msg_send[ObjCObject, "NSView", "setFrame:"](
        view, rect(0.0, 0.0, POPUP_W, POPUP_ROW_H)
    )
    _ = msg_send[ObjCObject, "NSWindow", "setContentView:"](win, view.ptr())
    _ = external_call["objc_retain", P](win.ptr())
    g_popup()[] = win.addr()
    g_popup_view()[] = view.addr()


def word_start(at: Int) -> Int:
    """Where the identifier under the caret begins.

    A completion replaces the word being typed, not the empty space after it;
    getting this wrong appends to a prefix and produces `setTitsetTitle:`.
    """
    if not has_rope():
        return at
    let text = g_buffer()[][0].slice(max(0, at - 128), at)
    let bytes = text.as_bytes()
    var back = 0
    while back < len(bytes):
        let c = Int(bytes[len(bytes) - 1 - back])
        let alnum = (
            (c >= 0x30 and c <= 0x39)
            or (c >= 0x41 and c <= 0x5A)
            or (c >= 0x61 and c <= 0x7A)
            or c == 0x5F
        )
        if not alnum:
            break
        back += 1
    return at - back


def show_popup(anchor_view: ObjCObject):
    """Put the list under the word being completed."""
    if completion_count() == 0:
        hide_popup()
        return
    ensure_popup()
    with autoreleasepool():
        let rows = min(completion_count(), POPUP_MAX_ROWS)
        let h = Float64(rows) * POPUP_ROW_H
        g_popup_from()[] = word_start(g_caret()[])
        let pos = caret_position(g_popup_from()[])

        # The caret is in view coordinates; the window wants screen ones.
        let local = rect(pos.x, pos.y + line_height(), POPUP_W, h)
        let in_window = msg_send[CGRect, "NSView", "convertRect:toView:"](
            anchor_view, local, ObjCObject(0).ptr()
        )
        let host = msg_send[ObjCObject, "NSView", "window"](anchor_view)
        if host.addr() == 0:
            return
        var screen = msg_send[CGRect, "NSWindow", "convertRectToScreen:"](
            host, in_window
        )
        # The window's y is its bottom edge, and the list hangs below the
        # caret, so the origin moves down by the height.
        screen.origin.y -= h

        let win = ObjCObject(g_popup()[])
        _ = msg_send[ObjCObject, "NSWindow", "setFrame:display:"](
            win, screen, True
        )
        _ = msg_send[ObjCObject, "NSView", "setFrameSize:"](
            ObjCObject(g_popup_view()[]), CGSize(POPUP_W, h)
        )
        _ = msg_send[ObjCObject, "NSView", "setNeedsDisplay:"](
            ObjCObject(g_popup_view()[]), True
        )
        # orderFront, never makeKey: the text keeps the keyboard.
        _ = msg_send[ObjCObject, "NSWindow", "orderFront:"](win, win.ptr())
        g_popup_open()[] = 1
        g_popup_sel()[] = 0


def hide_popup():
    if g_popup()[] == 0 or g_popup_open()[] == 0:
        return
    with autoreleasepool():
        _ = msg_send[ObjCObject, "NSWindow", "orderOut:"](
            ObjCObject(g_popup()[]), ObjCObject(g_popup()[]).ptr()
        )
    g_popup_open()[] = 0
    clear_completions()


def popup_open() -> Bool:
    return g_popup_open()[] != 0


def popup_move(delta: Int):
    let n = min(completion_count(), POPUP_MAX_ROWS)
    if n == 0:
        return
    var sel = g_popup_sel()[] + delta
    if sel < 0:
        sel = n - 1
    elif sel >= n:
        sel = 0
    g_popup_sel()[] = sel
    with autoreleasepool():
        _ = msg_send[ObjCObject, "NSView", "setNeedsDisplay:"](
            ObjCObject(g_popup_view()[]), True
        )


def popup_accept() -> Bool:
    """Insert the selected candidate over the word being completed."""
    if not popup_open() or completion_count() == 0:
        return False
    let sel = min(g_popup_sel()[], completion_count() - 1)
    let text = g_comp_insert()[][sel]
    let from_ = g_popup_from()[]
    hide_popup()
    if not has_rope():
        return False
    push_undo()
    set_rope(g_buffer()[][0].replace(from_, g_caret()[], text))
    set_caret(from_ + text.byte_length())
    return True


# ── Construction ────────────────────────────────────────────────────────────
class RoastGridView(NSView, NSTextInputClient):
    """The editor surface, and the whole NSTextInputClient.

    Twenty-one selectors that were an ObjCClassBuilder, eight encoding
    strings, and seven `add_method_unchecked` escapes -- the escapes existed
    because the checked overloads could not describe NSRange and CGRect
    crossing by value. The compiler takes every encoding from the SDK now,
    and the struct shapes cross the trampoline in registers both ways
    (struct_arg_test, struct_ret_test).

    Conformance is declared in the base list: implementing the selectors is
    not conforming, and AppKit asks `conformsToProtocol:` before it will
    speak NSTextInputClient to a view.
    """

    def isFlipped(self) -> Bool:
        # Origin at the top-left. Text goes down the page; the arithmetic should
        # not have to apologise for Cocoa's y-axis.
        return True

    def acceptsFirstResponder(self) -> Bool:
        return True

    def drawRect_(self, dirty: CGRect):
        """Paint the visible lines.

        The dirty rect that AppKit passes is ignored in favour of `visibleRect`,
        which is what the design actually wants: draw the viewport, not the
        document. Declaring the IMP without the CGRect argument is ABI-safe on
        arm64 -- the caller passes it in registers the callee simply never reads.
        """
        try:
            with autoreleasepool():
                let view = ObjCObject(self.__objc_id)
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

                # Every match on screen, faintly. Only the visible byte range is
                # searched, because only the visible range can be seen -- the whole
                # buffer would be scanned on every frame for nothing.
                let q = query()
                if q.byte_length() > 0:
                    let vis_a = buf[][0].line_start(first)
                    let vis_b = buf[][0].line_start(min(last, total - 1)) + buf[][
                        0
                    ].line(min(last, total - 1)).byte_length()
                    let NSColorM = ObjCClass.lookup["NSColor"]()
                    let found_bg = msg_send[
                        ObjCObject, "NSColor", "systemYellowColor", is_class=True
                    ](NSColorM.as_object())
                    let faded = msg_send[
                        ObjCObject, "NSColor", "colorWithAlphaComponent:"
                    ](found_bg, Float64(0.35))
                    _ = msg_send[ObjCObject, "NSColor", "setFill"](faded)
                    for m in buf[][0].find_all_in(q, vis_a, vis_b):
                        let a = caret_position(m)
                        let b = caret_position(m + q.byte_length())
                        if b.y == a.y:
                            _ = external_call["NSRectFill", NoneType](
                                rect(a.x, a.y, max(b.x - a.x, 2.0), lh)
                            )

                # Selection, painted under the text.
                let sel_a = sel_start()
                let sel_b = sel_end()
                if sel_a != sel_b:
                    let NSColor2 = ObjCClass.lookup["NSColor"]()
                    let hl = msg_send[
                        ObjCObject, "NSColor", "selectedTextBackgroundColor",
                        is_class=True,
                    ](NSColor2.as_object())
                    _ = msg_send[ObjCObject, "NSColor", "setFill"](hl)
                    let l0 = buf[][0].line_of_offset(sel_a)
                    let l1 = buf[][0].line_of_offset(sel_b)
                    var ln = max(l0, first)
                    while ln <= min(l1, last - 1):
                        let ls = buf[][0].line_start(ln)
                        let le = ls + buf[][0].line(ln).byte_length()
                        let from_ = max(sel_a, ls)
                        let to_ = min(sel_b, le)
                        let x0 = caret_position(from_).x
                        var x1 = caret_position(to_).x
                        # A selected newline shows as a sliver, the way a text view
                        # signals that the line break itself is included.
                        if sel_b > le and ln < l1:
                            x1 += advance() * 0.5
                        _ = external_call["NSRectFill", NoneType](
                            rect(x0, Float64(ln) * lh, max(x1 - x0, 1.0), lh)
                        )
                        ln += 1

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
                    # The line, in runs of one colour each. Monospaced means a
                    # run's x is just its column times the advance, so drawing in
                    # pieces costs a few more calls and no layout at all.
                    let text = buf[][0].line(i)
                    if text.byte_length() > 0:
                        let kinds = highlight(text)
                        var col = 0
                        var run = String()
                        var run_kind = KIND_PLAIN
                        var run_col = 0
                        for c in text.codepoints():
                            let k = kinds[col] if col < len(kinds) else KIND_PLAIN
                            if k != run_kind and run.byte_length() > 0:
                                _ = msg_send[
                                    ObjCObject,
                                    "NSString",
                                    "drawAtPoint:withAttributes:",
                                ](
                                    nsstring(run),
                                    CGPoint(
                                        GUTTER_W
                                        + TEXT_PAD
                                        + Float64(run_col) * advance(),
                                        y,
                                    ),
                                    _attrs_for(run_kind).ptr(),
                                )
                                run = String()
                                run_col = col
                            if run.byte_length() == 0:
                                run_col = col
                            run_kind = k
                            run += String(c)
                            col += 1
                        if run.byte_length() > 0:
                            _ = msg_send[
                                ObjCObject, "NSString", "drawAtPoint:withAttributes:"
                            ](
                                nsstring(run),
                                CGPoint(
                                    GUTTER_W + TEXT_PAD + Float64(run_col) * advance(),
                                    y,
                                ),
                                _attrs_for(run_kind).ptr(),
                            )
                    i += 1

                # Diagnostics from the language server. Drawn after the text so
                # the underline sits under the glyphs it is about, and before the
                # caret so the caret stays on top of everything.
                let dn = diagnostic_count()
                if dn > 0:
                    let NSColorD = ObjCClass.lookup["NSColor"]()
                    var di = 0
                    while di < dn:
                        let dline = g_diag_line()[][di]
                        if dline < first or dline >= last:
                            di += 1
                            continue
                        # 1 error, 2 warning, anything else advisory.
                        let sev = g_diag_sev()[][di]
                        var ink = msg_send[
                            ObjCObject, "NSColor", "systemRedColor", is_class=True
                        ](NSColorD.as_object())
                        if sev == 2:
                            ink = msg_send[
                                ObjCObject, "NSColor", "systemOrangeColor",
                                is_class=True,
                            ](NSColorD.as_object())
                        elif sev > 2:
                            ink = msg_send[
                                ObjCObject, "NSColor", "systemBlueColor",
                                is_class=True,
                            ](NSColorD.as_object())
                        _ = msg_send[ObjCObject, "NSColor", "setFill"](ink)

                        let y = Float64(dline) * lh
                        # The gutter mark: a bar at the left edge, which reads at a
                        # glance and does not need the line to be on screen wide.
                        _ = external_call["NSRectFill", NoneType](
                            rect(2.0, y + 3.0, 4.0, lh - 6.0)
                        )

                        # The underline, under the range the server gave.
                        let lstart = buf[][0].line_start(dline)
                        let a = caret_position(lstart + g_diag_col()[][di])
                        var end_col = g_diag_end()[][di]
                        if end_col <= g_diag_col()[][di]:
                            end_col = g_diag_col()[][di] + 1
                        let b = caret_position(lstart + end_col)
                        _ = external_call["NSRectFill", NoneType](
                            rect(a.x, y + lh - 2.0, max(b.x - a.x, advance()), 2.0)
                        )
                        di += 1

                # The caret: drawn only with focus, and only on the blink's on
                # phase, because a caret that never blinks reads as a rendering
                # artefact rather than a cursor.
                if g_focused()[] != 0 and g_blink_on()[] != 0 and sel_a == sel_b:
                    let NSColor3 = ObjCClass.lookup["NSColor"]()
                    let ink = msg_send[
                        ObjCObject, "NSColor", "textColor", is_class=True
                    ](NSColor3.as_object())
                    _ = msg_send[ObjCObject, "NSColor", "setFill"](ink)
                    let pos = caret_position(g_caret()[])
                    _ = external_call["NSRectFill", NoneType](
                        rect(pos.x, pos.y, 2.0, lh)
                    )

                # Composing text is underlined, which is how a person knows it is
                # not committed yet.
                if g_marked_len()[] > 0:
                    let a = caret_position(g_marked_at()[])
                    let b = caret_position(g_marked_at()[] + g_marked_len()[])
                    let NSColor4 = ObjCClass.lookup["NSColor"]()
                    let mark = msg_send[
                        ObjCObject, "NSColor", "textColor", is_class=True
                    ](NSColor4.as_object())
                    _ = msg_send[ObjCObject, "NSColor", "setFill"](mark)
                    _ = external_call["NSRectFill", NoneType](
                        rect(a.x, a.y + lh - 2.0, max(b.x - a.x, advance()), 1.0)
                    )
        except:
            pass

    def mouseDown_(self, event: ObjCObject):
        """Click to place the caret; drag to select."""
        try:
            with autoreleasepool():
                let view = ObjCObject(self.__objc_id)
                let win_pt = msg_send[CGPoint, "NSEvent", "locationInWindow"](
                    event
                )
                let local = msg_send[CGPoint, "NSView", "convertPoint:fromView:"](
                    view, win_pt, ObjCObject(0).ptr()
                )
                let at = offset_at_point(local.x, local.y)
                set_caret(at)
                g_coalesce_at()[] = -1
                _ = msg_send[ObjCObject, "NSWindow", "makeFirstResponder:"](
                    msg_send[ObjCObject, "NSView", "window"](view), view.ptr()
                )
                _refresh(P(unsafe_from_address=self.__objc_id))
        except:
            pass

    def mouseDragged_(self, event: ObjCObject):
        try:
            with autoreleasepool():
                let view = ObjCObject(self.__objc_id)
                let win_pt = msg_send[CGPoint, "NSEvent", "locationInWindow"](
                    event
                )
                let local = msg_send[CGPoint, "NSView", "convertPoint:fromView:"](
                    view, win_pt, ObjCObject(0).ptr()
                )
                # Move the caret, leave the anchor: that is a selection.
                g_caret()[] = offset_at_point(local.x, local.y)
                _refresh(P(unsafe_from_address=self.__objc_id))
        except:
            pass

    def becomeFirstResponder(self) -> Bool:
        g_focused()[] = 1
        g_blink_on()[] = 1
        return True

    def resignFirstResponder(self) -> Bool:
        g_focused()[] = 0
        return True

    def roastBlink_(self, timer: ObjCObject):
        """Toggle the caret and redraw just the line it is on."""
        try:
            g_blink_on()[] = 0 if g_blink_on()[] != 0 else 1
            if g_focused()[] == 0:
                return
            with autoreleasepool():
                let view = ObjCObject(self.__objc_id)
                let pos = caret_position(g_caret()[])
                _ = msg_send[ObjCObject, "NSView", "setNeedsDisplayInRect:"](
                    view, rect(pos.x - 1.0, pos.y, 4.0, line_height())
                )
        except:
            pass

    def acceptsFirstMouse_(self, event: ObjCObject) -> Bool:
        return True

    def keyDown_(self, event: ObjCObject):
        """Every key goes to the input context, never straight to the buffer.

        Interpreting the event ourselves would work for ASCII and break every
        input method: it is `interpretKeyEvents:` that turns a keystroke into
        `insertText:`, a command selector, or marked text mid-composition.
        """
        try:
            with autoreleasepool():
                let view = ObjCObject(self.__objc_id)
                let NSArray = ObjCClass.lookup["NSArray"]()
                let one = msg_send[
                    ObjCObject, "NSArray", "arrayWithObject:", is_class=True
                ](NSArray.as_object(), event)
                _ = msg_send[ObjCObject, "NSView", "interpretKeyEvents:"](
                    view, one.ptr()
                )
        except:
            pass

    def insertText_replacementRange_(self, text: ObjCObject, replacement: NSRange):
        """Committed text: a character, a pasted run, or a finished composition."""
        try:
            with autoreleasepool():
                let obj = text
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
                # A word character continues a completion; anything else ends one.
                if popup_open():
                    let typed = ns_to_string(s)
                    if typed.byte_length() != 1:
                        hide_popup()
                _refresh(P(unsafe_from_address=self.__objc_id))
        except:
            pass

    def setMarkedText_selectedRange_replacementRange_(self, text: ObjCObject, selected: NSRange, replacement: NSRange):
        """Text mid-composition: shown, not committed. Replacing the previous
        marked run is what keeps a CJK candidate window from duplicating input."""
        try:
            with autoreleasepool():
                let obj = text
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
                _refresh(P(unsafe_from_address=self.__objc_id))
        except:
            pass

    def unmarkText(self):
        g_marked_at()[] = 0
        g_marked_len()[] = 0

    def hasMarkedText(self) -> Bool:
        return g_marked_len()[] > 0

    def markedRange(self) -> NSRange:
        try:
            if g_marked_len()[] == 0:
                return NSRange(NOT_FOUND, 0)
            let a = byte_to_utf16(g_marked_at()[])
            let b = byte_to_utf16(g_marked_at()[] + g_marked_len()[])
            return NSRange(a, b - a)
        except:
            return NSRange(NOT_FOUND, 0)

    def selectedRange(self) -> NSRange:
        try:
            let a = byte_to_utf16(sel_start())
            let b = byte_to_utf16(sel_end())
            return NSRange(a, b - a)
        except:
            return NSRange(0, 0)

    def validAttributesForMarkedText(self) -> ObjCObject:
        """No marked-text styling is honoured, so the list is empty -- which is a
        legitimate answer, and an empty array rather than nil."""
        try:
            with autoreleasepool():
                let NSArray = ObjCClass.lookup["NSArray"]()
                return msg_send[ObjCObject, "NSArray", "array", is_class=True](
                    NSArray.as_object()
                )
        except:
            return ObjCObject(0)

    def attributedSubstringForProposedRange_actualRange_(self, range: NSRange, actual: P) -> ObjCObject:
        """The text an input method wants to reconsider -- used by dictionary
        lookup and by some candidate windows."""
        try:
            with autoreleasepool():
                if not has_rope():
                    return ObjCObject(0)
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
                return att
        except:
            return ObjCObject(0)

    def firstRectForCharacterRange_actualRange_(self, range: NSRange, actual: P) -> CGRect:
        """Where to put the candidate window: screen coordinates of the composing
        text. Getting this wrong parks the CJK candidate list in a corner."""
        try:
            with autoreleasepool():
                let view = ObjCObject(self.__objc_id)
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

    def characterIndexForPoint_(self, point: CGPoint) -> Int:
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

    def doCommandBySelector_(self, selector: P):
        """Movement and deletion arrive as selectors, not characters."""
        try:
            let raw = external_call["sel_getName", P](selector)
            if Int(raw) == 0:
                return
            let name = String(unsafe_from_utf8_ptr=raw.unsafe_bitcast[c_char]())
            apply_command(name)
            _refresh(P(unsafe_from_address=self.__objc_id))
        except:
            pass


class RoastCompletionView(NSView):
    """The completion popup's content view."""

    def drawRect_(self, dirty: CGRect):
        """The candidate list: label on the left, detail greyed on the right."""
        try:
            with autoreleasepool():
                let view = ObjCObject(self.__objc_id)
                let bounds = msg_send[CGRect, "NSView", "bounds"](view)
                let NSColorP = ObjCClass.lookup["NSColor"]()

                # Background and a hairline border, so it reads as a panel rather
                # than text that has escaped.
                let bg = msg_send[
                    ObjCObject, "NSColor", "controlBackgroundColor", is_class=True
                ](NSColorP.as_object())
                _ = msg_send[ObjCObject, "NSColor", "setFill"](bg)
                _ = external_call["NSRectFill", NoneType](bounds)

                let n = min(completion_count(), POPUP_MAX_ROWS)
                let attrs = ObjCObject(g_attrs()[])
                let dim = ObjCObject(g_gutter_attrs()[])
                var row = 0
                while row < n:
                    let y = Float64(row) * POPUP_ROW_H
                    if row == g_popup_sel()[]:
                        let hl = msg_send[
                            ObjCObject, "NSColor", "selectedContentBackgroundColor",
                            is_class=True,
                        ](NSColorP.as_object())
                        _ = msg_send[ObjCObject, "NSColor", "setFill"](hl)
                        _ = external_call["NSRectFill", NoneType](
                            rect(0.0, y, bounds.size.width, POPUP_ROW_H)
                        )
                    _ = msg_send[
                        ObjCObject, "NSString", "drawAtPoint:withAttributes:"
                    ](
                        nsstring(g_comp_label()[][row]),
                        CGPoint(8.0, y + 2.0),
                        attrs.ptr(),
                    )
                    let detail = g_comp_detail()[][row]
                    if detail.byte_length() > 0:
                        # Right-aligned, so the eye can run down the signatures.
                        var chars = 0
                        for _ in detail.codepoints():
                            chars += 1
                        let dx = bounds.size.width - 8.0 - Float64(chars) * advance()
                        _ = msg_send[
                            ObjCObject, "NSString", "drawAtPoint:withAttributes:"
                        ](
                            nsstring(detail),
                            CGPoint(max(dx, 180.0), y + 2.0),
                            dim.ptr(),
                        )
                    row += 1
        except:
            pass

    def isFlipped(self) -> Bool:
        return True


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

    # Syntax colours. System colours rather than chosen ones, so the editor
    # follows the appearance the rest of the machine is using.
    let comment_c = msg_send[
        ObjCObject, "NSColor", "systemGreenColor", is_class=True
    ](NSColor.as_object())
    let string_c = msg_send[
        ObjCObject, "NSColor", "systemRedColor", is_class=True
    ](NSColor.as_object())
    let keyword_c = msg_send[
        ObjCObject, "NSColor", "systemPurpleColor", is_class=True
    ](NSColor.as_object())
    let number_c = msg_send[
        ObjCObject, "NSColor", "systemBlueColor", is_class=True
    ](NSColor.as_object())
    g_attr_comment()[] = _make_attrs(comment_c)
    g_attr_string()[] = _make_attrs(string_c)
    g_attr_keyword()[] = _make_attrs(keyword_c)
    g_attr_number()[] = _make_attrs(number_c)

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

    # Instantiating the class registers it -- methods, protocol and all. The
    # conformance report the smoke test asserts stays: it now checks what the
    # declaration claims rather than what a builder was told.
    var view = ObjCObject(RoastGridView().__objc_id)
    var proto = external_call["objc_getProtocol", P](
        "NSTextInputClient".unsafe_ptr()
    )
    if not msg_send[Bool, "NSObject", "conformsToProtocol:"](view, proto):
        print("roast: NSTextInputClient protocol not registered")
    _ = msg_send[ObjCObject, "NSView", "setFrame:"](view, frame)

    # The blink. 0.53 s is what Cocoa uses, and matching it means the caret
    # keeps time with every other text field on screen.
    g_blink_on()[] = 1
    let NSTimer = ObjCClass.lookup["NSTimer"]()
    _ = msg_send[
        ObjCObject,
        "NSTimer",
        "scheduledTimerWithTimeInterval:target:selector:userInfo:repeats:",
        is_class=True,
    ](
        NSTimer.as_object(),
        Float64(0.53),
        view.ptr(),
        sel["roastBlink:"]().ptr(),
        view.ptr(),
        Bool(True),
    )
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


# NSRange comes from std.objc (TrivialRegisterPassable, x0/x1); location and
# length are counted in UTF-16 units here, as everywhere in Cocoa text.
comptime NOT_FOUND = NSRange.NOT_FOUND

# Caret and selection, in byte offsets. anchor == caret means no selection.
comptime g_caret = named_global["roast.caret", Int]
comptime g_anchor = named_global["roast.anchor", Int]
# The composing region, in bytes; length 0 means nothing is being composed.
comptime g_marked_at = named_global["roast.marked.at", Int]
comptime g_marked_len = named_global["roast.marked.len", Int]

# Undo is a stack of whole buffers, which is only sane because they share
# structure: a thousand entries of a 14 MB file cost kilobytes, not gigabytes.
# There are no command objects and no inverse operations, so there is nothing
# to get wrong when a new kind of edit is added later.
comptime g_undo = named_global["roast.undo", List[Rope]]
comptime g_redo = named_global["roast.redo", List[Rope]]
comptime g_undo_caret = named_global["roast.undo.caret", List[Int]]
comptime g_redo_caret = named_global["roast.redo.caret", List[Int]]

# Typing should undo in words, not letters. An insert that continues the
# previous one -- single character, immediately after it -- joins the entry
# already on the stack instead of pushing a new one.
comptime g_coalesce_at = named_global["roast.coalesce.at", Int]

# The caret blinks, and is drawn only while the view has focus.
# What is being searched for, and where the last match was. The query is a
# one-element list for the same reason the buffer is: a zero-initialised global
# List is valid, and a zero-initialised String is not.
comptime g_query = named_global["roast.query", List[String]]
comptime g_match_at = named_global["roast.match.at", Int]

# Bumped on every edit. The app watches it to decide when to tell the server,
# rather than sending a document on every keystroke.
comptime g_revision = named_global["roast.revision", Int]

# The completion popup: a borderless window floating above everything, drawing
# its own list. A floating window rather than something inside the editor so it
# is not clipped by the scroll view, and a self-drawn list rather than an
# NSTableView so there is no data source to keep in step with the model.
comptime g_popup = named_global["roast.popup", Int]
comptime g_popup_view = named_global["roast.popup.view", Int]
comptime g_popup_open = named_global["roast.popup.open", Int]
comptime g_popup_sel = named_global["roast.popup.sel", Int]
# Where the word being completed starts, so accepting replaces the prefix
# rather than appending to it.
comptime g_popup_from = named_global["roast.popup.from", Int]

comptime POPUP_ROW_H = 20.0
comptime POPUP_MAX_ROWS = 12
comptime POPUP_W = 460.0

# Text colours, made once and kept: NSColor lookups in a draw loop are the
# easy way to make a fast renderer slow.
comptime g_col_plain = named_global["roast.col.plain", Int]
comptime g_col_comment = named_global["roast.col.comment", Int]
comptime g_col_string = named_global["roast.col.string", Int]
comptime g_col_keyword = named_global["roast.col.keyword", Int]
comptime g_col_number = named_global["roast.col.number", Int]

# One attribute dictionary per colour, for the same reason.
comptime g_attr_comment = named_global["roast.attr.comment", Int]
comptime g_attr_string = named_global["roast.attr.string", Int]
comptime g_attr_keyword = named_global["roast.attr.keyword", Int]
comptime g_attr_number = named_global["roast.attr.number", Int]

comptime KIND_PLAIN = 0
comptime KIND_COMMENT = 1
comptime KIND_STRING = 2
comptime KIND_KEYWORD = 3
comptime KIND_NUMBER = 4


def _is_keyword(w: String) -> Bool:
    """cocoa-mojo's keywords, `let` and `fn` among them -- this fork revived
    both, and an editor that greys them out would be quietly wrong."""
    return (
        w == "def" or w == "fn" or w == "let" or w == "var" or w == "struct"
        or w == "trait" or w == "comptime" or w == "alias" or w == "import"
        or w == "from" or w == "as" or w == "if" or w == "elif" or w == "else"
        or w == "while" or w == "for" or w == "in" or w == "return"
        or w == "raise" or w == "raises" or w == "try" or w == "except"
        or w == "with" or w == "yield" or w == "pass" or w == "break"
        or w == "continue" or w == "and" or w == "or" or w == "not"
        or w == "is" or w == "True" or w == "False" or w == "None"
        or w == "self" or w == "Self" or w == "mut" or w == "out"
        or w == "deinit" or w == "ref" or w == "where"
    )


def highlight(line: String) -> List[Int]:
    """One kind per character of the line.

    A lexer rather than a parser, and deliberately: this runs on every visible
    line of every frame and has to be right about comments, strings and
    keywords without knowing anything else. Semantic tokens from the server
    layer on top when they arrive; this is what shows instantly, and what still
    shows when there is no server at all.
    """
    var kinds = List[Int]()
    var chars = List[String]()
    for c in line.codepoints():
        chars.append(String(c))
        kinds.append(KIND_PLAIN)

    var i = 0
    let n = len(chars)
    while i < n:
        let c = chars[i]
        if c == "#":
            # To end of line, and nothing after it is anything else.
            while i < n:
                kinds[i] = KIND_COMMENT
                i += 1
            break
        if c == '"' or c == "'":
            let quote = c
            kinds[i] = KIND_STRING
            i += 1
            while i < n:
                kinds[i] = KIND_STRING
                if chars[i] == "\\" and i + 1 < n:
                    i += 1
                    kinds[i] = KIND_STRING
                elif chars[i] == quote:
                    i += 1
                    break
                i += 1
            continue
        let b = Int(ord(c)) if len(c.as_bytes()) == 1 else 0x100
        if b >= 0x30 and b <= 0x39:
            while i < n:
                let d = Int(ord(chars[i])) if len(chars[i].as_bytes()) == 1 else 0x100
                if not (
                    (d >= 0x30 and d <= 0x39)
                    or d == 0x2E
                    or d == 0x5F
                    or (d >= 0x61 and d <= 0x7A)
                    or (d >= 0x41 and d <= 0x5A)
                ):
                    break
                kinds[i] = KIND_NUMBER
                i += 1
            continue
        let ident = (
            (b >= 0x41 and b <= 0x5A) or (b >= 0x61 and b <= 0x7A) or b == 0x5F
        )
        if ident:
            # `var`, not `let`. In cocoa-mojo `let x = y` binds to y rather
            # than copying it, so `let start = i` followed i as the loop
            # advanced and the keyword span came out empty. That is the
            # revived binding doing exactly what it says -- an immutable
            # binding to a place -- and it is a trap wherever the intent was a
            # snapshot of a value.
            var start = i
            var word = String()
            while i < n:
                let d = Int(ord(chars[i])) if len(chars[i].as_bytes()) == 1 else 0x100
                if not (
                    (d >= 0x41 and d <= 0x5A)
                    or (d >= 0x61 and d <= 0x7A)
                    or (d >= 0x30 and d <= 0x39)
                    or d == 0x5F
                ):
                    break
                word += chars[i]
                i += 1
            if _is_keyword(word):
                var k = start
                while k < i:
                    kinds[k] = KIND_KEYWORD
                    k += 1
            continue
        i += 1
    return kinds^


def _attrs_for(kind: Int) -> ObjCObject:
    if kind == KIND_COMMENT:
        return ObjCObject(g_attr_comment()[])
    if kind == KIND_STRING:
        return ObjCObject(g_attr_string()[])
    if kind == KIND_KEYWORD:
        return ObjCObject(g_attr_keyword()[])
    if kind == KIND_NUMBER:
        return ObjCObject(g_attr_number()[])
    return ObjCObject(g_attrs()[])


def _make_attrs(colour: ObjCObject) -> Int:
    """An attribute dictionary for one colour, retained for the process."""
    let NSMutableDictionary = ObjCClass.lookup["NSMutableDictionary"]()
    var d = msg_send[
        ObjCObject, "NSMutableDictionary", "dictionary", is_class=True
    ](NSMutableDictionary.as_object())
    _ = msg_send[ObjCObject, "NSMutableDictionary", "setObject:forKey:"](
        d, ObjCObject(g_font()[]).ptr(),
        extern_object["NSFontAttributeName"]().ptr(),
    )
    _ = msg_send[ObjCObject, "NSMutableDictionary", "setObject:forKey:"](
        d, colour.ptr(),
        extern_object["NSForegroundColorAttributeName"]().ptr(),
    )
    _ = external_call["objc_retain", P](d.ptr())
    return d.addr()

comptime g_blink_on = named_global["roast.blink", Int]
comptime g_focused = named_global["roast.focused", Int]


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


def push_undo(coalescing: Bool = False):
    """Record the current buffer so an edit can be taken back.

    `coalescing` is the typing case: a run of single characters becomes one
    undo entry rather than one per keystroke.
    """
    if not has_rope():
        return
    if coalescing and g_coalesce_at()[] == g_caret()[] and len(g_undo()[]) > 0:
        return  # continues the run already recorded
    g_undo()[].append(g_buffer()[][0].copy())
    g_undo_caret()[].append(g_caret()[])
    # Any new edit invalidates the redo branch, as it must.
    while len(g_redo()[]) > 0:
        _ = g_redo()[].pop()
    while len(g_redo_caret()[]) > 0:
        _ = g_redo_caret()[].pop()


def undo() -> Bool:
    if len(g_undo()[]) == 0 or not has_rope():
        return False
    g_redo()[].append(g_buffer()[][0].copy())
    g_redo_caret()[].append(g_caret()[])
    set_rope(g_undo()[].pop())
    set_caret(g_undo_caret()[].pop())
    g_coalesce_at()[] = -1
    return True


def redo() -> Bool:
    if len(g_redo()[]) == 0 or not has_rope():
        return False
    g_undo()[].append(g_buffer()[][0].copy())
    g_undo_caret()[].append(g_caret()[])
    set_rope(g_redo()[].pop())
    set_caret(g_redo_caret()[].pop())
    g_coalesce_at()[] = -1
    return True


def query() -> String:
    if len(g_query()[]) == 0:
        return String()
    return g_query()[][0]


def set_query(var q: String):
    let slot = g_query()
    if len(slot[]) == 0:
        slot[].append(q^)
    else:
        slot[][0] = q^


def find_next(wrap: Bool = True) -> Bool:
    """Move the selection to the next match after the caret."""
    let q = query()
    if q.byte_length() == 0 or not has_rope():
        return False
    let buf = g_buffer()[][0]
    var hit = buf.find(q, g_caret()[])
    if hit < 0 and wrap:
        hit = buf.find(q, 0)          # wrap, the way every editor does
    if hit < 0:
        return False
    g_anchor()[] = hit
    g_caret()[] = hit + q.byte_length()
    g_match_at()[] = hit
    return True


def find_previous() -> Bool:
    let q = query()
    if q.byte_length() == 0 or not has_rope():
        return False
    let buf = g_buffer()[][0]
    var hit = buf.find_last(q, sel_start())
    if hit < 0:
        hit = buf.find_last(q, buf.byte_length())
    if hit < 0:
        return False
    g_anchor()[] = hit
    g_caret()[] = hit + q.byte_length()
    g_match_at()[] = hit
    return True


def match_count() -> Int:
    if query().byte_length() == 0 or not has_rope():
        return 0
    let buf = g_buffer()[][0]
    return len(buf.find_all_in(query(), 0, buf.byte_length()))


def display_column(offset: Int) -> Int:
    """The column an offset sits at, counted in characters rather than bytes.

    Fixed-pitch means one character is one cell, so this is what multiplies by
    the advance. East Asian double-width characters occupy two cells and are
    not handled here -- the design lists a width table as a stdlib gap, and
    until it exists a CJK line's caret drifts. Latin and code are exact.
    """
    if not has_rope():
        return 0
    let buf = g_buffer()[][0]
    let line = buf.line_of_offset(offset)
    let start = buf.line_start(line)
    var n = 0
    for _ in buf.slice(start, offset).codepoints():
        n += 1
    return n


def caret_position(offset: Int) -> CGPoint:
    """Where a byte offset lands on screen, in view coordinates."""
    if not has_rope():
        return CGPoint(GUTTER_W + TEXT_PAD, 0.0)
    let line = g_buffer()[][0].line_of_offset(offset)
    return CGPoint(
        GUTTER_W + TEXT_PAD + Float64(display_column(offset)) * advance(),
        Float64(line) * line_height(),
    )


def offset_at_point(x: Float64, y: Float64) -> Int:
    """The reverse: a click becomes a caret position."""
    if not has_rope():
        return 0
    let buf = g_buffer()[][0]
    let line = max(0, min(buf.line_count() - 1, Int(y / line_height())))
    let col = max(0, Int((x - GUTTER_W - TEXT_PAD) / advance() + 0.5))
    let text = buf.line(line)
    # Walk codepoints so a click past a multi-byte character lands after it,
    # never inside it.
    var seen = 0
    var at = buf.line_start(line)
    for c in text.codepoints():
        if seen >= col:
            break
        at += len(String(c).as_bytes())
        seen += 1
    return at


def replace_selection(text: String):
    """The one place the buffer changes. Everything else routes through here so
    the caret, the marked range and the view are updated together."""
    if not has_rope():
        return
    let a = sel_start()
    let b = sel_end()
    # A one-character insert with nothing selected is typing; anything else is
    # an edit worth its own undo entry.
    let typing = a == b and text.byte_length() == 1 and text != "\n"
    push_undo(coalescing=typing)
    set_rope(g_buffer()[][0].replace(a, b, text))
    set_caret(a + text.byte_length())
    g_coalesce_at()[] = g_caret()[] if typing else -1
    g_marked_at()[] = 0
    g_marked_len()[] = 0


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

        # While candidates are showing, the arrows and Enter belong to the
        # list, not the buffer. Escape puts it away; anything else that is not
        # a movement dismisses it, because a list that survives an edit is
        # answering a question nobody is asking any more.
        if popup_open():
            if name == "moveDown:":
                popup_move(1)
                return
            if name == "moveUp:":
                popup_move(-1)
                return
            if name == "insertNewline:" or name == "insertTab:":
                _ = popup_accept()
                return
            if name == "cancelOperation:":
                hide_popup()
                return
            hide_popup()

        if name == "undo:":
            _ = undo()
            return
        elif name == "redo:":
            _ = redo()
            return
        elif name == "selectAll:":
            g_anchor()[] = 0
            g_caret()[] = buf.byte_length()
            return

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
                push_undo()
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
                push_undo()
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
        elif name == "moveToBeginningOfDocument:":
            set_caret(0)
        elif name == "moveToEndOfDocument:":
            set_caret(buf.byte_length())
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


