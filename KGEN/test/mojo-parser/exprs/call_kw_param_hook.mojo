# ===----------------------------------------------------------------------=== #
# Copyright (c) 2026, Modular Inc. All rights reserved.
#
# Licensed under the Apache License v2.0 with LLVM Exceptions:
# https://llvm.org/LICENSE.txt
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
# WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
# License for the specific language governing permissions and limitations
# under the License.
# ===----------------------------------------------------------------------=== #

# RUN: %parse-mojo-isolated %s | FileCheck %s

# `__call_kw_param__` -- keyword argument names as parameters at a call
# site, the call-site sibling of `__getattr_param__`. A call whose keyword
# operands cannot bind to declared parameter names re-dispatches onto this
# hook of the callee's type: the names arrive as StringLiteral parameters in
# source order, and every operand passes positionally with its keyword-ness
# stripped. cocoa_improvements_design.md, Sprint P1.
#
# The Objective-C tier rides this hook (`Obj["NSWindow"](...).setFrame(rect,
# display=True)` -- the label and the method name are assembled into a
# selector inside the metadata database, which is why the names must be
# parameters). This test pins the LANGUAGE mechanism with no database in
# sight, which is also what makes it isolated.

struct Recorder:
    """Hands back the label it was called with, so the check can see the
    name arrive as a parameter while the values stay positional."""
    def __init__(out self):
        pass

    def __call_kw_param__[
        label: StringLiteral
    ](self, first: Int, second: Int) -> StaticString:
        return label

    def __call_kw_param__[
        label: StringLiteral, second_label: StringLiteral
    ](self, first: Int, second: Int, third: Int) -> StaticString:
        return label

    def __call__(self, plain: Int) -> StaticString:
        return "no hook"


def take_named(plain: Int, other: Int) -> Int:
    return plain * 100 + other


def one_label(r: Recorder) -> StaticString:
    var got = r(3, by=4)
    return got

def two_labels(r: Recorder) -> StaticString:
    var got = r(1, slowly=2, carefully=3)
    return got

def declared_names_stay(r: Recorder) -> Int:
    # A callee that DECLARES matching parameter names keeps the ordinary
    # path: keyword arguments bind to them as they always did, and the hook
    # is never consulted.
    return take_named(plain=2, other=3)

def positional_stays(r: Recorder) -> StaticString:
    # No keywords, no hook: the type's own __call__ serves the call.
    return r(11)

# The keyword name arrives as a PARAMETER (`<:string "by"` before the call's
# operand list) and the values pass positionally -- the callee is
# __call_kw_param__, never __call__.
# CHECK: lit.call tail @{{.*}}@"__call_kw_param__{{.*}}<:string "by"
# CHECK-SAME: (%r, %{{[0-9]+}}, %{{[0-9]+}})
# Two labels, in source order, values still positional.
# CHECK: lit.call tail @{{.*}}@"__call_kw_param__{{.*}}<:string "slowly", :string "carefully"
# CHECK-SAME: (%r, %{{[0-9]+}}, %{{[0-9]+}}, %{{[0-9]+}})
# A callee with declared parameter names is untouched.
# CHECK: lit.call tail @{{.*}}take_named
# CHECK-NOT: __call_kw_param__
# A positional call is untouched too: the type's own __call__ serves it.
# CHECK: lit.call tail @{{.*}}@Recorder::@"__call__{{.*}}
