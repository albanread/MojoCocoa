# 5. The filter

One filter, shared by all three voices, with a per-voice routing switch. It is
the analogue part of the original and the only floating-point arithmetic in the
signal path — and it is where the most interesting bug in the example lived.

## Six lines of filter

```mojo
let f = fget(st, S_F)
let q = fget(st, S_Q)
var low = fget(st, S_LOW)
var band = fget(st, S_BAND)
low += f * band
let high = wet - low - q * band
band += f * high
```

A two-pole **state-variable filter** — the Chamberlin topology. Two state
variables, two multiplies, and all three responses available at once:

```mojo
let mode = get(st, S_FMODE)
var filtered = 0.0
if (mode & FILT_LP) != 0:
    filtered += low
if (mode & FILT_BP) != 0:
    filtered += band
if (mode & FILT_HP) != 0:
    filtered += high
```

Low, band and high are all computed anyway, so the mode register selects which
to sum — and because it is a bit mask rather than an enum, combinations work.
That matches the hardware, which also let you select more than one.

`f` controls cutoff, `q` controls damping. Higher resonance means *less*
damping:

```mojo
# Resonance 0..15 maps to damping 1.4 down to 0.1: higher resonance is
# less damping, and the filter rings.
let q = 1.4 - Float64(get(st, S_RES)) * 0.086
```

## The bug: conditionally stable, unconditionally trusted

A state-variable filter is only **conditionally stable**. Roughly, `f + q < 2`;
outside that the state grows without bound.

The original code clamped `f` to a flat 1.4 and left it there. The comment now
records what happened:

```mojo
# The two coefficients are NOT independent. A Chamberlin state-variable
# filter is stable only while f + q < 2, so the usable cutoff depends on
# the resonance chosen with it. Clamping f to a flat 1.4 was enough for
# the single cutoff and resonance the demo tunes used, and left the filter
# sitting just inside its own limit there -- f 1.099 against a bound of
# 1.116 -- with much of the rest of the range unstable. At cutoff 1700
# with resonance 5 the state diverges within a second, and everything
# after that is a buzz.
#
# Nothing found this until a tune began sweeping the cutoff, because
# nothing had ever changed it while a note was sounding.
```

Read that carefully, because it is a very good bug.

**The demo settings sat at f = 1.099 against a bound of 1.116.** Inside the
limit by 1.5%. Every test passed, every tune played, and the filter was one
small parameter change away from diverging — with no margin anyone had measured,
because nobody knew there was a bound to have a margin against.

**The flat clamp was the wrong shape.** A constant limit on `f` cannot express a
constraint that couples `f` and `q`. It happened to be safe at one point in a
two-dimensional space.

**Nothing found it for a long time**, and the reason is the sharpest part:
*nothing had ever changed the cutoff while a note was sounding*. Static
settings, chosen inside the stable region, never explore the space. It took the
ABC player's `[I:chip cutoff=…]` directive — a tune that *sweeps* the filter —
to walk the parameter out of the region.

The fix makes the limit depend on the resonance actually in use:

```mojo
var limit = 0.95 * (2.0 - q)
if limit > 1.4:
    limit = 1.4
if f > limit:
    f = limit
```

`2.0 - q` is the stability bound; `0.95` is a 5% margin; the 1.4 cap keeps the
old ceiling. High resonance now costs cutoff range, which is the real trade the
topology imposes.

## The second failure: NaN is sticky

Clamping the coefficients is not sufficient, because a filter can already be
diverging when the coefficients change. So the state is clamped too — and the
comment explains why an output clamp would not have helped:

```mojo
# A state-variable filter is only CONDITIONALLY stable, and nothing
# stops a tune asking for a high cutoff and a high resonance at the
# same time. Left alone the state diverges, reaches infinity, and the
# next subtraction turns it into NaN -- which is sticky: every sample
# after it is NaN too, so the synth goes silent for good and only a
# restart brings it back. The output clamp below cannot help, because
# by then the damage is in the state rather than the sample.
#
# A real filter saturates, so this one does. The reset on NaN is what
# makes it recoverable rather than merely quieter.
if low != low or band != band:
    low = 0.0
    band = 0.0
if low > FILTER_CEILING:
    low = FILTER_CEILING
elif low < -FILTER_CEILING:
    low = -FILTER_CEILING
```

Three things worth extracting.

**The failure is permanent.** `inf - inf` is NaN, and NaN propagates through
every subsequent operation. The state variables feed back into themselves, so
one NaN poisons the filter for the rest of the session. Not a glitch — silence
until restart.

**Clamping the output cannot fix it**, because the damage is in the *state*.
This is a general lesson about feedback: validating what comes out is useless
when the thing that is wrong is what gets fed back in.

**`low != low` is the NaN test.** NaN is the only value not equal to itself, and
this idiom avoids needing an `isnan` import — which matters here, because this
is an `fn` on the audio thread and cannot call anything that might raise.

And the justification for saturating rather than erroring: *a real filter
saturates, so this one does*. Clipping is a physical behaviour of an analogue
filter driven too hard. Reproducing it gives a sound rather than a silence.

## Recomputing only when dirty

```mojo
comptime S_DIRTY = 6       # filter coefficients need recomputing
```

```mojo
if get(st, S_DIRTY) != 0:
    recompute_filter(st)
```

`recompute_filter` calls `_sin`, which is a nine-term series — expensive by
audio-thread standards. The dirty flag means it runs when a register changes,
not per sample. It is checked once at the top of `chip_render` and again after
each 50 Hz player tick, which are the only two moments the registers can have
changed.

## The sine that could not be imported

```mojo
fn _sin(x: Float64) -> Float64:
    """Sine by series.

    std.math.sin is a `def`, and a `def` may raise. The render callback is an
    `fn` -- non-raising, C-callable -- so it cannot call one. Nine terms is
    far more than a filter coefficient needs.
    """
```

The standard library's `sin` is a `def`, and a `def` may raise. This code path
is reached from an `fn`, so it cannot call one. Nine terms of the Taylor series
it is.

And inside it, a range-reduction comment that is the best single warning in the
file:

```mojo
# Range reduction in one step, not a loop. Subtracting 2*pi until the
# argument lands in range is harmless for a filter coefficient and quietly
# ruinous for vibrato: that argument grows with the frame counter, so the
# loop gets one iteration longer every fifty frames -- on the audio
# thread, where the cost eventually shows up as a dropout and never as an
# error.
```

The textbook `while x > 2*pi: x -= 2*pi` is fine when the argument is small. The
vibrato in [chapter 6](06-player.md) calls `_sin(frame * 0.55)`, and `frame`
counts up forever — so the loop gets one iteration longer every fifty frames.
After ten minutes it is thousands of iterations, on the real-time thread.

**The failure mode is the point.** It does not error. It does not sound wrong.
It gets gradually more expensive until a buffer is late, and then you hear a
click — in a program that has been running for ten minutes, with nothing to
point at. One multiply and one truncation instead:

```mojo
let turns = x * 0.15915494309189535     # 1 / 2*pi
var t = x - 6.283185307179586 * Float64(Int(turns))
```

Constant time, whatever the argument.

## What is not modelled

> *The 6581's cutoff curve is notoriously non-linear and differs chip to chip,
> so there is no correct mapping to reproduce — this is a plain linear sweep
> across the range the chip covers.*

```mojo
let hz = 200.0 + Float64(cutoff) * 5.8
```

200 Hz to about 12 kHz, linearly. The real chip's curve is famously
inconsistent — the reason chip musicians talk about which revision a machine
has. There is no single curve to be faithful to, so the code picks a defensible
one and says that is what it did.
