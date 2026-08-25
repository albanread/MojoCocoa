# Apple GPU test run

58 in-scope tests executed directly (bazel built them; this runner ran them). 0 vendor-owned test(s) were excluded -- see the end of this file.

| outcome | count |
|---|---|
| pass | 28 |
| unverified | 2 |
| fail | 18 |
| pso | 1 |
| crash | 2 |
| timeout | 1 |
| build-failure | 6 |

**28 of 56 ran real work, checked it, and passed.** Excluded from that: 0 vacuous skip(s) and 2 test(s) that exit 0 with nothing that could fail them.


## fail (18)

| test | detail |
|---|---|
| `test_batch_kv_cache_flash_attention.mojo.test` | Unhandled exception caught during execution: At max/kernels/test/gpu/kv_cache/test_batch_kv_cache_flash_attent |
| `test_batch_kv_cache_flash_attention_causal_mask.mojo.test` | Unhandled exception caught during execution: At max/kernels/test/gpu/kv_cache/test_batch_kv_cache_flash_attent |
| `test_tensor_gpu.mojo.test` | Unhandled exception caught during execution: max/kernels/test/gpu/layout/test_tensor_gpu.mojo:61:33 failed cal |
| `test_tile_io.mojo.test` |   right: 9.0 |
| `test_gemv2.mojo.test` | Unhandled exception caught during execution: At max/kernels/src/linalg/gemv.mojo:1640:54: AppleGPURT: DeviceCo |
| `test_split_k_reduce.mojo.test` | Unhandled exception caught during execution: max/mojo/max/algorithm/backend/gpu/elementwise.mojo:563:29 failed |
| `test_argsort.mojo.test` |   reason: indices[1] = 0 expected_indices[1] = 1 N = 3731 ascending = True at position 1 |
| `test_flash_attention.mojo.test` | Unhandled exception caught during execution: At max/kernels/test/gpu/nn/test_flash_attention.mojo:602:32: Asse |
| `test_group_norm.mojo.test` | Unhandled exception caught during execution: At max/kernels/test/gpu/nn/test_group_norm.mojo:143:32: Assertion |
| `test_padding_gpu.mojo.test` | >>>>>> |
| `test_rms_norm_fused_fp8.mojo.test` | Unhandled exception caught during execution: Higher rank tensor test failed |
| `test_rope_split_store.mojo.test` | Unhandled exception caught during execution: V cache should be identical (no rope applied) |
| `test_tpool_patch_merger.mojo.test` | Unhandled exception caught during execution: At max/kernels/test/gpu/nn/test_tpool_patch_merger.mojo:179:28: A |
| `test_warp_bitonic_sort.mojo.test` |   reason: weight[0]: got nan expected 0.22222222. Non-equal weights mean biased score was used. |
| `test_causal_conv1d.mojo.test` | Test suite' max/kernels/test/gpu/state_space/test_causal_conv1d.mojo 'failed! |
| `test_gated_delta_conv1d.mojo.test` | Test suite' max/kernels/test/gpu/state_space/test_gated_delta_conv1d.mojo 'failed! |
| `test_mamba_split_conv1d_scan_combined.mojo.test` | Test suite' max/kernels/test/gpu/state_space/test_mamba_split_conv1d_scan_combined.mojo 'failed! |
| `test_varlen_causal_conv1d.mojo.test` | Test suite' max/kernels/test/gpu/state_space/test_varlen_causal_conv1d.mojo 'failed! |

## pso (1)

| test | detail |
|---|---|
| `test_gated_delta.mojo.test` | At max/mojo/max/gpu/host/_device_context_extras.mojo:168:17: AppleGPURT[metal]: newComputePipelineStateWithFun |

## crash (2)

| test | detail |
|---|---|
| `test_launch_binary.mojo.test` | signal 11 (SIGSEGV) |
| `test_fused_qk_rope_ragged.mojo.test` | signal 11 (SIGSEGV) |

## timeout (1)

| test | detail |
|---|---|
| `test_topk_gpu_fi.mojo.test` | — |

## build-failure (6)

| test | detail |
|---|---|
| `test_simd_reduction.mojo.test` | no binary produced |
| `test_compile_to_llvm_codegen.mojo.test` | wrapper target: max/kernels/test/gpu/compile/test_compile_to_llvm_codegen.mojo.test.binary was not produced |
| `test_double_buffer_gemm.mojo.test` | no binary produced |
| `test_layout_tensor_copy.mojo.test` | wrapper target: max/kernels/test/gpu/layout/test_layout_tensor_copy.mojo.test.binary was not produced |
| `test_topk_bitonic.mojo.test` | no binary produced |
| `test_rms_norm_fused_residual.mojo.test` | no binary produced |

## unverified (2)

| test | detail |
|---|---|
| `test_matmul_int.mojo.test` | exit 0, but the source has no assertion, no CHECK line and no failure path |
| `test_mha_sink_weights.mojo.test` | exit 0, but the source has no assertion, no CHECK line and no failure path |

## measured

| test | perf |
|---|---|
| `test_concat.mojo.test` | 5.46455540726938 GB/s |
