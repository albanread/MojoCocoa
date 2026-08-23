# Cocoa Mandelbrot

A native macOS app written entirely in Mojo — the Mac answer to the Windows
Direct3D mandelbrot. Every pixel is computed by a Mojo kernel on the GPU; the
frame is handed to a `CAMetalLayer` and presented at 60fps. No shader anywhere
in the pipeline.

On this machine the GPU is the **Apple M4** (10 cores), reached through the
Metal backend — `_accelerator_arch()` reports `metal:4`:

```
mojo build --target-accelerator=metal:4 -o mandel spikes/mandelbrot/mandelbrot.mojo
./mandel
```

It prints the CPU-vs-GPU timing, then opens a live-zooming window:

```
Mandelbrot 1024 x 768 , 256 iterations
  CPU: ... ms
  GPU: Apple M4 (Apple Metal)
  GPU: ... ms  ( ... x faster )
Rendering. Close the window to quit.
  frame 120 — 60.x fps
```

(Timings deliberately left blank — they have not been measured on this machine
yet. The x86-64 original on a Radeon Pro Vega II reported 149.8 ms CPU vs
0.40 ms GPU, a 374x speedup; the M4 is a different part and deserves its own
number rather than an inherited one.)

Nothing here uses a hand-rolled Objective-C binding. `NSApplication`,
`NSWindow`, `NSView`, `CAMetalLayer` and `CAMetalDrawable` are all driven
through `std.objc`, with every selector, dispatch stub, argument count and
register file checked at compile time against the SDK database — and the Metal
protocol objects (`id<MTLTexture>`, `id<MTLCommandQueue>`, …) through the
selector-keyed `std.objc.send`.

The pieces, each also a standalone spike:
- `window_smoke.mojo` — NSWindow + AppKit event loop from Mojo
- `compute_smoke.mojo` — CPU vs GPU mandelbrot, timed and cross-checked
- `mandelbrot.mojo` — the full app

## Porting note

This came from the x86-64 fork, where the GPU was an AMD Radeon Pro Vega II
driven by that fork's AIR backend and the target was `metal-vega2`. The Cocoa
and Metal code is unchanged: `DeviceContext(api="metal")` and the `CAMetalLayer`
path are identical on Apple Silicon. Only the accelerator target and the GPU's
name differ. See `COCOA_ARM64.md` at the repo root.
