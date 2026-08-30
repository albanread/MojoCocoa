# UCT on the CPU, playouts on the GPU.
#
# The flat player in `ai.mojo` spreads its samples evenly over the root moves
# and throws the results away after each decision. It is the crudest member
# of the Monte-Carlo family and it is on the GPU precisely BECAUSE it is
# crude: uniform sampling has no state, so ten thousand threads never need to
# agree about anything.
#
# UCT is the version that made the method famous. It builds a tree and spends
# its samples where the results look promising, abandoning lines that clearly
# lose -- vastly stronger per playout. And that selectivity is exactly what
# makes it a poor fit for a GPU: the tree is shared mutable state, and what to
# sample next depends on what the last sample found. The same tension that
# rules out alpha-beta.
#
# So the work is split along the line where it actually divides:
#
#   the CPU owns the tree     -- selection, expansion, backpropagation:
#                                sequential, branchy, tiny
#   the GPU answers one thing -- "how good is this position?", for sixty-four
#                                positions at once, by playing them out
#
# A kernel launch costs the same whether it evaluates one leaf or sixty-four,
# so the tree is asked to nominate a batch of leaves before each dispatch.
# That is leaf parallelisation, and the virtual-loss trick below is what stops
# all sixty-four nominations being the same node.
#
# The tree is parallel arrays rather than nodes with pointers: no ownership
# question, no allocation per node, and a whole search stays in cache.

from std.memory import Pointer, MutAnyOrigin
from std.objc import named_global
from max.gpu.host import DeviceContext

from board import legal_moves, flips_for, popcount
from std.gpu import global_idx
from ai import lowest, next_random, playout, GPU_BLOCK

comptime BATCH = 64            # leaves nominated per dispatch
comptime PER_LEAF = 32         # playouts each one gets
comptime EXPLORE = 1.2         # the C in the UCT formula


# The tree lives in module globals rather than a struct. A struct with ten
# List fields crashes this compiler outright -- "incorrect # of replacement
# values" out of DialectConversion, before any of this code runs -- and the
# globals are the idiom the rest of the example already uses. One search runs
# at a time, so there is nothing a struct would have protected.
comptime t_black = named_global["mcts.black", List[UInt64]]
comptime t_white = named_global["mcts.white", List[UInt64]]
comptime t_turn = named_global["mcts.turn", List[Int]]
comptime t_parent = named_global["mcts.parent", List[Int]]
comptime t_move = named_global["mcts.move", List[UInt64]]
comptime t_first = named_global["mcts.first", List[Int]]
comptime t_count = named_global["mcts.count", List[Int]]
comptime t_visits = named_global["mcts.visits", List[Int]]
comptime t_score = named_global["mcts.score", List[Int]]
comptime t_pending = named_global["mcts.pending", List[Int]]


def tree_add(black: UInt64, white: UInt64, black_turn: Bool,
             parent: Int, move: UInt64) -> Int:
    t_black()[].append(black)
    t_white()[].append(white)
    t_turn()[].append(1 if black_turn else 0)
    t_parent()[].append(parent)
    t_move()[].append(move)
    t_first()[].append(-1)
    t_count()[].append(0)
    t_visits()[].append(0)
    t_score()[].append(0)
    t_pending()[].append(0)
    return len(t_black()[]) - 1


def tree_reset(black: UInt64, white: UInt64, black_turn: Bool):
    t_black()[] = List[UInt64]()
    t_white()[] = List[UInt64]()
    t_turn()[] = List[Int]()
    t_parent()[] = List[Int]()
    t_move()[] = List[UInt64]()
    t_first()[] = List[Int]()
    t_count()[] = List[Int]()
    t_visits()[] = List[Int]()
    t_score()[] = List[Int]()
    t_pending()[] = List[Int]()
    _ = tree_add(black, white, black_turn, -1, UInt64(0))


def tree_expand(node: Int):
    """Give a node every child it has, once.

    Expanding fully rather than one child at a time keeps selection a single
    rule -- descend by UCT until a leaf -- instead of two.
    """
    if t_first()[][node] != -1:
        return
    let black_turn = t_turn()[][node] != 0
    let nb0 = t_black()[][node]
    let nw0 = t_white()[][node]
    let own = nb0 if black_turn else nw0
    let opp = nw0 if black_turn else nb0
    var moves = legal_moves(own, opp)
    if moves == 0:
        # A player with no move passes. If neither can move the node is
        # terminal and stays childless.
        if legal_moves(opp, own) != 0:
            let child = tree_add(nb0, nw0, not black_turn, node, UInt64(0))
            t_first()[][node] = child
            t_count()[][node] = 1
        else:
            t_count()[][node] = 0
            t_first()[][node] = -2      # terminal, and known to be
        return
    var first = -1
    var n = 0
    while moves != 0:
        let one = lowest(moves)
        moves &= moves - 1
        let f = flips_for(own, opp, one)
        var nb = nb0
        var nw = nw0
        if black_turn:
            nb = nb | one | f
            nw = nw ^ f
        else:
            nw = nw | one | f
            nb = nb ^ f
        let child = tree_add(nb, nw, not black_turn, node, one)
        if first == -1:
            first = child
        n += 1
    t_first()[][node] = first
    t_count()[][node] = n


def uct_child(node: Int) -> Int:
    """The child this node's player most wants to look at next.

    The score is stored from black's point of view throughout, so white
    maximises its negation. Doing the flip here, once, is why no other part
    of this file has to think about whose turn it is.
    """
    let first = t_first()[][node]
    let n = t_count()[][node]
    if first < 0 or n == 0:
        return -1
    let black_to_move = t_turn()[][node] != 0
    # Virtual loss counts as a visit while a nomination is outstanding, which
    # is what pushes the next nomination somewhere else.
    # Virtual loss has to be counted in the SAME units as visits. A visit is
    # one playout and a nomination is worth PER_LEAF of them, so counting
    # pending as 1 made it numerically invisible -- and every leaf in a batch
    # of 64 then followed the same path, which is the whole thing virtual
    # loss exists to prevent.
    # UCT's exploration term is scaled for a count of DECISIONS, not of
    # samples. A nomination here brings back PER_LEAF playouts at once, so
    # counting `visits` directly makes sqrt(log N / n) about sqrt(PER_LEAF)
    # times too small -- exploration vanishes and the search goes greedy,
    # pouring 89% of its samples into whichever move looked best first.
    # Both terms are therefore measured in nominations.
    let parent_plays = (
        t_visits()[][node] // PER_LEAF + t_pending()[][node] + 1
    )
    var best = -1
    var best_value = -1.0e18
    for i in range(n):
        let c = first + i
        let samples = t_visits()[][c]
        let plays = samples // PER_LEAF + t_pending()[][c]
        if plays == 0:
            # Never sampled: take it now. Nothing an estimate could say
            # beats actually looking.
            return c
        # The mean is over playouts, which is the honest estimate; the
        # exploration term is over nominations, which is the right scale.
        let mean = (
            Float64(t_score()[][c]) / Float64(samples) if samples > 0 else 0.0
        )
        let exploit = mean if black_to_move else -mean
        let explore = EXPLORE * _sqrt(
            _log(Float64(parent_plays)) / Float64(plays)
        )
        let value = exploit + explore
        if value > best_value:
            best_value = value
            best = c
    return best


fn _sqrt(x: Float64) -> Float64:
    if x <= 0.0:
        return 0.0
    var g = x
    for _ in range(20):
        g = 0.5 * (g + x / g)
    return g


fn _log(x: Float64) -> Float64:
    """Natural log by halving into [1,2) and a short series. The stdlib has
    one; this file avoids the import so the same arithmetic runs everywhere."""
    if x <= 0.0:
        return -1.0e18
    var v = x
    var e = 0.0
    while v >= 2.0:
        v *= 0.5
        e += 1.0
    while v < 1.0:
        v *= 2.0
        e -= 1.0
    # ln(v) for v in [1,2) via atanh series, which converges quickly there.
    let t = (v - 1.0) / (v + 1.0)
    let t2 = t * t
    var term = t
    var sum = 0.0
    var k = 0
    while k < 12:
        sum += term / Float64(2 * k + 1)
        term *= t2
        k += 1
    return 2.0 * sum + e * 0.6931471805599453


def select_leaf() -> Int:
    """Descend by UCT to a node worth evaluating, marking the path pending."""
    var node = 0
    while True:
        t_pending()[][node] += 1
        # Newly nominated: evaluate it rather than descending into a subtree
        # nobody has measured yet. The test has to come AFTER the increment
        # above -- testing before it never fires, and the descent then runs
        # all the way to a finished game, expanding every node on the way and
        # evaluating a position whose result was already decided.
        if node != 0 and t_visits()[][node] == 0 and t_pending()[][node] == 1:
            return node
        if t_first()[][node] == -2:
            return node                      # terminal
        if t_first()[][node] == -1:
            tree_expand(node)
            if t_first()[][node] == -2:
                return node
        let child = uct_child(node)
        if child < 0:
            return node
        node = child


def backpropagate(leaf: Int, total: Int, samples: Int):
    """Fold a batch of results back up the path, clearing the virtual loss."""
    var node = leaf
    while node != -1:
        t_visits()[][node] += samples
        t_score()[][node] += total
        t_pending()[][node] -= 1
        if t_pending()[][node] < 0:
            t_pending()[][node] = 0
        node = t_parent()[][node]


# ── The batched kernel the hybrid player uses ───────────────────────────────
# The flat player asks one question: "which of these root moves wins most?"
# A tree search asks a different one, thousands of times: "how good is THIS
# position?" -- about leaves it chose deliberately rather than uniformly.
#
# So the kernel takes an array of positions instead of one, and every thread
# still plays exactly one game. Batching is what makes the dispatch worth
# paying for: a kernel launch costs the same whether it evaluates one leaf or
# sixty-four, and the tree can always find sixty-four worth asking about.


def batch_playout_kernel(
    results: Pointer[Int32, MutAnyOrigin],
    blacks: Pointer[UInt64, MutAnyOrigin],
    whites: Pointer[UInt64, MutAnyOrigin],
    turns: Pointer[Int32, MutAnyOrigin],
    position_count: Int32,
    per_position: Int32,
    seed: UInt64,
):
    let idx = Int(global_idx.x)
    let total = Int(position_count) * Int(per_position)
    if idx >= total:
        return
    let which = idx // Int(per_position)
    let r = playout(
        blacks[unsafe_offset=which],
        whites[unsafe_offset=which],
        turns[unsafe_offset=which] != 0,
        seed ^ (UInt64(idx) * 0x9E3779B97F4A7C15),
    )
    # Always from black's point of view. The tree flips the sign where it
    # needs to, once, rather than every thread guessing whose turn it is.
    results[unsafe_offset=idx] = Int32(r)


def best_by_uct_gpu(
    ctx: DeviceContext,
    black: UInt64,
    white: UInt64,
    black_to_move: Bool,
    seed: UInt64,
    rounds: Int,
) raises -> UInt64:
    """A move chosen by tree search, with the GPU doing the measuring."""
    let own = black if black_to_move else white
    let opp = white if black_to_move else black
    let root_moves = legal_moves(own, opp)
    if root_moves == 0:
        return 0
    if popcount(root_moves) == 1:
        return root_moves

    tree_reset(black, white, black_to_move)
    tree_expand(0)

    var kern = ctx.compile_function[batch_playout_kernel]()
    var d_black = ctx.enqueue_create_buffer[DType.uint64](BATCH)
    var d_white = ctx.enqueue_create_buffer[DType.uint64](BATCH)
    var d_turn = ctx.enqueue_create_buffer[DType.int32](BATCH)
    var d_out = ctx.enqueue_create_buffer[DType.int32](BATCH * PER_LEAF)

    var rng = seed | 1
    var leaves = List[Int]()

    for _ in range(rounds):
        # Nominate a batch. Virtual loss makes each nomination avoid the ones
        # already outstanding, so a batch explores rather than repeating.
        leaves.clear()
        with d_black.map_to_host() as hb:
            with d_white.map_to_host() as hw:
                with d_turn.map_to_host() as ht:
                    let pb = hb.unsafe_ptr()
                    let pw = hw.unsafe_ptr()
                    let pt = ht.unsafe_ptr()
                    for i in range(BATCH):
                        let leaf = select_leaf()
                        leaves.append(leaf)
                        pb[unsafe_offset=i] = t_black()[][leaf]
                        pw[unsafe_offset=i] = t_white()[][leaf]
                        pt[unsafe_offset=i] = Int32(t_turn()[][leaf])

        rng = next_random(rng)
        let total_threads = BATCH * PER_LEAF
        let blocks = (total_threads + GPU_BLOCK - 1) // GPU_BLOCK
        ctx.enqueue_function(
            kern, d_out, d_black, d_white, d_turn,
            Int32(BATCH), Int32(PER_LEAF), rng,
            grid_dim=(blocks), block_dim=(GPU_BLOCK),
        )
        ctx.synchronize()

        with d_out.map_to_host() as ho:
            let po = ho.unsafe_ptr()
            for i in range(BATCH):
                var sum = 0
                for k in range(PER_LEAF):
                    sum += Int(po[unsafe_offset=i * PER_LEAF + k])
                backpropagate(leaves[i], sum, PER_LEAF)

    # By MEAN, not by visit count. Visit count is the usual criterion and it
    # is the right one when the search is long enough for the best move to
    # pull clearly ahead. It is not right here: a few thousand nominations
    # spread over a tree leaves the root children with visit counts within
    # noise of each other, so "most visited" picks whichever happened to be
    # nominated marginally more often. The mean is over tens of thousands of
    # playouts and says something.
    let first = t_first()[][0]
    var best_move = UInt64(0)
    var best_value = -1.0e18
    for i in range(t_count()[][0]):
        let c = first + i
        let samples = t_visits()[][c]
        if samples == 0:
            continue
        let mean = Float64(t_score()[][c]) / Float64(samples)
        let value = mean if black_to_move else -mean   # root's mover
        if value > best_value:
            best_value = value
            best_move = t_move()[][c]
    return best_move if best_move != 0 else lowest(root_moves)
