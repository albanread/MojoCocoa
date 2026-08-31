# A misspelled keyword label is a compile error, not a runtime
# doesNotRecognizeSelector:. The selector is assembled from the name and the
# labels together, so a label the SDK has never heard of fails the lookup --
# naming the class, the method and the label that built the selector nobody
# records.
from std.objc import Cls, Obj, load_framework
from std.objc.geometry import CGRect, CGPoint, CGSize


def main() raises:
    if not load_framework["AppKit"]():
        raise Error("could not load AppKit")
    let wc = Cls["NSWindow"]()
    var win = wc.alloc()
    win = Obj["NSWindow"](win.addr()).initWithContentRect_styleMask_backing_defer(
        CGRect(CGPoint(1.0, 1.0), CGSize(10.0, 10.0)), Int(15), Int(2), False
    )
    # 'diplay' is not a part of any selector; the frame stays put and the
    # program does not build.
    Obj["NSWindow"](win.addr()).setFrame(
        CGRect(CGPoint(2.0, 2.0), CGSize(9.0, 9.0)), diplay=False
    )
