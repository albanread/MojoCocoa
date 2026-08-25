# Tests excluded from the Apple GPU build

61 test files are marked `@platforms//:incompatible` for `//:apple_gpu`.
They never become bazel targets, so they are absent from any pass rate measured with `bazel test`.

16 carry a stated reason; 45 do not.

## `max/kernels/test/gpu/compile` (1)

| test | id | reason |
|---|---|---|
| `test_compile_to_llvm_codegen.mojo` | KERN-2360 | external_memory is not supported on Apple silicon |

## `max/kernels/test/gpu/linalg` (12)

| test | id | reason |
|---|---|---|
| `test_batched_matmul.mojo` | PRDT-506 | (no reason given) |
| `test_gemv.mojo` | MOCO-3587 | Metal compilation failure |
| `test_gemv2.mojo` |  | (no reason given) |
| `test_grouped_matmul_rowwise_scaled_fp8.mojo` |  | (no reason given) |
| `test_grouped_matmul_tile_scheduler.mojo` |  | (no reason given) |
| `test_grouped_matmul_vendor.mojo` | PRDT-506 | (no reason given) |
| `test_linalg_matmul_gpu.mojo` | MOCO-2366 | (no reason given) |
| `test_matmul.mojo` | PRDT-506 | (no reason given) |
| `test_matmul_custom.mojo` | PRDT-506 | (no reason given) |
| `test_matmul_tile_scheduler.mojo` | MOCO-2405 | (no reason given) |
| `test_multistage_gemm_kernel.mojo` |  | long running on MacOS |
| `test_split_k_reduce.mojo` | MOCO-2411 | bfloat16 numerical mismatch on Apple GPU |

## `max/kernels/test/gpu/nn` (37)

| test | id | reason |
|---|---|---|
| `test_apply_packed_bitmask.mojo` |  | (no reason given) |
| `test_argmax_streaming_gpu.mojo` | MOCO-2397 | same argmax path as test_argmaxmin_gpu.mojo |
| `test_argmaxmin_gpu.mojo` | MOCO-2397 | (no reason given) |
| `test_argsort.mojo` | MOCO-2366 | (no reason given) |
| `test_concat.mojo` | MOCO-2411 | segfaults on Apple GPU remote workers |
| `test_flash_attention.mojo` | MOCO-3049 | (no reason given) |
| `test_fused_qk_rope.mojo` | MOCO-3104 | (no reason given) |
| `test_fused_qk_rope_ragged.mojo` | MOCO-3104 | (no reason given) |
| `test_gather_nd_oob.mojo` | MOCO-2366 | (no reason given) |
| `test_gemv_partial_norm.mojo` |  | (no reason given) |
| `test_group_norm.mojo` | MOCO-3587 | Metal compilation failure |
| `test_gumbel_argmax_from_probs.mojo` |  | Bounded masked DRAM->SRAM copy proof; the masked `cp.async` zero-fill |
| `test_layer_norm_rope_ragged.mojo` | KERN-3390 | (no reason given) |
| `test_learnable_2d_interp_pos_emb.mojo` |  | (no reason given) |
| `test_mha_chunked_causal_mask.mojo` | KERN-3062 | flash attention numerically diverges on Metal |
| `test_mha_mask.mojo` | KERN-2031 | (no reason given) |
| `test_mha_sink_weights.mojo` |  | (no reason given) |
| `test_mha_tile_scheduler.mojo` | MOCO-2405 | (no reason given) |
| `test_mla.mojo` |  | (no reason given) |
| `test_moe_indices.mojo` | MOCO-2489 | (no reason given) |
| `test_padding_gpu.mojo` | GEX-2562 | (no reason given) |
| `test_pool_gpu.mojo` |  | (no reason given) |
| `test_rms_norm_fused_fp8.mojo` | PRDT-506 | (no reason given) |
| `test_rms_norm_fused_residual_add.mojo` | KERN-2651 | Metal threadgroup memory limit (33032 > 32768) |
| `test_rms_norm_rope.mojo` | KERN-3390 | Row rms_norm_rope writes all zeros on Metal, at every tier. |
| `test_rope_split_store.mojo` |  | (no reason given) |
| `test_scatter_set_constant.mojo` | PRDT-506 | (no reason given) |
| `test_softmax.mojo` | PRDT-506 | (no reason given) |
| `test_sparse_indexer_common.mojo` |  | (no reason given) |
| `test_topk_bitonic.mojo` |  | (no reason given) |
| `test_topk_gpu.mojo` |  | Apple GPU shared memory limit (32768) exceeded by second stage top-k kernel |
| `test_topk_gpu_fi.mojo` | KERN-3121 | topk_topp_sampling_from_prob samples out-of-top-K index on Metal |
| `test_topk_topp_masked_probs.mojo` |  | `from_probs` refuses to build on Apple (`_block_reduce_topk` caps its |
| `test_topk_topp_sampling_with_dist.mojo` |  | (no reason given) |
| `test_toppminp_gpu.mojo` | MOCO-3650 | NaN in BFloat16 top-p sampling on Apple GPU |
| `test_tpool_patch_merger.mojo` |  | (no reason given) |
| `test_warp_bitonic_sort.mojo` |  | Block-wide bitonic sort top-k (topk_bitonic.mojo) — same constraint as above. |

## `max/kernels/test/gpu/quantization` (1)

| test | id | reason |
|---|---|---|
| `test_scaled_fp8_quantization.mojo` |  | (no reason given) |

## `max/kernels/test/gpu/state_space` (10)

| test | id | reason |
|---|---|---|
| `test_causal_conv1d.mojo` |  | (no reason given) |
| `test_causal_conv1d_update.mojo` |  | (no reason given) |
| `test_gated_delta.mojo` |  | (no reason given) |
| `test_gated_delta_conv1d.mojo` |  | (no reason given) |
| `test_mamba_split_conv1d_scan_combined.mojo` |  | (no reason given) |
| `test_rms_norm_fused_residual.mojo` |  | (no reason given) |
| `test_selective_scan.mojo` |  | (no reason given) |
| `test_ssd_combined.mojo` |  | (no reason given) |
| `test_varlen_causal_conv1d.mojo` |  | (no reason given) |
| `test_varlen_selective_scan.mojo` |  | (no reason given) |

