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
from std.math import cos, sin, exp2
from std.atomic import Atomic, Ordering

from gamepane.api.audio import (
    P, get, put, fget, fput, vget, vput, chip_new, chip_free, chip_render,
    gate_off, set_freq_hz, set_pulse_width, set_filter, PLAYER_BASE,
    SAMPLE_RATE, FRAME_SAMPLES,
    S_CUTOFF, S_RES, S_FMODE, V_SUS, V_PW, V_ENV,
)
from gamepane.abc.schedule import Step, SE_NOTE_ON, SE_NOTE_OFF, SE_CHIP
from gamepane.abc.model import CP_PAN, CP_ECHO, CP_ETIME, CP_EFB
from gamepane.abc.chipplay import (
    apply_chip, apply_note_on, apply_note_off, silent_tick,
    STEP_SLOTS, SC_VOICE_NOTE, CHIP_ADSR, MACRO_BASE, MACRO_STRIDE,
    macro_slot, M_ARP, M_ARP_POS, M_VIB, M_VIB_PHASE, M_SLIDE, M_SLIDE_CUR,
    M_PWM, M_PWM_PHASE, M_PWM_BASE, M_TREM, M_TREM_PHASE, M_SWEEP,
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
comptime T_ETIME = 24        # echo time in 50 Hz ticks
comptime T_EFB = 25          # echo feedback, 0..15
comptime T_DELAY = 26        # the delay lines: 2 * SAMPLE_RATE floats, L then R
comptime T_DELAY_POS = 27    # write head, 0..SAMPLE_RATE-1
comptime T_ESCRATCH = 28     # the span's summed echo sends, TRIO_SPAN floats
comptime T_ECHO_USED = 29    # set the first time any send goes live; while
                             # zero the echo pass is skipped ENTIRELY, which
                             # is what keeps CT0's equality untouched
comptime T_PLAYHEAD = 30     # PUBLISHED schedule position -- the sync track's
                             # needle, release-stored by the renderer, acquire-
                             # loaded by whoever draws. Loop wraps rewind it,
                             # which is exactly what a beat lookup wants.
comptime T_SCOPE = 31        # the oscilloscope ring: SCOPE_FRAMES stereo pairs
comptime T_SCOPE_POS = 32    # frames ever written, release-stored after the
                             # samples they cover -- the ring's write head is
                             # this modulo SCOPE_FRAMES
comptime TRIO_SLOTS = 40

comptime SCOPE_FRAMES = 2048
"""About 43 ms of mix in the window -- two full cycles of a bass A, which
is what an oscilloscope needs to look like an oscilloscope."""


# ── the SPSC discipline, the deck's own ─────────────────────────────────────
#
# One writer, one reader, no lock: the renderer release-stores a counter
# AFTER the payload it covers, the reader acquire-loads it BEFORE reading
# the payload. Same pair as the deck's trigger ring, for the same reason --
# the ordering rides the two accesses that need it, not the thread.


@always_inline
fn tget_acquire(t: P, slot: Int) -> Int:
    """Acquire-load a counter the render thread writes."""
    return Atomic[Int].load[ordering = Ordering.ACQUIRE](
        t.unsafe_bitcast[Int]() + slot
    )


@always_inline
fn tput_release(t: P, slot: Int, value: Int):
    """Release-store a counter the render thread owns."""
    Atomic[Int].store[ordering = Ordering.RELEASE](
        t.unsafe_bitcast[Int]() + slot, value
    )


fn trio_playhead(t: P) -> Int:
    """Where the tune IS, in samples, from any thread. A binary search of
    the schedule at this position names the note that is sounding, which
    is the whole sync story: no message, no estimate, no drift."""
    return tget_acquire(t, T_PLAYHEAD)


fn trio_voice_level(t: P, chip: Int, voice: Int) -> Int:
    """A voice's envelope, 0..255, racily and on purpose: it feeds a VU
    bar, a torn read is one frame of flicker, and a lock here would be a
    price with no goods. Only ever read it for display."""
    var v = voice
    if v < 0:
        v = 0
    elif v > 2:
        v = 2
    return vget(trio_chip(t, chip), v, V_ENV) >> 16


fn trio_scope_read(
    t: P, out_buf: Pointer[Float32, MutUntrackedOrigin], frames: Int
) -> Int:
    """Copy the newest `frames` stereo pairs of the mix, oldest first.
    Returns how many were real; the reader's buffer is its own."""
    var want = frames
    if want > SCOPE_FRAMES:
        want = SCOPE_FRAMES
    let written = tget_acquire(t, T_SCOPE_POS)
    var have = want
    if written < have:
        have = written
    let ring = Pointer[Float32, MutUntrackedOrigin](
        unsafe_from_address=get(t, T_SCOPE))
    for i in range(have):
        let src = ((written - have + i) % SCOPE_FRAMES) * 2
        out_buf[unsafe_offset=i * 2] = ring[unsafe_offset=src]
        out_buf[unsafe_offset=i * 2 + 1] = ring[unsafe_offset=src + 1]
    return have

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
    # The echo's memory, all of it, before any callback exists: two delay
    # lines a second long and the span's send bus.
    let delay = external_call["calloc", P](Int(2 * SAMPLE_RATE), Int(4))
    if Int(delay) == 0:
        raise Error("trio: no delay line")
    put(t, T_DELAY, Int(delay))
    let ebus = external_call["calloc", P](Int(TRIO_SPAN), Int(4))
    if Int(ebus) == 0:
        raise Error("trio: no echo bus")
    put(t, T_ESCRATCH, Int(ebus))
    put(t, T_ETIME, 15)          # 300 ms and gentle, until a tune says
    put(t, T_EFB, 6)
    let ring = external_call["calloc", P](Int(SCOPE_FRAMES * 2), Int(4))
    if Int(ring) == 0:
        raise Error("trio: no scope ring")
    put(t, T_SCOPE, Int(ring))
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
    _ = external_call["free", NoneType](
        P(unsafe_from_address=get(t, T_DELAY))
    )
    _ = external_call["free", NoneType](
        P(unsafe_from_address=get(t, T_ESCRATCH))
    )
    _ = external_call["free", NoneType](
        P(unsafe_from_address=get(t, T_SCOPE))
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
    # A new tune states its own sound: the sends come up off, the delay
    # lines come up silent, and whatever the last tune left ringing dies
    # with it. (Loop wraps within ONE tune keep their tail on purpose.)
    for c in range(3):
        put(t, T_ECHO_SEND + c, 0)
    put(t, T_ECHO_USED, 0)
    put(t, T_DELAY_POS, 0)
    let dl = Pointer[Float32, MutUntrackedOrigin](
        unsafe_from_address=get(t, T_DELAY))
    for i in range(2 * SAMPLE_RATE):
        dl[unsafe_offset=i] = Float32(0.0)
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


# ── the 50 Hz performance layer (CT2) ───────────────────────────────────────
#
# This is where the chiptune lives: not in the notes but in the registers
# being poked fifty times a second. The engine runs as the chips' tick --
# chip_render calls it at every frame boundary -- and it touches NOTHING
# whose macro is off. That restraint is a proof obligation, not a nicety:
# a macro-free tune must render bit-identically to the silent tick, and
# test_trio holds the trio to that.


@always_inline
fn isin64(phase: Int) -> Int:
    """Integer sine, 64 steps a cycle, -127..127: Bhaskara's parabola on a
    quarter wave. No table, so nothing had to be allocated or copied into
    every chip; smooth enough for a wobble, and exactly reproducible."""
    let x = phase & 63
    let h = x & 31
    let v = 127 * h * (32 - h) // 256
    return v if x < 32 else -v


@always_inline
fn _hz(midi: Float64) -> Float64:
    """Equal temperament from A4 = 440, for FRACTIONAL notes -- vibrato and
    slides live between the semitones."""
    return 440.0 * exp2((midi - 69.0) / 12.0)


fn trio_macro_tick(st: P):
    """One chip's macros, one 50 Hz frame. Audio-thread rules throughout."""
    for v in range(3):
        # ── pitch: arp, then slide, then vibrato, in that order ─────────
        # Arp picks the note, slide approaches it, vibrato wobbles the
        # approach. Only runs when a pitch macro is on AND a note is held.
        let arp = get(st, macro_slot(v, M_ARP))
        let vib = get(st, macro_slot(v, M_VIB))
        let slide = get(st, macro_slot(v, M_SLIDE))
        let midi = get(st, PLAYER_BASE + SC_VOICE_NOTE + v)
        if midi >= 0 and (arp != 0 or (vib & 255) != 0 or slide != 0):
            var target = Float64(midi)
            if arp != 0:
                let count = arp >> 32
                let pos = get(st, macro_slot(v, M_ARP_POS))
                target += Float64((arp >> (4 * (pos % count))) & 15)
                put(st, macro_slot(v, M_ARP_POS), pos + 1)
            var cur = fget(st, macro_slot(v, M_SLIDE_CUR))
            if slide == 0 or cur == 0.0:
                cur = target
            else:
                let step = Float64(slide) / 16.0
                if cur < target:
                    cur += step
                    if cur > target:
                        cur = target
                elif cur > target:
                    cur -= step
                    if cur < target:
                        cur = target
            fput(st, macro_slot(v, M_SLIDE_CUR), cur)
            var eff = cur
            if (vib & 255) != 0:
                let ph = get(st, macro_slot(v, M_VIB_PHASE)) + (vib & 255)
                put(st, macro_slot(v, M_VIB_PHASE), ph)
                eff += Float64((vib >> 8) & 255) * Float64(isin64(ph)) \
                    / (127.0 * 16.0)
            set_freq_hz(st, v, _hz(eff))

        # ── pulse width breathes even through the release ───────────────
        let pwm = get(st, macro_slot(v, M_PWM))
        if (pwm & 255) != 0:
            let ph = get(st, macro_slot(v, M_PWM_PHASE)) + (pwm & 255)
            put(st, macro_slot(v, M_PWM_PHASE), ph)
            # A triangle, the classic shape: depth is in eighths of the
            # 12-bit range, so pwm=64/2 swings the width by +-512.
            let tp = ph & 127
            var tri = tp - 64
            if tri < 0:
                tri = -tri
            tri -= 32
            var pw = get(st, macro_slot(v, M_PWM_BASE)) \
                + ((pwm >> 8) & 255) * tri // 4
            if pw < 16:
                pw = 16
            elif pw > 4080:
                pw = 4080
            set_pulse_width(st, v, pw)

        # ── tremolo dips the sustain target, and only that ──────────────
        # Notes in attack or decay pass unwobbled; the SID had no per-voice
        # volume either, and this is the honest equivalent.
        let trem = get(st, macro_slot(v, M_TREM))
        if (trem & 255) != 0:
            let ph = get(st, macro_slot(v, M_TREM_PHASE)) + (trem & 255)
            put(st, macro_slot(v, M_TREM_PHASE), ph)
            let s_rec = get(st, PLAYER_BASE + CHIP_ADSR + v * 4 + 2)
            var eff_s = s_rec * 17 \
                - ((trem >> 8) & 255) * (127 + isin64(ph)) // 254
            if eff_s < 0:
                eff_s = 0
            elif eff_s > 255:
                eff_s = 255
            vput(st, v, V_SUS, eff_s)

    # ── the chip-level filter sweep ─────────────────────────────────────
    let sw = get(st, PLAYER_BASE + MACRO_BASE + M_SWEEP)
    if sw != 0:
        var c = get(st, S_CUTOFF) + sw
        if c < 0:
            c = 0
        elif c > 2047:
            c = 2047
        set_filter(st, c, get(st, S_RES), get(st, S_FMODE))


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
                    if (value & 15) != 0:
                        put(t, T_ECHO_USED, 1)
                elif param == CP_ETIME:
                    put(t, T_ETIME, value)
                elif param == CP_EFB:
                    put(t, T_EFB, value & 15)
                else:
                    apply_chip(trio_chip(t, c), sub, param, value)
            elif kind == SE_NOTE_ON:
                let st = trio_chip(t, _chip_for_abc_voice(voice))
                let midi = sched[unsafe_offset=at + 3]
                apply_note_on(st, midi, sched[unsafe_offset=at + 4])
                # apply_note_on jumps straight to the note's own pitch. A
                # voice with a slide should APPROACH it instead -- from
                # wherever its last note left off -- so put the frequency
                # back where the glide stands; the next tick moves it.
                for v in range(3):
                    if get(st, PLAYER_BASE + SC_VOICE_NOTE + v) != midi:
                        continue
                    let cur = fget(st, macro_slot(v, M_SLIDE_CUR))
                    if get(st, macro_slot(v, M_SLIDE)) != 0 and cur != 0.0:
                        set_freq_hz(st, v, _hz(cur))
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

        let echo_on = get(t, T_ECHO_USED) != 0
        let ebus = Pointer[Float32, MutUntrackedOrigin](
            unsafe_from_address=get(t, T_ESCRATCH))
        if echo_on:
            for i in range(span):
                ebus[unsafe_offset=i] = Float32(0.0)

        for c in range(3):
            chip_render(trio_chip(t, c), scratch, span, trio_macro_tick)
            let gl = Float64(get(t, T_GAIN_L + c)) / 256.0 * master
            let gr = Float64(get(t, T_GAIN_R + c)) / 256.0 * master
            let send = Float64(get(t, T_ECHO_SEND + c)) / 16.0
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
                if send > 0.0:
                    ebus[unsafe_offset=i] = Float32(
                        Float64(ebus[unsafe_offset=i]) + s * send)

        if echo_on:
            # Ping-pong: the bus enters the left line, the left line's
            # output feeds the right, the right's feeds the left. First
            # tap left, second right, and every repeat quieter by fb --
            # which is at most 15/16, so the ring is a geometric series
            # and the ceiling is arithmetic, not hope.
            let dl = Pointer[Float32, MutUntrackedOrigin](
                unsafe_from_address=get(t, T_DELAY))
            var dtime = get(t, T_ETIME)
            if dtime < 1:
                dtime = 1
            elif dtime > 50:
                dtime = 50
            dtime *= FRAME_SAMPLES
            let fb = Float64(get(t, T_EFB) & 15) / 16.0
            var wp = get(t, T_DELAY_POS)
            for i in range(span):
                var rp = wp - dtime
                if rp < 0:
                    rp += SAMPLE_RATE
                let outl = Float64(dl[unsafe_offset=rp])
                let outr = Float64(dl[unsafe_offset=SAMPLE_RATE + rp])
                dl[unsafe_offset=wp] = Float32(
                    Float64(ebus[unsafe_offset=i]) + outr * fb)
                dl[unsafe_offset=SAMPLE_RATE + wp] = Float32(outl * fb)
                let o = (filled + i) * 2
                var l = Float64(dest[unsafe_offset=o]) + outl * master
                var r = Float64(dest[unsafe_offset=o + 1]) + outr * master
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
                wp += 1
                if wp >= SAMPLE_RATE:
                    wp = 0
            put(t, T_DELAY_POS, wp)

        # The span's mix is finished: copy it into the scope ring, THEN
        # publish how far the ring reaches, then where the tune stands.
        let ring = Pointer[Float32, MutUntrackedOrigin](
            unsafe_from_address=get(t, T_SCOPE))
        var wrote = get(t, T_SCOPE_POS)
        for i in range(span):
            let dst = (wrote % SCOPE_FRAMES) * 2
            let o = (filled + i) * 2
            ring[unsafe_offset=dst] = dest[unsafe_offset=o]
            ring[unsafe_offset=dst + 1] = dest[unsafe_offset=o + 1]
            wrote += 1
        tput_release(t, T_SCOPE_POS, wrote)

        filled += span
        put(t, T_SAMPLE, now + span)
        tput_release(t, T_PLAYHEAD, now + span)

        if cursor >= count and get(t, T_SAMPLE) > get(t, T_END):
            if get(t, T_LOOP) != 0:
                put(t, T_CURSOR, 0)
                put(t, T_SAMPLE, 0)
                tput_release(t, T_PLAYHEAD, 0)
                for c in range(3):
                    let st = trio_chip(t, c)
                    for v in range(3):
                        put(st, PLAYER_BASE + SC_VOICE_NOTE + v, -1)
                        gate_off(st, v)
            else:
                put(t, T_DONE, 1)
