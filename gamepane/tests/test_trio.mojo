# ===----------------------------------------------------------------------=== #
# CT0 — the trio: three chips, one walker, a stereo mixer.
#
# The claim that matters is EQUALITY: a three-voice tune rendered through a
# trio, with chip 0 panned hard left at unity master, produces the same
# samples on the left channel that render_scheduled produces on its own.
# Not close -- the same. Everything else here is routing: nine voices land
# on three chips, a chip instruction addressed to V:5 reaches chip 1's
# middle voice, and pan puts a chip where it said.
#
# Run: ./tools/gp.sh gamepane/tests/test_trio.mojo
# ===----------------------------------------------------------------------=== #

from std.memory import Pointer, MutUntrackedOrigin

from gamepane.api import P, SAMPLE_RATE, chip_new, chip_free
from gamepane.api.audio import vget, V_WAVE, WAVE_NOISE
from gamepane.abc import (
    Tune, parse_abc, resolve_ties, build_schedule, sort_steps, Step,
    flatten_schedule, render_scheduled,
    trio_new, trio_free, trio_chip, set_trio_pan, set_trio_master,
    flatten_trio, render_trio, T_GAIN_L, T_GAIN_R,
)
from gamepane.api.audio import get


def steps_for(source: String) raises -> List[Step]:
    var t = Tune()
    parse_abc(source, t)
    resolve_ties(t)
    var steps = List[Step]()
    build_schedule(t, SAMPLE_RATE, steps)
    sort_steps(steps)
    return steps^


# A three-voice tune that exercises what a real one does: instrument
# settings, the filter, a chord, rests, differing note lengths.
comptime THREE = String("""X:1
M:4/4
L:1/8
Q:1/4=140
K:Am
V:1
[I:chip v=1 wave=pulse pw=700 a=0 d=5 s=7 r=3 filt=1 cutoff=1400 res=3 mode=lp vol=13]
A,2 C2 E2 A2 | E2 C2 A,4
V:2
[I:chip v=2 wave=saw a=1 d=3 s=9 r=5]
c4 e4 | a2 e2 c4
V:3
[I:chip v=3 wave=noise a=0 d=1 s=0 r=1]
z2 C2 z2 C2 | C2 z2 C2 z2
""")

# Nine voices: one note per chip region, in three separated time windows,
# so a channel's energy names the chip that made it.
comptime NINE = String("""X:1
M:4/4
L:1/4
Q:1/4=120
K:C
V:1
C4 | z4 | z4
V:2
E4 | z4 | z4
V:3
G4 | z4 | z4
V:4
z4 | C4 | z4
V:5
[I:chip v=5 wave=noise]
z4 | E4 | z4
V:6
z4 | G4 | z4
V:7
z4 | z4 | C4
V:8
z4 | z4 | E4
V:9
z4 | z4 | G4
""")


def energy(buf: List[Float32], channel: Int, lo: Int, hi: Int) -> Float64:
    var e = 0.0
    for i in range(lo, hi):
        let v = Float64(buf[i * 2 + channel])
        e += v * v
    return e


def main() raises:
    var failures = 0
    let n = 4 * SAMPLE_RATE

    # ── equality: the trio walker IS chipplay's walker ────────────────────
    var mono = List[Float32](length=n, fill=0.0)
    var st = chip_new()
    var steps = steps_for(THREE)
    _ = flatten_schedule(steps, st)
    render_scheduled(st, Pointer[Float32, MutUntrackedOrigin](
        unsafe_from_address=Int(mono.unsafe_ptr())), n)

    var stereo = List[Float32](length=n * 2, fill=0.0)
    var t = trio_new()
    set_trio_master(t, 256)          # unity, so left IS chip 0's output
    set_trio_pan(t, 0, -128)
    _ = flatten_trio(steps, t)
    render_trio(t, Pointer[Float32, MutUntrackedOrigin](
        unsafe_from_address=Int(stereo.unsafe_ptr())), n)

    var diffs = 0
    var peak = 0.0
    for i in range(n):
        if mono[i] != stereo[i * 2]:
            diffs += 1
        let v = Float64(mono[i])
        if v > peak:
            peak = v
    if diffs == 0 and peak > 0.05:
        print("ok    three-voice tune: trio left == single chip,",
              n, "samples, peak", peak)
    else:
        print("FAIL  equality:", diffs, "differing samples, peak", peak)
        failures += 1
    # And nothing leaked to the right past the pan law's floor.
    let right = energy(stereo, 1, 0, n)
    if right == 0.0:
        print("ok    hard left: right channel exactly silent")
    else:
        print("FAIL  hard left: right channel energy", right)
        failures += 1

    # ── nine voices land on three chips ──────────────────────────────────
    var s9 = steps_for(NINE)
    var t9 = trio_new()
    set_trio_pan(t9, 0, -128)
    set_trio_pan(t9, 1, 0)
    set_trio_pan(t9, 2, 127)
    _ = flatten_trio(s9, t9)
    let n9 = 6 * SAMPLE_RATE
    var out9 = List[Float32](length=n9 * 2, fill=0.0)
    render_trio(t9, Pointer[Float32, MutUntrackedOrigin](
        unsafe_from_address=Int(out9.unsafe_ptr())), n9)
    # Bars are two seconds at Q=120: windows inside bars 1, 2, 3.
    let w = SAMPLE_RATE // 2
    let b1 = SAMPLE_RATE // 4
    let b2 = 2 * SAMPLE_RATE + b1
    let b3 = 4 * SAMPLE_RATE + b1
    let l1 = energy(out9, 0, b1, b1 + w)
    let r1 = energy(out9, 1, b1, b1 + w)
    let l2 = energy(out9, 0, b2, b2 + w)
    let r2 = energy(out9, 1, b2, b2 + w)
    let l3 = energy(out9, 0, b3, b3 + w)
    let r3 = energy(out9, 1, b3, b3 + w)
    if l1 > 0.0 and r1 == 0.0:
        print("ok    bar 1: chip 0 hard left  L", l1)
    else:
        print("FAIL  bar 1 placement L", l1, "R", r1)
        failures += 1
    if l2 > 0.0 and r2 > 0.0 and l2 * 2.0 > r2 and r2 * 2.0 > l2:
        print("ok    bar 2: chip 1 centred    L", l2, "R", r2)
    else:
        print("FAIL  bar 2 placement L", l2, "R", r2)
        failures += 1
    if r3 > 0.0 and l3 < r3 / 100.0:
        print("ok    bar 3: chip 2 hard right R", r3)
    else:
        print("FAIL  bar 3 placement L", l3, "R", r3)
        failures += 1

    # ── a chip instruction crosses to the right chip ─────────────────────
    # NINE's V:5 carries [I:chip v=5 wave=noise]: chip 1, middle voice.
    if vget(trio_chip(t9, 1), 1, V_WAVE) == WAVE_NOISE:
        print("ok    [I:chip v=5] reached chip 1 voice 1")
    else:
        print("FAIL  v=5 instruction went astray: chip1 v1 wave",
              vget(trio_chip(t9, 1), 1, V_WAVE))
        failures += 1

    # ── the pan law's stated extremes ────────────────────────────────────
    if get(t9, T_GAIN_L + 0) == 256 and get(t9, T_GAIN_R + 0) == 0:
        print("ok    pan -128 is exactly (256, 0)")
    else:
        print("FAIL  pan -128 gains", get(t9, T_GAIN_L + 0),
              get(t9, T_GAIN_R + 0))
        failures += 1

    chip_free(st)
    trio_free(t)
    trio_free(t9)
    _ = mono
    _ = stereo
    _ = out9

    if failures == 0:
        print("PASS  test_trio")
    else:
        print("FAIL ", failures, "failures")
        raise Error("test_trio failed")
