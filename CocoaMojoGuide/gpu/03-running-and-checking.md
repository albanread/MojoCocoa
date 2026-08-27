# 3. Running and checking

## Running: JIT or build

From a CocoaMojo distribution:

```bash
cocoamojo --run   prog.mojo        # JIT, straight into this process
cocoamojo --build prog.mojo        # -> ./prog, a normal binary
cocoamojo --build prog.mojo -o app # -> ./app
```

**Both paths run GPU kernels.** `cocoamojo` is the whole interface: no `-I`
flags, no `MODULAR_*` environment variables, no Bazel. The distribution ships
the compiler, the Mojo runtime, the Metal device runtime
(`libCocoaMojoGPU`), the packages and `cocoa.sqlite` beside one another, and
the driver points the compiler at them. Binaries from `--build` carry an rpath
to `lib/`, so they run anywhere on the machine without a wrapper.

### A correction worth knowing

Earlier versions of this fork's documentation — including earlier versions of
this guide — said that GPU code could not be JIT-run, because "the JIT cannot
resolve the GPU runtime's symbols". **That was wrong**, and the mistake is
worth understanding because it is a common shape.

The JIT was never the problem. `ExecutionEngineOptions::libraryPaths` feeds an
ORC dynamic-library search generator, and `-Xlinker -L`/`-l` reach it. The
symbols were missing for the same reason so many things here were missing:
nothing exported them. Once the device runtime existed as
`libCocoaMojoGPU.dylib` rather than a hidden-visibility archive, the JIT
resolved them like any other library and ran GPU kernels immediately:

```text
GPU: 0.413 ms   speedup: 197.96 x
exact agreement: 100.0 % ( 0 boundary-band pixels differ)
COMPUTE-SMOKE: PASS
```

All sixteen spike checks now pass through the JIT path.

The lesson generalises: *"the JIT cannot do X"* is almost always *"nothing
exported the symbol X needs"*, and the two have very different fixes.

### One reason to prefer a subprocess anyway

The argument for building and exec'ing does survive, in one specific form.
JIT'd code runs in the **host process's address space**. A segfault is caught
by `CrashRecoveryContext`, but a call to `exit()` is not, and it would take the
host down with it.

That matters if you are embedding the compiler in something long-lived — an
editor, say. For running your own programs from a shell it is irrelevant.

## Building against the source tree

If you are working in the repository rather than from a distribution, you drive
the compiler directly and supply what `cocoamojo` would have supplied:

```bash
mojo build --target-accelerator apple-m4 \
  -I mojo/stdlib -I max/kernels/src -I max/mojo \
  -o /tmp/prog prog.mojo
```

### `--target-accelerator` is required

Through Bazel the toolchain supplies it. Compiling directly you must pass it
yourself, or comptime GPU dispatch fails with *"Unknown GPU architecture"*.

### Clear the kernel cache when a change seems not to take

Compiled kernels are cached, so a rebuilt compiler can still hand you
yesterday's answer. When an edit appears to do nothing, suspect this first:

```bash
./clear_cache.sh
```

`./rebuild.sh` does it as part of a rebuild, and can assert that a marker
string is genuinely present in the binary you are about to run — so "did it
actually rebuild?" has an answer that is evidence rather than hope.

One Bazel trap worth knowing: **Bazel does not forward your shell environment
into compile actions**, so exporting a variable does nothing. Use
`--action_env=FOO=1`, which forwards it *and* changes the action key so the
action re-runs — at the cost of invalidating the whole graph, so expect a full
rebuild each way.

## Timing

Warm up first. The first dispatch pays for pipeline creation and first-touch
residency, and including it will make your kernel look several times slower
than it is.

```mojo
    # warm
    ctx.enqueue_function(f, ...); ctx.synchronize()

    var t0 = perf_counter_ns()
    ctx.enqueue_function(f, ...); ctx.synchronize()
    var t1 = perf_counter_ns()
```

`synchronize()` before reading the clock, or you are timing the enqueue rather
than the work.

Launch is synchronous by default. Setting `APPLEGPU_ASYNC_LAUNCH=1` defers the
wait to `synchronize()`, which is worth about +29% on a single-chain FMA kernel
and +2.9% at 64 chains — most valuable when you are launch-bound and nearly
irrelevant when you are not.

## Checking the answer

This deserves more care than it usually gets, because the obvious check is the
wrong one.

Comparing every GPU value to every CPU value for exact equality will fail on
correct code. The GPU contracts a multiply and an add into a single fused
operation; the CPU does them separately, rounding in between. For most data the
results are identical, but wherever the computation is iteration-sensitive the
two can diverge.

The Mandelbrot spike says it plainly:

> CPU and GPU agree exactly on interior and exterior pixels. In the thin
> chaotic band right at the set boundary, a point is so iteration-sensitive
> that the GPU's fused multiply-add (vs the CPU's separate mul/add) can shift
> its escape count — inherent to Float32 mandelbrot, not a bug.

So it measures an **agreement rate** and requires it to be very high:

```mojo
    var rate = Float64(agree) / Float64(checked) * 100.0
    print("PASS" if rate > 99.0 else "FAIL")
```

The general rule is to **classify differences before claiming victory or
defeat**:

| Difference | Verdict |
|:---|:---|
| Boundary of a chaotic region, tiny population | arithmetic — expected |
| Last-bit differences in float output | contraction — expected |
| Smooth, low-iteration region | codegen bug |
| Large, structured, or in a flat area | codegen bug |
| Exactly one block's worth of values wrong | a bounds check or an index |
| Everything past a certain index wrong | grid too small, or a missing `if i < n` |

A picture that looks right is not evidence. A picture that survives a
classification filter is.

## Debugging

The runtime reads a set of environment variables, and the two you will reach
for first are:

| Variable | Use |
|:---|:---|
| `APPLEGPU_TRACE_LAUNCH` | Trace each dispatch — confirms the launch happened and with what dimensions |
| `APPLEGPU_TRACE_CAPS` | Report the device capabilities resolved at context creation |

`APPLEGPU_KEEP_AIR` keeps the intermediate GPU module for inspection, and
`APPLEGPU_TRACE_BLOB`, `APPLEGPU_TRACE_PROFILE` and `APPLEGPU_AIR_TRACE_KNOBS`
cover capture blobs, timing and which knobs are in effect.

Metal's own validation is worth enabling during bring-up: this fork's dispatch
path passes with Metal debug and shader validation on, and a residency mistake
that is silent otherwise becomes an error there.

## What this hardware supports

The reference machine is an **M4 Max**, and one distinction shapes what runs.

Apple's 16×16 `simdgroup_matrix` operations — the tensor-core-class matrix
paths — require `MTLGPUFamilyApple10`, which **M5 is the first part to
advertise**. On an M4 those kernels compile, and the module loads, and the
driver then declines the pipeline with *"supported by GPUFamily10 and later"*.

You will meet this as a runtime error mentioning Apple M5, not as a compile
failure, because everything up to pipeline creation succeeds. Guards in the
kernel library are spelled `compute_capability() != 5`, and this fork answers
that question by asking Metal for the family rather than trusting a marketing
name.

The 8×8 matrix path does work here.

## An honest word on maturity

The GPU support is a **working vertical slice**, not a finished backend. A
Mandelbrot runs and agrees with the CPU; 96 of 119 in-scope GPU tests pass; the
failures are triaged and named. The open work is mostly numerical correctness
in specific kernels, plus the M5 surface that cannot be exercised on this
machine at all.

Two consequences for you. Ordinary kernels of the shape in this section — index,
guard, compute, store — are well-travelled ground. The further you go towards
the kernel library's specialised paths, the more likely you are to meet
something that has not been validated here yet, and the more the advice is to
verify numerically against a CPU reference rather than to assume.
