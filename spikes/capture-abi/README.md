# Capture-ABI probes

Reproducers for the launch-ABI defects in [`defects.md`](../../defects.md).
Each is a self-contained program; run them through a dist compiler with
GPU validation on:

    MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1 \
      <dist>/bin/cocoamojo --run <probe>.mojo

- `two_caps.mojo`  — two scalar captures through an adapter (baseline;
  always expected to pass).
- `agg_caps.mojo`  — a captured DEVICE POINTER as a pack member (D3):
  passes when the slot is typed device and the runtime resolves the
  address in the allocation registry; wrong numbers if typed constant.
- `pack_struct.mojo` — a by-reference struct capture (D4): the rms_norm
  adapter shape in miniature. Expected to pass with the
  `kgen.offload.capture` marker fix.
- `rms_repro.mojo` — the real `rms_norm[target="gpu"]` dispatcher path
  (D5/D6). Flip `reroute_gpu_to_rms_norm_gpu` in the dist's
  `lib/mojo/kernels/nn/normalization.mojo` to exercise the reroute.

The probes that failed to launch print the runtime's own classification
("caller says constant, reflection says device"), which is the fastest
orientation when a change moves one of these.
- `tile_caps.mojo` — a copy-captured TileTensor (memory-passable,
  DevicePassable): the MOCO-4045 regression test. Crosses BY VALUE since the
  ClosureEmitter fix; before it, boxed thin and died with
  "unknown device address".
