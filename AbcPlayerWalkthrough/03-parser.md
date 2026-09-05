# 3. Reading ABC

The parser is three files: `parse.mojo` splits a file into headers and music,
`music.mojo` reads the music, and `model.mojo` holds what they produce. It is
about 1,500 lines, and the header of `music.mojo` explains why it needs to be:

> *This is the part with the sharp edges. The notation is terse, ambiguous in
> places, and every real tune uses the ambiguous parts.*

## The one rule that makes ABC parseable

```
# ABC's header ends at the K: field, which is the one rule that makes the
# format parseable at all -- everything before it configures the tune, and
# everything after it is music, except that field lines are still allowed in
# the body and most real tunes use them for voice switches.
```

`K:` is the boundary. Before it, every line is a field; after it, a line is
music **unless** it looks like a field — one letter, a colon, a value.

That exception is not a nicety. Multi-voice tunes switch parts with `V:` lines
in the middle of the music, and `L:` or `K:` can change mid-tune. So the
parser cannot simply stop looking for fields; it has to keep the test running
and let real tunes use it.

## Four ambiguities, each resolved by one character of lookahead

| written | usually | unless |
|:---|:---|:---|
| `(` | a slur | a digit follows — then a tuplet |
| `[` | a chord | it is `[K:` etc. — then an inline field |
| `\|` | a bar line | a digit follows — then also an ending |
| `^F` | this F is sharp | *every* F for the rest of the bar is |

The first three are ordinary lookahead. The fourth is different in kind, and
the source flags it:

> *That last rule is the one worth being careful about. It is what makes ABC
> readable to a musician, and a parser that skips it plays wrong notes in
> roughly every tune that has an accidental in it.*

This is the convention of printed music: write the accidental once, and it
governs that letter until the bar line. A parser that treats `^F` as "this
note is sharp" gets the second F in `^F A F` wrong — and gets it wrong in
almost every tune that has an accidental at all, because writing it twice is
what notation exists to avoid.

## The accidental state, in one integer

The bar's accidentals live in a single `Int`, seven nibbles wide:

```mojo
var bar_acc: Int           # seven 4-bit fields, one per letter

fn acc_of(self, letter: Int) -> Int:
    """The accidental in force for a letter this bar, or NO_ACCIDENTAL."""
    let nib = (self.bar_acc >> (letter * 4)) & 0xF
    return NO_ACCIDENTAL if nib == 0 else nib - 8

fn set_acc(mut self, letter: Int, alter: Int):
    # Biased by 8 so that zero can mean "nothing set": a natural sign is
    # an accidental too, and storing it as 0 would erase it.
    let nib = (alter + 8) & 0xF
    self.bar_acc = (self.bar_acc & ~(0xF << (letter * 4))) | (
        nib << (letter * 4)
    )
```

The bias by 8 is the detail worth noticing. A natural sign (`=F`) is an
alteration of **zero**, and it is a real instruction — it cancels a sharp
earlier in the bar. Storing alterations raw would make "natural" and "nothing
set" the same value, and `=F` would silently do nothing.

Clearing the bar is then one assignment:

```mojo
fn clear_bar(mut self):
    self.bar_acc = 0
```

Which is called at every bar line, and also after `K:` — because a key change
resets what the letters mean.

## A key signature is arithmetic

Seven letters, two orderings, no tables:

```mojo
fn sharp_order(k: Int) -> Int:
    """Sharps arrive F C G D A E B; flats take the same list backwards."""

fn key_alter(sharps: Int, letter: Int) -> Int:
    """What a key signature does to one letter: +1, 0 or -1.

    Derived rather than stored. With `sharps` sharps, the first `sharps`
    letters of F C G D A E B are raised; with flats, the first `-sharps` of
    that list read backwards are lowered.
    """
```

Sharps always arrive in the order F C G D A E B; flats arrive in exactly that
list reversed. Two sharps means F and C are raised; that *is* the definition of
D major. There is nothing to look up.

`key_sharps_for` then maps a `K:` field onto a position on the circle of
fifths, and handles the modes — which are not decoration:

> *a tune marked `K:Ador` is in G major's signature, and reading it as A major
> puts three accidentals in the wrong place for the whole tune.*

`Ador` is A Dorian: A as the tonic, but G major's key signature. Folk material
uses modes constantly — Dorian and Mixolydian especially — so a player that
treats the letter as a major key is wrong for a large fraction of the corpus.
The implementation is a subtraction:

```mojo
elif rest.startswith("dor"):
    fifths -= 2
```

Dorian is the second mode, so its signature sits two fifths below the major of
the same letter. Mixolydian is one below, minor and Aeolian three, Phrygian
four, Locrian five, Lydian one above. Six lines for the whole modal system.

## Durations, and why nothing is a float

```mojo
def read_duration(line: String, start: Int, unit_ticks: Int) -> List[Int]:
    """The length that follows a note, rest or chord. Returns [ticks, next].

    ABC writes a multiplier, a divisor after `/`, or both: `A2`, `A/2`, `A/`,
    `A//`, `A3/2`. A bare `/` halves, and each extra `/` halves again.
    """
```

`A3/2` is a dotted note. `A//` is a sixteenth of the unit length. All of it is
a rational multiple of `L:`, and all of it stays exact because the unit is 480
ticks per quarter — see [chapter 4](04-time.md).

## State the parser has to carry

```mojo
struct MusicCtx(Copyable, Movable):
    var voice: Int
    var bar_acc: Int           # seven 4-bit fields, one per letter
    var tuplet_left: Int       # notes still inside a tuplet
    var tuplet_num: Int
    var tuplet_den: Int
    var broken: Int            # >0 after '>', <0 after '<', magnitude = count
    var in_grace: Bool
    var last_note: Int         # index in tune.events of the last note emitted
    var gchord_root: Int       # the chord symbol in force, or -1
    var gchord_kind: Int
```

Everything here exists because ABC lets it change mid-tune. `tuplet_left`
counts down over the *following* notes, so `(3` alters the three notes after
it. `broken` records a `>` or `<` and applies to the pair it sits between.
`last_note` is needed because a tie and a broken rhythm both reach backwards
to modify a note already emitted.

The `Voice` struct carries the same idea at a larger scale:

> *ABC lets any of this change mid-tune through an inline field, so it is state
> rather than configuration.*

## The subtle one: defaults for a voice that has not appeared yet

```mojo
# Header defaults. A voice can be mentioned for the first time in the
# music, long after L: and K: were read, so the tune has to remember what
# a new voice should start life with -- otherwise a tune whose header says
# L:1/4 plays in eighths and nothing in the parse looks wrong.
var default_unit_num: Int
var default_unit_den: Int
...
```

`V:2` may appear forty lines below the `L:1/4` that should govern it. If the
new voice is created with library defaults instead of the tune's, it plays at
the wrong note length — and *nothing in the parse looks wrong*, because every
individual step succeeded. The tune simply has one part in the wrong tempo.

## Encoding traps, met and commented

Two byte-level details cost time and are recorded where they happened.

**A trailing carriage return:**

```mojo
# A trailing carriage return is invisible and breaks every comparison
# that follows it, so it goes first. The trimmed copy is a new String:
# assigning a slice of a String back over itself aliases the buffer it
# is reading from.
```

ABC files come from everywhere, so CRLF is common. `"K:D\r"` is not `"K:D"`,
and the difference is invisible in every error message. The second sentence is
a separate hazard in this dialect: slicing a `String` back over itself aliases
the buffer being read.

**Rebuilding a string byte by byte:**

```mojo
# Sliced, not rebuilt character by character: `chr(byte)` turns
# each byte of a multi-byte character into its own codepoint, so
# a title with an accent in it comes out as mojibake.
let body = String(line[byte = 2 : len(b)])
```

`T:Sí Beag, Sí Mór` is the ordinary case, not an exotic one. Iterating bytes
and calling `chr` on each turns every UTF-8 continuation byte into its own
character.

## What is deliberately not supported

> *Ignored deliberately, because a chip cannot hear them: slurs, decorations,
> lyrics alignment, and clefs.*

A slur is a phrasing mark for a human player; a chip has no legato to apply.
`w:` lyric lines are consumed and dropped. The decision is recorded rather than
left as an omission, which is the difference between a limitation and a bug.
