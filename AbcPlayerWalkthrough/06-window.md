# 6. The window

`ui.mojo` is 1,018 lines and draws everything itself:

> *There is no NSButton and no NSSlider — the panel is a few dozen rectangles
> and a hit test, which is less code than wiring that many controls to
> target/action, and it keeps the whole interface in one place you can read.*

That is a defensible claim for this interface specifically. Roughly forty
controls, each of which sets one integer register, would be forty outlets and
forty actions. Drawn directly, the whole panel is a layout function and a hit
test — and adding a register is one entry in one table.

## Three things live in it

**A tune list.** Whatever is in `tunes/` at startup, plus anything **Add…**
brings in through a file panel.

**A voice editor showing all three voices at once.** The reason is musical
rather than aesthetic:

> *There are only three, and a patch is the relationship *between* them —
> which voice carries the melody, which one is the noise channel — so none of
> them is hidden behind a tab.*

Every register the chip actually has is on screen. Two details in that layout
are worth extracting:

> *the four waveforms (they AND together, which is what the hardware did, so
> they are toggles and not a radio group)*

The interface tells you the truth about the hardware. On the real chip
selecting two waveforms ANDs their outputs — which is where most of the
memorable timbres come from — so presenting them as mutually exclusive would
both remove capability and teach the wrong model.

> *Cutoff, resonance and level sit in their own block underneath, labelled,
> because they belong to the one filter all three voices share — a control that
> looks per-voice and is not would be worse than no label at all.*

There is one filter, not three. Putting cutoff in each voice's column would
imply three independent filters, and the user would spend a while wondering why
voice 2's cutoff moves voice 1.

**A playable keyboard**, using Logic Pro's and GarageBand's *Musical Typing*
layout:

```text
     W E   T Y U   O P          the black keys, in their piano positions
    A S D F G H J K L ;         the white keys, from C
```

> *the mapping a Mac musician already has in their fingers*

`R` and `I` are gaps because a piano has no black key between E and F, or
between B and C — the layout is a picture of a keyboard, so the gaps have to be
there.

| Key | |
|:---|:---|
| `Z` `X` | octave down / up |
| `C` `V` | level down / up |
| `Tab` | sustain |
| `Space` | play / pause |
| `Q` `Esc` | quit |

> *`Z X C V` are free for that job precisely because they are not note keys,
> which is why Logic chose them and why this does too.*

Following an existing convention rather than inventing one gets the layout
*and* its reasoning for free.

## Velocity is deliberately absent

> *The chip has no per-note velocity — neither did the 6581 — so `C` and `V`
> move the master level, which is the register that exists.*

This is the most instructive decision in the interface. A velocity control
would be easy to add and would do nothing, because there is no register behind
it. Rather than fake one, the keys move the register that is real.

The same honesty governs polyphony:

> *Three voices means three notes. A fourth steals the oldest, which is what a
> three-oscillator chip has to do.*

## Live playing does not touch the schedule

```mojo
# Nothing here touches the audio thread's schedule. Live notes are register
# writes -- set a frequency, raise a gate -- and the render callback reads
# those registers on its own clock. A torn read costs one frame of one
# oscillator, where a lock would cost a click in the speaker.
```

Playing a key does not enqueue anything. It writes a frequency and raises a
gate, and the render callback picks that up whenever it next looks. The
[audio chapter](05-audio.md) covers why there is no lock.

The panel reads back the same way:

> *The panel reads the chip's registers rather than its own copy of them, so
> you can watch a tune move the sliders.*

One source of truth. A tune containing `[I:chip cutoff=450]` moves the cutoff
slider, because the slider is drawn from the register the directive wrote.

## Changing the sound mid-tune

The directive lives in ABC's `I:` field, and the choice of field is argued:

> *ABC's `I:` field is specified as instructions to the software, which is
> exactly what a chip register is, so the directive goes there rather than
> inventing syntax nobody else would recognise.*

```abc
[I:chip v=1 wave=pulse pw=1100 a=0 d=6 s=9 r=3 cutoff=1200 res=7 vol=11]ACEA cAec
[I:chip v=1 pw=350 cutoff=450]aged cAEC
```

Because it is written inline, it applies at the point in the music where it
appears — not at a bar line, not at the start of a phrase.

And unknown keys are ignored rather than refused:

> *so a tune using a setting this build does not have still plays its notes.*

Forward compatibility in one sentence. A tune written for a later version with
more registers still plays; it just sounds plainer.

## The demonstration tune

`tunes/galixigans.abc` exists to show the directive doing something a static
patch could not:

> *a dive where the pulse width narrows and the filter closes as they come at
> you, a four-step power-up with the cutoff opening on every bar, and a
> fanfare. It is in A minor throughout the defence and ends in A major. The
> picardy third is the joke — it is a triumphant ending, and the triumph is not
> ours.*

A **picardy third** is the old device of ending a minor piece on a major
chord — a lift at the last moment. Here the aliens win and the music is
triumphant anyway.

## Two things that make the window testable

```
ABC_SHOT=<path> draws one frame to a PNG and exits, so the window can be
checked without a person at the screen.
```

The same idea as Fluid's `FLUID_AUTOSHOT`: a GUI you can only check by looking
at it is a GUI nobody checks. One environment variable makes the interface part
of a scriptable run.

And the fonts are made once, which is a fix rather than an optimisation — the
chip example's README records what happens otherwise:

> *Asking for a font on every string, thirty times a second, eventually
> returned nil, and a nil value in an attributes dictionary raises — surfacing
> as a trap deep inside AppKit with a stack that mentions nothing about fonts.*

`g_font_title`, `g_font_body` and `g_font_small` are built once at startup and
retained.
