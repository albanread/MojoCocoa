# Apple GPU test run

16 tests executed directly (bazel built them; this runner ran them).

| outcome | count |
|---|---|
| pass | 8 |
| partial | 2 |
| fail | 4 |
| pso | 2 |

**10 of 16 did real work and passed** (0 were vacuous skips).


## fail (4)

| test | detail |
|---|---|
| `test_metal_print.mojo.test` | FileCheck command line:  ../+llvm_configure+llvm-project/llvm/FileCheck max/kernels/test/gpu/basics/test_metal |
| `test_apple_gpu_matmul.mojo.test` | Unhandled exception caught during execution: enqueue_apple_matmul requires Apple M5 (compute_capability == 5); |
| `test_apple_int8_matmul.mojo.test` | Unhandled exception caught during execution: FAILED: 3 of 3 stages |
| `test_grouped_matmul_apple_fp8.mojo.test` | Unhandled exception caught during execution: matmul2d W4A16 (Apple M5 NVFP4) requires Apple M5 (compute_capabi |

## pso (2)

| test | detail |
|---|---|
| `test_apple_fp4_matmul.mojo.test` | == FAILED test_stage4_dispatch_paths: At max/mojo/max/gpu/host/_device_context_extras.mojo:168:17: AppleGPURT[ |
| `test_apple_fa_prefill.mojo.test` | Unhandled exception caught during execution: At max/mojo/max/gpu/host/_device_context_extras.mojo:168:17: Appl |

## partial (2)

| test | detail |
|---|---|
| `test_apple_mma_fragment.mojo.test` | SKIP: requires Apple M5 + Metal 4 == test_mma_1x1 SKIP: requires Apple M5 + Metal 4 == tes |
| `test_conv2d_im2col_apple.mojo.test` | SKIP: dispatcher declined this shape (1x1 / K<16 / N<16) == bf16 3x3 s1 same-pad C64->1 |
