# The examples, and what each one is for

The distribution ships eighteen example projects, about 13,200 lines of Mojo.
They are not a gallery. Most of them were written to answer a question, and a
few were carried in from elsewhere to prove that they still run. This section
walks through every one and says what it teaches.

It also says when an example teaches **nothing**. Several here are smoke tests
or compatibility checks, and pretending otherwise would waste your time. Each
section ends with a plain verdict, and some of those verdicts are "none".

## The whole set

| Example | Size | The lesson |
|:---|:---|:---|
| [`hello`](01-the-small-ones.md#hello) | 7 lines | **None.** It proves the toolchain works. |
| [`window`](01-the-small-ones.md#window) | 97 lines | The fork's whole thesis, at the smallest size it can be stated |
| [`operators`](01-the-small-ones.md#operators) | 544 lines | **None specific to this fork** — upstream's example, running unmodified |
| [`process`](01-the-small-ones.md#process) | 128 lines | **None specific to this fork** — same, for child processes |
| [`life-python`](01-the-small-ones.md#life-python) | 231 lines | **No code lesson** — the source is upstream's. The Python workflow is the lesson |
| [`vector-add`](02-the-gpu-primers.md#vector-add) | 80 lines | The canonical first kernel: one thread, one element |
| [`grayscale`](02-the-gpu-primers.md#grayscale) | 115 lines | Two-dimensional indexing. Little else beyond `vector-add` |
| [`tiled-matmul`](02-the-gpu-primers.md#tiled-matmul) | 345 lines | Shared memory, and the *second* barrier everyone omits |
| [`life`](03-the-applications.md#life) | 592 lines | A real application, and a program right to use no GPU at all |
| [`mandelbrot`](03-the-applications.md#mandelbrot) | 469 lines | One dispatch per frame, computing *and* colouring, with no shader |
| [`fluid`](03-the-applications.md#fluid) | 873 lines | Thirty-five dependent dispatches per step, where launch cost dominates |
| [`othello`](03-the-applications.md#othello) | 1,000 lines | The honest answer about game trees: one search suits a GPU, one does not |
| [`chip`](04-sound-and-time.md#chip) | 2,176 lines | A Mojo `fn` serving as a C function pointer on a real-time thread — dissected in [chapter 6](06-inside-the-chip.md) |
| [`abcplayer`](04-sound-and-time.md#abcplayer) | 4,650 lines | The largest example: a real parser, and exact timing without floats |
| [`bifurcation`](05-python-used-well.md#bifurcation) | 250 lines | What Python is genuinely better at, measured rather than assumed |
| [`gamepane`](07-the-game-pane.md) | 11,548 lines | A retro game engine as a package: four composited layers, GPU kernels, two chips — [chapter 7](07-the-game-pane.md) |
| [`galaxigans`](07-the-game-pane.md) | 1,545 lines | A Galaga on that engine, ported from BASIC — the game the package exists for |
| [`fern`](../gpu/04-three-ferns.md) | 289 lines | Wide work with no deadline — correctly on the CPU |
| [`ferns`](../gpu/04-three-ferns.md) | 641 lines | A deadline, but work too narrow to move |
| [`fernwind`](../gpu/04-three-ferns.md) | 760 lines | Wide *and* out of time — the crossing, measured at 104× |

The last three have a chapter of their own, [Three ferns](../gpu/04-three-ferns.md),
because together they make an argument no single example can.
<!-- doccrate:keep-together:start -->


## The chapters

| Chapter | What it covers |
|:---|:---|
| [1. The small ones](01-the-small-ones.md) | `hello`, `window`, `operators`, `process`, `life-python` |
| [2. The GPU primers](02-the-gpu-primers.md) | `vector-add`, `grayscale`, `tiled-matmul` |
| [3. The applications](03-the-applications.md) | `life`, `mandelbrot`, `fluid`, `othello` |
| [4. Sound, and time](04-sound-and-time.md) | `chip`, `abcplayer` |
| [6. Inside `chip`](06-inside-the-chip.md) | The synthesiser in full: flow, algorithms, and how to extend it |
| [5. Python, used well](05-python-used-well.md) | `bifurcation`, and what it measures about the boundary |

<!-- doccrate:keep-together:end -->
<!-- doccrate:keep-together:start -->


## Two questions the set keeps asking

Read end to end, the examples circle the same two decisions.

<!-- doccrate:keep-together:end -->

**Where does the work run?** The GPU chapters and the ferns settle this with a
rule worth carrying into the rest of the section:

> Move work to the GPU when it is **wide** and you are **out of time**. Width
> without a deadline does not need one. A deadline with narrow work cannot use
> one.

`life` declines a GPU, `mandelbrot` needs exactly one dispatch, `fluid` needs
thirty-five and discovers that launch cost is the whole problem, and `othello`
splits its own players down the middle. Four different answers, all correct.

**Who calls whom?** A Cocoa application is not a program that runs; it is a
program that is *called*. `window` shows the smallest version — a button that
sends a message to a `class` you declared. `life` shows three such classes.
`chip` shows the case where the caller is not Objective-C at all, but CoreAudio
on a real-time thread, and the thing it wants is a bare C function pointer.
<!-- doccrate:keep-together:start -->


## How to run one

Every example is a folder with a `main.mojo` in it. In Roast, **File ▸ Open
Folder…**, then ⌘R. There is no project file and nothing to generate.

<!-- doccrate:keep-together:end -->

The GPU examples guard themselves with `has_accelerator` and will say so
rather than fail if there is no Metal device. `life-python` and `bifurcation`
need a Python environment; each README explains what and why, and Roast builds
one on demand — only for projects that actually use Python.

    And the largest example is not in this folder: File ▸ Open IDE Source
    opens Roast's own source — the editor you are reading this in, written
    in the language it edits. It has a chapter too:
    Guide, chapter 10.
