// Does dispatch cost grow with the number of unrelated live allocations?
//
// The question AIR_EXPERIMENTS.md item 6 asks the runtime to answer with a
// number. markAllResident() declared every live root buffer to every compute
// encoder, so a dispatch paid for every allocation in the process whether the
// kernel could reach it or not. The residency set moves that to allocation
// time. If the fix is real, dispatch time is flat in the allocation count
// under the default mode and grows under APPLEGPU_COARSE_RESIDENCY=1; if the
// two curves match, the fix is theatre.
//
//   applegpu_residency_bench
//   APPLEGPU_COARSE_RESIDENCY=1 applegpu_residency_bench
//
// Prints one line per population size: unrelated live buffers, then the warm
// wall time for a fixed batch of tiny dispatches. The kernel touches one
// float; the workload is deliberately nothing so the launch path is the
// entire measurement.
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

typedef struct Ctx Ctx;
typedef struct Buf Buf;
typedef struct Fn Fn;

extern const char *AsyncRT_DeviceContext_create(const Ctx **r, const char *api, int id);
extern void AsyncRT_DeviceContext_release(const Ctx *c);
extern const char *AsyncRT_DeviceContext_createBuffer_async(const Buf **r, void **dp, const Ctx *c, size_t len, size_t elem);
extern void AsyncRT_DeviceBuffer_release(const Buf *b);
extern const char *AsyncRT_DeviceContext_synchronize(const Ctx *c);
extern const char *AsyncRT_DeviceContext_loadFunction(
    const Fn **r, const Ctx *c, const char *module, const char *fname,
    const char *data, size_t dataLen, int32_t maxDynShared,
    const char *debugLevel, int32_t optLevel);
extern void AsyncRT_DeviceFunction_release(const Fn *f);
extern const char *AsyncRT_DeviceContext_enqueueFunctionDirect(
    const Ctx *c, const Fn *f, uint32_t gx, uint32_t gy, uint32_t gz,
    uint32_t bx, uint32_t by, uint32_t bz, uint32_t smem, void *attrs,
    uint32_t nattrs, void *const *args, uint32_t argc, const uint64_t *sizes);

static const char *kTouch =
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "kernel void touch(device float *y [[buffer(0)]],\n"
    "                  uint id [[thread_position_in_grid]]) {\n"
    "  if (id == 0) y[0] += 1.0f;\n"
    "}\n";

#define CHECK(expr)                                                            \
  do {                                                                         \
    const char *_err = (expr);                                                 \
    if (_err) {                                                                \
      fprintf(stderr, "BENCH FAIL at %d: %s\n", __LINE__, _err);               \
      return 1;                                                                \
    }                                                                          \
  } while (0)

static double now_ms(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return ts.tv_sec * 1e3 + ts.tv_nsec / 1e6;
}

enum { kDispatches = 256, kMaxPop = 4096 };

int main(void) {
  const Ctx *ctx = NULL;
  CHECK(AsyncRT_DeviceContext_create(&ctx, "metal", 0));

  const Fn *fn = NULL;
  CHECK(AsyncRT_DeviceContext_loadFunction(&fn, ctx, "", "touch", kTouch,
                                           strlen(kTouch), -1, "none", 3));

  const Buf *target = NULL;
  void *targetAddr = NULL;
  CHECK(AsyncRT_DeviceContext_createBuffer_async(&target, &targetAddr, ctx,
                                                 4096, 1));

  // The population of unrelated buffers, grown between rounds and never
  // touched by the kernel. Their only role is to exist.
  static const Buf *pop[kMaxPop];
  static void *popAddr[kMaxPop];
  int live = 0;

  printf("mode: %s\n", getenv("APPLEGPU_COARSE_RESIDENCY")
                           ? "coarse (walk per dispatch)"
                           : "precise (residency set)");
  printf("%9s  %14s  %14s\n", "buffers", "batch ms", "us/dispatch");

  int sizes[] = {0, 16, 64, 256, 1024, 4096};
  for (unsigned s = 0; s < sizeof(sizes) / sizeof(sizes[0]); ++s) {
    while (live < sizes[s]) {
      CHECK(AsyncRT_DeviceContext_createBuffer_async(&pop[live], &popAddr[live],
                                                     ctx, 4096, 1));
      ++live;
    }

    // Metal-wrapper protocol, as the smoke uses it: args[0] points at an
    // {addrs, sizes, isDevicePtr} triple, and isDev is what says "bind this
    // with setBuffer" rather than validating it against a constant slot.
    uint64_t yA = (uint64_t)(uintptr_t)targetAddr;
    void *addrs[1] = {&yA};
    uint64_t sizes1[1] = {8};
    bool isDev[1] = {true};
    struct {
      void *const *addrs;
      const uint64_t *sizes;
      const bool *isDev;
    } metalArgs = {addrs, sizes1, isDev};
    void *packed[1] = {&metalArgs};

    // One warm round paid outside the clock: pipeline caches, first-touch.
    for (int i = 0; i < kDispatches; ++i)
      CHECK(AsyncRT_DeviceContext_enqueueFunctionDirect(
          ctx, fn, 1, 1, 1, 1, 1, 1, 0, NULL, 0, packed, 1, NULL));
    CHECK(AsyncRT_DeviceContext_synchronize(ctx));

    double best = 1e30;
    for (int round = 0; round < 5; ++round) {
      double t0 = now_ms();
      for (int i = 0; i < kDispatches; ++i)
        CHECK(AsyncRT_DeviceContext_enqueueFunctionDirect(
            ctx, fn, 1, 1, 1, 1, 1, 1, 0, NULL, 0, packed, 1, NULL));
      CHECK(AsyncRT_DeviceContext_synchronize(ctx));
      double t = now_ms() - t0;
      if (t < best)
        best = t;
    }
    printf("%9d  %14.3f  %14.2f\n", live, best,
           best * 1000.0 / kDispatches);
  }

  for (int i = 0; i < live; ++i)
    AsyncRT_DeviceBuffer_release(pop[i]);
  AsyncRT_DeviceBuffer_release(target);
  AsyncRT_DeviceFunction_release(fn);
  AsyncRT_DeviceContext_release(ctx);
  printf("done\n");
  return 0;
}
