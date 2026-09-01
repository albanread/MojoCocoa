# The debugger — gaps and sprints

A review of Roast's debugging feature — `ide/dap.mojo` (the DAP client),
the wiring in `ide/roast.mojo`, the gutter in `ide/gridview.mojo`,
`ide/dap_test.mojo`, and the debugger checks in `tools/check-ide.sh` —
turned into execution order. Nothing here touches the plugin or the
compiler: the semantic ceiling (expression evaluation over frame locals,
method calls, non-scalarised types) is mapped in
`spikes/MOJOLLDB-SPIKE.md` and stays there.

## What is already right, and stays

Recorded so a sprint does not re-litigate it:

- **The architecture.** The editor speaks DAP to `lldb-dap` over a pipe
  and never debugs Mojo itself — the same seam as the LSP. Process
  isolation is the decision, not an accident.
- **Breakpoint slide honesty.** Markers draw at the line the adapter
  *bound* (`verified_line`, drawn at `gridview.mojo:492`), the take-once
  freshness handshake keeps stale locals off screen, and `_take_stack`
  pins the stop to the frame the adapter reported.
- **Teardown.** `stop()` disconnects with `terminateDebuggee` before
  terminating the adapter, because a killed adapter strands a stopped
  debuggee forever — earned the hard way, per the spike's notes.
- **Stream hardening.** Content-Length sanity limits, resynchronisation
  over junk, UTF-8 chunk boundaries, and debuggee bytes sanitised at the
  edge (`_display`).
- **The test's honesty.** `dap_test.mojo` pins not just what works but
  what fails-with-words, and skips (rather than fails) the variables
  section when no Mojo plugin rides beside the adapter.

## The gaps

**Robustness.** Adapter death is undetected: `poll()` breaks on EOF
without changing state (`dap.mojo:715`) and nothing checks
`NSTask isRunning` — unlike the build driver, which reaps exactly this
way (`build.mojo:396`). After an adapter crash the session looks alive,
`Debug` says "Already debugging", and `Stop` writes into a closed pipe,
which raises an Objective-C exception Mojo cannot catch — the documented
un-catchable class. `stop()`'s 200-spin drain loop has no sleep, so it
finishes in microseconds, long before the adapter can answer the
`disconnect` it is supposedly draining. And `pause()` is implemented
(`dap.mojo:695`) but reachable from nothing — no menu item, no toolbar
button, no agent verb, no key. A runaway loop cannot be interrupted
without killing the session.

**The editor's own jobs.** Breakpoints do not follow edits: insert or
delete lines above one and it stays on the old line number, though the
rope already knows every edit span. They are not persisted across app
restarts, though `session.mojo` already persists settings and tabs. The
agent's `break <line>` works only on the entry-point file
(`roast.mojo:5558`). The `initialize` response is never parsed, so
capabilities are ignored — `exceptionBreakpointFilters` could make Break
on Raise a live toggle instead of "next session only" (`roast.mojo:2403`),
and `setBreakpoints` never carries `condition`/`hitCondition`, so
conditional breakpoints are one JSON field away. Output events with the
`console` category are dropped (`dap.mojo:881`) — the category that
carries lldb's own warnings, including the one that explains an empty
locals pane on an Xcode-adapter machine.

**Surface.** The stack prints but cannot be selected — `g_frame_id` is
only ever the top frame (`dap.mojo:970`) — and it is capped at eight
frames with no paging. Threads are tracked (`stopped.threadId`) but
never listed or chosen. There is no breakpoints navigator, no
enable/disable, no logpoints. The console is read-only: evaluation is
selection-only (⇧⌘E) or agent-driven. Every Debug press recompiles from
scratch; there is no Restart. Two evaluations in quick succession
cross-wire the reply (one expr/result slot, no request-id matching).

**Testing.** `pause`, mid-session breakpoint resends (the `g_bp_dirty`
path), breakpoints in non-entry files, adapter-crash behaviour, stacks
deeper than eight, and thread events have no coverage anywhere. The
UI-level checks are gated behind `ROAST_CHECK_DEBUGGER=1` (the macOS
attach dialog needs a human), so a default CI run exercises the protocol
client but never the toolbar/menu path — each sprint below says which
side of that gate its verification lands on.

## Sprints

Numbered D1–D8 so they cannot collide with `improvement_sprints.md`
(plain numbers), `cocoa_improvement_sprints.md` (P-numbers), or
`IDE-DESIGN.md`'s milestones.

**Ordering.** D1 is first and alone: it closes the one path that crashes
the editor, and its state clearing is a precondition for honest tests of
everything after. D2 is small and mostly written. D3 is the papercut
that bites daily. D4 is the protocol literacy the surface sprints want
to lean on; D5 wants D4's capabilities gate. D6 and D7 are independent
of each other and can run in either order or in parallel. D8 is last and
optional. Nothing here needs the plugin; nothing here is blocked by it.

### Sprint D1 — process lifecycle (IMPLEMENTED 2026-09-01, size S)

**Status.** Landed. A SIGKILLed adapter is reaped by the tick's `poll()`
(`_adapter_alive`, mirroring `build.mojo`'s reap), `_send` refuses to write
into a dead pipe, `stop()` sleeps between drain spins so the disconnect is
actually read, and `dead_why()` gives the status line its words. Verified in
`dap_test`'s lifecycle section: kill → reaped, `stop()` a clean no-op, a
fresh session starts, no orphaned debuggee.

1. **Reap on EOF, the build driver's way.** In `poll()`, a read of 0
   (or a negative return) with the task not `isRunning` means the adapter
   is gone: clear `g_task`/`g_in`/`g_read_fd`, reset the phase, clear the
   stop state, reset `bound`/`verified` on breakpoints (they are facts
   about a process that no longer exists — the same rule `stop()`
   applies), bump `g_serial`, and record a distinguishable reason so the
   status line can say "debug adapter exited" rather than nothing.
   Mirror the shape of `build.mojo:389-403`, which already solves this
   for the compiler task.
2. **Guard `_send`.** Check `NSTask isRunning` before `writeData:` so no
   code path — the tick's dirty-breakpoint resend, `Stop`, `evaluate` —
   can write into a pipe whose reader died. The guard is the only
   defence available: an `NSFileHandleOperationException` is an
   Objective-C exception crossing into Mojo, and there is no handler for
   that.
3. **Make `stop()` actually drain.** Sleep between spins of the
   disconnect loop (`std.time.sleep`, a few milliseconds) so the
   adapter has time to read the `disconnect` and act on it before
   `terminate` arrives. The comment claims "drained rather than slept
   through"; as written the loop spins out in microseconds and
   termination does the work. lldb-dap cleans up on SIGTERM today, which
   is why this passes — the sprint makes the code mean what it says.
4. **A symptom worth naming in the status text**: after a reaped
   adapter, `Debug` must start a fresh session, not answer "Already
   debugging" (`roast.mojo:837` gates on `is_running()`, which today
   stays true forever).

Verification (headless, `dap_test.mojo`): start a session, kill the
adapter with `kill(pid, SIGKILL)` (the pid from the task's
`processIdentifier`), then assert `is_running()` goes false, the
breakpoint bindings reset, `stop()` is a clean no-op, and a second
`start()` launches. In `check-ide.sh`: a run whose adapter is killed
mid-session still exits cleanly with no orphaned debuggee on the process
list.

### Sprint D2 — Pause, at last (IMPLEMENTED 2026-09-01, size S)

**Status.** Landed, with one protocol fact corrected on the way: thread id
0 is not "whatever is running" to lldb-dap, it is a refusal (`pause
success False`, measured). `pause()` now asks `threads` first when no stop
has named a thread, and the reply sends the pause. The interrupt landing
inside a syscall reports stop reason `exception` rather than `pause` —
either way the program is stopped, and the test accepts both. Debug-menu
item *Pause* (⌃⌘Y, Xcode's chord) and the agent verb `pause` are wired;
the toolbar-item toggle was not needed.

1. Wire `dap.pause()` into the Debug menu — *Pause*, ⌃⌘Y (Xcode's
   pause/resume chord; ⌘Y/⇧⌘Y are taken by Start/Stop and F5 is
   Continue, so the row keeps its logic). Status "Pausing…" then the
   ordinary stop handling when the `stopped` event arrives — the reason
   string arrives as `pause` and needs no new machinery.
2. The agent verb `pause`, direct rather than through a toolbar item
   (there is no toolbar item — see 3), answering `requested` like `eval`.
3. Optional, decided in-sprint with a screenshot: the Continue toolbar
   item becomes Pause while the program is running — same position, same
   item, symbol and action swapped. The UI doc's rule is that the bar
   must not change *shape* while someone is reaching for it; swapping
   one item's symbol is not a shape change, but if it reads badly in the
   screenshot, the menu item and agent verb alone are enough.
4. Note the thread-0 comment at `dap.mojo:699` — "whatever is running"
   is lldb-dap-specific behaviour — and pin it with the test before
   relying on it anywhere else.

Verification: `dap_test.mojo` gains a program that runs for a while
(a loop, not a sleep against the wall clock), then
`pause()` → pump → assert `is_stopped()` with reason `pause`, then
`resume()` → pump → `exited()`. Agent side: `pause` then `stopped`
answering `yes …(pause)`, in the `ROAST_AGENT_STEPS` style — headless
through the self-event path, no TCC gate.

### Sprint D3 — breakpoints that tell the truth (PARTLY LANDED 2026-09-01)

**Status.** Three of the four pieces landed: breakpoints follow edits (a
shift hook at every buffer-edit site in `gridview.mojo`, plus undo/redo
deriving the same shift from the two ropes' line counts and the
remembered caret), they persist per project (`breakpoints` rows in the
session document, restored as unverified intentions), and the agent can
`break <path>:<line>` in any file.

**The fourth piece — canonicalising paths — was tried and REVERTED, and
the lesson is the reason this status paragraph exists.** The compiler
records a compile unit's path as whatever ABSOLUTE path it was handed,
and realpaths only arguments it had to resolve itself; the debug adapter
matches breakpoints by that spelling exactly. A client-side
"resolve symlinks before sending" rule therefore guesses — and it breaks
whichever environment spells the other way: it mismatches a CU compiled
from an as-given `/var/folders/...` (the check fixtures) while claiming
to fix a CU compiled relatively under `/tmp`. Breakpoint stop-and-step
worked before that change in every environment the project uses, and the
change broke the primary one. Reverted completely — `lsp.canonical`
deleted, `toggle_breakpoint`/`shown_path`/document uris back to as-given
spelling. The rule that is actually true: **path spellings must flow
from one source — how the file was opened — and the breakpoint store is
not that source.** If the symlinked-project case ever matters, the fix
belongs at the compile command (hand the compiler the resolved entry so
the CU is canonical by construction), decided deliberately, not guessed
client-side.

1. **Follow edits.** The rope's edit pipeline already computes the span
   every keystroke replaces (it is how incremental `didChange` is built).
   Feed the same spans to the breakpoint lists: an edit that replaces
   `old_lines` with `new_lines` in a file shifts every breakpoint below
   it by `new_lines - old_lines`, collapses any breakpoint inside the
   replaced span to the edit's start line, and resets `bound`/`verified`
   on the moved rows with `g_bp_dirty` set — the adapter re-answers with
   where it now binds, and the gutter re-draws. A marker that drifts the
   moment you edit during a session is the papercut; this removes it.
2. **Persist them.** `debug.breakpoints` in the session file, one
   `path:line` per entry, restored on project open as unverified
   intentions (`bound = 0`, `verified = 0`, dirty) — the state a
   breakpoint has before any adapter exists, which is exactly the state
   the pre-`start` path already handles.
3. **Agent `break <path>:<line>`.** Accept a project-relative or
   absolute path; bare `<line>` keeps today's entry-point meaning. An
   agent (and a check) can then break in an *imported* file — the
   common debugging case, and today impossible without a mouse.

Verification: an editor-level check (the `ROAST_`-env style, headless)
that sets a breakpoint, types newlines above it, and asserts the marker
and the asked-for line both moved by the count typed; a `dap_test`
addition that toggles a breakpoint mid-session and asserts the resend
re-binds (covers `g_bp_dirty`, which no test touches today); the agent
walk in `check-ide.sh` sets its breakpoint in a second file, imports it
from `main.mojo`, and asserts the stop lands there — this one needs
`ROAST_CHECK_DEBUGGER=1`, so its headless half is the `dap_test`
mid-session case.

### Sprint D4 — read the handshake, forward the warnings (IMPLEMENTED 2026-09-01, size S)

**Status.** Landed. The initialize response is parsed
(`_take_capabilities`), `configurationDone` is sent only when the adapter
wants it, and the `console`/`important` output categories are forwarded —
which is how lldb's *"This version of LLDB has no plugin for the language
'mojo'"* warning became visible in the IDE console (verified in the
condition test: the adapter's own error text now reaches the person at
the keyboard). One fact read off the wire: our adapter advertises only
`cpp_catch, cpp_throw, objc_catch, objc_throw` — no mojo/raise filter —
so `set_exception_breakpoints` exists and works as the live path for
adapters that have one, while Break on Raise on OUR stack stays on the
`preRunCommands` fallback, honestly labelled "next debug session". The
`break ... if` verb also notes when it is used outside a session, since
capabilities are only known once one is running.

1. **Parse the `initialize` response** into a capabilities global (the
   JSON machinery exists): `supportsConfigurationDoneRequest` gates the
   `configurationDone` send (default true, as today),
   `supportsTerminateRequest`, `supportsConditionalBreakpoints` — which
   D5 wants to gate its UI on — and `exceptionBreakpointFilters`.
2. **Break on Raise, live.** If the adapter advertises a filter, DAP's
   `setExceptionBreakpoints` after launch toggles it mid-session, which
   retires the "takes effect on the next debug session" caveat for every
   adapter that speaks it. Discover rather than assume: our plugin's
   `mojo break-on-raise` is a `preRunCommands` today, and whether it
   also registers a DAP filter is a fact to read off the capabilities
   reply, not to guess. The `preRunCommands` path stays as the fallback
   for adapters without the filter.
3. **Forward the adapter's own words.** Admit the `console` and
   `important` output categories alongside today's `""`/`stdout`/
   `stderr` (`dap.mojo:881`); keep `telemetry` excluded. Then verify
   with `ROAST_DAP_TRACE` which category actually carries lldb's
   *"This version of LLDB has no plugin for the language 'mojo'"*
   warning on an Xcode-adapter machine — if it is `console`, the IDE
   console now says why the locals pane is empty instead of saying
   nothing.

Verification: `dap_test` asserts capabilities were parsed and
non-empty for our adapter and Xcode's; a mid-session filter toggle
changes stopping behaviour (fixture: a program that raises); the
no-plugin warning text appears in the console output global when run
against Xcode's adapter, and the check script's skip rationale matches
what the app itself now shows.

### Sprint D5 — breakpoint affordances (PARTLY LANDED 2026-09-01; wants D4)

**Status.** The data and the wire landed: per-row `condition`,
`hitCondition` and an enabled flag (omission from the request IS the
protocol's disabling, tracked with a reply-slot map so positional replies
still land on the right rows), plus the agent surface — `break <line|path:line>
[if <expr> | hit <n>]`, `bps`, `bp-on <n>`, `bp-off <n>`. Measured
against the real adapter: **hit counts work** (third hit stops on the
third iteration), **disable works** (the program runs to exit, never
stops), and **conditions reach the adapter and are honoured by lldb — but
the plugin's expression parser cannot see frame locals yet** (the spike's
documented JIT limitation), so a condition errors and lldb stops on the
error. The test pins exactly that, including the error text arriving in
the console. Conditions become useful the day frame locals land in the
JIT; the client side is done. NOT built: the gutter context menu and the
navigator pane — `bps` is the honest agent stand-in, and a pane wants a
Cocoa surface decision (D6/D7's pane, or the sidebar's).

1. **Conditions and hit counts**: `condition` and `hitCondition` on the
   `setBreakpoints` payload (`dap.mojo:483` is where they go), gated on
   D4's capability flags. Surface: a context menu on the gutter marker
   (condition…, hit count…, disable, remove) and the agent spelling
   `break <line> if <expr>` / `break <line> hit <n>`.
2. **Enable/disable without deleting** — a per-row flag that filters the
   `setBreakpoints` payload and draws the marker hollow (the unverified
   visual already exists to copy).
3. **A breakpoints navigator** — a section of the sidebar or drawer
   listing `file:line [condition]` rows: click to open and jump, ⌫ to
   remove, the same toggle the gutter uses. It is the only way today to
   see breakpoints in files that are not open, which after D3 is a
   bigger set than it was.
4. Logpoints are named and not built: they want console-input plumbing
   D7 owns, and a row's worth of UI for a feature nobody has asked for
   yet.

Verification: a conditional breakpoint stops only on the satisfying
iteration (count the stops); a hit count of 3 stops on the third; a
disabled row never stops and still survives a session restart via D3's
persistence; navigator rows jump to their file and line. `dap_test`
covers the wire shape; the rest rides the agent checks.

### Sprint D6 — frames and threads (IMPLEMENTED 2026-09-01, size M)

**Status.** Landed. The stack pages (32 at a time, bounded at 96 — the
45-frame recursion fixture proves the second page), frame ids are kept
alongside the lists, `select_frame(n)` re-runs the scopes/variables chain
for the chosen frame (frame 1's `level == 1`, frame 0's `level == 0`,
verified), and `threads` is requested on every stop and listed
(`thread 0 = Thread 1`; more when the program has them). The console's
stack block marks the selected frame and names thread count when there
is company. The agent verbs `frames`, `frame <n>`, `threads` are wired;
clickable console lines and a pane remain the later upgrade, as planned.

1. **Paging the stack.** Request frames in pages (32 at a time) while
   the reply's `totalFrames` says more remain, instead of the fixed
   `levels: 8` (`dap.mojo:869`). The console keeps its
   `_startup.mojo` cut-off for the printed walk; the *data* stops
   truncating. Deep recursion is the normal case in the programs this
   editor debugs.
2. **Frame selection.** An agent verb `frame <n>`: sets the current
   frame, re-requests `scopes`/`variables` for it, and makes `eval`
   use it — the machinery is the stop chain with a different `frameId`,
   so this is mostly plumbing plus a current-frame global that `evaluate`
   reads instead of the hard-wired top-frame id (`dap.mojo:970`).
   Clickable console lines and a variables pane are the upgrade path,
   deliberately later; the verb is the honest increment and the test
   surface.
3. **Threads.** On a stop whose `allThreadsStopped` is set, issue the
   `threads` request and report the list (status line count, console
   block, `status`/agent reply). An agent verb `thread <n>` selects
   which thread `stopped`/`stackTrace` describe. A thread *pane* waits
   until there is a pane that can hold one.

Verification: `dap_test` on a 20-deep recursion shows every frame;
selecting frame 1 in the `add`/`total` fixture shows `sum` and not
`total` — the existing "wrong frame" assertion, inverted into a
feature test. Thread assertions ride what the fixture can produce
(dispatch_async is enough to make a second thread); if the fixture
cannot, the `threads` round-trip is pinned and the rest is marked
skipped, the way plugin-less variables are.

### Sprint D7 — the console becomes a REPL (PARTLY LANDED 2026-09-01)

**Status.** Two of the three pieces landed: evaluate replies are matched
by `request_seq` (a second ask no longer leaves the first answer
attributed to it; dropped replies are counted, and the test asserts the
count deterministically), and the console has an input line — an
NSTextField above the output, target/action into the same class every
other control talks to, Enter echoes `» expr` and evaluates in the
stopped frame through the one `evaluate` path shared with ⇧⌘E and the
agent. NOT built: input history — it wants a field-delegate for arrow
keys, a piece of Cocoa surface not worth its risk on the day; named here
so it is a decision rather than an omission.

1. An input line in the console pane, shown while stopped: type an
   expression, press Return, the answer lands in the flow above beside
   the locals. ⇧⌘E stays as the selection shortcut. History in the
   session file, because a REPL without history re-types everything.
2. **Request-id matching for `evaluate`**: tag requests with their seq,
   match responses on `request_seq`, and ignore replies whose request is
   no longer the live one. Today a second eval before the first reply
   lands overwrites the expression slot and the first answer arrives
   attributed to the second — fine while evaluation is a rare gesture,
   wrong the moment there is an input line.
3. Context stays `"watch"` (`dap.mojo:217` documents why: `"repl"` lets
   the adapter mistake an expression for an lldb command). Decide
   in-sprint whether a `!`-prefixed escape to real lldb commands is
   worth it; the default is no — the menus are the surface for commands,
   the console for Mojo.

Verification: `dap_test` fires two evaluations back to back and asserts
each reply is attributed to its own expression; the editor check types
`total` into the console and reads the value back from the console text;
an error prints its words, not an empty line.

### Sprint D8 — Restart, and the iterate loop (IMPLEMENTED 2026-09-01, size S)

**Status.** Landed as relaunch-not-rebuild: `relaunch()` in dap.mojo keeps
the last launch config and re-runs it after a clean `stop()`; the Debug
menu has *Restart* (⌃⌘R) and the agent verb `restart` answers
`requested`. Verified: the relaunched run stops on the same line with
the same breakpoints, no compiler involved. The skip-rebuild-on-Debug
half (item 2) stays unbuilt, as the sprint itself recommended against
it.

1. **Restart = relaunch, not rebuild.** A Debug menu item and agent verb
   that disconnects (D1's teardown) and launches the *existing* debug
   binary again — no compiler, no `--debug-level full` wait. The person
   pressed Restart, not Debug; VS Code's restart has the same semantics,
   and it makes the edit-stop-step loop a two-second turn instead of a
   compile. Staleness is the user's to notice — the console already
   names the binary it is debugging.
2. `Debug` itself may reuse a current `-debug` binary when nothing
   changed, but that wants a staleness story (imports included) that is
   not worth its cost yet; if it ever grates, the honest version is a
   content hash of the files the build read, not mtimes.

Verification: time a Stop→Debug cycle against a Restart cycle in an
unattended run and assert the compiler was not invoked for the restart
(no build line in the console, no compile time in the serial); the
program stops on the same breakpoints, re-bound fresh.

## Deliberately not in this plan

- **Anything in `spikes/MOJOLLDB-SPIKE.md`'s critical path** — the
  frame-local type filter, the semantic sidecar, declaration surfaces.
  The spike's ordering stands: the type filter first, the contract as
  one deliberate piece, the declaration surface after. IDE surface built
  on storage-level facts before that contract exists is the thing the
  spike warns against.
- **Moving `_pretty_type` and the hex-strip into the plugin's
  formatters.** They belong in `Language/Formatters/` and will keep
  accreting scalars in the editor until they move — but that is plugin
  work, listed here only so the next reader knows it was seen and
  parked, not missed.
- **A variables pane with expandable children, a memory view,
  disassembly, step-by-instruction.** All named in the code as later
  things; all want a pane that can expand things, which is a Cocoa
  surface decision before it is a DAP one.
- **Reverse requests.** Traced, never answered (`dap.mojo:780`), and
  nothing Roast sends today solicits one. If `runInTerminal` ever
  appears in a launch config, answering it becomes a sprint of its own.

## Standing verification commands

```bash
tools/check-ide.sh                 # the dap suite, headless — every sprint's floor
ROAST_CHECK_DEBUGGER=1 tools/check-ide.sh   # the in-app walk; needs the human-gated
                                    # macOS attach dialog, so it is the release
                                    # ritual, not the default run
ROAST_DAP_TRACE=1 …                 # every message both ways (requests included)
                                    # that is not a `module` event
```

The extended `dap_test` runs five extra sessions beyond its original one
(lifecycle-kill, pause, deep stack, conditions, relaunch). The pause and
deep-stack sessions need two fixtures a caller provides — a program that
runs long enough to interrupt (`ROAST_DAP_SPIN`) and a 40-deep recursion
(`ROAST_DAP_DEEP`, plus `ROAST_DAP_DEEP_SOURCE` for the breakpoint); each
section **skips cleanly when its env is absent**, so the check's default
behaviour is unchanged until `check-ide.sh` wires the fixtures in the
same style as the existing one. Compile fixtures the way the check
already does — absolute path as given, source env relative, run from the
fixture directory — because that is the spelling contract the compiler's
DWARF and the adapter actually keep (see D3's status).

Each sprint's own acceptance is in its section; the floor for all of
them is `check-ide.sh` green on the headless side, with the dap suite
extended to cover whatever new client state the sprint introduced —
the review's testing gaps (`pause`, mid-session resends, non-entry
breakpoints, adapter death, deep stacks, threads) are closed by the
sprints that own the features, not by a separate testing sprint.
