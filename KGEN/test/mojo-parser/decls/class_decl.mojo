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


# CHECK-DAG: lit.struct.decl @GridView({{.*}}) register_passable attributes {objcBases = ["NSView", "NSTextInputClient", "NSDraggingDestination"], objcClass
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


# Methods resolve, and `self` is the class. Registering them with the runtime
# is the rest of sprint 2; this is the half that has to be true first.
# CHECK-DAG: lit.fn @"isFlipped(class_decl::TabBar)"{{.*}}%self: !lit.ref<!TabBar
class TabBar(NSView):
    """A docstring."""

    def isFlipped(self) -> Bool:
        return True


# Structs are untouched: still memory-only, still no Objective-C attributes.
# CHECK-DAG: lit.struct.decl @PlainStruct({{.*}}) attributes {sourceName
struct PlainStruct:
    var x: Int
