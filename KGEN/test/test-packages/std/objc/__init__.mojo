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

    def add_method[
        F: AnyType
    ](mut self, selector: StringSlice, encoding: StringSlice, imp: F) -> Bool:
        return False

    def add_protocol(mut self, name: StringSlice) -> Bool:
        return False

    def register(mut self) -> ObjCClass:
        return ObjCClass(0)

    def register_and_instantiate(mut self) -> Int:
        return 0
