# Playing a schedule through the chip, sample by sample.
#
# The chip in examples/chip/ is a synthesiser with three voices and no idea
# what a tune is. This is what tells it: a flat array of "at sample N, start
# note M" that the render callback walks as it fills the buffer.
#
# The buffer is filled in spans between events rather than in one go. If a
# note begins 137 samples into a 512-sample buffer, the first 137 samples are
# rendered, the note is started, and the remaining 375 are rendered after --
# so the note begins on sample 137 and not at the buffer boundary. That is the
# whole difference between sample-accurate and buffer-accurate timing, and it
# costs one loop.
#
# Everything here runs on the audio thread, so the schedule is a plain block
# of memory rather than a List: allocated once, before the unit starts, and
# never resized.

from std.memory import Pointer, MutUntrackedOrigin, OpaquePointer
from std.ffi import external_call

from gamepane.api.audio import (
    P, get, put, vget, vput, chip_render, set_freq_hz, set_wave, set_adsr,
    set_filter, set_volume, set_pulse_width, gate_on, gate_off, route_filter,
    PLAYER_BASE, S_CUTOFF, S_RES, S_FMODE, V_ENV, V_PHASE, V_PW, V_WAVE,
    WAVE_PCM, V_ACC, V_PCM_PTR, V_PCM_LEN, V_PCM_LOOP_START, V_PCM_LOOP_LEN,
    ENV_IDLE,
    ENV_RELEASE, WAVE_PULSE, WAVE_SAW, WAVE_TRI, Tick,
)
from gamepane.abc.schedule import Step, SE_NOTE_ON, SE_NOTE_OFF, SE_CHIP
from gamepane.abc.model import (
    CP_WAVE, CP_PW, CP_A, CP_D, CP_S, CP_R, CP_FILT,
    CP_CUTOFF, CP_RES, CP_FMODE, CP_VOL,
    CP_PAN, CP_ECHO, CP_ETIME, CP_EFB,
    CP_ARP, CP_VIB, CP_SLIDE, CP_PWM, CP_SWEEP, CP_TREM,
    CP_PCM_OFFSET, CP_PCM_PTR, CP_PCM_LEN, CP_PCM_LOOP_START, CP_PCM_LOOP_LEN,
)

# Slots in the chip's player region. The chip example's own player does not
# run here -- this is a different way to drive the same chip -- so the whole
# region is free.
comptime SC_ADDR = 0          # address of the flattened schedule
comptime SC_COUNT = 1         # how many steps it holds
comptime SC_CURSOR = 2        # the next step to apply
comptime SC_SAMPLE = 3        # absolute sample position
comptime SC_END = 4           # sample at which the tune finishes
comptime SC_LOOP = 5
comptime SC_PAUSE = 6
comptime SC_DONE = 7
comptime SC_SCOPE = 8
comptime SC_SCOPE_POS = 9
comptime SC_VOICE_NOTE = 16   # three slots: the note each chip voice holds
comptime SC_VOICE_AGE = 20    # three slots: when it was struck

comptime STEP_SLOTS = 5
comptime SCOPE_LEN = 1024


def flatten_schedule(steps: List[Step], mut st: P) -> Int:
    """Copy the schedule into plain memory the audio thread can walk."""
    let n = len(steps)
    let addr = Int(external_call["calloc", P](Int(n * STEP_SLOTS + 8), Int(8)))
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
    put(st, PLAYER_BASE + SC_ADDR, addr)
    put(st, PLAYER_BASE + SC_COUNT, n)
    put(st, PLAYER_BASE + SC_CURSOR, 0)
    put(st, PLAYER_BASE + SC_SAMPLE, 0)
    put(st, PLAYER_BASE + SC_END, last + 48000)   # a second of tail
    for v in range(3):
        put(st, PLAYER_BASE + SC_VOICE_NOTE + v, -1)
        put(st, PLAYER_BASE + SC_VOICE_AGE + v, 0)
    return addr


@always_inline
fn midi_to_hz(note: Int) -> Float64:
    """Equal temperament, by octave and a twelve-way table.

    Clamped, because this runs on the audio thread and the octave loop below
    is a loop: a nonsense note would be a hang, not a wrong pitch.
    """
    var n = note
    if n < 0:
        n = 0
    elif n > 127:
        n = 127
    let offset = n - 69
    var octave = offset // 12
    let semi = offset - octave * 12
    var hz = 440.0
    if semi == 1: hz = 466.1637615180899
    elif semi == 2: hz = 493.8833012561241
    elif semi == 3: hz = 523.2511306011972
    elif semi == 4: hz = 554.3652619537442
    elif semi == 5: hz = 587.3295358348151
    elif semi == 6: hz = 622.2539674441618
    elif semi == 7: hz = 659.2551138257398
    elif semi == 8: hz = 698.4564628660078
    elif semi == 9: hz = 739.9888454232688
    elif semi == 10: hz = 783.990871963500
    elif semi == 11: hz = 830.6093951598903
    while octave > 0:
        hz *= 2.0
        octave -= 1
    while octave < 0:
        hz *= 0.5
        octave += 1
    return hz


@always_inline
fn apply_note_on(st: P, midi: Int, velocity: Int):
    """Give the note a chip voice.

    Three voices and a tune that may want more, so something has to give when
    they are all busy. A voice whose envelope has finished is free; failing
    that the oldest sounding note is taken, because it is the one furthest
    through its decay and the least missed.
    """
    var chosen = -1
    for v in range(3):
        if get(st, PLAYER_BASE + SC_VOICE_NOTE + v) < 0:
            chosen = v
            break
    if chosen < 0:
        for v in range(3):
            if vget(st, v, V_PHASE) == ENV_IDLE:
                chosen = v
                break
    if chosen < 0:
        var oldest = get(st, PLAYER_BASE + SC_VOICE_AGE)
        chosen = 0
        for v in range(1, 3):
            let age = get(st, PLAYER_BASE + SC_VOICE_AGE + v)
            if age < oldest:
                oldest = age
                chosen = v

    put(st, PLAYER_BASE + SC_VOICE_NOTE + chosen, midi)
    put(st, PLAYER_BASE + SC_VOICE_AGE + chosen,
        get(st, PLAYER_BASE + SC_SAMPLE))
    set_freq_hz(st, chosen, midi_to_hz(midi))
    if vget(st, chosen, V_WAVE) == WAVE_PCM:
        # Phase continuity is right for a periodic wave -- restarting a
        # saw's cycle on every note would click. It is wrong for a
        # sample: a new note means the beginning of the recording.
        vput(st, chosen, V_ACC, 0)
    gate_on(st, chosen)


@always_inline
fn apply_note_off(st: P, midi: Int):
    """Release whichever voice is holding this note."""
    for v in range(3):
        if get(st, PLAYER_BASE + SC_VOICE_NOTE + v) == midi:
            put(st, PLAYER_BASE + SC_VOICE_NOTE + v, -1)
            gate_off(st, v)
            return


@always_inline
fn apply_chip(st: P, voice: Int, param: Int, value: Int):
    """One register change, on the audio thread.

    No allocation and nothing that can raise: this is the same contract the
    note events keep, because it runs from the same place they do. The ADSR
    setters recompute increments, which is arithmetic and nothing more.
    """
    if param == CP_CUTOFF:
        set_filter(st, value, get(st, S_RES), get(st, S_FMODE))
        return
    if param == CP_RES:
        set_filter(st, get(st, S_CUTOFF), value, get(st, S_FMODE))
        return
    if param == CP_FMODE:
        set_filter(st, get(st, S_CUTOFF), get(st, S_RES), value)
        return
    if param == CP_VOL:
        set_volume(st, value)
        return
    if param == CP_PAN or param == CP_ECHO or param == CP_ETIME \
            or param == CP_EFB:
        # Trio-level. The trio walker intercepts these before delegating;
        # a bare chip hearing one has nowhere to put it, and says nothing.
        return
    if param == CP_SWEEP:
        # Stored unbiased: the wire carries rate+1024 past the parser's
        # non-negative gate, the register holds the truth.
        put(st, PLAYER_BASE + MACRO_BASE + M_SWEEP, value - 1024)
        return
    if param == CP_PCM_OFFSET:
        # Only reaches here if something calls apply_chip directly,
        # bypassing the trio -- meaningless without T_PCM_ADDR, so a bare
        # chip says nothing, exactly like CP_PAN and the echo family.
        return

    if voice < 0 or voice > 2:
        return
    if param == CP_PCM_PTR:
        vput(st, voice, V_PCM_PTR, value)
        return
    if param == CP_PCM_LEN:
        vput(st, voice, V_PCM_LEN, value)
        return
    if param == CP_PCM_LOOP_START:
        vput(st, voice, V_PCM_LOOP_START, value)
        return
    if param == CP_PCM_LOOP_LEN:
        vput(st, voice, V_PCM_LOOP_LEN, value)
        return
    if param == CP_ARP:
        put(st, macro_slot(voice, M_ARP), value)
        put(st, macro_slot(voice, M_ARP_POS), 0)
        return
    if param == CP_VIB:
        put(st, macro_slot(voice, M_VIB), value)
        put(st, macro_slot(voice, M_VIB_PHASE), 0)
        return
    if param == CP_SLIDE:
        put(st, macro_slot(voice, M_SLIDE), value)
        return
    if param == CP_PWM:
        put(st, macro_slot(voice, M_PWM), value)
        put(st, macro_slot(voice, M_PWM_PHASE), 0)
        put(st, macro_slot(voice, M_PWM_BASE), vget(st, voice, V_PW))
        return
    if param == CP_TREM:
        put(st, macro_slot(voice, M_TREM), value)
        put(st, macro_slot(voice, M_TREM_PHASE), 0)
        return
    if param == CP_WAVE:
        set_wave(st, voice, value)
    elif param == CP_PW:
        set_pulse_width(st, voice, value)
    elif param == CP_FILT:
        route_filter(st, voice, value != 0)
    else:
        let b = PLAYER_BASE + CHIP_ADSR + voice * 4
        var a = get(st, b + 0)
        var d = get(st, b + 1)
        var sus = get(st, b + 2)
        var r = get(st, b + 3)
        if param == CP_A:
            a = value
        elif param == CP_D:
            d = value
        elif param == CP_S:
            sus = value
        elif param == CP_R:
            r = value
        set_adsr(st, voice, a, d, sus, r)
        record_adsr(st, voice, a, d, sus, r)


comptime CHIP_ADSR = 40      # 12 slots: voice * 4 + {a, d, s, r}

# ── the macro region (CT1 stores, CT2 plays) ────────────────────────────
#
# Per voice, MACRO_STRIDE slots from MACRO_BASE. A packed value of zero is
# off in every case, which is what lets calloc'd chips be macro-silent.
# Slide keeps the CURRENT pitch as a float across notes -- that carry-over
# from the previous note IS portamento, not an accident of state.

comptime MACRO_BASE = 64      # PLAYER_BASE-relative, after CHIP_ADSR
comptime MACRO_STRIDE = 12
comptime M_ARP = 0            # count<<32 | nibbles, first digit lowest
comptime M_ARP_POS = 1
comptime M_VIB = 2            # depth<<8 | rate; rate 0 is off
comptime M_VIB_PHASE = 3
comptime M_SLIDE = 4          # 16ths of a semitone per tick; 0 snaps
comptime M_SLIDE_CUR = 5      # float: current fractional MIDI pitch
comptime M_PWM = 6            # depth<<8 | rate
comptime M_PWM_PHASE = 7
comptime M_PWM_BASE = 8       # the pulse width the sweep breathes around
comptime M_TREM = 9           # depth<<8 | rate
comptime M_TREM_PHASE = 10
comptime M_SWEEP = 44         # chip-level, one slot past the three voices:
                              # signed cutoff slew per tick (stored unbiased)


@always_inline
fn macro_slot(voice: Int, m: Int) -> Int:
    return PLAYER_BASE + MACRO_BASE + voice * MACRO_STRIDE + m


@always_inline
fn record_adsr(st: P, voice: Int, a: Int, d: Int, sus: Int, r: Int):
    """Remember the four nibbles a set_adsr was given.

    set_adsr turns them into 16.16 increments through a period-stretching
    ladder, and that is not invertible -- so changing only the decay later
    means keeping the other three somewhere. They live in the player region
    where the audio thread can read them without a lock.
    """
    let b = PLAYER_BASE + CHIP_ADSR + voice * 4
    put(st, b + 0, a)
    put(st, b + 1, d)
    put(st, b + 2, sus)
    put(st, b + 3, r)


fn silent_tick(st: P) -> None:
    """The chip's own player routine, doing nothing.

    The schedule drives the notes here, so the 50 Hz routine has no work --
    but the chip still calls it, and a null function pointer would not do.
    """
    pass


fn render_scheduled(
    st: P, dest: Pointer[Float32, MutUntrackedOrigin], frames: Int
):
    """Fill one buffer, applying every event that falls inside it.

    Runs on the audio thread. No allocation, no locks, and no call that could
    raise: the schedule was flattened into plain memory before the unit was
    started, and this only reads it.
    """
    let addr = get(st, PLAYER_BASE + SC_ADDR)
    if addr == 0:
        for i in range(frames):
            dest[unsafe_offset=i] = Float32(0.0)
        return
    let sched = Pointer[Int, MutUntrackedOrigin](unsafe_from_address=addr)
    let count = get(st, PLAYER_BASE + SC_COUNT)

    var filled = 0
    while filled < frames:
        var cursor = get(st, PLAYER_BASE + SC_CURSOR)
        let now = get(st, PLAYER_BASE + SC_SAMPLE)

        # Everything due at this exact sample happens before another sample
        # is rendered.
        while cursor < count:
            let at = cursor * STEP_SLOTS
            if sched[unsafe_offset=at] > now:
                break
            if sched[unsafe_offset=at + 1] == SE_CHIP:
                apply_chip(
                    st,
                    sched[unsafe_offset=at + 2],
                    sched[unsafe_offset=at + 3],
                    sched[unsafe_offset=at + 4],
                )
            elif sched[unsafe_offset=at + 1] == SE_NOTE_ON:
                apply_note_on(
                    st, sched[unsafe_offset=at + 3], sched[unsafe_offset=at + 4]
                )
            else:
                apply_note_off(st, sched[unsafe_offset=at + 3])
            cursor += 1
        put(st, PLAYER_BASE + SC_CURSOR, cursor)

        # Render as far as the next event, or to the end of the buffer.
        var span = frames - filled
        if cursor < count:
            let next = sched[unsafe_offset=cursor * STEP_SLOTS] - now
            if next < span:
                span = next
        if span < 1:
            span = 1

        chip_render(
            st,
            Pointer[Float32, MutUntrackedOrigin](
                unsafe_from_address=Int(dest) + filled * 4
            ),
            span,
            silent_tick,
        )
        filled += span
        put(st, PLAYER_BASE + SC_SAMPLE, now + span)

        # Round again at the end.
        if cursor >= count and get(st, PLAYER_BASE + SC_SAMPLE) > get(
            st, PLAYER_BASE + SC_END
        ):
            if get(st, PLAYER_BASE + SC_LOOP) != 0:
                put(st, PLAYER_BASE + SC_CURSOR, 0)
                put(st, PLAYER_BASE + SC_SAMPLE, 0)
                for v in range(3):
                    put(st, PLAYER_BASE + SC_VOICE_NOTE + v, -1)
                    gate_off(st, v)
            else:
                put(st, PLAYER_BASE + SC_DONE, 1)
