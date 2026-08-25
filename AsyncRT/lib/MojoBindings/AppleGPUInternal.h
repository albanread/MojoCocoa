//===----------------------------------------------------------------------===//
// AppleGPURT internal interface between the ABI layer (AppleGPURT.cpp) and the Metal
// backend (AppleGPUMetal.cpp).
//===----------------------------------------------------------------------===//
#pragma once
#include <cstddef>
#include <cstdint>

struct AGMetalCtx;
struct AGMetalBuf;
struct AGMetalFunc;

extern "C" {
int AppleGPUMetal_deviceCount(void);
const char *AppleGPUMetal_createContext(AGMetalCtx **out, int id, char *nameOut,
                                      size_t nameCap, char *archOut,
                                      size_t archCap);
void AppleGPUMetal_destroyContext(AGMetalCtx *ctx);
const char *AppleGPUMetal_mtlDevice(AGMetalCtx *ctx, void **out);
const char *AppleGPUMetal_synchronize(AGMetalCtx *ctx);
const char *AppleGPUMetal_memInfo(AGMetalCtx *ctx, size_t *freeMem, size_t *total);
size_t AppleGPUMetal_maxAlloc(AGMetalCtx *ctx);
int AppleGPUMetal_getAttribute(AGMetalCtx *ctx, int attr, int *out);
int AppleGPUMetal_computeCapability(AGMetalCtx *ctx);
const char *AppleGPUMetal_createBuffer(AGMetalBuf **out, void **devAddr,
                                     AGMetalCtx *ctx, size_t bytes, bool host);
const char *AppleGPUMetal_createSubBuffer(AGMetalBuf **out, void **devAddr,
                                        AGMetalBuf *parent, size_t offBytes,
                                        size_t bytes);
void AppleGPUMetal_destroyBuffer(AGMetalBuf *buf);
void *AppleGPUMetal_hostPtr(AGMetalBuf *buf);
const char *AppleGPUMetal_copyHtoD(AGMetalBuf *dst, const void *src, size_t bytes);
const char *AppleGPUMetal_copyDtoH(void *dst, AGMetalBuf *src, size_t bytes);
const char *AppleGPUMetal_copyDtoD(AGMetalBuf *dst, AGMetalBuf *src, size_t bytes);
const char *AppleGPUMetal_copyRawDtoD(AGMetalCtx *ctx, uint64_t dstAddr,
                                      uint64_t srcAddr, size_t bytes);
const char *AppleGPUMetal_copyRawHtoD(AGMetalCtx *ctx, uint64_t dstAddr,
                                    const void *src, size_t bytes);
const char *AppleGPUMetal_copyRawDtoH(AGMetalCtx *ctx, void *dst,
                                    uint64_t srcAddr, size_t bytes);
const char *AppleGPUMetal_fill(AGMetalBuf *dst, uint64_t val, size_t valSize);
const char *AppleGPUMetal_loadFunction(AGMetalFunc **out, AGMetalCtx *ctx,
                                     const char *functionName, const char *data,
                                     size_t dataLen,
                                     int32_t maxDynamicSharedBytes);
void AppleGPUMetal_destroyFunction(AGMetalFunc *fn);
const char *AppleGPUMetal_launch(AGMetalCtx *ctx, AGMetalFunc *fn,
                               const uint32_t grid[3], const uint32_t block[3],
                               uint32_t sharedMemBytes, void *const *argAddrs,
                               const uint64_t *argSizes,
                               const bool *argIsDevicePtr, uint32_t argc);
}
