# 3. The board is two integers

`board.mojo` is 121 lines and contains the entire ruleset of Othello. There is
no board class, no square type, no list of pieces. There is this:

```mojo
var black: UInt64
var white: UInt64
```

Bit *i* is row `i // 8`, column `i % 8`, row 0 at the top — and the comment
says why that particular convention:

> *the order the board is drawn in, so the UI never has to flip.*

A small thing, but it is the sort of decision that saves a bug: Fluid has to
flip its mouse coordinates because Cocoa's origin is bottom-left, and every
flip is somewhere a sign can go wrong. Here the drawing code does the flip
once, in one place, and the rules never think about it.

## `shift` — one step, with the edge masked off

```mojo
comptime NOT_LEFT = UInt64(0xFEFEFEFEFEFEFEFE)   # every column but the first
comptime NOT_RIGHT = UInt64(0x7F7F7F7F7F7F7F7F)  # every column but the last

fn shift(b: UInt64, dir: Int) -> UInt64:
    if dir == DIR_E:
        return (b << 1) & NOT_LEFT
    ...
```

Shifting a bitboard east by one moves every disc one column right — including
bit 7, the last column, which lands on bit 8: the *first* column of the next
row. That is a move through the edge of the board.

The mask is the fix, and the docstring names exactly what it replaces:

> *Masking after the shift is what the sentinel border was for.*

Norvig's 100-element array carried 36 sentinel squares so that a walk off the
edge would hit a wall. Here it is two constants, applied after the shift,
costing one AND instruction. North and south need no mask at all — shifting by
8 pushes discs off the end of the word, which is exactly right.

## `legal_moves` — every move at once

```mojo
fn legal_moves(own: UInt64, opp: UInt64) -> UInt64:
    var empty = ~(own | opp)
    var moves = UInt64(0)
    for dir in range(8):
        var run = shift(own, dir) & opp
        for _ in range(5):
            run |= shift(run, dir) & opp
        moves |= shift(run, dir) & empty
    return moves
```

Read it as a sentence. *Start from every square adjacent to one of mine that
holds an opponent disc* (`shift(own, dir) & opp`). *Grow that run along the
direction as long as it keeps hitting opponent discs* (the inner loop).
*Wherever the run's far end is an empty square, that square is a legal move.*

Two details are worth pausing on.

**The five.** The docstring explains it exactly:

> *The run is grown six times because a line of eight squares can hold at most
> six discs between the two ends.*

One initial step plus five in the loop. It is not a loop-until-done — it is a
fixed count derived from the geometry of the board, so there is no data-
dependent iteration count. **Every call executes precisely the same
instructions.** On the CPU that is merely predictable. In a kernel where forty
thousand threads run this in lockstep, it is the difference between the
algorithm working and the algorithm being pointless.

**No branch depends on the position.** `dir` is a loop counter, the inner
count is a constant, and everything else is `&`, `|`, `<<`, `>>`. Nothing in
here asks "what is on this square?" — which is what makes it uniform.

The result is a bitboard, not a list. Every legal move in one word, ready to
be iterated with `x &= x - 1` or counted with `popcount`.

## `flips_for` — and the one place a branch survives

```mojo
fn flips_for(own: UInt64, opp: UInt64, move: UInt64) -> UInt64:
    var flipped = UInt64(0)
    for dir in range(8):
        var run = shift(move, dir) & opp
        for _ in range(5):
            run |= shift(run, dir) & opp
        # The run only counts if one of ours closes it. Anything else -- an
        # empty square, or the edge -- and nothing turns over.
        if (shift(run, dir) & own) != 0:
            flipped |= run
    return flipped
```

Same propagation, run from the *move* rather than from your own discs. The
difference is the test at the end: a run of opponent discs only flips if one
of yours closes it. A run that ends at an empty square, or at the edge, flips
nothing.

That `if` is the only position-dependent branch in the file, and it is
harmless — it is a predicated `|=` that any compiler will turn into a select.

The docstring also states the function's contract in seven words: *"Empty if
the move is not legal."* Which means callers do not need to check legality
separately, and `apply_move` in `main.mojo` uses exactly that:

```mojo
let f = flips_for(own, opp, move)
if f == 0:
    return
```

An illegal click is a move that flips nothing, and it is rejected by the same
code that computes the flips.

## `popcount` — and a deliberate refusal to be clever

```mojo
fn popcount(b: UInt64) -> Int:
    """How many discs. The obvious loop, not the clever one: it runs once per
    move on the CPU and once per finished game on the GPU."""
    var n = 0
    var x = b
    while x != 0:
        x &= x - 1
        n += 1
    return n
```

`x &= x - 1` clears the lowest set bit — Kernighan's trick — so the loop runs
once per disc rather than 64 times.

The docstring is doing something more interesting than describing the code: it
is **justifying the absence of an optimisation**. There is a well-known
branch-free SWAR popcount, and there is a hardware instruction. Neither is
used, because this runs once per move and once per finished game. The comment
records that the trade was considered and declined, which is what stops the
next reader from "fixing" it.

Note that this is the *one* function here with a data-dependent iteration
count — it runs `popcount(b)` times. Inside the kernel it is called only at
the very end of a playout, after roughly sixty moves of uniform work, so the
divergence it introduces is a rounding error.

## Why 121 lines is the headline

The whole ruleset — legality, flipping, passing, counting, the opening
position — is 121 lines with no data structure more complicated than a
`UInt64`. And it is *checked*, which is the part that matters for a move
generator:

```
perft 1 = 4        perft 5 = 1396
perft 2 = 12       perft 6 = 8200
perft 3 = 56       perft 7 = 55092
```

**Perft** is the count of distinct positions reachable in exactly *n* plies.
It is the standard correctness test for a move generator, because these
numbers are published and a generator that is subtly wrong — one direction
masked incorrectly, one edge case in passing — produces a number that is
subtly wrong too, while still looking like it works.

The commit message makes the point:

> *because a move generator that is subtly wrong still looks like it works.*

The whole of `board.mojo` compiles to something a GPU thread can run without
touching memory. That is the property [chapter 2](02-the-argument.md) spends
itself arguing for, and this file is where it is actually earned.
