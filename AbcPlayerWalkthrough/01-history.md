# 1. Where it came from

Two histories meet in this program: a notation designed so that folk tunes
could be sent by email, and a player that has been written several times over,
in several languages, of which this is the latest.

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

## One player, several languages

An ABC player is a good thing to port. It is small enough to finish, it has a
genuinely awkward grammar, and the output is checkable — so it makes a decent
way to get the measure of an unfamiliar language. This one has been through
C++, Rust, Modula-2 and Smalltalk before arriving here, and the Mojo version
took the C++ as its starting text simply because that was the handy one to
read from.

The commit records what came out of that read-through — five behaviours the
port had to change. They are worth keeping not as a verdict on any of the
earlier versions but because of the property they share: **every one of them
still produced music.**

None of them announces itself. A tune with the wrong key signature is still a
tune; a note an octave low is still a note. Nothing crashes, nothing logs, and
the output is plausible — which is exactly the class of fault that survives
being tested by listening to it, and exactly why the
[MIDI file output](04-time.md) earns its place.

### 1. Key signatures did nothing

`KeySignature("G")` set `sharps(0)` and never filled its `accidentals` map.
Nothing anywhere assigned `.sharps`. And `applyKeySignature()` returned its
argument unchanged, under a comment reading *"For now, just return the
semitone unchanged"*.

So tunes played in C major whatever the `K:` field said. Folk material is
mostly G, D and A, so that covers most of the corpus — and it still sounded
like music, because a tune transposed into the wrong mode is still a tune.

### 2. Explicit accidentals were dropped

`isAccidental()` tested for `#` and `b`. Those are not ABC's accidental
characters — ABC uses `^` and `_`.

It was also unreachable: the note branch was guarded by `isNote(*p)`, so
`parseAccidental` only ran once the pointer was already on a letter. `^C` fell
through to *"Ignoring unknown character"*.

### 3. First and second endings were ignored

`expandABCRepeats` duplicated the text between `|:` and `:|` with a regular
expression. So `|: A |1 B :|2 C |` — which means *play A B, then A C* — came
out as **A B A B**.

So a repeated strain ended on its first ending rather than its second. The
`REP1` and `REP2` feature types were in the enum, waiting to be used.

### 4. Middle C was an octave low

`calculateMidiNote` computed `base_octave * 12 + semitone` with `base_octave =
4` for an uppercase note, giving 48, against a comment two lines below reading
*"C4 = 60"*.

The model file now states the arithmetic and why the off-by-one octave is easy
to land on:

> *ABC's `C` is middle C, so the octave that letter sits in is 5 in the
> `(octave * 12)` convention — 5 * 12 + 0 = 60. Writing `base_octave * 12`
> with base_octave 4 gives 48, which is a C, an octave low, and sounds
> plausible enough to survive review.*

The last clause is the point. An octave error does not sound broken; it
sounds like a lower part.

### 5. Chord symbols corrupted the melody's timeline

`generateChordNotes` appended its tones to the **melody voice**, which
advanced that voice's clock. So every `"Am7"` in the source pushed everything
after it out of step.

Here chord symbols go to their own voice — `GCHORD_VOICE_BASE = 100` — so the
melody's clock is untouched.

## What the port took from that

The README puts the justification in one line:

> *Numbers 1 and 2 are why this port is not a rewrite for its own sake: a tune
> in `K:D` now plays in D.*

Between them the first two cover most of what pitch means in folk music, which
is what gives this port something to do beyond translating.

The more useful outcome is that two of the fixes are structural rather than
corrective — the shapes that allowed the faults are gone, not just the faults:

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

## What this one is testing

Each language this player has been written in gets tested on the same two
things, and the README names them:

> *It was worth doing for two reasons that have nothing to do with Mojo being
> new: a complicated parser is a real test of a language, and a music player is
> a real test of timing.*

The parser half is [chapter 3](03-parser.md). The timing half is where this
version departs from its predecessors rather than merely translating them —
and it is [chapter 2](02-timing.md).
