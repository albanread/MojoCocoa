# ===----------------------------------------------------------------------=== #
# fluidctl — drive a running `fluid` from outside the process, in Mojo.
#
#     fluidctl <pid> snap | clear | rain | pause | quit
#
# Why a purpose-built sender rather than `osascript`: AppleScript addresses an
# application through a `tell application "..."` clause, which resolves a name,
# a bundle identifier or a path to an application BUNDLE. `fluid` is a bare
# Mach-O executable produced by `mojo build` -- it has no bundle and no
# identifier, so there is nothing for a tell clause to resolve, and no amount
# of `«event FLUDsnap»` syntax fixes that.
#
# The Apple Event machinery underneath is perfectly happy to address a process
# by pid, though, which is what `+[NSAppleEventDescriptor
# descriptorWithProcessIdentifier:]` builds. So this sends the same events
# AppleScript would, addressed the one way that works for an un-bundled binary.
#
# Make `fluid` a real .app bundle later and `tell application "Fluid" to
# «event FLUDsnap»` starts working with no change to the receiving side --
# the handlers are registered against the event class and ID, not against how
# the event was addressed.
# ===----------------------------------------------------------------------=== #

from std.objc import ObjCClass, ObjCObject, msg_send, autoreleasepool
from std.ffi import external_call, c_char
from std.memory import OpaquePointer
from std.sys import argv

comptime P = OpaquePointer[MutUntrackedOrigin]

comptime AE_CLASS = 0x464C5544  # 'FLUD'

# typeApplicationBundleID etc. are not needed: we address by pid.
comptime KAE_NO_REPLY = 0x00000001  # kAENoReply
comptime KAE_NORMAL_PRIORITY = 0x00000000


def verb_code(name: String) -> Int:
    if name == "snap":
        return 0x736E6170
    if name == "clear":
        return 0x636C7220  # 'clr '
    if name == "rain":
        return 0x7261696E
    if name == "pause":
        return 0x70617573  # 'paus'
    if name == "quit":
        return 0x71756974
    return 0


def main() raises:
    var args = argv()
    if len(args) != 3:
        print("usage: fluidctl <pid> snap|clear|rain|pause|quit")
        print()
        print("  pid   the process id `fluid` printed when it started")
        return

    var pid = Int(String(args[1]))
    var verb = String(args[2])
    var eid = verb_code(verb)
    if eid == 0:
        print("unknown verb:", verb)
        print("expected one of: snap clear rain pause quit")
        return

    with autoreleasepool():
        var NSAppleEventDescriptor = ObjCClass.lookup[
            "NSAppleEventDescriptor"
        ]()

        # The target: this process, by pid.
        var target = msg_send[
            ObjCObject,
            "NSAppleEventDescriptor",
            "descriptorWithProcessIdentifier:",
            is_class=True,
        ](NSAppleEventDescriptor.as_object(), Int32(pid))

        var event = msg_send[
            ObjCObject,
            "NSAppleEventDescriptor",
            "appleEventWithEventClass:eventID:targetDescriptor:returnID:"
            "transactionID:",
            is_class=True,
        ](
            NSAppleEventDescriptor.as_object(),
            UInt32(AE_CLASS),
            UInt32(eid),
            target.ptr(),
            Int16(-1),  # kAutoGenerateReturnID
            Int32(0),  # kAnyTransactionID
        )

        # -[NSAppleEventDescriptor sendEventWithOptions:timeout:error:]
        #
        # The error: parameter is an NSError** out-param. Pointer in this fork
        # is non-nullable by construction -- a genuinely good constraint -- so
        # rather than fabricating a null, give it a real one-slot box and read
        # what lands there.
        var errbox = external_call["calloc", P](Int(1), Int(8))
        var reply = msg_send[
            ObjCObject,
            "NSAppleEventDescriptor",
            "sendEventWithOptions:timeout:error:",
        ](event, Int(KAE_NO_REPLY), Float64(2.0), errbox)
        print("  target nil?", target.is_nil(), " event nil?", event.is_nil(),
              " reply nil?", reply.is_nil(), " err slot:", 
              Pointer[Int, MutUntrackedOrigin](unsafe_from_address=Int(errbox))[])
        var errp = Pointer[Int, MutUntrackedOrigin](
            unsafe_from_address=Int(errbox)
        )
        if errp[] != 0:
            var e = ObjCObject(errp[])
            var desc = msg_send[ObjCObject, "NSError", "localizedDescription"](e)
            var cs = msg_send[P, "NSString", "UTF8String"](desc)
            print("send failed:", String(unsafe_from_utf8_ptr=cs.unsafe_bitcast[c_char]()))
            external_call["free", NoneType](errbox)
            return
        external_call["free", NoneType](errbox)

    print("sent", verb, "to pid", pid)
