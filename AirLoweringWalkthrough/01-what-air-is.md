# 1. What AIR is

AIR — Apple Intermediate Representation — is LLVM bitcode with Apple's
metadata conventions, written for the LLVM fork inside Apple's Metal compiler.
Every `.metallib` is a container of it. When Metal Shading Language is
compiled with `xcrun metal`, AIR is what comes out of the front end; when a
pipeline state is created at run time, AIR is what the driver's compiler
service reads and turns into machine code for the GPU generation it finds
itself on.

That is the whole reason this backend exists and the whole reason it is
difficult. The GPU's instruction set is not public, the driver compiler does
that half of the job, and the only way to reach it is to *serialise* bitcode
that the reader will accept.

## A frozen reader, reached by serialisation

NVPTX and AMDGPU are in-tree LLVM backends. They consume the optimiser's
output in-process, with no serialisation and no version boundary. AIR is
reached by writing bitcode for a reader that is a frozen LLVM fork of roughly
the clang-17 era, and that boundary is where every difference between "what
modern LLVM emits" and "what a 2023 reader understands" turns fatal.

The backend states this in its own words about the optimisation pipeline:

> *AIR has no LLVM codegen target. The TargetMachine (opt pipeline only —
> emission goes through emitObject/emitBitcode) is built for arm64.*

There is no `AIRTargetMachine`, no instruction selection, no register
allocator on this side. The compiler borrows the host's arm64 target so the
ordinary LLVM pass pipeline has something to ask questions of, and then throws
the arm64 identity away before emission. Everything AIR-specific is done by
rewriting IR, not by generating code.

Three consequences follow, and every chapter of this document is about one of
them:

1. **Version skew is a correctness problem, not a warning.** A unary `fneg`,
   a `freeze`, a `poison` constant, a `range` attribute, a GEP no-wrap flag —
   ordinary modern IR — each crashes the writer or is rejected by the reader.
   The oracle finding on this quotes the number that makes it systemic: *63%
   of Modular's GPU test suite is vendor-neutral*, and those tests emit all of
   the above freely because on the two backends with real coverage they cost
   nothing. *Every "generic" test is secretly a compatibility test nobody
   wrote on purpose.*

2. **The machine model is different, and the reader does not say so.** AIR
   has no generic address space, no 64-bit floats, no three-way compare, no
   call stack, and a lane that is scalar. Code that violates any of these is
   mostly not rejected; it is compiled and computes the wrong answer, or the
   compiler service dies with a message that names nothing.

3. **The only specification is what Apple's compiler emits.** There is no AIR
   language reference. Every metadata name, every suffix on every builtin,
   every version number in this backend was read off a sample produced by
   `xcrun metal -S -emit-llvm` and confirmed against the corpus of released
   Mojo output kept in the `oracles` repository.

## The target identity is five things

The profile header opens with the observation that took a while to make:

> *The Apple target identity is five separate things that were being carried
> as scattered literals.*

<!-- doccrate:keep-together:start -->

| Fact | Value on this machine | Where it lands in the module |
|:---|:---|:---|
| GPU family | `apple-m4` | what the runtime reports; selects capabilities |
| AIR version | 2.8.0 | `!air.version`, **and** the `_v28` inside the triple |
| Metal language version | 4.0.0 | `!air.language_version` |
| SDK version | 26.0 | the `"SDK Version"` module flag |
| minimum deployment OS | 26.0.0 | the `macosx26.0.0` part of the triple |

<!-- doccrate:keep-together:end -->

Conflating them was the original defect. `metal:4` reads like a Metal
language version and actually selects M4 *hardware*. The triple, `air.version`
and `air.language_version` each had their own literal with its own comment
warning that the other two had to be changed to match. And, as the header
goes on:

> *They vary independently. The AIR and Metal versions are properties of the
> installed TOOLCHAIN, not of the chip: this machine's Metal toolchain emits
> 2.8/4.0 for an M1 as readily as an M4. The family selects capabilities.*

So a target profile is a pair — a hardware family and a *language profile* —
and the alias `apple-m4-metal4` names the pair rather than a sixth
architecture. The language profile carries the three version numbers, the SDK
and OS stamps, the bitcode writer version, and one more field worth quoting
in full because it encodes a mistake the backend has already made once:

> *`goldenVerified`: False until someone has actually run `xcrun metal -S
> -emit-llvm` under this profile and read the numbers off the result.
> Selecting an unverified profile is refused rather than guessed at — picking
> the conservative-looking one without measuring is a mistake this backend has
> already made once, and the module was rejected with no useful error.*

`kMetal4` is golden-verified: the toolchain on this machine, *Apple metal
version 32023.830*, emits triple `air64_v28-apple-macosx26.0.0`, AIR 2.8.0,
Metal 4.0.0. `kMetal3_2` — the pairing the stdlib's `info.mojo` carries as
`+metal3_2,+air2_7_0` — is deliberately left *unverified*, with zeroed SDK and
OS fields, so that selecting it fails loudly instead of stamping invented
versions. Nobody has sampled a Metal 3.2 toolchain here.

### The disagreement that looks like a bug

The stdlib maps every Apple family to the same feature string:

```mojo
`#kgen.target<triple = "air64-apple-macosx", `,
`arch = "apple-m4", `,
`features = "+metal3_2,+air2_7_0", `,
```

and the backend stamps 2.8/4.0 regardless. That is not an oversight; the
profile header explains that the backend *has always been right to*: the
installed toolchain emits 2.8/4.0, and the conservative-looking 2.7/3.2 was
tried, produced a module the reader rejected, and *taught nothing because the
error named nothing*. The feature string selects language features for the
stdlib to gate on. What the module is stamped with is what the toolchain
writes. The oracle finding that closed this checked every probe in both
Apple profiles of the corpus, nine files each, and found AIR 2.8.0 in all
eighteen — the two profiles differ only in `air.language_version`, 3.2 versus
4.0.

### Two spellings of the triple

The same finding records that Apple's reader accepts two triples:

```text
xcrun metal -S -emit-llvm k.metal   ->  target triple = "air64_v28-apple-macosx26.0.0"
released Mojo 1.0.0                 ->  target triple = "air64-apple-macosx26.0.0"
```

This port emits the `_v28` form because the profile builds it from the
version fields, which is what keeps the suffix and `!air.version` from
drifting apart — they are the same fact stated twice, and a reader that
checks both will reject a module where they differ. The optimisation
pipeline's *codegen* triple is derived from the same profile for a smaller
reason with the same shape: it used to be a literal `arm64-apple-macosx14.2.0`
in `AirTraits.h`, contradicting the AIR triple's `macosx26.0.0`, and nobody
noticed because *"the host triple" is not where you look when auditing AIR
versions*.

## Resource limits belong to the profile too

Metal's feature-set limits are module metadata, so the profile carries them
even though every Apple family currently agrees:

<!-- doccrate:keep-together:start -->

| Module flag | Value |
|:---|---:|
| `air.max_device_buffers` | 31 |
| `air.max_constant_buffers` | 31 |
| `air.max_threadgroup_buffers` | 31 |
| `air.max_textures` | 128 |
| `air.max_read_write_textures` | 8 |
| `air.max_samplers` | 16 |

<!-- doccrate:keep-together:end -->

The first of those is load-bearing for a design decision in chapter 3: a
kernel gets thirty-one buffer slots, and the x86-64 fork this backend
descends from spent one per captured pointer.

## The machine model that matters

Four facts about the hardware shape everything downstream, and each one is
invisible from the IR.

**A lane is scalar.** The backend's comment on why vectorisation is off:

> *An Apple GPU lane is scalar: SIMD is across threads, MSL vectors stop at
> four wide, and a `<16 x float>` fmul has no unit to land on.*

Thirty-two threads execute together in a simdgroup. A `float4` is a real
type; a `<16 x float>` is sixteen scalar operations wearing a costume, and it
carries insert and extract traffic the scalar form never had. Chapter 6 puts
a number on it.

**There is no generic address space.** Device memory is `addrspace(1)`,
constant argument memory is `addrspace(2)`, threadgroup memory is
`addrspace(3)`, thread-private memory is `addrspace(0)`. A pointer with no
address space is not "generic" — it is private, and it addresses nothing the
kernel was given. Across every golden sample the port has taken there are
*zero* `addrspacecast` instructions and *zero* `addrspace(0)` pointers to
anything but allocas.

**There is no call stack.** Metal kernels are fully inlined regardless of
what the IR says. The backend inlines every internal helper *first*, before
any legalisation, for reasons chapter 3 quotes.

**There is no `double`.** MSL has no 64-bit floating type, and no 128-bit
integer. A kernel that uses either is refused by legalisation with an error
naming the kernel, rather than silently demoted.

## Golden samples: the only specification there is

The project's `STATUS.md` states the technique in two commands:

```bash
xcrun metal -S -emit-llvm k.metal -o k.ll
xcrun metal -x ir -c k.ll -o k.air
```

Write the smallest MSL kernel that exercises the construct in question, read
the textual AIR the front end emits, and copy the shape exactly: the metadata
tuple order, the builtin suffix, the address space on each parameter. Then
inspect the result with the shipped `air-objdump`, `air-readobj`, `air-nm`,
`air-opt` and `air-link` tools.

The most useful output of a golden sample is inverted — *what the reference
never emits*. For Apple that list is `addrspacecast`, `addrspace(0)`, and the
native `sitofp` / `uitofp` / `fptosi` / `fptoui` casts. Every one of those
was a real defect when this backend emitted it, and, as the diagnostics
finding puts it, *each cost a separate day to find individually*.

The second oracle is the `oracles` repository beside this one: the AIR that
Modular's released compiler emits for a corpus of probe kernels, on the
`apple-m4` and `apple-m4-metal4` targets. Where Apple's compiler shows what
the reader was designed for, the released compiler shows what a *Mojo*
kernel looks like when it arrives correctly — the same generic-pointer,
NVPTX-numbered input this backend receives, already legalised by the people
who own the frontend. Both are consulted throughout, and when they disagree
(the two triple spellings, the scalar `llvm.fma.f32` Apple never emits but
the released compiler does) the reader's acceptance of both is the fact
recorded.
