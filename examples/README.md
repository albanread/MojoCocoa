# Examples

Each folder here is a project: a folder with a `main.mojo` in it. Open one in
Roast (File ▸ Open Folder…) and press ⌘R. Output appears in the console pane,
which opens itself when a build starts and toggles with ⌘0.

    hello/        the smallest thing that runs — one file
    fern/         Barnsley's fern, saved as a png — three files, so a
                  project with more than one file in it
    animals/      dog barks, cat meows -- the same example twice, once
                  with a trait the compiler resolves and once with a real
                  Objective-C class the runtime does, and what each costs
    window/       a Cocoa window with a button, in Mojo
    life/         Conway's Life: a real app -- mouse, keyboard, a Metal
                  layer, and three `class` declarations Cocoa calls into
    fluid/        Stable Fluids on the GPU, every kernel written in Mojo
    mandelbrot/   a live-zooming fractal at 60fps, every pixel computed
                  and coloured by one Mojo kernel on the Apple GPU
    grayscott/    reaction-diffusion: two chemicals and one four-line
                  kernel, six named regions of its parameter plane
                  producing spots, worms, spirals or a maze that never
                  stops growing. Drag to seed it, 1-6 to jump regions live
    physarum/     300,000 slime-mould agents, each sensing three points
                  and turning toward the strongest, converge into a
                  branching vein network that no agent and no pixel was
                  ever told to build. Drag to attract it, 1-4 for four
                  turning regimes
    boids/        a flock: separation, alignment and cohesion, three
                  local rules and nothing else, coloured by each bird's
                  own heading so a flock turning together turns the same
                  colour together. Unlike physarum's agents (which never
                  sense each other, only a shared trail) these look
                  directly at their neighbours -- hold the mouse to draw
                  the flock toward the cursor, 1-4 for four characters
    othello/      the board game, and an honest answer to where a GPU helps
                  a computer player -- and where it does not
    chip/         a chip-tune synthesiser: three voices, a resonant filter,
                  and a Mojo `fn` serving as CoreAudio's render callback on
                  a real-time thread. Plays ABC notation.
    abcplayer/    a full ABC notation player -- parser, repeats, tuplets,
                  MIDI file output -- scheduled to the sample, playing
                  through either the chip or General MIDI. A window with a
                  tune list, an editor for all three chip voices, and a
                  playable keyboard on Logic's Musical Typing layout. Tunes
                  can change the chip's registers mid-phrase with [I:chip ...]
    galaxigans/   a Galaga: the sprite layer, the text overlay and 12,000
                  GPU particles that take their colours from the sprite
                  that just exploded. Start here of the two
    galaxigans-deluxe/
                  the same game rebuilt on the whole package -- an indexed
                  pane whose per-scanline palette makes the capture boss's
                  tractor beam flow without redrawing a pixel, fourteen
                  alien species across twelve waves, and two kinds of
                  music: the big cues on the system's General MIDI synth,
                  a chip motif for each species when it dives
    moonshot/     the Moon, the Sun and the sky for any date -- Meeus's
                  ephemeris, checked against his worked examples to the
                  digit -- and Apollo 11's week printed as its flight
                  dynamics team had it, the Sun 10.7° over Tranquility
                  at touchdown (the record says 10.8°). Then one
                  Runge–Kutta integrator over Earth, Moon and Sun,
                  proved against Kepler on the CPU in Float64 and run as
                  a 16,384-thread GPU kernel in Float32 on int64 fixed
                  point -- the Apollo computer's trick -- to within 350 m
                  of the truth at the Moon. Then Apollo 11's translunar
                  injection re-planned from its parking orbit and its
                  clock: Lambert, then differential correction with the
                  n-body integrator in the loop, to a far-side perilune
                  at LOI-1's minute for 3 181 m/s (the S-IVB burned
                  3 182). Then the month: every launch minute of July
                  1969 at every flight time, 714 240 candidates on the
                  GPU, and the Sun over three landing sites picking the
                  16th, the 18th and the 21st -- the days NASA picked.
                  And the console itself: the PLAN screen, where the
                  choices are yours -- pad, site, day, hour, flight time,
                  the lunar orbit -- and the sheet (timeline, burns, the
                  mass at every event, margins, the red lines) and the
                  3D course in three frames are computed from them; and
                  the TRACK screen, where the plan is flown -- the burns
                  at their seconds, the three tracking stations and the
                  Moon's occultation (LOS 48 s from Apollo 11's record,
                  AOS 96 s), the flown course against the planned one;
                  and the dispersions: 16,384 copies of the plan with
                  the S-IVB's cutoff errors flown to their perilunes on
                  the GPU (5.6% reach the LOI corridor uncorrected; 100%
                  after a correction), and a mission whose S-IVB misses
                  by half a metre a second, whose tracking is noisy, and
                  whose trench corrects it -- or, left uncorrected, hits
                  the Moon. Then the arrival: the flyby plane chosen to
                  hold the landing site at the landing time, LOI-1
                  solved as the finite burn it is (877 m/s for 111 x
                  314 km), LOI-2 at the measured second perilune, and
                  the pass over Tranquility found at 102:42 with the
                  site 0.2 km off the plane -- Apollo 11 touched down at
                  102:45. Then the descent itself: Klumpp's guidance
                  through its gates, the DPS between 10% and full, a
                  seeded terrain with West Crater where it was, a crew
                  who see craters from the approach and rocks only in
                  the final, and the rules -- a nominal landing in 13
                  minutes for 2.2 km/s with 60 s of hover left; over a
                  boulder field a 60 s reserve aborts with 12 m to go
                  and a 30 s reserve lands with 35. And the consequences:
                  seeded cards (an SPS fault, a program alarm, a dead
                  landing radar), the rules that answer them, a flyby
                  that comes home on a free return or a DPS burn when
                  LOI is called off, a debrief that names the plan line
                  responsible, and the chip for the calls, the alarm and
                  the touchdown. `checks.mojo` prints the sums; see
                  moonshot_design.md
    ferns/        a landscape of Barnsley ferns growing live over a
                  procedural lawn, under a cloudy dusk sky (CPU)
    fernwind/     the same meadow swaying in the wind: every fern redrawn
                  from scratch each frame by 24,576 GPU chaos-game streams
    bifurcation/  the logistic map: 6.4M iterations in Mojo, then a
                  publication-quality figure from matplotlib. What Python
                  is genuinely good at, measured against what it is not.
                  Needs a Python environment — see its README
    life-python/  Conway again, drawn by PYGAME instead of Cocoa: the
                  same program in two windowing worlds. Needs a Python
                  environment — see its README

    And the largest example is not in this folder: File ▸ Open IDE Source
    opens Roast's own source — the editor you are reading this in, written
    in the language it edits.

    From Modular's own example collection, running here unmodified:

    operators/    a Complex struct wearing the full operator set — Mojo's
                  object model, with a std.testing suite beside it
    process/      child processes from std.os — spawn, wait, poll, kill
    vector-add/   the canonical first GPU kernel, TileTensor and all
    grayscale/    a 2D image kernel on the GPU
    tiled-matmul/ shared-memory tiles and barriers, with a validation pass

## What a project is

A folder. There is no project file and nothing to generate.

Mojo has no link step: the compiler is given one file and follows its imports
from there, so a project needs an entry point rather than a file list. Roast
looks for one in this order:

1. `main.mojo` in the project root — the convention, and what these examples use
2. the file on screen, if it is in the root and declares a top-level `main` —
   with several to choose from, the one being looked at is the one meant
3. the one non-test file in the root that declares a top-level `main`
4. the file on screen

Step 4 is what makes a single loose file still buildable: open one file, press
⌘B, and it builds that file. There is no separate single-file mode — it is the
same question with a smaller answer.

Step 3 ignores `*_test.mojo` because every test suite declares a `main` and
none of them is what the project is. And "declares a `main`" means at the start
of a line: `ide/build.mojo` explains this rule using the exact string it
searches for, so a plain substring scan nominates it as the entry point of the
whole editor.

The binary lands in `<project>/build/<name>`. ⌘R runs it with the project
folder as its working directory, which is why `fern/` writes its png into
`fern/` rather than wherever Roast was started from. A failed build does not
run anything; the console shows why, and the caret goes to the first error —
opening the file if it is not open, since the error is often in something
`main.mojo` imported and you have never had on screen.

Imports resolve from the entry point's own directory, so a project with several
files puts them beside `main.mojo` and imports them by name — `fern/` is
`main.mojo`, `ifs.mojo` and `png.mojo` doing exactly that.

That is also the limit: a module in a *sibling* folder is not found, because
nothing tells the compiler to look there. Sharing code between projects needs an
include path, and an include path needs somewhere to write it down. That is the
first thing a project file would be for, and until something needs it there
isn't one.

## Notes on the examples

`fern/` writes a real PNG with no library behind it: `png.mojo` is a CRC, an
Adler-32, and deflate's stored mode, which is about eighty lines and compresses
nothing — the file comes out around 2 MB for 720×960. Swapping in real
compression is a self-contained exercise if anyone wants it.

`mandelbrot/` needs a GPU. It times the same fractal on one CPU core and on
the GPU before opening the window — on an M4 Max the difference is a couple
of hundred times — then zooms into the seahorse valley until you click
somewhere better. The cross-checking of GPU against CPU arithmetic lives on
as `spikes/mandelbrot/compute_smoke.mojo`.

`ferns/` is `fern/`'s showy sibling: the same four affine maps, but a dozen
plants in different shades of green growing point-by-point at 60fps, out of a
lawn of fourteen thousand procedural grass blades, under value-noise clouds.
Click to plant another — lower on screen means closer, so it comes up bigger.

`fernwind/` is the fractal-flame answer to `ferns/`. The CPU version cannot
move -- its picture IS the accumulation -- so this one redraws every fern from
scratch each frame: thousands of GPU threads each run a short chaos game and
their hits meet in density buffers through atomic adds. Redrawing from
scratch is what buys the wind: each fern's climb map is rotated a fraction of
a degree by a travelling gust field, and because that map applies recursively
up the plant, the rotation compounds into a progressive bend -- stems lean,
tips whip. `mandelbrot/`, `fluid/` and `fernwind/` compute on the GPU;
`life/` and `ferns/` compute on the CPU and use Metal only to present.

`life/`, `fluid/`, `mandelbrot/`, `othello/`, `ferns/` and `fernwind/` are the
ones that look like applications. They declare Objective-C classes with
`class` — the view whose mouse and key handlers Cocoa calls, the app delegate,
the timer target in `life/`, the Apple Event handler in `fluid/` — so there is
no `ObjCClassBuilder`, no hand-written type encoding, and no `cmd` slot
anywhere in them. `fluid/` is Jos Stam's Stable Fluids with every kernel
compiled through this fork's AIR backend; there is no shader in the pipeline.

The last five are Modular's, copied from `mojo/examples/` and `max/examples/`
in this same tree with nothing changed but the filename — including
`DeviceContext()` with no arguments, which resolves to the Apple GPU here.
That is the point of carrying them: upstream's own teaching examples, warp
primitives aside, build and run through this fork's AIR backend as written.
`tiled-matmul/` is the strongest of the five — shared-memory tiles and barrier
synchronisation, and the only one that checks its own arithmetic at all, though
what it checks is five closed-form spot values rather than the CPU reference
its own output claims.

Each example gets a section in the guide: **The examples**, in
`CocoaMojoGuide/examples/`, says what every one of them teaches — and says so
plainly where the honest answer is "nothing".
