# 4. Sound, and time

The two largest examples in the distribution make noise. They are here for
different reasons: `chip` answers "what is `fn` actually *for*", and
`abcplayer` is the closest thing the set has to a full application — a real
parser, an exact clock, and two independent output backends.

Both run code on a real-time audio thread, which is the strictest execution
environment in the collection. No allocation, no locks, no raising, no
unbounded loops. Every one of those constraints is annotated in the source at
the line that obeys it.

## `chip`

2,159 lines across four files. A chip-tune synthesiser in the spirit of the
6581: three voices with sawtooth, triangle, pulse and noise, ring modulation,
hard sync, ADSR envelopes and a shared resonant filter — driven by a 50 Hz
player routine, with an oscilloscope on a C64 palette.

### The lesson, stated plainly

This example exists to show that **one Mojo process can hold both halves of a
foreign ABI with no shim**. `class` gives Cocoa an Objective-C object to send
messages to. `fn` gives CoreAudio a bare C function pointer to call on a
real-time thread. Neither needs a C file, a bridging header, or a block.

The type is spelled as a `comptime`:

```mojo
# The callback's type. An AURenderCallback is a C function pointer, and `fn`
# in a type position is exactly that -- the same aliasing the Objective-C
# bindings use for an IMP.
comptime AURenderCallback = fn(P, P, P, UInt32, UInt32, P, /) -> Int32
```

and installing it is four lines:

```mojo
var cbfn: AURenderCallback = render
let fn_addr = Pointer(to=cbfn).unsafe_bitcast[Int]()[]
var cbs = external_call["calloc", P](Int(2), Int(8))
cbs.unsafe_bitcast[Int]()[unsafe_offset=0] = fn_addr
cbs.unsafe_bitcast[Int]()[unsafe_offset=1] = Int(st)
```

That is an `AURenderCallbackStruct` — a function pointer and a `refCon` — built
by hand and handed to `AudioUnitSetProperty`. Because `fn` *is* a C function
pointer, the eight bytes in that slot are exactly what CoreAudio wants.

Note the second slot. All synthesiser state hangs off one pointer passed
through `inRefCon`, so no global holds the chip and two of these could run at
once. Even the UI's own flags live in the unused tail of that block, so the
callback still needs only the one pointer. The full treatment of this pattern
is [Guide, chapter 6](../guide/06-callbacks.md), under "When the caller is not
Objective-C".

The old AudioUnit API is used rather than `AVAudioSourceNode` for a stated
reason: the modern one takes an Objective-C block, and **Mojo cannot construct
a block**. That is a real limitation of the fork, and it is why the older API
is the right one here.

### What the real-time thread costs you

`fn` is non-raising, and that has consequences that reach down into the DSP:

```mojo
# std.math.sin is a `def`, and a `def` may raise. The render callback is an
# `fn` -- non-raising, C-callable -- so it cannot call one.
```

So the filter carries a hand-rolled nine-term sine series. And its range
reduction is deliberately a single step rather than a loop, because the
argument grows with the frame counter — a subtract-until-in-range loop would
get one iteration longer every fifty frames, "on the audio thread, where the
cost eventually shows up as a dropout and never as an error."

There is no lock in the callback, and the comment is explicit that this is a
choice rather than an oversight: the main thread reads the same state to draw
the meters, and "a torn read costs a wrong pixel for one frame, where a held
lock would cost a click in the speaker." The oscilloscope's ring buffer is
unsynchronised for the same reason.

### The bug worth keeping

The example documents a freeze that took real time to find, and the annotation
is preserved at the line that fixes it:

```mojo
# `var`, not `let`. `let` names the storage of `i` rather than copying
# it, so the index recorded here would follow `i` as the loop below
# advances it -- and voice_part would then be handed 96 instead of 32,
# pointing this voice at another voice's events and, past the end of the
# block, at whatever the heap holds. That read is what hung the audio
# thread: a note of a few billion is an octave loop that never finishes.
var bass_first = i
```

This is the fork's `let`-binds-by-reference rule producing its worst possible
symptom. A garbage note is not a wrong pitch — it is a hang, because the octave
normalisation loops. And a hang on the audio thread stops the speaker without
raising anything. The fix that stuck was a clamp in `midi_hz`, on the grounds
that the audio thread must never be handed an input it can loop forever on.

Two other Cocoa traps are recorded here and are worth knowing:

- **The retain is not optional.** A Mojo-made `NSView` handed to AppKit is
  released at the end of the statement that made it, after which the first
  `drawRect:` traps inside AppKit with a stack that says nothing about
  ownership.
- **Build fonts once.** Asking for a font inside `drawRect:` thirty times a
  second eventually returns nil, and a nil into an attributes dictionary raises
  from inside AppKit's drawing machinery.

**The lesson: `fn` is the C ABI, and a real-time thread means what it says.**
Both documented failures here were silence rather than crashes, which is the
failure mode that makes you blame the audio system instead of your code.

## `abcplayer`

3,344 lines across nine files — the largest example in the distribution. It
reads ABC notation, parses it fully (repeats, first and second endings,
tuplets, broken rhythm, ties, grace notes, chord symbols, key signatures and
modes), schedules it to the sample, and plays it through either the chip
synthesiser or General MIDI — or writes a standard MIDI file instead.

### Time is an integer

The central design decision is stated in `model.mojo` and everything follows
from it:

> **Time is an integer.** Durations are counted in ticks at 480 per quarter
> note — 1920 per whole note — and never in seconds or doubles. That number is
> the standard MIDI resolution and it divides exactly by everything ABC can
> ask for: a 1/64 note is 30 ticks, a triplet eighth is 160, a dotted quarter
> is 720. Nothing rounds, so a tune that should land on the bar line does,
> however many tuplets and dots came before it.

There is exactly **one** place where that integer clock becomes a sample
position, and it rounds once:

```mojo
fn tick_to_sample(tick: Int, bpm: Int, per_beat: Int, sample_rate: Int) -> Int:
    let denom = bpm * per_beat
    if denom <= 0:
        return 0
    return (tick * sample_rate * 60 + denom // 2) // denom
```

Choosing 480 also means the MIDI writer needs no conversion at all — the ticks
it writes are the ticks the model holds.

### Dispatch inside the buffer, not at its edges

The timing argument is the reason this example was written, and it is
measurable. Notes are not started by waking a thread at the right moment; the
schedule is compiled to sample offsets ahead of time, and the render callback
splits its own buffer at each event:

```mojo
span = min(frames - filled, next_event - now)
```

The measurement, taken with 512-frame buffers deliberately chosen so that no
onset falls on a buffer boundary: scheduled at samples 0, 48000, 96000, 144000;
measured at 0, 48001, 96001, 144000. **Worst error one sample — 0.021 ms** —
and the source is candid that the one-sample discrepancies are the onset
detector's threshold rather than the scheduler.

One ordering detail carries real musical weight. The schedule sorts NOTE_OFF
before NOTE_ON at the same sample, "because releasing first leaves the voice
free for the new note. The other order steals a voice that is about to be freed
and drops a note."

### Two backends from one model

The same schedule drives three outputs, which is the strongest argument for
keeping the model free of audio concerns: the chip synthesiser (three voices,
with stealing that takes the oldest sounding note "because it is the one
furthest through its decay and the least missed"), Apple's DLS synth for
General MIDI, and a standard MIDI file.

The file is the interesting one, and the README says why:

> The MIDI file is the proof. It opens in any notation program, so the pitches,
> the lengths and the bar positions can be checked by something that was not
> written here.

That is the right instinct about correctness. A parser that only feeds its own
synthesiser can be wrong in a way that sounds fine.

### What the port found

`abcplayer` is a port of a C++ program, and it fixed five defects in it. Four
were findable by reading:

1. **Key signatures did nothing.** `applyKeySignature()` returned its argument
   unchanged, so every tune played in C major.
2. **Explicit accidentals were dropped.** The test looked for `#` and `b`
   rather than ABC's `^` and `_` — and was unreachable anyway, behind a guard.
3. **First and second endings were ignored**, giving `A B A B` where the music
   says `A B A C`.
4. **Middle C was an octave low**, from `base_octave * 12` with `base_octave`
   of 4 — "a C, an octave low, and sounds plausible enough to survive review."
5. **Chord symbols corrupted the melody's timeline**, because generated chord
   notes were appended to the melody voice and advanced its clock.

The first two meant the original played most folk tunes wrong from the opening
bar.

### A catalogue of compiler traps — most of them now historical

`abcplayer` records six failure modes it hit during the port, each annotated at
the line that works around it, and each with its *symptom* rather than just its
rule. That made it the most useful bug catalogue in the distribution.

**Every one was retested against the shipped compiler in August 2026, and four
no longer reproduce.** The workarounds are still in the source, so the examples
below describe code that is no longer necessary. They are kept here because the
comments are still in the files, and a reader who meets one deserves to know it
is a fossil.

| What the source says | Retested |
|:---|:---|
| `+=` through a `List` subscript updates a temporary — rests occupied no time | **Fixed.** Reverting the workaround produces a byte-identical MIDI file |
| A `fn` returning a heap-owning type crashes in `DialectConversion` | **Fixed.** Now a clean diagnostic asking for `.copy()` |
| Passing a `mut` struct on to a second function crashes at the call site | **Fixed.** Works |
| Reading `self` while appending to a `List` `self` owns crashes | **Fixed.** Works |
| A `let` bound into a `List` that later *grows* dangles | **Caught** — but reported as `error: failed to run the pass manager`, which says nothing |
| A `let` naming a list slot that is later *written* breaks an insertion sort | **Still real — but no longer silent** |

That last row is the one to carry away, because it is not a bug — it is
[`let` binding by reference](#the-bug-worth-keeping), working exactly as
designed, in its most damaging form. The insertion sort in `midi.mojo` is four
lines of ordinary code:

```mojo
for a in range(1, len(times)):
    let t = times[a]        # names the slot; the shift below writes over it
    var b = a - 1
    while b >= 0 and times[b] > t:
        times[b + 1] = times[b]
```

Sorting `5 3 9 1` that way yields `5 5 9 9`. The behaviour has not changed and
`let` still binds by reference, but the compiler now warns at the write that
invalidates the read, names the binding, and tells you to use `var` for a
snapshot. The comment in `midi.mojo` predates that diagnostic.

One non-compiler caveat also stands: **rebuilding a string with `chr()` mangles
UTF-8** — slice instead, or a title with an accent comes out as mojibake.

The cost of the historical traps was real: `music.mojo` is 823 lines *partly
because* the chord emitter, bar mirror and broken-rhythm handler had to be
written out inline. That shape is now a scar rather than a requirement, and the
workarounds could be unwound with a test at each site.

**The lesson: exact timing is a representation problem, not a scheduling
problem.** Pick an integer clock that divides by everything the input can ask
for, round once, and dispatch inside the buffer. Everything else — three
backends, a MIDI file that other programs can check — follows from the model
staying clean.

> **One caveat if you are reading or editing this example.** `abcplayer` ships
> its own copy of `chip.mojo`, a verbatim duplicate of `chip/chip.mojo` with a
> provenance header asking that the two be kept in sync. That is a deliberate
> trade — an IDE example should be a folder that opens and runs with no include
> flags — but it is a real drift risk, and a fix to one will not reach the
> other.
