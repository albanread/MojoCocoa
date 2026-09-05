# 1. What it is imitating

## The chip

In 1982 the Commodore 64 shipped with a sound chip that was, by the standards
of home computers then, absurd. Most machines of the era had a square-wave
beeper. This one had three oscillators with four selectable waveforms, a
four-stage envelope generator per voice, a shared multimode resonant filter,
ring modulation and hard sync.

It was designed by a synthesiser enthusiast who set out to build a proper
subtractive synthesiser rather than a sound-effects generator, and the
architecture shows it — the signal path is the one a Minimoog has, in silicon,
for a home computer.

Two accidents of that design are why it has a *sound* rather than merely a
specification:

- **It is part digital, part analogue.** The oscillators and envelopes are
  digital; the filter is analogue, and its cutoff curve varies noticeably
  between individual chips. Two machines do not sound quite the same.
- **The waveform selector was wired in a way its designer did not intend.**
  Selecting two waveforms at once ANDs their outputs together, producing
  timbres nobody designed, which musicians immediately began using on purpose.

The register interface is the other half of the story. There is no note
concept, no polyphony manager, no sequencer. There is a bank of registers, and
whatever writes them fifty times a second is the instrument.

## Why this is not an emulator

The source is direct about the choice, in its first paragraph:

> *Not an emulator. rechip exists, it is cycle-exact, and it is thousands of
> lines of measured analogue behaviour. This is the other thing — the
> arithmetic that gives the chip its voice, written plainly, small enough to
> read in one sitting and fast enough to run under a real-time deadline.*

That is a real distinction and worth being precise about.

A **cycle-exact emulator** reproduces the chip's behaviour sample by sample,
including its documented bugs, its undocumented ones, the analogue sag of its
output stage, and the fact that the filter differs between production runs. It
exists so that decades of existing music plays back correctly. It is thousands
of lines of measurement, and it must be, because the goal is fidelity to
hardware including hardware's mistakes.

This is the **other** goal: the arithmetic that produces the character, in 579
readable lines. It cannot play back an existing chip tune bit-accurately and
does not try. It can be read in a sitting, and it can be modified — which an
emulator, by construction, cannot be.

Where the two diverge, the source says so rather than glossing:

> *The AND is faithful; what it cannot reproduce is that the real result also
> sags with the analogue behaviour of the output stage, so combined waveforms
> here are brighter than a 6581's.*

And for the filter:

> *The 6581's cutoff curve is notoriously non-linear and differs chip to chip,
> so there is no correct mapping to reproduce — this is a plain linear sweep
> across the range the chip covers.*

There is no correct answer to reproduce, so it does not pretend to have found
one.

## The four things that make it sound right

The header lists them, and they are worth reading as a set — each is a place
where the obvious modern implementation would sound wrong:

> - *the oscillators are 24-bit phase accumulators, so the pitch drifts in the
>   same quantised way and the waveforms have the same hard edges*
> - *the noise is the actual 23-bit LFSR with the actual output taps, which is
>   why it rasps instead of hissing*
> - *the envelope decays by the chip's period-stretching table rather than by an
>   exponential curve, which is the difference between a C64 snare and a beep*
> - *the pulse width is a register you are expected to modulate every frame*

Each names a substitution that a from-scratch synthesiser would naturally make,
and each substitution destroys the character:

| the obvious choice | what it costs |
|:---|:---|
| a floating-point phase, band-limited | the hard edges and quantised pitch go; it sounds clean and generic |
| white noise from a random generator | hisses instead of rasping; the noise loses its pitch |
| an exponential decay | *"the difference between a C64 snare and a beep"* |
| a static pulse width | the sound goes lifeless in about half a second |

Notice that all four are the machine's *limitations*. The pitch is quantised
because 24 bits was what fitted; the noise rasps because a 23-bit shift
register was cheap; the envelope steps because a proper exponential would have
needed a multiplier. Reproducing the sound means reproducing the constraints —
which is why this is a piece of arithmetic and not a preset.

## Integer, because the chip was

> *The chip is integer hardware, so this is integer arithmetic. The only
> floating point is the filter and the final sample.*

Phase accumulators, waveform generation, the noise register and the envelope
are all integer. The filter is float because it is the analogue part of the
original; the final sample is float because that is what CoreAudio takes.

This is not a performance decision. Integer arithmetic *is* the model — a phase
accumulator that wraps at 2²⁴ is what produces the pitch quantisation, and a
float accumulator would silently remove it.

## What is in the folder

| File | |
|:---|:---|
| [chip.mojo](../examples/chip/chip.mojo) | the synthesiser: oscillators, envelopes, filter |
| [tune.mojo](../examples/chip/tune.mojo) | the player routine — the part people forget |
| [abc.mojo](../examples/chip/abc.mojo) | a small ABC reader, so real tunes can be played |
| [main.mojo](../examples/chip/main.mojo) | CoreAudio, and the window |

`chip.mojo` depends only on the standard library, which is why the
[ABC player](../AbcPlayerWalkthrough/index.md) can vendor it as a single file:

```
# --- vendored from examples/chip/chip.mojo ---
# abcplayer reuses the chip synthesiser's DSP engine. An IDE example is a
# folder that opens and runs with no include flags, so the one module it needs
# from the chip example lives here as a copy rather than as a cross-folder
# import.
```

A verbatim copy with a header saying so, and an instruction to keep the two in
step. Not elegant, and honest about why: an example folder that needs include
flags to open is an example that does not open.
