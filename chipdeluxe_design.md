# ChipDeluxe — three chips, nine voices, and the demoscene on top

Design for a chiptune player that is itself a demo: the sound of 1987 made
by the machinery of 2026, none of it sampled, all of it computed. This is
the design and the sprint plan in one document; numbering is CT0–CT8 so it
cannot collide with the G, P or D series.

## The mission, and an opinion

The ask: three chips, nine voices, driven from ABC's `[I:...]` inline
command; original tunes in the tradition of the 1980s demos without copying
any of them; visuals that earn the name, on our GPU kernels where a kernel
is the right tool; and a player that can also read period tracker data — the
Amiga `.MOD` family.

The opinion, having read the tree before writing this: **the engine is
already most of a demoscene machine, and the missing part is small.** The
per-scanline palette of the indexed pane IS the copper. The sprite layer's
per-instance transforms ARE a sine scroller. The chip is deterministic
integer arithmetic with committed hashes, so nine voices can stay provably
correct. The one real gap between our chip and the classic sound is the
**50 Hz performance layer** — arpeggio, vibrato, slide, pulse-width sweep —
and the chip already has the hook for it (`Tick`, a plain `fn(P)` called
once per 50 Hz frame). Better still: those four tricks are *also* the MOD
effect set, so one macro engine serves both the ABC grammar and the
importer. The design below is mostly wiring between things that exist.

## What exists (the inventory this design stands on)

| piece | where | what it gives us |
|---|---|---|
| the chip | `gamepane/api/audio.mojo` | 3 voices, tri/saw/pulse/noise, ADSR, resonant multimode filter, all integer/fixed-point, 50 Hz frame clock, `Tick` hook |
| the schedule | `gamepane/abc/schedule.mojo` | ABC → sorted sample-stamped steps; `SE_CHIP` register events |
| the player | `gamepane/abc/chipplay.mojo` | flat-memory schedule walked on the audio thread, span rendering (sample-accurate), voice allocator, loop |
| the grammar | `gamepane/abc/music.mojo` `chip_settings` | `[I:chip v=2 wave=pulse pw=900 …]` → triples; **unknown keys are ignored**, which is the whole extension mechanism: an old build plays a new tune's notes |
| the deck | `gamepane/metal/audio.mojo` | one AudioUnit, mono Float32, SPSC trigger ring with the acquire/release discipline, `MAX_BUFFER` 4096 |
| layer 0 | `gamepane/metal/layers.mojo` | full-screen fragment shader (starfield shipped; plasma is a dozen lines) |
| the copper | `IndexedPane.set_line_rgb` | indices 1–15 are per-scanline — the actual Amiga trick, kept for exactly this |
| sprites | `gamepane/metal/sprites.mojo` | GPU-composited quads, per-instance position/scale/rotation/alpha |
| kernels | `gamepane/metal/blitter.mojo`, `particles.mojo` | the precedent: Mojo `def`s compiled to AIR, fixed-width args, clip-before-launch |

## 1. The trio

A **trio** is three chip states behind one schedule walker and one stereo
mixer. The chips themselves do not change — `chip_new`, `chip_render`, the
filter, the hashes, all untouched. What is new is the frame around them:

- **One cursor.** The flattened schedule keeps a single sample cursor, as
  today. Each step routes by voice number: ABC voice `V:n` (1-based) lands
  on **chip `(n-1)/3`**, and note allocation stays dynamic **within** that
  chip's three voices, exactly as `apply_note_on` behaves now. `V:1..3` is
  chip 0 — so every existing three-voice tune plays on a trio unchanged,
  which is the compatibility proof CT0 must render and hash.
- **Span rendering, three ways.** Between events, all three chips render
  the span into scratch and the mixer folds them to stereo. The chips stay
  independent: three filters, three master volumes, which is what makes a
  trio richer than one 9-voice chip — a swept lowpass on the lead chip
  never dulls the drums.
- **Stereo at last.** The AudioUnit goes to two channels. Each chip has a
  pan position (−128..127) through a 256-entry constant-power table —
  integer in, integer table, deterministic out. Defaults: chip 0 centre,
  chip 1 left, chip 2 right, the classic twin-SID rig. Games are untouched:
  the deck writes its mono sum to both channels.

`[I:chip …]` grows chip-level keys, addressed through any voice the chip
owns: `pan=`, and the echo sends of §3. `v=` now ranges 1..9. Unknown-key
tolerance does the versioning for us.

## 2. The performance layer — where the chiptune actually lives

A chip tune is not notes; it is **register writes at frame rate**. Hubbard's
basses, the shimmer of an arpeggiated chord standing in for polyphony, the
pulse pad that breathes — all of it is a routine poking the chip 50 times a
second. Ours runs in the trio's tick, integer state in the chip block's
spare slots, nothing allocated, nothing raised:

| key | meaning | the classic it buys |
|---|---|---|
| `arp=0473` | semitone offsets cycled per tick (hex digits, 1–8 of them) | the chord-in-one-voice shimmer; MOD effect `0xy` |
| `vib=d/r` | pitch wobble, depth in 16ths of a semitone, rate in ticks | the singing lead; MOD `4xy` |
| `slide=n` | glide toward each new note at n units/tick; 0 snaps | portamento bass; MOD `3xy` |
| `pwm=d/r` | pulse-width triangle sweep, depth and rate | the fat pad that breathes |
| `sweep=n` | filter cutoff slew per tick, signed | the opening filter ramp |
| `trem=d/r` | volume wobble | MOD `7xy` |

Two rules keep it honest. **Macros are per voice and survive notes** — they
are how a voice *plays*, not how one note sounds — and every macro is
integer arithmetic against the tick counter, so a rendered tune still
hashes identically on every run. The hash suite grows one fixture per
macro.

## 3. Echo

One stereo delay line per trio, allocated with the trio, before the unit
starts — the callback contract (`no allocation, no locks, no raising`)
holds. Per-chip send `echo=0..15`, trio-wide `etime=` (in ticks, max one
second) and `efb=0..15` feedback, all through `[I:chip …]`. Integer
feedback path, so it, too, hashes.

That one effect is disproportionate: dry chips sound like 1982; the same
chips into a quarter-note echo sound like a demo. It is also the cheap way
to make nine voices feel like more.

## 4. Reading the period trackers — `.MOD`

The Amiga `.MOD` is the other 80s: four channels of sampled PCM where we
have synthesis. Two stages, honest about what each is.

**CT7, the importer — a MOD as a score.** Parse the container (M.K. 4-ch
and the 6/8-ch variants; 31-sample table, order list, 64-row patterns of
period/sample/effect) into **our schedule**: periods → pitches through the
PAL table, rows → sample times through speed/tempo (`Fxx`), and the effect
column → the §2 macros, which map almost one for one (`0`→arp, `1/2/3`→
slide, `4`→vib, `7`→trem, `9` has no meaning without PCM, `A/C`→velocity,
`B/D`→order flow). Each of the 31 instruments gets a **chip recipe** —
wave, ADSR, pwm — inferred crudely from its sample (length, loop, coarse
brightness) and overridable from a sidecar text file. The result is not
the MOD; it is a *chip cover* of the MOD, which is itself a fine scene
tradition — and it exercises every part of CT0–CT3 with music that already
exists.

**CT8, the Paula wave — a decision, not a promise.** A fourth voice mode,
`WAVE_PCM`: the phase accumulator that already walks tri/saw/pulse walks a
preloaded sample block instead — pointer, length, loop point, the period as
the step. Paula was *simpler* than the SID; this is the one extension that
makes an imported MOD sound like the Amiga rather than like our chip
covering it. It is also the one that changes what the chip *is*, so it is
its own sprint with a go/no-go: land CT7, listen, and decide whether the
cover or the record is the product.

**No bundled third-party MODs, ever.** The importer is a capability; the
music we ship is ours. A `.mod` dropped next to the player is the user's
own business.

## 5. Sync — the schedule is the sync track

Demos die by drift, so nothing here estimates the beat. The audio thread
already knows the exact sample position (`SC_SAMPLE`); it publishes it once
per callback with a release store, the render thread reads it with an
acquire load — the deck's own SPSC discipline, one counter, no lock. The
UI holds the *same schedule it built*, so "what note just happened" is a
binary search, and a copper flash lands on the note that caused it, sample-
accurately, with no message channel at all.

Two more taps, both display-only and both plain reads of chip memory the
audio thread owns: the nine envelope levels (`V_ENV`, a 16.16 int each) for
VU, and a 2048-frame stereo ring of the final mix for the oscilloscope,
written by the mixer, cursor published the same way.

## 6. The visuals

Layered exactly as a game is, every effect from stock parts:

- **Copper VU.** Nine horizontal bars, one per voice, height and glow from
  `V_ENV`, drawn as *palette ramps* on the indexed pane — per-scanline
  colour does the gradient, and the beat flash is a palette write, not a
  redraw. The signature effect, and the cheapest.
- **The scope.** A Mojo GPU kernel (blitter family: fixed-width args,
  clip before launch) clears a strip and plots the mix ring as a connected
  trace — one launch a frame, 2048 points. Green phosphor ramp in the
  per-scanline palette, slight decay via a second `fade` kernel pass, which
  the particle kernel already proved the shape of.
- **Behind everything, plasma.** Layer 0 fragment shader: two sine fields
  and a palette walk, hue-pulled by which chip is loudest. The shipped
  starfield remains as the alternate backdrop; the tune picks.
- **The scroller.** Greeting text as sprite glyphs — 5×7 font rendered
  once into sprite definitions, ~40 instances riding
  `y = A·sin(x·k + t)` with a slow per-glyph rotation. Per-instance
  transforms make this a data update, not a draw.
- **Stretch: Kefrens bars**, one kernel writing one scanline from the line
  above — only if CT5 lands early; the design owes nobody a fourth effect.

## 7. The player

`examples/chipdeluxe` — a gamepane program, not a Cocoa-widget app; the
player *is* the demo. Attract order: tune list on the text overlay, plasma
behind, scroller greeting the tradition without quoting anyone. Keys:
1–9 pick a tune, space pause, L loop, S swaps scope/VU emphasis, 2/4 the
zoom the games taught us, esc quits. `CHIPDELUXE_FRAMES` renders headless
for `check-examples.sh`, and a `--wav <tune> <file>` flag renders offline
through the same trio for the hash suite and for handing tunes around.

## 8. The demos — four originals, one tradition

Not covers, not soundalikes of any one composer; the *devices* are the
tradition, and each tune leans on different ones. Working titles:

1. **Powerline** — 152 bpm driver: octave pulse bass with `pwm`, `arp`
   chords standing in for a pad, saw lead under a long `sweep`. Chips:
   drums centre, bass+arp left, lead right. The Hubbard lesson without a
   Hubbard note.
2. **Glass Cathedral** — slow build across all nine voices, `vib` leads in
   octaves, deep `etime` echo doing the choir's work. The Follin lesson:
   vibrato is a voice, not an ornament.
3. **Copper Sky** — mid-tempo title groove, the copper VU's showcase;
   melody trades between chips left and right so the stereo *is* the
   arrangement.
4. **Four-Kilobyte Waltz** — 3/4, triangle lead, the echo taps *as* the
   accompaniment: proof the machine can be delicate, which the 80s demos
   rarely bothered to prove.

Each ships with its committed render hash, like the twelve effects before
them: a change to the oscillator or a macro shows up as a number, not as
someone eventually noticing the waltz limps.

## The sprints

Sizes as elsewhere: **S** a sitting, **M** a day or two, **L** a week.

- **CT0 — the trio (DONE, was M).** Three chips, one walker, stereo mixer, pan
  table; deck grows a stereo path with games writing mono to both.
  *Checks:* a shipped 3-voice tune renders through a trio and hashes
  identically to the single-chip render (mono channel compared); a 9-voice
  scale exercises all three chips; games' audio unchanged by ear and by
  hash.
- **CT1 — the grammar (DONE, was S).** `v=1..9`, `pan=`, `echo=`, `etime=`, `efb=`,
  macro keys parsed to triples; old builds still play new tunes' notes.
  *Checks:* parse-triple tests; unknown-key tolerance test.
- **CT2 — the macros (DONE, was M).** Arp, vib, slide, pwm, sweep, trem in the trio
  tick. *Checks:* one hash fixture per macro; a determinism run of 100
  renders.
- **CT3 — echo (DONE, was S).** Preallocated stereo delay, sends, feedback.
  *Checks:* hash fixture; silence-in silence-out; feedback ceiling proof.
- **CT4 — taps and sync (DONE, was S).** Published sample cursor, env reads, scope
  ring. *Checks:* SPSC discipline documented against the deck's; a
  headless reader sees a monotonic cursor.
- **CT5 — the visuals (DONE, was M; the scope's fade pass deferred -- clear-and-plot reads well without it).** Copper VU, scope kernel + fade pass, plasma,
  sprite scroller. *Checks:* headless frame checksums, the game panes'
  own trick.
- **CT6 — the player and the four tunes (DONE except the offline --wav flag; tunes tuned by ear against rendered WAVs).** The app, attract mode,
  offline `--wav`, the demos written and tuned by ear against rendered
  WAVs (the Galaxigans workflow: render, listen, revise, wire).
  *Checks:* `check-examples.sh` headless run; four committed tune hashes.
- **CT7 — the MOD importer (DONE, was M).** Container, periods, tempo, effect→macro
  map, recipe inference + sidecar. *Checks:* a synthetic test MOD written
  by our own tool round-trips; effect coverage table in the tests.
- **CT8 — the Paula wave (M, gated).** `WAVE_PCM` behind a listening
  decision after CT7. *Checks:* hash fixtures with a generated sample;
  the chip suite unchanged when the mode is unused.

## The rules that keep it honest

The audio callback allocates nothing, locks nothing, raises nothing — the
trio, its delay line and its rings are built before the unit starts, and
every cross-thread counter uses the acquire/release pair, not fences. Every
tune and every macro renders byte-identically or the hash suite says so.
Anything touching AudioToolbox is **built, not `run`** — the JIT cannot
resolve it. GPU kernels cache by source hash; visual work sees stale
kernels if it forgets. And the three-copies staleness class applies: the
player must run from the dist the way `gp.sh` stages it, or the IDE will
happily play last week's chip.
