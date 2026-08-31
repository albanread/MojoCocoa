/* Lifetime stress (Sprint 4 exit criterion): destroy a Metal buffer while
 * an asynchronous dispatch still references it, from another thread.
 *
 * Before the destroyBuffer drain, this released the MTLBuffer (and tore
 * down its registry/residency entries) with a committed-but-unwaited blit
 * still reading it -- a use-after-free the validation layer may or may not
 * catch, depending on scheduling. With the drain, destruction waits for
 * completion and the race is gone by construction.
 *
 *   clang -O2 -I ../../../AsyncRT/lib/MojoBindings lifetime_stress.c \
 *     -o /tmp/ltstress /path/to/libCocoaMojoGPU.dylib -framework Metal \
 *     -framework Foundation -lobjc
 *   MTL_DEBUG_LAYER=1 /tmp/ltstress
 */
#include <AppleGPUInternal.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>

static AGMetalCtx *ctx;
static char payload[4096];

int main(void) {
  char name[64], arch[64];
  if (AppleGPUMetal_createContext(&ctx, 0, name, sizeof name, arch,
                                  sizeof arch) != 0) {
    fprintf(stderr, "no metal context\n");
    return 1;
  }
  memset(payload, 0x5a, sizeof payload);

  for (int round = 0; round < 200; round++) {
    AGMetalBuf *buf = NULL;
    void *addr = NULL;
    if (AppleGPUMetal_createBuffer(&buf, &addr, ctx, sizeof payload,
                                   /*host=*/false))
      break;
    uint64_t dst = (uint64_t)(uintptr_t)addr;
    /* Commit work WITHOUT waiting -- the async-launch default. */
    for (int i = 0; i < 8; i++)
      AppleGPUMetal_copyRawHtoD(ctx, dst, payload, sizeof payload);
    /* Destroy mid-flight: this is the race. With the drain it waits. */
    AppleGPUMetal_destroyBuffer(buf);
  }
  AppleGPUMetal_synchronize(ctx);
  AppleGPUMetal_destroyContext(ctx);
  printf("lifetime-stress: OK\n");
  return 0;
}
