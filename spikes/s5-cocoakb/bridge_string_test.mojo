# Bare Strings cross to NSString where the selector takes an object.
#
# Sprint P4's blocked half, unblocked compiler-side without touching the
# language: a comptime `if T == String` cannot narrow the value inside a
# generic callee, so the keyword hooks bridge INSTEAD at the call site --
# where the operand's type is still concrete -- whenever the metadata says
# the argument position is an object. A String where the selector takes a
# NON-object is deliberately left unwrapped: it reaches the callee's guard
# and is refused with a teaching error (must_fail_kwarg_string pins that).
from std.objc import load_framework, autoreleasepool
from std.objc.typed import Cls, Obj


def main() raises:
    with autoreleasepool():
        # The call direction: +dictionaryWithObject:forKey:, both arguments
        # objects, both bare Strings.
        let dc = Cls["NSMutableDictionary"]()
        var d = dc.dictionaryWithObject("bare value", forKey="bare key")
        if Obj["NSDictionary"](d.addr()).count() != 1:
            raise Error("the bridged class-side call built nothing")

        # The construction direction: +labelWithString:, a one-label
        # factory whose only argument is an object.
        if not load_framework["AppKit"]():
            raise Error("could not load AppKit")
        comptime NSTextField = Obj["NSTextField"]
        let field = NSTextField(labelWithString="A bare label")
        if Obj["NSString"](field.stringValue().addr()).length() != 12:
            raise Error("the bridged construction built nothing")

    print("string bridging: call side and construction side both verified")
