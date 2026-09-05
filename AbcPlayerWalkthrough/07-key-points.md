# 7. What to understand

Nine things about this player are not obvious from listening to it.

## 1. Nothing ever sleeps

The whole design follows from refusing `sleep_until`. The tune becomes a list
of *"at sample N, do this"*, and the audio callback — the only thread with a
reliable clock — applies each event at its offset inside the buffer it is
already filling.

Measured worst error: **1 sample, 0.021 ms**, and the source says that is
probably the measuring apparatus rather than the scheduler. The design it
replaces is out by 1–2 ms idle and tens under load, *varying*, which is what
the ear hears as looseness.

## 2. Time is an integer until the last possible moment

480 ticks to the quarter note, chosen because it divides exactly by everything
ABC can ask for — 1/64 notes, triplets, dots, quintuplets. Then **one**
conversion:

```mojo
return (tick * sample_rate * 60 + denom // 2) // denom
```

Computed from the event's absolute tick, not from the previous event's sample,
so there is nothing to accumulate. Floating-point timestamps would drift by a
fraction of a tick per note — inaudible for a hundred notes and then visibly
wrong.

## 3. The MIDI file is the proof, not a feature

> *A MIDI file is a public format with other readers: if the tune opens in a
> notation program with the right pitches, the right lengths and the bar lines
> in the right places, then the parser and the tick arithmetic are correct, and
> no amount of listening to a synthesiser could establish the same thing.*

Listening tests your ears. A file read by software that was not written here
tests your model — and displays it as notation, so a bar that does not add up
is visible instead of audible.

## 4. An accidental holds to the end of the bar

Not to the end of the note. `^F A F` has **two** sharp Fs, and the F in the
next bar is natural again. A parser that misses this plays wrong notes in
roughly every tune containing an accidental, which is most of them.

Held in one `Int` as seven nibbles, biased by 8 so that a natural sign — an
alteration of zero, and a real instruction — is distinguishable from "nothing
set".

## 5. A key signature is arithmetic

Sharps arrive F C G D A E B; flats take that list backwards. Two sharps means F
and C are raised, and that *is* D major. `key_alter` derives it; there is no
table to half-fill, which is the shape the original C++ bug had.

Modes are a subtraction on the circle of fifths — Dorian −2, Mixolydian −1,
minor −3 — and they matter, because `K:Ador` is in G major's signature and
reading it as A major is three accidentals wrong for the whole tune. Folk
material uses modes constantly.

## 6. First and second endings are the point of a repeat

`|: A |1 B :|2 C |` plays **A B A C**. Text-duplicating expanders produce A B A
B, so a repeated strain ends on the wrong phrase every time.

The mechanism is one rule — at `:|`, replay from the repeat start but stop
where the first ending began — and there is no special case for `|2` at all;
the second pass simply falls through into it.

Expanding over **events** rather than text is what makes repeats across line
breaks, and inside one voice of several, need no code.

## 7. The audio thread's contract shapes three unrelated decisions

May not allocate, may not lock, may not raise. Consequences:

- the schedule is `calloc`'d into a flat block before the unit starts, and only
  read after
- `midi_to_hz` clamps, because its octave loop would **hang** on a nonsense
  note — *"a wrong pitch is a wrong note; a hang is silence for the session"*
- `render` is an `fn`, which in this dialect is both non-raising and C-callable,
  so it goes straight into `AudioUnitSetProperty` with no shim

And the deliberate absence of a lock, which is a judgement rather than an
oversight: a torn read costs one frame of one oscillator; a lock can make the
audio thread wait on the UI thread, and a late buffer is an audible click.

## 8. A chord must not advance the clock

When repeats are expanded, every event is re-stamped — and only things that
occupy time advance the clock. Get it wrong and `[CEG]` becomes C, E, G one
beat apart.

The comment records the symptom because the symptom is misleading: an arpeggio
where a chord should be looks exactly like a chord-parsing bug, and the parser
is fine. The fault is three stages downstream in the re-timing.

## 9. The compiler notes in the README are now history

The README lists four compiler behaviours that cost real time during the port.
**Three of them no longer reproduce.** From `CLAUDE.md`, retested August 2026
against the shipped compiler:

| trap | status |
|:---|:---|
| `let` binds by reference | **still true** — it is the language, and there is now a warning for the tracked case |
| `+=` through a `List` subscript | fixed; reverting the workaround gives a byte-identical MIDI file |
| passing `mut Struct` on to a second function | fixed |
| a `fn` returning a heap-owning type | now a clean diagnostic asking for `.copy()` |
| reading `self` while appending to its own `List` | fixed |

The workarounds are still in the source — the chord emitter, the bar mirror and
the broken-rhythm handler are written inline because passing `mut Struct` used
to crash — and the annotations are still there beside them.

**Do not write new code around any of these except the first**, and do not cite
them as current behaviour. The rule that produced this list is worth keeping:
write the four-line reproducer and run it before working around a compiler.

## A short list of things that will bite

| If you change… | …this happens |
|:---|:---|
| ticks to a float | voices drift apart after a few hundred notes |
| `tick_to_sample` to accumulate from the previous event | the same drift, faster |
| the accidental map to store raw alterations | `=F` silently does nothing |
| repeat expansion to work on text | endings break; line breaks and voices need special cases |
| a chord member to take the current tick | `[CEG]` arpeggiates, one member per beat |
| the step sort's tie-break | a note is dropped whenever one ends as another begins |
| a `List` on the audio thread | an allocation under a 10.7 ms deadline |
| `midi_to_hz`'s clamp | a nonsense note hangs the audio thread — silence, no crash |
| a lock around the registers | the audio thread waits on the UI thread; clicks |
| fonts built inside `drawRect:` | nil after a while, and a trap inside AppKit |

## Running it

```bash
cocoamojo --build examples/abcplayer/main.mojo -o /tmp/abcplayer
```

| | |
|:---|:---|
| `/tmp/abcplayer tunes/carolan.abc` | chip voices |
| `… --midi` | Apple's DLS synthesiser |
| `… --write=out.mid` | a Standard MIDI File, no playing |
| `ABC_SHOT=<path>` | draw one frame to a PNG and exit |

The synthesiser it plays through is covered in
[its own walkthrough](../ChipWalkthrough/index.md).
