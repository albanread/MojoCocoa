# Fix list

Notes from human testing. Round one: all twelve entries below were fixed
and verified; the loud half (1-5, 7, 9) landed in 9acd80c and the
interaction half (6, 8, 10, 11, 12) in the commit that updated this line.
Details live in those commit messages; the entries are kept as filed, for
the record of what testing actually surfaced.

1. **Highlighter: docstring continuation lines lose their color.** In a
   triple-quoted string, only the line carrying the opening `"""` is
   highlighted as a comment/string; the following lines render as code.
   Seen on:

       """One plant's standing state. The bend is computed fresh each
       frame from the wind, so nothing here moves except by being
       recalculated."""

   Likely cause: the highlighter is per-line and carries no "inside a
   triple-quoted string" state between lines.

2. **Shipped example warns on build.** `fernwind/main.mojo:127` trips the
   doc-string lint -- the summary opens with a formula, and `x'` begins
   with a lowercase letter:

       warning: doc string summary should begin with a capital letter or
       non-alpha character, but this begins with 'x'
           """x' = a x + b y + e,  y' = c x + d y + f, chosen with
           probability p."""

   An example that ships with the toolchain should build silently. Easiest
   fix is a leading word ("Affine map: x' = ..."); worth a sweep of every
   example for other warnings while there.

3. **False error squiggle on `from max.gpu.host import DeviceContext`.**
   The editor marks it as an error (red gutter, underline) yet the build
   runs fine. Cause found: the build and the language server disagree
   about the import roots. `bin/cocoamojo` passes three --

       INC=(-I "$PKG/stdlib" -I "$PKG/max" -I "$PKG/kernels")

   -- while `lsp_import_path()` (roast.mojo:3723) returns ONE,
   `lib/mojo/stdlib`, so the server cannot resolve `max.*` and diagnoses
   an import the compiler accepts. Fix: the LSP must get the same three
   roots the build gets (and `ROAST_IMPORTS` should take a list). Check
   whether the server takes multiple roots in its settings; the wrapper's
   INC array is the single source of truth to mirror.

   More of the same, seen later in testing: the STATUS BAR reports
   "unable to locate module 'max'" while the build runs fine -- the
   server's resolution failure surfaced as if it were the truth about the
   program. Worth checking, when fixing: whether the status line should
   ever relay a diagnostic class the build demonstrably contradicts.

4. **Deprecated pointer arithmetic in a shipped example.**
   `fernwind/main.mojo:292` warns:

       warning: '__add__' is deprecated, use 'unsafe_offset' instead
           _ = Atomic.fetch_add(bacc + pat, cb)

   Same rule as entry 2 -- shipped examples build silently -- and same
   sweep should catch both: build every example and fix every warning,
   not just the two that testing happened to surface.

5. **Every build warns: `'sse4.1' is not a recognized target feature`.**
   Emitted with no source location (`<unknown>:0`) on every example -- so
   it reads as noise from the toolchain itself, which is worse than a
   warning in one program. Cause located: `CpuId.has_sse4()` in
   `mojo/stdlib/std/sys/info.mojo:215` asks the target about `"sse4.1"`,
   an x86 feature name, and on an arm64 target LLVM warns instead of
   answering false quietly. Something on the always-run path calls it.
   Fix direction: gate the x86 feature queries on the target ARCH first
   (`is_x86()` else False) so the feature-name check never reaches LLVM
   on Apple Silicon; find and note the prelude-path caller while there.

6. **Double-click does not select the word under the mouse.** Confirmed in
   the code: `mouseDown_` (gridview.mojo:608) never reads the event's
   `clickCount` -- every click places the caret, so a double (and triple)
   click is just two carets in a row. Fix: read `clickCount` off the
   NSEvent; 2 selects the word around `offset_at_point` (the completion
   code already knows word boundaries), 3 selects the line; drag after a
   double-click should extend by words, the way every Mac text view does.

7. **`class FernwindView(NSView):` gets an error squiggle; builds fine.**
   Same family as entry 3 -- the server is configured worse than the
   compiler -- but a different missing piece: the KB. `lsp.mojo`'s
   `start_with_environment` sets MODULAR_MOJO_MAX_IMPORT_PATH and nothing
   else, while `bin/cocoamojo` also exports MODULAR_MOJO_MAX_COCOAKB_PATH
   (share/cocoa.sqlite) before every build. A Finder-launched Roast.app
   inherits no shell environment at all, so the server elaborates `class`
   declarations with no Cocoa database, cannot resolve NSView, and marks
   the fork's own keyword as an error. Fix, together with entry 3: the
   server gets exactly the environment and import roots the wrapper gives
   the compiler -- one source of truth, not two configurations drifting.

8. **No auto-indent on Return.** A new line starts at column 0 regardless
   of the previous line's indentation (screenshot: `var l = 1` at col 0
   inside a nested block -- though the diagnostics caught the resulting
   indent error nicely). `insertNewline:` (gridview.mojo:2006) inserts a
   bare newline. Fix: carry the previous line's leading whitespace onto
   the new line, and add one level when the previous line ends with `:`
   -- the two rules that cover nearly all Mojo typing. Shift-Return can
   keep the bare newline for when the copied indent is unwanted.

9. **No autocomplete in the app.** The menu renders the key correctly
   (^Space, confirmed in testing) and invoking Complete does NOTHING
   visible -- menu route included, which rules out macOS swallowing the
   keystroke as the whole story. That strengthens the first suspect: the
   same starved server as entries 3/7. A Finder-launched app gives the
   LSP no KB and one import root, so the query returns nothing and an
   empty popup never opens -- from the chair, "nothing happened".
   (roastComplete_ would at least say "No language server" in the status
   bar if the server were down entirely; silence means it asked and got
   nothing back.) Fix 3/7 first, retest, and only then suspect the popup
   path.

10. **Feature: right-click context menu over the selection.** Nothing
    handles `rightMouseDown_`/`menuForEvent:` today, so a right click
    does nothing. The natural contents already exist as actions -- Cut,
    Copy, Paste, then Go to Definition, Find References, Rename, and
    Evaluate Selection when the debugger is stopped -- so the menu is
    wiring, not new features. If the click lands outside the current
    selection, select the word under the pointer first (entry 6's word
    machinery), the way every Mac editor does.

11. **Feature: visible progress while the compiler runs.** Mojo compiles
    are long enough that a static "Building..." reads as a hang. Put a
    spinner (NSProgressIndicator, small, indeterminate) beside the status
    text, shown while build.is_running() and hidden on finish -- the tick
    already knows both moments. Elapsed seconds appended to the status
    ("Building... 14s") costs one line more and answers the actual
    question, which is "is it still going". Applies to Build, Run's build
    half, and the debug build.

12. **Feature: Python examples in the Examples menu.** Thirteen shipped
    examples, none touching Python -- yet the app carries a whole
    relocatable CPython, a per-project venv system and a Python menu, all
    invisible until someone has a use in hand. Upstream sources exist to
    adapt: `mojo/examples/python-interop/` (hello_mojo, person_module,
    mandelbrot_mojo) -- and best of all `mojo/examples/life/lifev1.mojo`
    and `lifev2.mojo`: Conway rendered through PYGAME via
    `Python.import_module("pygame")`. Life-via-pygame beside the native
    `life` the app already ships makes the comparison the demo -- same
    program, Python windowing vs Cocoa -- and it exercises the whole venv
    flow, since pygame must pip-install into the project environment
    first. Ship it, plus one or two of the smaller ones, -- a minimal
    "call into Python, print what came back", and one that pip-installs
    a small package into the project venv and uses it, since the venv
    flow is the part nothing else demonstrates. Must run via cmd-R with
    the bundled CPython on a machine with no Python installed, which is
    the whole point of carrying one.
