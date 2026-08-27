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
# A class is a MEMORY-ONLY struct: its first field is the id, the author's
# fields follow (the box, stored inline in the object's one ivar), and the C
# ABI's registers-only view of the receiver exists at exactly one place, the
# synthesized trampoline. It is deliberately NOT a separate op; see the
# sprint 1 decision in the design document.


# A class holds exactly one thing: the pointer to the Objective-C object. The
# fields an author declares go in a box behind it -- sprint 3.
# CHECK-DAG: lit.struct.field __objc_id
# CHECK-DAG: lit.struct.decl @Bare({{.*}}) attributes {objcClass
class Bare:
    pass


# The bases survive parsing in source order: superclass first, protocols after.
# They are strings, because they name things the Objective-C runtime resolves
# and not Mojo traits -- reading them as traits would report `NSView` as an
# undefined trait, which is a lie about a correct line.
# CHECK-DAG: lit.struct.decl @WithSuper({{.*}}) attributes {objcBases = ["NSObject"], objcClass
class WithSuper(NSObject):
    pass


# And the framework that declares the superclass, which registration needs
# before it can ask the runtime anything: objc_getClass("NSView") is nil until
# AppKit is loaded, and building against a nil superclass silently produces a
# root class. Only BridgeSupport knows the attribution.
# CHECK-DAG: lit.struct.decl @GridView({{.*}}) attributes {objcBases = ["NSView", "NSTextInputClient", "NSDraggingDestination"], objcClass, objcFrameworks = ["AppKit"]
class GridView(NSView, NSTextInputClient, NSDraggingDestination):
    pass


# Every class carries a synthesized initializer that builds it in the runtime
# on the way to making an instance, driving std.objc's ObjCClassRegistrar with
# the three things only the compiler knows: the class name, the superclass, and
# the frameworks that must be loaded before the superclass resolves at all.
# Registering is idempotent, so the second instance costs one objc_getClass.
# CHECK-DAG: lit.var.decl "registrar" var : !lit.ref<!ObjCClassRegistrar
# CHECK-DAG: kgen.param.constant: !lit.struct<#StringLiteral <:string "GridView">>
# CHECK-DAG: kgen.param.constant: !lit.struct<#StringLiteral <:string "AppKit">>
# CHECK-DAG: ObjCClassRegistrar::@"__init__
# CHECK-DAG: ObjCClassRegistrar::@"add_protocol
# CHECK-DAG: ObjCClassRegistrar::@"register_and_instantiate


# A qualified name is kept whole rather than read as attribute access.
# CHECK-DAG: lit.struct.decl @Qualified({{.*}}) attributes {objcBases = ["foundation.NSObject"], objcClass
class Qualified(foundation.NSObject):
    pass


# An empty base list means the same as writing none at all: no objcBases.
# CHECK-DAG: lit.struct.decl @EmptyBases({{.*}}) attributes {objcClass
class EmptyBases():
    pass


# A base list wrapped over several lines, with the trailing comma such a list
# is actually written with.
# CHECK-DAG: lit.struct.decl @Multiline({{.*}}) attributes {objcBases = ["NSView", "NSTextInputClient"], objcClass
class Multiline(
    NSView,
    NSTextInputClient,
):
    pass


# Methods resolve, `self` is the class, and each one carries the selector the
# runtime will dispatch to it by: every `_` in the name is a `:` in the
# selector. Registering them is the rest of sprint 2; deriving the identity
# correctly has to be true first.
# Registers at the boundary, memory inside. The METHOD takes `self` as a
# memory borrow like any non-trivial type -- inside Mojo a borrowed class has
# to be addressable, because `self.__objc_id` is a field projection. The
# TRAMPOLINE is where the C ABI's registers-only view lives: it receives the
# receiver by value in x0 and stores it to a local before calling in. The
# store is the conversion between the two calling conventions.
# CHECK-DAG: lit.fn @"isFlipped(class_decl::TabBar)"[{{.*}}%self: !lit.ref<!TabBar
# CHECK-DAG: lit.fn @"__objc_imp_isFlipped({{.*}}(%self: !TabBar, %_cmd: !Int{{.*}}) cabi
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

    # CHECK-DAG: ObjCClassRegistrar::@"add_method
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


# A class with fields of its own: the box. The registration reserves the one
# ivar with the class's own sizeof -- an expression the elaborator resolves
# after layout -- caches where the runtime put it, and every trampoline moves
# the incoming id along by that offset before calling in.
# CHECK-DAG: lit.struct.decl @Boxed({{.*}}) attributes {objcBases = ["NSObject"], objcClass
# CHECK-DAG: ObjCClassRegistrar::@"add_box
# CHECK-DAG: get_sizeof
# CHECK-DAG: vega.objc.boxoffset/Boxed
# CHECK-DAG: pop.offset
#
# The receiver invariant, pinned after it was violated once at real cost:
# at the IMP boundary the receiver is a FOREIGN ABI VALUE -- a raw pointer --
# and becomes a Ref<Self> only after the ivar offset is added. Modelling it as
# `!lit.ref<!Boxed> read_mem` materialised a stack copy of Self at the
# argument boundary, and every box write landed in dead stack while the
# method cheerfully returned its answers.
# CHECK-DAG: lit.fn @"__objc_imp_isProxy(!kgen.pointer<i8>{{.*}}(%self: !kgen.pointer<i8>, %_cmd: !Int
# CHECK-NOT: __objc_imp_isProxy{{.*}}!lit.ref<!Boxed
class Boxed(NSObject):
    var count: Int

    def isProxy(self) -> Bool:
        return self.count > 0


# Structs are untouched: still memory-only, still no Objective-C attributes.
# CHECK-DAG: lit.struct.decl @PlainStruct({{.*}}) attributes {sourceName
struct PlainStruct:
    var x: Int
