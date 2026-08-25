# Apple GPU corpus: what is relevant, and how it does

712 `.mojo.test` targets under `//max/kernels/test/gpu/...`.

Runnability comes from bazel (it honours constraints declared inline on a rule, which BUILD-dict parsing misses); the reason a target does not run comes from the BUILD files.

## Relevant to this fork

| outcome | count |
|---|---|
| pass | 78 |
| fail (ran, wrong or errored) | 18 |
| fail to build | 0 |
| **relevant total** | **96** |

**78/96 passing (81%).**

## Not run here

| category | count | meaning |
|---|---|---|
| off-on-apple | 97 | in scope, switched off in BUILD with a named defect — the real backlog |
| other-vendor | 482 | NVIDIA/AMD/Qualcomm; each has its own fork, out of scope here |
| needs-more-gpus | 37 | multi-GPU / NVSHMEM; single-GPU machine |

## Failing now

| target | outcome |
|---|---|
| `test_accelerator_arch_cli_kernels.mojo.test` (basics) | fail |
| `test_amd_block_sync_lds.mojo.test` (compile) | fail |
| `test_elementwise_trace_description.mojo.test` (compile) | fail |
| `test_mha_decoding_vs_naive.mojo.test` (kv_cache) | fail |
| `test_apple_fp4_matmul.mojo.test` (linalg) | fail |
| `test_apple_gpu_matmul.mojo.test` (linalg) | fail |
| `test_apple_int8_matmul.mojo.test` (linalg) | fail |
| `test_grouped_matmul_apple_fp8.mojo.test` (linalg) | fail |
| `attention/test_naive_fa_decode_apple.mojo.test` (nn) | fail |
| `test_apple_fa_prefill.mojo.test` (nn) | fail |
| `test_apple_fa_prefill_paged.mojo.test` (nn) | fail |
| `test_conv_grouped.mojo.test` (nn) | fail |
| `test_fused_qk_rms_norm_rope.mojo.test` (nn) | fail |
| `test_gather.mojo.test` (nn) | fail |
| `test_index_tensor.mojo.test` (nn) | fail |
| `test_layer_norm.mojo.test` (nn) | fail |
| `test_rms_norm.mojo.test` (nn) | fail |
| `test_mamba2_ssd_scan.mojo.test` (state_space) | fail |

## Switched off on Apple (the backlog)

| test | id | reason |
|---|---|---|
| `test_launch_binary.mojo.test` |  | Requires metallib tool which may not be available on Mac |
| `test_prefix_sum.mojo.test` |  | llvm.ctlz intrinsic not evaluating at compile time on macOS |
| `test_shuffle.mojo.test` |  | llvm.ctlz intrinsic not evaluating at compile time on macOS |
| `test_simd_reduction.mojo.test` |  | llvm.ctlz intrinsic not evaluating at compile time on macOS |
| `test_verify_buffers_gpu.mojo.test` |  | Uses block.sum/block.max (llvm.ctlz issue) |
| `test_device_graph_builder.mojo.test` |  | Metal does not support device graph builder |
| `test_external_stream.mojo.test` |  | Metal does not support external streams |
| `test_function_attributes.mojo.test` |  | — |
| `test_occupancy_max_active_blocks.mojo.test` |  | occupancy query not implemented for Metal |
| `test_matmul_kernel_10.mojo.test` |  | — |
| `test_grouped_matmul_tile_scheduler.mojo.test` |  | — |
| `test_multistage_gemm_kernel.mojo.test` |  | long running on MacOS |
| `test_apply_packed_bitmask.mojo.test` |  | — |
| `test_gemv_partial_norm.mojo.test` |  | — |
| `test_gumbel_argmax_from_probs.mojo.test` |  | — |
| `test_learnable_2d_interp_pos_emb.mojo.test` |  | — |
| `test_mha_sink_weights.mojo.test` |  | — |
| `test_mla.mojo.test` |  | — |
| `test_pool_gpu.mojo.test` |  | — |
| `test_rope_split_store.mojo.test` |  | — |
| `test_sparse_indexer_common.mojo.test` |  | — |
| `test_topk_bitonic.mojo.test` |  | — |
| `test_topk_gpu.mojo.test` |  | Apple GPU shared memory limit (32768) exceeded by second stage top-k kernel |
| `test_topk_topp_masked_probs.mojo.test` |  | — |
| `test_topk_topp_sampling_with_dist.mojo.test` |  | — |
| `test_tpool_patch_merger.mojo.test` |  | — |
| `test_warp_bitonic_sort.mojo.test` |  | — |
| `test_scaled_fp8_quantization.mojo.test` |  | — |
| `test_causal_conv1d.mojo.test` |  | — |
| `test_causal_conv1d_update.mojo.test` |  | — |
| `test_gated_delta.mojo.test` |  | — |
| `test_gated_delta_conv1d.mojo.test` |  | — |
| `test_mamba_split_conv1d_scan_combined.mojo.test` |  | — |
| `test_rms_norm_fused_residual.mojo.test` |  | — |
| `test_selective_scan.mojo.test` |  | — |
| `test_ssd_combined.mojo.test` |  | — |
| `test_varlen_causal_conv1d.mojo.test` |  | — |
| `test_varlen_selective_scan.mojo.test` |  | — |
| `test_device_stream.mojo.test` | GEX-2554 | — |
| `test_device_event.mojo.test` | GEX-2555 | — |
| `test_device_context_sub_buffer.mojo.test` | GEX-2562 | — |
| `test_padding_gpu.mojo.test` | GEX-2562 | — |
| `test_mha_mask.mojo.test` | KERN-2031 | — |
| `test_kv_cache_ragged_matmul_scale.mojo.test` | KERN-2318 | — |
| `test_init_vector_gpu.mojo.test` | KERN-2360 | MetalAIRPass address space propagation bug |
| `test_compile_to_llvm_codegen.mojo.test` | KERN-2360 | external_memory is not supported on Apple silicon |
| `test_rms_norm_fused_residual_add.mojo.test` | KERN-2651 | Metal threadgroup memory limit (33032 > 32768) |
| `test_tile_io.mojo.test` | KERN-2834 | — |
| `test_tile_io_copy.mojo.test` | KERN-2834 | — |
| `test_mha_chunked_causal_mask.mojo.test` | KERN-3062 | flash attention numerically diverges on Metal |
| `test_topk_gpu_fi.mojo.test` | KERN-3121 | topk_topp_sampling_from_prob samples out-of-top-K index on Metal |
| `test_layer_norm_rope_ragged.mojo.test` | KERN-3390 | — |
| `test_rms_norm_rope.mojo.test` | KERN-3390 | Row rms_norm_rope writes all zeros on Metal, at every tier. |
| `test_print_elementwise.mojo.test` | MOCO-2366 | — |
| `test_linalg_matmul_gpu.mojo.test` | MOCO-2366 | — |
| `test_argsort.mojo.test` | MOCO-2366 | — |
| `test_gather_nd_oob.mojo.test` | MOCO-2366 | — |
| `test_matmul_int.mojo.test` | MOCO-2397 | — |
| `test_argmax_streaming_gpu.mojo.test` | MOCO-2397 | same argmax path as test_argmaxmin_gpu.mojo |
| `test_argmaxmin_gpu.mojo.test` | MOCO-2397 | — |
| `test_capture_trait_type.mojo.test` | MOCO-2405 | — |
| `test_debug_assert_gpu_error.mojo.test` | MOCO-2405 | — |
| `test_print.mojo.test` | MOCO-2405 | — |
| `test_printf.mojo.test` | MOCO-2405 | — |
| `test_matmul_tile_scheduler.mojo.test` | MOCO-2405 | — |
| `test_mha_tile_scheduler.mojo.test` | MOCO-2405 | — |
| `test_split_k_reduce.mojo.test` | MOCO-2411 | bfloat16 numerical mismatch on Apple GPU |
| `test_concat.mojo.test` | MOCO-2411 | segfaults on Apple GPU remote workers |
| `test_double_buffer_gemm.mojo.test` | MOCO-2415 | — |
| `test_matmul.mojo.test` | MOCO-2415 | — |
| `test_moe_indices.mojo.test` | MOCO-2489 | — |
| `test_flash_attention.mojo.test` | MOCO-3049 | — |
| `test_fused_qk_rope.mojo.test` | MOCO-3104 | — |
| `test_fused_qk_rope_ragged.mojo.test` | MOCO-3104 | — |
| `test_kv_cache_2m_iadd.mojo.test` | MOCO-3187 | — |
| `test_kv_cache_radd.mojo.test` | MOCO-3187 | — |
| `test_kv_cache_store_ragged.mojo.test` | MOCO-3187 | — |
| `test_fast_div.mojo.test` | MOCO-3587 | Metal compilation failure (originally wrong FastDiv remainder) |
| `test_gemv.mojo.test` | MOCO-3587 | Metal compilation failure |
| `test_group_norm.mojo.test` | MOCO-3587 | Metal compilation failure |
| `test_toppminp_gpu.mojo.test` | MOCO-3650 | NaN in BFloat16 top-p sampling on Apple GPU |
| `test_strided_load.mojo.test` | MOCO-3878 | Metal IR does not contain @llvm.masked.gather |
| `test_grouped_matmul_rowwise_scaled_fp8.mojo.test` | MOCO-4405 | Metal compile exceeds the 900s ceiling since the |
| `test_batch_kv_cache_flash_attention.mojo.test` | PRDT-506 | — |
| `test_batch_kv_cache_flash_attention_causal_mask.mojo.test` | PRDT-506 | — |
| `test_kv_cache_matmul.mojo.test` | PRDT-506 | — |
| `test_layout_mma.mojo.test` | PRDT-506 | — |
| `test_layout_tensor_copy.mojo.test` | PRDT-506 | — |
| `test_tensor_gpu.mojo.test` | PRDT-506 | — |
| `test_batched_matmul.mojo.test` | PRDT-506 | — |
| `test_gemv2.mojo.test` | PRDT-506 | — |
| `test_grouped_matmul_vendor.mojo.test` | PRDT-506 | — |
| `test_matmul.mojo.test` | PRDT-506 | — |
| `test_matmul_custom.mojo.test` | PRDT-506 | — |
| `test_rms_norm_fused_fp8.mojo.test` | PRDT-506 | — |
| `test_scatter_set_constant.mojo.test` | PRDT-506 | — |
| `test_softmax.mojo.test` | PRDT-506 | — |
