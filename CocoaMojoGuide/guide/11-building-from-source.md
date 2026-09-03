# Appendix A. Building from source

You do not need this to write CocoaMojo programs. The
[installer](01-getting-started.md) gives you a complete toolchain, and the
standard library it installs is editable. This appendix is for working on the
fork itself: the compiler, the AIR backend, the IDE.
<!-- doccrate:keep-together:start -->


## What you need

| Requirement | Why |
|:---|:---|
| Apple Silicon Mac, macOS 15+, Xcode 16+ | As for the installed toolchain |
| A checkout of [MojoCocoa](https://github.com/albanread/MojoCocoa) | The compiler and standard library |
| A checkout of [CocoaBaseMCP](https://github.com/albanread/CocoaBaseMCP) | Builds `cocoa.sqlite` |

<!-- doccrate:keep-together:end -->

The two checkouts are expected to sit beside each other. Everything below
assumes that layout; if yours differs, one environment variable fixes it.
<!-- doccrate:keep-together:start -->


## Build the SDK database

The database is built from *your* machine — the live Objective-C runtime plus
BridgeSupport — not downloaded. It takes about twelve seconds.

<!-- doccrate:keep-together:end -->
<!-- doccrate:keep-together:start -->


```bash
python3 ../CocoaBaseMCP/build.py
```

<!-- doccrate:keep-together:end -->

You get roughly 236 MB describing 28,814 classes and 522,170 methods. This is
the same database the installer generates; it is separated here only because a
source tree has no installer to do it.
<!-- doccrate:keep-together:start -->


## Build the compiler

```bash
./bazelw build --config=build-mojo --config=release //KGEN/tools/mojo:mojo
```

<!-- doccrate:keep-together:end -->

**Both `--config` flags matter.** Without them the build succeeds and produces
a compiler that cannot declare an Objective-C class, along with a `libLLVM`
containing no symbols — a failure that looks like a source problem and is not.

For everything a distribution needs, use the release script, which builds the
compiler, the shared libraries, `CompilerRT`, the language server and the
debugger, assembles `dist/CocoaMojo`, and verifies the result:
<!-- doccrate:keep-together:start -->


```bash
./tools/release.sh
```

<!-- doccrate:keep-together:end -->
<!-- doccrate:keep-together:start -->


## Point the compiler at the database

```bash
export MODULAR_MOJO_MAX_COCOAKB_PATH=/path/to/cocoa.sqlite
```

<!-- doccrate:keep-together:end -->

An assembled distribution carries its own copy and needs no variable;
`bin/cocoamojo` exports this before every build.
<!-- doccrate:keep-together:start -->


## Run a program from the source tree

There is a wrinkle worth knowing before it wastes your afternoon: the raw
`mojo-full` binary cannot locate `std.mojoc` on its own. Run Mojo through the
Bazel wrapper, which supplies the standard-library import paths:

<!-- doccrate:keep-together:end -->
<!-- doccrate:keep-together:start -->


```bash
./bazelw run //KGEN:mojo -- run /absolute/path/to/program.mojo
```

<!-- doccrate:keep-together:end -->

Note the **absolute** path. Bazel runs the wrapper in its own working
directory, so a relative path will not resolve the way you expect.
<!-- doccrate:keep-together:start -->


## Run the checks

The interesting half of the verification suite is the half that must *fail*:

<!-- doccrate:keep-together:end -->
<!-- doccrate:keep-together:start -->


```bash
./spikes/run-cocoa-checks.sh
```

<!-- doccrate:keep-together:end -->

Twelve spikes that must compile and run, and four that must be **rejected at
compile time** — sixteen checks in all. A run in which the must-fail spikes
quietly succeed is a failed run, because the design's entire claim is that
unknown names cannot reach code generation.

The four must-fail checks each pin one guarantee: an unknown metadata name
(`must_fail.mojo`), a wrong argument count (`must_fail_argcount.mojo`), a
raising `fn` (`must_fail_fn_raises.mojo`), and reassigning a `let`
(`must_fail_let_assign.mojo`).
<!-- doccrate:keep-together:start -->


## Build the IDE and an installer

Roast is built from `ide/roast.mojo` by the freshly built compiler:

<!-- doccrate:keep-together:end -->
<!-- doccrate:keep-together:start -->


```bash
./tools/make-app.sh
```

<!-- doccrate:keep-together:end -->

The disk image — payload, installer, signing, notarization, stapling and
verification — is built from the `RoastInstaller` checkout beside this one:
<!-- doccrate:keep-together:start -->


```bash
MOJOCOCOA=/path/to/MojoCocoa ../RoastInstaller/tools/make-release.sh
```

<!-- doccrate:keep-together:end -->

Signing identity and notary profile are personal and live in an ignored
`tools/signing.local.sh`. `--no-notarize` builds everything but the round trip.
