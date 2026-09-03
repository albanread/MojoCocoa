# 1. Getting started

CocoaMojo ships as a signed, notarized disk image containing an installer and
**Roast**, a Mac IDE for Mojo written in Mojo. Installing it gives you the
compiler, the standard library, the language server, the debugger, the
examples, and an editor to run them in.

This chapter takes you from that disk image to a running Cocoa program. If you
want to build the fork from source instead, that is
[Appendix A](11-building-from-source.md); you do not need it to write anything.
<!-- doccrate:keep-together:start -->


## What you need

| Requirement | Why |
|:---|:---|
| Apple Silicon Mac | The fork targets `arm64` Darwin and hardcodes it deliberately |
| macOS 15 or later | The metadata is built from the live Objective-C runtime on your machine |
| Xcode 16 or later | Supplies the SDK the database is built from, and the AIR toolchain if you go near the GPU |

<!-- doccrate:keep-together:end -->

There is an Intel build for the 2019 Mac Pro as well. Everything in this guide
applies to it unchanged except the GPU chapters, which describe Apple Silicon.
<!-- doccrate:keep-together:start -->


## Install

Open the disk image, double-click **Install Roast**, and press **Install**.

<!-- doccrate:keep-together:end -->

Two things happen, and the second is the slow one:

1. The toolchain is copied to `/Applications/Roast`.
2. **`cocoa.sqlite` is built from your Mac's SDK**, with a progress bar. It is
   not downloaded, because it describes *your* machine: roughly 236 MB covering
   28,814 classes and 522,170 methods, read out of the live Objective-C runtime
   and BridgeSupport.

That second step is the whole idea of this fork. The compiler answers questions
about macOS *while your program is being compiled*, and it answers them from
the SDK you actually have.

If you install again later the button reads **Reinstall**, and that is also the
answer to "I updated macOS" — see [After a macOS update](#after-a-macos-update).
<!-- doccrate:keep-together:start -->


## Where everything is

The installed toolchain:

<!-- doccrate:keep-together:end -->
<!-- doccrate:keep-together:start -->


```text
/Applications/Roast/
    CocoaMojo/
        2026.08.31.2/        one directory per installed version
        current -> 2026.08.31.2
    Roast.app
```

<!-- doccrate:keep-together:end -->

Versions sit side by side and `current` is a symlink, so an install adds a
directory and moves one link rather than overwriting what is working.

The parts you are allowed to edit live somewhere else:
<!-- doccrate:keep-together:start -->


```text
~/Library/Application Support/Roast/
    Standard Library/stdlib      the stdlib, editable
    Examples/                    what the Examples menu opens
    IDE Source/                  Roast's own source
    Python/Environments/         per-project Python environments
```

<!-- doccrate:keep-together:end -->

The reason for the split is worth knowing early. An installed app's `Resources`
are sealed by its code signature, so "how do I change the standard library"
cannot be answered with "break the seal." Instead the first launch copies the
standard library and the examples out to user space, and **everything that
reads them — builds, the language server, the Examples menu, jump-to-definition
— reads your copy**. The bundle keeps the pristine originals, which is what
makes *Reset* a copy rather than a download.

So you can edit the standard library, and you can put it back.
<!-- doccrate:keep-together:start -->


## Your first program

Open Roast. The **Examples** menu lists everything in the box; pick **hello**
and press **⌘R**.

<!-- doccrate:keep-together:end -->
<!-- doccrate:keep-together:start -->


```text
Hello from cocoa-mojo.
The first hundred integers sum to 5050
```

<!-- doccrate:keep-together:end -->

The console opens itself when a build starts, and **⌘0** toggles it.

That proves the toolchain. Now one that proves the *point* of it. **File ▸ New
Folder**, save this as `main.mojo` inside it, and press ⌘R:
<!-- doccrate:keep-together:start -->


```mojo
from std.objc import Obj, Cls, nsstring, autoreleasepool
from std.ffi import c_char


def main():
    with autoreleasepool():
        let s = Obj["NSString"](nsstring("Hello from Cocoa, via Mojo").addr())

        print("length:", s.length())

        let back = s.UTF8String()
        print("round trip:", String(unsafe_from_utf8_ptr=back.bitcast[c_char]()))
```

<!-- doccrate:keep-together:end -->
<!-- doccrate:keep-together:start -->


```text
length: 26
round trip: Hello from Cocoa, via Mojo
```

<!-- doccrate:keep-together:end -->

Nothing in that program named a dispatch function, a type encoding, or a
selector address. All of it came from the database while the program was being
compiled.
<!-- doccrate:keep-together:start -->


## A project is a folder

There is no project file and nothing to generate. A project is a folder with a
`main.mojo` in it — **File ▸ Open Folder…**, then ⌘R.

<!-- doccrate:keep-together:end -->

Mojo has no link step: the compiler is given one file and follows its imports,
so a project needs an entry point rather than a file list. Roast looks for one
in this order:

1. `main.mojo` in the project root — the convention, and what the examples use
2. the file on screen, if it is in the root and declares a top-level `main`
3. the one non-test file in the root that declares a top-level `main`
4. the file on screen

Step 4 is what makes a single loose file buildable: open one file, press ⌘B,
and it builds that file.
<!-- doccrate:keep-together:start -->


## Prove the checking is real

Change `"length"` to `"lenght"` and look at it.

<!-- doccrate:keep-together:end -->

You do not get a runtime crash, and you do not get a silently wrong answer. You
get an error naming the selector — and you get it **as you type**, because the
language server asks the same database the compiler does.

That is the claim this whole design rests on: a name that does not exist cannot
reach code generation. The [Reference Manual](../reference/) lists every
diagnostic that enforces it.
<!-- doccrate:keep-together:start -->


## The command line, if you prefer one

The toolchain is not added to your `PATH`. The driver is at:

<!-- doccrate:keep-together:end -->
<!-- doccrate:keep-together:start -->


```bash
/Applications/Roast/CocoaMojo/current/bin/cocoamojo
```

<!-- doccrate:keep-together:end -->

and it is the whole interface — no `-I` flags, no `MODULAR_*` variables:
<!-- doccrate:keep-together:start -->


```bash
cocoamojo --run   hello.mojo         # compile and run
cocoamojo --build hello.mojo         # -> ./hello
cocoamojo --build hello.mojo -o app  # -> ./app
```

<!-- doccrate:keep-together:end -->

The distribution carries the compiler, the Mojo runtime, the Metal device
runtime, the packages and `cocoa.sqlite` beside one another, and the driver
wires them together. `--run` JITs; both paths work for Cocoa and for GPU code.
Binaries from `--build` carry an rpath to `lib/`, so they run anywhere on the
machine without a wrapper.

Add it to your `PATH` if you want it by name:
<!-- doccrate:keep-together:start -->


```bash
export PATH="/Applications/Roast/CocoaMojo/current/bin:$PATH"
```

<!-- doccrate:keep-together:end -->
<!-- doccrate:keep-together:start -->


## After a macOS update

Rebuild the database: open the installer again and press **Reinstall**. An SDK
update changes what the compiler should know about macOS, and nothing forces
the issue — the compiler will happily keep using the old database.

<!-- doccrate:keep-together:end -->

`cocoakb_db_hash()` is how you check. It returns the SHA-256 of the database a
given compilation consulted, so a binary can record exactly which revision it
was built against.
<!-- doccrate:keep-together:start -->


## Where to go next

Chapter 2 is not optional. This compiler rejects a good deal of Mojo that
current tutorials still teach, and knowing what changed will save you more time
than anything else in this guide.

<!-- doccrate:keep-together:end -->

If you would rather read code than prose, [The examples](../examples/) walks
through everything in the Examples menu and says what each one is for.
