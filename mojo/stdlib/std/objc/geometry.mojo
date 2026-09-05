# ===----------------------------------------------------------------------=== #
# The Cocoa geometry types, declared the way the ABI sees them.
#
# Every one of these is a homogeneous aggregate the C ABI keeps in registers:
# CGPoint and CGSize are two doubles (v0-v1), CGRect is four (v0-v3), NSRange
# is two 64-bit words (x0/x1). Declaring them TrivialRegisterPassable makes
# Mojo agree -- which is not a micro-optimisation but what lets a `class`
# method RETURN one. A memory-only result becomes a by-ref slot, which is not
# how Objective-C returns a struct, so `selectedRange` was impossible to
# implement until these types stopped being memory-only.
#
# Thirteen files used to redeclare CGRect locally, each as `Copyable, Movable`
# and therefore each subtly wrong for that purpose. This is the one copy.
# ===----------------------------------------------------------------------=== #
from std.sys.info import TrivialRegisterPassable


@fieldwise_init
struct CGPoint(TrivialRegisterPassable):
    var x: Float64
    var y: Float64


@fieldwise_init
struct CGSize(TrivialRegisterPassable):
    var width: Float64
    var height: Float64


@fieldwise_init
struct CGRect(TrivialRegisterPassable):
    var origin: CGPoint
    var size: CGSize


@fieldwise_init
struct NSRange(TrivialRegisterPassable):
    """`{_NSRange=QQ}`: location and length, in x0/x1. `NSNotFound` for a
    range that does not exist is `location == NOT_FOUND`."""

    var location: Int
    var length: Int

    comptime NOT_FOUND = 0x7FFFFFFFFFFFFFFF


# ===----------------------------------------------------------------------=== #
# Metal's own geometry.
#
# These are here for the same reason CGRect is: they are SDK struct layouts
# that every program drawing anything has to spell, and a program that spells
# one wrong gets a corrupted call rather than a diagnostic. Before this they
# were copy-pasted into eight files in this tree -- five examples and three
# parts of the game pane -- which is seven chances to get a field order wrong
# and no way to fix it once.
#
# The integer fields are NSUInteger, so they are `Int` here, and an MTLRegion
# is 48 bytes: too large for registers, so it crosses on the stack. That is
# what makes `replaceRegion:` and `getBytes:` work without a shim.
# ===----------------------------------------------------------------------=== #


@fieldwise_init
struct MTLOrigin(Copyable, Movable):
    """`{MTLOrigin=QQQ}`: the corner of a region, in texels."""

    var x: Int
    var y: Int
    var z: Int


@fieldwise_init
struct MTLSize(Copyable, Movable):
    """`{MTLSize=QQQ}`: an extent, in texels. `depth` is 1 for a 2D texture,
    not 0 -- a zero-depth region copies nothing and reports no error."""

    var width: Int
    var height: Int
    var depth: Int


@fieldwise_init
struct MTLRegion(Copyable, Movable):
    """`{MTLRegion={MTLOrigin=QQQ}{MTLSize=QQQ}}`: 48 bytes, by value."""

    var origin: MTLOrigin
    var size: MTLSize


@fieldwise_init
struct MTLClearColor(Copyable, Movable):
    """`{MTLClearColor=dddd}`: four doubles.

    On arm64 that is a homogeneous float aggregate, so it reaches
    `setClearColor:` in v0..v3 the way a CGRect does -- not on the stack,
    despite being the same 32 bytes a CGRect is.
    """

    var red: Float64
    var green: Float64
    var blue: Float64
    var alpha: Float64
