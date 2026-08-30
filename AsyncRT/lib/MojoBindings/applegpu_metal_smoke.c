// AppleGPURT Metal smoke: the phase-2b acceptance gate.
// Exercises the AsyncRT_* ABI through local prototypes only — the same way
// Mojo's external_call finds it. Saxpy on the default Metal device; every
// element verified.
//
// Deliberately the MSL source path, not AIR. The AIR trio now builds, but
// this gate exists to test the RUNTIME in isolation: if it fails, the fault
// is in AppleGPURT/AppleGPUMetal, not in codegen. Getting a Mojo kernel
// through Mojo -> AIR -> metallib is the next gate up, and wants its own.
//
// Run it under validation as well as plain — a raw device address that is
// not resident passes silently without it. See markAllResident() in
// AppleGPUMetal.cpp.
//
//   MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1 applegpu_metal_smoke
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct Ctx Ctx;
typedef struct Buf Buf;
typedef struct Fn Fn;

extern const char *AsyncRT_DeviceContext_create(const Ctx **r, const char *api, int id);
extern void AsyncRT_DeviceContext_release(const Ctx *c);
extern int32_t AsyncRT_DeviceContext_numberOfDevices(const char *kind);
extern const char *AsyncRT_DeviceContext_deviceName(const Ctx *c);
extern void AsyncRT_DeviceContext_strfree(const char *p);
extern const char *AsyncRT_DeviceContext_createBuffer_async(const Buf **r, void **dp, const Ctx *c, size_t len, size_t elem);
extern void AsyncRT_DeviceBuffer_release(const Buf *b);
extern const char *AsyncRT_DeviceContext_HtoD_async(const Ctx *c, const Buf *dst, const void *src);
extern const char *AsyncRT_DeviceContext_DtoH_async(const Ctx *c, void *dst, const Buf *src);
extern const char *AsyncRT_DeviceContext_setMemory_async(const Ctx *c, const Buf *dst, uint64_t val, size_t vs);
extern const char *AsyncRT_DeviceContext_synchronize(const Ctx *c);
extern const char *AsyncRT_DeviceContext_getMemoryInfo(const Ctx *c, size_t *freeM, size_t *tot);
extern const char *AsyncRT_DeviceContext_maxSingleAllocationSize(const Ctx *c, size_t *r);
extern const char *AsyncRT_DeviceContext_getAttribute(int *r, const Ctx *c, int attr);
extern const char *AsyncRT_DeviceContext_loadFunction(
    const Fn **r, const Ctx *c, const char *module, const char *fname,
    const char *data, size_t dataLen, int32_t maxDynShared,
    const char *debugLevel, int32_t optLevel);
extern void AsyncRT_DeviceFunction_release(const Fn *f);
extern const char *AsyncRT_DeviceContext_enqueueFunctionDirect(
    const Ctx *c, const Fn *f, uint32_t gx, uint32_t gy, uint32_t gz,
    uint32_t bx, uint32_t by, uint32_t bz, uint32_t smem, void *attrs,
    uint32_t nattrs, void *const *args, uint32_t argc, const uint64_t *sizes);

static const char *kSaxpy =
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "kernel void saxpy(device float *y [[buffer(0)]],\n"
    "                  device const float *x [[buffer(1)]],\n"
    "                  constant float &a [[buffer(2)]],\n"
    "                  constant uint &n [[buffer(3)]],\n"
    "                  uint id [[thread_position_in_grid]]) {\n"
    "  if (id < n) y[id] = a * x[id] + y[id];\n"
    "}\n";

#define CHECK(expr)                                                            \
  do {                                                                         \
    const char *_err = (expr);                                                 \
    if (_err) {                                                                \
      fprintf(stderr, "SMOKE FAIL at %s:%d: %s\n  from: %s\n", __FILE__,       \
              __LINE__, _err, #expr);                                          \
      AsyncRT_DeviceContext_strfree(_err);                                     \
      return 1;                                                                \
    }                                                                          \
  } while (0)

int main(void) {
  printf("metal devices: %d\n", AsyncRT_DeviceContext_numberOfDevices("gpu"));

  const Ctx *ctx = NULL;
  CHECK(AsyncRT_DeviceContext_create(&ctx, "metal", 0));
  const char *name = AsyncRT_DeviceContext_deviceName(ctx);
  printf("device: %s\n", name);
  AsyncRT_DeviceContext_strfree(name);

  size_t freeM = 0, tot = 0, maxAlloc = 0;
  int warp = 0;
  CHECK(AsyncRT_DeviceContext_getMemoryInfo(ctx, &freeM, &tot));
  CHECK(AsyncRT_DeviceContext_maxSingleAllocationSize(ctx, &maxAlloc));
  CHECK(AsyncRT_DeviceContext_getAttribute(&warp, ctx, 10));
  printf("memory: %.1f GiB total, maxAlloc %.1f GiB, warp %d\n",
         tot / 1073741824.0, maxAlloc / 1073741824.0, warp);

  enum { N = 1 << 20 };
  const Buf *x = NULL, *y = NULL;
  void *xAddr = NULL, *yAddr = NULL;
  CHECK(AsyncRT_DeviceContext_createBuffer_async(&x, &xAddr, ctx, N, 4));
  CHECK(AsyncRT_DeviceContext_createBuffer_async(&y, &yAddr, ctx, N, 4));
  // Not "private, HBM2" — that was the Vega II, which had its own memory and
  // needed a staging blit per transfer. These are storageModeShared in one
  // unified pool, and the addresses are MTLBuffer gpuAddress values.
  printf("buffers: x@0x%llx y@0x%llx (shared, unified)\n",
         (unsigned long long)(uintptr_t)xAddr,
         (unsigned long long)(uintptr_t)yAddr);

  float *hostX = malloc(N * 4), *hostY = malloc(N * 4);
  for (int i = 0; i < N; i++) {
    hostX[i] = (float)i;
    hostY[i] = 2.0f * (float)i;
  }
  CHECK(AsyncRT_DeviceContext_HtoD_async(ctx, x, hostX));
  CHECK(AsyncRT_DeviceContext_HtoD_async(ctx, y, hostY));

  // Load from MSL source (the sniff path) and launch: y = 3x + y.
  const Fn *fn = NULL;
  CHECK(AsyncRT_DeviceContext_loadFunction(&fn, ctx, "", "saxpy", kSaxpy,
                                           strlen(kSaxpy), -1, "none", 3));
  printf("pipeline: built from MSL source\n");

  float a = 3.0f;
  uint32_t n = N;
  uint64_t xA = (uint64_t)(uintptr_t)xAddr, yA = (uint64_t)(uintptr_t)yAddr;
  // Metal-wrapper protocol: args[0] -> {addrs, sizes, isDevicePtr}.
  void *addrs[4] = {&yA, &xA, &a, &n};
  uint64_t sizes[4] = {8, 8, 4, 4};
  bool isDev[4] = {true, true, false, false};
  struct {
    void *const *addrs;
    const uint64_t *sizes;
    const bool *isDev;
  } metalArgs = {addrs, sizes, isDev};
  void *packed[1] = {&metalArgs};
  // Three dependent launches without an intervening synchronize exercise
  // queue ordering. DtoH below is the observation boundary and must drain all
  // three before copying from unified memory.
  for (int launch = 0; launch < 3; ++launch)
    CHECK(AsyncRT_DeviceContext_enqueueFunctionDirect(
        ctx, fn, (N + 255) / 256, 1, 1, 256, 1, 1, 0, NULL, 0, packed, 4,
        NULL));

  CHECK(AsyncRT_DeviceContext_DtoH_async(ctx, hostY, y));
  size_t bad = 0;
  for (int i = 0; i < N; i++) {
    float want = 11.0f * (float)i; // initial 2x + three additions of 3x
    if (hostY[i] != want && bad++ < 3)
      fprintf(stderr, "  wrong at %d: got %f want %f\n", i, hostY[i], want);
  }
  printf("queued saxpy x3: %zu/%d wrong\n", bad, N);

  // Cross the 64-dispatch backpressure boundary twice. A zero coefficient
  // leaves the checked result unchanged while still exercising command-buffer
  // rollover, commit, wait, and error inspection.
  a = 0.0f;
  for (int launch = 0; launch < 130; ++launch)
    CHECK(AsyncRT_DeviceContext_enqueueFunctionDirect(
        ctx, fn, (N + 255) / 256, 1, 1, 256, 1, 1, 0, NULL, 0, packed, 4,
        NULL));
  CHECK(AsyncRT_DeviceContext_DtoH_async(ctx, hostY, y));
  size_t badBackpressure = 0;
  for (int i = 0; i < N; i++)
    if (hostY[i] != 11.0f * (float)i)
      badBackpressure++;
  printf("backpressure x130: %zu/%d wrong\n", badBackpressure, N);
  bad += badBackpressure;

  // A malformed launch after a valid queued one must not strand the earlier
  // dispatch in an uncommitted batch. Repeat past the retained-buffer limit:
  // each size-contract failure commits a partial batch, so the next valid
  // launch must eventually apply backpressure without losing either work or
  // the immediate validation error.
  const char *expectedError = NULL;
  for (int rejection = 0; rejection < 65; ++rejection) {
    CHECK(AsyncRT_DeviceContext_enqueueFunctionDirect(
        ctx, fn, 1, 1, 1, 1, 1, 1, 0, NULL, 0, packed, 4, NULL));
    sizes[2] = 8;
    expectedError = AsyncRT_DeviceContext_enqueueFunctionDirect(
        ctx, fn, 1, 1, 1, 1, 1, 1, 0, NULL, 0, packed, 4, NULL);
    sizes[2] = 4;
    if (!expectedError) {
      fprintf(stderr, "SMOKE FAIL: malformed constant size was accepted\n");
      return 1;
    }
    AsyncRT_DeviceContext_strfree(expectedError);
  }
  printf("malformed launch x65: rejected\n");
  CHECK(AsyncRT_DeviceContext_synchronize(ctx));

  // The pre-encoder validation path must flush an already-open batch too.
  CHECK(AsyncRT_DeviceContext_enqueueFunctionDirect(
      ctx, fn, (N + 255) / 256, 1, 1, 256, 1, 1, 0, NULL, 0, packed, 4, NULL));
  expectedError = AsyncRT_DeviceContext_enqueueFunctionDirect(
      ctx, fn, 1, 1, 1, 2048, 1, 1, 0, NULL, 0, packed, 4, NULL);
  if (!expectedError) {
    fprintf(stderr, "SMOKE FAIL: oversized threadgroup was accepted\n");
    return 1;
  }
  printf("oversized launch: rejected\n");
  AsyncRT_DeviceContext_strfree(expectedError);
  CHECK(AsyncRT_DeviceContext_synchronize(ctx));

  // memset path too. Counted separately: folding this into `bad` and then
  // announcing "verified zero" regardless of the count meant the gate
  // reported a pass it had not established.
  CHECK(AsyncRT_DeviceContext_setMemory_async(ctx, y, 0, 4));
  CHECK(AsyncRT_DeviceContext_synchronize(ctx));
  CHECK(AsyncRT_DeviceContext_DtoH_async(ctx, hostY, y));
  size_t badMemset = 0;
  for (int i = 0; i < N; i++)
    if (hostY[i] != 0.0f)
      badMemset++;
  printf("memset: %zu/%d wrong\n", badMemset, N);
  bad += badMemset;

  // Leave one final no-op dispatch unsynchronized. Releasing the function and
  // buffers before the context exercises Metal's encoder-held resource
  // lifetime; context teardown must commit and drain the open batch safely.
  a = 0.0f;
  CHECK(AsyncRT_DeviceContext_enqueueFunctionDirect(
      ctx, fn, (N + 255) / 256, 1, 1, 256, 1, 1, 0, NULL, 0, packed, 4, NULL));

  AsyncRT_DeviceFunction_release(fn);
  AsyncRT_DeviceBuffer_release(x);
  AsyncRT_DeviceBuffer_release(y);
  AsyncRT_DeviceContext_release(ctx);
  free(hostX);
  free(hostY);

  if (bad) {
    fprintf(stderr, "SMOKE FAIL: %zu wrong elements\n", bad);
    return 1;
  }
  printf("teardown drain: PASS\n");
  printf("APPLEGPU METAL SMOKE: ALL PASS\n");
  return 0;
}
