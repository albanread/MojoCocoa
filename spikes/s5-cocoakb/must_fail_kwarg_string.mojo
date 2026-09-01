# A String argument where the selector takes a non-object is a compile
# error, not memory corruption at run time. Sprint P4's safety half: the
# @encode kind of every argument position is packed into an integer at
# compile time, and a String is refused wherever it cannot legally cross.
# (Where the selector DOES take an object, the String is also refused for
# now -- automatic bridging is blocked on comptime value narrowing; see the
# sprint notes -- with a message saying to wrap it as nsstring(s).ptr().)
from std.objc import load_framework
from std.objc.typed import Obj
from std.objc.geometry import CGRect, CGPoint, CGSize

comptime NSWindow = Obj["NSWindow"]


def main() raises:
    if not load_framework["AppKit"]():
        raise Error("could not load AppKit")
    let win = NSWindow(
        contentRect=CGRect(CGPoint(5.0, 5.0), CGSize(200.0, 100.0)),
        styleMask=Int(15),
        backing=Int(2),
        defer=False,
    )
    # setStyleMask: takes an integer. A String here used to compile and
    # hand Cocoa garbage; it must not build.
    win.setStyleMask("titled")
