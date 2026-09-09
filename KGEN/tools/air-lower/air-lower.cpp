//===----------------------------------------------------------------------===//
// Copyright (c) 2026, Modular Inc. All rights reserved.
//
// Licensed under the Apache License v2.0 with LLVM Exceptions:
// https://llvm.org/LICENSE.txt
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//
//
// air-lower -- LLVM IR text in, Apple `.metallib` out.
//
//   air-lower kernel.ll -o kernel.metallib
//   air-lower --check-only kernel.ll
//
// The point of this tool is to make the AIR back end reachable by a compiler
// that is NOT Mojo. A frontend that can print LLVM IR as text -- with no LLVM
// linked into it at all -- gets the whole Apple GPU pipeline behind one
// subprocess call. MACVM's Smalltalk kernels are the first such consumer
// (`../MACVM/docs/gpu_kernels_design.md`).
//
// NOTHING IN HERE KNOWS WHAT AIR IS. Not an address-space number, not a
// metadata name, not a bitcode version. `TargetBackend::emitObject` is public
// and the AIR override is the entire job in one call --
//
//     legalizeModule            address spaces, captured pointers, thread-id
//                               rewriting, air.* metadata, module flags
//   → verifyBeforeEmit          while the IR is still canonical
//   → PointerRewriter           opaque pointers back to typed
//   → LLVMIRDowngradePass       constructs the LLVM-17 reader predates
//   → WriteBitcode17ToFile      the version Metal's loader accepts
//   → xcrun -sdk macosx metallib
//
// -- so this file parses, dispatches, and writes bytes. If a rule appears to
// be missing, it belongs in AirBackend.cpp; adding it here would fork the
// rules, and two copies of a rule set that must agree exactly is the failure
// this tool exists to avoid.
//
// Exit codes are a contract with the caller, which needs to tell a user error
// from a machine limitation:
//
//   0  a metallib was written
//   1  the IR was rejected -- the *code* is wrong
//   2  this machine cannot build kernels -- no xcrun, no Metal toolchain
//
// A caller maps 1 and 2 to different messages: one is fixed by editing
// source, the other by installing Xcode. Loading an existing metallib needs
// no toolchain at all, so 2 is a build-time limitation and not a run-time one.

#include "KGEN/Compiler/Target/TargetBackend.h"
#include "KGEN/ToolCommon/CompilationOptions.h"
#include "Support/Buffer.h"
#include "Target/TargetTraits.h"

#include "llvm/CodeGen/CommandFlags.h"
#include "llvm/IR/LLVMContext.h"
#include "llvm/IR/Module.h"
#include "llvm/IRReader/IRReader.h"
#include "llvm/Support/CommandLine.h"
#include "llvm/Support/FileSystem.h"
#include "llvm/Support/InitLLVM.h"
#include "llvm/Support/Program.h"
#include "llvm/Support/SourceMgr.h"
#include "llvm/Support/TargetSelect.h"
#include "llvm/Support/ToolOutputFile.h"
#include "llvm/Support/raw_ostream.h"
#include "llvm/Target/TargetMachine.h"
#include "llvm/TargetParser/Triple.h"

#include "mlir/IR/Location.h"
#include "mlir/IR/MLIRContext.h"

#include <optional>
#include <string>

// Defined in ObjectCompiler (Target/Air/AirLegality.cpp), which this tool
// already links. Forward-declared rather than pulling the header onto this
// tool's include path -- it lives under lib/, not include/. Same arrangement
// kgen-llvm-opt uses for the same function.
namespace M::KGEN::Air {
void reportLegality(llvm::Module &m);
} // namespace M::KGEN::Air

namespace {

constexpr int kOk = 0;
constexpr int kRefused = 1;
constexpr int kUnavailable = 2;

/// Options live in a struct constructed inside main, never at namespace scope:
/// this tree builds with -Werror,-Wglobal-constructors, and an `llvm::cl::opt`
/// global trips it. (kgen-llvm-opt solves the same problem with M::cl::MOpt
/// members of an M::CLOptionsBase; a plain struct is enough here.)
struct Options {
  llvm::cl::OptionCategory cat{"air-lower options"};

  llvm::cl::opt<std::string> input{
      llvm::cl::Positional, llvm::cl::desc("<input .ll or .bc>"),
      llvm::cl::init("-"), llvm::cl::cat(cat)};

  llvm::cl::opt<std::string> output{
      "o", llvm::cl::desc("Output .metallib path"),
      llvm::cl::value_desc("filename"), llvm::cl::cat(cat)};

  llvm::cl::opt<bool> checkOnly{
      "check-only",
      llvm::cl::desc("Run the AIR legality firewall and print its findings, "
                     "then stop. Writes nothing and needs no Metal toolchain. "
                     "The trailing '-- <file>: N fail' line is the summary."),
      llvm::cl::cat(cat)};

  llvm::cl::opt<std::string> mtriple{
      "mtriple", llvm::cl::desc("Override the module's target triple"),
      llvm::cl::value_desc("triple"), llvm::cl::cat(cat)};
};

/// A target may compile through a different LLVM triple than it names: AIR has
/// no codegen target of its own and rides arm64's. The traits know the
/// mapping; asking them keeps that knowledge in one place.
std::string fixTargetTriple(llvm::StringRef triple) {
  if (M::ErrorOr<const M::KGEN::TargetTraits *> traits =
          M::KGEN::TargetTraitsRegistry::get().lookup(llvm::Triple(triple));
      !traits.isError())
    return (*traits)->codegenTriple(triple);
  return triple.str();
}

/// Whether this machine can package a metallib at all.
///
/// emitObject reports a missing xcrun as an ordinary error, indistinguishable
/// from "your IR is wrong" at the exit-code level -- and those two want
/// different messages. Checking up front is also honest about a case the error
/// path would otherwise hide: xcrun present, Metal toolchain absent, which is
/// a separate Xcode component and a common state on a fresh machine.
bool metalToolchainPresent(std::string &why) {
  llvm::ErrorOr<std::string> xcrun = llvm::sys::findProgramByName("xcrun");
  if (!xcrun && llvm::sys::fs::can_execute("/usr/bin/xcrun"))
    xcrun = std::string("/usr/bin/xcrun");
  if (!xcrun) {
    why = "xcrun not found on PATH or at /usr/bin/xcrun; the AIR emitter "
          "needs the Xcode command line tools";
    return false;
  }
  llvm::SmallVector<llvm::StringRef, 6> args = {*xcrun, "-sdk", "macosx", "-f",
                                                "metallib"};
  // Silence both streams: this is a probe, and its failure is reported here.
  std::optional<llvm::StringRef> redirects[3] = {
      std::nullopt, llvm::StringRef(""), llvm::StringRef("")};
  if (llvm::sys::ExecuteAndWait(*xcrun, args, std::nullopt, redirects) != 0) {
    why = "`xcrun -sdk macosx -f metallib` failed; the Metal toolchain is not "
          "installed (it is a separate Xcode component)";
    return false;
  }
  return true;
}

} // namespace

int main(int argc, char **argv) {
  static llvm::codegen::RegisterCodeGenFlags cgFlags;
  llvm::InitLLVM x(argc, argv);

  llvm::InitializeAllTargets();
  llvm::InitializeAllTargetMCs();
  llvm::InitializeAllAsmPrinters();
  llvm::InitializeAllAsmParsers();

  Options opts;
  llvm::cl::HideUnrelatedOptions(opts.cat);
  llvm::cl::ParseCommandLineOptions(
      argc, argv, "LLVM IR -> Apple metallib, through the AIR backend\n");

  llvm::LLVMContext ctx;
  llvm::SMDiagnostic parseErr;
  std::unique_ptr<llvm::Module> module =
      llvm::parseIRFile(opts.input, parseErr, ctx);
  if (!module) {
    parseErr.print(argv[0], llvm::errs());
    return kRefused;
  }

  if (!opts.mtriple.empty())
    module->setTargetTriple(
        llvm::Triple(llvm::Triple::normalize(opts.mtriple)));

  // The firewall alone: fast, and the only mode that runs without Xcode.
  if (opts.checkOnly) {
    M::KGEN::Air::reportLegality(*module);
    return kOk;
  }

  if (opts.output.empty()) {
    llvm::errs() << argv[0] << ": -o <output.metallib> is required\n";
    return kRefused;
  }

  std::string why;
  if (!metalToolchainPresent(why)) {
    llvm::errs() << argv[0] << ": " << why << "\n";
    return kUnavailable;
  }

  // Registered at static init by linking //KGEN:ObjectCompiler, and dispatched
  // by triple. This lookup is the entire access path to the AIR pipeline.
  M::ErrorOr<const M::KGEN::TargetBackend *> backend =
      M::KGEN::TargetBackendRegistry::get().lookup(module->getTargetTriple());
  if (backend.isError()) {
    llvm::errs() << argv[0] << ": no backend for target triple '"
                 << module->getTargetTriple().str()
                 << "': " << backend.getError()
                 << "\n  (an AIR module needs a triple such as "
                    "air64_v28-apple-macosx26.0.0)\n";
    return kRefused;
  }

  llvm::Triple codegenTriple(fixTargetTriple(module->getTargetTriple().str()));
  llvm::Expected<std::unique_ptr<llvm::TargetMachine>> tm =
      llvm::codegen::createTargetMachineForTriple(codegenTriple,
                                                  llvm::CodeGenOptLevel::Default);
  if (!tm) {
    llvm::errs() << argv[0] << ": failed to create a target machine for '"
                 << codegenTriple.str() << "': " << llvm::toString(tm.takeError())
                 << "\n";
    return kRefused;
  }

  M::KGEN::CompilationOptions options(/*optimizationLevel=*/2);
  options.targetTriple = module->getTargetTriple().str();

  // AirBackend::emitObject reads no field of the EmitContext -- AIR bypasses
  // llc and the system linker entirely -- so this supplies the minimum that
  // compiles. The MLIRContext exists only to own a Location for diagnostics;
  // no MLIR pipeline runs here.
  //
  // If a future change makes emitObject read ctx.runLlc or ctx.linker, an
  // empty function_ref is a null call rather than a diagnostic. Re-check with:
  //   sed -n '/ErrorOr<BufferRef> emitObject/,/^  }/p' \
  //     KGEN/lib/Compiler/ObjectCompiler/Target/Air/AirBackend.cpp \
  //     | grep -oE 'ctx\.[a-zA-Z]+'
  mlir::MLIRContext mlirCtx;
  M::KGEN::EmitContext emitCtx{options, **tm, mlir::UnknownLoc::get(&mlirCtx)};

  M::ErrorOr<M::BufferRef> object = (*backend)->emitObject(*module, emitCtx);
  if (object.isError()) {
    llvm::StringRef msg(object.getError());
    llvm::errs() << argv[0] << ": " << msg << "\n";
    // The backend's own toolchain diagnostics, mapped to the environment code
    // even though the pre-flight probe above should have caught them.
    if (msg.contains("xcrun not found") || msg.contains("cannot execute tool") ||
        msg.contains("unable to find utility"))
      return kUnavailable;
    return kRefused;
  }

  std::error_code ec;
  llvm::ToolOutputFile out(opts.output, ec, llvm::sys::fs::OF_None);
  if (ec) {
    llvm::errs() << argv[0] << ": " << opts.output << ": " << ec.message()
                 << "\n";
    return kRefused;
  }
  out.os() << (*object)->getBuffer();
  out.os().flush();
  if (out.os().has_error()) {
    llvm::errs() << argv[0] << ": failed writing " << opts.output << "\n";
    return kRefused;
  }
  out.keep();
  return kOk;
}
