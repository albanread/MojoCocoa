# Three chips behind one schedule — the ChipDeluxe trio (CT0).
#
# A trio is not a nine-voice chip. It is three of the chip everything else
# already trusts, untouched, behind one walker and one stereo mixer: three
# independent filters, three master volumes, and a pan position each. ABC
# voice V:n lands on chip (n-1)/3, so V:1..3 is chip 0 and every tune
# written for the single chip plays on a trio unchanged -- test_trio.mojo
# holds that as sample-for-sample equality, not as a promise.
#
# The walker is chipplay's, re-run against three states: the same span
# rendering, the same event ordering, the same allocator per chip -- those
# `fn`s are imported rather than copied, because two walkers that merely
# agree today is how they disagree next year.
#
# Everything here keeps the audio-thread contract: the trio, its schedule
# and its scratch are plain memory allocated before any callback runs, and
# render_trio allocates nothing, locks nothing, raises nothing.

from std.memory import Pointer, MutUntrackedOrigin
from std.ffi import external_call
from std.math import cos, sin

from gamepane.api.audio import (
    P, get, put, chip_new, chip_free, chip_render, gate_off, PLAYER_BASE,
)
from gamepane.abc.schedule import Step, SE_NOTE_ON, SE_NOTE_OFF, SE_CHIP
from gamepane.abc.model import CP_PAN, CP_ECHO, CP_ETIME, CP_EFB
from gamepane.abc.chipplay import (
    apply_chip, apply_note_on, apply_note_off, silent_tick,
    STEP_SLOTS, SC_VOICE_NOTE,
)

# ── the trio block ──────────────────────────────────────────────────────────
#
# Flat Int slots, the house shape: readable from any thread, owned by the
# audio thread while the unit runs, and every cross-thread field is a whole
# machine word.

comptime T_CHIP_BASE = 0     # three slots: the chips' addresses
comptime T_PAN_BASE = 3      # three slots: pan positions, -128..127
comptime T_GAIN_L = 6        # three slots: left gains, 0..256
comptime T_GAIN_R = 9        # three slots: right gains, 0..256
comptime T_MASTER = 12       # output scale, /256 -- 128 is the deck's honest half
comptime T_ADDR = 13         # the flattened schedule
comptime T_COUNT = 14
comptime T_CURSOR = 15
comptime T_SAMPLE = 16
comptime T_END = 17
comptime T_LOOP = 18
comptime T_DONE = 19
comptime T_SCRATCH = 20      # one mono span buffer, reused chip by chip
comptime T_ECHO_SEND = 21    # three slots: per-chip send into the echo, 0..15
comptime T_ETIME = 24        # echo time in 50 Hz ticks (CT3 consumes)
comptime T_EFB = 25          # echo feedback, 0..15
comptime TRIO_SLOTS = 32

comptime TRIO_SPAN = 4096
"""The most one chip_render is asked for in one go. A longer quiet span is
split; events still land on their exact sample, because splitting a span
between events changes nothing about when the next event applies."""


def trio_new() raises -> P:
    """Three chips and the frame around them. Allocate before audio starts."""
    let t = external_call["calloc", P](Int(TRIO_SLOTS), Int(8))
    if Int(t) == 0:
        raise Error("trio: no memory")
    for i in range(3):
        let c = chip_new()
        put(t, T_CHIP_BASE + i, Int(c))
        # The allocator's "free" is -1. calloc's zero is MIDI note 0, which
        # is a note something could release by accident.
        for v in range(3):
            put(c, PLAYER_BASE + SC_VOICE_NOTE + v, -1)
    let scratch = external_call["calloc", P](Int(TRIO_SPAN), Int(4))
    if Int(scratch) == 0:
        raise Error("trio: no scratch")
    put(t, T_SCRATCH, Int(scratch))
    put(t, T_MASTER, 128)
    # The twin-SID rig: music centre, and the outer chips off to each side.
    set_trio_pan(t, 0, 0)
    set_trio_pan(t, 1, -96)
    set_trio_pan(t, 2, 96)
    return t


fn trio_free(t: P):
    if Int(t) == 0:
        return
    for i in range(3):
        chip_free(P(unsafe_from_address=get(t, T_CHIP_BASE + i)))
    _ = external_call["free", NoneType](
        P(unsafe_from_address=get(t, T_SCRATCH))
    )
    let addr = get(t, T_ADDR)
    if addr != 0:
        _ = external_call["free", NoneType](P(unsafe_from_address=addr))
    _ = external_call["free", NoneType](t)


fn trio_chip(t: P, i: Int) -> P:
    """Chip i of 3 -- for settings, taps, and the tests' own assertions."""
    var k = i
    if k < 0:
        k = 0
    elif k > 2:
        k = 2
    return P(unsafe_from_address=get(t, T_CHIP_BASE + k))


fn set_trio_pan(t: P, chip: Int, pos: Int):
    """Place a chip in the field, -128 hard left through 0 to 127 right.

    Constant-power: the gains are cos/sin of the quarter turn, scaled to
    /256 integers ONCE, here, on the calling thread -- the callback only
    ever multiplies by what this stored. Hard left is exactly (256, 0),
    which is what lets a test read a chip's raw output off one channel.
    """
    if chip < 0 or chip > 2:
        return
    var p = pos
    if p < -128:
        p = -128
    elif p > 127:
        p = 127
    put(t, T_PAN_BASE + chip, p)
    let theta = (Float64(p) + 128.0) / 256.0 * 1.5707963267948966
    var gl = Int(cos(theta) * 256.0 + 0.5)
    var gr = Int(sin(theta) * 256.0 + 0.5)
    if gl > 256:
        gl = 256
    if gr > 256:
        gr = 256
    put(t, T_GAIN_L + chip, gl)
    put(t, T_GAIN_R + chip, gr)


fn set_trio_master(t: P, scale: Int):
    """Output scale, /256. The default 128 is the deck's halving, kept for
    the same reason: three chips at full tilt should meet a clamp rarely,
    not lean on it."""
    var s = scale
    if s < 0:
        s = 0
    elif s > 256:
        s = 256
    put(t, T_MASTER, s)


def flatten_trio(steps: List[Step], mut t: P) -> Int:
    """Copy the schedule into plain memory, at trio level.

    Same layout chipplay flattens to -- STEP_SLOTS a step, sample-sorted --
    but owned by the trio rather than by any one chip, because the walker
    that reads it routes to all three. Returns len(steps)."""
    let old = get(t, T_ADDR)
    if old != 0:
        _ = external_call["free", NoneType](P(unsafe_from_address=old))
        put(t, T_ADDR, 0)
    let n = len(steps)
    let addr = Int(external_call["calloc", P](Int(n * STEP_SLOTS + 8), Int(8)))
    if addr == 0:
        return 0
    let p = Pointer[Int, MutUntrackedOrigin](unsafe_from_address=addr)
    var last = 0
    for i in range(n):
        let at = i * STEP_SLOTS
        p[unsafe_offset=at + 0] = steps[i].sample
        p[unsafe_offset=at + 1] = steps[i].kind
        p[unsafe_offset=at + 2] = steps[i].voice
        p[unsafe_offset=at + 3] = steps[i].midi
        p[unsafe_offset=at + 4] = steps[i].velocity
        if steps[i].sample > last:
            last = steps[i].sample
    put(t, T_ADDR, addr)
    put(t, T_COUNT, n)
    put(t, T_CURSOR, 0)
    put(t, T_SAMPLE, 0)
    put(t, T_END, last)
    put(t, T_DONE, 0)
    return n


fn set_trio_loop(t: P, loop: Bool):
    put(t, T_LOOP, 1 if loop else 0)


fn trio_done(t: P) -> Bool:
    return get(t, T_DONE) != 0


@always_inline
fn _chip_for_abc_voice(voice: Int) -> Int:
    """ABC voice numbers are 1-based: V:1..3 chip 0, V:4..6 chip 1, V:7..9
    chip 2, and anything past nine stays on the last chip rather than
    vanishing -- a tune with too many voices should still be heard."""
    var c = (voice - 1) // 3
    if c < 0:
        c = 0
    elif c > 2:
        c = 2
    return c


fn render_trio(
    t: P, dest: Pointer[Float32, MutUntrackedOrigin], frames: Int
):
    """Fill `frames` INTERLEAVED STEREO frames: chipplay's walk, three ways.

    The span logic is render_scheduled's, kept step for step: everything
    due at this sample applies before another sample is rendered, then all
    three chips render to the next event and the mixer folds them L/R by
    the stored gains. Audio-thread rules throughout.
    """
    for i in range(frames * 2):
        dest[unsafe_offset=i] = Float32(0.0)
    let addr = get(t, T_ADDR)
    if addr == 0:
        return
    let sched = Pointer[Int, MutUntrackedOrigin](unsafe_from_address=addr)
    let count = get(t, T_COUNT)
    let scratch = Pointer[Float32, MutUntrackedOrigin](
        unsafe_from_address=get(t, T_SCRATCH)
    )
    let master = Float64(get(t, T_MASTER)) / 256.0

    var filled = 0
    while filled < frames:
        var cursor = get(t, T_CURSOR)
        let now = get(t, T_SAMPLE)

        while cursor < count:
            let at = cursor * STEP_SLOTS
            if sched[unsafe_offset=at] > now:
                break
            let kind = sched[unsafe_offset=at + 1]
            let voice = sched[unsafe_offset=at + 2]
            if kind == SE_CHIP:
                # SE_CHIP's voice is already 0-based (schedule.mojo did the
                # -1); chip-level keys still land through any of its voices.
                var c = 0
                var sub = -1
                if voice >= 0:
                    c = voice // 3
                    if c > 2:
                        c = 2
                    sub = voice - c * 3
                let param = sched[unsafe_offset=at + 3]
                let value = sched[unsafe_offset=at + 4]
                # Trio-level parameters stop here: a chip has no pan and no
                # echo, and apply_chip would rightly ignore them.
                if param == CP_PAN:
                    set_trio_pan(t, c, value - 128)
                elif param == CP_ECHO:
                    put(t, T_ECHO_SEND + c, value & 15)
                elif param == CP_ETIME:
                    put(t, T_ETIME, value)
                elif param == CP_EFB:
                    put(t, T_EFB, value & 15)
                else:
                    apply_chip(trio_chip(t, c), sub, param, value)
            elif kind == SE_NOTE_ON:
                apply_note_on(
                    trio_chip(t, _chip_for_abc_voice(voice)),
                    sched[unsafe_offset=at + 3], sched[unsafe_offset=at + 4],
                )
            else:
                apply_note_off(
                    trio_chip(t, _chip_for_abc_voice(voice)),
                    sched[unsafe_offset=at + 3],
                )
            cursor += 1
        put(t, T_CURSOR, cursor)

        var span = frames - filled
        if cursor < count:
            let next = sched[unsafe_offset=cursor * STEP_SLOTS] - now
            if next < span:
                span = next
        if span < 1:
            span = 1
        if span > TRIO_SPAN:
            span = TRIO_SPAN

        for c in range(3):
            chip_render(trio_chip(t, c), scratch, span, silent_tick)
            let gl = Float64(get(t, T_GAIN_L + c)) / 256.0 * master
            let gr = Float64(get(t, T_GAIN_R + c)) / 256.0 * master
            for i in range(span):
                let s = Float64(scratch[unsafe_offset=i])
                let o = (filled + i) * 2
                var l = Float64(dest[unsafe_offset=o]) + s * gl
                var r = Float64(dest[unsafe_offset=o + 1]) + s * gr
                if l > 1.0:
                    l = 1.0
                elif l < -1.0:
                    l = -1.0
                if r > 1.0:
                    r = 1.0
                elif r < -1.0:
                    r = -1.0
                dest[unsafe_offset=o] = Float32(l)
                dest[unsafe_offset=o + 1] = Float32(r)

        filled += span
        put(t, T_SAMPLE, now + span)

        if cursor >= count and get(t, T_SAMPLE) > get(t, T_END):
            if get(t, T_LOOP) != 0:
                put(t, T_CURSOR, 0)
                put(t, T_SAMPLE, 0)
                for c in range(3):
                    let st = trio_chip(t, c)
                    for v in range(3):
                        put(st, PLAYER_BASE + SC_VOICE_NOTE + v, -1)
                        gate_off(st, v)
            else:
                put(t, T_DONE, 1)
