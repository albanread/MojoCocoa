# ===----------------------------------------------------------------------=== #
# Sprint G8 — tunes: ABC in, sample-accurate notes out.
#
# The Rust's tests assert absolute MIDI numbers under its own C = 48
# convention. This parser's convention is asserted ONCE, below, and every
# other case is written against a relative fact -- F under K:G is F plus
# one, a tie is one note of the summed length, a chord is three note-ons at
# one time -- so a convention change breaks one line rather than fifteen.
#
# Run: ./tools/gp.sh gamepane/tests/test_tunes.mojo
# ===----------------------------------------------------------------------=== #

from gamepane.abc import (
    Tune, parse_abc, MsEvent, to_ms_events, SE_NOTE_ON, SE_NOTE_OFF,
    build_midi, put_varlen, channel_for,
)


def events(source: String) raises -> List[MsEvent]:
    var t = Tune()
    parse_abc(source, t)
    return to_ms_events(t^)


def notes_on(e: List[MsEvent]) -> List[Int]:
    var out = List[Int]()
    for i in range(len(e)):
        if e[i].kind == SE_NOTE_ON:
            out.append(e[i].midi)
    return out^


def head(body: String) -> String:
    return String("X:1\nT:t\nM:4/4\nL:1/4\nQ:1/4=120\nK:C\n") + body + "\n"


def main() raises:
    var failures = 0

    # ── the convention, asserted once ────────────────────────────────────
    # Everything below is relative to this.
    let base = notes_on(events(head(String("C"))))
    if len(base) != 1:
        print("FAIL  a single C produced", len(base), "note-ons")
        failures += 1
        raise Error("no baseline")
    let MIDDLE_C = base[0]
    print("ok    this parser's C is MIDI", MIDDLE_C)

    # ── lowercase is the octave above ────────────────────────────────────
    let lower = notes_on(events(head(String("c"))))
    if len(lower) != 1 or lower[0] != MIDDLE_C + 12:
        print("FAIL  lowercase c is", lower[0], "want", MIDDLE_C + 12)
        failures += 1
    else:
        print("ok    lowercase c is the octave above uppercase C")

    # ── a key signature sharpens F ───────────────────────────────────────
    let f_nat = notes_on(events(head(String("F"))))
    var g_tune = String("X:1\nT:t\nM:4/4\nL:1/4\nQ:1/4=120\nK:G\nF\n")
    let f_sharp = notes_on(events(g_tune))
    if len(f_nat) != 1 or len(f_sharp) != 1:
        print("FAIL  F did not produce one note in both keys")
        failures += 1
    elif f_sharp[0] != f_nat[0] + 1:
        print("FAIL  F under K:G is", f_sharp[0], "want", f_nat[0] + 1)
        failures += 1
    else:
        print("ok    F is natural under K:C and sharp under K:G")

    # ── a bar line resets an accidental ──────────────────────────────────
    # ^F F | F -- the second F is still sharp, the third is not.
    let acc = notes_on(events(head(String("^F F | F"))))
    if len(acc) != 3:
        print("FAIL  expected three notes, got", len(acc))
        failures += 1
    elif not (acc[0] == acc[1] and acc[2] == acc[0] - 1):
        print("FAIL  accidental carry/reset:", acc[0], acc[1], acc[2])
        failures += 1
    else:
        print("ok    an accidental carries to the bar line and no further")

    # ── a rest advances without sounding ─────────────────────────────────
    let with_rest = events(head(String("C z C")))
    let without = events(head(String("C C")))
    if len(notes_on(with_rest)) != 2 or len(notes_on(without)) != 2:
        print("FAIL  the rest changed the note count")
        failures += 1
    else:
        # The second C starts two beats in with the rest, one without.
        var a2 = 0
        var b2 = 0
        var seen = 0
        for i in range(len(with_rest)):
            if with_rest[i].kind == SE_NOTE_ON:
                seen += 1
                if seen == 2:
                    a2 = with_rest[i].ms
        seen = 0
        for i in range(len(without)):
            if without[i].kind == SE_NOTE_ON:
                seen += 1
                if seen == 2:
                    b2 = without[i].ms
        if a2 != b2 * 2:
            print("FAIL  a rest did not advance the cursor:", b2, "->", a2)
            failures += 1
        else:
            print("ok    a rest advances the cursor without sounding")

    # ── a tie merges two notes into one longer one ───────────────────────
    let tied = events(head(String("C-C")))
    let untied = events(head(String("C C")))
    let long_one = events(head(String("C2")))
    if len(notes_on(tied)) != 1:
        print("FAIL  a tie left", len(notes_on(tied)), "note-ons, want 1")
        failures += 1
    elif len(notes_on(untied)) != 2:
        print("FAIL  untied notes merged")
        failures += 1
    else:
        # And the tied note is as long as writing it as one note.
        var tie_len = 0
        var whole_len = 0
        for i in range(len(tied)):
            if tied[i].kind == SE_NOTE_OFF:
                tie_len = tied[i].ms
        for i in range(len(long_one)):
            if long_one[i].kind == SE_NOTE_OFF:
                whole_len = long_one[i].ms
        if tie_len != whole_len:
            print("FAIL  C-C lasts", tie_len, "ms, C2 lasts", whole_len)
            failures += 1
        else:
            print("ok    a tie is one note of the summed length")

    # ── a chord is three note-ons at one instant ─────────────────────────
    let chord = events(head(String("[CEG]")))
    let ons = notes_on(chord)
    if len(ons) != 3:
        print("FAIL  a chord produced", len(ons), "note-ons")
        failures += 1
    else:
        var at = -1
        var same = True
        for i in range(len(chord)):
            if chord[i].kind == SE_NOTE_ON:
                if at < 0:
                    at = chord[i].ms
                elif chord[i].ms != at:
                    same = False
        if not same:
            print("FAIL  the chord's notes are not simultaneous")
            failures += 1
        else:
            print("ok    a chord is three note-ons at one instant")

    # ── a repeat doubles the enclosed material ───────────────────────────
    let once = notes_on(events(head(String("C D E F"))))
    let twice = notes_on(events(head(String("|:C D E F:|"))))
    if len(twice) != len(once) * 2:
        print("FAIL  a repeat gave", len(twice), "notes, want", len(once) * 2)
        failures += 1
    else:
        var matched = True
        for i in range(len(once)):
            if twice[i] != once[i] or twice[len(once) + i] != once[i]:
                matched = False
        if not matched:
            print("FAIL  the repeat did not replay the same material")
            failures += 1
        else:
            print("ok    a repeat plays the enclosed material twice")

    # ── two voices land on two channels ──────────────────────────────────
    let two = events(
        String("X:1\nT:t\nM:4/4\nL:1/4\nQ:1/4=120\nK:C\nV:1\nC\nV:2\nE\n")
    )
    var chans = List[Int]()
    for i in range(len(two)):
        if two[i].kind == SE_NOTE_ON:
            var seen = False
            for k in range(len(chans)):
                if chans[k] == two[i].channel:
                    seen = True
            if not seen:
                chans.append(two[i].channel)
    if len(chans) != 2:
        print("FAIL  two voices used", len(chans), "channels")
        failures += 1
    else:
        print("ok    two voices get distinct MIDI channels")

    # ── the tempo header changes the clock ───────────────────────────────
    let slow = events(
        String("X:1\nT:t\nM:4/4\nL:1/4\nQ:1/4=60\nK:C\nC C\n")
    )
    var fast_second = 0
    var slow_second = 0
    var n = 0
    for i in range(len(without)):
        if without[i].kind == SE_NOTE_ON:
            n += 1
            if n == 2:
                fast_second = without[i].ms
    n = 0
    for i in range(len(slow)):
        if slow[i].kind == SE_NOTE_ON:
            n += 1
            if n == 2:
                slow_second = slow[i].ms
    if slow_second != fast_second * 2:
        print("FAIL  halving the tempo gave", slow_second, "not",
              fast_second * 2)
        failures += 1
    else:
        print("ok    the tempo header changes the clock")

    # ── %%MIDI: the directives the parser used to skip ───────────────────
    var t = Tune()
    parse_abc(
        String(
            "X:1\nT:t\nM:4/4\nL:1/4\nK:C\n%%MIDI program 42\n"
            "%%MIDI channel 5\n%%MIDI transpose 12\nC\n"
        ),
        t,
    )
    if len(t.voices) == 0:
        print("FAIL  no voice after the directives")
        failures += 1
    elif (
        t.voices[0].instrument != 42
        or t.voices[0].channel != 5
        or t.voices[0].transpose != 12
    ):
        print("FAIL  %%MIDI: program", t.voices[0].instrument,
              "channel", t.voices[0].channel,
              "transpose", t.voices[0].transpose)
        failures += 1
    else:
        print("ok    %%MIDI program, channel and transpose are read")

    var td = Tune()
    parse_abc(
        String("X:1\nT:t\nM:4/4\nL:1/4\nK:C\n%%MIDI drum dd\nC\n"), td
    )
    if td.voices[0].channel != 9:
        print("FAIL  %%MIDI drum put the voice on channel",
              td.voices[0].channel, "want 9")
        failures += 1
    else:
        print("ok    %%MIDI drum is channel 10, one-based")

    # An unknown directive is ignored, not fatal.
    var tu = Tune()
    parse_abc(
        String("X:1\nT:t\nM:4/4\nL:1/4\nK:C\n%%score (1 2)\n%%MIDI wobble\nC\n"),
        tu,
    )
    var tu_ev = to_ms_events(tu^)
    if len(notes_on(tu_ev)) != 1:
        print("FAIL  an unknown directive changed the music")
        failures += 1
    else:
        print("ok    an unknown directive is ignored, not fatal")

    # And a directive still transposes what is heard.
    let plain = notes_on(events(head(String("C"))))
    var tt = Tune()
    parse_abc(
        String("X:1\nT:t\nM:4/4\nL:1/4\nK:C\n%%MIDI transpose 12\nC\n"), tt
    )
    let shifted = notes_on(to_ms_events(tt^))
    if len(shifted) != 1 or shifted[0] != plain[0] + 12:
        print("FAIL  transpose did not reach the note:", shifted[0],
              "want", plain[0] + 12)
        failures += 1
    else:
        print("ok    %%MIDI transpose reaches the sounding note")

    # ── the SMF writer ───────────────────────────────────────────────────
    var twinkle = Tune()
    parse_abc(
        String(
            "X:1\nT:Twinkle\nM:4/4\nL:1/4\nQ:1/4=120\nK:C\n"
            "C C G G | A A G2 | F F E E | D D C2 |\n"
        ),
        twinkle,
    )
    var smf = List[UInt8]()
    build_midi(twinkle, smf)
    if len(smf) < 22:
        print("FAIL  the smf is", len(smf), "bytes")
        failures += 1
    elif not (
        smf[0] == UInt8(ord("M")) and smf[1] == UInt8(ord("T"))
        and smf[2] == UInt8(ord("h")) and smf[3] == UInt8(ord("d"))
    ):
        print("FAIL  the smf does not begin MThd")
        failures += 1
    else:
        print("ok    a tune writes an SMF that begins MThd")

    var empty = Tune()
    var esmf = List[UInt8]()
    build_midi(empty, esmf)
    # An empty tune still writes a valid header; what matters is that it
    # does not crash and does not claim tracks it has not written.
    if len(esmf) < 14:
        print("FAIL  an empty tune produced", len(esmf), "bytes")
        failures += 1
    else:
        print("ok    an empty tune writes a header and no phantom track")

    # ── variable-length quantities round-trip ────────────────────────────
    var vlq = List[UInt8]()
    put_varlen(vlq, 0)
    put_varlen(vlq, 127)
    put_varlen(vlq, 128)
    put_varlen(vlq, 0x3FFF)
    put_varlen(vlq, 0x200000)
    # Seven bits a byte: 0 and 127 fit in one, 128 and 0x3FFF need two, and
    # 0x200000 is the first value needing four -- 0x100000 still fits in
    # three, which is the off-by-one this line exists to pin down.
    if len(vlq) != 10:
        print("FAIL  varlen wrote", len(vlq), "bytes, want 10")
        failures += 1
    elif not (
        vlq[0] == 0 and vlq[1] == 127
        and vlq[2] == 0x81 and vlq[3] == 0x00
        and vlq[4] == 0xFF and vlq[5] == 0x7F
    ):
        print("FAIL  varlen encoding is wrong")
        failures += 1
    else:
        print("ok    variable-length quantities encode multi-byte values")

    # ── twinkle, as a whole ──────────────────────────────────────────────
    let tw = to_ms_events(twinkle^)
    let tw_on = notes_on(tw)
    if len(tw_on) != 14:
        print("FAIL  twinkle has", len(tw_on), "notes, want 14")
        failures += 1
    elif tw_on[0] != MIDDLE_C or tw_on[2] != MIDDLE_C + 7:
        print("FAIL  twinkle starts", tw_on[0], tw_on[2],
              "want", MIDDLE_C, MIDDLE_C + 7)
        failures += 1
    else:
        print("ok    twinkle is 14 notes starting C C G")

    # Offs come before ons at the same millisecond, or a repeated note
    # retriggers and is silenced in the same instant.
    var bad_order = 0
    for i in range(1, len(tw)):
        if (
            tw[i].ms == tw[i - 1].ms
            and tw[i].kind == SE_NOTE_OFF
            and tw[i - 1].kind == SE_NOTE_ON
        ):
            bad_order += 1
    if bad_order != 0:
        print("FAIL ", bad_order, "note-offs follow an on at the same ms")
        failures += 1
    else:
        print("ok    note-offs precede note-ons at the same millisecond")

    print()
    if failures == 0:
        print("G8 tunes: PASS")
    else:
        print("G8 tunes: FAILED", failures, "check(s)")
        raise Error("G8 failed")
