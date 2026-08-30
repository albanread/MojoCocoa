# Hybrid UCT + GPU playouts — unfinished

A tree search on the CPU that farms its evaluations out to the GPU in
batches. **It does not work yet**: it loses to the flat Monte-Carlo player
in `examples/othello/` 0–6, and more search makes it worse. It is here
rather than in `examples/` because the shipped example should be a thing
that works, and because the four bugs already found are worth keeping.

    ./dist/CocoaMojo/bin/cocoamojo --build <driver>.mojo \
        -I examples/othello -I spikes/othello-mcts -o /tmp/duel

## The idea

`examples/othello/` shows where a GPU helps a board game: alpha-beta does
not want one, uniform Monte-Carlo playouts do. But flat Monte-Carlo is the
crudest member of its family — it spreads samples evenly and forgets
everything between moves.

UCT is the version that made the method famous, and its selectivity is
exactly what makes it GPU-hostile: the tree is shared mutable state, and
what to sample next depends on what the last sample found. The same tension
that rules out alpha-beta.

So split the work where it actually divides:

- the **CPU** owns the tree — selection, expansion, backpropagation:
  sequential, branchy, tiny
- the **GPU** answers one question — "how good is this position?" — for 64
  positions at once, by playing each out many times

A kernel launch costs the same whether it evaluates one leaf or sixty-four,
so the tree nominates a batch before each dispatch. That is leaf
parallelisation; virtual loss is what stops all 64 nominations picking the
same node.

## What was wrong, and is now fixed

Four real bugs, each of which made it play badly in a different way:

1. **The descent never stopped.** The "is this node newly nominated?" test
   ran *before* the counter it reads was incremented, so it never fired.
   Every selection ran to a finished game, expanding the whole line: 60
   selections built 7,256 nodes instead of 129, and every evaluation was of
   a position whose result was already decided.

2. **Virtual loss in the wrong units.** `pending` counted nominations (1
   each) and was compared against `visits`, which counts playouts (192
   each). The loss was numerically invisible and all 64 leaves in a batch
   followed one path.

3. **Exploration scaled to samples, not decisions.** UCT's
   `sqrt(log N / n)` is written for a count of decisions. Counting playouts
   makes it about `sqrt(PER_LEAF)` too small; exploration vanished and the
   search went greedy, putting 89% of its samples on one move in a balanced
   opening.

4. **Root chosen by visit count** when the visit counts were within noise of
   each other. Most-visited is right when the search is long enough for the
   best move to pull clearly ahead; it is not right at a few thousand
   nominations.

After all four the search *looks* correct: visits spread 66k–78k over four
near-equal opening moves, and the means agree with direct sampling to within
0.01.

## What is still wrong

It still loses 0–6, by 8 to 48 discs. And the diagnostic result:

    16 rounds   → loses by 8, 24, 14, 34, 38, 48
    128 rounds  → loses by 48, 44, 40, 30, 32, 54

**More search makes it worse.** A correct search that is merely
under-resourced improves with more simulations. One that degrades is
converging confidently on the wrong quantity, so the remaining defect is in
what gets backed up, not in tuning.

## Where to look next

Instrument a single move end to end: dump the principal variation and check
by hand whether the backed-up value at depth 2–3 matches a direct playout
estimate of that same position. That isolates backup from selection, which
is the split the evidence has not yet cut.

Two things to be suspicious of:

- the mean at a node mixes playouts taken at different depths and under
  different amounts of tree guidance, which is normal for MCTS but makes a
  sign or perspective error very hard to see from the root
- `t_score` is black-positive everywhere and the flip happens once, in
  `uct_child`. That is the right design, and it is also exactly where a
  single misplaced negation would produce this symptom

## Note on the compiler

The tree is parallel arrays in module globals rather than a struct. A
`struct` with ten `List` fields crashes this compiler outright —
`incorrect # of replacement values` out of `DialectConversion` — before any
of this code runs. The globals are the idiom the rest of the example uses
anyway, and one search runs at a time, so there is nothing a struct would
have protected.
