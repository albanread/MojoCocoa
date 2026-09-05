# 1. Where it came from

Two histories meet in this program: a notation designed so that folk tunes
could be sent by email, and a C++ player that read it badly.

## ABC notation

ABC is a text format for music, devised by Chris Walshaw in the early 1990s
for exactly the material this player targets: traditional and folk tunes,
mostly single-line melodies, mostly in a handful of keys.

Its design constraint was plain-ASCII portability. A tune had to survive being
typed into a newsgroup post or an email, so a note is a letter, its octave is
a comma or an apostrophe, its length is a number, and a sharp is `^` because
`#` was taken.

```abc
X:1
T:Sí Beag, Sí Mór
C:Turlough O'Carolan
M:3/4
L:1/8
K:D
D2|F4 A2|d4 f2|e4 d2|B4 A2|
```

Two properties of that design matter here. It is **terse** — good for humans,
awkward for parsers. And it is **enormously widely used**: hundreds of
thousands of tunes exist in it, which means a player is judged against real
files written by people who were not thinking about your parser.

The awkwardness is not incidental complexity, and [chapter 3](03-parser.md) is
about it. Briefly:

- `(` opens a slur — unless a digit follows, when it opens a tuplet
- `[` opens a chord — unless it is `[K:`, when it is an inline field
- `|` is a bar line — unless a digit follows, when it also opens an ending
- an accidental holds **to the end of the bar**

Each of those ambiguities is resolved by looking at the *next* character, and
all four occur in ordinary tunes.

## The C++ ancestor, and five things that had never worked

This is a port of a C++ ABC player, and the commit is blunt about what the
port found:

> *Five things in the original had never worked, found by reading it before
> porting rather than by running it.*

That distinction matters. These are not regressions or edge cases. They are
features that were written, compiled, shipped, and never functioned — and the
program still played something, which is why nobody noticed.

### 1. Key signatures did nothing

`KeySignature("G")` set `sharps(0)` and never filled its `accidentals` map.
Nothing anywhere assigned `.sharps`. And `applyKeySignature()` returned its
argument unchanged, under a comment reading *"For now, just return the
semitone unchanged"*.

**Every tune played in C major**, whatever its `K:` field said. Folk material
is overwhelmingly in G, D and A — so that is most notes wrong, in most tunes,
all the time. It still sounded like music, because a tune played in the wrong
key is still a tune.

### 2. Explicit accidentals were dropped

`isAccidental()` tested for `#` and `b`. Those are not ABC's accidental
characters — ABC uses `^` and `_`.

And it could not have fired anyway: the note branch was guarded by
`isNote(*p)`, so `parseAccidental` only ever ran once the pointer was already
on a letter. `^C` fell through to *"Ignoring unknown character"*.

Two independent bugs in one function, either of which alone would have been
enough.

### 3. First and second endings were ignored

`expandABCRepeats` duplicated the text between `|:` and `:|` with a regular
expression. So `|: A |1 B :|2 C |` — which means *play A B, then A C* — came
out as **A B A B**.

Every repeated strain ended on the wrong phrase. The `REP1` and `REP2` feature
types existed in the enum and were never used.

### 4. Middle C was an octave low

`calculateMidiNote` computed `base_octave * 12 + semitone` with `base_octave =
4` for an uppercase note, giving **48**. Two lines below sat a comment saying
*"C4 = 60"*.

The model file's docstring now states the arithmetic and why it is easy to get
wrong:

> *ABC's `C` is middle C, so the octave that letter sits in is 5 in the
> `(octave * 12)` convention — 5 * 12 + 0 = 60. Writing `base_octave * 12`
> with base_octave 4 gives 48, which is a C, an octave low, and sounds
> plausible enough to survive review.*

That last clause is the whole problem. An octave error does not sound broken.
It sounds like a bass part.

### 5. Chord symbols corrupted the melody's timeline

`generateChordNotes` appended its tones to the **melody voice**, which
advanced that voice's clock. So every `"Am7"` in the source pushed everything
after it out of step.

Here chord symbols go to their own voice — `GCHORD_VOICE_BASE = 100` — so the
melody's clock is untouched.

## Why this is a port and not a rewrite

The README answers directly:

> *Numbers 1 and 2 are why this port is not a rewrite for its own sake: a tune
> in `K:D` now plays in D.*

Bugs 1 and 2 together mean the original could not play a tune in a key, and
could not play an accidental. Between them that is most of what pitch means in
folk music. The port is not a tidier version of a working program; it is the
first version that plays the right notes.

Two design decisions follow directly from that experience, and both are stated
as invariants in the source rather than left to care:

**A key signature is arithmetic, not a table.**

> *The alteration a key applies to a letter follows from the circle of fifths,
> so `key_alter` computes it rather than storing seven numbers per key. The
> whole of Western key signatures is two orderings of the same seven letters.*

A table can be half-filled and look fine. `key_alter` derives the answer from
`sharp_order` — the sequence F C G D A E B — so there is no table to forget to
populate. Bug 1 is not fixed here so much as made unrepresentable.

**Repeats are expanded over events, not over text.**

> *The expansion works on events rather than on text. By this point every note
> already knows its voice and its length, so replaying a section is copying a
> range and re-stamping the clock — and a repeat that crosses a line break, or
> sits inside one voice of several, needs no special handling at all.*

The regex approach that produced bug 3 operates on characters, which know
nothing about voices or line breaks. Working on events makes the hard cases
disappear rather than requiring extra code.

## Why port it at all

> *It was worth doing for two reasons that have nothing to do with Mojo being
> new: a complicated parser is a real test of a language, and a music player is
> a real test of timing.*

Both halves are genuine exercises. ABC is an awkward grammar with real corpora
to test against. And a music player has a deadline you can hear — which is
[chapter 2](02-timing.md), and the more interesting half.
