# ===----------------------------------------------------------------------=== #
# Sprint G7 — the audio deck: two chips, the trigger ring, the twelve
# effects, the voice bank and the WAV codec.
#
# The chip is integer arithmetic with a fixed LFSR seed, so a rendered
# effect is byte-identical every run. That is what makes a hash a real
# regression test here rather than a tolerance check.
#
# Run: ./tools/gp.sh gamepane/tests/test_audio.mojo
# ===----------------------------------------------------------------------=== #

from std.memory import Pointer

from gamepane.api import (
    P, SAMPLE_RATE, FRAME_SAMPLES, chip_new, chip_free, chip_render,
    SFX_COUNT, SFX_SAUCER, SFX_BOSS_HUM, SFX_ZAP, SFX_CLICK,
    sfx_name, sfx_frames, sfx_start, sfx_frame, sfx_stop,
    Instrument, midi_to_hz, set_instrument, note_on, note_off,
    is_voice_active, active_voices, allocate_voice,
    wav_bytes, read_wav, WAV_HEADER_BYTES,
    WAVE_PULSE, set_volume, vget, V_ENV,
)
from gamepane.metal import (
    deck_new, deck_free, music_chip, sfx_chip, sfx_play, pending_triggers,
    dropped_triggers, drain_triggers, advance_effects, RING_SIZE,
)


fn no_tick(st: P):
    pass


def render_effect(index: Int, frames: Int) raises -> List[Float32]:
    """One effect, offline, from a fresh chip -- the same arithmetic the
    audio thread runs, with no audio device involved."""
    var st = chip_new()
    set_volume(st, 15)
    sfx_start(st, 0, index)
    var out = List[Float32]()
    var buf = List[Float32](length=FRAME_SAMPLES, fill=0.0)
    let p = Pointer[Float32, MutUntrackedOrigin](
        unsafe_from_address=Int(buf.unsafe_ptr())
    )
    for f in range(frames):
        sfx_frame(st, 0, index, f)
        chip_render(st, p, FRAME_SAMPLES, no_tick)
        for i in range(FRAME_SAMPLES):
            out.append(buf[i])
    sfx_stop(st, 0, index)
    chip_free(st)
    return out^


def hash_of(s: Span[Float32, _]) -> Int:
    """FNV-1a over the 16-bit quantisation, so the hash is the audio a
    listener would get rather than the last bit of a float."""
    var h = 0xCBF29CE484222325
    for i in range(len(s)):
        var v = Float64(s[i])
        if v > 1.0:
            v = 1.0
        elif v < -1.0:
            v = -1.0
        var q = Int(v * 32767.0)
        if q < 0:
            q += 65536
        h = ((h ^ (q & 255)) * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
        h = ((h ^ ((q >> 8) & 255)) * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
    return h


def main() raises:
    var failures = 0

    # ── the trigger ring ─────────────────────────────────────────────────
    # 1,000 triggers, fired faster than the callback consumes them: none
    # lost, none applied twice. The ring holds 256, so this drains four
    # times over -- which is the point, since a ring that is never full
    # proves nothing about its wrap.
    var d = deck_new()
    var sent = 0
    var seen = 0
    var wrong = 0
    var expect = 0
    for round in range(5):
        for k in range(200):
            if sfx_play(d, k % SFX_COUNT):
                sent += 1
        # Drain by hand, counting: this is what the callback does.
        let before = pending_triggers(d)
        seen += before
        drain_triggers(d)
        if pending_triggers(d) != 0:
            wrong += 1
    if sent != 1000:
        print("FAIL  only", sent, "of 1000 triggers were accepted;",
              dropped_triggers(d), "dropped")
        failures += 1
    elif seen != 1000:
        print("FAIL  the callback saw", seen, "of 1000")
        failures += 1
    elif wrong != 0:
        print("FAIL  the ring did not drain fully", wrong, "times")
        failures += 1
    else:
        print("ok    1000 triggers through a", RING_SIZE,
              "slot ring: none lost, none twice")

    # A full ring refuses rather than overwriting -- losing the OLDEST
    # unplayed trigger silently would be worse than saying no.
    for k in range(RING_SIZE + 10):
        _ = sfx_play(d, 0)
    if dropped_triggers(d) != 10:
        print("FAIL  a full ring dropped", dropped_triggers(d), "want 10")
        failures += 1
    else:
        print("ok    a full ring refuses, and says how many it refused")
    drain_triggers(d)

    # ── every effect runs, and out of range is safe ───────────────────────
    var quiet = List[String]()
    for e in range(SFX_COUNT):
        let s = render_effect(e, sfx_frames(e))
        var peak = 0.0
        var nan = 0
        for i in range(len(s)):
            let v = Float64(s[i])
            if v != v:
                nan += 1
            if abs(v) > peak:
                peak = abs(v)
        if nan != 0 or peak > 1.0:
            print("FAIL ", sfx_name(e), "produced", nan, "NaN, peak", peak)
            failures += 1
        if peak < 0.01:
            quiet.append(sfx_name(e))
    if len(quiet) != 0:
        print("FAIL  silent effects:", len(quiet))
        for i in range(len(quiet)):
            print("      ", quiet[i])
        failures += 1
    else:
        print("ok    all", SFX_COUNT, "effects sound, in range, no NaN")

    # Out of range is a click, not a trap.
    var st = chip_new()
    sfx_start(st, 0, -5)
    sfx_frame(st, 0, -5, 0)
    sfx_stop(st, 0, -5)
    sfx_start(st, 0, 9999)
    sfx_stop(st, 0, 9999)
    chip_free(st)
    print("ok    an out-of-range effect index is safe")

    # ── saucer and boss_hum beat at their detune ─────────────────────────
    # The warble is not an LFO; it is two voices a few hertz apart. So the
    # envelope of the output must rise and fall at that difference, and
    # counting the peaks of the envelope is how you see it.
    def beats_per_second(index: Int, seconds: Float64) raises -> Float64:
        let s = render_effect(index, Int(seconds * 50.0))
        # Envelope: the MEAN absolute value over a 5 ms window, then count
        # upward crossings of its own mean.
        #
        # Mean, not peak. Two TRIANGLE waves a few hertz apart beat in
        # amplitude and a peak detector sees it plainly -- saucer shows six
        # clean cycles a second. Two PULSE waves do not: their sum only ever
        # takes three values, and the beat changes how much TIME it spends
        # at each rather than how large the largest gets, so a peak detector
        # reads a flat line and boss_hum looks like it has no beat at all.
        # The mean sees both.
        comptime WIN = 240      # 5 ms
        var env = List[Float64]()
        var i = 0
        while i + WIN <= len(s):
            var m = 0.0
            for k in range(WIN):
                m += abs(Float64(s[i + k]))
            env.append(m / Float64(WIN))
            i += WIN
        if len(env) == 0:
            return 0.0
        var mean = 0.0
        for k in range(len(env)):
            mean += env[k]
        mean /= Float64(len(env))
        var crossings = 0
        for k in range(1, len(env)):
            if env[k - 1] <= mean and env[k] > mean:
                crossings += 1
        return Float64(crossings) / (Float64(len(env)) * Float64(WIN)
                                     / Float64(SAMPLE_RATE))

    let saucer_hz = beats_per_second(SFX_SAUCER, 0.8)
    let boss_hz = beats_per_second(SFX_BOSS_HUM, 0.9)
    # 600 vs 606 is a 6 Hz beat; 110 vs 114 is 4 Hz. The envelope detector
    # is coarse, so this asks for the right neighbourhood, not the decimal.
    if saucer_hz < 3.0 or saucer_hz > 9.0:
        print("FAIL  saucer beats at", saucer_hz, "Hz, want about 6")
        failures += 1
    elif boss_hz < 2.0 or boss_hz > 7.0:
        print("FAIL  boss_hum beats at", boss_hz, "Hz, want about 4")
        failures += 1
    else:
        print("ok    saucer beats at", saucer_hz, "Hz and boss_hum at",
              boss_hz, "Hz -- their detunes")

    # ── the render is deterministic, and these are the twelve ────────────
    # The chip is integer arithmetic with a fixed LFSR seed, so an effect
    # renders byte for byte the same every run -- which makes a hash a real
    # regression test rather than a tolerance check. Any change to the
    # oscillator, the envelope, the filter or a recipe shows up HERE, as a
    # different number, instead of as someone eventually noticing that the
    # laser sounds wrong.
    #
    # Regenerate deliberately, never to make a red test green.
    var expected: List[Int] = [
        -0x78df76cf20511770,   # 0  coin
        -0x347b572db49baced,   # 1  jump
        0x56a630415fb74441,    # 2  zap
        0x5b6edb0d23533bd5,    # 3  shoot
        -0x1528fa4ba63d0303,   # 4  explode
        -0x5a4de0b4f562ce35,   # 5  powerup
        -0x5ed280e14dc6fa8,    # 6  hurt
        0x1bc997386f0b5ba4,    # 7  click
        0x5823e6215dc3016b,    # 8  bang
        -0x3401873111756427,   # 9  blip
        -0x3fd16cd8f294232f,   # 10 saucer
        -0x955378513a8088c,    # 11 boss_hum
    ]
    var drifted = 0
    for e in range(SFX_COUNT):
        let h = hash_of(Span(render_effect(e, sfx_frames(e))))
        if h != expected[e]:
            print("FAIL ", sfx_name(e), "hashes", hex(h),
                  "expected", hex(expected[e]))
            drifted += 1
    if drifted != 0:
        failures += 1
    else:
        print("ok    all", SFX_COUNT, "effects hash to their committed values")

    let z1 = hash_of(Span(render_effect(SFX_ZAP, sfx_frames(SFX_ZAP))))
    let z2 = hash_of(Span(render_effect(SFX_ZAP, sfx_frames(SFX_ZAP))))
    if z1 != z2:
        print("FAIL  two renders of zap differ:", hex(z1), hex(z2))
        failures += 1
    else:
        print("ok    and a second render of zap is identical")

    # ── the voice bank ───────────────────────────────────────────────────
    st = chip_new()
    set_volume(st, 15)
    if active_voices(st) != 0:
        print("FAIL  a fresh bank has active voices")
        failures += 1
    else:
        print("ok    a fresh bank has no active voices")

    var buf = List[Float32](length=FRAME_SAMPLES, fill=0.0)
    let bp = Pointer[Float32, MutUntrackedOrigin](
        unsafe_from_address=Int(buf.unsafe_ptr())
    )
    set_instrument(st, 0, Instrument(WAVE_PULSE))
    note_on(st, 0, 69)                       # A4
    chip_render(st, bp, FRAME_SAMPLES, no_tick)
    if not is_voice_active(st, 0):
        print("FAIL  note_on did not activate the voice")
        failures += 1
    note_off(st, 0)
    # The release is not instant -- that is the point of asking the
    # envelope rather than the gate.
    chip_render(st, bp, FRAME_SAMPLES, no_tick)
    let still = is_voice_active(st, 0)
    for _ in range(200):
        chip_render(st, bp, FRAME_SAMPLES, no_tick)
    if not still:
        print("FAIL  the voice went idle the instant the gate dropped")
        failures += 1
    elif is_voice_active(st, 0):
        print("FAIL  the voice never went idle after its release")
        failures += 1
    else:
        print("ok    note_on activates, note_off releases, then it idles")

    # Voices sum, and an idle voice contributes silence.
    #
    # From FRESH chips both times, not by adding a voice to a chip already
    # running one: the first voice's envelope has moved on by then, so the
    # comparison would be between one voice at peak and one voice at
    # sustain plus one at peak -- which is not the question.
    def energy(voices: Int) raises -> Float64:
        var c = chip_new()
        set_volume(c, 15)
        var b = List[Float32](length=FRAME_SAMPLES, fill=0.0)
        let q = Pointer[Float32, MutUntrackedOrigin](
            unsafe_from_address=Int(b.unsafe_ptr())
        )
        set_instrument(c, 0, Instrument(WAVE_PULSE))
        note_on(c, 0, 69)
        if voices > 1:
            set_instrument(c, 1, Instrument(WAVE_PULSE))
            note_on(c, 1, 76)
        chip_render(c, q, FRAME_SAMPLES, no_tick)
        var e = 0.0
        for i in range(FRAME_SAMPLES):
            e += Float64(b[i]) * Float64(b[i])
        chip_free(c)
        return e

    let one = energy(1)
    let two = energy(2)
    # POWER, not mean absolute value. Two 50%-duty pulse waves at unrelated
    # pitches sum to a signal taking three values -- -2A, 0, +2A -- with the
    # zero half the time, so its MEAN ABSOLUTE value is exactly one voice's
    # and a test on that metric reads "the second voice did nothing". The
    # power does add: uncorrelated signals sum in energy, so two voices are
    # about twice one.
    if two <= one * 1.5:
        print("FAIL  a second voice did not add: ", one, "->", two)
        failures += 1
    else:
        print("ok    voices sum together:", one, "->", two)

    # An idle chip is silent: the third voice was never gated.
    var silent = chip_new()
    set_volume(silent, 15)
    chip_render(silent, bp, FRAME_SAMPLES, no_tick)
    var e0 = 0.0
    for i in range(FRAME_SAMPLES):
        e0 += abs(Float64(buf[i]))
    chip_free(silent)
    if e0 != 0.0:
        print("FAIL  idle voices were not silent:", e0)
        failures += 1
    else:
        print("ok    idle voices contribute silence")

    note_on(st, 0, 69)
    set_instrument(st, 1, Instrument(WAVE_PULSE))
    note_on(st, 1, 76)
    chip_render(st, bp, FRAME_SAMPLES, no_tick)
    if allocate_voice(st) != 2:
        print("FAIL  allocate_voice did not find the one idle voice")
        failures += 1
    note_off(st, 0)
    note_off(st, 1)
    chip_free(st)

    # KEEPALIVE. `bp` is a raw pointer into `buf`, and Mojo destroys a value
    # at its LAST USE rather than at the end of the scope -- so without this
    # `buf` dies at the last `buf[i]` above and every later chip_render
    # writes through a dangling pointer into freed heap. It does not crash
    # there; it crashes in the next List reallocation, which is a long way
    # from the cause. Same rule as the DeviceBuffer in spike_shared.
    _ = buf

    # midi_to_hz: A4 is 440, an octave up is 880.
    if abs(midi_to_hz(69) - 440.0) > 0.001 or abs(midi_to_hz(81) - 880.0) > 0.01:
        print("FAIL  midi_to_hz:", midi_to_hz(69), midi_to_hz(81))
        failures += 1
    else:
        print("ok    midi_to_hz is equal temperament from A4 = 440")

    # ── the WAV codec ────────────────────────────────────────────────────
    var probe = List[Float32]()
    for i in range(1000):
        probe.append(Float32(-1.0 + 2.0 * Float64(i) / 999.0))
    let w = wav_bytes(Span(probe), SAMPLE_RATE)
    if len(w) != WAV_HEADER_BYTES + 2000:
        print("FAIL  wav is", len(w), "bytes, want", WAV_HEADER_BYTES + 2000)
        failures += 1
    let back = read_wav(Span(w))
    if len(back) != 1000:
        print("FAIL  read back", len(back), "samples of 1000")
        failures += 1
    else:
        var worst = 0.0
        for i in range(1000):
            let e = abs(Float64(back[i]) - Float64(probe[i]))
            if e > worst:
                worst = e
        # One 16-bit step is 1/32768; half-away rounding keeps the error
        # inside half a step.
        if worst > 1.0 / 32768.0:
            print("FAIL  round trip is off by", worst)
            failures += 1
        else:
            print("ok    a wav round-trips within half a quantisation step")

    var refused = False
    var empty = List[Float32]()
    try:
        _ = wav_bytes(Span(empty), SAMPLE_RATE)
    except:
        refused = True
    if not refused:
        print("FAIL  an empty sound was written rather than refused")
        failures += 1
    else:
        print("ok    an empty sound is refused, not written")

    deck_free(d)

    print()
    if failures == 0:
        print("G7 audio: PASS")
    else:
        print("G7 audio: FAILED", failures, "check(s)")
        raise Error("G7 audio failed")
