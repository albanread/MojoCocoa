# READ ME FIRST — `Target/` sources were never committed

**Written from the M4 Max, 2026-08-23, against a fresh clone of this repo.**

If you are the machine the Apple Silicon port was actually done on: **do not
start new work, and do not `git clean`.** You are probably holding the only
copy of four files. Recovery procedure is in §3.

## 1. What is wrong

`.gitignore` line 69 is a bare `target/` — upstream's rule for the Rust build
directory. Git turns on `core.ignorecase` automatically on macOS, so that
pattern also matches `Target/`, and it silently swallowed every `Target/`
*source* directory in the tree. 21 tracked files are missing from this repo.

This is not only the AIR work. It includes upstream infrastructure the compiler
cannot build without — `TargetTraits`, `TargetLowering`, `TargetBackend` and the
whole `Host` backend. **As cloned, this repo does not compile.** The absence is
invisible in a normal `git status`, which is why it survived a push.

MojoMacX64 hit this exact bug and fixed it in commit `b8380ce`, *"CRITICAL:
un-ignore Target/ sources — the AIR trio was never committed"*. The squash that
created MojoCocoa reintroduced upstream's `.gitignore`, so we paid for it twice.

`STATUS.md` claims the AIR trio is "ported, not yet compiled". The porting was
real; the committing never happened. Treat that section as describing files that
exist **only on the machine that wrote them**.

## 2. The 21 files

Four of these are the Apple port and exist nowhere else. Seventeen are shared
with MojoMacX64 and can be restored from there at any time.

**Apple port — irreplaceable, recover from your working copy:**

    KGEN/lib/Target/Air/AirTraits.h
    KGEN/lib/Target/Air/AirTraits.cpp
    KGEN/lib/KGENToLLVM/Target/Air/AirLowering.cpp
    KGEN/lib/Compiler/ObjectCompiler/Target/Air/AirBackend.cpp

**Shared with MojoMacX64 — restorable, but restore yours if you have them:**

    KGEN/include/KGEN/Compiler/Target/TargetBackend.h
    KGEN/lib/Target/TargetTraits.h
    KGEN/lib/Target/TargetTraits.cpp
    KGEN/lib/Target/TargetLowering.h
    KGEN/lib/Target/TargetLowering.cpp
    KGEN/lib/Target/Host/HostTraits.h
    KGEN/lib/Target/Host/HostTraits.cpp
    KGEN/lib/KGENToLLVM/Target/Host/HostLowering.cpp
    KGEN/lib/Compiler/ObjectCompiler/Target/TargetBackend.cpp
    KGEN/lib/Compiler/ObjectCompiler/Target/Host/HostBackend.h
    KGEN/lib/Compiler/ObjectCompiler/Target/Host/HostBackend.cpp
    Support/lib/DebugInfoDialect/DebugInfoToLLVM/Target/TargetAdapter.h
    Support/lib/DebugInfoDialect/DebugInfoToLLVM/Target/TargetAdapter.cpp
    Support/lib/DebugInfoDialect/DebugInfoToLLVM/Target/AMDGPUAdapter.h
    Support/lib/DebugInfoDialect/DebugInfoToLLVM/Target/AMDGPUAdapter.cpp
    Support/lib/DebugInfoDialect/DebugInfoToLLVM/Target/NVPTXAdapter.h
    Support/lib/DebugInfoDialect/DebugInfoToLLVM/Target/NVPTXAdapter.cpp

Even for the seventeen, prefer your local copies — if the Cocoa port touched
`TargetTraits.h` to register the AIR target, MojoMacX64's copy will not have
that edit.

## 3. Recovery, on the machine that has the files

**Step 1 — confirm they are there.** This is the whole question:

```bash
ls KGEN/lib/Target/Air/ KGEN/lib/KGENToLLVM/Target/Air/ \
   KGEN/lib/Compiler/ObjectCompiler/Target/Air/
```

Three files named `AirTraits.*`, `AirLowering.cpp`, `AirBackend.cpp` means the
Apple port is alive. Nothing there — see §4.

**Step 2 — back them up outside the repo before touching anything.** A stray
`git clean -xdf` deletes ignored files, and right now these *are* ignored:

```bash
tar czf ~/mojococoa-target-rescue.tgz $(git status --porcelain --ignored | awk '$1=="!!"{print $2}' | grep -iE '/target/|/target$')
```

**Step 3 — fix the rule.** Anchor it so it means the Rust directory at the repo
root and nothing else:

```bash
perl -0pi -e 's{^target/$}{# was `target/` (Rust build dir) — case-insensitively swallowed\n# every KGEN .../Target/ source directory, including the whole AIR trio.\n/target/}m' .gitignore
```

Verify the pattern no longer bites:

```bash
git check-ignore -v KGEN/lib/Target/Air/AirTraits.h
```

Silence and exit status 1 is what you want. If it still prints a rule, that rule
is what needs anchoring.

**Step 4 — add, using `-f` so it works either way:**

```bash
git add .gitignore && git add -f KGEN/lib/Target KGEN/lib/KGENToLLVM/Target KGEN/lib/Compiler/ObjectCompiler/Target KGEN/include/KGEN/Compiler/Target Support/lib/DebugInfoDialect/DebugInfoToLLVM/Target
```

**Step 5 — check the count before committing.** Expect 21 files, or 22 with
`.gitignore`:

```bash
git diff --cached --name-only | tee /dev/stderr | wc -l
```

Fewer than 21 means some are genuinely absent — note which, and read §4 for
those. More is fine if the Cocoa port added files this note does not know about.

**Step 6 — commit and push.** Push before anything else; the risk is losing
these, not committing them imperfectly.

```bash
git commit -s -m "CRITICAL: un-ignore Target/ sources — the AIR trio was never committed" -m "Same bug MojoMacX64 fixed in b8380ce. Bare 'target/' matched 'Target/' under core.ignorecase on macOS, so 21 files including the Host backend and TargetTraits were never tracked. The repo did not compile as cloned." && git push
```

## 4. If the files are gone

Then the Apple AIR edits are lost and get redone from MojoMacX64's Vega
versions. Not a disaster — `STATUS.md` records what changed, precisely enough to
serve as the spec:

- `AirTraits` — arch list `apple-m1`..`apple-m5`, upstream's own names.
- `AirBackend` — profile read off a golden sample, not guessed:
  `air64_v28-apple-macosx26.0.0`, `air.version 2.8.0`, Metal 4.0.0, SDK 26.0.
- `AirBackend` — capture hoisting removed; it burned one of 31 buffer slots per
  captured pointer and only existed because AMD needs a bound resource.
  `deviceizeCapturedPointers` extended to cover the `extractvalue` case.
- Plus the two open `TODO`s, `air-indirect` and `air-residency`.

Restore the seventeen shared files from MojoMacX64 first — same fork point
(`577b6b839e`), so they drop in clean — then re-port the four.

## 5. What is *not* affected

The runtime half survived, because it does not sit under a `Target/` path.
These are tracked and present:

    AsyncRT/lib/MojoBindings/AppleGPURT.cpp
    AsyncRT/lib/MojoBindings/AppleGPUMetal.cpp
    AsyncRT/lib/MojoBindings/AppleGPUInternal.h
    AsyncRT/lib/MojoBindings/applegpu_metal_smoke.c

So is the Cocoa work, and so are the AIR-supporting edits to
`BitcodeWriter17.cpp`, `LLVMIRDowngradePass.cpp` and `PointerRewriter.cpp`. The
tree is AIR-ready everywhere except the `Target/` directories.

## 6. Environment note, unrelated to the bug

The Metal toolchain needed for golden-sample work is present on the M4 Max and
did not need installing: `metal` 32023.864 targeting `air64-apple-darwin25.5.0`,
with `metal-objdump`, `metal-nm`, `metal-ar`, `metallib` and `air-lld`. The
`AIR_APPLE_SILICON.md` §"Golden-sample technique" workflow runs as written.
