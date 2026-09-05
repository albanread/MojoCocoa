# ===----------------------------------------------------------------------=== #
# Sprint G0 — device identity.
#
# The game pane's layers draw with a device obtained from Metal; its blitter
# kernels run on the device the GPU runtime chose. If those are two different
# objects, a texture made by one and sampled by the other is undefined — so
# this asks whether they are the same pointer, before anything depends on it.
#
# The runtime already publishes its device: `AsyncRT_DeviceContext_metal_device`
# is an extern "C" entry point in AppleGPURT.cpp, added for its own reasons and
# reachable from Mojo with no runtime change at all.
#
# Run: cocoamojo run gamepane/tests/spike_device.mojo
# ===----------------------------------------------------------------------=== #

from std.objc import load_framework, ObjCObject, send, ns_to_string, autoreleasepool
from std.ffi import external_call, c_char
from std.memory import OpaquePointer, Pointer
from max.gpu.host import DeviceContext

comptime P = OpaquePointer[MutUntrackedOrigin]


def main() raises:
    if not load_framework["Metal"]():
        raise Error("could not load Metal")

    var failures = 0

    with autoreleasepool():
        # The device the LAYERS would use.
        let metal_dev = Int(external_call["MTLCreateSystemDefaultDevice", P]())

        # The device the RUNTIME uses for kernels.
        var ctx = DeviceContext(api="metal")
        # `const char *f(void **result, const DeviceContext *ctx)`.
        # Both parameters are pointers, and on arm64 a pointer and an Int
        # travel in the same register, so passing addresses as Int is the
        # unambiguous spelling for a raw C call -- the Pointer(to=x)[] idiom
        # elsewhere in this tree belongs to the typed ObjC surface, which
        # takes the address itself.
        var slot = List[Int](length=1, fill=0)
        let err = external_call[
            "AsyncRT_DeviceContext_metal_device", P
        ](slot.unsafe_ptr(), ctx._handle)
        if Int(err) != 0:
            print(
                "FAIL  metal_device returned an error:",
                String(unsafe_from_utf8_ptr=err.unsafe_bitcast[c_char]()),
            )
            failures += 1
        let runtime_dev = slot[0]

        print("MTLCreateSystemDefaultDevice:", hex(metal_dev))
        print("runtime device            :", hex(runtime_dev))
        if runtime_dev == 0:
            print("FAIL  the runtime reported no device")
            failures += 1
        elif runtime_dev == metal_dev:
            print("ok    the same MTLDevice object — one device, no bridging")
        else:
            # Not fatal, but it decides the design: textures would have to be
            # created on the runtime's device rather than the default one.
            print("NOTE  different objects; layers must use the runtime's device")
            let a = ns_to_string(
                ObjCObject(send[ObjCObject, "name"](ObjCObject(metal_dev)).addr())
            )
            let b = ns_to_string(
                ObjCObject(send[ObjCObject, "name"](ObjCObject(runtime_dev)).addr())
            )
            print("      default:", a, " runtime:", b)

    print()
    if failures == 0:
        print("G0 device identity: PASS")
    else:
        print("G0 device identity: FAILED", failures, "check(s)")
        raise Error("device spike failed")
