# std.objc P4: struct returns and struct arguments through msg_send, dispatched
# by the database. CGRect is 32 bytes; on x86-64 that is a SysV MEMORY return
# routed through objc_msgSend_stret, while on arm64 it is a homogeneous float
# aggregate (h4) returned in v0-v3 by the ordinary send. Either way the
# programmer never names the stub, and passing/returning the struct is just a
# typed Mojo value -- which is the whole point of reading it from the SDK.
#
# (Filename kept to match the sister x86-64 fork; there is no stret on arm64.)
from std.objc import ObjCClass, ObjCObject, msg_send
from std.sys._cocoakb import cocoakb_struct_size, cocoakb_field_offset
from std.sys import size_of


@fieldwise_init
struct CGPoint(Copyable, Movable):
    var x: Float64
    var y: Float64


@fieldwise_init
struct CGSize(Copyable, Movable):
    var width: Float64
    var height: Float64


@fieldwise_init
struct CGRect(Copyable, Movable):
    var origin: CGPoint
    var size: CGSize


def main():
    # Layout is checked against the SDK before any call happens.
    comptime assert size_of[CGRect]() == cocoakb_struct_size["CGRect"]()
    comptime assert cocoakb_field_offset["CGRect", "size"]() == 16

    var NSValue = ObjCClass.lookup["NSValue"]()

    # +[NSValue valueWithRect:] -- a 32-byte struct passed BY VALUE. AAPCS64
    # classifies it h4, so it travels in v0-v3 rather than on the stack.
    var r = CGRect(CGPoint(10.0, 20.0), CGSize(30.0, 40.0))
    var v = msg_send[
        ObjCObject, "NSValue", "valueWithRect:", is_class=True
    ](NSValue.as_object(), r)
    print("NSValue created:", not v.is_nil())

    # -[NSValue rectValue] -- a 32-byte struct RETURN, classified h4. The C ABI
    # brings it back in v0-v3 because the declared return type is CGRect. No
    # stub named by hand, and no sret slot needed on this architecture.
    var back = msg_send[CGRect, "NSValue", "rectValue"](v)
    print(
        "rect back:",
        back.origin.x,
        back.origin.y,
        back.size.width,
        back.size.height,
    )

    var ok = (
        back.origin.x == 10.0
        and back.origin.y == 20.0
        and back.size.width == 30.0
        and back.size.height == 40.0
    )
    print("STRUCT-RETURN-TEST: PASS" if ok else "STRUCT-RETURN-TEST: FAIL")
