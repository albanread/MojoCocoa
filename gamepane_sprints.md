# MacGamePane in Mojo — sprints

Execution order for [`gamepane_design.md`](gamepane_design.md). Each sprint
carries its own verification; nothing lands without the checks it names.
Numbering is G0–G10 so it cannot collide with the P-series
(`cocoa_improvement_sprints.md`) or the D-series (`debugger_improvements.md`).

Sizes as elsewhere in this tree: **S** is a sitting, **M** is a day or two,
**L** is a week with things learned along the way.

**Ordering.** G0 is the gate for the whole graphics chain: it proves the one
thing no Mojo program has done yet (a render pipeline) and lands the two
runtime accessors everything after it uses. G1 does not need G0 and can run
beside it. G2–G6 want G0 and are otherwise independent of each other, so
two pairs of hands can split them. **G7 and G8 need no Metal at all** — the
audio half is CPU code plus one AudioUnit, and the chip already exists — so
they can start on day one and run the whole way in parallel. G9 wants
everything before it. G10 is what the rest is for.

The Rust's 98 tests are the checklist. Each sprint lists the ones it makes
pass, by the Rust's own test names, so coverage is auditable against the
source rather than asserted.

---

## Sprint G0 — the render-pipeline spike, and the runtime accessors (DONE, size M)

**Goal.** Establish, before a single layer is written, that Mojo can compile
an MSL fragment shader, build a render pipeline, draw into a texture and
read the pixel back — and that a buffer a Mojo kernel wrote can be sampled
by that pipeline through a texture view. If this sprint passes, every layer
is a port of known code. If it does not, §6 of the design names the fallback
and the decision is made here, not discovered in G3. (It passed; the
fallback is not taken.)

**Pieces.**

1. **Two accessors in the fork's own runtime.**
   `AsyncRT_DeviceContext_metalDevice(ctx)` returns `AGMetalCtx.device`;
   `AsyncRT_DeviceBuffer_metalBuffer(buf, &offset)` returns
   `AGMetalBuf.buffer` and its view offset. Same shape as
   `AsyncRT_DeviceContext_deviceName` (`AppleGPURT.cpp:243`). Mojo wrappers
   `metal_device()` and `metal_buffer(buf)` in `gamepane/metal/device.mojo`.
   Rebuild the runtime dylib; the compiler binary is untouched.
2. **One shader, one triangle, one pixel.** The Rust's own first test:
   compile a solid-colour `fmain` through `newLibraryWithSource:options:error:`,
   build the pipeline with a typed `MTLRenderPipelineDescriptor` and a
   `send` for `newRenderPipelineStateWithDescriptor:error:`, draw the
   full-screen triangle into a 4×4 `BGRA8Unorm` texture, `getBytes:` it
   back, assert the colour. Also the negative: a source with no `fmain`
   fails with an error that names it.
3. **Every struct-by-value send the compositor will use, once.**
   `MTLClearColor` (four doubles) on the pass descriptor; two `MTLSize`s in
   `dispatchThreadgroups:threadsPerThreadgroup:`; `MTLRegion` in
   `getBytes:bytesPerRow:fromRegion:mipmapLevel:`. `mandelbrot` proved
   `MTLRegion` on the stack; the other two are new and are checked by the
   pixel readback being right.
4. **Device identity.** The accessor's device and
   `MTLCreateSystemDefaultDevice()` are the same pointer on this Mac. Assert
   it; record the result, because the fallback path depends on it.
5. **One memory, three readers, proven.** A `DeviceBuffer` from the runtime,
   a linear `R8Uint` texture view over it via
   `newTextureWithDescriptor:offset:bytesPerRow:` with the stride rounded to
   `minimumLinearTextureAlignmentForPixelFormat:`, a Mojo kernel that writes
   index `7` at `(1, 1)`, a palette buffer, the indexed-pane fragment shader
   (ported verbatim), a render, a readback: pixel `(1, 1)` is palette entry
   7 and pixel `(0, 0)` was discarded.

**Status (2026-09-05): all five pieces pass.** `./tools/check-gamepane.sh`
runs them.

Passing, in `gamepane/tests/`:

- `spike_pipeline.mojo` — MSL compiles, a pipeline builds, a draw into a 4x4
  texture reads back rgba(0.25, 0.50, 0.75) as B=191 G=128 R=64 A=255.
  `MTLClearColor` (four doubles) and `MTLRegion` (48 bytes) both cross by
  value. A CPU byte store into a Shared buffer reaches the indexed shader
  through a linear texture view, and index 0 discards. Alignment for R8Uint
  is 16 here, so a 4-wide plane has a 16-byte row — the stride rule is real.
- `spike_device.mojo` — the layers' device and the runtime's are the SAME
  object. `AsyncRT_DeviceContext_metal_device` already existed; no runtime
  change was needed to ask.

- `spike_shared.mojo` — a Mojo KERNEL's write, read by the fragment shader
  through a linear texture view over the same allocation. `hostPtr` and the
  MTLBuffer's `contents` are the same address; pixel (3,3) comes back as the
  palette entry the kernel indexed and (0,0) stays transparent. **This is the
  design's "one memory, three readers" (§4.3), demonstrated.**

The accessor landed: `AppleGPUMetal_mtlBuffer` plus
`AsyncRT_DeviceBuffer_metal_buffer` / `_metal_offset`, built into
`libCocoaMojoGPU.dylib` by `tools/make-gpu-runtime.sh`.

**Two bugs cost most of this sprint, and neither was where it looked.**

1. *A three-argument Mojo call to a two-parameter C function.* The offset
   was split into its own `_metal_offset` entry point in the C, and the
   Mojo call site was never updated — so the handle landed in `x2` and the
   `buffer` parameter held the offset slot's data pointer, which the C then
   read as a `DeviceBuffer`. It found a plausible non-null `mtl` in that
   list's storage and crashed locking the mutex of a context that had never
   been a context.
2. *A borrow outliving its owner.* The returned `id<MTLBuffer>` is not
   retained; it lives as long as the `DeviceBuffer` that owns it. Mojo
   destroys a value at its **last use**, not at the end of the scope, so
   `plane` died at the `plane._handle` that fetched the handle, and every
   message to the buffer after that went to freed memory. `_ = plane` after
   the last use of the view is the fix, and the accessor now says so.

Both were masked by a third thing worth knowing: **under `cocoamojo run`,
buffered stdout is lost on a crash, and `flush=True` does not save it.** The
bisect prints all vanished, which made the crash look like it happened
several statements earlier than it did. `cocoamojo build` to a binary and
run that — the same crash then prints every line first.

**Done when** all five pieces pass as a headless test, with the output
printed and the accessor patch committed separately from the spike. They
do, so the §6 fallback — index planes made through `send` and a CPU blitter
— is not taken, and G4's kernels are real kernels.

**Rust tests covered.** `a_trivial_solid_color_shader_compiles_and_renders_one_frame`,
`a_shader_missing_fmain_fails_to_compile_with_a_clear_error`,
`stride_is_the_width_rounded_up_to_the_devices_alignment`.

---

## Sprint G1 — window, loop, input (DONE, size S)

**Goal.** A `GamePane` that opens, pumps events, presents a cleared frame,
and knows what the keyboard, mouse and a gamepad are doing. Independent of
G0: the frame it presents is a `Clear` and nothing else.

**Pieces.**

1. `gamepane/metal/window.mojo`: `Obj["NSWindow"](contentRect=…,
   styleMask=…, backing=…, defer=False)`, a `CAMetalLayer` on the runtime's
   device (or the system default until G0 lands), `setReleasedWhenClosed(False)`
   — the `chip` review found what happens without it — and the pump:
   drain `nextEventMatchingMask:` until nil, `sendEvent:` each, `isVisible`
   ends the loop. `pump()`, `present()`, `dt()`, and `run(tick)` over them.
2. `class GameView(NSView)` with `acceptsFirstResponder`,
   `acceptsFirstMouse_`, `keyDown_`/`keyUp_`, `mouseDown_`/`mouseUp_`/
   `mouseDragged_`, `rightMouseDown_`/`rightMouseUp_`/`rightMouseDragged_`.
   State in `named_global`s: 128 held flags, mouse x/y normalised and
   y-flipped through `convertPoint:fromView:` + `bounds`, two buttons.
   `key_held(code)`, `mouse_state()`, `clear_all()`. The Rust's key codes
   (`KEY_LEFT` 123 … `KEY_SPACE` 49) as constants.
3. Gamepad: `load_framework["GameController"]`,
   `ObjCClass.lookup["GCController"]`, `send` for `controllers` →
   `extendedGamepad` → `buttonA`/`buttonB` `isPressed`, `leftThumbstick`
   `xAxis`/`yAxis`. First connected, or none.
4. **The database learns GameController.** One line in
   `share/cocoakb/build.py`'s framework list; rebuild `cocoa.sqlite`; then
   piece 3 moves to the typed surface. Separate commit.
5. The harness idiom: `GAMEPANE_FRAMES=N` renders N frames as an unfocused
   Accessory and exits; `GAMEPANE_DUMP=path` writes the last frame as raw
   BGRA. Copied from `ferns`, where it already works.

**Done when** `GAMEPANE_FRAMES=30 GAMEPANE_DUMP=/tmp/f.bgra` produces a
480×320×4-byte file of black, the window opens and closes cleanly by its red
button under a human, and the storage-level input tests pass.

**Rust tests covered.** `key_held_defaults_to_false_and_is_out_of_range_safe`,
`key_down_then_up_imps_toggle_held_state`, `clear_all_releases_every_held_key`,
`mouse_state_defaults_to_released`, `clear_all_releases_stuck_mouse_buttons`,
`mouse_position_round_trips_normalized_and_top_left`,
`gamepad_first_connected_is_none_or_valid_without_crashing`.

**Status.** Done. `gamepane/tests/test_window.mojo` passes headless:
`GAMEPANE_FRAMES=30 GAMEPANE_DUMP=…` presents thirty frames through a real
`CAMetalLayer` drawable and writes 480×320×4 = 614400 bytes in which every
pixel is BGRA 23 13 13 255 — `round(CLEAR_* × 255)` for the ground colour,
which also proves the drawable is `BGRA8Unorm` and not its sRGB twin (that
would encode these to 63 and 83). Piece 4 landed with the rest rather than
separately: `GameController` and `Metal` joined the framework list in the
database generator's `ingest_runtime.py`, and `GCController`,
`GCExtendedGamepad` and `GCControllerDirectionPad` are now real rows, so
piece 3 is on the typed surface from the start.

Two things the sprint did not anticipate:

- **The package needed a home.** `bin/cocoamojo` carried a fixed
  `-I` list of stdlib/max/kernels, so `import gamepane` could not resolve
  whatever the file layout was. `gamepane` is now a fourth package on the
  same footing — `lib/mojo/gamepane` is the container the driver puts on
  `-I`, `gamepane/` inside it is the package, exactly as `lib/mojo/max`
  holds `max/` — synced by `tools/sync-dist-sources.sh` for a release and
  by `tools/gp.sh` for development.
- **`f.write(String)` is not how you write a frame.** The dump went through
  a `StringSlice(unsafe_from_utf8=…)`, which claims bytes are UTF-8 that
  are not; reading it back raised *Cannot construct a String from invalid
  UTF-8 data*. `write_bytes`/`read_bytes` on both sides.

---

## Sprint G2 — the shader pane and the direct pane (DONE, size S, wants G0)

**Goal.** Layer 0 and the framebuffer-you-write-yourself — the two layers
with no drawing API of their own, so they are the smallest.

**Pieces.**

1. `ShaderPane`: the Rust `HEADER` verbatim, the user's `fmain` appended,
   `Uniforms{time, aspect, p[8]}` at buffer 0, `Clear` to black, `time` from
   `perf_counter_ns` since creation, `set_param(i, v)` bounds-checked,
   `set_aspect`.
2. `DirectPane`: three `DeviceBuffer`s with texture views, `stride()`
   public, `backbuffer_ptr()` and `buffer_ptrs()` (the whole rotation, for a
   writer that counts frames itself), `buffer_len()`, a 256-entry `float4`
   palette, `render` draws the current buffer then advances. Zeroed at
   creation so a first frame is a colour.

**Done when** the starfield shader from the Rust demo twinkles in a window,
and a direct-pane plasma (a 40-line demo) animates with no upload call
anywhere in it.

**Rust tests covered.** `the_backbuffer_pointer_is_writable_memory`, plus
G0's two shader tests now running against the real `ShaderPane`.

**Status.** Done. `gamepane/tests/test_panes.mojo` passes, and both demos
run headless in `check-examples.sh`.

The frame became a type. `GamePane` now hands out a `Frame` — drawable,
target texture, command buffer, and whether there was a drawable at all —
from `begin_frame()`, and every layer encodes into that one command buffer
before `end_frame()` presents and commits it. That is what makes a composite
a composite rather than a stack of submissions, and it is the API G3–G6 all
plug into. `present()` survives as begin/clear/end for a pane with no layers.
`read_frame()` reads a finished frame back as BGRA, so a test can assert
about what was DRAWN: a pipeline that compiles and a pipeline that puts the
right colour on the drawable are different claims, and only the second one
matters.

Both panes are checked through real pixels. `u.p[0..2]` set to (1, 0, 0.5)
comes back from the drawable as BGRA 128 0 255. A direct-pane plane filled
with index 200, whose palette entry is (12, 200, 60), comes back as BGRA
60 200 12 — a host byte became a colour on screen with no upload call in
between. The negative case is checked too: a source with no `fmain` raises
an error that names `fmain`, because an empty source compiles cleanly and it
is `newFunctionWithName:` that fails.

The compiler caught a `let` aliasing bug in `DirectPane.render` — `let drawn
= self.write` binds to the field the rotation at the end of the function
overwrites. Harmless as written, since every use precedes the write, and a
trap the moment anyone adds a use after it.

**The demos.** `examples/gamepane-starfield` is the Rust demo's fragment
shader quoted verbatim: thirteen lines of MSL, no vertex buffer, no texture,
no CPU work, and `u.time` the only thing that changes between frames — 141
pixels differ between frame 5 and frame 90, so it really twinkles.
`examples/gamepane-plasma` is forty lines that write bytes into
`backbuffer_ptr()`; there is no upload call anywhere in it, and the rows are
`stride_bytes()` apart rather than `width` apart, which is why it is a
plasma and not a diagonal smear.

---

## Sprint G3 — the indexed pane (DONE, size M, wants G0)

**Goal.** Layer 1 entire: eight slots, the per-line/global palette, overscan
scrolling, and every drawing primitive — with no CPU mirror.

**Pieces.**

1. Eight slots as eight `DeviceBuffer`s of `stride × world_h` bytes, each
   with an `R8Uint` texture view. `set_active`, `swap_buffers` (swap the
   views and the buffers, not the bytes), `FRONT`/`BACK` constants.
2. The palette: `viewport_h × 16 + 240` RGBA **bytes** in one shared buffer.
   `set_rgb` (asserts index ≥ 16), `set_line_rgb` (asserts 1..15 and the
   line range), `palette_ptr()`, `palette_entries()`,
   `palette_global_base()`, `load_default_palette` (grey ramp per line,
   240-step hue wheel global — `hsv_to_rgb` ported as written).
3. `set_scroll` clamped to `world − viewport`; `scroll()`.
4. Primitives writing through `contents` with the stride: `cls`, `pset`
   (out-of-bounds is a no-op, not a trap), `pget` (transparent when out of
   bounds), `fill_rect`, `line` (Bresenham), `circle` (midpoint outline),
   `disc` (spans), `blit(data)` (bulk, length-safe).
5. The fragment shader verbatim, `Uniforms{scroll, viewport}`, `Load`.

**Done when** the twelve platforms render over the starfield at their
colours, the per-line gradient in index 1 runs down the viewport, and the
scroll drifts across the world with nothing redrawn.

**Rust tests covered.** All nine of `indexed_pane.rs`:
`pset_pget_round_trips_within_the_active_buffer`,
`blit_bulk_copies_indices_and_is_length_safe`,
`out_of_bounds_pset_is_a_no_op_not_a_panic`, `cls_fills_the_whole_active_buffer`,
`fill_rect_covers_exactly_its_rectangle`,
`swap_buffers_exchanges_front_and_back_content`,
`scroll_is_clamped_to_the_overscan_margin`,
`palette_index_math_matches_the_per_line_vs_global_split`,
`set_line_rgb_rejects_index_0_and_global_range`.

**Status.** Done, all nine plus five the Rust has no equivalent of.
`gamepane/tests/test_indexed.mojo` passes and
`examples/gamepane-platforms` is the demo.

**The mirror is gone, as designed.** Each of the eight slots is one
`DeviceBuffer` with a linear `R8Uint` texture view over it, so a `pset`
stores into the exact bytes the fragment shader samples. That deletes the
Rust's `Vec<u8>` per slot, its `dirty` flags and its `upload()` — and with
them the reason its blitter had to apply every operation twice, which is
what G4 inherits.

**The primitives went to the neutral tier.** An index plane is a rectangle of
bytes `stride` apart, which is all Bresenham needs, so `api/indexed.mojo`
holds `Plane` — base pointer, stride, width, height — and every primitive on
it. It cannot tell a Metal buffer from a `List`, which is what makes the
neutral tier a real boundary rather than a claim. The backend's whole job is
to say where the bytes are.

**The window now uses the runtime's device.** `GamePane` owns a
`DeviceContext` and takes its `MTLDevice` from `metal_device()` rather than
`MTLCreateSystemDefaultDevice`, so every layer, pipeline, texture and kernel
shares one device by construction. G0 found them to be the same object here;
this makes that irrelevant rather than load-bearing. The G0 accessors moved
out of the spikes into `metal/device.mojo`, which is also where the borrow
rule is written down.

**Five checks the Rust does not have.** `blit` repacks a width-major source
into stride-major rows, so it is tested at a width the alignment does not
divide; a second pane 641 wide proves the stride is 656 and that row 1
begins a stride in rather than a width in; and the composite is read back
through a real drawable, where the same index 3 comes out red on line 1 and
green on line 2, a global index 200 resolves through the other half of the
palette, index 0 discards to the ground, and world row 300 arrives at screen
row 60 after a scroll that redrew nothing.

640 divides by 16, so the Rust's own dimensions never exercise the stride at
all — which is why the awkward width is a separate pane rather than a
different constant.

---

## Sprint G4 — the blitter, as Mojo kernels (DONE, size M, wants G0 and G3)

**Goal.** `copy`, `transparent`, `minterm` (AND/OR/XOR) and `clear` between
any two slots, on the GPU, through this fork's own backend — and the rule
that keeps them ordered against the frame.

**Pieces.**

1. Four Mojo kernels over the index bytes, each a `(w, h)` grid with the
   `BlitParams` record (`src_x, src_y, dst_x, dst_y, w, h, op, value`) as
   arguments, launched with `enqueue_function` on the runtime's queue.
   Rectangles validated against world bounds before launch.
2. `present()` calls `ctx.synchronize()` before encoding the frame — every
   enqueued blit is complete before the frame that shows it.
3. If G0's accessor path did not land: the same four operations as CPU
   loops through `contents`. Same tests, same semantics, and the kernels
   return when the accessors do.

**Done when** the Rust's four blitter tests pass reading the result back
through `map_to_host`, and a fifth — blit, present, read the composite —
proves the ordering rule.

**Rust tests covered.** `copy_moves_pixels_from_one_slot_to_another_on_the_cpu_mirror`
(renamed: there is no mirror), `transparent_copy_skips_index_zero_source_pixels`,
`minterm_and_masks_the_destination_by_the_source`,
`clear_fills_the_rectangle_with_the_given_index`.

**Status.** Done. `gamepane/tests/test_blitter.mojo` passes. Piece 3 — the
CPU-loop fallback — is not needed; these are real kernels.

Four Mojo `def`s in `metal/blitter.mojo`, no hand-written Metal compute
shaders anywhere, writing the same bytes the fragment shader samples. The
Rust applies every operation twice, to the texture and to a CPU mirror,
because its `upload()` would otherwise push stale mirror bytes over the
result; with no mirror there is one application and nothing to keep in step.

**Clipping moved to the neutral tier and happens once.** `api/blit.mojo`
holds `clip_blit`, which trims a requested rectangle against both planes
before any thread launches — so a kernel never bounds-checks a plane, an
off-edge blit is a no-op rather than a trap, and both origins move together
(trimming two pixels off the destination's left trims two off the source, or
the copy shears).

**Compilation is cached, measured rather than assumed.** The first
`compile_function` for a kernel costs about 140 ms and every later one about
28 µs, so the operations call it per blit and `warm_up_blitter` exists only
so a game pays the 140 ms at startup instead of at its first sprite.

**The ordering rule is automatic, and the test for it took three tries.**
`begin_frame` calls `ctx.synchronize()`: blits are enqueued on the runtime's
stream while frames are encoded on the layer's command queue, two submission
paths to one device with nothing implicitly ordering them, and the failure
mode is a frame late by one — which reads as a game bug, not a missing call.

Getting a test that could actually fail was the work. `enqueue_function`
**does** commit; it just does not wait. So a 32×4 fill finishes long before
`nextDrawable` returns and passed with the synchronize deleted; so did 240
fills of a 64×64 world. Sixty fills of a 1024×1024 world take a measured
4.5 ms to drain and the plane's last byte is still unwritten the instant
enqueue returns — but `nextDrawable` blocks longer than 4.5 ms, so even that
passed through the composite path. The race is masked on this machine, not
absent, and a faster drawable or a slower blit unmasks it. The test
therefore asks the plane directly: after `begin_frame`, the queue must be
drained. With the synchronize removed that check reports 0 instead of 200.
The composite check stays as the end-to-end confirmation, with a note saying
it cannot fail here on its own.

---

## Sprint G5 — sprites (NOT STARTED, size M, wants G0)

**Goal.** Layer 2: definitions from the row format, retained per-definition
GPU state, instances with the full transform set, animation and hit
testing.

**Pieces.**

1. `parse_sprite_rows`: `/`-separated rows of hex digits, `.` as 0,
   ragged or empty rejected. `define_sprite(rows) -> Optional[Int]`,
   `add_frame(id, rows) -> Bool` (dimensions must match), `sprite_rgb(id,
   index, r, g, b)` with a dirty flag flushed at render.
2. Per frame: one `DeviceBuffer` (`stride × h`) with an `R8Uint` view. Per
   definition: one 16 × `float4` palette buffer.
3. Instances: `place`, `move_to`, `set_scale`, `set_rotation`, `set_alpha`
   (clamped), `set_frame`, `animate(fps)`, `show`/`hide`, `sprite_x`/`sprite_y`,
   `tick(dt)` advancing the accumulator and wrapping the frame, `hit(a, b)`
   as the AABB.
4. `quad_vertices` on the CPU exactly as the Rust: half-extents by scale,
   rotate, subtract scroll, map to NDC, triangle-strip order. One
   `drawPrimitives:` per visible instance; the blend pipeline
   (source-alpha / one-minus) from the Rust descriptor.

**Done when** the five decorative coins glint at 4 fps across the scrolling
world and the big one moves under the arrow keys, over the platforms, over
the stars.

**Rust tests covered.** `parse_sprite_rows_reads_hex_digits_and_dot_as_transparent`,
`parse_sprite_rows_rejects_ragged_rows`, `define_and_place_a_sprite`,
`add_frame_rejects_mismatched_size`, `animate_cycles_frames_over_time`,
`hit_detects_overlapping_and_separate_instances`.

---

## Sprint G6 — the text overlay and the text plane (NOT STARTED, size S, wants G0)

**Goal.** Layer 3 both ways: the retained overlay for object-attached text,
and the cell grid for screens.

**Pieces.**

1. The font: `DIGIT_GLYPHS`, `LETTER_GLYPHS`, the punctuation cases and the
   placeholder, ported byte for byte into `gamepane/api/text.mojo`;
   `glyph_for(ch)` with the lowercase fold. `GLYPH_W = 5`, `GLYPH_H = 7`,
   advance 6.
2. `TextOverlay`: RGBA buffer backing an `RGBA8Unorm` texture,
   `draw_text(x, y, text, r, g, b, scale)`, `clear`, `upload` (this one
   layer keeps an upload, because a texture is the right home for RGBA),
   blended full-screen pass, always last.
3. `TextPlane`: `cols = viewport_w / 6`, `rows = viewport_h / 8`, never
   zero; cells `[char, fg, bg, flags]` in a shared buffer, `cells_ptr()`,
   `cells_len()`, `clear`; the 256-glyph atlas baked from `glyph_for`; the
   Rust's shader verbatim; the default sixteen at palette 16..31, white
   elsewhere so an unset index is visible.

**Done when** `0-9 :- DEMO` renders at the top left of the demo, a scale-3
title renders as blocks, `%` renders as a hollow box, and a text-plane menu
sits over the picture with a transparent background.

**Rust tests covered.** All eight of `text_overlay.rs` and all three of
`text_plane.rs`: `clear_zeroes_the_whole_buffer`, `letter_a_lights_the_expected_pixels`,
`digit_zero_is_a_ring_with_a_hollow_interior`, `space_leaves_its_cell_untouched`,
`characters_advance_by_glyph_advance_pixels_at_scale_one`,
`scale_blocks_each_font_pixel_into_a_square`,
`unknown_character_renders_the_hollow_placeholder_box`,
`lowercase_folds_to_the_uppercase_glyph`,
`geometry_divides_the_viewport_into_six_by_eight_cells`,
`a_fresh_plane_is_entirely_unused_cells`, `cells_are_writable_and_clear_blanks_them`.

---

## Sprint G7 — audio: the chip as the engine (NOT STARTED, size M, needs no Metal)

**Goal.** Sound effects and a voice bank from `chip.mojo`, on one audio
unit, with the trigger path from the main thread proven lock-free. This
sprint does not port `synth.rs` or `voice.rs`; by decision (design §2), the
chip is the synth.

**Pieces.**

1. Lift `chip.mojo` into `gamepane/api/audio.mojo` unchanged;
   `examples/chip` imports it from there. The review's four rough edges
   (cutoff wrap, `set_wave` unmasked, `high` before the NaN reset, voice 0's
   stale sync source) are fixed on the way in, each with the test that
   would have caught it.
2. The audio unit and the callback in `gamepane/metal/audio.mojo`:
   `start_audio` from `chip/main.mojo` (mono `Float32` 48 kHz, the
   `AURenderCallbackStruct` with the chip state as `inRefCon`), and a
   `fn render` that runs **chip A** (music) and **chip B** (effects) into
   two spans and sums them. Stopped before `main` returns, always.
3. The trigger ring: a single-producer, single-consumer ring of
   `(effect_id, sample)` with power-of-two size and two counters —
   `sfx.play(id)` writes on the main thread, the callback drains it at the
   top of each buffer and gates a chip-B voice, stealing the oldest when all
   three are busy. A test fires 1,000 triggers faster than the callback
   consumes them and counts that none is lost or applied twice.
4. The twelve effects as chip recipes — waveform, ADSR, start pitch, and a
   50 Hz routine on chip B's player hook: `coin` (two pulses a fifth
   apart), `jump` (rising sweep), `zap`/`shoot` (falling sweep, noise mix),
   `explode` (noise, falling pitch, filter closing), `powerup` (rising
   square), `hurt`, `click`, `bang`, `blip`, `saucer` (two voices 6 Hz
   apart — the beat is the warble), `boss_hum` (110 vs 114 Hz). Numeric
   indices 0–11 as the Rust's `play_sound(preset)`; an out-of-range index
   is a short click, never a trap.
5. `ChipVoiceBank`: `note_on(voice, midi)`, `note_off(voice)`,
   `set_instrument(voice, recipe)`, `is_voice_active` — over `gate_on`,
   `gate_off` and the register setters.
6. `wav.mojo`: port of `wav.rs`, write with half-away rounding, read
   8/16/24/32-bit. Offline render — `chip_render` into a heap buffer — plus
   `write_wav` is how every effect gets a regression test: the chip is
   integer arithmetic with a fixed LFSR seed, so a rendered `zap` hashes
   identically every run.

**Done when** Space plays a zap over a running tune with no click and no
dropout under `MODULAR_DEBUG` off, twelve `.wav` files render and their
hashes are committed as the test's expected values, and the ring test
passes.

**Rust tests covered (re-homed on the chip).** `all_presets_run_and_produce_sane_output`,
`play_sound_covers_every_index_and_out_of_range_is_safe`,
`saucer_and_boss_hum_beat_at_their_detune`,
`render_is_deterministic_given_same_seed_and_effect` (as a hash),
`a_fresh_bank_has_no_active_voices`,
`note_on_activates_a_voice_and_note_off_eventually_idles_it`,
`idle_voices_contribute_silence`, `multiple_voices_sum_together`,
`round_trip_preserves_samples_within_quantization_tolerance`,
`write_wav_rejects_empty_sound`, `volume_scales_output_amplitude`.
Not carried, by decision: `synth.rs`'s LCG, waveform and ADSR-curve tests,
and `playback.rs`'s pool tests.

---

## Sprint G8 — audio: tunes (NOT STARTED, size S, needs no Metal, wants G7)

**Goal.** ABC in, sample-accurate notes on chip A out; the one parser gap
closed; SMF export kept.

**Pieces.**

1. Lift `parse/music/model/schedule/repeats/midi` from `examples/abcplayer`
   into `gamepane/abc/`; the example imports them back. `Tune`, `Event`,
   `Voice`, `Step`, `build_schedule`, `sort_steps` unchanged.
2. `%%MIDI program / channel / transpose / drum` — the one construct the
   Rust parser has and this one lacks. `program` sets the voice instrument
   (used by the DLS backend; the chip maps GM programs onto its three
   recipes), `channel` and `drum` as the Rust does, `transpose` onto the
   existing `Voice.transpose`.
3. `play_tune(tune)` schedules onto chip A through the existing callback
   path; `stop_tune`; `[I:chip …]` directives already switch voices
   mid-tune. The DLS `MusicDevice` backend remains selectable for a General
   MIDI rendering of the same `Step`s.
4. `to_ms_events(tune)` — the Rust's flat form, absolute milliseconds,
   time-sorted with its priority order — for anything that wants it, and
   `write_smf` over it.

**Done when** Twinkle Twinkle plays at demo start on chip A while zaps land
on chip B, and the parser cases below pass. The Rust's tests assert absolute
MIDI numbers under its `C = 48` convention; this parser's convention is
asserted once, and every other case is written against relative facts
(F under `K:G` is F + 1, a tie is one note of the summed length, a chord is
three note-ons at one time, a repeat doubles the enclosed material, two
voices land on two channels).

**Rust tests covered.** `twinkle_twinkle_default_state` (event count and
tempo), `key_signature_g_makes_f_sharp`, `no_key_signature_f_is_natural`,
`tied_notes_merge_into_one_longer_note`, `untied_notes_stay_separate`,
`chord_emits_three_simultaneous_note_ons`,
`repeat_expansion_plays_enclosed_material_twice`,
`two_voices_get_distinct_midi_channels`,
`rest_advances_cursor_without_emitting_notes`, `bar_line_resets_accidental`,
`lowercase_c_is_octave_above_uppercase`, `tempo_header_changes_bpm`,
`structural_fields_and_tempo_meta_present`, `write_smf_rejects_empty_tune`,
`vlq_round_trips_multi_byte_values`.

---

## Sprint G9 — the demo, the package, the chapter (NOT STARTED, size S, wants G1–G8)

**Goal.** The acceptance test, shipped.

**Pieces.**

1. `examples/gamepane-starfield/main.mojo`: `starfield_demo/main.rs` line
   for line — the shader, the twelve platforms at the six brick colours, the
   per-line gradient, the 8×8 coin with the shifting highlight, five
   decorative coins and a steerable one, the HUD, a zap on Space, Twinkle
   at start.
2. `tools/sync-dist-sources.sh` gains `rsync -a --delete "$ROOT/gamepane/"
   "$D/lib/mojo/gamepane/"`; `check-examples.sh` registers the demo and
   holds the raw `msg_send` count at zero (protocol-typed Metal calls use
   `send`, which is the sanctioned spelling).
3. `tools/check-gamepane.sh`: builds every file under `gamepane/tests/`,
   runs them, then runs the demo with `GAMEPANE_FRAMES=30` and
   `GAMEPANE_DUMP` and checks the dump is not black.
4. A guide chapter, *The game pane*, in the house style: the layer stack,
   the frame contract, one worked example, and the audio arrangement.

**Done when** `check-gamepane.sh` is green, the demo is in the Examples
menu of an installed Roast, and the chapter is in the PDF.

---

## Sprint G10 — the first game: Galaxigans (NOT STARTED, size L, wants G9)

**Goal.** The reason for all of it: port a Rust MacGamePane game to
`gamepane.api` and have it play. Galaxigans is the candidate — the Rust
repository's own history (`engine: the galaxigans-port extensions`) lists
what it needed: text scale and full glyphs, sprite frames and visibility,
synth presets, scripted event injection. Each of those is in G5–G8.

**Pieces.** The game's source against `gamepane.api` only; its tune in ABC
with `[I:chip]` directives; its effects as chip recipes; a `GAMEPANE_FRAMES`
run in `check-gamepane.sh` that plays the attract mode headless.

**Done when** it runs, and when a second game starts from it as a template
rather than from the engine.

---

## Deferred, explicitly

Carried from the Rust's own list, still deferred: the `VoiceScript`
sequencer, a separate tilemap layer, FM/additive/granular synthesis, gamepad
rumble. Added here: sampled-sound playback through `AVAudioPlayerNode`, and
a generic software synth as a second engine behind `Sfx` — neither designed
out, neither waited on.

## Standing verification commands

```bash
# the gate
cocoamojo run gamepane/tests/spike_pipeline.mojo

# everything headless -- every spike_* and test_* in gamepane/tests,
# against dist/CocoaMojo, stealing nobody's focus
./tools/check-gamepane.sh

# the demos, without a screen
GAMEPANE_FRAMES=30 GAMEPANE_DUMP=/tmp/starfield.bgra \
  cocoamojo run examples/gamepane-starfield/main.mojo
GAMEPANE_FRAMES=30 GAMEPANE_DUMP=/tmp/plasma.bgra \
  cocoamojo run examples/gamepane-plasma/main.mojo

# the whole example set, msg_send held at zero
./tools/check-examples.sh
```
