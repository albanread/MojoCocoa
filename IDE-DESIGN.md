# Roast — a Mojo IDE, written in cocoa-mojo

*Working name: cocoa gets roasted; a build is a roast. Rename freely.*

This is the design for a native Mac IDE written in the language it edits. It is
also the answer to a fair observation: this repository healed a language,
rebuilt its toolchain, and wired a database into its compiler — and contains
almost no Mojo. The IDE is where that inverts. It is the first real cocoa-mojo
program, it is built by `cocoamojo`, and once milestone 3 lands it builds
itself.

The thesis in one sentence: **a monospaced editor is a grid, a grid is
arithmetic, and arithmetic beats a layout engine** — so a native editor that
refuses to do layout can hold a keystroke-to-glyph budget no browser-based
editor can reach, while the language server and compiler this repo already
ships do the hard parts over pipes.

## What it stands on

Nothing below is speculative; every piece was built and verified this session.

| piece | where | proven by |
|---|---|---|
| windows, buttons, delegates, timers | `std/objc/classes.mojo` (`new_class`, `fn` callbacks) | p0_window, playground |
| GCD queues and blocks | `std/objc/dispatch.mojo` | dispatch_test |
| ARC ownership + weak refs | `std/objc/ownership.mojo` | weakref_test |
| NSError bridging | `std/objc/error.mojo` (`msg_send_raising`) | nserror_test |
| subprocess + pipes + non-blocking reads | NSTask/NSPipe pattern | the playground's ⌘R |
| language intelligence | `dist/CocoaMojo/bin/mojo-lsp-server` | 11 capabilities + Cocoa completion, probed in check-dist |
| AOT compile and run | `cocoamojo --build` / `--run` | every demo |
| the LSP wire protocol, traced | `tools/lsp-probe/complete.py` | the Cocoa-completion check |
| Metal at 60fps from Mojo | the mandelbrot | 0.4 ms/frame |

## Architecture

```
┌────────────────────────────────────────────────────────────┐
│ NSApp · menu bar · NSToolbar                               │
├──────────┬─────────────────────────────────────────────────┤
│ sidebar  │  GridView (custom NSView, Core Text)            │
│ NSOutline│    ├─ rope snapshot (immutable)                 │
│ View     │    ├─ CTLine cache (visible lines only)         │
│ (lazy)   │    └─ gutter: numbers + diagnostics             │
├──────────┴───────────────┬─────────────────────────────────┤
│ issues drawer            │ output pane (build/run streams) │
├──────────────────────────┴─────────────────────────────────┤
│ status bar: ln:col · UTF-8 · LSP ● · build state           │
└────────────────────────────────────────────────────────────┘
        │ JSON-RPC over NSPipe          │ NSTask
        ▼                               ▼
  mojo-lsp-server (one per project)   cocoamojo --build / spawn
```

Three processes, and that is a decision, not an accident:

- **The editor never parses Mojo.** The language server does — diagnostics,
  completion (including the Cocoa database), definition, rename, semantic
  tokens. IDE-EMBEDDING.md is explicit that for a non-C++ editor the LSP over
  stdin/stdout is the boundary; the editor is written in Mojo, so that is us.
- **The editor never runs user code in-process.** Run = AOT build + spawn.
  This session established that JIT'd code calling `exit()` takes its host
  with it; an editor is precisely the host that must survive. Process
  isolation costs a fork/exec and buys crash immunity.
- **We own both ends of the wire.** The server is in this repo. Where LSP is
  not enough — project-wide symbol index, build-on-save — we add an extension
  method to our server rather than working around a vendor's.

## The text engine: a persistent rope

One structure carries the whole design.

**Shape.** A B-tree rope: UTF-8 leaves of ~4 KB, interior fanout 32, every
node caching `(bytes, newlines)`. A 100 MB file is ~25,000 leaves at depth 4.
Line → offset and offset → line are O(log n) walks on the newline counts.
250,000 lines (~10 MB) is a small case, not the ceiling.

**Persistent, deliberately.** Nodes are immutable; an edit copies the ≤4-node
path from leaf to root and returns a new root. That one property pays three
times:

1. **Undo is a stack of old roots.** Structural sharing makes a thousand-entry
   undo history cost kilobytes. No command objects, no inverse operations —
   `let` bindings holding old roots *are* the history.
2. **Snapshots are one pointer copy.** Background work — LSP sync, search,
   save — takes the current root and reads it on a GCD queue with no lock,
   while the main thread keeps editing. Single-writer, many-snapshot-readers
   is the entire concurrency model.
3. **Crash-cheap saves.** Save serializes a snapshot; the user typing during a
   save cannot tear it.

**Edits.** keystroke → `rope.replace(range, text)` → new root, O(log n),
single-digit microseconds. The edit span is known exactly, so the LSP
`didChange` is incremental for free and the invalidated screen region is
exactly the changed lines.

## The render path, and why it beats a browser

`GridView` is a layer-backed `NSView` inside an `NSScrollView`. It owns no
text storage — it borrows the current rope root and draws.

- **Layout is arithmetic.** Fixed-pitch font: x = column × advance,
  y = line × lineHeight, document height = lineCount × lineHeight. There is no
  layout pass to run, ever.
- **Draw only the viewport.** `drawRect` maps the dirty rect to a line range,
  fetches each line from the rope (O(log n) + O(len)), builds a `CTLine`, and
  draws it. An LRU cache keyed on `(line, ropeRevision, tokensRevision)` makes
  scrolling redraw only newly exposed lines.
- **Unicode without lies.** CJK double-width, emoji, and font fallback are
  real. The rule: *cells for layout, Core Text for truth.* Pure-ASCII lines
  take the arithmetic fast path; any other line gets its x-positions and hit
  testing from `CTLineGetStringIndexForPosition` / `CTLineGetOffsetForStringIndex`.
  Never hand-roll hit testing — Core Text already knows where the glyphs are.
- **Input is `NSTextInputClient`, fully.** This is the highest-risk UI item
  and it is not optional: dead keys, option-e composition, and CJK input
  methods all flow through it. Implement the whole protocol in milestone 1 and
  test with Pinyin on day one, not month three.
- **Selection, caret, squiggles** are cheap: rects and underlines on a grid.
  Diagnostics from the server paint as gutter marks plus an underline layer.

The budget, and what enforces it:

| action | budget | mechanism |
|---|---|---|
| keystroke → glyph | ≤ 1 frame (8.3 ms @ 120 Hz) | O(log n) edit + one CTLine redrawn |
| open 250k lines → first paint | < 100 ms | single-pass rope build; paint visible only |
| full-speed scroll | 0 dropped frames | translate + draw exposed lines from cache |
| literal find, 100 MB | < 200 ms | snapshot scan on a queue, memchr-paced |
| completion popup | < 50 ms after reply | popup is one layer; server did the work |

A browser editor pays DOM mutation → style → layout → paint → composite, plus
a JS heap and its collector, on every keystroke — typical measured keystroke
latency 15–40 ms. This design's keystroke path is microseconds of CPU and one
compositor frame. That is the whole argument; everything else is keeping it
true.

**Milestone 5, optional:** a Metal glyph-atlas renderer on the same
machinery that runs the mandelbrot at 0.4 ms/frame, for guaranteed 120 Hz on
ProMotion. Core Text into layers is expected to hold the budget without it;
measure before building it.

## Language intelligence

One `mojo-lsp-server` per project window, spawned like the playground spawns
the compiler, speaking JSON-RPC with `Content-Length` framing over NSPipe —
the exact flow `tools/lsp-probe/complete.py` already exercises.

- `initialize` / `initialized` / `didOpen` on open; incremental `didChange`
  from the rope's edit spans, coalesced per runloop tick (the server has its
  own debouncer; don't double-debounce).
- **Diagnostics** → gutter, squiggles, issues drawer.
- **Completion** on `.` and inside `msg_send`/`lookup` strings — the Cocoa
  database completion this session added arrives through the same wire, so the
  IDE completes `setTitle:` with `(ObjCObject) -> None` on day one.
- **Semantic tokens full/delta** drive highlighting; a tiny local lexer colors
  keywords/strings/comments instantly while tokens are in flight, then yields.
- Definition, references, hover, rename, signature help, inlay hints: all
  advertised, all straight protocol work.

Known capacity issue, named in IDE-EMBEDDING.md: the server re-parses the
stdlib per open document. Mitigation now: cap synced documents (close ones
evicted from tabs). Fix later: in our fork, because we own it.

## Build and run

- **Build** = `NSTask` running `cocoamojo --build file.mojo -o build/name`.
  Diagnostics are the `path:line:col: severity: message` shape this session
  grepped a hundred times; parse into the issues drawer, click to jump.
- **Run** = spawn the built binary; stdout/stderr stream into the output pane
  via dispatch sources. A basic SGR-color subset later; a pty only if an
  interactive program ever matters.
- A project is a folder. `mojoproject.toml` (entry point, output dir, flags)
  when one file stops being enough. No build graph — `cocoamojo` is the build
  system.
- ⌘B build, ⌘R build-and-run, matching the playground's habit.

## Scriptable, the Mac way

(The request said AppleTalk; the scripting technology is AppleScript, via a
scripting definition — AppleTalk was the network stack. Designing for
AppleScript/OSA.)

An `.sdef` published by the app, Cocoa scripting's KVC machinery underneath,
commands routed through one controller class:

```xml
<suite name="Roast" code="Rost">
  <class name="document">  text · selection · file · modified  </class>
  <command name="build">   result: list of diagnostics          </command>
  <command name="run"/>
  <command name="go to">   line · column                        </command>
  <command name="find">    string → list of ranges              </command>
</suite>
```

The point is not automation for its own sake: **the scripting dictionary is
the test harness.** `osascript` drives open → edit → build → read diagnostics
in CI, exactly as `P0_AUTOCLOSE_TICKS` made window_smoke testable. A
`check-ide.sh` in the house style falls out of it.

## What the stdlib must grow

Honest gaps, each small, each reusable beyond the IDE:

1. **`std.json`** — encode/decode for LSP. Strict, no reflection, hand-rolled.
2. **`std.rope`** — the persistent rope belongs in the stdlib, not the app.
3. **East Asian width table** — cell-width classification for the grid.
4. **`class_addProtocol` in `objc.classes`** — `NSTextInputClient` adoption
   needs the registered class to *conform*, not just implement. One
   external_call plus plumbing.
5. **FSEvents wrapper** — file watching for external-change detection.
6. Core Text declarations — C API, plain `external_call`, no binding layer.

NSRegularExpression (via msg_send) covers regex find for v1; literal find
runs on the rope directly.

## Deliberately not building

No plugin system in v1 — scriptability plus our own server extensions cover
it. No minimap. No proportional fonts. No web technology of any kind. No
in-process compiler embedding — the C++ seam exists (IDE-EMBEDDING.md) but a
Mojo IDE reaches it only if a C shim ever earns its keep; the subprocess story
is simpler and crash-isolated.

## Milestones, each verifiable

| # | lands | verified by |
|---|---|---|
| 0 | shell: window, native tabbing, menu, toolbar, status bar, sidebar | opens, tabs, quits clean; autoclose-ticks smoke |
| 1 | rope + GridView + full NSTextInputClient, undo, find | open 250k-line file < 100 ms; type-at-budget probe; Pinyin composes |
| 2 | LSP: diagnostics, completion, definition, semantic tokens | scripted session completes `setTitle:` inside a msg_send string |
| 3 | build/run, issues drawer, output pane — **self-hosting** | the IDE builds the IDE |
| 4 | AppleScript dictionary + `check-ide.sh` | osascript drives edit→build→diagnostics in CI |
| 5 | (optional) Metal glyph renderer | 120 Hz scroll measurement says it's needed, or it isn't built |

Rough effort: 0 is a week, 1 is the long pole at two to three, 2 and 3 a week
or two each, 4 a week. A dogfoodable editor in roughly two months; the
latency claim is testable at milestone 1, which is the point of the ordering.

## Risks, named

- **NSTextInputClient / IME** is where native editors quietly fail. It is
  scheduled first among the hard things and tested with real input methods.
- **Grid vs. glyph truth**: any place column math bypasses Core Text on a
  non-ASCII line is a caret bug. The rule above is the defense; review for it.
- **LSP memory** per open document — capped now, fixable in our fork.
- **Cocoa scripting's KVC plumbing** is fiddly and poorly documented; routing
  every verb through one controller keeps the surface small.
- **250k-file trees** (the other reading of the requirement): the sidebar is
  lazy `NSOutlineView` children and never stats a directory it hasn't opened;
  project search shells to `ugrep` when present.
