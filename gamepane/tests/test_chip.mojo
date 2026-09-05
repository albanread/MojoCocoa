# ===----------------------------------------------------------------------=== #
# Sprint G7, piece 1 — the chip, lifted into the package, with the four
# rough edges the review found fixed and a test apiece.
#
# The chip is integer arithmetic with a fixed LFSR seed, so every one of
# these is exactly reproducible: no tolerance, no "about right".
#
# Run: ./tools/gp.sh gamepane/tests/test_chip.mojo
# ===----------------------------------------------------------------------=== #

from std.memory import Pointer

from gamepane.api import (
    P, SAMPLE_RATE, FRAME_SAMPLES,
    WAVE_TRI, WAVE_SAW, WAVE_PULSE, WAVE_NOISE,
    FILT_LP, FILT_BP, FILT_HP,
    chip_new, chip_free, chip_render,
    set_freq_hz, set_wave, set_adsr, gate_on, gate_off,
    set_filter, route_filter, set_volume,
    get, fget, vget, vput,
    S_CUTOFF, S_FMODE, S_LOW, S_BAND,
    V_WAVE, V_SYNC, V_ACC, V_STEP, V_PREV,
)


fn no_tick(st: P):
    """The chip calls a player routine every 50 Hz frame; these tests drive
    the registers themselves, so theirs does nothing."""
    pass


def render(st: P, n: Int) raises -> List[Float32]:
    """`n` samples into a fresh buffer, with no player hook."""
    var buf = List[Float32](length=n, fill=0.0)
    chip_render(
        st,
        Pointer[Float32, MutUntrackedOrigin](
            unsafe_from_address=Int(buf.unsafe_ptr())
        ),
        n,
        no_tick,
    )
    return buf^


def main() raises:
    var failures = 0

    # ── 1. the cutoff clamps rather than wrapping ────────────────────────
    # A sweep that runs off the top of the range used to wrap to 0, so an
    # effect that opens up ended in a thud -- and the register read back
    # perfectly reasonable afterwards.
    var st = chip_new()
    set_filter(st, 2048, 0, FILT_LP)
    if get(st, S_CUTOFF) != 0x7FF:
        print("FAIL  cutoff 2048 became", get(st, S_CUTOFF), "want 2047")
        failures += 1
    set_filter(st, 5000, 0, FILT_LP)
    if get(st, S_CUTOFF) != 0x7FF:
        print("FAIL  cutoff 5000 became", get(st, S_CUTOFF))
        failures += 1
    set_filter(st, -10, 0, FILT_LP)
    if get(st, S_CUTOFF) != 0:
        print("FAIL  a negative cutoff became", get(st, S_CUTOFF))
        failures += 1
    else:
        print("ok    the cutoff clamps at both ends; a sweep cannot wrap")

    # A sweep that walks past the top must never get QUIETER as it opens.
    # That is the audible form of the bug: 2047 is wide open, 2048 was shut.
    set_volume(st, 15)
    set_freq_hz(st, 0, 220.0)
    set_wave(st, 0, WAVE_SAW)
    set_adsr(st, 0, 0, 0, 15, 0)
    route_filter(st, 0, True)
    gate_on(st, 0)
    _ = render(st, FRAME_SAMPLES)
    var at_2047 = 0.0
    var at_2500 = 0.0
    set_filter(st, 2047, 0, FILT_LP)
    var b = render(st, FRAME_SAMPLES)
    for i in range(len(b)):
        at_2047 += abs(Float64(b[i]))
    set_filter(st, 2500, 0, FILT_LP)
    b = render(st, FRAME_SAMPLES)
    for i in range(len(b)):
        at_2500 += abs(Float64(b[i]))
    if at_2500 < at_2047 * 0.5:
        print("FAIL  sweeping past the top shut the filter:",
              at_2047, "->", at_2500)
        failures += 1
    else:
        print("ok    sweeping past the top stays open, it does not thud")
    chip_free(st)

    # ── 2. set_wave masks like every other register setter ───────────────
    st = chip_new()
    set_wave(st, 0, WAVE_TRI | 0x70)
    if vget(st, voice=0, field=V_WAVE) != WAVE_TRI:
        print("FAIL  set_wave stored", vget(st, voice=0, field=V_WAVE),
              "want", WAVE_TRI)
        failures += 1
    else:
        print("ok    set_wave keeps only the four waveform bits")
    chip_free(st)

    # ── 3. the high-pass tap is finite after the state resets ────────────
    # A state-variable filter is only conditionally stable. Left alone the
    # state diverges to NaN, and `high` -- computed BEFORE the reset -- went
    # straight to the output in HP mode. The output clamp cannot catch it:
    # every comparison against NaN is false, so a NaN Float32 reached the
    # audio device and the synth was silent for good.
    st = chip_new()
    set_volume(st, 15)
    set_freq_hz(st, 0, 440.0)
    set_wave(st, 0, WAVE_SAW)
    set_adsr(st, 0, 0, 0, 15, 0)
    route_filter(st, 0, True)
    set_filter(st, 2047, 15, FILT_HP)
    gate_on(st, 0)
    # Poison the state with an actual NaN, not merely a huge number.
    #
    # That distinction is the whole finding. A DIVERGING filter reaches
    # +/-inf, and inf is handled: the output clamp catches it, because
    # `value < -1.0` is true for -inf. Only NaN slips through, because every
    # comparison against NaN is false and `value` passes both branches
    # untouched. And inside `chip_render` the state can never ARRIVE NaN --
    # the reset at the bottom of the previous sample cleared it. So this is
    # defence in depth against a state poisoned from outside, which is
    # exactly what the next line does and what a debugger or a stray
    # register write could do too.
    from gamepane.api import fput
    let huge = 1.0e308
    let inf = huge * 10.0
    let poison = inf - inf
    fput(st, S_LOW, poison)
    fput(st, S_BAND, poison)
    var out = render(st, 512)
    var bad = 0
    for i in range(len(out)):
        let v = Float64(out[i])
        if v != v or v > 1.0 or v < -1.0:
            bad += 1
    if bad != 0:
        print("FAIL ", bad, "of", len(out), "samples were NaN or out of range")
        failures += 1
    else:
        print("ok    a diverged filter recovers; no NaN reaches the output")
    # And it really did recover -- the voice is audible again afterwards.
    out = render(st, 512)
    var energy = 0.0
    for i in range(len(out)):
        energy += abs(Float64(out[i]))
    if energy <= 0.0:
        print("FAIL  the chip stayed silent after the reset")
        failures += 1
    else:
        print("ok    and the voice is audible again, not silent for good")
    chip_free(st)

    # ── 4. all three oscillators advance together ────────────────────────
    # Sync is a ring -- 1 syncs to 0, 2 to 1, 0 to 2 -- so there is no order
    # in which every source is already current. Advancing inside the voice
    # loop meant voices 1 and 2 saw a source that had moved this sample
    # while voice 0 saw one that had not, and voice 0's sync fired a sample
    # late. Symmetry is the test: with identical settings, the pair (0 <- 2)
    # must behave exactly as the pair (1 <- 0).
    def sync_pair(master: Int, slave: Int) raises -> List[Float32]:
        var c = chip_new()
        set_volume(c, 15)
        # The master runs slow, the slave fast: the slave's reset is then
        # frequent and plainly audible in the waveform.
        set_freq_hz(c, master, 110.0)
        set_wave(c, master, WAVE_TRI)
        set_adsr(c, master, 0, 0, 15, 0)
        set_freq_hz(c, slave, 1234.0)
        set_wave(c, slave, WAVE_SAW)
        set_adsr(c, slave, 0, 0, 15, 0)
        vput(c, voice=slave, field=V_SYNC, value=1)
        gate_on(c, master)
        gate_on(c, slave)
        var r = render(c, 2048)
        chip_free(c)
        return r^

    let a = sync_pair(2, 0)      # voice 0 syncs to voice 2
    let bb = sync_pair(0, 1)     # voice 1 syncs to voice 0
    var diff = 0
    for i in range(len(a)):
        if a[i] != bb[i]:
            diff += 1
    if diff != 0:
        print("FAIL ", diff, "of", len(a), "samples differ between the two")
        print("      sync pairs; voice 0's source is a sample stale")
        failures += 1
    else:
        print("ok    every voice syncs off the same generation")

    # ── the chip still sounds like the chip ──────────────────────────────
    # A plain note: not silent, in range, and centred -- the three ways a
    # rewrite of the render loop goes wrong without erroring.
    st = chip_new()
    set_volume(st, 15)
    set_freq_hz(st, 0, 440.0)
    set_wave(st, 0, WAVE_PULSE)
    set_adsr(st, 0, 0, 0, 15, 0)
    gate_on(st, 0)
    out = render(st, SAMPLE_RATE // 10)
    var peak = 0.0
    var sum = 0.0
    var nan = 0
    for i in range(len(out)):
        let v = Float64(out[i])
        if v != v:
            nan += 1
        if abs(v) > peak:
            peak = abs(v)
        sum += v
    let mean = sum / Float64(len(out))
    if nan != 0 or peak <= 0.01 or peak > 1.0 or abs(mean) > 0.35:
        print("FAIL  a plain note: peak", peak, "mean", mean, "nan", nan)
        failures += 1
    else:
        print("ok    a plain note is audible, in range and centred")
    gate_off(st, 0)
    chip_free(st)

    print()
    if failures == 0:
        print("G7 chip: PASS")
    else:
        print("G7 chip: FAILED", failures, "check(s)")
        raise Error("G7 chip failed")
