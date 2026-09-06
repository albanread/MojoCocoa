# The period trackers — a .MOD as a score (CT7).
#
# An Amiga MOD is four (or six, or eight) channels of sampled PCM. We have
# synthesis, so this importer takes the half that transfers: the NOTES.
# Periods become pitches through the PAL table, rows become sample times
# through speed and tempo, the effect column becomes the 50 Hz macros it
# always secretly was -- 0xy IS an arpeggio, 4xy IS vibrato, 3xx IS the
# slide -- and each of the 31 instruments becomes a chip recipe, inferred
# crudely from its sample header and overridable line by line from a
# sidecar. The result is not the MOD; it is a CHIP COVER of the MOD,
# which is itself a fine scene tradition.
#
# One engine truth had to be faced rather than fudged: a tracker channel
# IS a voice. Note four's vibrato must wobble note four, not whichever
# voice the allocator happened to hand out. So a MOD schedule runs the
# trio in PINNED mode (set_trio_pinned): channel k owns one chip voice
# for the whole song, by construction, and every macro and volume change
# is addressed to it. ABC tunes keep the dynamic allocator they were
# written against; the flag is per-schedule and reset by flatten_trio.
#
# What is skipped is skipped in the open -- the coverage table in
# test_mod.mojo is the contract: 9xx (sample offset) means nothing
# without PCM and waits for CT8; Axy (volume slides) and 5xy/6xy (the
# combo commands) are out of the cover's reach until then too.

from std.memory import Pointer, MutUntrackedOrigin

from gamepane.api.audio import SAMPLE_RATE
from gamepane.abc.schedule import Step, SE_NOTE_ON, SE_NOTE_OFF, SE_CHIP
from gamepane.abc.model import (
    CP_WAVE, CP_PW, CP_A, CP_D, CP_S, CP_R, CP_VOL, CP_ARP, CP_VIB,
    CP_SLIDE, CP_TREM,
)
from gamepane.api.audio import WAVE_TRI, WAVE_SAW, WAVE_PULSE, WAVE_NOISE
from gamepane.abc.music import chip_settings


# ── the PAL period table, octaves 1-3, C-1 at MIDI 48 ───────────────────────

def periods() raises -> List[Int]:
    """A def and not a comptime: a comptime List cannot be indexed by a
    runtime loop variable without materialising, and this runs at import
    time on the game thread where an allocation is nobody's problem."""
    return [
        856, 808, 762, 720, 678, 640, 604, 570, 538, 508, 480, 453,
        428, 404, 381, 360, 339, 320, 302, 285, 269, 254, 240, 226,
        214, 202, 190, 180, 170, 160, 151, 143, 135, 127, 120, 113,
    ]


def period_to_midi(period: Int) raises -> Int:
    """The nearest note of the table; C-2 (428) is middle C. Finetune is
    ignored -- a chip cover is a transcription, not a restoration."""
    if period <= 0:
        return -1
    let table = periods()
    var best = 0
    var best_d = 1 << 30
    for i in range(len(table)):
        var d = table[i] - period
        if d < 0:
            d = -d
        if d < best_d:
            best_d = d
            best = i
    return 48 + best


def channel_voice(ch: Int, channels: Int) -> Int:
    """Which GLOBAL chip voice (0..8) a tracker channel owns.

    Four channels sit on the outer chips the way the Amiga panned them --
    hardware left for 0 and 3, right for 1 and 2 -- leaving chip 0 free.
    Six spread one per chip and then a second; eight take a third column.
    """
    if channels <= 4:
        var m4: List[Int] = [3, 6, 7, 4]
        return m4[ch] if ch < 4 else 4
    if channels == 6:
        var m6: List[Int] = [0, 3, 6, 1, 4, 7]
        return m6[ch] if ch < 6 else 7
    var m8: List[Int] = [0, 3, 6, 1, 4, 7, 2, 5]
    return m8[ch] if ch < 8 else 5


# ── the container ───────────────────────────────────────────────────────────


def _u16be(b: Span[UInt8, _], at: Int) -> Int:
    return (Int(b[at]) << 8) | Int(b[at + 1])


def mod_channels(b: Span[UInt8, _]) raises -> Int:
    """The channel count, from the signature at 1080 -- or a refusal.
    The 15-sample SoundTracker layout has no signature at all; refusing
    it beats misreading its patterns as sample names."""
    if len(b) < 1084:
        raise Error("mod: too short for a 31-sample module")
    var sig = String("")
    for i in range(4):
        sig += chr(Int(b[1080 + i]))
    if sig == "M.K." or sig == "M!K!" or sig == "FLT4" or sig == "4CHN":
        return 4
    if sig == "6CHN":
        return 6
    if sig == "8CHN" or sig == "FLT8":
        return 8
    raise Error("mod: unknown signature '" + sig + "' (15-sample modules are not supported)")


struct ModInstrument(Copyable, Movable):
    var length: Int          # bytes of PCM
    var volume: Int          # 0..64
    var looped: Bool
    var bright: Int          # zero crossings per 128 PCM bytes, 0 if unread

    def __init__(out self):
        self.length = 0
        self.volume = 64
        self.looped = False
        self.bright = 0


def _recipe(inst: ModInstrument, voice: Int, at: Int,
            mut steps: List[Step]) raises:
    """One instrument as chip registers, addressed to a pinned voice.

    Crude on purpose: a looped sample holds a note, so it becomes a
    sustained recipe; a one-shot decays by its own length; the zero
    crossings of its first page pick the waveform -- busy is noise, rough
    is saw, smooth is pulse. The sidecar overrides all of this per
    instrument, through the very same [I:chip] grammar."""
    var wave = WAVE_PULSE
    if inst.bright > 40:
        wave = WAVE_NOISE
    elif inst.bright > 12:
        wave = WAVE_SAW
    elif inst.length > 0 and inst.length < 2000 and not inst.looped:
        wave = WAVE_TRI
    var a = 0
    var d = 6
    var sus = 0
    var r = 4
    if inst.looped:
        sus = 9 + inst.volume * 4 // 64          # 9..13
        d = 3
        r = 5
    elif inst.length > 8000:
        d = 9
        r = 6
    steps.append(Step(sample=at, kind=SE_CHIP, voice=voice,
                      midi=CP_WAVE, velocity=wave))
    steps.append(Step(sample=at, kind=SE_CHIP, voice=voice,
                      midi=CP_PW, velocity=900))
    steps.append(Step(sample=at, kind=SE_CHIP, voice=voice, midi=CP_A,
                      velocity=a))
    steps.append(Step(sample=at, kind=SE_CHIP, voice=voice, midi=CP_D,
                      velocity=d))
    steps.append(Step(sample=at, kind=SE_CHIP, voice=voice, midi=CP_S,
                      velocity=sus))
    steps.append(Step(sample=at, kind=SE_CHIP, voice=voice, midi=CP_R,
                      velocity=r))


def mod_to_steps(
    b: Span[UInt8, _],
    mut steps: List[Step],
    sidecar: String = String(""),
) raises -> Int:
    """The whole song as sample-stamped steps. Returns the channel count.

    Voice numbers in the steps are 1-based ABC style for note events and
    0-based for SE_CHIP, exactly as build_schedule emits them, so the trio
    walker needs no second convention -- only the pinned flag.
    """
    let channels = mod_channels(b)

    # ── instruments ─────────────────────────────────────────────────────
    var inst = List[ModInstrument]()
    var total_pcm = 0
    for i in range(31):
        var m = ModInstrument()
        let at = 20 + i * 30
        m.length = _u16be(b, at + 22) * 2
        m.volume = Int(b[at + 25])
        m.looped = _u16be(b, at + 28) > 1
        inst.append(m^)
        total_pcm += _u16be(b, at + 22) * 2

    let song_len = Int(b[950])
    var highest = 0
    for i in range(128):
        if Int(b[952 + i]) > highest:
            highest = Int(b[952 + i])
    let pattern_bytes = 64 * channels * 4
    let pcm_at = 1084 + (highest + 1) * pattern_bytes

    # brightness: zero crossings across each sample's first page
    var pcm_pos = pcm_at
    for i in range(31):
        if inst[i].length >= 32 and pcm_pos + 128 <= len(b):
            var crossings = 0
            var prev = Int(b[pcm_pos])
            if prev > 127:
                prev -= 256
            let page = 128 if inst[i].length >= 128 else inst[i].length
            for k in range(1, page):
                var v = Int(b[pcm_pos + k])
                if v > 127:
                    v -= 256
                if (v >= 0) != (prev >= 0):
                    crossings += 1
                prev = v
            inst[i].bright = crossings
        pcm_pos += inst[i].length

    # ── the sidecar: "<n> key=value ..." through the [I:chip] grammar ───
    var override = List[List[Int]](length=32, fill=List[Int]())
    if sidecar.byte_length() > 0:
        for line in sidecar.split("\n"):
            let t = String(line).strip()
            if t.byte_length() == 0 or t.startswith("#"):
                continue
            let sp = String(t).split(" ", 1)
            if len(sp) < 2:
                continue
            var n = 0
            var okn = True
            for cb in String(sp[0]).as_bytes():
                if cb < 48 or cb > 57:
                    okn = False
                else:
                    n = n * 10 + Int(cb) - 48
            if okn and n >= 1 and n <= 31:
                override[n] = chip_settings(
                    String("chip ") + String(sp[1]), 1)

    # ── the rows ────────────────────────────────────────────────────────
    var speed = 6                        # ticks a row
    var tempo = 125                      # 125 BPM: a tick IS 50 Hz
    var pos = 0                          # order position
    var row = 0
    var t = 0.0                          # the clock, in samples
    var visited = List[Bool](length=128 * 64, fill=False)
    var cur_inst = List[Int](length=channels, fill=-1)
    var last = 0

    while pos < song_len:
        if visited[pos * 64 + row]:
            break                        # a backward jump: the song loops here
        visited[pos * 64 + row] = True
        let pat = Int(b[952 + pos])
        let row_at = 1084 + pat * pattern_bytes + row * channels * 4
        let tick_len = Float64(SAMPLE_RATE) * 2.5 / Float64(tempo)
        var jump_pos = -1
        var jump_row = -1

        for ch in range(channels):
            let c = row_at + ch * 4
            let b0 = Int(b[c])
            let period = ((b0 & 15) << 8) | Int(b[c + 1])
            let sample_n = (b0 & 240) | (Int(b[c + 2]) >> 4)
            let fx = Int(b[c + 2]) & 15
            let param = Int(b[c + 3])
            let g = channel_voice(ch, channels)
            let now = Int(t)

            # timing and flow first: they shape this very row
            if fx == 15:
                if param == 0:
                    pass
                elif param < 32:
                    speed = param
                else:
                    tempo = param
            elif fx == 11:
                jump_pos = param
                jump_row = 0
            elif fx == 13:
                jump_pos = pos + 1
                jump_row = (param >> 4) * 10 + (param & 15)
                if jump_row > 63:
                    jump_row = 0

            # an instrument named is a recipe applied (changes only)
            if sample_n > 0 and sample_n <= 31 and sample_n != cur_inst[ch]:
                cur_inst[ch] = sample_n
                if len(override[sample_n]) > 0:
                    let o = override[sample_n]
                    for k in range(0, len(o), 3):
                        steps.append(Step(sample=now, kind=SE_CHIP,
                                          voice=g, midi=o[k + 1],
                                          velocity=o[k + 2]))
                else:
                    _recipe(inst[sample_n - 1], g, now, steps)

            # the macros this row asks for, addressed to the pinned voice
            if fx == 0 and param != 0:
                let packed = (3 << 32) | ((param >> 4) << 4) \
                    | ((param & 15) << 8)
                steps.append(Step(sample=now, kind=SE_CHIP, voice=g,
                                  midi=CP_ARP, velocity=packed))
            elif fx == 0 and period > 0:
                steps.append(Step(sample=now, kind=SE_CHIP, voice=g,
                                  midi=CP_ARP, velocity=0))
            if fx == 4 and param != 0:
                let d = (param & 15) * 3
                let r = param >> 4 if (param >> 4) > 0 else 2
                steps.append(Step(sample=now, kind=SE_CHIP, voice=g,
                                  midi=CP_VIB, velocity=(d << 8) | r))
            if fx == 7 and param != 0:
                let d = (param & 15) * 12
                let r = param >> 4 if (param >> 4) > 0 else 2
                steps.append(Step(sample=now, kind=SE_CHIP, voice=g,
                                  midi=CP_TREM, velocity=(d << 8) | r))
            if fx == 3 and param != 0:
                steps.append(Step(sample=now, kind=SE_CHIP, voice=g,
                                  midi=CP_SLIDE, velocity=param // 4 + 1))
            if fx == 12:
                if param == 0:
                    steps.append(Step(sample=now, kind=SE_NOTE_OFF,
                                      voice=g + 1, midi=-1, velocity=0))
                else:
                    var v15 = param * 15 // 64
                    if v15 > 15:
                        v15 = 15
                    steps.append(Step(sample=now, kind=SE_CHIP, voice=g,
                                      midi=CP_S, velocity=v15))

            # the note itself
            if period > 0:
                let midi = period_to_midi(period)
                if fx == 3:
                    # tone portamento: the note is a destination, not a
                    # retrigger -- velocity 0 is the pinned walker's
                    # legato mark.
                    steps.append(Step(sample=now, kind=SE_NOTE_ON,
                                      voice=g + 1, midi=midi, velocity=0))
                elif fx == 14 and (param >> 4) == 13 and (param & 15) > 0:
                    let delay = Int(Float64(param & 15) * tick_len)
                    steps.append(Step(sample=now + delay, kind=SE_NOTE_ON,
                                      voice=g + 1, midi=midi, velocity=64))
                else:
                    steps.append(Step(sample=now, kind=SE_NOTE_ON,
                                      voice=g + 1, midi=midi, velocity=64))
                if now > last:
                    last = now
            if fx == 14 and (param >> 4) == 12:
                let cut = Int(Float64(param & 15) * tick_len)
                steps.append(Step(sample=now + cut, kind=SE_NOTE_OFF,
                                  voice=g + 1, midi=-1, velocity=0))

        t += Float64(speed) * tick_len
        if jump_pos >= 0:
            pos = jump_pos
            row = jump_row
        else:
            row += 1
            if row >= 64:
                row = 0
                pos += 1

    # every channel released at the end, so a looped render starts clean
    let end = Int(t)
    for ch in range(channels):
        steps.append(Step(sample=end, kind=SE_NOTE_OFF,
                          voice=channel_voice(ch, channels) + 1,
                          midi=-1, velocity=0))
    return channels
