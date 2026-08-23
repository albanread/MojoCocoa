# Cocoa on Apple Silicon — porting the MacVegaFork design to arm64

This tree carries the `cocoakb_query` compiler hook and the `std.objc` /
`std.sys._cocoakb` layers from [MojoMacX64](https://github.com/albanread/MojoMacX64),
retargeted from x86-64 SysV to **arm64 / AAPCS64**. The design is unchanged —
see `COCOA_DESIGN.md` in that fork. This file records only what differs here,
and why.

## What did not change

The mechanism, the query names, and the Mojo API are identical. A binding still
states a **name** and the compiler still supplies and checks everything else
from `cocoa.sqlite` during elaboration:

- one comptime param-expr, `#kgen.param.expr<cocoakb_query, "<query>", ...>`
- the same 16 queries + `db_hash`
- the same failure discipline: an unknown class, selector, struct or field is a
  **compile error at the asking source location**, never a wrong answer
- inheritance still resolved in SQL by recursive CTE, not in Mojo

Verified on this machine: `NSMutableString`/`length` resolves to `NSString`,
`Q16@0:8`; `CGRect` is 32/8 with `origin@0`, `size@16`.

## What changed, and why

**The ABI tables.** `CocoaBaseMCP` already derives both architectures —
`method_abi` / `posix_function_abi` are AAPCS64, `method_abi_x64` /
`posix_function_abi_x64` are SysV. The port is a retarget, not a rewrite: the
six ABI queries now read the AAPCS64 tables.

**`msgsend_variant` is a constant here.** arm64 has exactly one send. Probed on
this machine's libobjc:

| symbol | arm64 |
|---|---|
| `objc_msgSend` | present |
| `objc_msgSendSuper`, `objc_msgSendSuper2` | present |
| `objc_msgSend_stret` | **absent** |
| `objc_msgSend_fpret` | **absent** |

An aggregate return travels in `x0`-`x1`, in `v0`-`v3` when it is a homogeneous
float aggregate, or through the `x8` indirect-result register — all via the
ordinary send. So the query answers `objc_msgSend` for every modelable method.

It is **kept rather than deleted** because its second job survives: a signature
the ABI pass could not model still answers `'?'`, and a call through such a
method still fails to build (design decision D4). Only the answer for the
modelable case got simpler. The x86-64 DB has 3,881 `_stret` methods and 2
`_fpret`; on arm64 those are free.

**The token vocabulary differs, so `_nth_class_kind` was rewritten.** SysV
classifies per eightbyte (`f`, `ff`, `gf`…), so "every byte is `f`" means the
SSE file. AAPCS64 uses `g` / `f` / `h2`..`h4` (HFA) / `i1`,`i2` / `b` / `s` /
`v`. A `CGRect` argument is `h4` — the float file — and the SysV test would have
put it in the integer file. The arm64 reading: `f` alone, or anything starting
`h`, is the `v` register file.

**Not ported at Cocoa time:** the `KGEN/BUILD.bazel` glob for
`lib/Compiler/ObjectCompiler/LLVM/Bitcode/17/*.h`, since it belonged to the
fork's `AirBackend` rather than the Cocoa work. It has since been restored --
the AIR backend needs it for LLVM-17 bitcode encoding. See
`AIR_APPLE_SILICON.md`.

## The database

Built from the **live** runtime and SDK on this machine (`build.py`, 12.3s):

| table | rows |
|---|---|
| `rt_classes` | 28,814 |
| `rt_methods` | 522,170 |
| `method_abi` (AAPCS64) | 522,170 |
| `structs` / `struct_fields` | 2,403 / 16,766 |
| `bs_enums` / `bs_constants` | 48,775 / 12,892 |
| `posix_functions` / `posix_function_abi` | 299 / 299 |

Rebuild it after any macOS update; `cocoakb_query<"db_hash">` makes drift
visible. Point the compiler at it with:

    export MODULAR_MOJO_MAX_COCOAKB_PATH="$PWD/../CocoaBaseMCP/cocoa.sqlite"

Opened read-only, once per process, mutex-guarded, and **never created if
missing** — a missing database is a configuration error, not an empty one that
answers wrongly.

## Examples and spikes

`spikes/s5-cocoakb/` — `check.mojo` and `stret_test.mojo` carry arm64
expectations (`h4` where the x86-64 fork expects `s`/`_stret`); the rest are
architecture-neutral and were copied verbatim. `stret_test.mojo` keeps its
filename to stay diffable against the sister fork, though there is no stret
here.

`spikes/mandelbrot/`, `spikes/life/`, `spikes/playground/` — the Cocoa apps.
All three drive AppKit entirely through `std.objc` and render through a
`CAMetalLayer`, which is the same path on both architectures. What changed:

| was (x86-64 fork) | is (here) |
|---|---|
| `--target-accelerator=metal-vega2` | `--target-accelerator=metal:4` |
| `MOJO_BIN = /Volumes/S/mojo/vega-sdk/bin/mojo` | `bazel-bin/KGEN/mojo` |
| "Radeon Pro Vega II" in titles and menus | "Apple M4" / "the GPU" |

`life.mojo` and `playground.mojo` needed nothing else; `mandelbrot.mojo` only
its header comment and window title. `toolchain-build-run.sh` was **not**
copied — it builds an x86_64 LLVM into `/Volumes/S` for the sister fork's
hand-rolled toolchain, which Bazel does for us here.

Not yet run: none of these has been executed on this machine, because the
compiler is still building. The mandelbrot README carries no M4 timings for
that reason.
