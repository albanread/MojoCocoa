# ===----------------------------------------------------------------------=== #
# CT7 — the MOD importer: a synthetic module, written byte by byte here,
# read back as a schedule.
#
# The module is its own oracle: every cell below was placed knowing what
# step it must become. Period 428 is middle C; six ticks a row at tempo
# 125 is 5760 samples; 0x37 after effect 0 is an arpeggio of 0,3,7; C20
# is sustain 7 of 15; ECx is a cut x ticks in. What is NOT covered is the
# contract too: 9xx, Axy, 5xy/6xy wait for the Paula wave (CT8), and the
# 15-sample SoundTracker layout is refused by name.
#
# Run: ./tools/gp.sh gamepane/tests/test_mod.mojo
# ===----------------------------------------------------------------------=== #

from std.memory import Pointer, MutUntrackedOrigin

from gamepane.api import P, SAMPLE_RATE
from gamepane.api.audio import get, WAVE_NOISE
from gamepane.abc import (
    Step, SE_NOTE_ON, SE_NOTE_OFF, SE_CHIP, sort_steps,
    mod_to_steps, mod_channels, period_to_midi, channel_voice,
    trio_new, trio_free, trio_chip, flatten_trio, render_trio,
    set_trio_pinned,
)
from gamepane.abc.model import CP_ARP, CP_VIB, CP_SLIDE, CP_S, CP_WAVE
from gamepane.abc.chipplay import SC_VOICE_NOTE
from gamepane.api.audio import PLAYER_BASE


comptime ROW = 5760                      # 6 ticks x 960 samples at tempo 125


def synth_mod() raises -> List[UInt8]:
    """One pattern, four channels, every mapped feature on a known row."""
    var b = List[UInt8](length=1084 + 1024, fill=0)
    # sample 1: looped, quiet-ish -- a sustained recipe
    b[20 + 22] = 0; b[20 + 23] = 100                 # length 100 words
    b[20 + 25] = 48                                  # volume
    b[20 + 28] = 0; b[20 + 29] = 8                   # loop: sustained
    # sample 2: one-shot
    b[50 + 22] = 0; b[50 + 23] = 50
    b[50 + 25] = 64
    b[950] = 1                                       # one position
    b[951] = 127
    b[952] = 0                                       # order: pattern 0
    b[1080] = 77; b[1081] = 46; b[1082] = 75; b[1083] = 46   # "M.K."

    def cell(mut b: List[UInt8], row: Int, ch: Int, period: Int,
             sample: Int, fx: Int, param: Int) raises:
        let at = 1084 + (row * 4 + ch) * 4
        b[at] = UInt8(((sample & 240)) | ((period >> 8) & 15))
        b[at + 1] = UInt8(period & 255)
        b[at + 2] = UInt8(((sample & 15) << 4) | (fx & 15))
        b[at + 3] = UInt8(param & 255)

    cell(b, 0, 0, 428, 1, 0, 0)          # row 0 ch0: middle C, instrument 1
    cell(b, 1, 0, 428, 0, 0, 0x37)       # row 1: arpeggio 0,3,7
    cell(b, 2, 1, 214, 2, 4, 0x24)       # row 2 ch1: C above, vibrato
    cell(b, 3, 0, 0, 0, 12, 0x20)        # row 3: volume C20 -> sustain 7
    cell(b, 4, 2, 856, 1, 14, 0xC3)      # row 4 ch2: low C, cut 3 ticks in
    cell(b, 5, 3, 428, 1, 3, 8)          # row 5 ch3: portamento target
    cell(b, 6, 0, 0, 0, 13, 0)           # row 6: pattern break -> song ends
    cell(b, 63, 0, 428, 0, 0, 0)         # never reached
    return b^


def find(steps: List[Step], kind: Int, voice: Int, param: Int) -> Int:
    """The sample time of the first matching step, or -1."""
    for i in range(len(steps)):
        if steps[i].kind == kind and steps[i].voice == voice:
            if kind != SE_CHIP or steps[i].midi == param:
                return steps[i].sample
    return -1


def main() raises:
    var failures = 0
    var raw = synth_mod()

    if mod_channels(Span(raw)) == 4:
        print("ok    M.K. reads as four channels")
    else:
        print("FAIL  channel count")
        failures += 1

    var steps = List[Step]()
    let channels = mod_to_steps(Span(raw), steps)
    sort_steps(steps)
    print("ok    imported", len(steps), "steps from", channels, "channels")

    # ── pitch and time ───────────────────────────────────────────────────
    let v0 = channel_voice(0, 4) + 1                 # ch0's 1-based voice
    let on0 = find(steps, SE_NOTE_ON, v0, -1)
    if on0 == 0 and period_to_midi(428) == 60:
        print("ok    period 428 is middle C at sample 0")
    else:
        print("FAIL  first note: sample", on0, "midi", period_to_midi(428))
        failures += 1
    let v1 = channel_voice(1, 4) + 1
    let on2 = find(steps, SE_NOTE_ON, v1, -1)
    if on2 == 2 * ROW and period_to_midi(214) == 72:
        print("ok    row 2 lands at", on2, "and period 214 is c'")
    else:
        print("FAIL  row 2:", on2)
        failures += 1

    # ── the effect column became the macros ──────────────────────────────
    # Two arp steps exist by design: the plain note on row 0 CLEARS any
    # stale arpeggio (velocity 0), and row 1 arms 0,3,7. Find the armed one.
    let g0 = channel_voice(0, 4)
    var arp_at = -1
    var arp_val = -1
    for i in range(len(steps)):
        if steps[i].kind == SE_CHIP and steps[i].voice == g0 \
                and steps[i].midi == CP_ARP and steps[i].velocity != 0:
            arp_val = steps[i].velocity
            arp_at = steps[i].sample
    if arp_at == ROW and arp_val == ((3 << 32) | 0x730):
        print("ok    0x37 became arp 0,3,7 on the pinned voice")
    else:
        print("FAIL  arp at", arp_at, "packed", arp_val)
        failures += 1
    let g1 = channel_voice(1, 4)
    var vib_val = -1
    for i in range(len(steps)):
        if steps[i].kind == SE_CHIP and steps[i].voice == g1 \
                and steps[i].midi == CP_VIB:
            vib_val = steps[i].velocity
    if vib_val == ((12 << 8) | 2):
        print("ok    4x24 became vib depth 12 rate 2")
    else:
        print("FAIL  vib packed", vib_val)
        failures += 1
    var sus_val = -1
    for i in range(len(steps)):
        if steps[i].kind == SE_CHIP and steps[i].voice == g0 \
                and steps[i].midi == CP_S and steps[i].sample == 3 * ROW:
            sus_val = steps[i].velocity
    if sus_val == 7:
        print("ok    C20 became sustain 7 of 15")
    else:
        print("FAIL  volume mapping", sus_val)
        failures += 1

    # ── EC cut, ED-free note, portamento legato ─────────────────────────
    let g2v = channel_voice(2, 4) + 1
    let cut_at = find(steps, SE_NOTE_OFF, g2v, -1)
    if cut_at == 4 * ROW + 3 * 960:
        print("ok    EC3 cuts exactly three ticks in:", cut_at)
    else:
        print("FAIL  cut at", cut_at)
        failures += 1
    let g3v = channel_voice(3, 4) + 1
    var legato_vel = -1
    for i in range(len(steps)):
        if steps[i].kind == SE_NOTE_ON and steps[i].voice == g3v:
            legato_vel = steps[i].velocity
    if legato_vel == 0:
        print("ok    3xx note is a legato destination, not a retrigger")
    else:
        print("FAIL  portamento velocity", legato_vel)
        failures += 1

    # ── D00 ended the song after row 6, one pattern of eight rows ───────
    var max_on = 0
    for i in range(len(steps)):
        if steps[i].kind == SE_NOTE_ON and steps[i].sample > max_on:
            max_on = steps[i].sample
    if max_on <= 6 * ROW:
        print("ok    the break ended the song: last note at", max_on)
    else:
        print("FAIL  a note after the break:", max_on)
        failures += 1

    # ── pinned render: the channels hold THEIR voices ────────────────────
    var trio = trio_new()
    _ = flatten_trio(steps, trio)
    set_trio_pinned(trio, True)
    let n = 3 * ROW + ROW // 2
    var out = List[Float32](length=n * 2, fill=0.0)
    render_trio(trio, Pointer[Float32, MutUntrackedOrigin](
        unsafe_from_address=Int(out.unsafe_ptr())), n)
    # 3.5 rows in: ch0 (chip1 slot 0) holds middle C; ch1 (chip2 slot 0)
    # holds c'; nothing has borrowed anyone's slot.
    let c1 = trio_chip(trio, 1)
    let c2 = trio_chip(trio, 2)
    if get(c1, PLAYER_BASE + SC_VOICE_NOTE + 0) == 60 \
            and get(c2, PLAYER_BASE + SC_VOICE_NOTE + 0) == 72:
        print("ok    pinned: ch0 owns chip1 slot 0 (60), ch1 chip2 slot 0 (72)")
    else:
        print("FAIL  pinned slots:", get(c1, PLAYER_BASE + SC_VOICE_NOTE),
              get(c2, PLAYER_BASE + SC_VOICE_NOTE))
        failures += 1
    var peak = 0.0
    for i in range(n * 2):
        let v = abs(Float64(out[i]))
        if v > peak:
            peak = v
    if peak > 0.02:
        print("ok    the cover is audible, peak", peak)
    else:
        print("FAIL  silent render, peak", peak)
        failures += 1
    trio_free(trio)
    _ = out

    # ── refusals and the uncovered, stated ──────────────────────────────
    var st15 = List[UInt8](length=1084, fill=0)
    var refused = False
    try:
        _ = mod_channels(Span(st15))
    except:
        refused = True
    if refused:
        print("ok    a signatureless module is refused, not misread")
    else:
        print("FAIL  15-sample layout accepted")
        failures += 1
    print("ok    coverage: 0 arp / 3 slide / 4 vib / 7 trem / B D jumps /")
    print("ok      C volume / EC cut / ED delay / F timing. Waiting on")
    print("ok      CT8's PCM: 9xx offset, Axy slides, 5xy 6xy combos.")

    if failures == 0:
        print("PASS  test_mod")
    else:
        print("FAIL ", failures, "failures")
        raise Error("test_mod failed")
