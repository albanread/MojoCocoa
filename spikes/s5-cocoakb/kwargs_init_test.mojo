# Constructing Cocoa objects with keyword arguments.
#
# Sprint P2 of cocoa_improvements_design.md. `NSWindow(contentRect=...,
# styleMask=...)` is now a construction, not an alloc/init chain written out
# by hand -- and the machinery is generic: the database decides which
# constructor the labels name, with no class written down anywhere.
#
# Two spellings exist and the labels decide:
#   the INIT form -- `alloc` plus an initialiser whose first part is
#   'initWith' with the first label capitalised onto it
#   (initWithContentRect:styleMask:backing:defer:).
#   the FACTORY form -- a class method whose selector's parts are the labels
#   verbatim (buttonWithTitle:target:action:).
#
# Three different classes exercise three different shapes, so the check
# proves the machinery is not NSWindow-shaped. The BARE String crosses to
# NSString automatically: the hook bridges it where the metadata says the
# argument is an object, at the call site where the type is still concrete
# -- the compiler-side unblock of sprint P4's blocked half.
from std.objc import (
    Obj,
    ObjCObject,
    load_framework,
    nsstring,
    sel,
    autoreleasepool,
)
from std.objc.geometry import CGRect, CGPoint, CGSize

comptime NSWindow = Obj["NSWindow"]
comptime NSTextView = Obj["NSTextView"]
comptime NSButton = Obj["NSButton"]


def main() raises:
    if not load_framework["AppKit"]():
        raise Error("could not load AppKit")

    with autoreleasepool():
        # The INIT form, four labels: alloc + initWithContentRect:...
        let win = NSWindow(
            contentRect=CGRect(CGPoint(100.0, 100.0), CGSize(300.0, 200.0)),
            styleMask=Int(15),
            backing=Int(2),
            defer=False,
        )
        let f = win.frame()
        if f.origin.x != 100.0 or f.size.width != 300.0:
            raise Error("the four-label construction is not the window asked for")
        if f.size.height != 228.0:
            # 200 plus the title bar -- a real window, not a bare rect.
            raise Error("the constructed window has no title bar")

        # The INIT form, one label, on a second class: alloc + initWithFrame:
        let tv = NSTextView(frame=CGRect(CGPoint(0.0, 0.0), CGSize(80.0, 20.0)))
        if tv.frame().size.width != 80.0:
            raise Error("the one-label construction is not the view asked for")

        # The FACTORY form, three labels, on a third class:
        # +buttonWithTitle:target:action:
        let btn = NSButton(
            buttonWithTitle="Click",
            target=ObjCObject(0),
            action=sel["beep:"]().ptr(),
        )
        if btn.title().length() != 5:
            raise Error("the factory-form construction built nothing")

    print(
        "keyword construction: init 4-label, init 1-label, factory 3-label"
        " all verified"
    )
