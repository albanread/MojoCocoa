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

# RUN: %parse-mojo-isolated %s | FileCheck %s

# `class` declares an Objective-C class -- COCOA_CLASS_DESIGN.md.
#
# Sprint 2 resolves one to a type. What the IR should show, and what these
# checks pin, is the design's central claim about representation: a class is a
# **register-passable** struct -- a pointer, not a value -- carrying the
# Objective-C names it was declared against. It is deliberately NOT a separate
# op; see the sprint 1 decision in the design document.


# CHECK-DAG: lit.struct.decl @Bare({{.*}}) register_passable attributes {objcClass
class Bare:
    pass


# The bases survive parsing in source order: superclass first, protocols after.
# They are strings, because they name things the Objective-C runtime resolves
# and not Mojo traits -- reading them as traits would report `NSView` as an
# undefined trait, which is a lie about a correct line.
# CHECK-DAG: lit.struct.decl @WithSuper({{.*}}) register_passable attributes {objcBases = ["NSObject"], objcClass
class WithSuper(NSObject):
    pass


# And the framework that declares the superclass, which registration needs
# before it can ask the runtime anything: objc_getClass("NSView") is nil until
# AppKit is loaded, and building against a nil superclass silently produces a
# root class. Only BridgeSupport knows the attribution.
# CHECK-DAG: lit.struct.decl @GridView({{.*}}) register_passable attributes {objcBases = ["NSView", "NSTextInputClient", "NSDraggingDestination"], objcClass, objcFrameworks = ["AppKit"]
class GridView(NSView, NSTextInputClient, NSDraggingDestination):
    pass


# A qualified name is kept whole rather than read as attribute access.
# CHECK-DAG: lit.struct.decl @Qualified({{.*}}) register_passable attributes {objcBases = ["foundation.NSObject"], objcClass
class Qualified(foundation.NSObject):
    pass


# An empty base list means the same as writing none at all: no objcBases.
# CHECK-DAG: lit.struct.decl @EmptyBases({{.*}}) register_passable attributes {objcClass
class EmptyBases():
    pass


# A base list wrapped over several lines, with the trailing comma such a list
# is actually written with.
# CHECK-DAG: lit.struct.decl @Multiline({{.*}}) register_passable attributes {objcBases = ["NSView", "NSTextInputClient"], objcClass
class Multiline(
    NSView,
    NSTextInputClient,
):
    pass


# Methods resolve, `self` is the class, and each one carries the selector the
# runtime will dispatch to it by: every `_` in the name is a `:` in the
# selector. Registering them is the rest of sprint 2; deriving the identity
# correctly has to be true first.
# CHECK-DAG: lit.fn @"isFlipped(class_decl::TabBar)"{{.*}}%self: !lit.ref<!TabBar
#
# The encoding beside each is looked up in the SDK database, not derived: the
# runtime is what will send these messages, so its idea of their shape is the
# only one that counts. Note drawRect:'s struct expansion, which is the string
# ide/roast.mojo writes out by hand today.
# CHECK-DAG: objcEncoding = "B16@0:8", objcSelector = "isFlipped"
# CHECK-DAG: objcEncoding = "v48@0:8{CGRect={CGPoint=dd}{CGSize=dd}}16", objcSelector = "drawRect:"
# CHECK-DAG: objcEncoding = "@40@0:8@16q24@32", objcSelector = "outlineView:child:ofItem:"
class TabBar(NSView):
    """A docstring."""

    def isFlipped(self) -> Bool:
        return True

    def drawRect_(self, dirty: Int):
        pass

    def outlineView_child_ofItem_(self, view: Int, index: Int, item: Int) -> Int:
        return 0

    # A leading underscore means the method is Mojo's own and never reaches the
    # runtime -- which is what keeps snake_case helpers legal in a language
    # where snake_case is the norm.
    # CHECK-NOT: objcSelector = "_tab:width"
    def _tab_width(self, total: Int) -> Int:
        return total


# Every class carries the function that will build it in the runtime. Empty so
# far -- COCOA_CLASS_DESIGN.md sprint 2b fills it in -- but synthesized, which
# is what everything after it depends on.
# CHECK-DAG: lit.fn @"__objc_register__()"() -> !kgen.none

# Structs are untouched: still memory-only, still no Objective-C attributes.
# CHECK-DAG: lit.struct.decl @PlainStruct({{.*}}) attributes {sourceName
struct PlainStruct:
    var x: Int
