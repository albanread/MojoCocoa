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

# A stub of std.objc, for parser tests only.
#
# `class` synthesizes a registration function that constructs an
# ObjCClassRegistrar (COCOA_CLASS_DESIGN.md), so every parser test containing
# a class needs this module to exist. Only the shape the compiler emits calls
# to is here; the real one is in mojo/stdlib/std/objc, and nothing in these
# tests runs.


struct ObjCClass:
    var _cls: Int

    def __init__(out self, cls: Int):
        self._cls = cls


struct _StubPointer(TrivialRegisterPassable):
    var _mlir_value: __mlir_type.`!kgen.pointer<i8>`

    def __init__(out self):
        self._mlir_value = __mlir_op.`pop.pointer.bitcast`[
            _type = __mlir_type.`!kgen.pointer<i8>`
        ](__mlir_op.`lit.ref.to_pointer`(__get_mvalue_as_litref(self)))


struct ObjCClassRegistrar:
    var _cls: Int
    var _ok: Bool
    var _existing: Bool

    def __init__(
        out self,
        name: StringSlice,
        superclass: StringSlice,
        frameworks: StringSlice = "",
    ):
        self._cls = 0
        self._ok = False
        self._existing = False

    def __init__(
        out self,
        name: StringSlice,
        superclass: StringSlice,
        frameworks: StringSlice,
        ensure_super: fn () -> None,
    ):
        self._cls = 0
        self._ok = False
        self._existing = False

    def add_method[
        F: AnyType
    ](mut self, selector: StringSlice, encoding: StringSlice, imp: F) -> Bool:
        return False

    def add_class_method[
        F: AnyType
    ](mut self, selector: StringSlice, encoding: StringSlice, imp: F) -> Bool:
        return False

    def add_protocol(mut self, name: StringSlice) -> Bool:
        return False

    def add_box(
        mut self, size: __mlir_type.index, class_name: StringSlice
    ) -> Bool:
        return False

    # `witness` is never read: it exists so the box's type reaches a
    # parametric call the compiler cannot spell an explicit parameter for.
    def add_dealloc[T: Deinitable](mut self, ref witness: T) -> Bool:
        return False

    def box_offset_of(mut self, class_name: StringSlice) -> Int:
        return 0

    # The compiler reaches through the result for `_mlir_value` -- it needs an
    # address it can offset and bitcast -- so the stub has to be pointer
    # SHAPED, not merely pointer named. std.memory is not importable here.
    def box_of(
        mut self, id: Int, size: __mlir_type.index, class_name: StringSlice
    ) -> _StubPointer:
        return _StubPointer()

    def register(mut self) -> ObjCClass:
        return ObjCClass(0)

    def register_and_instantiate(mut self) -> Int:
        return 0
