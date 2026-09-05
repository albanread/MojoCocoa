# 6. What to understand

Eight things about this example are not obvious from playing it.

## 1. The example's answer is "no", and that is the deliverable

It would have been easy to write a GPU Othello and present it as a success.
The example instead ships alpha-beta on the CPU, measures it at 81 µs, and
says that moving it would be slower. From the source:

> *Moving that to a GPU would make it slower, and saying otherwise would be a
> demo rather than an argument.*

The one place the GPU *does* help is genuinely narrow: uniform, stateless,
register-resident Monte-Carlo playouts. Everything else about a board game
resists the hardware. If you take one thing away, take the shape of the test
rather than the verdict — *independent, register-sized, uniform control flow*
is the question to ask of any workload.

## 2. The bitboard is load-bearing, not a flourish

Two `UInt64`s instead of Norvig's 100-element array is not a speed tweak. It
is the reason a GPU thread can hold an entire game:

> *a thread that plays a whole game needs two registers for the board, and
> every thread executes the same instructions regardless of what its game
> looks like.*

With an array board, each of forty thousand threads would need its own 100
bytes in memory, and the workload whose entire justification is *"it touches
no memory"* would touch four megabytes of it per dispatch. The representation
is what makes the argument true.

## 3. `legal_moves` has no data-dependent loop

```mojo
for dir in range(8):
    var run = shift(own, dir) & opp
    for _ in range(5):
        run |= shift(run, dir) & opp
```

Eight, then five. Both constants, derived from the geometry: a line of eight
squares holds at most six discs between its ends. **No branch in the whole
function depends on what is on the board.**

On a CPU that is merely nice. In a warp of threads playing forty thousand
different games, it is the difference between the algorithm working and being
pointless — every thread runs the identical instruction sequence, and only the
bits differ.

## 4. Every thread must have its own dice, and the bug has no symptom

```mojo
seed ^ (UInt64(idx) * 0x9E3779B97F4A7C15)
```

> *Mixing the index in avoids every thread replaying the same game, which is
> the only way this can be wrong and still look plausible.*

Share a seed across threads and all 4,096 playouts of a move are the *same
game*. The counts still come back. The player still picks a move. It picks it
from a sample of size one, disguised as a sample of size 4,096, and no
diagnostic anywhere will tell you.

## 5. The reduction is on the CPU, and that is the right call

Each thread writes one `Int32` to its own slot. Nothing is summed on the
device:

> *an atomic per playout would serialise exactly the thing that is supposed to
> be parallel, and the reduction is 4096 additions per move on a CPU that is
> idle anyway.*

Forty thousand atomics onto a handful of addresses would serialise the
workload whose only virtue is that it does not serialise. A proper tree
reduction would work and would cost shared memory, barriers and a second
dispatch — to save a few thousand additions on a CPU that is blocked on
`synchronize` anyway.

## 6. Two ways to compute the same function are not the same to a compiler

```mojo
return Int(b > w) * 2 - Int(b != w)
```

The obvious `if b > w: 1 elif w > b: -1 else: 0` is folded into `llvm.scmp`,
which the Metal backend cannot lower — so the kernel fails to link with a
message naming an intrinsic and nothing else. And the obvious workaround,
`Int(b > w) - Int(w > b)`, is folded too: it is the *canonical shape* the
optimiser looks for.

Two lessons. A link error naming an LLVM intrinsic is usually a lowering gap,
not your bug. And writing an idiom out by hand can hand the optimiser exactly
the pattern you were trying to avoid.

## 7. `let` binds to a place, and the failure is invisible

```mojo
let clicked = g_click()[]   # a live view of the global, not a snapshot
if clicked != 0:
    g_click()[] = 0         # clicked is now 0
    let m = bit(clicked - 1)  # bit(-1)
```

The handler fires, the coordinates are right, the square is legal, and the
move vanishes one line later. Read the value **out** of a global before
clearing it — test it directly, derive what you need, then reset.

## 8. Speed bought strength, not just speed

The 40× is the headline and the least interesting number here. What it
actually bought is a *different player*:

```
Master (GPU playouts)  6 - 0  Advanced (alpha-beta, 4 ply)
```

Six games, margins of 6 to 26 discs, all played in half a second. A level that
would have stalled for most of a second per move can now answer immediately,
so it can afford to be the strongest thing in the app. That crude-but-plentiful
beats sophisticated-but-shallow here is a real result — and
[chapter 7](07-mcts.md) is what happened when we tried to have both.

## A short list of things that will bite

| If you change… | …this happens |
|:---|:---|
| the seed to be shared across threads | 4,096 identical games, reported as 4,096 samples |
| the thread layout to `idx % move_count` | a warp explores several different games at once |
| the inner `range(5)` to a while-until-done | data-dependent iteration; the warp diverges |
| the reduction into the kernel as atomics | serialises the one part that was parallel |
| `Int(b>w)*2 - Int(b!=w)` back to an `if` | the kernel stops linking, citing `llvm.scmp` |
| `var` to `let` around a global you clear | the value evaporates, with no symptom |
| a pass to consume depth in `negamax` | the search horizon burns on forced sequences |
| the terminal score to use the table | positions won on discs are evaluated as losses |

## Controls

| | |
|:---|:---|
| **click** | play a disc — legal squares are dotted |
| **N** | new game |
| **B / I / A / M** | Beginner, Intermediate, Advanced, Master |
| **Q** or **Esc** | quit |

The status bar shows the disc count, the level, and the time the computer's
last move took — which is where every number in
[chapter 2](02-the-argument.md) comes from.
