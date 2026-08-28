# Typing an Objective-C result from the SDK, with no cast and no annotation.
#
# This is MacModula2's trick -- its README claims "[arr count] is a CARDINAL
# and [view frame] is an NSRect, no casts" -- and reproducing it took one
# database table and one compiler fix.
#
# The table: `method_ret_kind`, derived in CocoaBaseMCP from the same @encode
# string everything else here comes from. It answers a different question from
# `method_abi.ret_class`, which says which REGISTER the result arrives in and
# so cannot tell an Int from a Bool from an object -- AAPCS64 puts all three
# in x0.
#
# The compiler fix: `cocoakb_query` folds at ATTRIBUTE level now, not only in
# the elaborator. A conditional type has to pick its branch while types are
# checked, and the elaborator runs long after that, so a type conditioned on a
# database answer used to stay symbolic -- the error printed the whole
# unevaluated conditional as the type.
#
# One more link mattered and is worth remembering: the class and selector
# reach the query as `!kgen.string` PARAMETERS, taken from `StringLiteral`'s
# own parameter. Routed through `_get_kgen_string` instead they arrive as a
# `data_to_str` expression, which does not fold at attribute level, and the
# chain breaks one level below the part that was fixed.
from std.sys._cocoakb import (
    cocoakb_p_method_ret_kind, cocoakb_p_method_ret_class,
)
from std.objc import (
    ObjCObject, msg_send, load_framework, nsstring, ns_to_string, CGRect,
)


comptime ObjCResult[cls: StringLiteral, sel: StringLiteral]: AnyType = (
    NoneType if cocoakb_p_method_ret_kind[cls, sel, "0"] == 118       # v
    else ObjCObject if cocoakb_p_method_ret_kind[cls, sel, "0"] == 64  # @
    else Bool if cocoakb_p_method_ret_kind[cls, sel, "0"] == 66        # B
    else Float64 if cocoakb_p_method_ret_kind[cls, sel, "0"] == 100    # d
    else CGRect if cocoakb_p_method_ret_kind[cls, sel, "0"] == 82      # R
    else Int
)


def main() raises:
    if not load_framework["AppKit"]():
        raise Error("no AppKit")

    var s = nsstring(String("hello"))

    # An unsigned count: typed Int, and usable as one without a cast.
    var n = msg_send[
        ObjCResult["NSString", "length"], "NSString", "length"
    ](s)
    if n + 1 != 6:
        print("length ->", n)
        raise Error("a scalar result was not typed as a scalar")

    # An object: typed ObjCObject, and it has an object's methods.
    var upper = msg_send[
        ObjCResult["NSString", "uppercaseString"], "NSString",
        "uppercaseString",
    ](s)
    if ns_to_string(upper) != String("HELLO"):
        raise Error("an object result was not typed as an object")

    # A predicate: typed Bool, not an Int that happens to be 0 or 1.
    var empty = msg_send[
        ObjCResult["NSString", "isEqualToString:"], "NSString",
        "isEqualToString:",
    ](s, s.ptr())
    if not empty:
        raise Error("a boolean result was not typed as a boolean")

    # And WHICH object, which I twice claimed was unknowable. It is not in
    # the method's encoding -- every object there is a bare `@` -- but a
    # PROPERTY's attribute string carries `T@"NSTextStorage"`, and a property
    # is read by a selector. Ingesting properties covers a little over half of
    # every object-returning instance method.
    comptime storage = cocoakb_p_method_ret_class[
        "NSTextView", "textStorage", "0"
    ]
    comptime window = cocoakb_p_method_ret_class["NSView", "window", "0"]
    if storage != StaticString("NSTextStorage") or window != StaticString("NSWindow"):
        print("textStorage ->", storage, " window ->", window)
        raise Error("the returned class did not come from the SDK")

    # `@self` is the instancetype rule: alloc/new/init answer the RECEIVER's
    # class, and they are declared on NSObject, so a chain-walking lookup
    # would otherwise report [NSString alloc] as an NSObject.
    comptime allocd = cocoakb_p_method_ret_class["NSObject", "alloc", "1"]
    if allocd != StaticString("@self"):
        print("alloc ->", allocd)
        raise Error("instancetype was resolved to a fixed class")

    print("typed results OK")
