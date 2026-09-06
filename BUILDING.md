# Building MojoCocoa from a fresh clone

This is the whole sequence, in order, with what each step produces and how to
tell it worked. It exists because on 2026-09-06 the person who ported this
could not build it from the README, and every failure along the way was one a
newcomer would hit. Each of those failures is in the table at the end.

**The rule that prevents most of them: never type `bazel` by hand.**
`./tools/mojo-build.sh` is the only thing that should run it.

## Requirements

- Apple Silicon, macOS 15+, Xcode 16+ (`xcode-select -p` must point at Xcode,
  not just the command-line tools — the Metal toolchain lives in Xcode).
- `python3`, `git`, `sqlite3` (all on a stock Mac).
- ~60 GB free. The first compiler build is LLVM + MLIR from source.
- The sibling repository **CocoaBaseMCP**, cloned *beside* this one. The
  scripts default to `../CocoaBaseMCP`; `COCOAKB_SRC` overrides.

## 0. The SDK database — and keep it current

```bash
git clone https://github.com/albanread/CocoaBaseMCP.git ../CocoaBaseMCP
python3 ../CocoaBaseMCP/build.py          # ~12s, reads the live SDK on this machine
```

Produces `../CocoaBaseMCP/cocoa.sqlite` (~240 MB). The compiler reads it during
elaboration; that is how it checks a struct layout or a selector against the
SDK instead of being told.

**The compiler's queries and this database's schema move together, in two
different repositories.** A checkout older than the compiler produces a database
missing tables the compiler asks for. `make-dist` now warns if the checkout is
behind origin, and the compiler now refuses a database missing any table it
queries — but the habit is: `git -C ../CocoaBaseMCP pull` before you build.
Rebuild the database after a macOS update, too.

## 1. `local.bazelrc`

Create this file at the repo root. It is gitignored, and it is not optional:

```
build --config=build-mojo
build --action_env=MODULAR_MOJO_MAX_COCOAKB_PATH=/ABSOLUTE/PATH/TO/CocoaBaseMCP/cocoa.sqlite
build --sandbox_add_mount_pair=/ABSOLUTE/PATH/TO/CocoaBaseMCP
```

The path must be absolute — it is read inside bazel's sandbox, where `~` and
relative paths mean nothing. `--action_env` is how the database reaches the
compiler *during a bazel build*; after `make-dist` it is bundled and no
environment variable is needed.

Do not change these lines casually once set. The environment is part of every
action's cache key, so editing this file rebuilds LLVM (~45 minutes).

## 2. The compiler

```bash
./tools/mojo-build.sh                     # everything make-dist needs
```

First time: **~45 minutes** (LLVM + MLIR + the compiler, ~10,000 actions).
After that, source changes are incremental — a one-file change is seconds to a
few minutes.

What it runs, and why you must not run it yourself:

```
./bazelw build --config=build-mojo --config=release <targets>
```

`--config=release` builds the *opt* tree, tunes for the M4, and — the part
that matters — compiles LLVM and MLIR with default symbol visibility so they
can be linked as shared libraries. Without it you get the *dbg* tree, whose
`libMLIR.dylib` exports 192 symbols instead of 37,000 and **cannot link**.
The failure looks like this and has nothing to do with your change:

```
ld64.lld: error: undefined symbol: llvm::raw_ostream::write(char const*, unsigned long)
ld64.lld: error: undefined symbol: llvm::errs()
```

Groups, if you want less than everything:

```bash
./tools/mojo-build.sh compiler     # just the compiler binary
./tools/mojo-build.sh libs         # libLLVM, libMLIR, libMojoCompiler
./tools/mojo-build.sh runtime      # the three dylibs make-dist ships beside the compiler
./tools/mojo-build.sh debugger     # lldb, lldb-dap, the MojoLLDB plugin
./tools/mojo-build.sh //some:target
```

Success looks like `INFO: Build completed successfully, N total actions`, and
`bazel-bin` now points into `bazel-out/darwin_arm64-opt/`.

## 3. The distribution — after which bazel is not needed

```bash
NO_IDE=1 ./tools/make-dist.sh             # a minute or two
```

Produces `dist/CocoaMojo/` (~1.1 GB): the compiler as `bin/cocoamojo-compiler`,
the `cocoamojo` driver, the runtime dylibs, `libLLVM`/`libMLIR`, the stdlib and
`gamepane` packages, a relocatable Python, and a **freshly regenerated**
`share/cocoa.sqlite`. From here on, `cocoamojo --run` and `--build` are the
whole interface — no bazel, no environment variables.

`NO_IDE=1` skips building the Roast IDE, which needs more and is not required to
compile or run Mojo. Omit it only when you want the IDE.

`make-dist` runs a preflight first and refuses with a reason if the compiler is
from the wrong tree, a runtime dylib is missing, or CocoaBaseMCP is behind
origin. Each of those is a real failure someone hit; read the message, it says
what to run.

If a Roast IDE is *running* from `dist/CocoaMojo`, do not overwrite it under
it: `DIST_DIR=/tmp/mine ./tools/make-dist.sh`.

## 4. Verify

```bash
COCOAMOJO=dist/CocoaMojo/bin/cocoamojo ./spikes/run-cocoa-checks.sh
```

Runs every Cocoa verification spike: the ones that must compile and run, one
that must agree with clang about the C ABI, and the ones that must be
**rejected** at compile time with a Cocoa diagnostic (a segfault or a runtime
`raise` counts as a failure there, not a pass). The last line is
`N passed, M failed`; **M must be 0**. The script prints the real count; do not
trust a number quoted in a document over the number it prints.

Then the rest, as needed:

```bash
./tools/check-examples.sh      # builds and launches every example, holds the msg_send ratchet at 0
./tools/check-gamepane.sh      # renders a frame and asserts it is not black
./tools/check-ide.sh
./tools/check-dist.sh
```

There is no CI. Every number in `STATUS.md` was produced by someone running
these by hand on one machine, on the date beside it.

## 5. Use it

```bash
dist/CocoaMojo/bin/cocoamojo --run  examples/life/main.mojo
dist/CocoaMojo/bin/cocoamojo --build examples/life/main.mojo -o life
```

## Verifying a Mojo change without bazel at all

If you are changing `gamepane/`, `examples/` or `ide/` — not the compiler — you
do not need step 2 at all. Copy an existing distribution, overlay your sources,
build against the copy:

```bash
cp -R /Applications/Roast/CocoaMojo/<date> /tmp/mine          # or dist/CocoaMojo
rsync -a --exclude='tests/' --include='*/' --include='*.mojo' --exclude='*' \
      gamepane/ /tmp/mine/lib/mojo/gamepane/gamepane/
/tmp/mine/bin/cocoamojo --build gamepane/tests/test_audio.mojo -o /tmp/t && /tmp/t
```

Seconds, not minutes. This is also the fastest way to tell "my change broke it"
from "the data is stale": run the failing test against the installed toolchain,
which bundles its own database. If it passes there, suspect the database.

## When it goes wrong

| you see | it means | do |
|---|---|---|
| `undefined symbol: llvm::errs()` … at link | built without `--config=release` (the dbg tree) | `./tools/mojo-build.sh`, never `./bazelw build` by hand |
| `make-dist`: `cp: …libKGENCompilerRTShared.dylib: No such file` | runtime dylibs not built (pre-2026-09-06 `mojo-build.sh all` omitted them) | `./tools/mojo-build.sh runtime`, then `make-dist` again |
| `make-dist`: "bazel-bin points at … not the release (opt) tree" | last bazel run was a hand-typed dbg build | `./tools/mojo-build.sh` |
| spikes fail with `does not implement '__add__'` or `has no attribute 'origin'` on a `cocoakb_query` type | **the database is older than the compiler** — a query hit a missing table, the compiler folded the error into an unresolved conditional type | `git -C ../CocoaBaseMCP pull && python3 ../CocoaBaseMCP/build.py`, then `make-dist` |
| `the Cocoa metadata database at '…' is missing: method_ret_kind` | same thing, caught at open (the compiler now checks) | same |
| `cannot open the Cocoa metadata database` / `no Cocoa metadata database is configured` | `local.bazelrc` path wrong or relative | step 1; the path must be absolute |
| `run-cocoa-checks`: "no distribution at dist/CocoaMojo/bin/cocoamojo" | you skipped step 3 | `NO_IDE=1 ./tools/make-dist.sh` |
| `cocoamojo-compiler` aborts, `libLLVM.dylib (no such file)` | `make-dist` died partway and left a half-built dist | fix the preflight failure it printed, rerun `make-dist` |
| a full ~45 min rebuild you did not expect | you edited `local.bazelrc` or the sysroot list | it is the cache key; batch such edits, and read `STATUS.md` "Build discipline" |
| every GPU program fails with `AIR legalization failed: no Apple AIR target profile for arch ''` | a compiler between 15694245 and its fix (D21): the arch was stripped before legalization read it | `git pull`, `./tools/mojo-build.sh`, `make-dist`; and after ANY compiler change run `check-examples.sh` and `check-gamepane.sh`, not just the program you were fixing |
| GPU tests report `FAILED TO BUILD` for binaries that built; log says `Resource gpu-memory is not being tracked` | bazel was invoked without going through `tools/bazel`, so `build/local-resources.bazelrc` was never generated and every GPU test is unschedulable, not broken (it mislabelled 218 targets on a sister port) | always go through `./tools/mojo-build.sh` or `./bazelw` -- both use the wrapper. To repair by hand: `bazel/internal/detect_local_resources.sh > build/local-resources.bazelrc`. See `oracles/findings/build-traps.md` |

## How long things take (Apple M4, 24 GB)

| step | first time | after |
|---|---|---|
| `build.py` (database) | 12 s | 12 s |
| `mojo-build.sh` (compiler) | ~45 min | seconds–minutes |
| `make-dist.sh` | 1–2 min | 1–2 min |
| `run-cocoa-checks.sh` | ~5 min | ~5 min |
