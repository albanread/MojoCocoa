# Roast — a Mojo IDE, written in cocoa-mojo

*Working name: cocoa gets roasted; a build is a roast. Rename freely.*

This is the design for a native Mac IDE written in the language it edits. It is
also the answer to a fair observation: this repository healed a language,
rebuilt its toolchain, and wired a database into its compiler — and contains
almost no Mojo. The IDE is where that inverts. It is the first real cocoa-mojo
program, it is built by `cocoamojo`, and as of milestone 4 it builds
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

| action | budget | mechanism | measured |
|---|---|---|---|
| keystroke → glyph | ≤ 1 frame (8.3 ms @ 120 Hz) | O(log n) edit + one CTLine redrawn | **2.4 µs** rope edit |
| open 250k lines → first paint | < 100 ms | single-pass rope build; paint visible only | **5 ms** rope build |
| full-speed scroll | 0 dropped frames | translate + draw exposed lines from cache |
| literal find, 100 MB | < 200 ms | leaf walk, never flattening the buffer |
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

### Python is embedded; environments are not

`std.python` loads CPython into the running Mojo program. Roast does not put a
Python worker between Mojo and `PythonObject`: Run is still one AOT Mojo
binary, and that process calls `dlopen` on the Python library and
`Py_Initialize` itself.

The application carries one pinned, relocatable `Python.framework`. Mutable
packages cannot live in a signed application, so each project gets a venv at:

```text
~/Library/Application Support/Roast/Python/Environments/<project-hash>/py-<minor>
```

The actual base comes from `NSSearchPathForDirectoriesInDomains`, not from
concatenating `$HOME`; a future sandbox therefore redirects it into the app's
container without changing this design. A stable FNV-1a hash keeps source
paths and punctuation out of directory names while preventing projects with
the same basename from sharing packages. The Python-minor component makes a
runtime upgrade create a compatible environment instead of pointing a new
CPython at the previous version's `site-packages`.

Before Build, Run, Debug, or LSP launch, Roast overlays four values on the
inherited process environment:

| value | role |
|---|---|
| `MOJO_PYTHON_LIBRARY` | bundled library loaded into the Mojo process |
| `MOJO_PYTHON` | selected venv interpreter; KGEN turns this into `PYTHONEXECUTABLE` |
| `PYTHONHOME` | relocated bundled standard library, overriding the framework's build prefix |
| `VIRTUAL_ENV` | project environment identity for child tools and packages |

`PYTHONNOUSERSITE=1` prevents a successful import from secretly depending on
the user's global packages. Run and Debug create a missing venv asynchronously
before continuing. The Python menu can create/repair it, install the project's
`requirements.txt` or editable `pyproject.toml`, or pass one requirement to
`pip`. pip is invoked as `venv/bin/python -m pip` in the console; it is never
imported into an already initialized CPython process, and no shell parses the
package requirement.

Packaging closes over the framework's non-system dylibs and rejects absolute
dependencies left on the packaging machine. Its smoke test then creates a
real venv and has a compiled Mojo program import a marker module from that
venv. That is the minimum test which proves both halves—the relocated CPython
runtime and Mojo's in-process selection—at once.

## Scriptable, the Mac way: the agent surface

The last planned feature surface: full agentic automation of the IDE, and
screenshots. An agent -- CI, a coding assistant, a colleague's script --
drives Roast at runtime through Apple Events and sees the result through the
app photographing itself.

**What tonight's work established, and this design rests on.** The launch-time
env probes (`ROAST_DEBUG_LINE`, `ROAST_DEBUG_STEPS`) drive the app unattended
and are how the debugger's buttons got verified -- but they are decided at
launch and cannot converse. Runtime inspection from outside is walled off by
TCC: `screencapture` fails without Screen Recording, System Events fails with
-1743 without Automation, and neither can be granted headlessly, by design.
The conclusion is not to fight the wall. Make the app scriptable in its own
right -- receiving Apple Events needs no permission at all -- and give it a
screenshot verb that renders its OWN view hierarchy to a PNG, which involves
no screen capture and therefore no TCC. The one grant a human ever makes is
Automation for their agent's host process, per sender, once.

**Three layers.**

1. **Transport: one raw Apple Event handler.** Event class `Rost`, event
   `cmnd` -- text in, text out -- registered with `NSAppleEventManager` at
   launch. No KVC object graph. Works identically in the bare `bin/roast` and
   in `Roast.app`. (Sprints 1-2 folded the planned second event, `shot`, into
   this one: a screenshot's argument is a path and its answer is a path, so
   `cmnd` already carried it, and a second unpack path bought nothing. If the
   sdef in sprint 5 wants `screenshot at "..."` as its own verb, terminology
   can map it onto `cmnd` without a second event.)

2. **Terminology: an sdef, on top, later.** `Roast.sdef` gives AppleScript
   the words -- `tell application "Roast" to do command "step-over"` -- and
   is carried by the bundle (`NSAppleScriptEnabled` +
   `OSAScriptingDefinition` in make-app.sh's Info.plist, file in Resources).
   The bare binary can embed it too: `__TEXT,__sdef` and `__TEXT,__info_plist`
   sections via `-sectcreate`, for which the wrapper's `LINK` array is the
   extension point. Raw-coded events work everywhere regardless, so the sdef
   is polish, not plumbing.

3. **The command set** -- the agentic surface. One namespace, text replies:

       open <path> · goto <line> · save          the editor
       build · run · stop                        the compiler
       debug · continue · step-over · step-in    the debugger,
         · step-out · break <line> · eval <e>      via the REAL buttons
       status · console · stopped · variables    read the app's state
         · caret · file · toolbar · help
       screenshot <path>                         see the app

**Design rules, each earned this week.**

- **The agent presses the real controls.** Step verbs go through
  `_press_debug_button` -- the item looked up in the live toolbar, its action
  sent to its own target -- so every agent run is also a UI test. A button
  that breaks under the pointer breaks under the agent, and vice versa.
- **Replies are text; slow operations answer `requested`.** Build, run and
  eval complete on later ticks and report through serials internally, so the
  agent confirms by reading state (`status`, `console`, `stopped`), not by
  blocking a handler on a nested runloop.
- **One dispatcher.** The AE handlers unwrap the descriptor, call
  `agent_command(text) -> text`, wrap the reply. Everything else is the same
  functions the menus call. (v1 of this section sketched a KVC document
  model; the risk register already called that plumbing fiddly, and the env
  probes have since proven that a string surface tests beautifully here.
  Terminology stays; the object model goes.)
- **No new power.** Commands never touch a shell; `eval` has exactly the
  debuggee power a human at the keyboard already has; the only write is the
  screenshot, to the path the sender named.
- **Receiving is inert.** With no sender, the handlers are dead weight in the
  registry -- so this ships on main with no gate, in keeping with
  default-off-until-real elsewhere.

**The screenshot.** `contentView`'s superview is the frame view -- titlebar,
toolbar and content together. `bitmapImageRepForCachingDisplayInRect:` +
`cacheDisplayInRect:toBitmapImageRep:` render the hierarchy into a bitmap at
backing scale, `representationUsingType:properties:` makes a PNG, NSData
writes it. This is view drawing, not screen capture: no TCC, and it should
render even occluded or miniaturized (verified in its sprint, not assumed).
It finally answers "does the ladybug icon render" from inside the process.

**Testing, the check-ide way.** The handler path is provable without a second
process: build an event with `descriptorWithProcessIdentifier:` (own pid) and
`sendEventWithOptions:timeout:error:`, assert on the reply -- registration,
unpack, dispatch and reply all exercised. A `ROAST_AGENT` env var runs a
command script at a fixed tick for CI greps. Screenshots assert PNG magic and
a sane byte count. The osascript end-to-end run is a documented MANUAL
acceptance step, because TCC grants cannot be scripted -- that is the
security model working, not the test failing. Every API this design names is
confirmed present in the Cocoa KB, including the two load-bearing ones
(`sendEventWithOptions:timeout:error:`, `cacheDisplayInRect:toBitmapImageRep:`).

**Sprints, each landing on main, each with its acceptance line.**

1. **Transport and first light.** DONE. Handler registered; `status`,
   `console`, `help`; the self-post test. *Acceptance met:* `OK agent events
   Rost/cmnd round trip`. *Discovery, answered:* a self-post dispatches
   INLINE -- no runloop reentry, no deadlock, and it works in a process with
   no NSApplication at all. So the whole handler path is CI-testable with no
   second process and no TCC grant, which is what makes the rest of this
   cheap. One thing the sprint found: `handleEvent:withReplyEvent:` is a
   selector no SDK class declares, so it cannot be a `class` method -- the
   compiler takes encodings from the SDK. It is an `ObjCClassBuilder` with
   `encoding="v@:@@"` given explicitly.
2. **The screenshot.** DONE. `screenshot [path]`, rendering the frame view so
   the titlebar and toolbar are in the picture. *Acceptance met:* `OK
   screenshot  1417x969 px, 39180 bytes, PNG magic` from an unattended run.
   The ladybug question is answered and needed no human: the app photographed
   itself and every SF Symbol resolves -- hammer, play, stop, ladybug, the
   double-chevron continue, and the three circled step arrows.
3. **Drive the debugger.** `debug`, the four transport verbs through the
   live toolbar, `break`, `eval`, `stopped`, `variables`; the button walk
   re-run over Apple Events (env probes stay -- launch-time CI keeps them).
   *Acceptance:* the in->6, over->7, out->11 walk, driven externally.
4. **Editor and build verbs.** DONE, and wider than planned: `open`, `save`,
   `goto <line>[:col]`, `caret`, `file`, `tabs`, `tab <n>`, `type <text>`,
   `find <text>`, `views`, `sidebar <pt>`, `console-size <pct>`,
   `setting <key> [value]` -- and the master key, **menu invocation by
   visible name**: `menus`, `menu <Title>`, `menu <Title> > <Item>` through
   `performActionForItemAtIndex:`, the real dispatch, which puts every
   menued feature on the agent surface at a stroke. Build/run need no verbs
   of their own: `menu Build > ...` already reaches them, though direct
   verbs can be added when an agent wants arguments. *Acceptance met, on the
   released binary:* typed text read back from the SAVED file, divider
   moves read back from `views`, a setting round-tripped, and Zoom In
   invoked by name with its visible effect -- the status line's point size
   -- in the screenshot. One naming subtlety recorded: a top-level menu
   item's own title is often empty; the NAME lives on the submenu it
   carries.
5. **Terminology.** DONE. `ide/Roast.sdef` -- one command, `do command`,
   because the whole surface IS the command language and `do command "help"`
   lists it. make-app.sh wires `NSAppleScriptEnabled` +
   `OSAScriptingDefinition` and copies the sdef into Resources, then FAILS
   the bundle if `sdef(1)` cannot read the terminology back. The
   `-sectcreate` experiment, concluded: the bare binary embeds
   `__TEXT,__sdef` and `__TEXT,__info_plist` cleanly (segedit reads the XML
   back byte-identical, and the identity sections ship in `bin/roast`), but
   `sdef(1)` refuses a bare executable with error -192 -- so raw event codes
   work everywhere, and the BUNDLE is the terminology carrier. The Script
   Editor sentence on a granted machine stays the one manual step.

   And on top of the surface: **File > Run Script…** -- a script run against
   the live session, one function behind the menu item and the agent's
   `run-script <path>` verb. Two languages by extension: agent-command lines
   (the language `help` describes, `#` comments, echoed `> cmd` / reply into
   the console, so a hand-driven session can be saved and replayed) and
   `.applescript`/`.scpt`, run in-process by NSAppleScript -- an app sending
   events to itself needs no Automation grant, so a user's script drives
   Roast with no dialog.

**Open questions, named now so they are cheap later.** ~~Self-send runloop
reentry~~ (answered: inline, no reentry). ~~Whether the sdef can ride the
bare binary~~ (answered: the sections embed and ship, but sdef(1) resolves
terminology only from a bundle -- error -192 on a bare executable).
Whether AppleScript resolves the bare binary by
running-process name or only the bundle (sprint 1, manually). Async `eval`
ergonomics -- `requested` + poll reads fine for an agent, worth revisiting if
it grates. Multi-window, when there is more than one window.

## The toolchain is the product: services, and an installer

The direction this keeps arriving at from different roads. Written down as a
direction, not a plan: nothing below is built.

**Roast should be one client among several, not the owner.** Today the app
IS the toolchain with an editor attached -- a gigabyte, because it carries a
compiler, a language server, a debugger, a standard library, a Cocoa
database and a CPython. A thin Roast is a few megabytes and finds those
things rather than containing them.

**Two thirds of "any app can use it" needs no new interface.** LSP and DAP
are standard protocols; `mojo-lsp-server` and `lldb-dap` can be driven today
by VS Code, Zed, Neovim, Emacs, anything. What is missing is not an
architecture, it is **discovery**: a documented, versioned place the
binaries live and a way to ask which toolchain is current. That is an
installation story, and the reason it keeps coming up is that we keep
needing it for other reasons and inventing a worse version each time --
`COCOAMOJO_ROOT`, NSBundle introspection, and now a candidate list that
guesses at `/Applications/Roast.app`.

**The compiler is the one piece that wants a real service.** "Compile this"
is not a standard protocol, and it is where the performance argument lives:
a resident process holding a parsed standard library and a warm MLIR
context turns every build into a request rather than a cold start. Mojo
compiles are slow enough that this session added a spinner and an elapsed
counter to make the waiting legible; a warm service changes the category of
the problem rather than the presentation of it.

**launchd should own the lifecycle.** Every process this editor manages, it
manages by hand: NSTask, terminate, isRunning, a global holding a pid. That
code crashed twice in one afternoon -- an unlaunched task raising when
asked to launch, then raising again when asked to stop -- and the fixes are
guards around an API that raises rather than returns. XPC and launchd give
crash isolation, restart, and no zombie tasks, which is the reliability
argument standing entirely on its own.

### Decided: install it

Not a bundle. **The compiler, the language server, the debugger, the
standard library, the IDE's own source and the examples are installed**,
and Roast fronts them all. That is the whole payload -- everything the
1 GB bundle carries today -- moved to one versioned place that anything
can use, with the editor reduced to a client of it.

Roast fronts them: it is the friendly face on an installed toolchain, not
a container for one. Open Standard Library, Open IDE Source, the Examples
menu, Build, Run, Debug and completion all become views onto the
installation. Nothing about the editor's surface changes; everything about
where it looks does.

The user-editable copies stay exactly as they are. A system location is
not user-writable, so first launch still copies the standard library, the
examples and the IDE source into Application Support -- only the SOURCE of
that copy changes, from inside a bundle to the installation. That machinery
already exists and is the one piece of this that needs no design.

### The shape

    /Applications/Roast/                        the Roast folder
      Roast.app                                 thin: the editor only
      CocoaMojo/<version>/                      the toolchain, versioned
        bin/      cocoamojo, mojo-lsp-server, lldb, lldb-dap
        lib/      the dylibs, and mojo/{stdlib,max,kernels}
        share/    examples, ide-source, cocoa.sqlite
        Python/   the relocatable CPython
      CocoaMojo/current  ->  <version>          one symlink says which

`/Applications/Roast`, not `/Library/Developer`: an admin user can write
it without a password prompt, it is where a person already looks for what
they installed, and the versioned layout with a `current` symlink lives
INSIDE it -- the Xcode convention's benefits without its privileges. The
lookup order everywhere becomes: `COCOAMOJO_ROOT` (a harness pointing
somewhere deliberate), then `/Applications/Roast/CocoaMojo/current`, then
beside-the-binary (a development tree). Three generations of path-guessing
become one list, checked with `_is_toolchain` -- a root counts only if
`bin/cocoamojo` is really there.

    org.mojococoa.lsp.<version>       launchd-managed, LSP over XPC or a pipe
    org.mojococoa.compiler.<version>  the new interface: warm context, build
                                       requests, diagnostics streamed back
    lldb-dap                          already out-of-process, already a
                                       protocol; needs discovery, not design

    clients: Roast.app · cocoamojo(1) · any LSP/DAP editor · CI

Service names carry the version so two toolchains coexist and a client asks
for the one it wants -- which is the answer to the question the current
design avoids by construction.

### What it costs, honestly

The drag-to-Applications story. `make-app.sh` exists to make a bundle that
needs no installation, and a shared toolchain replaces that with an
installer and a user-facing notion of versions. That is the trade:
self-contained-and-duplicated, or installed-and-shared. Every serious
toolchain lands on the second; the first only looked right while Roast was
the only client.

Version identity is the question the design must answer, not dodge. It is
already load-bearing: `MojoPrecompiledFile` refuses bytecode from a
different compiler, the debug-info work assumes compiler and plugin ship
together, and a person may now edit their own copy of the standard library
while another client compiles against the pristine one. A shared service
has to arbitrate what a bundle made impossible.

### The installer is a signed, notarized package

Not a bespoke installer app. A **`.pkg`, signed with a Developer ID
Installer certificate and notarized**, inside a signed and notarized DMG.
This is the shape Apple documents for putting a toolchain on a machine,
and every reason is one we would otherwise have to build badly ourselves:

- **Authorization.** Writing `/Applications/Roast` needs rights this
  process does not have. `installer` asks for them the way the system
  asks for everything else. A custom app would need `SMJobBless` or the
  deprecated `AuthorizationExecuteWithPrivileges` -- a privilege-escalation
  surface written by us, reviewed by nobody.
- **Gatekeeper.** A notarized, stapled package installs with no scary
  dialog and no right-click-Open folklore. An unsigned installer app on a
  machine that has never seen us is exactly the friction this is meant to
  remove.
- **Receipts.** `pkgutil` knows what was installed and where, so uninstall
  can be truthful rather than a guess.
- **The UI is Apple's** -- familiar, localized, accessible, and not our
  bug.

**And so the CLI face disappears, which was the right instinct.** It is not
that a notarized binary may not parse argv; it is that with a `.pkg` there
is no installer app to give a CLI to. Unattended testing uses the system's
own tools -- `installer -pkg … -target`, `pkgutil --files`,
`pkgutil --forget` -- which is better than a private flag, because the
test drives exactly the path a person's click drives.

    Roast-<version>.dmg           signed, notarized, stapled
      Install CocoaMojo.pkg       signed (Developer ID Installer),
                                  notarized, stapled
      Read Me.rtf

The package installs `/Applications/Roast/CocoaMojo/<version>/`, the thin
`Roast.app`, and a small `CocoaMojo Utility.app`; a postinstall script
points `current` at the new version and registers the app.

### Reset and Uninstall

Still there from the first release -- leaving a machine the way you found
it is a feature, not an afterthought -- but they live where they can be
signed and notarized like everything else:

    CocoaMojo Utility.app     installed beside Roast, reachable from
                              Roast's Help menu, and the thing a person
                              finds when they go looking in the folder.

    Reset Installation        re-lay the current version's files from the
                              package receipt. Repairs a toolchain that
                              was experimented on. NEVER touches
                              Application Support: edited standard
                              library, examples, IDE source, projects and
                              Python environments all survive, the same
                              contract File > Reset already keeps.

    Uninstall All             remove /Applications/Roast entirely -- every
                              version, both apps, the symlink -- after a
                              confirm stating precisely what goes, then
                              `pkgutil --forget` so the receipts go too.
                              One checkbox, OFF by default: "Also remove
                              my user data (edited standard library,
                              examples, Python environments)".

The utility is a separate app so that Uninstall is not asking Roast to
delete the Roast that is running it. It is written in Swift -- the
installer path must work on a machine where nothing is installed, and the
platform's own language is the honest bootstrap. Dogfooding belongs in the
product, not in the ladder up to it.

### What signing actually costs us

Notarization refuses a package containing one unsigned Mach-O, and this
payload has **fifteen** before Python: `bin/cocoamojo-compiler`,
`mojo-lsp-server`, `lldb`, `lldb-dap`, `lldb-argdumper`, `roast`, and nine
dylibs including `libLLVM` (78 MB), `libMLIR` (159 MB), `liblldb`,
`libMojoLLDB` and `libMojoCompiler`. The relocatable CPython adds its own,
and `bundle-python.sh` already relocates its dylibs -- every one needs a
signature after that surgery. So signing is a build step over an
inventory, not a flourish at the end, and the count is the reason it must
be automated from the first sprint rather than retrofitted.

Two entitlements the toolchain genuinely needs, both of which weaken the
hardened runtime and must therefore be justified in one place and reviewed:

    com.apple.security.cs.allow-jit                 the compiler JITs;
                                                    `cocoamojo --run` is
                                                    the JIT path
    com.apple.security.cs.disable-library-validation
                                                    lldb loads
                                                    libMojoLLDB.dylib at
                                                    run time, and a
                                                    hardened process
                                                    refuses a plugin it
                                                    did not ship with

Programs a person compiles are unsigned, and that is fine: they are not
distributed, and Gatekeeper judges what arrives from outside, not what a
compiler makes locally. The debugger attaching to them is the ordinary
developer case -- and the reason the machine asks its two questions the
first time, which we already know about.

### What moves, in order

1. **The layout and the lookup.** An assembly step arranges the versioned
   tree; Roast and the `cocoamojo` wrapper resolve
   `/Applications/Roast/CocoaMojo/current` -- env override first, then the
   installation, then beside-the-binary -- every candidate CHECKED for
   `bin/cocoamojo` rather than trusted. Three generations of path-guessing
   collapse into one list. *Acceptance:* a hand-copied installation; a
   bare `roast` launched with no environment at all finds it; `check-ide`
   green against it. No signing yet, no package yet.

2. **Signing, over the whole inventory.** `tools/sign-payload.sh` walks
   every Mach-O -- inside out, dylibs before the binaries that load them,
   Python's relocated libraries after `bundle-python.sh` has moved them --
   applies the hardened runtime and the two entitlements, and then
   VERIFIES: `codesign --verify --deep --strict` plus
   `spctl --assess`. Second, because sprint 1's tree is what it signs, and
   before the package, because a package of unsigned parts cannot be
   notarized. *Acceptance:* the script reports the count it signed, that
   count equals the count found, and verification passes on every one.

3. **The package.** `pkgbuild` over the signed tree, `productbuild` with a
   distribution and a licence, `productsign` with the Developer ID
   Installer certificate, `notarytool submit --wait`, `stapler staple`.
   The postinstall script points `current` and registers the app.
   *Acceptance:* `installer -pkg … -target CurrentUserHomeDirectory` into
   a scratch root lays the tree down; `pkgutil --files` lists what it
   claims; `spctl --assess --type install` accepts it; and on a machine
   that has never seen it, double-click installs with no Gatekeeper
   dialog.

4. **CocoaMojo Utility.app** -- Reset Installation and Uninstall All,
   signed and notarized with the rest, reachable from Roast's Help menu.
   *Acceptance:* sabotage the installed standard library and watch a build
   fail, Reset heals it and the build passes, while a marker file in
   Application Support survives untouched; Uninstall leaves nothing under
   the root and nothing in `pkgutil` receipts, keeps user data by default,
   and removes it when the checkbox is ticked.

5. **The thin app.** `make-app` stops folding the toolchain into
   `Contents/Resources`; `migrate_user_space` copies from the installation
   instead of from the bundle. *Acceptance:* `Roast.app` under 50 MB, the
   full gate green against thin-app-plus-installed-toolchain, and first
   launch still populating user space exactly as it does today.

6. **The DMG**, replacing `make-app`'s drag image: package, read-me,
   signed, notarized, stapled. *Acceptance:* mount it on a clean machine
   state, install, and every acceptance above still holds.

7. **Versions coexist.** A second version installs beside the first,
   `current` moves, the old stays runnable by explicit path, and Uninstall
   can name one version rather than all. *Acceptance:* two versions on
   disk; a build through `current` and a build pinned to the older one
   both pass.

Then the **LSP as a launchd service** -- already a protocol on a pipe,
already where the crashes were -- and the **compiler service** last: the
biggest win, a warm context instead of a cold start, and the only piece
needing an interface designed from nothing.

### The release runs on a different machine

Building happens here; **signing, packaging and notarization happen on a
macOS VM** that holds the identities. That is the right shape -- release
credentials do not belong on a development machine -- but it is a
constraint on the scripts, not a detail of who runs them:

- **Every release script takes its identity as an argument** and hard-codes
  nothing: `--sign-app`, `--sign-installer`, `--notary-profile`. A script
  that knows one machine's certificate cannot run on the machine that has
  it.
- **The unit that travels is self-contained.** `make-release.sh` here emits
  a `release/` folder -- the payload, the scripts that sign and package it,
  the entitlements plist, a manifest of every Mach-O the signer must
  account for. Nothing in it reaches back into the repository, because on
  the far side there may not be one.
- **Verification runs on both sides.** The manifest is written here and
  checked there: if the count the signer signed does not equal the count
  the build found, the release stops. A payload that gained a dylib in
  transit is exactly the failure notarization would otherwise report as
  something inscrutable an hour later.
- **The staple comes home.** The signed, notarized DMG returns as the
  artifact; nothing here re-signs it, and `spctl --assess` on this machine
  is the last check before it is a release.

### What this needs that we do not have

Present on the build machine: a **Developer ID Application** certificate
(`[redacted] ([redacted])`), which is what sprint 2 signs the
fifteen Mach-Os with.

Needed on the signing VM, and not verifiable from here: a **Developer ID
Installer** certificate -- a different certificate type from the
Application one, and the only thing `productsign` accepts -- and a stored
`notarytool` credential profile. Sprints 1 and 2 are unblocked either way;
sprint 3 is where the VM becomes load-bearing.

## What the stdlib must grow

Honest gaps, each small, each reusable beyond the IDE:

1. ~~**`std.json`**~~ — **done** as `ide/json.mojo`, 30 tests. Belongs in the
   stdlib once it has been used in anger.
2. **`std.rope`** — the persistent rope belongs in the stdlib, not the app.
3. **East Asian width table** — cell-width classification for the grid.
4. ~~**`class_addProtocol`**~~ — **done**, as `ObjCClassBuilder.add_protocol`,
   with `add_method_unchecked` alongside it for signatures the typed IMP
   shapes cannot express (`selectedRange` returns an NSRange by value,
   `firstRectForCharacterRange:` an NSRect).
   *(Milestone 0 closed a neighbouring gap: `IMP*Obj` shapes, for delegate
   methods that answer with an object. They return `Int` rather than a pointer
   because Objective-C delegates must be able to answer nil and Mojo's
   `Pointer` is non-nullable by construction — an `id` as an address is the
   same register and keeps the nullability where Objective-C put it.)*
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
| 0 | **done** — shell: window, native tabbing, menu, toolbar, status bar, sidebar | `tools/check-ide.sh` — 7 checks green |
| 1 | **done** — rope, GridView, NSTextInputClient, caret, selection, undo, find | 250k lines in 5 ms, keystroke 2.4 µs, snapshot 400 ns; 59 editing checks + 37 rope checks; Pinyin still to try with a real IME |
| 2 | LSP: **diagnostics and completion done**; definition and semantic tokens to come | `check-ide.sh` completes `setTitle: (ObjCObject) -> None` inside a msg_send string |
| 3 | **done** — documents: open, save, tabs, dirty tracking, project navigator | two tabs from the sidebar; re-opening a file selects its tab rather than duplicating it |
| 4 | **done** — build, run, console pane, jump-to-error, examples project | Roast builds Roast: 408 KB binary, and the binary it produced opens a window |
| 5 | **projects**: folder tree in the sidebar, project-wide search | open `ide/`, click through the files, search across them |
| 6 | AppleScript dictionary + `check-ide.sh` | osascript drives edit→build→diagnostics in CI |
| 7 | (optional) Metal glyph renderer | 120 Hz scroll measurement says it's needed, or it isn't built |

### Documents, and why they are their own milestone

Milestones 0–2 were written as though there were one buffer, and there is: the
rope, the caret, the selection, the undo stack, the marked range, the revision
and the document URI are all process globals. That was the right shape for
proving the editor works and it is exactly wrong for tabs.

So milestone 3 is a refactor before it is a feature. A `Document` gathers what
is currently spread across roughly forty globals; the app holds a list of them
and an index; the grid view draws the current one. Tabs then cost almost
nothing, because AppKit's native tabbing is already switched on and the window
already has a tabbing identifier — what was missing was ever having a second
thing to show.

It comes before build and run rather than after, for a reason that only shows
up when you try: building compiles a file on disk, so Run on an unsaved buffer
is a question that has to be answered before the Run button can mean anything.

### Build, and what a project turns out to be

Mojo has no link step. The compiler is handed one file and follows its imports
from there, so a project does not need a list of sources — it needs an entry
point, and everything else in it is reached by being imported. That single fact
decides the whole build model, and it is why there is still no project file.

Which file is the entry point, cheapest test first:

1. `main.mojo` in the project root — the convention, and what `examples/` uses.
2. the file on screen, if it is in the project root and declares a top-level
   `main` — with several to choose from, the one being looked at is the one
   meant.
3. the one non-test file in the root that declares a top-level `main`.
4. the file on screen.

Step 4 is what makes a single loose file with no project around it buildable:
there is no separate single-file mode, it is the same question with a smaller
answer. Step 3 skips `*_test.mojo` because every test suite here declares a
`main` and none of them is what the project is — without that rule `ide/` has
six candidates and picks a test.

Two details cost a debugging session each and are worth writing down. "Declares
a `main`" means at the start of a line, not anywhere in the text: `build.mojo`
documents this rule using the exact string it searches for, so a substring
scan nominates it as the entry point of the entire editor. And Build saves
every dirty buffer first, because the compiler reads the disk — building
without that compiles the last save, which looks precisely like the compiler
ignoring your fix.

Output goes to `<project>/build/<stem>`, beside the source and inside the
folder the sidebar already hides. Run is Build followed by the binary, with the
working directory set to the project, so a program that writes a file writes it
where its source lives — `examples/fern` leaves its `fern.png` in
`examples/fern`. Run happens only if the build exits zero.

The process is an `NSTask` with stdout and stderr on one pipe, drained without
blocking from the same timer that drains the language server, for the same
reason: a compiler thinking hard must not be an editor that has stopped
responding. One pane for both streams, because a build that succeeds and then
runs is one continuous thing to read. On failure the first error is parsed out
of the log and the caret goes to it — opening the file if it is not open, which
matters because the error is often in something the entry point imported and
you have never had on screen.

### A project is a folder

No project file, no workspace format, no index to rebuild. Open a folder and it
is a project; the files in it are the project's files. `ide/` is the working
example, and the test: open it, see `roast.mojo`, `rope.mojo`, `gridview.mojo`,
`lsp.mojo`, `json.mojo` and their tests, click one, edit it.

The sidebar is an `NSOutlineView` whose items are paths. Children are listed
lazily and cached per directory, so opening a folder never walks it — a tree
with a quarter of a million files under it costs whatever is expanded and
nothing else, which is the other reading of the original requirement and the
one that decides the design. Dotfiles and build output are hidden.

Selecting a row opens that file, which is the whole interaction: no drag, no
context menu, no rename in v1. `mojoproject.toml` can arrive later to name an
entry point and build flags; until something needs it, a folder is enough.

Opening and saving are the small half and land first. Until they do, the File
menu is advertising three commands that do not exist -- `Open…` and `Save` have
no implementation at all, and `New Tab` calls `addTabbedWindow:` with the window
itself, which duplicates a window rather than opening a document.

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
- **Managing child processes by hand** is where this has actually broken.
  NSTask raises rather than returning: launching a missing executable and
  terminating an unlaunched task each took the editor down, and an
  Objective-C exception crossing back into Mojo has no handler. Every such
  call is guarded now, but the guards are the symptom -- the toolchain
  services above are the treatment.
- **Path guessing has three generations** and they disagree:
  `COCOAMOJO_ROOT`, NSBundle introspection, and a candidate list that looks
  for `/Applications/Roast.app`. Each was added because the previous one
  failed somewhere new. An installed, versioned toolchain replaces all
  three with a lookup.
- **250k-file trees** (the other reading of the requirement): the sidebar is
  lazy `NSOutlineView` children and never stats a directory it hasn't opened;
  project search shells to `ugrep` when present.
