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

# RUN: %parse-mojo-isolated %s -verify-diagnostics

# `let` -- the cocoa-mojo revival: an immutable, scope-bound BINDING inside
# a function body (COCOA_LET_DESIGN.md). Two properties are pinned here:
#
#   the binding is a BIND, not a copy -- `let start = i` names i's storage,
#   so a later write through i changes what `start` reads. That is the
#   documented semantics AND the documented trap (AGENTS.md records three
#   real incidents), so the compiler warns at the WRITE -- the line that
#   causes the surprise, naming the binding that will read through it.
#
#   a binding of a VALUE (`i + 1`), or one whose source is never written
#   through afterwards, has no hazard and no warning -- the common case
#   stays silent. Verify mode polices that for free: any diagnostic without
#   an annotation is itself a failure.
#
# The named_global accessor shape (the third trap) needs the real standard
# library and is pinned by the spike suite instead.

def place_bind_and_write() -> Int:
    var i = 7
    let start = i
    # expected-note@above {{'start' bound here}}
    i += 1
    # expected-warning@above {{this write changes what 'start' reads: 'let start' is bound to a place rooted at 'i'}}
    return start

def value_bind_stays_silent() -> Int:
    var i = 7
    let derived = i + 1
    i += 1
    return derived

def untouched_source_stays_silent() -> Int:
    var i = 7
    var other = 9
    let seen = i
    other += 1
    return seen + other

def slot_bind_and_write() -> Int:
    var times = List[Int](2)
    times[0] = 5
    let t = times[0]
    # expected-note@above {{'t' bound here}}
    times[1] = times[0]
    # expected-warning@above {{this write changes what 't' reads: 'let t' is bound to a place rooted at 'times'}}
    return t
