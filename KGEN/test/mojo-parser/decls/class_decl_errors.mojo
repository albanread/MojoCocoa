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


# Fields belong in a box reached through one hidden ivar, not in the class type
# -- which is one pointer and nothing else. Accepting one would not fail; it
# would quietly make `Boxed` an Int rather than something pointing at one,
# which is why this is diagnosed rather than deferred.
class Boxed(NSObject):
    # expected-error @+1 {{class fields are not implemented yet: 'count'}}
    var count: Int


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
