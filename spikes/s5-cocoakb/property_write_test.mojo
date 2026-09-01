# Property writes: `win.title = x` sends setTitle:.
#
# Sprint P3 of cocoa_improvements_design.md -- the write-shaped sibling of
# `__getattr_param__`. The attribute name arrives as a StringLiteral
# parameter, the setter it means is assembled and verified in SQL, and the
# value carries the same argument-kind guard as every call. A property the
# class has no setter for is a compile error naming the class and the
# property -- a read-only property, or a typo, never a silently dropped
# write.
#
# The value still crosses by hand here (nsstring(...).ptr()): automatic
# String bridging is blocked on comptime value narrowing -- sprint P4's
# notes -- and the guard says so if you try a bare String.
from std.objc import load_framework, nsstring, autoreleasepool
from std.objc.typed import Obj
from std.objc.geometry import CGRect, CGPoint, CGSize

comptime NSWindow = Obj["NSWindow"]


def main() raises:
    if not load_framework["AppKit"]():
        raise Error("could not load AppKit")

    with autoreleasepool():
        let win = NSWindow(
            contentRect=CGRect(CGPoint(5.0, 5.0), CGSize(200.0, 100.0)),
            styleMask=Int(15),
            backing=Int(2),
            defer=False,
        )
        var w = Obj["NSWindow"](win.addr())

        if w.title().length() != 0:
            raise Error("a fresh window should have no title")

        # Write, read back.
        win.title = nsstring(String("Set by property")).ptr()
        if w.title().length() != 15:
            raise Error("the property write did not take")

        # Write again, read back: the write path is live, not one-shot.
        win.title = nsstring(String("Longer title now")).ptr()
        if w.title().length() != 16:
            raise Error("the second property write did not take")

    print("property write: set, read back, set again -- verified")
