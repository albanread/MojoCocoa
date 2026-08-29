# Fix list

Notes from human testing, to be worked later. Newest at the bottom; each
entry gets a line of diagnosis when the cause is known, and moves to the
commit that fixes it when one does.

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

4. **Deprecated pointer arithmetic in a shipped example.**
   `fernwind/main.mojo:292` warns:

       warning: '__add__' is deprecated, use 'unsafe_offset' instead
           _ = Atomic.fetch_add(bacc + pat, cb)

   Same rule as entry 2 -- shipped examples build silently -- and same
   sweep should catch both: build every example and fix every warning,
   not just the two that testing happened to surface.
