# GPU corpus status

Pattern: `//max/kernels/test/gpu/...` — 805 test targets.

A bazel PASS is not evidence: `VACUOUS` rows passed by skipping every path.

| relevance | EXCLUDED | FAIL | NO_STATUS | PARTIAL | PASS | VACUOUS | total |
|---|---|---|---|---|---|---|---|
| apple | 0 | 5 | 1 | 2 | 8 | 0 | 16 |
| generic | 0 | 18 | 416 | 0 | 70 | 2 | 506 |
| excluded | 97 | 0 | 0 | 0 | 0 | 0 | 97 |
| foreign | 0 | 0 | 177 | 0 | 0 | 0 | 177 |
| disabled-everywhere | 0 | 0 | 9 | 0 | 0 | 0 | 9 |

## apple: needs attention

| target | outcome | metallibs | note |
|---|---|---|---|
| `//max/kernels/test/gpu/linalg:test_apple_fp4_matmul.mojo.test` | FAIL | 13 |  |
| `//max/kernels/test/gpu/linalg:test_apple_gpu_matmul.mojo.test` | FAIL | 73 |  |
| `//max/kernels/test/gpu/linalg:test_apple_int8_matmul.mojo.test` | FAIL | 6 |  |
| `//max/kernels/test/gpu/linalg:test_grouped_matmul_apple_fp8.mojo.test` | FAIL | 15 |  |
| `//max/kernels/test/gpu/nn:test_apple_fa_prefill.mojo.test` | FAIL | 1281 |  |
| `//max/kernels/test/gpu/layout:test_apple_mma_fragment.mojo.test` | PARTIAL | 19 | SKIP: |
| `//max/kernels/test/gpu/nn:test_conv2d_im2col_apple.mojo.test` | PARTIAL | 85 | SKIP: |

## generic: needs attention

| target | outcome | metallibs | note |
|---|---|---|---|
| `//max/kernels/test/gpu/basics:test_accelerator_arch_cli_kernels.mojo.test` | FAIL | 0 |  |
| `//max/kernels/test/gpu/basics:test_convert.mojo.test` | FAIL |  |  |
| `//max/kernels/test/gpu/basics:test_fast_div_ptx.mojo.test` | FAIL |  |  |
| `//max/kernels/test/gpu/basics:test_invariant_load.mojo.test` | FAIL |  |  |
| `//max/kernels/test/gpu/basics:test_is_sm90.mojo.test` | FAIL |  |  |
| `//max/kernels/test/gpu/basics:test_load_width_codegen.mojo.test` | FAIL |  |  |
| `//max/kernels/test/gpu/compile:test_amd_block_sync_lds.mojo.test` | FAIL | 0 |  |
| `//max/kernels/test/gpu/compile:test_elementwise_trace_description.mojo.test` | FAIL | 0 |  |
| `//max/kernels/test/gpu/kv_cache:test_mha_decoding_vs_naive.mojo.test` | FAIL | 151 |  |
| `//max/kernels/test/gpu/nn:attention/test_naive_fa_decode_apple.mojo.test` | FAIL | 47 |  |
| `//max/kernels/test/gpu/nn:test_apple_fa_prefill_paged.mojo.test` | FAIL | 577 |  |
| `//max/kernels/test/gpu/nn:test_conv_grouped.mojo.test` | FAIL | 14 |  |
| `//max/kernels/test/gpu/nn:test_fused_qk_rms_norm_rope.mojo.test` | FAIL | 14 |  |
| `//max/kernels/test/gpu/nn:test_gather.mojo.test` | FAIL | 0 |  |
| `//max/kernels/test/gpu/nn:test_index_tensor.mojo.test` | FAIL | 3 |  |
| `//max/kernels/test/gpu/nn:test_layer_norm.mojo.test` | FAIL | 30 |  |
| `//max/kernels/test/gpu/nn:test_rms_norm.mojo.test` | FAIL | 174 |  |
| `//max/kernels/test/gpu/state_space:test_mamba2_ssd_scan.mojo.test` | FAIL | 10 |  |
| `//max/kernels/test/gpu/nn:attention/test_naive_fa_decode_apple_sink.mojo.test` | VACUOUS | 11 | SKIP: Apple M5 required |
| `//max/kernels/test/gpu/nn:test_mla_layout_g_mma_smoke.mojo.test` | VACUOUS | 1 | Skipping: this test requires B200 (SM100) |
