#!/usr/bin/env python3
"""Every symbol Mojo calls must be defined by the runtime, and vice versa.

This exists because a truncated stub name -- `AsyncRT_cuda_tensorMapEncodeIm`
where Mojo calls `AsyncRT_cuda_tensorMapEncodeIm2col` -- sat undetected. It is
a latent undefined-symbol link failure, invisible only because nothing built
currently reaches that path. A capability table that faithfully lists a
misspelled symbol is worse than no table: it looks like coverage.

Note the scan must be multi-line. Mojo formats most of these with the symbol
on the line after `external_call[`, so a same-line grep finds a small fraction
of them and quietly reports success.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REPO = ROOT.parents[2]
RUNTIME = ["AppleGPURT.cpp", "AppleGPUMetal.cpp"]
MOJO_TREES = ["mojo/stdlib", "max/mojo", "max/kernels"]

# Defined but never called from Mojo. Not an error on its own -- an ABI may
# legitimately offer more than this tree uses -- so these are reported, not
# failed, and listed here once someone has looked at them.
KNOWN_UNCALLED = {
    "AsyncRT_AndThen",
    "AsyncRT_DeviceGraphBuilder_addFunction",
    "AsyncRT_DeviceMulticastBuffer_release",
    "AsyncRT_DeviceMulticastBuffer_retain",
}


def defined():
    out = set()
    for name in RUNTIME:
        # Drop the macro DEFINITIONS, whose parameter is literally `name`.
        text = "\n".join(l for l in (ROOT / name).read_text().split("\n")
                          if not l.lstrip().startswith("#define"))
        out |= set(re.findall(r"VR_STUB_(?:ERR|VOID|ZERO)\((\w+)", text))
        out |= set(re.findall(r'extern "C"[^;{]*?\b(AsyncRT_\w+)\s*\(', text,
                              re.S))
    return out


def called():
    out = set()
    for tree in MOJO_TREES:
        for p in (REPO / tree).rglob("*.mojo"):
            try:
                text = p.read_text(errors="ignore")
            except OSError:
                continue
            if "AsyncRT_" not in text:
                continue
            # Multi-line: the symbol usually sits on the line AFTER the `[`.
            out |= set(re.findall(r'external_call\s*\[\s*"(AsyncRT_\w+)"', text,
                                  re.S))
    return out


def main():
    d, c = defined(), called()
    missing = sorted(c - d)
    uncalled = sorted(d - c - KNOWN_UNCALLED)

    print(f"runtime defines {len(d)}, Mojo calls {len(c)}")
    if uncalled:
        print(f"\ndefined but never called from Mojo ({len(uncalled)}) -- "
              f"not an error, but worth knowing:")
        for s in uncalled:
            print(f"  {s}")
    if missing:
        print(f"\nERROR: called by Mojo, defined by nobody ({len(missing)}):",
              file=sys.stderr)
        for s in missing:
            print(f"  {s}", file=sys.stderr)
        print("\nThis is an undefined-symbol link failure waiting for the "
              "first build that reaches the path.", file=sys.stderr)
        return 1
    print("\nevery symbol Mojo calls is defined")
    return 0


if __name__ == "__main__":
    sys.exit(main())
