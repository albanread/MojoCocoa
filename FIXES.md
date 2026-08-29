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
