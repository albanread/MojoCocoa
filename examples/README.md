# Examples

Each folder here is a project: a folder with a `main.mojo` in it. Open one in
Roast (File ▸ Open Folder…) and press ⌘R. Output appears in the console pane,
which opens itself when a build starts and toggles with ⌘0.

    hello/        the smallest thing that runs — one file
    fern/         Barnsley's fern, saved as a png — three files, so a
                  project with more than one file in it
    window/       a Cocoa window with a button, in Mojo
    mandelbrot/   the GPU, via Metal, checked against the CPU

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

`mandelbrot/` needs a GPU, and checks the Metal result against the same
arithmetic on the CPU rather than trusting it.
