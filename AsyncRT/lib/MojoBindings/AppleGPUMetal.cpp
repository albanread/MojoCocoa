//===----------------------------------------------------------------------===//
// AppleGPUMetal — the Metal backend for AppleGPURT, targeting Apple Silicon
// GPUs (apple-m1..m5) through the Metal API on arm64 macOS.
//
// Ported from the x86-64 MacVegaFork, where the same code drove a Radeon Pro
// Vega II and a 580X in a 2019 Mac Pro. See AIR_APPLE_SILICON.md.
//
// Written in plain C++ over the Objective-C runtime (objc_msgSend casts, the
// metal-cpp technique) so no Objective-C++ toolchain support is required.
//
// UNIFIED-MEMORY semantics: on Apple Silicon the CPU and GPU share one pool,
// so every buffer is storageModeShared and both HtoD and DtoH are a plain
// memcpy -- no staging buffer, no blit encoder, no command buffer. The
// x86-64 fork could not do this: a discrete Vega II has its own HBM2, so
// device buffers had to be storageModePrivate and every transfer went
// through a staging blit.
//
// `isHost` therefore no longer means "host-visible" -- everything is. It now
// means only "the address handed to Mojo is a CPU pointer", which is still a
// real distinction (see gpuBase below). `hostVisible` carries the storage
// fact, and the staging paths are kept behind it so a future
// storageModePrivate mode (worthwhile for GPU-only buffers, which Apple can
// keep in a compressed layout) can switch it back per-buffer.
//
// Synchronous under the async names for bring-up, same completion model the
// CPU backend uses.
//
// Device pointers handed to Mojo are MTLBuffer gpuAddress values. A global
// interval map resolves any device address back to its owning MTLBuffer and
// offset, which is how kernel launches bind pointer arguments (setBuffer
// with a resolved offset) without trusting struct layouts we don't own.
//===----------------------------------------------------------------------===//

#include "AppleGPUInternal.h"

#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <map>
#include <mutex>
#include <string>
#include <vector>

#include <CoreFoundation/CoreFoundation.h>
#include <dispatch/dispatch.h>
#include <objc/message.h>
#include <objc/runtime.h>

extern "C" id MTLCopyAllDevices(void);

namespace {

//===----------------------------------------------------------------------===//
// objc plumbing
//===----------------------------------------------------------------------===//

template <typename R, typename... A> R msg(id obj, const char *sel, A... a) {
  using Fn = R (*)(id, SEL, A...);
  return reinterpret_cast<Fn>(objc_msgSend)(obj, sel_registerName(sel), a...);
}

struct MTLSizeC {
  unsigned long w, h, d;
};
struct NSRangeC {
  unsigned long loc, len;
};

void objcRelease(id obj) {
  if (obj)
    msg<void>(obj, "release");
}

std::string nsstringToStd(id nsstr) {
  if (!nsstr)
    return "";
  const char *utf8 = msg<const char *>(nsstr, "UTF8String");
  return utf8 ? utf8 : "";
}

char *agmStrdup(const char *s) {
  size_t n = strlen(s) + 1;
  char *p = static_cast<char *>(malloc(n));
  memcpy(p, s, n);
  return p;
}

const char *agmErrorf(const char *fmt, ...) {
  char buf[768];
  va_list ap;
  va_start(ap, fmt);
  vsnprintf(buf, sizeof(buf), fmt, ap);
  va_end(ap);
  return agmStrdup(buf);
}

const char *errorFromNSError(const char *what, id nserror) {
  std::string desc =
      nserror ? nsstringToStd(msg<id>(nserror, "localizedDescription"))
              : "(no NSError)";
  return agmErrorf("AppleGPURT[metal]: %s: %s", what, desc.c_str());
}

// storage modes: MTLResourceStorageMode{Shared=0, Managed=1<<4, Private=2<<4}
constexpr unsigned long kStorageShared = 0;
[[maybe_unused]] constexpr unsigned long kStoragePrivate = 2ul << 4;

// Unified memory: every allocation is CPU-coherent, so nothing needs Private.
// Flip this to false to get the discrete-GPU behaviour back wholesale.
constexpr bool kUnifiedMemory = true;

} // namespace

//===----------------------------------------------------------------------===//
// Structures
//===----------------------------------------------------------------------===//

struct AGMetalCtx {
  id device = nullptr; // id<MTLDevice>, retained by MTLCopyAllDevices
  id queue = nullptr;  // id<MTLCommandQueue>
  std::string name;
  std::string arch;
};

struct AGMetalBuf {
  AGMetalCtx *ctx = nullptr;
  id buffer = nullptr;   // id<MTLBuffer>; owned unless this is a sub-view
  bool ownsBuffer = false;
  size_t offset = 0;     // view offset within `buffer`
  size_t bytes = 0;
  bool isHost = false;   // the address given to Mojo is a CPU pointer
  bool hostVisible = false; // storage is Shared, so `contents` is usable
  uint64_t gpuBase = 0;  // gpuAddress of `buffer` (not of the view)
};

// What the compiled kernel says about one buffer index, read back from the
// pipeline at load time. This is the argument contract, and having it means
// the launch path no longer has to infer from argument VALUES what the
// compiler already decided.
//
// Read off MTLComputePipelineReflection for three of our kernels:
//
//   addrspace(1) device buffer   bufferDataType None    size 4    RW
//   addrspace(2) constant f32    bufferDataType UInt    size 4    RO
//   addrspace(2) constant struct bufferDataType UInt    size 72   RO
//
// A device-buffer parameter is `{} addrspace(1)*` -- an opaque pointee, so
// Metal reports MTLDataTypeNone. Constant parameters carry a real type and
// the size the kernel will read. That is the discriminator.
struct AGMetalArgSlot {
  bool known = false;
  bool deviceBuffer = false; // bind with setBuffer, not setBytes
  uint64_t declaredSize = 0; // bytes the kernel expects at this index
};

struct AGMetalFunc {
  id library = nullptr;
  id function = nullptr;
  id pipeline = nullptr; // id<MTLComputePipelineState>
  std::string name;
  int32_t maxDynamicSharedBytes = -1;
  std::vector<AGMetalArgSlot> argSlots; // indexed by buffer index
};

namespace {

//===----------------------------------------------------------------------===//
// Address registry: gpuAddress interval -> owning buffer
//===----------------------------------------------------------------------===//

// Function-local statics: the repo compiles -Werror=global-constructors.
struct AddressRegistry {
  std::mutex mu;
  // key: base gpu address of a root (owning) buffer -> {buf, sizeBytes}
  std::map<uint64_t, std::pair<AGMetalBuf *, size_t>> map;
};
AddressRegistry &registry() {
  static AddressRegistry *r = new AddressRegistry(); // never destroyed
  return *r;
}

void registerRoot(AGMetalBuf *buf, size_t fullBytes) {
  auto &r = registry();
  std::lock_guard<std::mutex> lock(r.mu);
  r.map[buf->gpuBase] = {buf, fullBytes};
}

void unregisterRoot(const AGMetalBuf *buf) {
  auto &r = registry();
  std::lock_guard<std::mutex> lock(r.mu);
  auto it = r.map.find(buf->gpuBase);
  if (it != r.map.end() && it->second.first == buf)
    r.map.erase(it);
}

// Resolve a device address to (MTLBuffer id, offset). Returns nil on miss.
id resolveAddress(uint64_t addr, size_t *offsetOut) {
  auto &r = registry();
  std::lock_guard<std::mutex> lock(r.mu);
  auto it = r.map.upper_bound(addr);
  if (it == r.map.begin())
    return nullptr;
  --it;
  uint64_t base = it->first;
  size_t size = it->second.second;
  if (addr < base || addr >= base + size)
    return nullptr;
  *offsetOut = static_cast<size_t>(addr - base);
  return it->second.first->buffer;
}

// Make every live allocation resident on `enc`.
//
// Required, not defensive. Since capture hoisting was dropped (AirBackend.cpp,
// "Captured pointers: NOT hoisted on Apple Silicon"), a device pointer inside
// a capture blob reaches the kernel as a bare 64-bit address. Metal tracks
// residency per *bound resource*, and a raw address is not a binding, so
// nothing keeps the pointee resident for the dispatch.
//
// Measured on an M4 Max, kernel dereferencing a gpuAddress out of a setBytes
// blob with no air.indirect_buffer metadata:
//
//   MTL_SHADER_VALIDATION=0   no useResource -> PASSES  (silently)
//   MTL_SHADER_VALIDATION=1   no useResource -> FAILS, every read returns 0
//   MTL_SHADER_VALIDATION=1   useResource    -> PASSES
//
// So the unfixed path is not merely fragile, it is already wrong; it only
// looks correct because a small, recently CPU-written Shared buffer happens
// to be resident. Run the GPU tests with MTL_SHADER_VALIDATION=1 or this
// class of bug stays invisible.
//
// Coarse by design: every live root buffer, not just the reachable ones. The
// precise fix is to mark only what a kernel can reach, which needs
// TODO(air-indirect) -- once capture structs carry air.indirect_buffer /
// air.struct_type_info, the pointer fields are described and Metal can
// resolve them itself. Cost here is O(live allocations) per dispatch.
void markAllResident(id enc) {
  // MTLResourceUsageRead | MTLResourceUsageWrite. Read-only would need the
  // reachability analysis above to know a kernel never writes through a
  // captured pointer.
  constexpr unsigned long kReadWrite = 1UL | 2UL;
  auto &r = registry();
  std::lock_guard<std::mutex> lock(r.mu);
  for (auto &entry : r.map) {
    AGMetalBuf *buf = entry.second.first;
    if (buf && buf->buffer)
      msg<void>(enc, "useResource:usage:", buf->buffer, kReadWrite);
  }
}

//===----------------------------------------------------------------------===//
// Command helpers (synchronous bring-up)
//===----------------------------------------------------------------------===//

struct BlitOp {
  id src = nullptr;
  size_t srcOff = 0;
  id dst = nullptr;
  size_t dstOff = 0;
  size_t bytes = 0;
  bool fill = false;
  uint8_t fillValue = 0;
};

const char *runBlitOp(AGMetalCtx *ctx, const BlitOp &op) {
  id cb = msg<id>(ctx->queue, "commandBuffer");
  if (!cb)
    return agmErrorf("AppleGPURT[metal]: commandBuffer creation failed");
  id blit = msg<id>(cb, "blitCommandEncoder");
  if (op.fill) {
    NSRangeC range{op.dstOff, op.bytes};
    msg<void>(blit, "fillBuffer:range:value:", op.dst, range,
              static_cast<uint8_t>(op.fillValue));
  } else {
    msg<void>(blit,
              "copyFromBuffer:sourceOffset:toBuffer:destinationOffset:size:",
              op.src, static_cast<unsigned long>(op.srcOff), op.dst,
              static_cast<unsigned long>(op.dstOff),
              static_cast<unsigned long>(op.bytes));
  }
  msg<void>(blit, "endEncoding");
  msg<void>(cb, "commit");
  msg<void>(cb, "waitUntilCompleted");
  id err = msg<id>(cb, "error");
  if (err)
    return errorFromNSError("blit failed", err);
  return nullptr;
}

// Sorted device list: Metal3-family first, then higher working-set. On an
// Apple Silicon Mac there is normally exactly one device, so the ordering is
// vestigial here -- it existed to keep the Vega II at id 0 ahead of the 580X
// on the fork's dual-GPU Mac Pro. Harmless, and still correct for an eGPU.
std::vector<id> &allDevices() {
  static std::vector<id> devices = [] {
    std::vector<id> result;
    id array = MTLCopyAllDevices();
    unsigned long count = msg<unsigned long>(array, "count");
    for (unsigned long i = 0; i < count; i++)
      result.push_back(msg<id>(array, "objectAtIndex:", i));
    auto rank = [](id dev) {
      bool metal3 = msg<bool>(dev, "supportsFamily:", (long)5001);
      unsigned long long ws =
          msg<unsigned long long>(dev, "recommendedMaxWorkingSetSize");
      return (metal3 ? (1ull << 62) : 0) + ws;
    };
    for (size_t i = 0; i < result.size(); i++)
      for (size_t j = i + 1; j < result.size(); j++)
        if (rank(result[j]) > rank(result[i]))
          std::swap(result[i], result[j]);
    return result;
  }();
  return devices;
}

std::string archForName(const std::string &name) {
  // Arch strings must classify as APPLE_GPU in the stdlib's _vendor_from_arch,
  // which SUBSTRING-matches: a name containing "amd", "gfx" or "mi" would
  // misroute device codegen to the HIP paths. "apple-*" is safe, and is the
  // spelling upstream itself uses (std/gpu/host/info.mojo defines apple-m1
  // through apple-m5; sys/info.mojo accepts either that bare form or the
  // vendor-prefixed "metal:N").
  //
  // Metal reports names like "Apple M4", "Apple M4 Pro", "Apple M4 Max" --
  // the family is what matters here, not the bin, so take the digit after a
  // standalone "M".
  if (name.rfind("Apple M", 0) == 0 && name.size() > 7) {
    char gen = name[7];
    if (gen >= '1' && gen <= '9')
      return std::string("apple-m") + gen;
  }
  return "metal-unknown";
}

} // namespace

//===----------------------------------------------------------------------===//
// Internal C API (consumed by AppleGPURT.cpp)
//===----------------------------------------------------------------------===//

extern "C" {

int AppleGPUMetal_deviceCount(void) {
  return static_cast<int>(allDevices().size());
}

const char *AppleGPUMetal_createContext(AGMetalCtx **out, int id_,
                                      char *nameOut, size_t nameCap,
                                      char *archOut, size_t archCap) {
  auto &devices = allDevices();
  if (id_ < 0 || static_cast<size_t>(id_) >= devices.size())
    return agmErrorf("AppleGPURT[metal]: device id %d out of range (%zu Metal "
                     "devices present)",
                     id_, devices.size());
  auto *ctx = new AGMetalCtx();
  ctx->device = devices[static_cast<size_t>(id_)];
  ctx->queue = msg<id>(ctx->device, "newCommandQueue");
  if (!ctx->queue) {
    delete ctx;
    return agmErrorf("AppleGPURT[metal]: newCommandQueue failed");
  }
  std::string devName = nsstringToStd(msg<id>(ctx->device, "name"));
  // test_smoke requires "Apple" in the name when api == "metal"; truthfully,
  // this is the Apple Metal API driving an AMD GPU.
  ctx->name = devName + " (Apple Metal)";
  ctx->arch = archForName(devName);
  snprintf(nameOut, nameCap, "%s", ctx->name.c_str());
  snprintf(archOut, archCap, "%s", ctx->arch.c_str());
  *out = ctx;
  return nullptr;
}

void AppleGPUMetal_destroyContext(AGMetalCtx *ctx) {
  if (!ctx)
    return;
  objcRelease(ctx->queue);
  delete ctx;
}

const char *AppleGPUMetal_mtlDevice(AGMetalCtx *ctx, void **out) {
  *out = ctx->device;
  return nullptr;
}

const char *AppleGPUMetal_synchronize(AGMetalCtx *ctx) {
  // Every op is currently synchronous; an empty command buffer round-trip
  // still serializes against anything in flight.
  id cb = msg<id>(ctx->queue, "commandBuffer");
  msg<void>(cb, "commit");
  msg<void>(cb, "waitUntilCompleted");
  return nullptr;
}

const char *AppleGPUMetal_memInfo(AGMetalCtx *ctx, size_t *freeMem,
                                size_t *total) {
  unsigned long long ws =
      msg<unsigned long long>(ctx->device, "recommendedMaxWorkingSetSize");
  unsigned long long used =
      msg<unsigned long long>(ctx->device, "currentAllocatedSize");
  *total = static_cast<size_t>(ws);
  *freeMem = static_cast<size_t>(ws > used ? ws - used : 0);
  return nullptr;
}

size_t AppleGPUMetal_maxAlloc(AGMetalCtx *ctx) {
  return static_cast<size_t>(
      msg<unsigned long>(ctx->device, "maxBufferLength"));
}

int AppleGPUMetal_getAttribute(AGMetalCtx *ctx, int attr, int *out) {
  switch (attr) {
  case 1: // MAX_THREADS_PER_BLOCK
    // Ask the device rather than pinning a number. Upstream's AppleMetalFamily
    // says 1024 for every Apple family it knows, which is the fallback here.
    {
      // MTLSize maxThreadsPerThreadgroup -> {width, height, depth}
      struct MTLSize3 { unsigned long w, h, d; };
      MTLSize3 mt = msg<MTLSize3>(ctx->device, "maxThreadsPerThreadgroup");
      *out = mt.w ? static_cast<int>(mt.w) : 1024;
    }
    return 0;
  case 10: // WARP_SIZE
    // Every Apple GPU family is 32-lane (upstream AppleMetalFamily:
    // warp_size=32), unlike the Vega II's wave64 that the x86-64 fork
    // reported here.
    *out = 32;
    return 0;
  // CLOCK_RATE is deliberately NOT answered. The fork returned Vega 20's
  // 1.7GHz boost; Metal exposes no clock for Apple GPUs and upstream's
  // AppleMetalFamily carries no such field, so any number would be invented.
  // Falling through reports the usual unsupported-attribute error.
  default:
    return -1; // not handled; caller reports the usual error
  }
}

const char *AppleGPUMetal_createBuffer(AGMetalBuf **out, void **devAddr,
                                     AGMetalCtx *ctx, size_t bytes,
                                     bool host) {
  size_t allocBytes = bytes ? bytes : 1; // non-null contract, as on CPU
  const bool hostVisible = host || kUnifiedMemory;
  unsigned long options = hostVisible ? kStorageShared : kStoragePrivate;
  id buffer = msg<id>(ctx->device, "newBufferWithLength:options:",
                      static_cast<unsigned long>(allocBytes), options);
  if (!buffer)
    return agmErrorf("AppleGPURT[metal]: newBufferWithLength(%zu, %s) failed "
                     "(maxBufferLength %zu)",
                     allocBytes, hostVisible ? "shared" : "private",
                     AppleGPUMetal_maxAlloc(ctx));
  auto *buf = new AGMetalBuf();
  buf->ctx = ctx;
  buf->buffer = buffer;
  buf->ownsBuffer = true;
  buf->bytes = bytes;
  buf->isHost = host;
  buf->hostVisible = hostVisible;
  // The address handed to Mojo (and used as this buffer's registry base):
  // device buffers expose their GPU virtual address; host (shared-storage)
  // buffers expose their CPU-dereferenceable contents pointer — Mojo reads
  // and writes host buffers directly.
  buf->gpuBase = host ? reinterpret_cast<uint64_t>(msg<char *>(buffer,
                                                               "contents"))
                      : msg<unsigned long long>(buffer, "gpuAddress");
  registerRoot(buf, allocBytes);
  *out = buf;
  *devAddr = reinterpret_cast<void *>(buf->gpuBase);
  return nullptr;
}

const char *AppleGPUMetal_createSubBuffer(AGMetalBuf **out, void **devAddr,
                                        AGMetalBuf *parent, size_t offBytes,
                                        size_t bytes) {
  auto *buf = new AGMetalBuf();
  buf->ctx = parent->ctx;
  buf->buffer = parent->buffer;
  buf->ownsBuffer = false;
  buf->offset = parent->offset + offBytes;
  buf->bytes = bytes;
  buf->isHost = parent->isHost;
  buf->hostVisible = parent->hostVisible;
  buf->gpuBase = parent->gpuBase;
  *out = buf;
  *devAddr = reinterpret_cast<void *>(buf->gpuBase + buf->offset);
  return nullptr;
}

void AppleGPUMetal_destroyBuffer(AGMetalBuf *buf) {
  if (!buf)
    return;
  if (buf->ownsBuffer) {
    unregisterRoot(buf);
    objcRelease(buf->buffer);
  }
  delete buf;
}

void *AppleGPUMetal_hostPtr(AGMetalBuf *buf) {
  // Under unified memory a *device* buffer has a perfectly good CPU pointer
  // too, so this is keyed on storage rather than on the address kind.
  if (!buf->hostVisible)
    return nullptr;
  char *contents = msg<char *>(buf->buffer, "contents");
  return contents ? contents + buf->offset : nullptr;
}

const char *AppleGPUMetal_copyHtoD(AGMetalBuf *dst, const void *src,
                                 size_t bytes) {
  if (!bytes)
    return nullptr;
  AGMetalCtx *ctx = dst->ctx;
  if (dst->hostVisible) {
    memcpy(static_cast<char *>(msg<char *>(dst->buffer, "contents")) +
               dst->offset,
           src, bytes);
    return nullptr;
  }
  id staging = msg<id>(ctx->device, "newBufferWithBytes:length:options:",
                       src, static_cast<unsigned long>(bytes), kStorageShared);
  if (!staging)
    return agmErrorf("AppleGPURT[metal]: HtoD staging alloc of %zu bytes failed",
                     bytes);
  BlitOp op;
  op.src = staging;
  op.dst = dst->buffer;
  op.dstOff = dst->offset;
  op.bytes = bytes;
  const char *err = runBlitOp(ctx, op);
  objcRelease(staging);
  return err;
}

const char *AppleGPUMetal_copyDtoH(void *dst, AGMetalBuf *src, size_t bytes) {
  if (!bytes)
    return nullptr;
  AGMetalCtx *ctx = src->ctx;
  if (src->hostVisible) {
    memcpy(dst,
           static_cast<char *>(msg<char *>(src->buffer, "contents")) +
               src->offset,
           bytes);
    return nullptr;
  }
  id staging = msg<id>(ctx->device, "newBufferWithLength:options:",
                       static_cast<unsigned long>(bytes), kStorageShared);
  if (!staging)
    return agmErrorf("AppleGPURT[metal]: DtoH staging alloc of %zu bytes failed",
                     bytes);
  BlitOp op;
  op.src = src->buffer;
  op.srcOff = src->offset;
  op.dst = staging;
  op.bytes = bytes;
  const char *err = runBlitOp(ctx, op);
  if (!err)
    memcpy(dst, msg<char *>(staging, "contents"), bytes);
  objcRelease(staging);
  return err;
}

const char *AppleGPUMetal_copyDtoD(AGMetalBuf *dst, AGMetalBuf *src,
                                 size_t bytes) {
  if (!bytes)
    return nullptr;
  BlitOp op;
  op.src = src->buffer;
  op.srcOff = src->offset;
  op.dst = dst->buffer;
  op.dstOff = dst->offset;
  op.bytes = bytes;
  return runBlitOp(dst->ctx, op);
}

// Raw-address copies (DevicePointer paths): resolve through the registry.
// Device-to-device by gpuAddress, for buffers that carry an address rather
// than an MTLBuffer handle (sub-buffer views have mtl == nullptr). Both ends
// resolve through the same allocation registry the other raw copies use.
const char *AppleGPUMetal_copyRawDtoD(AGMetalCtx *ctx, uint64_t dstAddr,
                                      uint64_t srcAddr, size_t bytes) {
  size_t dstOff = 0, srcOff = 0;
  id dstBuf = resolveAddress(dstAddr, &dstOff);
  id srcBuf = resolveAddress(srcAddr, &srcOff);
  if (!dstBuf || !srcBuf)
    return agmErrorf(
        "AppleGPURT[metal]: DtoD with unknown device address 0x%llx",
        (unsigned long long)(dstBuf ? srcAddr : dstAddr));
  BlitOp op;
  op.src = srcBuf;
  op.srcOff = srcOff;
  op.dst = dstBuf;
  op.dstOff = dstOff;
  op.bytes = bytes;
  return runBlitOp(ctx, op);
}

const char *AppleGPUMetal_copyRawHtoD(AGMetalCtx *ctx, uint64_t dstAddr,
                                    const void *src, size_t bytes) {
  size_t off = 0;
  id target = resolveAddress(dstAddr, &off);
  if (!target)
    return agmErrorf("AppleGPURT[metal]: HtoD to unknown device address 0x%llx",
                     (unsigned long long)dstAddr);
  id staging = msg<id>(ctx->device, "newBufferWithBytes:length:options:",
                       src, static_cast<unsigned long>(bytes), kStorageShared);
  BlitOp op;
  op.src = staging;
  op.dst = target;
  op.dstOff = off;
  op.bytes = bytes;
  const char *err = runBlitOp(ctx, op);
  objcRelease(staging);
  return err;
}

const char *AppleGPUMetal_copyRawDtoH(AGMetalCtx *ctx, void *dst,
                                    uint64_t srcAddr, size_t bytes) {
  size_t off = 0;
  id source = resolveAddress(srcAddr, &off);
  if (!source)
    return agmErrorf("AppleGPURT[metal]: DtoH from unknown device address 0x%llx",
                     (unsigned long long)srcAddr);
  id staging = msg<id>(ctx->device, "newBufferWithLength:options:",
                       static_cast<unsigned long>(bytes), kStorageShared);
  BlitOp op;
  op.src = source;
  op.srcOff = off;
  op.dst = staging;
  op.bytes = bytes;
  const char *err = runBlitOp(ctx, op);
  if (!err)
    memcpy(dst, msg<char *>(staging, "contents"), bytes);
  objcRelease(staging);
  return err;
}

const char *AppleGPUMetal_fill(AGMetalBuf *dst, uint64_t val, size_t valSize) {
  size_t bytes = dst->bytes;
  if (!bytes)
    return nullptr;
  // fillBuffer writes a single byte pattern; usable whenever all bytes of
  // the value are equal (memset-zero being the overwhelmingly common case).
  bool uniform = true;
  uint8_t b0 = static_cast<uint8_t>(val & 0xff);
  for (size_t i = 1; i < valSize; i++)
    if (static_cast<uint8_t>((val >> (8 * i)) & 0xff) != b0)
      uniform = false;
  if (uniform) {
    BlitOp op;
    op.dst = dst->buffer;
    op.dstOff = dst->offset;
    op.bytes = bytes;
    op.fill = true;
    op.fillValue = b0;
    return runBlitOp(dst->ctx, op);
  }
  // Pattern fill: build it host-side, then one HtoD.
  std::vector<char> pattern(bytes);
  for (size_t off = 0; off + valSize <= bytes; off += valSize)
    memcpy(pattern.data() + off, &val, valSize);
  return AppleGPUMetal_copyHtoD(dst, pattern.data(), bytes);
}

//===----------------------------------------------------------------------===//
// Functions: MSL source or metallib container, per the sniff-the-blob rule.
//===----------------------------------------------------------------------===//

const char *AppleGPUMetal_loadFunction(AGMetalFunc **out, AGMetalCtx *ctx,
                                     const char *functionName,
                                     const char *data, size_t dataLen,
                                     int32_t maxDynamicSharedBytes) {
  id library = nullptr;
  id nserr = nullptr;
  if (dataLen >= 4 && memcmp(data, "MTLB", 4) == 0) {
    dispatch_data_t dd = dispatch_data_create(data, dataLen, nullptr,
                                              DISPATCH_DATA_DESTRUCTOR_DEFAULT);
    library = msg<id>(ctx->device, "newLibraryWithData:error:", dd, &nserr);
    dispatch_release(dd);
    if (!library)
      return errorFromNSError("newLibraryWithData (metallib)", nserr);
  } else {
    CFStringRef source = CFStringCreateWithBytes(
        kCFAllocatorDefault, reinterpret_cast<const UInt8 *>(data),
        static_cast<CFIndex>(dataLen), kCFStringEncodingUTF8, false);
    if (!source)
      return agmErrorf("AppleGPURT[metal]: kernel source is not valid UTF-8");
    library = msg<id>(ctx->device, "newLibraryWithSource:options:error:",
                      reinterpret_cast<id>(const_cast<void *>(
                          static_cast<const void *>(source))),
                      (id) nullptr, &nserr);
    CFRelease(source);
    if (!library)
      return errorFromNSError("newLibraryWithSource (MSL)", nserr);
  }

  CFStringRef fname = CFStringCreateWithCString(kCFAllocatorDefault,
                                                functionName,
                                                kCFStringEncodingUTF8);
  id function = msg<id>(library, "newFunctionWithName:",
                        reinterpret_cast<id>(const_cast<void *>(
                            static_cast<const void *>(fname))));
  CFRelease(fname);
  if (!function) {
    objcRelease(library);
    return agmErrorf("AppleGPURT[metal]: function '%s' not found in module",
                     functionName);
  }

  nserr = nullptr;
  // Ask for reflection. The fork used it only to read back `__vega_cap_*`
  // parameter names, and dropped it when capture hoisting went away; we need
  // it again for a better reason. Without the argument contract the launch
  // path has to guess whether an 8-byte value is a device address to bind or
  // scalar bytes to copy, and a guess is wrong in one direction or the other
  // (see AGMetalArgSlot, and TODO(air-argtypes) as was).
  //
  // MTLPipelineOptionBindingInfo(1) | MTLPipelineOptionBufferTypeInfo(2).
  id refl = nullptr;
  id pipeline =
      msg<id>(ctx->device,
              "newComputePipelineStateWithFunction:options:reflection:error:",
              function, 3ul, &refl, &nserr);
  if (!pipeline) {
    objcRelease(function);
    objcRelease(library);
    return errorFromNSError("newComputePipelineStateWithFunction", nserr);
  }

  auto *fn = new AGMetalFunc();
  fn->library = library;
  fn->function = function;
  fn->pipeline = pipeline;
  fn->name = functionName;
  fn->maxDynamicSharedBytes = maxDynamicSharedBytes;

  // Record the contract. Reflection is best-effort: if it is unavailable the
  // slots stay `known == false` and the launch path falls back to the old
  // value-based classification rather than refusing to run.
  if (refl) {
    id bindings = msg<id>(refl, "bindings");
    unsigned long n = bindings ? msg<unsigned long>(bindings, "count") : 0ul;
    for (unsigned long b = 0; b < n; b++) {
      id bind = msg<id>(bindings, "objectAtIndex:", b);
      if (!bind)
        continue;
      // MTLBindingTypeBuffer == 0; threadgroup memory and textures are bound
      // by other paths and carry no argument contract here.
      if (msg<long>(bind, "type") != 0)
        continue;
      unsigned long idx = msg<unsigned long>(bind, "index");
      unsigned long dataType = msg<unsigned long>(bind, "bufferDataType");
      unsigned long dataSize = msg<unsigned long>(bind, "bufferDataSize");
      if (fn->argSlots.size() <= idx)
        fn->argSlots.resize(idx + 1);
      fn->argSlots[idx] = {/*known=*/true,
                           /*deviceBuffer=*/dataType == 0, // MTLDataTypeNone
                           /*declaredSize=*/dataSize};
    }
  }
  *out = fn;
  return nullptr;
}

void AppleGPUMetal_destroyFunction(AGMetalFunc *fn) {
  if (!fn)
    return;
  objcRelease(fn->pipeline);
  objcRelease(fn->function);
  objcRelease(fn->library);
  delete fn;
}

//===----------------------------------------------------------------------===//
// Launch. Argument model (decoded from _device_context_metal.mojo): per-arg
// value pointers + sizes + an is-device-pointer flag per argument. Pointer
// args hold a 64-bit device address; we resolve it to (MTLBuffer, offset)
// and bind with setBuffer — which also makes the resource resident. Scalar
// args are bound with setBytes. Argument index == buffer slot index.
//===----------------------------------------------------------------------===//

const char *AppleGPUMetal_launch(AGMetalCtx *ctx, AGMetalFunc *fn,
                               const uint32_t grid[3], const uint32_t block[3],
                               uint32_t sharedMemBytes, void *const *argAddrs,
                               const uint64_t *argSizes,
                               const bool *argIsDevicePtr, uint32_t argc) {
  // Metal can silently no-op a dispatch whose threadgroup is too large for
  // the pipeline (SDL #15241); validate against the pipeline's own limit and
  // fail loudly instead.
  unsigned long maxThreads =
      msg<unsigned long>(fn->pipeline, "maxTotalThreadsPerThreadgroup");
  unsigned long requested =
      static_cast<unsigned long>(block[0]) * block[1] * block[2];
  if (maxThreads && requested > maxThreads)
    return agmErrorf("AppleGPURT[metal]: threadgroup %ux%ux%u = %lu threads "
                     "exceeds this pipeline's maxTotalThreadsPerThreadgroup "
                     "(%lu) for '%s'",
                     block[0], block[1], block[2], requested, maxThreads,
                     fn->name.c_str());

  id cb = msg<id>(ctx->queue, "commandBuffer");
  if (!cb)
    return agmErrorf("AppleGPURT[metal]: commandBuffer creation failed");
  id enc = msg<id>(cb, "computeCommandEncoder");
  msg<void>(enc, "setComputePipelineState:", fn->pipeline);

  // APPLEGPU_TRACE_LAUNCH=1 dumps what actually reaches the encoder. Argument
  // binding is the hard part of this ABI and the failure mode is silent: a
  // wrong index or a scalar bound as a buffer yields a kernel that runs,
  // reports no error, and writes nothing you asked for.
  const bool trace = ::getenv("APPLEGPU_TRACE_LAUNCH") != nullptr;
  if (trace) {
    fprintf(stderr,
            "[applegpu] launch '%s' grid=%ux%ux%u block=%ux%ux%u smem=%u "
            "argc=%u flags=%s\n",
            fn->name.c_str(), grid[0], grid[1], grid[2], block[0], block[1],
            block[2], sharedMemBytes, argc,
            argIsDevicePtr ? "explicit" : "heuristic");
  }

  for (uint32_t i = 0; i < argc; i++) {
    // Classify 8-byte args by whether their value resolves in the allocation
    // registry: a resolving address is a device pointer and binds with
    // setBuffer. DeviceBuffer host structs are {device_ptr, handle}, so the
    // address is the leading word.
    //
    // This runs even when the caller supplied explicit flags, and must, because
    // the flags are wrong for CAPTURES on this backend. _device_context_metal
    // marks every capture slot false -- "captures are raw values, never device
    // buffers" -- which holds on CUDA, where a captured pointer is just an
    // integer the kernel dereferences. It does not hold here: AirBackend
    // promotes a captured device pointer into a real addrspace(1) kernel
    // buffer parameter, so the kernel expects a BINDING, not the address bytes.
    //
    // Binding it with setBytes instead put the address value where the kernel
    // expected the buffer base, and the kernel wrote 1.0 through it into
    // nothing. That is
    // max/kernels/test/gpu/basics/test_static_layout_capture_argcount.mojo,
    // which failed with the output buffer still holding its -1.0 fill:
    //
    //   arg[0] setBytes size=8 u64=0x1000001c900   <- a live device address
    //   define void @kernel({} addrspace(1)* writeonly %0, ...)
    //
    // A false positive needs an 8-byte scalar whose value lands inside a live
    // allocation, which is unlikely but not impossible. The principled fix is
    // to ask the pipeline what each argument is -- MTLComputePipelineReflection
    // via MTLPipelineOptionArgumentInfo gives an MTLArgumentType per index --
    // and bind to that rather than inferring from the value.
    // Prefer the kernel's own contract, recorded from pipeline reflection at
    // load time (AGMetalArgSlot). It is the compiler's decision read straight
    // back, so it needs no inference.
    const AGMetalArgSlot *slot =
        (i < fn->argSlots.size() && fn->argSlots[i].known) ? &fn->argSlots[i]
                                                           : nullptr;
    bool isDev;
    // Explicit caller flags WIN over reflection when they say "device".
    //
    // The reflection discriminator -- bufferDataType == MTLDataTypeNone --
    // identifies a device buffer only for kernels WE generate, whose
    // parameter is `{} addrspace(1)*` with an opaque pointee. A kernel
    // compiled from MSL source declares `device float*`, so Metal reports
    // Float/4 and the same test calls it a constant. That is a real kernel
    // taking a real buffer, and the runtime smoke test (saxpy from MSL) is
    // exactly that shape -- it started failing the size check below the
    // moment reflection was introduced.
    //
    // Reflection is still what settles the case the flags get wrong
    // (captures, flagged false but genuinely device pointers), so the rule is
    // "device if EITHER source says so".
    const bool flaggedDev = argIsDevicePtr && argIsDevicePtr[i];
    if (slot) {
      isDev = slot->deviceBuffer || flaggedDev;
      // A constant parameter must be handed exactly the bytes it declares.
      // If the two ever disagree neither binding is right and the kernel
      // reads undefined memory, so refuse rather than run. No test trips
      // this today -- the sizes do agree everywhere we have looked, including
      // the 72- and 56-byte capture structs in test_function_mts -- which is
      // the point: it is a standing invariant on the argument contract, cheap
      // to check, and the failure it guards against is silent.
      if (!isDev && argSizes && argSizes[i] != slot->declaredSize) {
        msg<void>(enc, "endEncoding");
        return agmErrorf(
            "AppleGPURT[metal]: '%s' arg %u expects %llu bytes of constant "
            "data (air.arg_type_size), host supplied %llu. The kernel's "
            "argument contract and the launch path disagree; binding either "
            "way would read undefined memory.",
            fn->name.c_str(), i, (unsigned long long)slot->declaredSize,
            (unsigned long long)argSizes[i]);
      }
    } else {
      // No reflection: fall back to the flags, then to the registry for an
      // 8-byte value the flags call a scalar. Captures arrive flagged false
      // because that is true on CUDA, where a captured pointer is just an
      // integer the kernel dereferences; here it may be a real buffer
      // parameter.
      isDev = argIsDevicePtr ? argIsDevicePtr[i] : false;
      if (!isDev && argSizes && argSizes[i] >= 8) {
        uint64_t maybe = 0;
        memcpy(&maybe, argAddrs[i], sizeof(maybe));
        size_t off = 0;
        if (resolveAddress(maybe, &off))
          isDev = true;
      }
    }
    if (trace)
      fprintf(stderr, "  arg[%u] %s (%s)\n", i, isDev ? "device" : "constant",
              slot ? "from pipeline reflection" : "inferred, no reflection");
    if (isDev) {
      uint64_t addr = 0;
      memcpy(&addr, argAddrs[i], sizeof(addr));
      size_t off = 0;
      id buffer = resolveAddress(addr, &off);
      if (!buffer) {
        msg<void>(enc, "endEncoding");
        return agmErrorf("AppleGPURT[metal]: launch arg %u: unknown device "
                         "address 0x%llx",
                         i, (unsigned long long)addr);
      }
      msg<void>(enc, "setBuffer:offset:atIndex:", buffer,
                static_cast<unsigned long>(off), static_cast<unsigned long>(i));
      if (trace)
        fprintf(stderr, "  arg[%u] setBuffer  addr=0x%llx off=%zu\n", i,
                (unsigned long long)addr, off);
    } else {
      uint64_t size = argSizes ? argSizes[i] : 0;
      msg<void>(enc, "setBytes:length:atIndex:", argAddrs[i],
                static_cast<unsigned long>(size),
                static_cast<unsigned long>(i));
      if (trace) {
        float asF = 0;
        uint32_t asU = 0;
        if (size >= 4) {
          memcpy(&asF, argAddrs[i], 4);
          memcpy(&asU, argAddrs[i], 4);
        }
        // An 8-byte scalar that resolves in the allocation registry is almost
        // certainly a device pointer travelling as a capture, which Metal
        // cannot bind as a resource. Say so: that is the shape of the
        // TODO(air-indirect) gap, and it is invisible otherwise.
        char note[80] = "";
        if (size >= 8) {
          uint64_t w = 0;
          memcpy(&w, argAddrs[i], 8);
          size_t off = 0;
          snprintf(note, sizeof note, "  u64=0x%llx%s",
                   (unsigned long long)w,
                   resolveAddress(w, &off) ? " <-- DEVICE ADDRESS" : "");
        }
        fprintf(stderr, "  arg[%u] setBytes   size=%llu  f32=%g u32=%u%s\n", i,
                (unsigned long long)size, (double)asF, asU, note);
      }
    }
  }

  // The fork bound hoisted capture pointers here as real resources. Apple
  // Silicon dereferences them directly out of the capture buffer instead,
  // which means nothing has told Metal to keep the pointee resident -- see
  // markAllResident() for the measurement showing this is a real fault and
  // not a theoretical one.
  markAllResident(enc);

  if (sharedMemBytes)
    msg<void>(enc, "setThreadgroupMemoryLength:atIndex:",
              static_cast<unsigned long>(sharedMemBytes), 0ul);

  MTLSizeC gridSize{grid[0], grid[1], grid[2]};
  MTLSizeC blockSize{block[0], block[1], block[2]};
  msg<void>(enc, "dispatchThreadgroups:threadsPerThreadgroup:", gridSize,
            blockSize);
  msg<void>(enc, "endEncoding");
  msg<void>(cb, "commit");
  msg<void>(cb, "waitUntilCompleted");
  id err = msg<id>(cb, "error");
  if (err)
    return errorFromNSError("kernel launch failed", err);
  return nullptr;
}

} // extern "C"
