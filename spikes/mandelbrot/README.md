# Mandelbrot smokes

The full windowed app lived here while it was a spike; it now ships as
`examples/mandelbrot/` — ported to the current patterns (`std.objc` geometry,
a `class` for the mouse and keyboard, flags between callback and frame loop)
the same way `life` and `fluid` were. Run it from there, or open the folder
in Roast and press ⌘R. On the M4 Max it reports the CPU-vs-GPU timing and
holds 60fps.

What stays here are the two smokes that prove the halves separately:

- `window_smoke.mojo` — NSWindow + AppKit event loop from Mojo
- `compute_smoke.mojo` — CPU vs GPU mandelbrot, timed and cross-checked

## Porting note

This came from the x86-64 fork, where the GPU was an AMD Radeon Pro Vega II
driven by that fork's AIR backend and the target was `metal-vega2`. The Cocoa
and Metal code is unchanged: `DeviceContext(api="metal")` and the `CAMetalLayer`
path are identical on Apple Silicon. Only the accelerator target and the GPU's
name differ. See `COCOA_ARM64.md` at the repo root.
