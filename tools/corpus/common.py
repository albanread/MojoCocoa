#!/usr/bin/env python3
"""Shared vocabulary for the corpus tools.

`run-tests.py` and `track-corpus.py` both have to answer the same question --
did this test actually do any work, or did it pass by skipping? -- and they
used to answer it with their own private copies of the same four regexes. The
copies drifted: run-tests.py matched `Skipped:` and track-corpus.py did not, so
the two tools scored the same log differently, one calling it vacuous and the
other calling it a pass. There is only one right answer, so there is only one
copy of it here.
"""
import re
import subprocess
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]

# Case-insensitive: the corpus uses SKIP:, skip:, Skip:, Skipping: and
# SKIPPED: interchangeably, and a case-sensitive pattern silently scores the
# spellings it misses as ordinary passes.
SKIP_RE = re.compile(r'^\s*(SKIP(?:PED)?|SKIPPING)\b[: ]', re.M | re.I)

# Lines that prove real work happened (harness section markers / checks).
WORK_RE = re.compile(r'^\s*(==\s+\S|PASS\b|ok\b|\[\s*OK\s*\])', re.M)

# Perf lines emitted by benches and some tests.
PERF_RE = re.compile(
    r'([0-9]+\.?[0-9]*)\s*(TFLOP/s|GFLOP/s|GFLOPS|GB/s|ms|us|ns)\b', re.I)

# Throughput beats elapsed time when a log carries both.
_PERF_PREFERRED = ("TFLOP/s", "GFLOP/s", "GFLOPS", "GB/s")


def sh(cmd, timeout=None, cwd=REPO, **kw):
    return subprocess.run(cmd, shell=True, cwd=cwd, capture_output=True,
                          text=True, timeout=timeout, **kw)


def source_of(target):
    """//pkg:name.mojo.test -> the .mojo file it was generated from."""
    pkg, name = target[2:].split(":", 1)
    return REPO / pkg / name.replace(".mojo.test", ".mojo")


def best_perf(log, fallback=False):
    """The most informative perf number in `log`, or '' if there is none.

    `fallback` returns the first timing measurement when no throughput unit
    appears; without it a log that only reports milliseconds reports nothing.
    """
    if not log:
        return ""
    hits = PERF_RE.findall(log)
    if not hits:
        return ""
    for unit in _PERF_PREFERRED:
        best = [h for h in hits if h[1].upper() == unit.upper()]
        if best:
            return f"{max(best, key=lambda h: float(h[0]))[0]} {unit}"
    return f"{hits[0][0]} {hits[0][1]}" if fallback else ""


def log_leaf(target):
    """Filesystem-safe, COLLISION-FREE leaf for a target label.

    The package has to be in the name. `test_matmul.mojo` exists in both
    layout/ and linalg/, `test_index_tensor.mojo` in both layout/ and nn/, and
    `test_tcgen05.mojo` in both basics/ and memory/ -- keying on the basename
    alone means the second run of a sweep silently overwrites the first one's
    log, for the tests most likely to be under investigation.
    """
    pkg, name = target[2:].split(":", 1)
    return (pkg.replace("/", "__") + "__" + name.replace("/", "__"))
