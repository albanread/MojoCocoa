# 8. What to understand

Nine things about this synthesiser are not obvious from listening to it.

## 1. The player routine is where the music is

The oscillator is the part everyone describes and the part that matters least.
Three voices and no memory means everything characteristic happens in a routine
that rewrites registers fifty times a second:

- a **chord** is one voice switching between three notes on consecutive frames
- a **held note** is kept alive by sweeping its pulse width
- a **drum** is noise plus a downward pitch sweep

> *So the interesting code is not the oscillator. It is this: fifty edits a
> second to a handful of registers, and out comes music.*

## 2. The envelope table is the single most important detail

Decay and release are **not exponential**. The chip counts down at a rate
divided further as the level falls — below 93, then 54, 26, 14 and 6 — so the
tail flattens in five steps.

> *Replacing that with a smooth exponential is the single change that makes
> this sound like a synthesiser instead of a games machine.*

Get every oscillator right and this wrong, and it sounds like a modern synth
playing chip waveforms.

## 3. Selecting two waveforms ANDs them

Not a mix, not an average — a bitwise AND, because that is how the outputs were
wired. Most of the timbres people remember come from an accident.

The interface follows the hardware: the ABC player's voice editor presents the
four waveforms as **toggles rather than a radio group**, because presenting
them as exclusive would both remove capability and teach the wrong model.

## 4. Noise has a pitch

The LFSR shifts on a rising edge of accumulator bit 19, so the frequency
register controls the noise's character — low is a rumble, high is a hiss. A
rising noise sweep is a **frequency** sweep, not a filter sweep.

This is why a chip drum is written as a note, and why the drum code sweeps `hz`.

## 5. Ring modulation is one XOR

A triangle wave folds according to its top bit. Ring modulation replaces that
bit with the previous voice's:

```mojo
if ((acc24 ^ ring_source_msb) & 0x800000) != 0:
    folded = (~acc24) & 0xFFFFFF
```

On a modular synthesiser this is a four-quadrant multiplier. Here it is one XOR
in a fold test — *"and it is why bells and gongs sound the way they do."*

## 6. The filter is only conditionally stable, and the bug proved it

A Chamberlin state-variable filter is stable while `f + q < 2`. The original
code clamped `f` to a flat 1.4, which does not express a constraint coupling two
variables — and at the demo settings it sat at **f 1.099 against a bound of
1.116**. Inside by 1.5%, with nobody aware there was a bound.

> *Nothing found this until a tune began sweeping the cutoff, because nothing
> had ever changed it while a note was sounding.*

Static settings never explore the parameter space. It took the ABC player's
`[I:chip cutoff=…]` directive to walk it out.

## 7. NaN is permanent, and clamping the output cannot save you

The filter's state feeds back into itself, so one NaN poisons every subsequent
sample. The synth goes silent for good.

> *The output clamp below cannot help, because by then the damage is in the
> state rather than the sample.*

The general rule: in a feedback system, validate what goes **back in**, not
what comes out. And `low != low` is the NaN test — the only value not equal to
itself — which avoids an import an `fn` could not make anyway.

## 8. A loop whose trip count grows is a real-time bug

```mojo
# Subtracting 2*pi until the argument lands in range is harmless for a
# filter coefficient and quietly ruinous for vibrato: that argument grows
# with the frame counter, so the loop gets one iteration longer every fifty
# frames -- on the audio thread, where the cost eventually shows up as a
# dropout and never as an error.
```

The vibrato calls `_sin(frame * 0.55)` and `frame` counts up forever. A
loop-based range reduction gets slower for as long as the program runs, and the
symptom arrives ten minutes in as a click with nothing to point at.

**On a real-time thread, "correct but unboundedly slow" is a bug.**

## 9. Silence is a worse failure than a wrong note

Two separate places clamp their input for the same reason:

```mojo
"""Clamped, because this runs on the audio thread and the octave loop below
is a loop: a nonsense note would be a hang, not a wrong pitch."""
```

> *On a real-time thread a value that is merely wrong and a value that hangs
> are different severities.*

A wrong note is audible, diagnosable and recoverable. A hang on the audio
thread is silence for the session, with no crash and no stack trace — and in
the bug that produced this rule, it happened about three runs in five, *"which
is exactly the failure rate that makes you blame the audio system."*

## A short list of things that will bite

| If you change… | …this happens |
|:---|:---|
| the envelope to a smooth exponential | it stops sounding like a chip |
| the phase accumulator to a float | the pitch quantisation and hard edges go |
| noise to a random generator | it hisses instead of rasping, and loses its pitch |
| `var prev` to `let prev` in the oscillator | hard sync and the noise clock stop, silently |
| `var left` to `let left` in the player | the drum's pitch sweep goes off by one frame |
| the pulse sweep to reach 0 or 4095 | the voice drops out at the edge of every cycle |
| the envelope multiply before the DC centring | a thump on every note-on |
| `f`'s clamp back to a constant | the filter diverges at high cutoff with resonance |
| the NaN reset out of the filter | one divergence silences the synth until restart |
| `_sin`'s range reduction to a loop | a dropout ten minutes in, with no error |
| a `def` anywhere on the render path | it will not install; `fn` is the C-ABI kind |

## Running it

```bash
cocoamojo --build examples/chip/main.mojo -I examples/chip -o /tmp/chip
```

| | |
|:---|:---|
| `/tmp/chip` | the built-in tune |
| `/tmp/chip examples/chip/tunes/ode.abc` | an ABC tune |

| Key | |
|:---|:---|
| `Space` | pause |
| `1` `2` `3` | mute a voice |
| `<` `>` | cutoff |
| `-` `+` | resonance |
| `F` | filter mode |
| `Q` | quit |

The same engine, driven from a sample-accurate schedule instead of a 50 Hz
score, is the [ABC player](../AbcPlayerWalkthrough/index.md).
