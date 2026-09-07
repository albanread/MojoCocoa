# Apple GPU test run

320 in-scope tests executed directly (bazel built them; this runner ran them). 186 vendor-owned test(s) were excluded -- see the end of this file.

| outcome | count |
|---|---|
| pass | 79 |
| partial | 2 |
| unverified | 6 |
| vacuous | 1 |
| fail | 15 |
| pso | 4 |
| build-failure | 26 |
| blocked | 187 |

**81 of 126 ran real work, checked it, and passed.** Excluded from that: 1 vacuous skip(s), 6 test(s) that exit 0 with nothing that could fail them, and 187 that bazel refuses to build here at all.


## fail (15)

| test | detail |
|---|---|
| `test_accelerator_arch_cli_kernels.mojo.test` |   Failed: 1 (100.00%) |
| `test_elementwise_trace_description.mojo.test` |   Failed: 1 (100.00%) |
| `positive_control_poison_uninit.mojo.test` | Unhandled exception caught during execution: expected all 16 elements to be NaN under poison; got 0 |
| `fuzz_sparse_indexer.mojo.test` | Unhandled exception caught during execution: output tail must be -1 |
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

## pso (4)

| test | detail |
|---|---|
| `test_apple_fp4_matmul.mojo.test` | == FAILED test_stage4_dispatch_paths: At max/mojo/max/gpu/host/_device_context_extras.mojo:168:17: AppleGPURT[ |
| `test_apple_fa_prefill.mojo.test` | Unhandled exception caught during execution: At max/mojo/max/gpu/host/_device_context_extras.mojo:168:17: Appl |
| `test_apple_fa_prefill_paged.mojo.test` | Unhandled exception caught during execution: At max/mojo/max/gpu/host/_device_context_extras.mojo:168:17: Appl |
| `test_mamba2_ssd_scan.mojo.test` | At max/mojo/max/gpu/host/_device_context_extras.mojo:168:17: AppleGPURT[metal]: newComputePipelineStateWithFun |

## build-failure (26)

| test | detail |
|---|---|
| `test_convert.mojo.test` | no binary produced |
| `test_invariant_load.mojo.test` | no binary produced |
| `test_load_width_codegen.mojo.test` | no binary produced |
| `test_metal_print.mojo.test` | wrapper target: max/kernels/test/gpu/basics/test_metal_print.mojo.test.binary was not produced |
| `test_sync.mojo.test` | wrapper target: max/kernels/test/gpu/basics/test_sync.mojo.test.binary was not produced |
| `test_compile_gcn.mojo.test` | wrapper target: max/kernels/test/gpu/compile/test_compile_gcn.mojo.test.binary was not produced |
| `test_compile_nvptx_debuginfo.mojo.test` | wrapper target: max/kernels/test/gpu/compile/test_compile_nvptx_debuginfo.mojo.test.binary was not produced |
| `test_multimem.mojo.test` | no binary produced |
| `test_readfirstlane.mojo.test` | no binary produced |
| `test_register_intrinsics.mojo.test` | no binary produced |
| `test_sleep_intrinsics.mojo.test` | no binary produced |
| `test_time.mojo.test` | no binary produced |
| `test_scatterND.mojo.test` | no binary produced |
| `fuzz_attn_res_mix.mojo.test` | - Kernels/lib/attn_res and referenced by '//max/kernels/test/gpu/fuzz:fuzz_attn_res_mix.mojo.test' |
| `fuzz_ep_combine.mojo.test` | no binary produced |
| `fuzz_topk_sampling.mojo.test` | no binary produced |
| `fuzz_topk_topp_masked_probs.mojo.test` | no binary produced |
| `fuzz_topk_topp_sampling_dist.mojo.test` | no binary produced |
| `test_coord_codegen.mojo.test` | no binary produced |
| `test_new_layout_codegen.mojo.test` | no binary produced |
| `test_multistage_gemm_fp8.mojo.test` | no binary produced |
| `test_prefetch.mojo.test` | no binary produced |
| `test_shared_mem_barrier.mojo.test` | wrapper target: max/kernels/test/gpu/memory/test_shared_mem_barrier.mojo.test.binary was not produced |
| `test_tma_ops.mojo.test` | wrapper target: max/kernels/test/gpu/memory/test_tma_ops.mojo.test.binary was not produced |
| `test_attn_res_mix.mojo.test` | - Kernels/lib/attn_res and referenced by '//max/kernels/test/gpu/nn:test_attn_res_mix.mojo.test' |
| `test_topk_topp_degenerate_row.mojo.test` | no binary produced |

## vacuous (1)

| test | detail |
|---|---|
| `attention/test_naive_fa_decode_apple_sink.mojo.test` | SKIP: Apple M5 required |

## unverified (6)

| test | detail |
|---|---|
| `test_gpu_mem_alloc_validation.mojo.test` | exit 0, but the source has no assertion, no CHECK line and no failure path |
| `positive_control_memcheck_oob.mojo.test` | exit 0, but the source has no assertion, no CHECK line and no failure path |
| `fuzz_moe_indices.mojo.test` | exit 0, but the source has no assertion, no CHECK line and no failure path |
| `fuzz_oob_canary.mojo.test` | exit 0, but the source has no assertion, no CHECK line and no failure path |
| `repro_decode_hang.mojo.test` | exit 0, but the source has no assertion, no CHECK line and no failure path |
| `issue_32811.mojo.test` | exit 0, but the source has no assertion, no CHECK line and no failure path |

## partial (2)

| test | detail |
|---|---|
| `test_apple_mma_fragment.mojo.test` | SKIP: requires Apple M5 + Metal 4 == test_mma_1x1 SKIP: requires Apple M5 + Metal 4 == tes |
| `test_conv2d_im2col_apple.mojo.test` | SKIP: dispatcher declined this shape (1x1 / K<16 / N<16) == bf16 3x3 s1 same-pad C64->1 |

## blocked (187)

| test | detail |
|---|---|
| `test_cluster.mojo.test` | bazel declares it incompatible with this platform |
| `test_allgather.mojo.test` | bazel declares it incompatible with this platform |
| `test_allgather_rmsnorm.mojo.test` | bazel declares it incompatible with this platform |
| `test_allgather_rmsnorm_mxfp8.mojo.test` | bazel declares it incompatible with this platform |
| `test_allreduce.mojo.test` | bazel declares it incompatible with this platform |
| `test_allreduce_determinism.mojo.test` | bazel declares it incompatible with this platform |
| `test_allreduce_residual_rmsnorm.mojo.test` | bazel declares it incompatible with this platform |
| `test_broadcast.mojo.test` | bazel declares it incompatible with this platform |
| `test_broadcast_subgroup.mojo.test` | bazel declares it incompatible with this platform |
| `test_fused_lamport_rmsnorm.mojo.test` | bazel declares it incompatible with this platform |
| `test_lamport_allreduce.mojo.test` | bazel declares it incompatible with this platform |
| `test_lamport_pingpong.mojo.test` | bazel declares it incompatible with this platform |
| `test_multimem_allreduce.mojo.test` | bazel declares it incompatible with this platform |
| `test_multimem_reducescatter.mojo.test` | bazel declares it incompatible with this platform |
| `test_p2p_copy.mojo.test` | bazel declares it incompatible with this platform |
| `test_p2p_ep_combine.mojo.test` | bazel declares it incompatible with this platform |
| `test_p2p_ep_dispatch.mojo.test` | bazel declares it incompatible with this platform |
| `test_p2p_ep_skip_a2a.mojo.test` | bazel declares it incompatible with this platform |
| `test_reducescatter.mojo.test` | bazel declares it incompatible with this platform |
| `test_reducescatter_rmsnorm.mojo.test` | bazel declares it incompatible with this platform |
| `test_scatter.mojo.test` | bazel declares it incompatible with this platform |
| `test_device_external_function.mojo.test` | bazel declares it incompatible with this platform |
| `test_function_error.mojo.test` | bazel declares it incompatible with this platform |
| `test_function_error_sync_mode.mojo.test` | bazel declares it incompatible with this platform |
| `fuzz_block_scaled_fp4.mojo.test` | bazel declares it incompatible with this platform |
| `fuzz_block_scaled_mxfp8.mojo.test` | bazel declares it incompatible with this platform |
| `fuzz_fused_qkv_index_matmul_mxfp8.mojo.test` | bazel declares it incompatible with this platform |
| `fuzz_fused_qkv_matmul_mxfp8.mojo.test` | bazel declares it incompatible with this platform |
| `fuzz_fused_swiglu_dispatch.mojo.test` | bazel declares it incompatible with this platform |
| `fuzz_fused_swiglu_mxfp8.mojo.test` | bazel declares it incompatible with this platform |
| `fuzz_gemv_split_k.mojo.test` | bazel declares it incompatible with this platform |
| `fuzz_grouped_matmul_mxfp8.mojo.test` | bazel declares it incompatible with this platform |
| `fuzz_matmul.mojo.test` | bazel declares it incompatible with this platform |
| `fuzz_mla_decode.mojo.test` | bazel declares it incompatible with this platform |
| `fuzz_msa_decode.mojo.test` | bazel declares it incompatible with this platform |
| `fuzz_msa_prefill.mojo.test` | bazel declares it incompatible with this platform |
| `fuzz_mxfp8_quantize.mojo.test` | bazel declares it incompatible with this platform |
| `fuzz_sparse_indexer_decode.mojo.test` | bazel declares it incompatible with this platform |
| `fuzz_sparse_indexer_prefill.mojo.test` | bazel declares it incompatible with this platform |
| `test_batch_kv_cache_flash_attention_causal_mask_ragged_fp8.mojo.test` | bazel declares it incompatible with this platform |
| `test_batch_kv_cache_flash_attention_causal_mask_ragged_paged_ps128_hs128.mojo.test` | bazel declares it incompatible with this platform |
| `test_batch_kv_cache_flash_attention_causal_mask_ragged_paged_ps128_hs256.mojo.test` | bazel declares it incompatible with this platform |
| `test_batch_kv_cache_flash_attention_causal_mask_ragged_paged_ps128_hs512.mojo.test` | bazel declares it incompatible with this platform |
| `test_batch_kv_cache_flash_attention_causal_mask_ragged_paged_ps128_hs64.mojo.test` | bazel declares it incompatible with this platform |
| `test_batch_kv_cache_flash_attention_causal_mask_ragged_paged_ps16_hs128.mojo.test` | bazel declares it incompatible with this platform |
| `test_batch_kv_cache_flash_attention_causal_mask_ragged_paged_ps16_hs256.mojo.test` | bazel declares it incompatible with this platform |
| `test_batch_kv_cache_flash_attention_causal_mask_ragged_paged_ps16_hs512.mojo.test` | bazel declares it incompatible with this platform |
| `test_batch_kv_cache_flash_attention_causal_mask_ragged_paged_ps16_hs64.mojo.test` | bazel declares it incompatible with this platform |
| `test_batch_kv_cache_flash_attention_causal_mask_ragged_paged_ps256_hs128.mojo.test` | bazel declares it incompatible with this platform |
| `test_batch_kv_cache_flash_attention_causal_mask_ragged_paged_ps256_hs256.mojo.test` | bazel declares it incompatible with this platform |
| `test_batch_kv_cache_flash_attention_causal_mask_ragged_paged_ps256_hs512.mojo.test` | bazel declares it incompatible with this platform |
| `test_batch_kv_cache_flash_attention_causal_mask_ragged_paged_ps256_hs64.mojo.test` | bazel declares it incompatible with this platform |
| `test_batch_kv_cache_flash_attention_causal_mask_ragged_paged_ps256_hs80.mojo.test` | bazel declares it incompatible with this platform |
| `test_batch_kv_cache_flash_attention_causal_mask_ragged_paged_ps64_hs128.mojo.test` | bazel declares it incompatible with this platform |
| `test_batch_kv_cache_flash_attention_causal_mask_ragged_paged_ps64_hs256.mojo.test` | bazel declares it incompatible with this platform |
| `test_batch_kv_cache_flash_attention_causal_mask_ragged_paged_ps64_hs512.mojo.test` | bazel declares it incompatible with this platform |
| `test_batch_kv_cache_flash_attention_causal_mask_ragged_paged_ps64_hs64.mojo.test` | bazel declares it incompatible with this platform |
| `test_kv_cache_ragged_matmul_bf16_fused_cont.mojo.test` | bazel declares it incompatible with this platform |
| `test_kv_cache_ragged_matmul_bf16_fused_paged.mojo.test` | bazel declares it incompatible with this platform |
| `test_kv_cache_ragged_matmul_bf16_k_paged.mojo.test` | bazel declares it incompatible with this platform |
| `test_kv_cache_ragged_matmul_bf16_kv_cont.mojo.test` | bazel declares it incompatible with this platform |
| `test_kv_cache_ragged_matmul_fp32_fused_cont.mojo.test` | bazel declares it incompatible with this platform |
| `test_kv_cache_ragged_matmul_fp32_fused_paged.mojo.test` | bazel declares it incompatible with this platform |
| `test_kv_cache_ragged_matmul_fp32_k_paged.mojo.test` | bazel declares it incompatible with this platform |
| `test_kv_cache_ragged_matmul_fp32_kv_cont.mojo.test` | bazel declares it incompatible with this platform |
| `test_mha_gemma4_shapes_ps128_causal.mojo.test` | bazel declares it incompatible with this platform |
| `test_mha_gemma4_shapes_ps128_sliding_1024.mojo.test` | bazel declares it incompatible with this platform |
| `test_mha_gemma4_shapes_ps256_causal.mojo.test` | bazel declares it incompatible with this platform |
| `test_mha_gemma4_shapes_ps256_sliding_1024.mojo.test` | bazel declares it incompatible with this platform |
| `test_mha_gemma4_shapes_ps64_causal.mojo.test` | bazel declares it incompatible with this platform |
| `test_mha_gemma4_shapes_ps64_sliding_1024.mojo.test` | bazel declares it incompatible with this platform |
| `test_mha_inflight_batching_gemma3_hang_ps128.mojo.test` | bazel declares it incompatible with this platform |
| `test_mha_inflight_batching_gemma3_hang_ps256.mojo.test` | bazel declares it incompatible with this platform |
| `test_mha_inflight_batching_gemma3_hang_ps64.mojo.test` | bazel declares it incompatible with this platform |
| `test_mha_paged_kv_oob_canary_ps128_causal.mojo.test` | bazel declares it incompatible with this platform |
| `test_mha_paged_kv_oob_canary_ps128_sliding_1024.mojo.test` | bazel declares it incompatible with this platform |
| `test_mha_paged_kv_oob_canary_ps256_causal.mojo.test` | bazel declares it incompatible with this platform |
| `test_mha_paged_kv_oob_canary_ps256_sliding_1024.mojo.test` | bazel declares it incompatible with this platform |
| `test_mha_paged_kv_oob_canary_ps64_causal.mojo.test` | bazel declares it incompatible with this platform |
| `test_mha_paged_kv_oob_canary_ps64_sliding_1024.mojo.test` | bazel declares it incompatible with this platform |
| `test_paged_kv_null_block_sentinel.mojo.test` | bazel declares it incompatible with this platform |
| `test_paged_lut_load_boundary_ps128.mojo.test` | bazel declares it incompatible with this platform |
| `test_paged_lut_load_boundary_ps16.mojo.test` | bazel declares it incompatible with this platform |
| `test_paged_lut_load_boundary_ps256.mojo.test` | bazel declares it incompatible with this platform |
| `test_paged_lut_load_boundary_ps32.mojo.test` | bazel declares it incompatible with this platform |
| `test_paged_lut_load_boundary_ps64.mojo.test` | bazel declares it incompatible with this platform |
| `test_stmatrix.mojo.test` | bazel declares it incompatible with this platform |
| `test_tensor_core_mi300x.mojo.test` | bazel declares it incompatible with this platform |
| `test_tensormap_replace_insts.mojo.test` | bazel declares it incompatible with this platform |
| `test_tma_3d_async_copy.mojo.test` | bazel declares it incompatible with this platform |
| `test_tma_4d_async_copy.mojo.test` | bazel declares it incompatible with this platform |
| `test_tma_5d_async_copy.mojo.test` | bazel declares it incompatible with this platform |
| `test_tma_async.mojo.test` | bazel declares it incompatible with this platform |
| `test_tma_async_mc.mojo.test` | bazel declares it incompatible with this platform |
| `test_tma_mc_swizzle.mojo.test` | bazel declares it incompatible with this platform |
| `test_tma_swizzle.mojo.test` | bazel declares it incompatible with this platform |
| `2_tensor_core.mojo.test` | bazel declares it incompatible with this platform |
| `3_swizzling.mojo.test` | bazel declares it incompatible with this platform |
| `4_tma_stmatrix.mojo.test` | bazel declares it incompatible with this platform |
| `5_2sm.mojo.test` | bazel declares it incompatible with this platform |
| `6_2sm_pipelined.mojo.test` | bazel declares it incompatible with this platform |
| `7_double_buf_writeout.mojo.test` | bazel declares it incompatible with this platform |
| `8_clc_tmem_ping.mojo.test` | bazel declares it incompatible with this platform |
| `test_block_scaled_matmul_mxfp8_dispatch.mojo.test` | bazel declares it incompatible with this platform |
| `test_block_scaled_matmul_with_epilogue.mojo.test` | bazel declares it incompatible with this platform |
| `test_blockwise_fp8_1d2d_structured.mojo.test` | bazel declares it incompatible with this platform |
| `test_blockwise_fp8_bk64.mojo.test` | bazel declares it incompatible with this platform |
| `test_fused_silu_mxfp8_interleave.mojo.test` | bazel declares it incompatible with this platform |
| `test_grouped_block_scaled_gemm_epilogue.mojo.test` | bazel declares it incompatible with this platform |
| `test_grouped_block_scaled_gemm_execution.mojo.test` | bazel declares it incompatible with this platform |
| `test_grouped_matmul_1d1d_block_fp4_smoke.mojo.test` | bazel declares it incompatible with this platform |
| `test_grouped_matmul_dynamic_scaled_fp8.mojo.test` | bazel declares it incompatible with this platform |
| `test_grouped_matmul_swiglu_mxfp8_dispatch.mojo.test` | bazel declares it incompatible with this platform |
| `test_grouped_tile_scheduler.mojo.test` | bazel declares it incompatible with this platform |
| `test_matmul_pdl_race.mojo.test` | bazel declares it incompatible with this platform |
| `test_small_mn_gemms_row_oob.mojo.test` | bazel declares it incompatible with this platform |
| `test_tma_im2col_unit.mojo.test` | bazel declares it incompatible with this platform |
| `test_async_cpy_wait_group.mojo.test` | bazel declares it incompatible with this platform |
| `test_buffer_io.mojo.test` | bazel declares it incompatible with this platform |
| `test_copy_async.mojo.test` | bazel declares it incompatible with this platform |
| `test_cp_async_bulk.mojo.test` | bazel declares it incompatible with this platform |
| `test_ldg_intrinsics.mojo.test` | bazel declares it incompatible with this platform |
| `test_ldmatrix_fp8.mojo.test` | bazel declares it incompatible with this platform |
| `test_load_cache.mojo.test` | bazel declares it incompatible with this platform |
| `test_semaphore_reduction.mojo.test` | bazel declares it incompatible with this platform |
| `test_sharedmem_async_cp.mojo.test` | bazel declares it incompatible with this platform |
| `test_tcgen05.mojo.test` | bazel declares it incompatible with this platform |
| `test_tma.mojo.test` | bazel declares it incompatible with this platform |
| `test_tma_block_reduce.mojo.test` | bazel declares it incompatible with this platform |
| `test_tma_gather4.mojo.test` | bazel declares it incompatible with this platform |
| `test_mha_causal_mask_depth_128.mojo.test` | bazel declares it incompatible with this platform |
| `test_mha_causal_mask_depth_256.mojo.test` | bazel declares it incompatible with this platform |
| `test_mha_causal_mask_depth_512.mojo.test` | bazel declares it incompatible with this platform |
| `test_mha_causal_mask_depth_64.mojo.test` | bazel declares it incompatible with this platform |
| `test_mha_causal_mask_depth_72.mojo.test` | bazel declares it incompatible with this platform |
| `test_mha_causal_mask_depth_80.mojo.test` | bazel declares it incompatible with this platform |
| `test_mha_causal_mask_depth_96.mojo.test` | bazel declares it incompatible with this platform |
| `test_mla_decode_paged_variable_ps128.mojo.test` | bazel declares it incompatible with this platform |
| `test_mla_prefill_blockscale_large_cache_ps256.mojo.test` | bazel declares it incompatible with this platform |
| `test_mla_prefill_blockscale_paged_ps128.mojo.test` | bazel declares it incompatible with this platform |
| `test_mla_prefill_blockscale_paged_ps16.mojo.test` | bazel declares it incompatible with this platform |
| `test_mla_prefill_blockscale_paged_ps256.mojo.test` | bazel declares it incompatible with this platform |
| `test_mla_prefill_blockscale_paged_ps32.mojo.test` | bazel declares it incompatible with this platform |
| `test_mla_prefill_blockscale_paged_ps64.mojo.test` | bazel declares it incompatible with this platform |
| `test_mla_prefill_generic_paged_ps128.mojo.test` | bazel declares it incompatible with this platform |
| `test_mla_prefill_generic_paged_ps16.mojo.test` | bazel declares it incompatible with this platform |
| `test_mla_prefill_generic_paged_ps256.mojo.test` | bazel declares it incompatible with this platform |
| `test_mla_prefill_generic_paged_ps32.mojo.test` | bazel declares it incompatible with this platform |
| `test_mla_prefill_generic_paged_ps64.mojo.test` | bazel declares it incompatible with this platform |
| `test_mla_prefill_per_token_scale_paged_ps128.mojo.test` | bazel declares it incompatible with this platform |
| `test_mla_prefill_per_token_scale_paged_ps16.mojo.test` | bazel declares it incompatible with this platform |
| `test_mla_prefill_per_token_scale_paged_ps256.mojo.test` | bazel declares it incompatible with this platform |
| `test_mla_prefill_per_token_scale_paged_ps32.mojo.test` | bazel declares it incompatible with this platform |
| `test_mla_prefill_per_token_scale_paged_ps64.mojo.test` | bazel declares it incompatible with this platform |
| `test_mla_prefill_vhead_repro_ps128.mojo.test` | bazel declares it incompatible with this platform |
| `test_mla_prefill_vhead_repro_ps64.mojo.test` | bazel declares it incompatible with this platform |
| `test_e2m1_conversion.mojo.test` | bazel declares it incompatible with this platform |
| `test_e4m3fn_conversion.mojo.test` | bazel declares it incompatible with this platform |
| `test_e4m3fn_to_e4m3fnuz_conversion.mojo.test` | bazel declares it incompatible with this platform |
| `test_e4m3fnuz_conversion.mojo.test` | bazel declares it incompatible with this platform |
| `test_e5m2_conversion.mojo.test` | bazel declares it incompatible with this platform |
| `test_e5m2fnuz_conversion.mojo.test` | bazel declares it incompatible with this platform |
| `test_fp8_nan.mojo.test` | bazel declares it incompatible with this platform |
| `test_ue8m0_conversion.mojo.test` | bazel declares it incompatible with this platform |
| `test_multistage_gemm_q.mojo.test` | bazel declares it incompatible with this platform |
| `test_ep_combine_ordering.mojo.test` | bazel declares it incompatible with this platform |
| `test_mx_ep_wait_scale_fusion.mojo.test` | bazel declares it incompatible with this platform |
| `test_mxfp4_fused_silu_scale_fusion.mojo.test` | bazel declares it incompatible with this platform |
| `test_mxfp6_fused_silu.mojo.test` | bazel declares it incompatible with this platform |
| `test_mxfp6_send_buf.mojo.test` | bazel declares it incompatible with this platform |
| `test_mxfp8_fused_silu_scale_fusion.mojo.test` | bazel declares it incompatible with this platform |
| `test_mxfp8_scale_overflow_probe.mojo.test` | bazel declares it incompatible with this platform |
| `test_shmem_buffer.mojo.test` | bazel declares it incompatible with this platform |
| `test_shmem_gpu_per_thread.mojo.test` | bazel declares it incompatible with this platform |
| `test_shmem_put_block.mojo.test` | bazel declares it incompatible with this platform |
| `test_load_to_lds.mojo.test` | bazel declares it incompatible with this platform |
| `test_mask_applier_unit.mojo.test` | bazel declares it incompatible with this platform |
| `test_mfma_fragment_lane_mapping.mojo.test` | bazel declares it incompatible with this platform |
| `test_mha_mma_op_fp8.mojo.test` | bazel declares it incompatible with this platform |
| `test_mha_softmax_unit.mojo.test` | bazel declares it incompatible with this platform |
| `test_mha_vs_naive_reference.mojo.test` | bazel declares it incompatible with this platform |
| `test_mma_op_unit.mojo.test` | bazel declares it incompatible with this platform |
| `test_ps_metadata.mojo.test` | bazel declares it incompatible with this platform |
| `test_pv_chain_fp32_ref.mojo.test` | bazel declares it incompatible with this platform |
| `test_q_loader_lane_layout.mojo.test` | bazel declares it incompatible with this platform |
| `test_qk_chain_fp32_ref.mojo.test` | bazel declares it incompatible with this platform |
| `test_v227_adapter_round_trip.mojo.test` | bazel declares it incompatible with this platform |

## excluded as another vendor's

| test | outcome here | why |
|---|---|---|
| `test_fast_div_ptx.mojo.test` | build-failure | vendor token in the test name |
| `test_has_sm100_or_newer.mojo.test` | pass | vendor token in the test name |
| `test_is_sm90.mojo.test` | build-failure | vendor token in the test name |
| `test_amd_asan_oob.mojo.test` | pass | vendor token in the test name |
| `test_amd_block_sync_lds.mojo.test` | fail | vendor token in the test name |
| `test_compile_via_param.mojo.test` | pass | lit REQUIRES: NVIDIA-GPU |
| `fuzz_grouped_matmul_sm100_w4a8.mojo.test` | blocked | vendor token in the test name |
| `test_mha_gemma4_shapes_amd_repro.mojo.test` | blocked | vendor token in the test name |
| `test_tensor_core_sm90.mojo.test` | blocked | vendor token in the test name |
| `test_wgmma.mojo.test` | blocked | vendor token in the test name |
| `test_wgmma_int8_uint8_layouts.mojo.test` | blocked | vendor token in the test name |
| `test_wgmma_layouts.mojo.test` | blocked | vendor token in the test name |
| `test_wgmma_with_static_tuple_output_bf16.mojo.test` | blocked | vendor token in the test name |
| `test_wgmma_with_static_tuple_output_fp8.mojo.test` | blocked | vendor token in the test name |
| `1_naive_sm100.mojo.test` | blocked | vendor token in the test name |
| `test_batched_matmul_sm100_scaled.mojo.test` | blocked | vendor token in the test name |
| `test_block_scaled_mma_amd_asm.mojo.test` | build-failure | vendor token in the test name |
| `test_bulk_mma_pair_cta_sm100.mojo.test` | blocked | vendor token in the test name |
| `test_grouped_block_scaled_gemm_nvfp4.mojo.test` | blocked | vendor token in the test name |
| `test_grouped_block_scaled_gemm_nvfp4_execution.mojo.test` | blocked | vendor token in the test name |
| `test_grouped_matmul_nvfp4_dispatch.mojo.test` | blocked | vendor token in the test name |
| `test_grouped_matmul_sm100_block_fp4.mojo.test` | blocked | vendor token in the test name |
| `test_grouped_matmul_sm100_blockwise_fp8.mojo.test` | blocked | vendor token in the test name |
| `test_grouped_matmul_sm100_mxfp8.mojo.test` | blocked | vendor token in the test name |
| `test_grouped_matmul_sm100_w4a8.mojo.test` | blocked | vendor token in the test name |
| `test_grouped_matmul_swiglu_nvfp4_dispatch.mojo.test` | blocked | vendor token in the test name |
| `test_grouped_matmul_swiglu_nvfp4_interleave.mojo.test` | blocked | vendor token in the test name |
| `test_lora_expand_qkv_sm100.mojo.test` | blocked | vendor token in the test name |
| `test_lora_shrink_qkv_permute_3mn_sm100.mojo.test` | pass | vendor token in the test name |
| `test_matmul_sm100_1sm_bf16.mojo.test` | blocked | vendor token in the test name |
| `test_matmul_sm100_1sm_bf16_1d_bias.mojo.test` | blocked | vendor token in the test name |
| `test_matmul_sm100_1sm_bf16_bias.mojo.test` | blocked | vendor token in the test name |
| `test_matmul_sm100_1sm_bf16_ctype_fp8.mojo.test` | blocked | vendor token in the test name |
| `test_matmul_sm100_1sm_bf16_normal_epilogue.mojo.test` | blocked | vendor token in the test name |
| `test_matmul_sm100_1sm_bf16_with_weight_prefetch.mojo.test` | blocked | vendor token in the test name |
| `test_matmul_sm100_1sm_blockwise_fp8_part_a.mojo.test` | blocked | vendor token in the test name |
| `test_matmul_sm100_1sm_blockwise_fp8_part_b.mojo.test` | blocked | vendor token in the test name |
| `test_matmul_sm100_1sm_fp32.mojo.test` | blocked | vendor token in the test name |
| `test_matmul_sm100_1sm_fp32_1d_bias.mojo.test` | blocked | vendor token in the test name |
| `test_matmul_sm100_1sm_fp8.mojo.test` | blocked | vendor token in the test name |
| `test_matmul_sm100_1sm_fp8_normal_epilogue.mojo.test` | blocked | vendor token in the test name |
| `test_matmul_sm100_2sm_bf16.mojo.test` | blocked | vendor token in the test name |
| `test_matmul_sm100_2sm_bf16_1d_bias.mojo.test` | blocked | vendor token in the test name |
| `test_matmul_sm100_2sm_bf16_bias.mojo.test` | blocked | vendor token in the test name |
| `test_matmul_sm100_2sm_bf16_ctype_fp8.mojo.test` | blocked | vendor token in the test name |
| `test_matmul_sm100_2sm_bf16_normal_epilogue.mojo.test` | blocked | vendor token in the test name |
| `test_matmul_sm100_2sm_bf16_with_weight_prefetch.mojo.test` | blocked | vendor token in the test name |
| `test_matmul_sm100_2sm_blockwise_fp8_part_a.mojo.test` | blocked | vendor token in the test name |
| `test_matmul_sm100_2sm_blockwise_fp8_part_b.mojo.test` | blocked | vendor token in the test name |
| `test_matmul_sm100_2sm_fp32.mojo.test` | blocked | vendor token in the test name |
| `test_matmul_sm100_2sm_fp32_1d_bias.mojo.test` | blocked | vendor token in the test name |
| `test_matmul_sm100_2sm_fp8.mojo.test` | blocked | vendor token in the test name |
| `test_matmul_sm100_2sm_fp8_normal_epilogue.mojo.test` | blocked | vendor token in the test name |
| `test_matmul_sm100_batched_1sm_bf16.mojo.test` | blocked | vendor token in the test name |
| `test_matmul_sm100_batched_1sm_bf16_ctype_fp8.mojo.test` | blocked | vendor token in the test name |
| `test_matmul_sm100_batched_2sm_bf16.mojo.test` | blocked | vendor token in the test name |
| `test_matmul_sm100_batched_2sm_bf16_ctype_fp8.mojo.test` | blocked | vendor token in the test name |
| `test_matmul_sm100_batched_block_scaled_mxfp8.mojo.test` | blocked | vendor token in the test name |
| `test_matmul_sm100_batched_block_scaled_mxfp8_1sm.mojo.test` | blocked | vendor token in the test name |
| `test_matmul_sm100_batched_block_scaled_mxfp8_2sm.mojo.test` | blocked | vendor token in the test name |
| `test_matmul_sm100_batched_block_scaled_nvfp4.mojo.test` | blocked | vendor token in the test name |
| `test_matmul_sm100_batched_block_scaled_nvfp4_1sm.mojo.test` | blocked | vendor token in the test name |
| `test_matmul_sm100_batched_block_scaled_nvfp4_2sm.mojo.test` | blocked | vendor token in the test name |
| `test_matmul_sm100_block_scaled_fp4.mojo.test` | blocked | vendor token in the test name |
| `test_matmul_sm100_block_scaled_fp4_1sm_with_weight_prefetch.mojo.test` | blocked | vendor token in the test name |
| `test_matmul_sm100_block_scaled_fp4_2sm.mojo.test` | blocked | vendor token in the test name |
| `test_matmul_sm100_block_scaled_fp4_2sm_with_weight_prefetch.mojo.test` | blocked | vendor token in the test name |
| `test_matmul_sm100_block_scaled_fp4_small_bn.mojo.test` | blocked | vendor token in the test name |
| `test_matmul_sm100_block_scaled_fp4_small_bn_2sm.mojo.test` | blocked | vendor token in the test name |
| `test_matmul_sm100_block_scaled_fp4_small_bn_2sm_with_weight_prefetch.mojo.test` | blocked | vendor token in the test name |
| `test_matmul_sm100_block_scaled_fp4_small_bn_with_weight_prefetch.mojo.test` | blocked | vendor token in the test name |
| `test_matmul_sm100_block_scaled_mxfp8.mojo.test` | blocked | vendor token in the test name |
| `test_matmul_sm100_block_scaled_mxfp8_1sm.mojo.test` | blocked | vendor token in the test name |
| `test_matmul_sm100_block_scaled_mxfp8_2sm.mojo.test` | blocked | vendor token in the test name |
| `test_matmul_sm100_block_scaled_mxfp8_small_bn.mojo.test` | blocked | vendor token in the test name |
| `test_matmul_sm100_block_scaled_mxfp8_small_bn_2sm.mojo.test` | blocked | vendor token in the test name |
| `test_matmul_sm100_block_scaled_mxfp8_small_bn_with_weight_prefetch.mojo.test` | blocked | vendor token in the test name |
| `test_matmul_sm100_block_scaled_nvfp4_1sm.mojo.test` | blocked | vendor token in the test name |
| `test_matmul_sm100_block_scaled_nvfp4_with_weight_prefetch.mojo.test` | blocked | vendor token in the test name |
| `test_matmul_sm100_blockwise_fp8.mojo.test` | blocked | vendor token in the test name |
| `test_matmul_sm100_blockwise_fp8_smoke.mojo.test` | blocked | vendor token in the test name |
| `test_matmul_sm100_epilogue.mojo.test` | blocked | vendor token in the test name |
| `test_matmul_sm100_fallback.mojo.test` | blocked | vendor token in the test name |
| `test_matmul_sm100_fp32_precision.mojo.test` | blocked | vendor token in the test name |
| `test_matmul_sm100_fp8_smallm_band_dispatch.mojo.test` | blocked | vendor token in the test name |
| `test_matmul_sm100_fused_bias_residual_dispatch.mojo.test` | blocked | vendor token in the test name |
| `test_matmul_sm100_partial_n_tile_epilogue.mojo.test` | blocked | vendor token in the test name |
| `test_matmul_sm100_smoke.mojo.test` | blocked | vendor token in the test name |
| `test_matmul_sm100_splitk_2sm_bf16.mojo.test` | blocked | vendor token in the test name |
| `test_matmul_sm100_structured_quick.mojo.test` | blocked | vendor token in the test name |
| `test_matmul_sm100_swapAB_epilogue.mojo.test` | blocked | vendor token in the test name |
| `test_matmul_sm100_swiglu_1sm.mojo.test` | blocked | vendor token in the test name |
| `test_matmul_sm100_swiglu_2sm.mojo.test` | blocked | vendor token in the test name |
| `test_matmul_sm100_swiglu_bias_1sm.mojo.test` | blocked | vendor token in the test name |
| `test_matmul_sm100_swiglu_bias_2sm.mojo.test` | blocked | vendor token in the test name |
| `test_mma_ws_partial_sm100.mojo.test` | blocked | vendor token in the test name |
| `test_tma_mma_sm100.mojo.test` | blocked | vendor token in the test name |
| `test_tma_mma_sm100_fp8.mojo.test` | blocked | vendor token in the test name |
| `test_tma_mma_sm100_fp8_cast.mojo.test` | blocked | vendor token in the test name |
| `test_tma_mma_sm100_mxfp8.mojo.test` | blocked | vendor token in the test name |
| `test_tma_pair_mma_sm100.mojo.test` | blocked | vendor token in the test name |
| `test_tma_pair_mma_sm100_mxfp8.mojo.test` | blocked | vendor token in the test name |
| `attention/test_mha_sm100_1q_splitk_combine_causal_d128_p10.mojo.test` | blocked | vendor token in the test name |
| `attention/test_mha_sm100_1q_splitk_combine_causal_d128_p16.mojo.test` | blocked | vendor token in the test name |
| `attention/test_mha_sm100_1q_splitk_combine_causal_d128_p2.mojo.test` | blocked | vendor token in the test name |
| `attention/test_mha_sm100_1q_splitk_combine_causal_d128_p4.mojo.test` | blocked | vendor token in the test name |
| `attention/test_mha_sm100_1q_splitk_combine_causal_d128_p6.mojo.test` | blocked | vendor token in the test name |
| `attention/test_mha_sm100_1q_splitk_combine_causal_d128_p8.mojo.test` | blocked | vendor token in the test name |
| `attention/test_mha_sm100_1q_splitk_combine_causal_d64_p10.mojo.test` | blocked | vendor token in the test name |
| `attention/test_mha_sm100_1q_splitk_combine_causal_d64_p16.mojo.test` | blocked | vendor token in the test name |
| `attention/test_mha_sm100_1q_splitk_combine_causal_d64_p2.mojo.test` | blocked | vendor token in the test name |
| `attention/test_mha_sm100_1q_splitk_combine_causal_d64_p4.mojo.test` | blocked | vendor token in the test name |
| `attention/test_mha_sm100_1q_splitk_combine_causal_d64_p6.mojo.test` | blocked | vendor token in the test name |
| `attention/test_mha_sm100_1q_splitk_combine_causal_d64_p8.mojo.test` | blocked | vendor token in the test name |
| `attention/test_mha_sm100_1q_splitk_combine_chunked_d128_p1.mojo.test` | blocked | vendor token in the test name |
| `attention/test_mha_sm100_1q_splitk_combine_chunked_d128_p10.mojo.test` | blocked | vendor token in the test name |
| `attention/test_mha_sm100_1q_splitk_combine_chunked_d128_p16.mojo.test` | blocked | vendor token in the test name |
| `attention/test_mha_sm100_1q_splitk_combine_chunked_d128_p2.mojo.test` | blocked | vendor token in the test name |
| `attention/test_mha_sm100_1q_splitk_combine_chunked_d128_p4.mojo.test` | blocked | vendor token in the test name |
| `attention/test_mha_sm100_1q_splitk_combine_chunked_d128_p6.mojo.test` | blocked | vendor token in the test name |
| `attention/test_mha_sm100_1q_splitk_combine_chunked_d128_p8.mojo.test` | blocked | vendor token in the test name |
| `attention/test_mha_sm100_1q_splitk_combine_chunked_d64_p10.mojo.test` | blocked | vendor token in the test name |
| `attention/test_mha_sm100_1q_splitk_combine_chunked_d64_p2.mojo.test` | blocked | vendor token in the test name |
| `attention/test_mha_sm100_1q_splitk_combine_chunked_d64_p4.mojo.test` | blocked | vendor token in the test name |
| `attention/test_mha_sm100_1q_splitk_combine_chunked_d64_p6.mojo.test` | blocked | vendor token in the test name |
| `attention/test_mha_sm100_1q_splitk_combine_chunked_d64_p8.mojo.test` | blocked | vendor token in the test name |
| `attention/test_mha_sm100_1q_splitk_combine_chunked_sink_d64_p8.mojo.test` | blocked | vendor token in the test name |
| `attention/test_mha_sm100_1q_splitk_combine_null_d128_p1.mojo.test` | blocked | vendor token in the test name |
| `attention/test_mha_sm100_1q_splitk_combine_null_d128_p10.mojo.test` | blocked | vendor token in the test name |
| `attention/test_mha_sm100_1q_splitk_combine_null_d128_p16.mojo.test` | blocked | vendor token in the test name |
| `attention/test_mha_sm100_1q_splitk_combine_null_d128_p2.mojo.test` | blocked | vendor token in the test name |
| `attention/test_mha_sm100_1q_splitk_combine_null_d128_p4.mojo.test` | blocked | vendor token in the test name |
| `attention/test_mha_sm100_1q_splitk_combine_null_d128_p6.mojo.test` | blocked | vendor token in the test name |
| `attention/test_mha_sm100_1q_splitk_combine_null_d128_p8.mojo.test` | blocked | vendor token in the test name |
| `attention/test_mha_sm100_1q_splitk_combine_null_d64_p1.mojo.test` | blocked | vendor token in the test name |
| `attention/test_mha_sm100_1q_splitk_combine_null_d64_p10.mojo.test` | blocked | vendor token in the test name |
| `attention/test_mha_sm100_1q_splitk_combine_null_d64_p16.mojo.test` | blocked | vendor token in the test name |
| `attention/test_mha_sm100_1q_splitk_combine_null_d64_p2.mojo.test` | blocked | vendor token in the test name |
| `attention/test_mha_sm100_1q_splitk_combine_null_d64_p4.mojo.test` | blocked | vendor token in the test name |
| `attention/test_mha_sm100_1q_splitk_combine_null_d64_p6.mojo.test` | blocked | vendor token in the test name |
| `attention/test_mha_sm100_1q_splitk_combine_null_d64_p8.mojo.test` | blocked | vendor token in the test name |
| `attention/test_mha_sm100_1q_splitk_combine_swcausal_d128_p1.mojo.test` | blocked | vendor token in the test name |
| `attention/test_mha_sm100_1q_splitk_combine_swcausal_d128_p10.mojo.test` | blocked | vendor token in the test name |
| `attention/test_mha_sm100_1q_splitk_combine_swcausal_d128_p16.mojo.test` | blocked | vendor token in the test name |
| `attention/test_mha_sm100_1q_splitk_combine_swcausal_d128_p2.mojo.test` | blocked | vendor token in the test name |
| `attention/test_mha_sm100_1q_splitk_combine_swcausal_d128_p4.mojo.test` | blocked | vendor token in the test name |
| `attention/test_mha_sm100_1q_splitk_combine_swcausal_d128_p6.mojo.test` | blocked | vendor token in the test name |
| `attention/test_mha_sm100_1q_splitk_combine_swcausal_d128_p8.mojo.test` | blocked | vendor token in the test name |
| `attention/test_mha_sm100_1q_splitk_combine_swcausal_d64_p10.mojo.test` | blocked | vendor token in the test name |
| `attention/test_mha_sm100_1q_splitk_combine_swcausal_d64_p2.mojo.test` | blocked | vendor token in the test name |
| `attention/test_mha_sm100_1q_splitk_combine_swcausal_d64_p4.mojo.test` | blocked | vendor token in the test name |
| `attention/test_mha_sm100_1q_splitk_combine_swcausal_d64_p6.mojo.test` | blocked | vendor token in the test name |
| `attention/test_mha_sm100_1q_splitk_combine_swcausal_d64_p8.mojo.test` | blocked | vendor token in the test name |
| `attention/test_mha_sm100_1q_splitk_combine_swnoncausal_d128_p1.mojo.test` | blocked | vendor token in the test name |
| `attention/test_mha_sm100_1q_splitk_combine_swnoncausal_d128_p10.mojo.test` | blocked | vendor token in the test name |
| `attention/test_mha_sm100_1q_splitk_combine_swnoncausal_d128_p2.mojo.test` | blocked | vendor token in the test name |
| `attention/test_mha_sm100_1q_splitk_combine_swnoncausal_d128_p4.mojo.test` | blocked | vendor token in the test name |
| `attention/test_mha_sm100_1q_splitk_combine_swnoncausal_d128_p6.mojo.test` | blocked | vendor token in the test name |
| `attention/test_mha_sm100_1q_splitk_combine_swnoncausal_d128_p8.mojo.test` | blocked | vendor token in the test name |
| `attention/test_mha_sm100_1q_splitk_combine_swnoncausal_d64_p10.mojo.test` | blocked | vendor token in the test name |
| `attention/test_mha_sm100_1q_splitk_combine_swnoncausal_d64_p2.mojo.test` | blocked | vendor token in the test name |
| `attention/test_mha_sm100_1q_splitk_combine_swnoncausal_d64_p4.mojo.test` | blocked | vendor token in the test name |
| `attention/test_mha_sm100_1q_splitk_combine_swnoncausal_d64_p6.mojo.test` | blocked | vendor token in the test name |
| `attention/test_mha_sm100_1q_splitk_combine_swnoncausal_d64_p8.mojo.test` | blocked | vendor token in the test name |
| `attention/test_mha_sm100_materialized_mask.mojo.test` | blocked | vendor token in the test name |
| `attention/test_mha_sm100_nonws_partial_v_pages.mojo.test` | blocked | vendor token in the test name |
| `attention/test_mha_sm100_ws_bm32_multitile.mojo.test` | blocked | vendor token in the test name |
| `attention/test_mha_sm100_ws_bm32_splitk.mojo.test` | blocked | vendor token in the test name |
| `attention/test_mha_sm100_ws_bm32_splitk_p16.mojo.test` | blocked | vendor token in the test name |
| `attention/test_mha_sm100_ws_bm32_splitk_p4.mojo.test` | blocked | vendor token in the test name |
| `attention/test_mha_sm100_ws_bm32_splitk_p8.mojo.test` | blocked | vendor token in the test name |
| `attention/test_mha_sm100_ws_layout_e_v_alignment.mojo.test` | blocked | vendor token in the test name |
| `test_amd_4wave_conv_dtypes_bfloat16.mojo.test` | blocked | vendor token in the test name |
| `test_amd_4wave_conv_dtypes_float16.mojo.test` | blocked | vendor token in the test name |
| `test_amd_4wave_conv_dtypes_float8_e4m3fn.mojo.test` | blocked | vendor token in the test name |
| `test_fp8_quantize_saturating.mojo.test` | unverified | vendor guard (has_nvidia_gpu_accelerator) and no work done here |
| `test_mha_causal_mask_amd_bf16.mojo.test` | blocked | vendor token in the test name |
| `test_mha_causal_mask_amd_fp8.mojo.test` | blocked | vendor token in the test name |
| `test_mla_layout_g_mma_smoke.mojo.test` | vacuous | vendor guard (_is_sm10x_gpu) and no work done here |
| `test_fp8fnuz_amd.mojo.test` | blocked | vendor token in the test name |
| `test_ep_combine.mojo.test` | blocked | lit REQUIRES: NVIDIA-GPU |
| `test_ep_dispatch.mojo.test` | blocked | lit REQUIRES: NVIDIA-GPU |
| `test_ep_dispatch_fp8.mojo.test` | blocked | lit REQUIRES: NVIDIA-GPU |
| `test_shmem_gpu_per_process.mojo.test` | blocked | lit REQUIRES: NVIDIA-GPU |
| `test_shmem_ring_bcast.mojo.test` | blocked | lit REQUIRES: NVIDIA-GPU |
| `test_shmem_ring_reduce.mojo.test` | blocked | lit REQUIRES: NVIDIA-GPU |
