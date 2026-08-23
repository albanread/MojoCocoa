# S5: the compiler reads cocoa.sqlite during elaboration. Everything below is
# resolved -- and checked -- before any code is generated.
from std.sys import size_of, align_of
from std.sys._cocoakb import (
    cocoakb_struct_size,
    cocoakb_struct_align,
    cocoakb_field_offset,
    cocoakb_enum_value,
    cocoakb_superclass,
    cocoakb_method_encoding,
    cocoakb_msgsend_variant,
    cocoakb_method_ret_class,
    cocoakb_posix_sig,
    cocoakb_posix_ret_class,
    cocoakb_posix_arg_classes,
    cocoakb_db_hash,
)


struct CGPoint:
    var x: Float64
    var y: Float64


struct CGSize:
    var width: Float64
    var height: Float64


struct CGRect:
    var origin: CGPoint
    var size: CGSize


def main():
    # ── Checked layouts: a struct that drifts from the SDK fails to build ──
    comptime assert size_of[CGPoint]() == cocoakb_struct_size["CGPoint"]()
    comptime assert size_of[CGRect]() == cocoakb_struct_size["CGRect"]()
    comptime assert align_of[CGRect]() == cocoakb_struct_align["CGRect"]()
    comptime assert cocoakb_field_offset["CGRect", "origin"]() == 0
    comptime assert cocoakb_field_offset["CGRect", "size"]() == 16
    print("layouts:   CGPoint/CGSize/CGRect verified against the SDK")

    # ── Enum values, straight from BridgeSupport ──
    comptime assert cocoakb_enum_value["NSUTF8StringEncoding"]() == 4
    comptime titled = cocoakb_enum_value["NSWindowStyleMaskTitled"]()
    print("enums:     NSUTF8StringEncoding=4, NSWindowStyleMaskTitled =", titled)

    # ── Inheritance-resolved method facts ──
    comptime enc = cocoakb_method_encoding["NSMutableString", "length"]()
    comptime assert enc == "Q16@0:8"
    print("methods:   NSMutableString.length found on a superclass:", enc)
    comptime sup = cocoakb_superclass["NSMutableString"]()
    print("           superclass(NSMutableString) =", sup)

    # ── Dispatch selection, and the AAPCS64 register classes behind it ──
    # On arm64 the stub is always objc_msgSend: the 32-byte CGRect that x86-64
    # must route through objc_msgSend_stret is a homogeneous float aggregate
    # here, returned in v0-v3 by the ordinary send. The classification is what
    # differs between the two; the query and the API do not.
    comptime plain = cocoakb_msgsend_variant["NSString", "length"]()
    comptime rect = cocoakb_msgsend_variant["NSValue", "rectValue"]()
    comptime cls_m = cocoakb_msgsend_variant["NSObject", "alloc", True]()
    comptime assert plain == "objc_msgSend"
    comptime assert rect == "objc_msgSend"
    comptime assert cls_m == "objc_msgSend"
    comptime assert cocoakb_method_ret_class["NSString", "length"]() == "g"
    comptime assert cocoakb_method_ret_class["NSValue", "rectValue"]() == "h4"
    print("dispatch:  -[NSString length]  ->", plain, "(ret g, one GPR)")
    print("           -[NSValue rectValue] ->", rect, "(ret h4, HFA in v0-v3)")
    print("           +[NSObject alloc]   ->", cls_m)

    # ── The POSIX layer, same database, same discipline ──
    print("posix:     open:", cocoakb_posix_sig["open"](),
          "| ret", cocoakb_posix_ret_class["open"](),
          "args", cocoakb_posix_arg_classes["open"]())

    # ── The reproducibility pin ──
    print("db:        sha256", cocoakb_db_hash())
    print("S5-COCOAKB: PASS")
