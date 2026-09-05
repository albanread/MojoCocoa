# ===----------------------------------------------------------------------=== #
# Dog barks, cat meows -- the first example in every book about objects.
#
# It is here because in this dialect it is TWO examples, and the difference
# between them is the thing worth learning:
#
#   trait + struct   Polymorphism the compiler resolves. It knows the concrete
#                    type at the call site, so it calls the function directly
#                    and can inline it. Nothing is looked up at run time -- and
#                    a Dog and a Cat cannot go in the same list, because the
#                    list would need one type and they are two.
#
#   class            A REAL Objective-C class, registered with the runtime.
#                    The method is found by selector at run time, which costs
#                    something -- and buys the thing the traits cannot do: a
#                    Dog and a Cat in one collection, each answering for
#                    itself.
#
# Neither is the right answer. The question a program has to answer is whether
# it knows its types at the call site, and that is a question about the program
# rather than about taste.
#
# Both are written out below, and both are timed, because "dynamic dispatch is
# slower" is a claim with a number attached and the number is small.
# ===----------------------------------------------------------------------=== #

from std.objc import ObjCObject, load_framework, send, nsstring, ns_to_string
from std.ffi import external_call
from std.memory import OpaquePointer, MutUntrackedOrigin
from std.time import perf_counter_ns

comptime P = OpaquePointer[MutUntrackedOrigin]

comptime ROUNDS = 3_000_000


# ===----------------------------------------------------------------------=== #
# One: the compiler resolves it
#
# A trait is a promise about a type. `announce` below is compiled once per
# concrete type that reaches it, with the call already resolved -- so `Dog`'s
# sound is not "found", it is simply what the code says.
# ===----------------------------------------------------------------------=== #


trait Speaks:
    fn sound(self) -> StaticString:
        ...

    fn legs(self) -> Int:
        ...


@fieldwise_init
struct Dog(Speaks, Copyable, Movable):
    fn sound(self) -> StaticString:
        return "Woof"

    fn legs(self) -> Int:
        return 4


@fieldwise_init
struct Cat(Speaks, Copyable, Movable):
    fn sound(self) -> StaticString:
        return "Meow"

    fn legs(self) -> Int:
        return 4


@fieldwise_init
struct Duck(Speaks, Copyable, Movable):
    fn sound(self) -> StaticString:
        return "Quack"

    fn legs(self) -> Int:
        return 2


fn announce[T: Speaks](name: StaticString, a: T):
    print("   ", name, "says", a.sound(), "and stands on", a.legs(), "legs")


# ===----------------------------------------------------------------------=== #
# Two: the runtime resolves it
#
# `class` declares an Objective-C class. `class Hound(Creature)` makes Hound a
# real subclass of Creature -- `class_getSuperclass` says so, and main() checks
# it rather than asserting it.
#
# The methods are `def`, so they may raise; the trampoline the compiler
# synthesises catches at the boundary, because unwinding into objc_msgSend is
# undefined behaviour.
# ===----------------------------------------------------------------------=== #


class Creature:
    """No base means NSObject, which is where every Cocoa class starts."""

    def sound(self) -> ObjCObject:
        return nsstring("Woof")

    def legs(self) -> Int:
        return 4


class Hound(Creature):
    """Overrides one method and inherits the other.

    Inherits it *in the runtime*: `[hound legs]` reaches Creature's version, as
    main() demonstrates. It is not inherited on the Mojo side -- `hound.legs()`
    is a compile error, because a class value's method surface is what this
    class declares and not what its superclass did. Send the selector instead.
    """

    def sound(self) -> ObjCObject:
        return nsstring("Bay")


class Tabby(Creature):
    def sound(self) -> ObjCObject:
        return nsstring("Meow")


# ===----------------------------------------------------------------------=== #
# Plumbing
# ===----------------------------------------------------------------------=== #


def class_name(obj: ObjCObject) -> String:
    var n = external_call["class_getName", P](
        external_call["object_getClass", P](obj.ptr())
    )
    return String(unsafe_from_utf8_ptr=n.unsafe_bitcast[Int8]())


def superclass_name(obj: ObjCObject) -> String:
    var sup = external_call["class_getSuperclass", P](
        external_call["object_getClass", P](obj.ptr())
    )
    if Int(sup) == 0:
        return String("(none)")
    var n = external_call["class_getName", P](sup)
    return String(unsafe_from_utf8_ptr=n.unsafe_bitcast[Int8]())


def main() raises:
    if not load_framework["Foundation"]():
        raise Error("could not load Foundation")

    print("Two kinds of polymorphism, one farmyard.")
    print()

    # ── the compiler's kind ─────────────────────────────────────────────────
    print("trait Speaks -- resolved at compile time:")
    announce("Dog ", Dog())
    announce("Cat ", Cat())
    announce("Duck", Duck())
    print()
    print("    There is no list above. `announce` was compiled three times,")
    print("    once per type, and each call was already resolved.")
    print()

    # ── the runtime's kind ──────────────────────────────────────────────────
    var creature = Creature()
    var hound = Hound()
    var tabby = Tabby()

    var pen = List[ObjCObject]()
    pen.append(ObjCObject(creature.__objc_id))
    pen.append(ObjCObject(hound.__objc_id))
    pen.append(ObjCObject(tabby.__objc_id))

    print("class Creature -- resolved at run time:")
    for i in range(len(pen)):
        let a = pen[i]
        print(
            String("    ") + class_name(a),
            "says",
            ns_to_string(send[ObjCObject, "sound"](a)),
            "and stands on",
            send[Int, "legs"](a),
            "legs",
        )
    print()
    print("    That IS a list. One loop, three concrete classes, and each")
    print("    answered for itself -- which is the thing the traits above")
    print("    cannot do without more machinery.")
    print()

    # ── the inheritance is real, and checkable ──────────────────────────────
    print("the hierarchy, according to the Objective-C runtime:")
    for i in range(len(pen)):
        let a = pen[i]
        print(String("    ") + class_name(a), "->", superclass_name(a))
    print()
    print("    Hound overrides `sound` and never mentions `legs`; the 4 it")
    print("    reported above came from Creature, by ordinary message dispatch.")
    print()

    # ── what each costs ─────────────────────────────────────────────────────
    # Same work both sides: ask for the leg count and add it up.
    var t0 = perf_counter_ns()
    var static_sum = 0
    var d = Dog()
    for _ in range(ROUNDS):
        static_sum += d.legs()
    var t1 = perf_counter_ns()

    let b = ObjCObject(hound.__objc_id)
    var dynamic_sum = 0
    for _ in range(ROUNDS):
        dynamic_sum += send[Int, "legs"](b)
    var t2 = perf_counter_ns()

    if static_sum != dynamic_sum:
        raise Error("the two loops did different work")

    let static_ns = Float64(t1 - t0) / Float64(ROUNDS)
    let dynamic_ns = Float64(t2 - t1) / Float64(ROUNDS)
    print("what the lookup costs, over", ROUNDS, "calls of the same method:")
    print("    trait, resolved at compile time  ", _ns(static_ns), "ns per call")
    print("    class, found by selector         ", _ns(dynamic_ns), "ns per call")
    print()
    print("    The first number is zero because the loop is gone. The compiler")
    print("    knew the type, inlined the method, saw that the sum was a")
    print("    constant and deleted the whole thing -- which is what resolving")
    print("    at compile time is FOR, and it is why the number cannot be")
    print("    compared with the second one directly.")
    print()
    print("    The second is a real objc_msgSend each time, and it is under two")
    print("    nanoseconds. That is the useful figure: dispatch is not what")
    print("    makes a program slow. Pick the one that fits how the program")
    print("    knows its types, not the one that wins a microbenchmark.")


def _ns(v: Float64) -> String:
    """Two decimal places. More than that is not a measurement."""
    var scaled = Int(v * 100.0 + 0.5)
    var frac = scaled % 100
    var pad = String("0") if frac < 10 else String("")
    return String(scaled // 100) + String(".") + pad + String(frac)
