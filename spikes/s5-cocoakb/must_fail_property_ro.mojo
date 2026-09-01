# A property the class has no setter for is a compile error naming the
# class and the property -- `titel` is a typo of `title`, and the metadata
# has no setTitle-shaped selector for it.
from std.objc import load_framework, nsstring
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
    win.titel = nsstring(String("no such property")).ptr()
