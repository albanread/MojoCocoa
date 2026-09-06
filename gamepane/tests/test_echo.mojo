# ===----------------------------------------------------------------------=== #
# CT3 — the echo: one preallocated ping-pong delay, sends per chip.
#
# Four claims. A tune that never says echo= renders as if the delay did
# not exist (test_trio already holds the stronger bit-equality; here the
# skip flag is checked directly). A note with a send rings after its
# release, where the dry version is silent. The FIRST repeat lands left
# and the SECOND right, because that is what ping-pong means. And the
# feedback ceiling is arithmetic: at efb=15 the ring is a geometric
# series that decays, never a runaway.
#
# Run: ./tools/gp.sh gamepane/tests/test_echo.mojo
# ===----------------------------------------------------------------------=== #

from std.memory import Pointer, MutUntrackedOrigin

from gamepane.api import P, SAMPLE_RATE
from gamepane.api.audio import get
from gamepane.abc import (
    Tune, parse_abc, resolve_ties, build_schedule, sort_steps, Step,
    trio_new, trio_free, flatten_trio, render_trio,
)
from gamepane.abc.trioplay import T_ECHO_USED


def render(source: String, seconds: Int) raises -> Tuple[P, List[Float32]]:
    var t = Tune()
    parse_abc(source, t)
    resolve_ties(t)
    var steps = List[Step]()
    build_schedule(t, SAMPLE_RATE, steps)
    sort_steps(steps)
    var trio = trio_new()
    _ = flatten_trio(steps, trio)
    let n = seconds * SAMPLE_RATE
    var out = List[Float32](length=n * 2, fill=0.0)
    render_trio(trio, Pointer[Float32, MutUntrackedOrigin](
        unsafe_from_address=Int(out.unsafe_ptr())), n)
    return (trio, out^)


def energy(buf: List[Float32], channel: Int, lo: Int, hi: Int) -> Float64:
    var e = 0.0
    for i in range(lo, hi):
        let v = Float64(buf[i * 2 + channel])
        e += v * v
    return e


# One short plucked note on the CENTRE chip, dead by 0.3 s.
def pluck(extra: String) -> String:
    return (String("X:1\nM:4/4\nL:1/4\nQ:1/4=120\nK:C\nV:1\n")
            + "[I:chip v=1 wave=pulse pw=800 a=0 d=3 s=0 r=2" + extra
            + "]\nC z3 | z4\n")


def main() raises:
    var failures = 0

    # ── never asked for, never run ───────────────────────────────────────
    var dry = render(pluck(String("")), 4)
    if get(dry[0], T_ECHO_USED) == 0:
        print("ok    no echo= anywhere: the pass never armed")
    else:
        print("FAIL  echo armed itself")
        failures += 1

    # ── the ring outlives the note ───────────────────────────────────────
    # etime=25 is half a second. The note is silent past 0.3 s, so the
    # window from 0.4 s holds only what the delay says.
    var wet = render(pluck(String(" echo=12 etime=25 efb=10")), 4)
    let tail_dry = (energy(dry[1], 0, SAMPLE_RATE * 2 // 5, SAMPLE_RATE * 3)
                    + energy(dry[1], 1, SAMPLE_RATE * 2 // 5, SAMPLE_RATE * 3))
    let tail_wet = (energy(wet[1], 0, SAMPLE_RATE * 2 // 5, SAMPLE_RATE * 3)
                    + energy(wet[1], 1, SAMPLE_RATE * 2 // 5, SAMPLE_RATE * 3))
    if tail_wet > tail_dry * 100.0 and tail_wet > 0.01:
        print("ok    the tail rings: wet", tail_wet, "dry", tail_dry)
    else:
        print("FAIL  tails: wet", tail_wet, "dry", tail_dry)
        failures += 1

    # ── first tap left, second right ─────────────────────────────────────
    # Taps at 0.5 s and 1.0 s; the note itself is centred, so each window
    # past the dry sound belongs to one line or the other.
    let w = SAMPLE_RATE // 5
    let tap1 = SAMPLE_RATE // 2 + SAMPLE_RATE // 100
    let tap2 = SAMPLE_RATE + SAMPLE_RATE // 100
    let l1 = energy(wet[1], 0, tap1, tap1 + w)
    let r1 = energy(wet[1], 1, tap1, tap1 + w)
    let l2 = energy(wet[1], 0, tap2, tap2 + w)
    let r2 = energy(wet[1], 1, tap2, tap2 + w)
    if l1 > r1 * 4.0:
        print("ok    first repeat is left  L", l1, "R", r1)
    else:
        print("FAIL  first repeat L", l1, "R", r1)
        failures += 1
    if r2 > l2 * 4.0:
        print("ok    second repeat is right L", l2, "R", r2)
    else:
        print("FAIL  second repeat L", l2, "R", r2)
        failures += 1

    # ── the ceiling is arithmetic ────────────────────────────────────────
    var hot = render(pluck(String(" echo=15 etime=5 efb=15")), 8)
    var peak_early = 0.0
    var peak_late = 0.0
    let half = 4 * SAMPLE_RATE * 2
    for i in range(half):
        let v = abs(Float64(hot[1][i]))
        if v > peak_early:
            peak_early = v
    for i in range(half, 8 * SAMPLE_RATE * 2):
        let v = abs(Float64(hot[1][i]))
        if v > peak_late:
            peak_late = v
    if peak_late < peak_early and peak_late < 1.0:
        print("ok    efb=15 decays:", peak_early, "then", peak_late)
    else:
        print("FAIL  feedback:", peak_early, "then", peak_late)
        failures += 1

    # ── deterministic, twice ─────────────────────────────────────────────
    var e1 = render(pluck(String(" echo=12 etime=20 efb=12")), 3)
    var e2 = render(pluck(String(" echo=12 etime=20 efb=12")), 3)
    var diffs = 0
    for i in range(3 * SAMPLE_RATE * 2):
        if e1[1][i] != e2[1][i]:
            diffs += 1
    if diffs == 0:
        print("ok    echoed render is byte-identical across fresh trios")
    else:
        print("FAIL  determinism:", diffs, "diffs")
        failures += 1

    trio_free(dry[0]); trio_free(wet[0]); trio_free(hot[0])
    trio_free(e1[0]); trio_free(e2[0])
    _ = dry[1]; _ = wet[1]; _ = hot[1]; _ = e1[1]; _ = e2[1]

    if failures == 0:
        print("PASS  test_echo")
    else:
        print("FAIL ", failures, "failures")
        raise Error("test_echo failed")
