#!/usr/bin/env python3
"""Decide whether a test is in scope for the Apple fork.

BUILD constraints are the primary signal (see classify.py), but they are not
complete: a number of vendor-specific tests carry no constraint at all and so
land in the `generic` bucket, where they inflate the denominator and then fail
or pass vacuously for reasons that have nothing to do with this backend.

Three additional signals, in decreasing order of certainty:

  1. a lit `# REQUIRES:` directive naming another vendor -- exact. lit marks the
     test UNSUPPORTED and exits 0, so it reports PASS having run nothing.
  2. a vendor token in the file name (`test_amd_*`, `*_sm90`, `*_ptx`) -- a
     naming convention this repo follows consistently.
  3. a hard vendor guard in the source (`_is_sm10x_gpu`, `has_amd_gpu_accelerator`)
     that made the test do no real work on this machine.

Signal 3 is deliberately conditioned on the observed outcome. Plenty of
in-scope tests mention a vendor in a branch they never take; excluding those
would hide real coverage. Only a test that BOTH carries a vendor-only guard AND
demonstrably did nothing here is treated as out of scope.
"""
import re
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]

NAME_VENDOR = re.compile(
    r'(^|_)(amd|nvidia|cuda|cublas|cudnn|cufft|nccl|ptx|rocm|hip|cdna|rdna'
    r'|gfx\d|mi\d{3}|sm\d{2,3}|sm_\d+|h100|b200|a100|hopper|blackwell|ampere'
    r'|wgmma|nvfp4|nvshmem)(_|$|\d)', re.I)
REQUIRES = re.compile(r'^\s*#\s*REQUIRES:\s*(.+)$', re.M)
REQ_VENDOR = re.compile(r'NVIDIA|AMD|CUDA|ROCM|H100|B200|SM\d', re.I)
HARD_GUARD = re.compile(
    r'_is_sm\d+x?_gpu|has_amd_gpu_accelerator|has_nvidia_gpu_accelerator'
    r'|_is_hopper|_is_blackwell', re.I)

DID_NO_WORK = {"vacuous", "unverified"}


def source_of(target):
    pkg, name = target[2:].split(":", 1)
    return REPO / pkg / name.replace(".mojo.test", ".mojo")


def out_of_scope(target, outcome=""):
    """Return a reason string if the test belongs to another vendor, else ''."""
    leaf = target.split(":", 1)[-1].replace(".mojo.test", "")
    if NAME_VENDOR.search(leaf):
        return "vendor token in the test name"
    src = source_of(target)
    if not src.is_file():
        return ""
    try:
        text = src.read_text(errors="replace")
    except OSError:
        return ""
    for req in REQUIRES.findall(text):
        if REQ_VENDOR.search(req):
            return f"lit REQUIRES: {req.strip()}"
    if outcome in DID_NO_WORK:
        g = HARD_GUARD.findall(text)
        if g:
            return f"vendor guard ({sorted(set(g))[0]}) and no work done here"
    return ""
