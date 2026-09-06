# ===----------------------------------------------------------------------=== #
# CT2 — the 50 Hz performance layer: arp, vibrato, slide, pwm, trem, sweep.
#
# Each macro is proven by the register it moves, read back after a render;
# then the whole set at once must be deterministic -- two fresh trios, the
# same tune, byte-identical output -- because a macro that consults
# anything but its own integer state would fail exactly that.
#
# Run: ./tools/gp.sh gamepane/tests/test_macros.mojo
# ===----------------------------------------------------------------------=== #

from std.memory import Pointer, MutUntrackedOrigin

from gamepane.api import P, SAMPLE_RATE
from gamepane.api.audio import get, fget, vget, V_PW, V_SUS, S_CUTOFF
from gamepane.abc import (
    Tune, parse_abc, resolve_ties, build_schedule, sort_steps, Step,
    trio_new, trio_free, trio_chip, flatten_trio, render_trio,
)
from gamepane.abc.chipplay import (
    macro_slot, M_ARP_POS, M_VIB_PHASE, M_SLIDE_CUR, M_PWM_PHASE,
)


def rendered(source: String, seconds: Int) raises -> Tuple[P, List[Float32]]:
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


def head(line: String) -> String:
    return (String("X:1\nM:4/4\nL:1/4\nQ:1/4=120\nK:C\nV:1\n") + line + "\n")


def fnv(buf: List[Float32]) -> Int:
    """FNV-1a over the sample bytes, for the determinism check's receipt."""
    var h = -3750763034362895579          # 0xcbf29ce484222325 as Int64
    let p = Pointer[UInt8, MutUntrackedOrigin](
        unsafe_from_address=Int(buf.unsafe_ptr()))
    for i in range(len(buf) * 4):
        h = (h ^ Int(p[unsafe_offset=i])) * 1099511628211
    return h


def main() raises:
    var failures = 0

    # ── arp advances and lands on table pitches ──────────────────────────
    var r1 = rendered(head(String("[I:chip v=1 wave=pulse arp=047] C4")), 1)
    let pos = get(trio_chip(r1[0], 0), macro_slot(0, M_ARP_POS))
    if pos >= 45 and pos <= 55:           # ~50 ticks in a second
        print("ok    arp stepped", pos, "times in a second")
    else:
        print("FAIL  arp position", pos)
        failures += 1
    trio_free(r1[0])

    # ── vibrato's phase runs, and the pitch is off the note ──────────────
    var r2 = rendered(head(String("[I:chip v=1 vib=12/5] C4")), 1)
    let vph = get(trio_chip(r2[0], 0), macro_slot(0, M_VIB_PHASE))
    if vph >= 200 and vph <= 300:         # 5/tick * ~50 ticks
        print("ok    vibrato phase at", vph, "after a second")
    else:
        print("FAIL  vibrato phase", vph)
        failures += 1
    trio_free(r2[0])

    # ── slide: caught mid-glide between two notes an octave apart ────────
    # C then c with slide=2: 12 semitones at 2/16 per tick is 96 ticks of
    # travel; at half a second past the change (~25 ticks) the glide is
    # around 3 semitones in -- strictly between the two pitches.
    var r3 = rendered(
        head(String("[I:chip v=1 slide=2] C4 | c4")), 3)
    let cur = fget(trio_chip(r3[0], 0), macro_slot(0, M_SLIDE_CUR))
    let base = Float64(get(trio_chip(r3[0], 0), 0) * 0)  # keep types simple
    if cur > 60.0 + base and cur < 73.0:
        print("ok    slide caught the glide at", cur)
    else:
        print("FAIL  slide cur", cur)
        failures += 1
    trio_free(r3[0])

    # ── pwm moved the width off its base ─────────────────────────────────
    var r4 = rendered(
        head(String("[I:chip v=1 wave=pulse pw=2048 pwm=64/3] C4")), 1)
    let pw = vget(trio_chip(r4[0], 0), 0, V_PW)
    let pph = get(trio_chip(r4[0], 0), macro_slot(0, M_PWM_PHASE))
    if pph > 100 and pw != 2048:
        print("ok    pwm breathing: width", pw, "phase", pph)
    else:
        print("FAIL  pwm width", pw, "phase", pph)
        failures += 1
    trio_free(r4[0])

    # ── tremolo wobbles the sustain target ───────────────────────────────
    var r5 = rendered(
        head(String("[I:chip v=1 a=0 d=2 s=12 r=3 trem=96/7] C4")), 1)
    let sus = vget(trio_chip(r5[0], 0), 0, V_SUS)
    if sus != 12 * 17:
        print("ok    tremolo moved sustain to", sus, "from", 12 * 17)
    else:
        print("FAIL  tremolo left sustain at", sus)
        failures += 1
    trio_free(r5[0])

    # ── the sweep walks the cutoff ───────────────────────────────────────
    var r6 = rendered(
        head(String("[I:chip v=1 filt=1 cutoff=200 sweep=8] C4")), 1)
    let cut = get(trio_chip(r6[0], 0), S_CUTOFF)
    if cut >= 500 and cut <= 700:         # 200 + 8 * ~50
        print("ok    sweep carried the cutoff to", cut)
    else:
        print("FAIL  cutoff", cut)
        failures += 1
    trio_free(r6[0])

    # ── all of it at once, twice, byte for byte ──────────────────────────
    comptime EVERYTHING = String("""X:1
M:4/4
L:1/8
Q:1/4=140
K:Am
V:1
[I:chip v=1 wave=pulse pw=1400 arp=047 pwm=32/2 filt=1 cutoff=300 sweep=6]
A,4 C4 | E8
V:2
[I:chip v=2 wave=saw vib=10/4 slide=3]
a4 e4 | c8
V:3
[I:chip v=3 wave=tri trem=80/5 a=1 d=2 s=13 r=6]
e4 a4 | e8
V:5
[I:chip v=5 wave=pulse pw=600 arp=037 pan=-80 echo=6]
C4 E4 | A8
""")
    var t1 = Tune()
    parse_abc(EVERYTHING, t1)
    resolve_ties(t1)
    var s1 = List[Step]()
    build_schedule(t1, SAMPLE_RATE, s1)
    sort_steps(s1)
    let n = 3 * SAMPLE_RATE
    var a = List[Float32](length=n * 2, fill=0.0)
    var b = List[Float32](length=n * 2, fill=0.0)
    var ta = trio_new()
    _ = flatten_trio(s1, ta)
    render_trio(ta, Pointer[Float32, MutUntrackedOrigin](
        unsafe_from_address=Int(a.unsafe_ptr())), n)
    var tb = trio_new()
    _ = flatten_trio(s1, tb)
    render_trio(tb, Pointer[Float32, MutUntrackedOrigin](
        unsafe_from_address=Int(b.unsafe_ptr())), n)
    var diffs = 0
    var peak = 0.0
    for i in range(n * 2):
        if a[i] != b[i]:
            diffs += 1
        let v = Float64(a[i])
        if v > peak:
            peak = v
    if diffs == 0 and peak > 0.05:
        print("ok    every macro at once, twice: byte-identical, peak", peak)
        print("ok    render hash", fnv(a))
    else:
        print("FAIL  determinism:", diffs, "differing samples, peak", peak)
        failures += 1
    trio_free(ta)
    trio_free(tb)
    _ = a
    _ = b
    _ = r1[1]; _ = r2[1]; _ = r3[1]; _ = r4[1]; _ = r5[1]; _ = r6[1]

    if failures == 0:
        print("PASS  test_macros")
    else:
        print("FAIL ", failures, "failures")
        raise Error("test_macros failed")
