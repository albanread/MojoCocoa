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

# `class` declares an Objective-C class -- COCOA_CLASS_DESIGN.md.
#
# Sprint 1 is the declaration form: the header parses, the name is registered,
# and lowering refuses. Every class below therefore carries the same refusal --
# that IS the pass condition. What is being tested is that the grammar was
# accepted, and -- through the note the refusal carries -- that the header was
# understood to mean what it says.


# The simplest form: no bases, meaning NSObject.
# expected-error @+1 {{class lowering is not implemented yet}}
class Bare:
    pass


# A superclass.
# expected-error @+2 {{class lowering is not implemented yet}}
# expected-note @+1 {{superclass 'NSObject'}}
class WithSuper(NSObject):
    pass


# A superclass and protocols. The first name is the superclass, the rest are
# protocols; this is the shape Roast's GridView needs.
# expected-error @+2 {{class lowering is not implemented yet}}
# expected-note @+1 {{superclass 'NSView', protocols 'NSTextInputClient', 'NSDraggingDestination'}}
class GridView(NSView, NSTextInputClient, NSDraggingDestination):
    pass


# Qualified base names are kept whole rather than being read as attribute
# access on something.
# expected-error @+2 {{class lowering is not implemented yet}}
# expected-note @+1 {{superclass 'foundation.NSObject'}}
class Qualified(foundation.NSObject):
    pass


# An empty base list is not an error; it means the same as writing none.
# expected-error @+1 {{class lowering is not implemented yet}}
class EmptyBases():
    pass


# A body with fields and methods. None of it is resolved in sprint 1 -- the
# body is skipped the same way a struct's is -- but it must not disturb the
# header parse or the statement that follows.
# expected-error @+2 {{class lowering is not implemented yet}}
# expected-note @+1 {{superclass 'NSView'}}
class WithBody(NSView):
    """A docstring."""

    var count: Int
    var name: String = String("untitled")

    def isFlipped(self) -> Bool:
        return True

    def drawRect_(self, dirty: CGRect):
        pass

    fn strict_(self, event: Int):
        pass


# Decorators are accepted before a class the same way they are before a struct.
# @objc is not interpreted yet; sprint 4 makes it mean something.
# expected-error @+3 {{class lowering is not implemented yet}}
# expected-note @+2 {{superclass 'NSView'}}
@objc("RoastTabBarV2")
class Renamed(NSView):
    pass


# A base list spread over several lines with a trailing comma, which is how a
# long protocol list actually gets written.
# expected-error @+2 {{class lowering is not implemented yet}}
# expected-note @+1 {{superclass 'NSView', protocols 'NSTextInputClient'}}
class Multiline(
    NSView,
    NSTextInputClient,
):
    pass


# The declaration after all of the above still parses: refusing a class must
# not derail the file.
struct StillFine:
    var x: Int
