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
