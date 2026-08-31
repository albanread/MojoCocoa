# AIR performance oracles

`fma_peak_bench.mojo` measures the schedule produced for independent Float32
recurrence chains held in one thread. It is intentionally small enough to run
while changing the AIR backend and large enough that a synchronization round
trip does not dominate every sample.

Build and run it through the CocoaMojo distribution:

```bash
cocoamojo --build fma_peak_bench.mojo -o /tmp/fma_peak_bench
/tmp/fma_peak_bench
APPLEGPU_SYNC_LAUNCH=1 /tmp/fma_peak_bench
```

On an M4 Max, 30 August 2026, the asynchronous-default runtime reduced the
warm 32-dispatch sample from 12.44 to 8.64 ms at four chains, 15.10 to 11.04
ms at eight chains, and 22.20 to 16.61 ms at sixteen chains. Checksums were
identical in both modes. This is 1.44x, 1.37x, and 1.34x throughput,
respectively.

Command-buffer batching is intentionally visible here as a separate runtime
axis. Ten alternating runs were neutral at four and eight chains and roughly
1% faster at sixteen; these kernels are compute-bound once warm. The
35-dispatch fluid workload improves by about 12%, which confirms that batching
removes submission overhead rather than changing generated arithmetic.

The LLVM wide-vector scalarizer was tested both as float4 fragments
(`APPLEGPU_AIR_SCALARIZE_MIN_BITS=128`) and as scalars (`=32`). Neither
improved the stable width-4/8/16 results. Explicit SIMD widths 32 and 64 are a
separate capability failure on this M4 Max: metallib creation succeeds, but
pipeline-state creation terminates the Metal compiler connection with
`XPC_ERROR_CONNECTION_INTERRUPTED`, with scalarization on or off. Do not
enable the scalarizer by default on the strength of IR shape alone. Reduce the
width-32 PSO failure, then split wide per-thread values before the form that
causes Apple's compiler to fail.


## Re-measured at HEAD `fca4e767`, 30 August 2026

Both oracles were re-run after the AIR lowering merge and the residency-set
selector fix. They measure orthogonal axes, and the comparison shows it:

**FMA compute oracle — unchanged, as it should be.** Six passes, first
discarded as cold, median of the rest, M4 Max:

| chains | sync ms (prev → now) | async ms (prev → now) | async speedup (prev → now) |
|---|---|---|---|
| 4 | 12.44 → 12.40 | 8.64 → 8.60 | 1.44x → 1.44x |
| 8 | 15.10 → 15.20 | 11.04 → 10.92 | 1.37x → 1.39x |
| 16 | 22.20 → 22.63 | 16.61 → 16.30 | 1.34x → 1.39x |

Within ~2% of the baseline everywhere, and the checksums are bit-identical to
the recorded run. This oracle holds one output buffer and is compute-bound
once warm, so nothing in the latest changes moves it -- which is exactly why
it is a separate oracle from the residency bench. A change that altered the
generated arithmetic would show here as a different checksum or a different
warm time; neither moved.

**Residency bench — transformed by the selector fix.** The companion oracle,
`AsyncRT/lib/MojoBindings/applegpu_residency_bench`, measures the opposite
axis: per-dispatch cost against the number of live allocations. The residency
set had never actually activated (wrong factory selector; see
`AIR_EXPERIMENTS.md` item 6 and MojoCocoa `267766a4`), so before the fix both
its modes ran the same useResource walk and were identical. With the set
genuinely active, us/dispatch walk vs set, 9-pass medians: 6.66 -> 3.77 at 64
live buffers, 18.56 -> 3.46 at 256, 73.35 -> 3.25 at 1024, 289.53 -> 3.37 at
4096. Flat in the allocation count where the walk is linear.

Taken together: the latest AIR changes left the compute schedule exactly
where it was and fixed the dispatch path that had silently never run. The two
oracles are the reason that statement can be made with numbers rather than
asserted.
