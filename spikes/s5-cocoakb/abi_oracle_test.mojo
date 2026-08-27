# The C ABI, checked against clang rather than against ourselves.
#
# Every other test here has Mojo on both ends and so proves only that
# cocoa-mojo agrees with itself. This one links abi_oracle.c -- compiled by
# the same clang that compiled AppKit -- and lets IT send the messages, which
# makes the answers ground truth rather than a shared opinion.
#
# Three shapes, one per AAPCS64 rule the trampoline has to survive:
#   setViewport:   48-byte non-HFA argument  -> caller copy behind a pointer
#   setFrameSize:  16-byte HFA argument      -> v0-v1
#   frameTransform 48-byte non-HFA result    -> hidden x8 pointer
#
# All three work, and that is the point: the compiler needs no gate for them.
# CABIAAPCS.cpp classifies the trampoline's signature properly because the
# trampoline is a C-ABI function. A gate refusing large aggregates was very
# nearly added on the opposite assumption -- this test is what disproved it.
from std.objc import ObjCObject, ObjCClass, msg_send, load_framework, named_global
from std.ffi import external_call
from std.sys.info import TrivialRegisterPassable

comptime g_sum = named_global["oracle.sum", Int]
comptime g_pair = named_global["oracle.pair", Int]

@fieldwise_init
struct Big(TrivialRegisterPassable):
    var a: Float64
    var b: Float64
    var c: Float64
    var d: Float64
    var e: Float64
    var f: Float64

@fieldwise_init
struct Pair(TrivialRegisterPassable):
    var x: Float64
    var y: Float64

class Probe(NSView):
    def setViewport_(self, v: Big):
        g_sum()[] = Int(v.a + v.b + v.c + v.d + v.e + v.f)

    def frameTransform(self) -> Big:
        return Big(1.0, 2.0, 4.0, 8.0, 16.0, 32.0)   # 63

    def setFrameSize_(self, p: Pair):
        g_pair()[] = Int(p.x + p.y)

def main() raises:
    if not load_framework["AppKit"]():
        raise Error("no AppKit")
    var probe = Probe()
    var id = probe.__objc_id
    external_call["poke_big", NoneType](id)
    external_call["poke_pair", NoneType](id)
    var ok = g_sum()[] == 24 and g_pair()[] == 31
    var back = external_call["take_big", Float64](id)
    if not ok or Int(back) != 63:
        print("indirect arg", g_sum()[], "want 24")
        print("hfa arg     ", g_pair()[], "want 31")
        print("sret result ", Int(back), "want 63")
        raise Error("the trampoline disagrees with clang about the C ABI")
    print("c abi matches clang OK")
