# Animals

Dog barks, cat meows — the first example in every book about objects. It is
here because in this dialect it is **two** examples, and the difference
between them is the thing worth learning.

    cocoamojo --build examples/animals/main.mojo -o /tmp/animals
    /tmp/animals

## Two kinds of polymorphism

| | `trait` + `struct` | `class` |
|:---|:---|:---|
| resolved | at compile time | at run time |
| dispatch | direct call, inlinable | `objc_msgSend`, by selector |
| a mixed collection | needs more machinery | is what it is for |
| what it produces | Mojo code | a real Objective-C class |
| cost, measured | the loop is deleted | ~1.4 ns per call |

Neither is the right answer. The question a program has to answer is whether
it knows its types at the call site, and that is a question about the program
rather than about taste.

## The compiler's kind

```mojo
trait Speaks:
    fn sound(self) -> StaticString: ...
    fn legs(self) -> Int: ...


@fieldwise_init
struct Dog(Speaks, Copyable, Movable):
    fn sound(self) -> StaticString:
        return "Woof"
    fn legs(self) -> Int:
        return 4


fn announce[T: Speaks](name: StaticString, a: T):
    print("   ", name, "says", a.sound(), "and stands on", a.legs(), "legs")
```

`announce` is compiled once for each concrete type that reaches it, with the
call already resolved. There is no lookup, and `Dog`'s sound is not *found* —
it is simply what the code says.

The cost of that is visible in the output: three separate copies of a function
that looks like one, and no way to put a `Dog` and a `Cat` in the same list,
because a list needs one type and they are two.

## The runtime's kind

```mojo
class Creature:
    def sound(self) -> ObjCObject:
        return nsstring("Woof")
    def legs(self) -> Int:
        return 4


class Hound(Creature):
    def sound(self) -> ObjCObject:
        return nsstring("Bay")
```

`class` declares a real Objective-C class, registered with the runtime — and
`class Hound(Creature)` makes `Hound` a real subclass. The program does not
assert that; it asks:

```text
the hierarchy, according to the Objective-C runtime:
    Creature -> NSObject
    Hound -> Creature
    Tabby -> Creature
```

So a mixed collection works, and each member answers for itself:

```mojo
for i in range(len(pen)):
    let a = pen[i]
    print(String("    ") + class_name(a),
          "says", ns_to_string(send[ObjCObject, "sound"](a)),
          "and stands on", send[Int, "legs"](a), "legs")
```

`Hound` overrides `sound` and never mentions `legs` — and the 4 it reports
comes from `Creature`, by ordinary message dispatch.

## The thing that will catch you

**Inheritance is real in the runtime and is not on the Mojo side.**

```mojo
var hound = Hound()
hound.sound()   # fine -- Hound declares it
hound.legs()    # error: 'Hound' value has no attribute 'legs'
```

A class value's method surface is what *that* class declares, not what its
superclass did. The method is still there and still reachable — send the
selector:

```mojo
send[Int, "legs"](ObjCObject(hound.__objc_id))     # 4, from Creature
```

Which is worth knowing before you write a base class with ten helpers on it
and try to call them from a subclass.

Note that `send` works here even though `legs` is a selector no SDK has ever
heard of. When the database does not know a selector, the encoding is derived
from the signature — the same rule that lets a `class` declare
`buttonClicked:` without writing `"v@:@"`.

## What the measurement says

```text
what the lookup costs, over 3000000 calls of the same method:
    trait, resolved at compile time   0.00 ns per call
    class, found by selector          1.39 ns per call
```

The first number is zero **because the loop is gone**. The compiler knew the
type, inlined the method, saw that the sum was a constant, and deleted the
whole thing — which is what resolving at compile time is for, and why the two
numbers cannot be compared directly.

The second is a real `objc_msgSend` every time, and it is under two
nanoseconds. That is the useful figure. Dispatch is not what makes a program
slow, and choosing a design to avoid 1.4 ns is choosing the wrong thing.

## A compiler wart, noted

Subclassing a **user-declared** class produces a spurious warning:

```text
examples/animals/main.mojo:108:7: warning: assignment to 'base' was never used
class Hound(Creature):
```

It is harmless — the class registers correctly and the hierarchy is right, as
the program's own output shows. It does not appear when the superclass is an
SDK class (`class LifeView(NSView)` and the rest are silent), so it is
specific to the user-superclass path in class lowering.
