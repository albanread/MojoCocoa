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
// Launches queue and batch by default, then drain at synchronization or
// host-observation boundaries. APPLEGPU_SYNC_LAUNCH=1 restores the synchronous
// bring-up mode.
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
#include <strings.h>

#include <IOKit/IOKitLib.h>
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

bool environmentFlag(const char *name, bool defaultValue) {
  const char *v = ::getenv(name);
  if (!v)
    return defaultValue;
  return *v && v[0] != '0' && ::strcasecmp(v, "off") != 0 &&
         ::strcasecmp(v, "false") != 0 && ::strcasecmp(v, "no") != 0;
}

/// Whether a dispatch may return before the GPU has finished it.
///
/// Async is the normal AsyncRT contract. `APPLEGPU_SYNC_LAUNCH=1` restores the
/// bring-up behaviour for debugging, while the old `APPLEGPU_ASYNC_LAUNCH`
/// switch remains an explicit compatibility override. Read once.
bool asyncLaunchEnabled() {
  static const bool on = [] {
    if (environmentFlag("APPLEGPU_SYNC_LAUNCH", false))
      return false;
    return environmentFlag("APPLEGPU_ASYNC_LAUNCH", true);
  }();
  return on;
}

/// Whether consecutive asynchronous dispatches share a Metal command buffer.
///
/// The synchronous debug path never batches, regardless of this setting.
/// `APPLEGPU_BATCH_DISPATCHES=0` keeps asynchronous launch but restores one
/// command buffer per dispatch for diagnosis and A/B measurement.
bool batchedLaunchEnabled() {
  static const bool on = environmentFlag("APPLEGPU_BATCH_DISPATCHES", true);
  return on;
}

/// Number of command buffers allowed in flight before a launch blocks.
/// Bounds memory and keeps error reporting close to the failing dispatch.
constexpr size_t kMaxPending = 64;
/// Preserve the existing 64-dispatch backpressure bound when those dispatches
/// are encoded into one command buffer instead of 64 separate buffers.
constexpr size_t kMaxBatchDispatches = kMaxPending;

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

/// What this device can actually answer, resolved once at context creation.
///
/// The rule here is that a value is either MEASURED from a platform property
/// or it is absent. A CUDA-shaped question Metal cannot answer is left
/// unanswered rather than filled with a plausible constant: an invented core
/// count does not fix attention dispatch, it moves the failure into kernel
/// scheduling where it is much harder to attribute.
struct AGMetalCaps {
  /// Physical GPU cores, from the IOKit AGXAccelerator registry entry
  /// (`gpu-core-count`). This is the honest analogue of a CUDA SM: an Apple
  /// GPU core has its own scheduler, register file and threadgroup memory.
  /// Zero means the property was not readable and the attribute stays
  /// unsupported.
  int coreCount = 0;
  /// `MTLDevice.architecture.name`, e.g. "applegpu_g16s". Distinct from the
  /// apple-mN family string: this is the GPU ISA generation, and it is what
  /// Apple's own offline AIR translator wants for -arch.
  std::string gpuArch;
  /// M-series generation, the Apple analogue of a CUDA compute capability:
  /// M4 -> 4, M5 -> 5. Zero means the part could not be identified.
  int generation = 0;
};

struct AGMetalCtx {
  id device = nullptr; // id<MTLDevice>, retained by MTLCopyAllDevices
  id queue = nullptr;  // id<MTLCommandQueue>
  std::string name;
  std::string arch;
  AGMetalCaps caps;
  /// Guards `pending` and `deferredError`.
  ///
  /// The synchronous path kept no mutable per-context state, so it needed no
  /// lock; asynchronous launch adds some. This backend is already reached from
  /// more than one thread -- the address registry below takes a mutex for
  /// exactly that reason -- and an unguarded `pending.push_back` from two
  /// launches at once corrupts the vector rather than merely racing.
  std::mutex mu;
  /// A drain failure seen on a path with no way to report it (hostPtr returns
  /// a pointer, not a status). Surfaced by the next synchronize.
  const char *deferredError = nullptr;
  /// Command buffers committed but not yet waited on, each retained by us.
  ///
  /// Empty unless asynchronous launch is enabled. Kept as a list rather than
  /// a single handle because a command buffer's `error` is only readable from
  /// the buffer itself: buffers on one queue complete in commit order, so
  /// waiting on the last implies the rest are done, but dropping the earlier
  /// ones would silently discard their failures.
  std::vector<id> pending;
  /// An uncommitted command buffer used by batched asynchronous launch.
  ///
  /// Each dispatch owns a separate compute encoder, so encoder state cannot
  /// leak between kernels. `mu` guards both fields and all encoding into this
  /// command buffer. The buffer is retained when opened and ownership moves to
  /// `pending` when it is committed.
  id openBatch = nullptr;
  size_t openBatchDispatches = 0;
};

/// Commit the open batch and transfer its retained ownership to `pending`.
/// The caller must hold `ctx->mu`.
void commitOpenBatchLocked(AGMetalCtx *ctx) {
  if (!ctx->openBatch)
    return;
  if (::getenv("APPLEGPU_TRACE_LAUNCH"))
    fprintf(stderr, "[applegpu] commit batch dispatches=%zu\n",
            ctx->openBatchDispatches);
  msg<void>(ctx->openBatch, "commit");
  ctx->pending.push_back(ctx->openBatch);
  ctx->openBatch = nullptr;
  ctx->openBatchDispatches = 0;
}

/// Wait for every outstanding dispatch and surface the first failure.
///
/// Buffers on one queue complete in commit order, so this walks them in order
/// and the waits after the first are already satisfied. Every buffer is
/// released whatever the outcome; the first error found is returned, and the
/// remainder are still drained so the queue is left clean for the caller.
/// The body; the caller must already hold `ctx->mu`. The wait happens under
/// the lock deliberately: a second thread must not reach device memory while
/// a drain is only half done.
const char *drainPendingLocked(AGMetalCtx *ctx) {
  commitOpenBatchLocked(ctx);
  if (ctx->pending.empty())
    return nullptr;
  const char *firstErr = nullptr;
  for (id cb : ctx->pending) {
    msg<void>(cb, "waitUntilCompleted");
    if (id err = msg<id>(cb, "error")) {
      if (!firstErr)
        firstErr = errorFromNSError("kernel launch failed", err);
    }
    objcRelease(cb);
  }
  ctx->pending.clear();
  return firstErr;
}

const char *drainPending(AGMetalCtx *ctx) {
  if (!ctx)
    return nullptr;
  std::lock_guard<std::mutex> lock(ctx->mu);
  return drainPendingLocked(ctx);
}

/// Park a drain failure that has nowhere to be returned.
///
/// First error wins. Overwriting would discard the failure that actually
/// corrupted the data the caller is about to read, in favour of a later one.
void deferError(AGMetalCtx *ctx, const char *e) {
  if (!ctx || !e)
    return;
  std::lock_guard<std::mutex> lock(ctx->mu);
  if (!ctx->deferredError)
    ctx->deferredError = e;
}

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
  /// Static threadgroup storage reported by the compiled pipeline. Metal's
  /// dispatch validator applies the device limit to this plus any dynamic
  /// allocation supplied at launch, so the runtime must do the same before it
  /// reaches an API-validation assertion.
  uint64_t staticThreadgroupBytes = 0;
  std::vector<AGMetalArgSlot> argSlots; // indexed by buffer index
  /// True when this came from an MTLB container, i.e. a metallib THIS
  /// compiler produced. False for MSL source compiled at load time.
  ///
  /// The distinction decides whether reflection can be trusted as the
  /// argument contract. Our kernels declare device parameters with an opaque
  /// pointee, so Metal reports bufferDataType == MTLDataTypeNone and that
  /// cleanly identifies a device buffer. An MSL kernel declares
  /// `device float*`, so Metal reports Float/4 and the same test would call
  /// it a constant. Same reflection API, opposite meaning, and no way to tell
  /// which you are looking at without knowing where the function came from.
  bool generated = false;
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

//===----------------------------------------------------------------------===//
// Precise residency: an MTLResidencySet mirroring the registry
//===----------------------------------------------------------------------===//
//
// markAllResident() declares every live root buffer to every compute encoder,
// one useResource: call per buffer per dispatch, under the registry lock.
// That is correct and O(live allocations) per dispatch -- the cost of a
// dispatch grows with every unrelated allocation in the process, which
// AIR_EXPERIMENTS.md item 6 names as the next runtime scaling defect.
//
// MTLResidencySet inverts the cost. The set is attached to the command queue
// once; membership is edited when an allocation is created or destroyed and
// committed then -- O(changes), off the dispatch path entirely. Metal keeps
// everything in an attached, committed set resident for all command buffers
// on that queue, which is exactly the guarantee useResource was providing,
// minus the per-dispatch walk.
//
// The registry stays the source of truth; the set mirrors it. Sub-views are
// covered by their root's membership, the same way the registry covers them.
//
// Per DEVICE, not per context: the registry is global because a capture blob
// may carry any live device address, so the residency guarantee must span
// contexts too. Two contexts on one device share a set; the set is attached
// to both queues.
//
// This is the runtime half of item 6. The compiler half -- describing which
// buffers a kernel can actually reach, so the set could shrink below "all of
// them" -- still wants air.indirect_buffer/air.struct_type_info, but the
// scaling defect is the per-dispatch walk, and that dies here.
//
// APPLEGPU_COARSE_RESIDENCY=1 restores the walk: the diagnostic escape hatch,
// and the A side of the benchmark. Devices without the API (pre-macOS 15) get
// the walk automatically.

struct ResidencyState {
  std::mutex mu;
  bool coarse = false;  // forced off by env, or unavailable on this device
  bool decided = false;
  // device -> id<MTLResidencySet>, one entry per device ever seen. Never
  // destroyed, like the registry: allocations may outlive any one context.
  std::vector<std::pair<id, id>> sets;
};
ResidencyState &residency() {
  static ResidencyState *s = new ResidencyState(); // never destroyed
  return *s;
}

// The set for a device, created on first sight. nil when unsupported, and
// that answer is stable for the lifetime of the process.
id residencySetForLocked(ResidencyState &st, id device) {
  if (!st.decided) {
    st.coarse = ::getenv("APPLEGPU_COARSE_RESIDENCY") != nullptr;
    st.decided = true;
  }
  if (st.coarse || !device)
    return nullptr;
  for (auto &e : st.sets)
    if (e.first == device)
      return e.second;

  id set = nullptr;
  // The factory is `new`-prefixed -- newResidencySetWithDescriptor:error: --
  // so it returns a +1-retained set that this never-destroyed singleton keeps.
  // The earlier `make...` spelling does not exist on MTLDevice: respondsToSelector
  // answered no, the set was never created, and every launch silently ran the
  // useResource walk instead. That the fallback is correct is exactly what hid
  // the bug -- results were right, the optimisation just never executed.
  Class descClass = objc_getClass("MTLResidencySetDescriptor");
  if (descClass &&
      msg<signed char>(device, "respondsToSelector:",
                       sel_registerName("newResidencySetWithDescriptor:error:"))) {
    id desc = msg<id>(msg<id>((id)descClass, "alloc"), "init");
    if (desc) {
      set = msg<id>(device, "newResidencySetWithDescriptor:error:", desc,
                    (id *)nullptr);
      objcRelease(desc);
      // No extra retain: `new` already handed us +1.
    }
  }
  // A nil set is recorded too: the decision is per device, made once, and a
  // device that cannot make one falls back to the walk forever.
  st.sets.push_back({device, set});
  return set;
}

bool residencyActiveFor(id device) {
  auto &st = residency();
  std::lock_guard<std::mutex> lock(st.mu);
  return residencySetForLocked(st, device) != nullptr;
}

void residencyAttach(id device, id queue) {
  auto &st = residency();
  std::lock_guard<std::mutex> lock(st.mu);
  id set = residencySetForLocked(st, device);
  if (set && queue)
    msg<void>(queue, "addResidencySet:", set);
}

void residencyAdd(id device, id buffer) {
  auto &st = residency();
  std::lock_guard<std::mutex> lock(st.mu);
  id set = residencySetForLocked(st, device);
  if (!set || !buffer)
    return;
  msg<void>(set, "addAllocation:", buffer);
  msg<void>(set, "commit");
}

void residencyRemove(id device, id buffer) {
  auto &st = residency();
  std::lock_guard<std::mutex> lock(st.mu);
  id set = residencySetForLocked(st, device);
  if (!set || !buffer)
    return;
  msg<void>(set, "removeAllocation:", buffer);
  msg<void>(set, "commit");
}

void registerRoot(AGMetalBuf *buf, size_t fullBytes) {
  {
    auto &r = registry();
    std::lock_guard<std::mutex> lock(r.mu);
    r.map[buf->gpuBase] = {buf, fullBytes};
  }
  // Mirrored after the registry write, never under its lock: the two locks
  // are independent and nothing may hold both.
  if (buf->ctx)
    residencyAdd(buf->ctx->device, buf->buffer);
}

void unregisterRoot(const AGMetalBuf *buf) {
  {
    auto &r = registry();
    std::lock_guard<std::mutex> lock(r.mu);
    auto it = r.map.find(buf->gpuBase);
    if (it != r.map.end() && it->second.first == buf)
      r.map.erase(it);
  }
  if (buf->ctx)
    residencyRemove(buf->ctx->device, buf->buffer);
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

/// Physical GPU core count, straight from the driver.
///
/// Metal itself exposes no core/SM count, which is why this attribute was
/// unanswered. But the AGXAccelerator IOKit entry publishes `gpu-core-count`,
/// and that is a real hardware property rather than a guess -- 32 on an
/// M4 Max, 10 on a base M2. Searching parents matters: the property lives on
/// the accelerator's parent entry on some machines.
///
/// Returns 0 if it cannot be read, and the caller then leaves the attribute
/// unsupported rather than substituting a number.
int queryGpuCoreCount() {
  int cores = 0;
  io_iterator_t it = 0;
  if (IOServiceGetMatchingServices(kIOMainPortDefault,
                                   IOServiceMatching("AGXAccelerator"),
                                   &it) != KERN_SUCCESS)
    return 0;
  io_object_t svc;
  while ((svc = IOIteratorNext(it))) {
    CFTypeRef v = IORegistryEntrySearchCFProperty(
        svc, kIOServicePlane, CFSTR("gpu-core-count"), kCFAllocatorDefault,
        kIORegistryIterateRecursively | kIORegistryIterateParents);
    if (v) {
      if (CFGetTypeID(v) == CFNumberGetTypeID())
        CFNumberGetValue((CFNumberRef)v, kCFNumberIntType, &cores);
      else if (CFGetTypeID(v) == CFDataGetTypeID() &&
               CFDataGetLength((CFDataRef)v) >= 4)
        memcpy(&cores, CFDataGetBytePtr((CFDataRef)v), 4);
      CFRelease(v);
    }
    IOObjectRelease(svc);
    if (cores)
      break;
  }
  IOObjectRelease(it);
  return cores;
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

/// The Apple analogue of a CUDA compute capability: the M-series generation,
/// so M4 -> 4 and M5 -> 5.
///
/// Exactly one distinction is load-bearing in the kernel library -- `== 5` --
/// and it gates the 16x16 simdgroup MMA (`enqueue_apple_matmul`, the FP4/FP8
/// tiled paths, the MMA flash-attention prefill). Metal answers that question
/// itself: the driver refuses those pipelines with "simdgroup_matrix<T,16,16x16>
/// operations are supported by GPUFamily10 and later", so MTLGPUFamilyApple10
/// IS the M5 predicate and is used as one here rather than trusting a marketing
/// name. Earlier parts come from the arch string `archForName` already derived.
///
/// Reporting 0 -- which this binding did unconditionally, with the comment
/// "meaningful for CUDA only" -- is not a harmless default. Every guard in the
/// kernels is spelled `compute_capability() != 5`, so a hard zero disables the
/// M5 fast paths on M5 hardware and makes every Apple GPU report
/// "got compute_capability=0" when it declines.
int queryGpuGeneration(id device, const std::string &arch) {
  // MTLGPUFamilyApple10 == 1010. M5 is the first part to advertise it, and it
  // is precisely the family the 16x16 simdgroup MMA requires.
  bool family10 = msg<bool>(device, "supportsFamily:", (long)1010);
  int named = 0;
  auto pos = arch.rfind("-m");
  if (pos != std::string::npos && pos + 2 < arch.size()) {
    char c = arch[pos + 2];
    if (c >= '1' && c <= '9')
      named = c - '0';
  }
  if (family10) {
    // Family10 IS the predicate, so it answers 5 whatever the part is called.
    // Returning `named` for a later part would be worse than useless: every
    // fast path in the kernel library is spelled `== 5` -- grouped_matmul.mojo,
    // matmul/gpu/__init__.mojo, fp8_gemv.mojo, fp4_matmul.mojo,
    // matmul_kernel.mojo -- so an M6 reporting 6 would silently disable on
    // newer hardware precisely the paths Family10 says that hardware has.
    if (named > 5)
      fprintf(stderr,
              "[applegpu] note: device arch '%s' names generation %d; the "
              "driver advertises MTLGPUFamilyApple10, so reporting 5, the "
              "generation the kernel guards are written against\n",
              arch.c_str(), named);
    return 5;
  }
  // No Family10: the 16x16 MMA is absent whatever the part is called, so never
  // report 5 here. A part named M5+ without the family would be a Metal or
  // naming change worth seeing rather than silently rounding away.
  if (named >= 5) {
    fprintf(stderr,
            "[applegpu] warning: device arch '%s' names generation %d but the "
            "driver does not advertise MTLGPUFamilyApple10; reporting 4\n",
            arch.c_str(), named);
    return 4;
  }
  return named;
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
  // Attach the device's residency set, so everything committed to it is
  // resident for every command buffer this queue will ever run. This is what
  // retires the per-dispatch markAllResident() walk; see the ResidencyState
  // comment for the whole story.
  residencyAttach(ctx->device, ctx->queue);
  std::string devName = nsstringToStd(msg<id>(ctx->device, "name"));
  // test_smoke requires "Apple" in the name when api == "metal"; truthfully,
  // this is the Apple Metal API driving an AMD GPU.
  ctx->name = devName + " (Apple Metal)";
  ctx->arch = archForName(devName);
  // Resolve capabilities once, here, rather than per query: the IOKit lookup
  // walks the registry and this is asked on every dispatch-shaping decision.
  ctx->caps.coreCount = queryGpuCoreCount();
  ctx->caps.generation = queryGpuGeneration(ctx->device, ctx->arch);
  if (const char *t = ::getenv("APPLEGPU_TRACE_CAPS"))
    (void)t, fprintf(stderr,
                     "[applegpu] caps device='%s' arch=%s cores=%d gen=%d\n",
                     devName.c_str(), ctx->arch.c_str(), ctx->caps.coreCount,
                     ctx->caps.generation);
  snprintf(nameOut, nameCap, "%s", ctx->name.c_str());
  snprintf(archOut, archCap, "%s", ctx->arch.c_str());
  *out = ctx;
  return nullptr;
}

void AppleGPUMetal_destroyContext(AGMetalCtx *ctx) {
  if (!ctx)
    return;
  // Asynchronous launch may still have command buffers in flight, and waiting
  // is not optional here: each is retained by us so dropping it leaks, its
  // error is readable only from the buffer itself, and the GPU is still
  // writing through the queue we are about to release. There is no status to
  // return from a destructor, so say it out loud instead of losing it.
  if (const char *e = drainPending(ctx))
    fprintf(stderr, "[applegpu] %s (during context teardown)\n", e);
  objcRelease(ctx->queue);
  delete ctx;
}

const char *AppleGPUMetal_mtlDevice(AGMetalCtx *ctx, void **out) {
  *out = ctx->device;
  return nullptr;
}

const char *AppleGPUMetal_synchronize(AGMetalCtx *ctx) {
  // Drain whatever asynchronous launch left in flight. This is where a failed
  // dispatch is reported when launches no longer wait individually.
  if (const char *e = drainPending(ctx))
    return e;
  {
    std::lock_guard<std::mutex> lock(ctx->mu);
    if (const char *e = ctx->deferredError) {
      ctx->deferredError = nullptr;
      return e;
    }
  }
  // An empty command-buffer round trip still serialises against anything the
  // queue holds that we did not submit ourselves.
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

/// M-series generation for this device (M4 -> 4, M5 -> 5), 0 if unidentified.
/// Resolved once at context creation; see `queryGpuGeneration`.
int AppleGPUMetal_computeCapability(AGMetalCtx *ctx) {
  return ctx ? ctx->caps.generation : 0;
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
  case 16: // MULTIPROCESSOR_COUNT
    // Metal exposes no SM count, so this was unanswered -- and an unanswered
    // attribute RAISES (DeviceContext.get_attribute wraps it in _checked), it
    // does not return a sentinel. That is what blocks the Apple attention and
    // KV-cache group, though not by the route it looks like: the MHA split-K
    // heuristic already guards this query behind `api == "cuda" or "hip"`.
    // The unconditional one is _softmax_gpu (softmax.mojo:1131), reached from
    // mha_gpu_naive, which every one of those tests runs as its reference.
    //
    // Answer it with the physical GPU core count from IOKit -- a measured
    // hardware property, not a CUDA constant. Cores are the honest analogue:
    // each has its own scheduler, register file and threadgroup memory.
    //
    // The value is used three ways in _softmax_gpu, and only one of them cares
    // what it is. Two are occupancy caps on a grid-stride kernel, where any
    // count >= 1 is functionally correct. The third picks a split-K factor,
    // and num_splits > 1 switches to a two-launch partial-max/partial-sum
    // reducer -- mathematically equivalent, but a different floating-point
    // reduction ORDER. A core count is small enough (32 here) that
    // blocks_per_sm * sm_count stays below the row count on realistic
    // attention shapes, so num_splits stays 1 and numerics are untouched.
    // A large invented value would silently change which kernel runs.
    if (ctx->caps.coreCount <= 0)
      return -1; // unreadable: stay unsupported rather than invent one
    // pad_gpu.mojo divides by this, so zero must never escape as a value.
    *out = ctx->caps.coreCount;
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
  // Metal requires an app to keep resources alive until every encoded use
  // has completed. Every host-observation path drains first (hostPtr, the
  // copy family), but destruction IS an observation of the buffer by the
  // host and skipped the drain: under asynchronous launch a committed but
  // unwaited dispatch could still be reading this buffer when it was
  // released and its registry/residency entries torn down. Drain here so
  // the release and the unregisterRoot below happen only once the GPU is
  // done. Deferred errors surface at the next synchronize, as elsewhere.
  if (buf->ownsBuffer && buf->ctx)
    if (const char *e = drainPending(buf->ctx))
      deferError(buf->ctx, e);
  if (buf->ownsBuffer) {
    unregisterRoot(buf);
    objcRelease(buf->buffer);
  }
  delete buf;
}

void *AppleGPUMetal_hostPtr(AGMetalBuf *buf) {
  // Device memory is about to be observed or overwritten from the host.
  // With asynchronous launch a dispatch may still be running, and the
  // unified-memory fast path below is a bare memcpy with no implicit
  // ordering, so drain first or read a half-written buffer.
  if (const char *e = drainPending(buf->ctx))
    deferError(buf->ctx, e);

  // Under unified memory a *device* buffer has a perfectly good CPU pointer
  // too, so this is keyed on storage rather than on the address kind.
  if (!buf->hostVisible)
    return nullptr;
  char *contents = msg<char *>(buf->buffer, "contents");
  return contents ? contents + buf->offset : nullptr;
}

const char *AppleGPUMetal_copyHtoD(AGMetalBuf *dst, const void *src,
                                 size_t bytes) {
  // Device memory is about to be observed or overwritten from the host.
  // With asynchronous launch a dispatch may still be running, and the
  // unified-memory fast path below is a bare memcpy with no implicit
  // ordering, so drain first or read a half-written buffer.
  if (const char *e = drainPending(dst->ctx))
    return e;

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
  // Device memory is about to be observed or overwritten from the host.
  // With asynchronous launch a dispatch may still be running, and the
  // unified-memory fast path below is a bare memcpy with no implicit
  // ordering, so drain first or read a half-written buffer.
  if (const char *e = drainPending(src->ctx))
    return e;

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
  // Device memory is about to be observed or overwritten from the host.
  // With asynchronous launch a dispatch may still be running, and the
  // unified-memory fast path below is a bare memcpy with no implicit
  // ordering, so drain first or read a half-written buffer.
  if (const char *e = drainPending(dst->ctx))
    return e;

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
  // Device memory is about to be observed or overwritten from the host.
  // With asynchronous launch a dispatch may still be running, and the
  // unified-memory fast path below is a bare memcpy with no implicit
  // ordering, so drain first or read a half-written buffer.
  if (const char *e = drainPending(ctx))
    return e;

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
  // Device memory is about to be observed or overwritten from the host.
  // With asynchronous launch a dispatch may still be running, and the
  // unified-memory fast path below is a bare memcpy with no implicit
  // ordering, so drain first or read a half-written buffer.
  if (const char *e = drainPending(ctx))
    return e;

  size_t off = 0;
  id target = resolveAddress(dstAddr, &off);
  if (!target)
    return agmErrorf("AppleGPURT[metal]: HtoD to unknown device address 0x%llx",
                     (unsigned long long)dstAddr);
  id staging = msg<id>(ctx->device, "newBufferWithBytes:length:options:",
                       src, static_cast<unsigned long>(bytes), kStorageShared);
  if (!staging)
    return agmErrorf(
        "AppleGPURT[metal]: raw HtoD staging alloc of %zu bytes failed",
        bytes);
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
  // Device memory is about to be observed or overwritten from the host.
  // With asynchronous launch a dispatch may still be running, and the
  // unified-memory fast path below is a bare memcpy with no implicit
  // ordering, so drain first or read a half-written buffer.
  if (const char *e = drainPending(ctx))
    return e;

  size_t off = 0;
  id source = resolveAddress(srcAddr, &off);
  if (!source)
    return agmErrorf("AppleGPURT[metal]: DtoH from unknown device address 0x%llx",
                     (unsigned long long)srcAddr);
  id staging = msg<id>(ctx->device, "newBufferWithLength:options:",
                       static_cast<unsigned long>(bytes), kStorageShared);
  if (!staging)
    return agmErrorf(
        "AppleGPURT[metal]: raw DtoH staging alloc of %zu bytes failed",
        bytes);
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
  // Device memory is about to be observed or overwritten from the host.
  // With asynchronous launch a dispatch may still be running, and the
  // unified-memory fast path below is a bare memcpy with no implicit
  // ordering, so drain first or read a half-written buffer.
  if (const char *e = drainPending(dst->ctx))
    return e;

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
  const bool generated = dataLen >= 4 && memcmp(data, "MTLB", 4) == 0;
  if (generated) {
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
  fn->generated = generated;
  fn->maxDynamicSharedBytes = maxDynamicSharedBytes;
  fn->staticThreadgroupBytes =
      msg<unsigned long>(pipeline, "staticThreadgroupMemoryLength");

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
  const bool async = asyncLaunchEnabled();
  const bool batching = async && batchedLaunchEnabled();

  auto flushOpenBatchForLaunchError = [&] {
    if (!batching)
      return;
    std::lock_guard<std::mutex> lock(ctx->mu);
    commitOpenBatchLocked(ctx);
  };

  // Metal can silently no-op a dispatch whose threadgroup is too large for
  // the pipeline (SDL #15241); validate against the pipeline's own limit and
  // fail loudly instead.
  unsigned long maxThreads =
      msg<unsigned long>(fn->pipeline, "maxTotalThreadsPerThreadgroup");
  unsigned long requested =
      static_cast<unsigned long>(block[0]) * block[1] * block[2];
  if (maxThreads && requested > maxThreads) {
    flushOpenBatchForLaunchError();
    return agmErrorf("AppleGPURT[metal]: threadgroup %ux%ux%u = %lu threads "
                     "exceeds this pipeline's maxTotalThreadsPerThreadgroup "
                     "(%lu) for '%s'",
                     block[0], block[1], block[2], requested, maxThreads,
                     fn->name.c_str());
  }

  if (fn->maxDynamicSharedBytes >= 0 &&
      static_cast<uint64_t>(sharedMemBytes) >
          static_cast<uint64_t>(fn->maxDynamicSharedBytes)) {
    flushOpenBatchForLaunchError();
    return agmErrorf(
        "AppleGPURT[metal]: dynamic threadgroup memory %u bytes exceeds "
        "the compiled maximum %d for '%s'",
        sharedMemBytes, fn->maxDynamicSharedBytes, fn->name.c_str());
  }

  const uint64_t maxThreadgroupBytes =
      msg<unsigned long>(ctx->device, "maxThreadgroupMemoryLength");
  const uint64_t totalThreadgroupBytes =
      fn->staticThreadgroupBytes + static_cast<uint64_t>(sharedMemBytes);
  if (maxThreadgroupBytes && totalThreadgroupBytes > maxThreadgroupBytes) {
    flushOpenBatchForLaunchError();
    return agmErrorf(
        "AppleGPURT[metal]: threadgroup memory for '%s' is %llu bytes "
        "(%llu static + %u dynamic), exceeding this device's %llu-byte "
        "limit",
        fn->name.c_str(), (unsigned long long)totalThreadgroupBytes,
        (unsigned long long)fn->staticThreadgroupBytes, sharedMemBytes,
        (unsigned long long)maxThreadgroupBytes);
  }

  std::unique_lock<std::mutex> batchLock(ctx->mu, std::defer_lock);
  id cb = nullptr;
  if (batching) {
    batchLock.lock();
    if (!ctx->openBatch) {
      // Error paths can commit a partially filled batch before it reaches the
      // normal dispatch-count limit. Keep those command buffers bounded too:
      // drain before opening another one once the retained-buffer limit is
      // reached, surfacing any earlier GPU failure at this launch boundary.
      if (ctx->pending.size() >= kMaxPending) {
        if (const char *err = drainPendingLocked(ctx))
          return err;
      }
      ctx->openBatch = msg<id>(ctx->queue, "commandBuffer");
      if (ctx->openBatch)
        msg<id>(ctx->openBatch, "retain");
    }
    cb = ctx->openBatch;
  } else {
    cb = msg<id>(ctx->queue, "commandBuffer");
  }
  if (!cb)
    return agmErrorf("AppleGPURT[metal]: commandBuffer creation failed");
  id enc = msg<id>(cb, "computeCommandEncoder");
  if (!enc) {
    if (batching) {
      commitOpenBatchLocked(ctx);
    } else {
      // Command buffers occupy queue order when they are created, not only
      // after a successful dispatch is encoded. Commit this empty buffer so a
      // later launch cannot stall behind an abandoned predecessor.
      msg<void>(cb, "commit");
    }
    return agmErrorf("AppleGPURT[metal]: computeCommandEncoder failed");
  }
  msg<void>(enc, "setComputePipelineState:", fn->pipeline);

  auto endEncodingForError = [&] {
    msg<void>(enc, "endEncoding");
    // Preserve any valid dispatches encoded by earlier calls. This call has
    // not dispatched yet, so committing an encoder containing only its
    // partial bindings is harmless and makes the earlier work drainable.
    if (batching) {
      commitOpenBatchLocked(ctx);
    } else {
      // Leaving an ended-but-uncommitted command buffer on a queue can block
      // later committed buffers because Metal preserves creation order.
      msg<void>(cb, "commit");
    }
  };

  // APPLEGPU_TRACE_LAUNCH=1 dumps what actually reaches the encoder. Argument
  // binding is the hard part of this ABI and the failure mode is silent: a
  // wrong index or a scalar bound as a buffer yields a kernel that runs,
  // reports no error, and writes nothing you asked for.
  const bool trace = ::getenv("APPLEGPU_TRACE_LAUNCH") != nullptr;
  if (trace) {
    fprintf(stderr,
            "[applegpu] launch '%s' grid=%ux%ux%u block=%ux%ux%u smem=%u "
            "argc=%u flags=%s batch=%s static-smem=%llu\n",
            fn->name.c_str(), grid[0], grid[1], grid[2], block[0], block[1],
            block[2], sharedMemBytes, argc,
            argIsDevicePtr ? "explicit" : "heuristic",
            batching ? "open" : "off",
            (unsigned long long)fn->staticThreadgroupBytes);
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
    if (fn->generated) {
      // Compiler-generated metallib: reflection IS the contract.
      //
      // Every slot must be known. A generated kernel whose reflection does not
      // describe an index the caller is binding means the compiler and the
      // driver disagree about the signature, and guessing which is right is
      // how a scalar gets bound as a buffer.
      if (!slot) {
        endEncodingForError();
        return agmErrorf(
            "AppleGPURT[metal]: '%s' is a compiler-generated kernel but "
            "pipeline reflection describes no argument at index %u, while the "
            "host is binding %u. The compiler's signature and the driver's "
            "reflected contract disagree.",
            fn->name.c_str(), i, argc);
      }
      // Caller flags are CHECKED against reflection, never allowed to
      // override it. A flag that disagrees is a real contract mismatch and
      // worth saying so, but the kernel's own declaration wins.
      isDev = slot->deviceBuffer;
      if (argIsDevicePtr && flaggedDev != isDev)
        fprintf(stderr,
                "[applegpu] '%s' arg %u: caller says %s, reflection says %s; "
                "using reflection\n",
                fn->name.c_str(), i, flaggedDev ? "device" : "constant",
                isDev ? "device" : "constant");
    } else if (slot) {
      // Raw MSL, with reflection available but not decisive: the
      // MTLDataTypeNone discriminator does not identify a device buffer here,
      // so either source saying "device" is taken at its word.
      isDev = slot->deviceBuffer || flaggedDev;
      // A constant parameter must be handed exactly the bytes it declares.
      // If the two ever disagree neither binding is right and the kernel
      // reads undefined memory, so refuse rather than run. No test trips
      // this today -- the sizes do agree everywhere we have looked, including
      // the 72- and 56-byte capture structs in test_function_mts -- which is
      // the point: it is a standing invariant on the argument contract, cheap
      // to check, and the failure it guards against is silent.
      if (!isDev && argSizes && argSizes[i] != slot->declaredSize) {
        endEncodingForError();
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
        endEncodingForError();
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
          if (::getenv("APPLEGPU_TRACE_BLOB") && size >= 8) {
            // A descriptor blob is opaque from the host side: pointers, shapes
            // and strides packed by the frontend and decoded by the kernel.
            // When the two disagree the only symptom is a buffer of zeros, so
            // dump the words and mark the ones the registry recognises.
            const uint64_t *w = (const uint64_t *)argAddrs[i];
            for (uint64_t k = 0; k < size / 8; ++k) {
              size_t off = 0;
              bool dev = resolveAddress(w[k], &off);
              fprintf(stderr, "      [%2llu] 0x%016llx  %20lld%s\n",
                      (unsigned long long)k, (unsigned long long)w[k],
                      (long long)w[k], dev ? "   <-- DEVICE PTR" : "");
            }
          }
      }
    }
  }

  // The fork bound hoisted capture pointers here as real resources. Apple
  // Silicon dereferences them directly out of the capture buffer instead,
  // which means something has to tell Metal to keep every pointee resident.
  // Normally that is the queue's residency set, maintained as allocations
  // come and go -- O(changes), nothing on this path. The walk below is the
  // fallback: the same guarantee, declared to this one encoder, at a cost
  // that grows with every live allocation in the process. It runs when the
  // device has no residency-set API, or when APPLEGPU_COARSE_RESIDENCY=1
  // forces it for diagnosis or measurement.
  if (!residencyActiveFor(ctx->device))
    markAllResident(enc);

  if (sharedMemBytes)
    msg<void>(enc, "setThreadgroupMemoryLength:atIndex:",
              static_cast<unsigned long>(sharedMemBytes), 0ul);

  MTLSizeC gridSize{grid[0], grid[1], grid[2]};
  MTLSizeC blockSize{block[0], block[1], block[2]};
  msg<void>(enc, "dispatchThreadgroups:threadsPerThreadgroup:", gridSize,
            blockSize);
  msg<void>(enc, "endEncoding");

  if (batching) {
    ++ctx->openBatchDispatches;
    // Preserve the old 64-dispatch memory/error-locality bound. A full batch
    // is committed and drained here; shorter batches commit at synchronize,
    // host observation, or teardown through drainPendingLocked().
    if (ctx->openBatchDispatches >= kMaxBatchDispatches) {
      commitOpenBatchLocked(ctx);
      return drainPendingLocked(ctx);
    }
    return nullptr;
  }

  msg<void>(cb, "commit");

  // Synchronous launch waits here, which costs a full CPU-GPU round trip per
  // dispatch. Measured against Modular's shipping release on the same M4 Max,
  // that tax is ~0.40ms and constant: it dominates short kernels and vanishes
  // on long ones, which is exactly the curve that looked like a codegen gap.
  //
  // Asynchronous launch hands the buffer to the queue and returns. Every path
  // that observes device memory -- synchronize, the D2H copies, hostPtr --
  // drains first, so ordering is still guaranteed to the caller; what changes
  // is only that ten dispatches no longer cost ten drains.
  //
  // Take ownership of the buffer FIRST. It is already committed, so any path
  // that returns without recording it leaves work running that no later drain
  // can wait on -- and the copy-out that follows then memcpys a buffer the GPU
  // is still writing, which is the very race these drains exist to prevent.
  if (async) {
    msg<id>(cb, "retain");
    std::lock_guard<std::mutex> lock(ctx->mu);
    ctx->pending.push_back(cb);
    // Backpressure: once the queue is deep enough, drain it -- this buffer
    // included, so one launch in kMaxPending pays a full round trip and the
    // rest pay none. Errors from anything in the window surface here.
    if (ctx->pending.size() >= kMaxPending)
      return drainPendingLocked(ctx);
    return nullptr;
  }

  msg<void>(cb, "waitUntilCompleted");
  id err = msg<id>(cb, "error");
  if (err)
    return errorFromNSError("kernel launch failed", err);
  return nullptr;
}

} // extern "C"
