# ===----------------------------------------------------------------------=== #
# Copyright (c) 2026, Modular Inc. All rights reserved.
#
# Licensed under the Apache License v2.0 with LLVM Exceptions:
# https://llvm.org/LICENSE.txt
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
# ===----------------------------------------------------------------------=== #

# RUN: %parse-mojo-isolated -verify-diagnostics %s

# Diagnostics for `class` -- COCOA_CLASS_DESIGN.md.
#
# A header that does not parse never reaches signature resolution, so these
# fire alone rather than alongside anything from the resolver. That is the
# property being pinned, and it is why these live apart from class_decl.mojo,
# where every class is expected to resolve cleanly.


# A name is required.
# expected-error @+1 {{expected class name}}
class:
    pass


# An Objective-C class is one runtime entity with one name, so there is nothing
# for a compile-time parameter to specialise. Diagnosed rather than quietly
# accepted with struct meaning.
# expected-error @+1 {{classes do not take parameters}}
class Parameterised[T: AnyType]:
    pass


# Bases are names.
# expected-error @+1 {{expected base class or protocol name}}
class BadBase(1 + 2):
    pass


# expected-error @+1 {{expected name after '.'}}
class BadQualified(foundation.):
    pass


# expected-error @+1 {{expected ')' in class base list}}
class Unclosed(NSView:
    pass


# expected-error @+1 {{expected ':' in class definition}}
class NoColon(NSView)
    pass


# Like a struct's parameter list, a base list has to begin on the name's own
# line -- otherwise the recorded source extent stops at the bracket and the
# real failure surfaces much later, somewhere unrelated.
# expected-error @+2 {{base class list may not appear at the start of the line}}
class LineBreak
(NSView):
    pass


# Classes are top level, for the same reasons structs are.
struct Host:
    # expected-error @+1 {{nested class not supported here}}
    class Nested:
        pass


trait SomeTrait:
    # expected-error @+1 {{nested class in a trait not supported here}}
    class NestedInTrait:
        pass


def some_function():
    # expected-error @+1 {{class inside a function not supported here}}
    class NestedInFunction:
        pass


# Fields work now -- the box, COCOA_CLASS_DESIGN.md sprint 3 -- so the case
# that used to be diagnosed here lives in class_decl.mojo as a positive check.


# The selector is the method name with every `_` turned into `:`, so the colon
# count has to match the arguments. Both directions are diagnosed.
class Selectors(NSObject):
    # A public snake_case name derives a selector nobody wanted. The fix is to
    # rename it, or to prefix it with `_` and make it private.
    # expected-error @+1 {{derives the selector 'my:helper', which takes 1 argument, but the method declares 0 after 'self'}}
    def my_helper(self) -> Int:
        return 1

    # The dangerous direction: forgetting the trailing underscore means this
    # would never override `drawRect:` at all, and nothing would say so.
    # expected-error @+1 {{derives the selector 'drawRect', which takes 0 arguments, but the method declares 1 after 'self'}}
    def drawRect(self, dirty: Int):
        pass


# A superclass the runtime has never heard of. A typo here does not fail at
# runtime, it produces a root class and a window that never appears.
# expected-error @+1 {{the Objective-C runtime has no class 'NSVeiw' to inherit from}}
class Typo(NSVeiw):
    pass


# The SDK's idea of a selector's shape is the only one that counts, because
# the runtime is what sends the message. Disagreeing with it is diagnosed in
# both directions -- result and argument.
class Disagrees(NSView):
    # expected-error @+1 {{the SDK declares 'tag' with a result of 'q', but this method declares 'B'}}
    def tag(self) -> Bool:
        return True

    # expected-error @+1 {{the SDK declares 'mouseDown:' with argument 1 of '@', but this method declares 'B'}}
    def mouseDown_(self, event: Bool):
        pass



# A method the compiler cannot give a trampoline is a compile ERROR, not a
# silent omission. This is the whole point: both of these used to return
# quietly, and the class would register without the method -- a window that
# does not respond to a message the framework definitely sent, with nothing
# anywhere saying why. Refusing out loud costs one diagnostic and saves an
# afternoon.
@fieldwise_init
struct InMemory(Copyable, Movable):
    var a: Int
    var b: Int
    var c: Int


class Refused(NSView):
    # Mojo passes a memory-only value by reference, so the result never
    # reaches the C ABI as a value at all -- the fix is register-passability,
    # which is exactly what std/objc/geometry.mojo does for CGRect.
    # expected-error @+1 {{'selectedRange' returns a type Mojo passes in memory}}
    def selectedRange(self) -> InMemory:
        return InMemory(0, 0, 0)


# A class-typed argument is an id on the wire, and turning one back into a
# class value needs the receiver's box conversion, which the argument path
# does not have yet. Say that, rather than vanishing.
class Handler(NSView):
    pass


class TakesAClass(NSView):
    # expected-error @+1 {{takes argument 1 as the Objective-C class 'Handler', but the runtime sends an 'id'}}
    def mouseDown_(self, other: Handler):
        pass


# `@objc` overrides the naming rules, not the checking. A selector whose colon
# count disagrees with the arguments registers and then never receives
# anything -- the exact failure the derived-selector check exists to prevent,
# so an overridden selector goes through the very same gate.
#
# One class per case: the first error in a class stops its later methods from
# reaching decorator processing, which would hide the rest.
class ColonCount(NSView):
    # expected-error @+2 {{@objc selector 'setThing:' takes 1 argument, but the method declares 0 after 'self'}}
    @objc("setThing:")
    def thing(self) -> Bool:
        return True


class NotAString(NSView):
    # expected-error @+1 {{@objc requires a string literal}}
    @objc(42)
    # expected-error @+1 {{the SDK declares 'other' with a result of '@'}}
    def other(self) -> Bool:
        return True


class TooManyArgs(NSView):
    # expected-error @+1 {{@objc takes exactly one argument: the selector, as a string}}
    @objc("a", "b")
    # No second diagnostic: with the override rejected, `two` falls back to
    # the derived selector, which is a perfectly good one.
    def two(self) -> Bool:
        return True


# On a type, @objc names the class the runtime will register, which only means
# something for a `class`.
# expected-error @+1 {{@objc names an Objective-C class, so it applies to 'class', not to 'struct'}}
@objc("NotAClass")
struct PlainStruct:
    var x: Int


# A field initializer is a `class` thing. A struct's initial values belong in
# its `__init__`, where Mojo checks that every field is set exactly once; a
# class has no such place, because its `__init__` is the compiler's, which is
# the whole reason the declaration is allowed to say it.
struct StructWithInit(Copyable, Movable):
    # expected-error @+1 {{a struct field cannot have an initializer here; set it in '__init__'}}
    var x: Int = 3
