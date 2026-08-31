# Calling Cocoa with keyword arguments: `win.setFrame(aRect, display=True)`.
#
# Sprint P1 of cocoa_improvements_design.md. The labels are the selector's
# trailing parts, so a keyword call carries the selector in its own spelling;
# the compiler re-dispatches the call onto `__call_kw_param__` (the call-site
# sibling of `__getattr_param__`), the names arrive as StringLiteral
# parameters, and the selector is assembled from name and parts INSIDE the
# metadata database -- because string surgery does not fold, and a type
# conditioned on it would stay symbolic.
#
# What is checked here is the whole chain: the call compiles, the selector
# the labels build is one the SDK records, and the real Objective-C runtime
# executes it. The fold itself is checked first -- a type chosen by a keyword
# query is the canary the sprint ordered before anything else was built.
from std.sys._cocoakb import (
    cocoakb_p_selector_for_parts_1,
    cocoakb_p_ret_kind_for_parts_1,
)
from std.objc import (
    Cls,
    Obj,
    ObjCObject,
    load_framework,
    nsstring,
    autoreleasepool,
)
from std.objc.geometry import CGRect, CGPoint, CGSize


def main() raises:
    # The canary: a TYPE chosen by a keyword-form query must fold. setFrame:
    # display: returns void (kind 118), so T is Bool -- not an unevaluated
    # conditional printed as the type.
    comptime T: AnyType = (
        Bool
        if cocoakb_p_ret_kind_for_parts_1[
            "NSWindow", "setFrame", "0", "display"
        ] == 118
        else Int
    )
    comptime folded: T = True
    if not folded:
        raise Error("the keyword query did not fold into a type")

    comptime sel = cocoakb_p_selector_for_parts_1[
        "NSWindow", "setFrame", "0", "display"
    ]
    if String(sel) != "setFrame:display:":
        raise Error("name + label did not assemble the selector")

    if not load_framework["AppKit"]():
        raise Error("could not load AppKit")

    with autoreleasepool():
        # Instance side, one label: setFrame:display: on a real window.
        let wc = Cls["NSWindow"]()
        var win = wc.alloc()
        win = Obj["NSWindow"](win.addr()).initWithContentRect_styleMask_backing_defer(
            CGRect(CGPoint(100.0, 100.0), CGSize(300.0, 200.0)),
            Int(15),
            Int(2),
            False,
        )
        let w = Obj["NSWindow"](win.addr())

        w.setFrame(
            CGRect(CGPoint(400.0, 400.0), CGSize(320.0, 240.0)), display=False
        )
        let f = w.frame()
        if f.origin.x != 400.0 or f.size.width != 320.0:
            raise Error("the keyword call did not move the window")

        # Class side, one label: +dictionaryWithObject:forKey:
        let dc = Cls["NSMutableDictionary"]()
        var d = dc.dictionaryWithObject(
            nsstring(String("value")).ptr(), forKey=nsstring(String("key")).ptr()
        )
        if Obj["NSDictionary"](d.addr()).count() != 1:
            raise Error("the class-side keyword call built nothing")

        # Two labels: -initWithTitle:action:keyEquivalent:
        let mc = Cls["NSMenuItem"]()
        var mi = mc.alloc()
        mi = Obj["NSMenuItem"](mi.addr()).initWithTitle(
            nsstring(String("Hi")).ptr(),
            action=ObjCObject(0).ptr(),
            keyEquivalent=nsstring(String("q")).ptr(),
        )
        if Obj["NSMenuItem"](mi.addr()).title().length() != 2:
            raise Error("the two-label keyword call built nothing")

    print("keyword calls: fold, instance, class and two-label all verified")
