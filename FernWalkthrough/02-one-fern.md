# 2. One fern, one PNG

`fern/` is 289 lines across three files, and it does exactly one thing: run two
million steps of the chaos game and write `fern.png`.

Its structure is deliberate, and the comment says so:

```mojo
# An iterated function system, kept apart from the example that draws it so
# there is a project here with more than one file in it.
```

The split exists partly to demonstrate the IDE's project handling — `main.mojo`
imports from `ifs.mojo` and `png.mojo`, and the build follows the imports from
there.

## Density, not hit-or-miss

The most important decision in the file is not to plot pixels:

```mojo
# Count how many points land in each pixel. Chaos-game pictures are all
# about density -- plotting hit-or-miss throws away most of the picture,
# which is exactly what the old text version was doing.
var hits = List[UInt32](length=W * H, fill=0)
var peak: UInt32 = 0
```

The chaos game visits parts of the fern in proportion to how much fern is
there. The stem gets hammered; the tip of an outer frond gets a handful of
visits in two million steps. Recording a boolean *"was this pixel ever hit?"*
discards all of that, and the result is a flat green silhouette.

Counting hits keeps it. This is the same insight the fractal-flame algorithm is
built on, and [chapter 4](04-the-flame.md) is where it becomes atomic adds in
a GPU buffer.

## And a log scale, for the same reason

```mojo
# Density to colour, on a log scale: linear brightness would leave the
# fronds invisible next to the stem.
var scale = 1.0 / log(Float64(peak) + 1.0)
```

Having kept the density, you cannot display it linearly. The busiest pixel gets
thousands of hits and an outer frond gets three, so a linear map paints
everything except the stem black.

`log(h + 1)` normalised by `log(peak + 1)` compresses that range into
something an eye can see, and the `+1` keeps `log(0)` out of it. The program
prints its own busiest pixel so the number is visible:

```mojo
print("plotted", POINTS, "points into", W, "x", H, "-- busiest pixel:", peak)
```

The colour ramp then bends each channel differently:

```mojo
rgb.append(UInt8(24.0 + 200.0 * t * t))       # red:   t squared
rgb.append(UInt8(70.0 + 175.0 * t))           # green: linear
rgb.append(UInt8(38.0 + 150.0 * t * t * t))   # blue:  t cubed
```

Green rises fastest, red next, blue last — so sparse regions are green, dense
regions warm toward white, and the fern is lit by its own density.

## A deterministic RNG, on purpose

```mojo
struct Rng(Movable):
    """A small deterministic generator, so the picture is the same every run --
    an example that draws something different each time is hard to check."""
```

xorshift64\*, seeded with a fixed constant. The reasoning is about testability
rather than about randomness: *an example that draws something different each
time is hard to check.* Two runs produce byte-identical PNGs, so a change that
alters the image is visible as a changed file.

Note the contrast with `fernwind/`, which needs the **opposite** property —
each thread and each frame must differ, or the animation strobes. Same
generator, opposite requirement, and both are commented where they are.

## The PNG writer

`png.mojo` is 125 lines and writes a real PNG with no library:

```mojo
# A PNG writer, small enough to read in one sitting.
#
# Truecolour, eight bits a channel, no filtering, and deflate's "stored" mode
# -- which compresses nothing but is a legal deflate stream, so every decoder
# accepts it. The whole format is four chunks and two checksums.
```

The trick worth knowing is **deflate's stored mode**. A PNG's image data must
be a zlib stream, and zlib must contain deflate — but deflate has a block type
meaning *"the following bytes are uncompressed"*. Emit those blocks with the
right headers and you have a valid, entirely legal deflate stream that
compresses nothing.

So the file is larger than it needs to be, and every PNG decoder in the world
opens it. Implementing actual compression would have meant Huffman coding and
LZ77 matching; this is a length, a one's-complement of the length, and the
bytes.

Two checksums, both written out plainly:

```mojo
fn _crc32(data: List[UInt8]) -> UInt32:
    """The CRC PNG puts at the end of every chunk. Bit at a time; the table
    version is faster but this one fits on the screen."""
```

> *the table version is faster but this one fits on the screen*

A 256-entry lookup table would be perhaps eight times quicker, on a function
that runs four times per program. The comment records that the trade was
considered and declined for legibility, which is what stops the next reader
"fixing" it.

`_adler32` is zlib's own checksum, riding at the end of the compressed stream —
a different algorithm at a different layer, and the file has both because the
formats are nested.

## The contrast this example was built for

`fern/` writes its PNG by hand. The [bifurcation
example](../examples/bifurcation) does the opposite — computes in Mojo and
hands the result to Python's matplotlib — and its README puts the two side by
side deliberately:

> *`fern/` in this collection writes a PNG **by hand** — 125 lines to put pixels
> in a file, with no axes, no ticks, no scale and no legend. That is the right
> answer when a bitmap is all you want. This is the other answer, and the two
> sit side by side on purpose.*

A fern needs no axes. A bifurcation diagram needs axes, ticks, a colour map
with a legend, and a second panel sharing an x-axis — thousands of decisions
somebody has already made well. The examples exist as a pair so that neither
answer looks like the only one.
