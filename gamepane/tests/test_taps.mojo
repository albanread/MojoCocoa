# ===----------------------------------------------------------------------=== #
# CT4 — the taps: the playhead, the voice levels, the scope ring.
#
# The playhead must be monotonic within a pass and equal to the frames
# rendered -- it is the sync track's needle, and a needle that skips is
# worse than none. The scope ring's newest frames must BE the newest
# frames of the mix, verbatim. The voice level must rise when a voice
# sounds and fall when it stops. Nothing here waits on anything: every
# read is the reader's own risk, by design.
#
# Run: ./tools/gp.sh gamepane/tests/test_taps.mojo
# ===----------------------------------------------------------------------=== #

from std.memory import Pointer, MutUntrackedOrigin

from gamepane.api import P, SAMPLE_RATE
from gamepane.abc import (
    Tune, parse_abc, resolve_ties, build_schedule, sort_steps, Step,
    trio_new, trio_free, flatten_trio, render_trio,
    trio_playhead, trio_voice_level, trio_scope_read, SCOPE_FRAMES,
    set_trio_loop,
)


comptime TUNE = String("""X:1
M:4/4
L:1/4
Q:1/4=120
K:C
V:1
[I:chip v=1 wave=pulse pw=900 a=0 d=3 s=10 r=2]
C2 z2
""")


def main() raises:
    var failures = 0
    var t = Tune()
    parse_abc(TUNE, t)
    resolve_ties(t)
    var steps = List[Step]()
    build_schedule(t, SAMPLE_RATE, steps)
    sort_steps(steps)
    var trio = trio_new()
    _ = flatten_trio(steps, trio)

    # ── the playhead advances by exactly what was rendered ───────────────
    let chunk = 700                       # deliberately not a span multiple
    var buf = List[Float32](length=chunk * 2, fill=0.0)
    var ok_mono = True
    var last = 0
    var total = 0
    for _ in range(120):
        render_trio(trio, Pointer[Float32, MutUntrackedOrigin](
            unsafe_from_address=Int(buf.unsafe_ptr())), chunk)
        total += chunk
        let ph = trio_playhead(trio)
        if ph != total or ph < last:
            ok_mono = False
        last = ph
    if ok_mono:
        print("ok    playhead tracked 120 uneven chunks exactly:", last)
    else:
        print("FAIL  playhead", last, "after", total)
        failures += 1

    # ── the level moves with the note ────────────────────────────────────
    # 84000 frames in: the C (0..1 s) is sounding history; at this point
    # (1.75 s) the gate is off. Render a fresh trio in two halves instead.
    var t2 = trio_new()
    _ = flatten_trio(steps, t2)
    var half = List[Float32](length=SAMPLE_RATE * 2, fill=0.0)
    render_trio(t2, Pointer[Float32, MutUntrackedOrigin](
        unsafe_from_address=Int(half.unsafe_ptr())), SAMPLE_RATE // 2)
    let held = trio_voice_level(t2, 0, 0)
    render_trio(t2, Pointer[Float32, MutUntrackedOrigin](
        unsafe_from_address=Int(half.unsafe_ptr())), SAMPLE_RATE)
    let released = trio_voice_level(t2, 0, 0)
    if held > 50 and released < held // 4:
        print("ok    voice level held", held, "then released", released)
    else:
        print("FAIL  levels held", held, "released", released)
        failures += 1

    # ── the scope's newest frames are the mix's newest frames ────────────
    var t3 = trio_new()
    _ = flatten_trio(steps, t3)
    let n3 = SAMPLE_RATE // 2
    var out3 = List[Float32](length=n3 * 2, fill=0.0)
    render_trio(t3, Pointer[Float32, MutUntrackedOrigin](
        unsafe_from_address=Int(out3.unsafe_ptr())), n3)
    var scope = List[Float32](length=SCOPE_FRAMES * 2, fill=0.0)
    let got = trio_scope_read(t3, Pointer[Float32, MutUntrackedOrigin](
        unsafe_from_address=Int(scope.unsafe_ptr())), SCOPE_FRAMES)
    var mism = 0
    for i in range(got):
        let src = (n3 - got + i) * 2
        if scope[i * 2] != out3[src] or scope[i * 2 + 1] != out3[src + 1]:
            mism += 1
    var live = 0.0
    for i in range(got * 2):
        let v = Float64(scope[i])
        if v > live:
            live = v
    if got == SCOPE_FRAMES and mism == 0 and live > 0.01:
        print("ok    scope holds the newest", got, "frames verbatim, peak",
              live)
    else:
        print("FAIL  scope got", got, "mismatches", mism, "peak", live)
        failures += 1

    # ── a loop wrap rewinds the needle ───────────────────────────────────
    var t4 = trio_new()
    _ = flatten_trio(steps, t4)
    set_trio_loop(t4, True)
    var big = List[Float32](length=SAMPLE_RATE * 2 * 3, fill=0.0)
    render_trio(t4, Pointer[Float32, MutUntrackedOrigin](
        unsafe_from_address=Int(big.unsafe_ptr())), SAMPLE_RATE * 3)
    let ph4 = trio_playhead(t4)
    if ph4 < SAMPLE_RATE * 3:
        print("ok    looping playhead rewound to", ph4)
    else:
        print("FAIL  looping playhead", ph4)
        failures += 1

    trio_free(trio); trio_free(t2); trio_free(t3); trio_free(t4)
    _ = buf; _ = half; _ = out3; _ = scope; _ = big

    if failures == 0:
        print("PASS  test_taps")
    else:
        print("FAIL ", failures, "failures")
        raise Error("test_taps failed")
