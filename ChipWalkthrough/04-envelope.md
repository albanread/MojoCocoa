# 4. The envelope

The README makes an unusually strong claim about this one file's worth of
arithmetic:

> *The envelope table is the single detail that matters most. Replace it with a
> smooth exponential and the thing stops sounding like a C64 and starts
> sounding like a synthesiser.*

## What a textbook envelope does

Attack rises to full, decay falls to the sustain level, sustain holds, release
falls to silence. Every synthesiser has this, and the decay is normally
exponential — a fixed *fraction* removed per unit time, which gives the smooth
asymptotic curve of a plucked string.

## What this one does

```mojo
"""One sample of the envelope. Returns the level, 0..255.

The decay and release are not exponential curves. The chip counts down at
a rate that is divided further as the level falls -- once below 93, then
54, 26, 14 and 6 -- so the tail flattens in five visible steps. Replacing
that with a smooth exponential is the single change that makes this
sound like a synthesiser instead of a games machine.
"""
```

```mojo
let level = env >> 16
var divisor = 1
if level <= 6:
    divisor = 30
elif level <= 14:
    divisor = 16
elif level <= 26:
    divisor = 8
elif level <= 54:
    divisor = 4
elif level <= 93:
    divisor = 2
let step = vget(st, voice, V_DINC if phase == ENV_DECAY else V_RINC)
env -= step // divisor
```

The rate is **piecewise constant**. Above level 93 the envelope falls at full
speed; below 93 at half; below 54 at a quarter; below 26, 14 and 6 slower
again, down to a thirtieth.

The hardware reason is economy. A true exponential needs a multiply per sample,
and this chip had no multiplier. A counter whose *reload period* is stretched at
a few thresholds is a handful of comparators, and it approximates an exponential
well enough — which is to say, not very, and audibly.

The result is a decay that falls quickly, then *sticks* — five discrete
flattenings on the way down. That is the shape of a C64 note, and it is why a
snare made this way cracks and then hangs rather than simply fading.

## The attack is linear, and only the falling phases stretch

```mojo
if phase == ENV_ATTACK:
    # The attack is linear. Only the falling phases are stretched.
    env += vget(st, voice, V_AINC)
```

Asymmetric, matching the hardware. It also matters musically: a linear attack
has a hard front edge, which is where the *snap* on a chip bass comes from.

## The rate table, and the 3× rule

```mojo
# The chip's attack times in milliseconds, 0..15. Decay and release run three
# times slower for the same index, which is why a C64 bass can have a snap on
# the front and still ring for half a second.
fn attack_ms(index: Int) -> Int:
    if index == 0: return 2
    if index == 1: return 8
    ...
    if index == 9: return 250
    if index == 10: return 500
    ...
    return 8000
```

Sixteen values from **2 ms to 8 seconds**, and the spacing is not even —
roughly linear at the short end, then jumping. Index 8 is 100 ms, index 9 is
250 ms; that step is where a musician's choices actually live, and it is the
hardware's.

Then:

```mojo
vput(st, voice, V_AINC, rate_increment(attack_ms(a)))
vput(st, voice, V_DINC, rate_increment(attack_ms(d) * 3))
vput(st, voice, V_SUS, (s & 15) * 17)  # 4 bits scaled to 0..255
vput(st, voice, V_RINC, rate_increment(attack_ms(r) * 3))
```

One table, three uses. Decay and release take the same index times three, which
is the hardware's ratio — so the same nibble means a much longer fall than rise.
The comment explains the musical consequence rather than the mechanism: *a snap
on the front and still ring for half a second*.

`* 17` for the sustain is `0xFF / 0xF` — a 4-bit register scaled to 8 bits so
that 15 maps to 255 exactly, not 240.

## The guard that stops a voice going silent forever

```mojo
fn rate_increment(ms: Int) -> Int:
    """Envelope steps per sample, 16.16 fixed point, for a full 0..255 sweep.

    Clamped to at least one so the shortest attack still moves; a zero here
    would hang the envelope in its attack phase and the voice would never
    sound.
    """
    let samples = (ms * SAMPLE_RATE) // 1000
    if samples < 1:
        return 255 << 16
    let inc = (255 << 16) // samples
    return 1 if inc < 1 else inc
```

Two clamps for two different failures.

`samples < 1` handles a rate so fast it rounds to no samples at all — jump
straight to full. And `inc < 1` handles the opposite: an 8-second release
divided across 384,000 samples could round to **zero** increment, at which point
the envelope never moves and the voice is stuck in its attack phase, silent,
forever.

Integer division rounding to zero is the whole bug, and one comparison prevents
it.

## Fixed point at 16.16

The envelope level is kept as 16.16 fixed point and read out as `env >> 16`.
The reason is the one above: a full sweep over 384,000 samples needs a step
much smaller than one unit of the 0–255 output, so the fractional bits are
where the slow envelopes actually live.

## Why the shape matters more than the timing

An exponential decay and this stepped one can be tuned to the same *duration* —
same time from full to silence. They still sound different, because the ear
follows the shape of the fall rather than its endpoint. The stepped version
lingers at low levels far longer than an exponential would, which is exactly
the "hang" that makes a chip drum sound like one.

That is what the README means by *the single detail that matters most*: it is
not an accuracy detail. Get the oscillators right and the envelope wrong and it
sounds like a modern synthesiser playing chip waveforms.
