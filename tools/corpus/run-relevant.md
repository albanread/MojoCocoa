# Apple GPU test run

91 in-scope tests executed directly (bazel built them; this runner ran them). 9 vendor-owned test(s) were excluded -- see the end of this file.

| outcome | count |
|---|---|
| pass | 67 |
| partial | 2 |
| unverified | 2 |
| vacuous | 1 |
| fail | 13 |
| pso | 3 |
| build-failure | 3 |

**69 of 88 ran real work, checked it, and passed.** Excluded from that: 1 vacuous skip(s) and 2 test(s) that exit 0 with nothing that could fail them.


## fail (13)

| test | detail |
|---|---|
| `test_accelerator_arch_cli_kernels.mojo.test` |   Failed: 1 (100.00%) |
| `test_elementwise_trace_description.mojo.test` |   Failed: 1 (100.00%) |
| `test_mha_decoding_vs_naive.mojo.test` | Unhandled exception caught during execution: At max/kernels/test/gpu/kv_cache/test_mha_decoding_vs_naive.mojo: |
| `test_apple_gpu_matmul.mojo.test` | Unhandled exception caught during execution: enqueue_apple_matmul requires Apple M5 (compute_capability == 5); |
| `test_apple_int8_matmul.mojo.test` | Unhandled exception caught during execution: FAILED: 3 of 3 stages |
| `test_grouped_matmul_apple_fp8.mojo.test` | Unhandled exception caught during execution: matmul2d W4A16 (Apple M5 NVFP4) requires Apple M5 (compute_capabi |
| `attention/test_naive_fa_decode_apple.mojo.test` | Unhandled exception caught during execution: At max/kernels/test/gpu/nn/attention/test_naive_fa_decode_apple.m |
| `test_conv_grouped.mojo.test` | Unhandled exception caught during execution: At max/kernels/test/gpu/nn/test_conv_grouped.mojo:158:17: Asserti |
| `test_fused_qk_rms_norm_rope.mojo.test` | Unhandled exception caught during execution: At max/kernels/test/gpu/nn/test_fused_qk_rms_norm_rope.mojo:394:4 |
| `test_gather.mojo.test` | >>>>>> |
| `test_index_tensor.mojo.test` |   right: 1 |
| `test_layer_norm.mojo.test` | Unhandled exception caught during execution: At max/kernels/test/gpu/nn/test_layer_norm.mojo:112:32: Assertion |
| `test_rms_norm.mojo.test` | Unhandled exception caught during execution: At max/kernels/test/gpu/nn/test_rms_norm.mojo:114:32: AssertionEr |

## pso (3)

| test | detail |
|---|---|
| `test_apple_fp4_matmul.mojo.test` | == FAILED test_stage4_dispatch_paths: At max/mojo/max/gpu/host/_device_context_extras.mojo:168:17: AppleGPURT[ |
| `test_apple_fa_prefill.mojo.test` | Unhandled exception caught during execution: At max/mojo/max/gpu/host/_device_context_extras.mojo:168:17: Appl |
| `test_apple_fa_prefill_paged.mojo.test` | Unhandled exception caught during execution: At max/mojo/max/gpu/host/_device_context_extras.mojo:168:17: Appl |

## build-failure (3)

| test | detail |
|---|---|
| `test_invariant_load.mojo.test` | no binary produced |
| `test_load_width_codegen.mojo.test` | no binary produced |
| `test_metal_print.mojo.test` | wrapper target: max/kernels/test/gpu/basics/test_metal_print.mojo.test.binary was not produced |

## vacuous (1)

| test | detail |
|---|---|
| `attention/test_naive_fa_decode_apple_sink.mojo.test` | SKIP: Apple M5 required |

## unverified (2)

| test | detail |
|---|---|
| `test_random.mojo.test` | exit 0, but the source has no assertion, no CHECK line and no failure path |
| `issue_32811.mojo.test` | exit 0, but the source has no assertion, no CHECK line and no failure path |

## partial (2)

| test | detail |
|---|---|
| `test_apple_mma_fragment.mojo.test` | SKIP: requires Apple M5 + Metal 4 == test_mma_1x1 SKIP: requires Apple M5 + Metal 4 == tes |
| `test_conv2d_im2col_apple.mojo.test` | SKIP: dispatcher declined this shape (1x1 / K<16 / N<16) == bf16 3x3 s1 same-pad C64->1 |

## excluded as another vendor's

| test | outcome here | why |
|---|---|---|
| `test_fast_div_ptx.mojo.test` | build-failure | vendor token in the test name |
| `test_has_sm100_or_newer.mojo.test` | pass | vendor token in the test name |
| `test_is_sm90.mojo.test` | build-failure | vendor token in the test name |
| `test_amd_asan_oob.mojo.test` | pass | vendor token in the test name |
| `test_amd_block_sync_lds.mojo.test` | fail | vendor token in the test name |
| `test_compile_via_param.mojo.test` | pass | lit REQUIRES: NVIDIA-GPU |
| `test_lora_shrink_qkv_permute_3mn_sm100.mojo.test` | pass | vendor token in the test name |
| `test_fp8_quantize_saturating.mojo.test` | unverified | vendor guard (has_nvidia_gpu_accelerator) and no work done here |
| `test_mla_layout_g_mma_smoke.mojo.test` | vacuous | vendor guard (_is_sm10x_gpu) and no work done here |
