# ===----------------------------------------------------------------------=== #
# CT1 — the grammar: what [I:chip ...] says, the triples must carry.
#
# chip_settings is tested directly, triple by triple, because the whole
# scheme rests on one rule: unknown keys are ignored, known keys become
# (voice, param, value) with any signedness carried by a stated bias. If
# the bias moved, an old tune would detune every new build -- so the exact
# numbers are asserted here, not just "parses".
#
# Run: ./tools/gp.sh gamepane/tests/test_chipgrammar.mojo
# ===----------------------------------------------------------------------=== #

from gamepane.api import P, SAMPLE_RATE
from gamepane.api.audio import get
from gamepane.abc import (
    Tune, parse_abc, resolve_ties, build_schedule, sort_steps, Step,
    trio_new, trio_free, trio_chip, flatten_trio, render_trio,
)
from gamepane.abc.music import chip_settings
from gamepane.abc.model import (
    CP_PAN, CP_ECHO, CP_ETIME, CP_EFB, CP_TONE, CP_ARP, CP_VIB, CP_SLIDE, CP_PWM,
    CP_SWEEP, CP_TREM, CP_WAVE,
)
from gamepane.abc.chipplay import macro_slot, M_ARP, M_VIB, M_SLIDE, M_PWM
from gamepane.abc.trioplay import T_ECHO_SEND, T_ETIME, T_EFB, T_PAN_BASE
from std.memory import Pointer, MutUntrackedOrigin


def one(source: String, want_param: Int) raises -> List[Int]:
    """The [voice, param, value] triple for want_param, or [-1,-1,-1]."""
    let t = chip_settings(source, 1)
    var out: List[Int] = [-1, -1, -1]
    for i in range(0, len(t), 3):
        if t[i + 1] == want_param:
            out[0] = t[i]
            out[1] = t[i + 1]
            out[2] = t[i + 2]
    return out^


def check(mut failures: Int, name: String, got: List[Int],
          voice: Int, value: Int) raises:
    if got[0] == voice and got[2] == value:
        print("ok   ", name, "->", got[0], got[2])
    else:
        print("FAIL ", name, "voice", got[0], "value", got[2],
              "wanted", voice, value)
        failures += 1


def main() raises:
    var failures = 0

    # ── the pairs and the packings ───────────────────────────────────────
    check(failures, "arp=047",
          one(String("chip v=5 arp=047"), CP_ARP), 5, (3 << 32) | 0x740)
    check(failures, "arp=0",
          one(String("chip arp=0"), CP_ARP), 1, (1 << 32))
    check(failures, "vib=8/3",
          one(String("chip v=2 vib=8/3"), CP_VIB), 2, (8 << 8) | 3)
    check(failures, "pwm=40/2",
          one(String("chip pwm=40/2"), CP_PWM), 1, (40 << 8) | 2)
    check(failures, "trem=6/4",
          one(String("chip v=9 trem=6/4"), CP_TREM), 9, (6 << 8) | 4)
    check(failures, "slide=24",
          one(String("chip slide=24"), CP_SLIDE), 1, 24)

    # ── the biases, exactly ──────────────────────────────────────────────
    check(failures, "pan=-96",
          one(String("chip v=4 pan=-96"), CP_PAN), 4, 32)
    check(failures, "pan=127",
          one(String("chip pan=127"), CP_PAN), 1, 255)
    check(failures, "sweep=-40",
          one(String("chip sweep=-40"), CP_SWEEP), 1, 984)
    check(failures, "sweep=12",
          one(String("chip sweep=12"), CP_SWEEP), 1, 1036)

    # ── the echo family ──────────────────────────────────────────────────
    check(failures, "echo=9",
          one(String("chip v=7 echo=9"), CP_ECHO), 7, 9)
    check(failures, "etime=18",
          one(String("chip etime=18"), CP_ETIME), 1, 18)
    check(failures, "efb=11",
          one(String("chip efb=11"), CP_EFB), 1, 11)
    check(failures, "tone=9",
          one(String("chip tone=9"), CP_TONE), 1, 9)

    # ── tolerance: the unknown key rule that versions the format ─────────
    let tol = chip_settings(String("chip v=2 zorble=9 wave=saw"), 1)
    var saw_wave = False
    var saw_junk = False
    for i in range(0, len(tol), 3):
        if tol[i + 1] == CP_WAVE:
            saw_wave = True
        if tol[i + 2] == 9 and tol[i + 1] != CP_ECHO:
            saw_junk = True
    if saw_wave and not saw_junk:
        print("ok    zorble=9 ignored, wave=saw kept")
    else:
        print("FAIL  unknown-key tolerance")
        failures += 1

    # ── through the whole pipe: ABC -> schedule -> trio registers ────────
    comptime TUNE = String("""X:1
M:4/4
L:1/4
Q:1/4=120
K:C
V:4
[I:chip v=4 pan=-64 echo=7 etime=12 efb=9 arp=047 vib=8/3 slide=16 pwm=64/2]
C4
""")
    var tune = Tune()
    parse_abc(TUNE, tune)
    resolve_ties(tune)
    var steps = List[Step]()
    build_schedule(tune, SAMPLE_RATE, steps)
    sort_steps(steps)
    var trio = trio_new()
    _ = flatten_trio(steps, trio)
    var out = List[Float32](length=SAMPLE_RATE * 2, fill=0.0)
    render_trio(trio, Pointer[Float32, MutUntrackedOrigin](
        unsafe_from_address=Int(out.unsafe_ptr())), SAMPLE_RATE)

    let c1 = trio_chip(trio, 1)          # V:4 is chip 1, voice 0
    if get(trio, T_PAN_BASE + 1) == -64:
        print("ok    pan=-64 landed on chip 1's trio slot")
    else:
        print("FAIL  trio pan:", get(trio, T_PAN_BASE + 1))
        failures += 1
    if get(trio, T_ECHO_SEND + 1) == 7 and get(trio, T_ETIME) == 12 \
            and get(trio, T_EFB) == 9:
        print("ok    echo=7 etime=12 efb=9 landed at trio level")
    else:
        print("FAIL  echo family:", get(trio, T_ECHO_SEND + 1),
              get(trio, T_ETIME), get(trio, T_EFB))
        failures += 1
    if get(c1, macro_slot(0, M_ARP)) == ((3 << 32) | 0x740) \
            and get(c1, macro_slot(0, M_VIB)) == ((8 << 8) | 3) \
            and get(c1, macro_slot(0, M_SLIDE)) == 16 \
            and get(c1, macro_slot(0, M_PWM)) == ((64 << 8) | 2):
        print("ok    arp/vib/slide/pwm stored in chip 1 voice 0's registers")
    else:
        print("FAIL  macro registers:", get(c1, macro_slot(0, M_ARP)),
              get(c1, macro_slot(0, M_VIB)), get(c1, macro_slot(0, M_SLIDE)),
              get(c1, macro_slot(0, M_PWM)))
        failures += 1

    trio_free(trio)
    _ = out

    if failures == 0:
        print("PASS  test_chipgrammar")
    else:
        print("FAIL ", failures, "failures")
        raise Error("test_chipgrammar failed")
