#!/usr/bin/env python3
"""Track the GPU test corpus: relevance, real outcome, and performance.

A bazel "PASSED" is not evidence a kernel works: a test whose body is a
compute-capability guard passes by printing SKIP and returning. This tool
separates those, so the corpus score means what it appears to mean.

Outcome classes
  PASS         ran real work, no skip marker
  PARTIAL      ran real work AND skipped a section (e.g. M4 path ok, M5 gated)
  VACUOUS      "passed" but every code path was skipped -- no evidence
  FAIL         built and ran, test failed
  BUILD_FAIL   did not build
  INCOMPATIBLE bazel refused the target for this platform
  NO_STATUS    ran nothing / cancelled

Relevance (this fork ships Apple only; see memory fork-target-ownership)
  apple        Apple/AIR/Metal-specific
  shared       vendor-neutral, expected to work here
  foreign      NVIDIA/AMD/Qualcomm-specific, not this fork's concern
"""
import argparse, csv, os, re, subprocess, sys, json
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import classify  # BUILD-derived relevance; see classify.py
# One copy of the skip/work/perf vocabulary, shared with run-tests.py: these
# used to be private near-duplicates here, and the divergence meant the two
# tools scored the same `Skipped:` log differently. See common.py.
from common import REPO, SKIP_RE, WORK_RE, best_perf, sh


def testlog_path(target):
    # //max/kernels/test/gpu/linalg:test_x.mojo.test -> bazel-testlogs/max/.../test_x.mojo.test/test.log
    pkg, name = target[2:].split(":", 1)
    return REPO / "bazel-testlogs" / pkg / name / "test.log"


def classify_outcome(status, log):
    if status == "PASSED":
        if not log:
            # bazel says it passed but there is no output to show for it, so
            # there is no way to tell real work from a body that skipped
            # everything. That is what VACUOUS means.
            return "VACUOUS", "passed with no test log to check"
        skip = SKIP_RE.search(log)
        work = WORK_RE.search(log)
        if skip and work:
            return "PARTIAL", skip.group(0).strip()
        if skip:
            return "VACUOUS", " ".join(
                log[skip.start():skip.start() + 90].split())
        return "PASS", ""
    return {"FAILED": "FAIL", "NO STATUS": "NO_STATUS",
            "FAILED TO BUILD": "BUILD_FAIL"}.get(status, status), ""


def metallibs(target):
    """AOT-compiled Metal libraries in the test binary.

    Compile evidence is independent of run evidence: a kernel gated off at
    runtime by a compute-capability check is still lowered through the AIR
    backend at build time. A VACUOUS row with a high count means the backend
    handles the kernel and only the hardware gate stops us seeing it run.
    """
    pkg, name = target[2:].split(":", 1)
    b = REPO / "bazel-bin" / pkg / name
    if not b.is_file():
        return ""
    try:
        return str(b.read_bytes().count(b"MTLB"))
    except OSError:
        return ""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("pattern", nargs="?", default="//max/kernels/test/gpu/...",
                    help="bazel target pattern")
    ap.add_argument("--out", default="tools/corpus/corpus-status")
    ap.add_argument("--no-run", action="store_true",
                    help="classify from existing bazel-testlogs only")
    ap.add_argument("--jobs", default="")
    args = ap.parse_args()

    if not args.no_run:
        flags = "--keep_going --test_output=errors"
        if args.jobs:
            flags += f" --jobs={args.jobs}"
        print(f"running {args.pattern} ...", file=sys.stderr)
        sh(f"./bazelw test {args.pattern} {flags}", timeout=None)

    # authoritative per-target status from the BEP-free summary
    st = sh(f"./bazelw test {args.pattern} --test_output=summary "
            f"--keep_going --check_up_to_date 2>&1 || true")
    statuses = {}
    for line in (st.stdout + st.stderr).splitlines():
        m = re.match(r'^(//\S+)\s+(PASSED|FAILED|NO STATUS|FAILED TO BUILD)', line)
        if m:
            statuses[m.group(1)] = m.group(2)

    cls_index = classify.build_index()
    q = sh(f'./bazelw query "tests({args.pattern})" 2>/dev/null')
    targets = [t for t in q.stdout.split() if t.startswith("//")]

    rows = []
    for t in sorted(targets):
        lp = testlog_path(t)
        log = ""
        if lp.exists():
            try:
                log = lp.read_text(errors="replace")
            except OSError:
                pass
        # NOT `"PASSED" if lp.exists()`. bazel-testlogs persists across runs,
        # so a target that is switched off, filtered out, or fails to build
        # today still has yesterday's test.log sitting there -- and treating
        # that as a pass is precisely the "a clean sweep can mean nothing ran"
        # failure this tool exists to catch. Absent from the summary means we
        # have no status for it, whatever is on disk.
        status = statuses.get(t, "NO_STATUS")
        if status == "NO_STATUS":
            log = ""  # do not classify this run from a previous run's output
        outcome, why = classify_outcome(status, log)
        rel, rel_reason, tracker_id = classify.classify_target(t, cls_index)
        if rel == "excluded":
            outcome = "EXCLUDED"
            why = rel_reason
        rows.append({
            "target": t,
            "relevance": rel,
            "outcome": outcome,
            "metallibs": metallibs(t),
            "perf": best_perf(log, fallback=True),
            "tracker_id": tracker_id,
            "note": why,
        })

    outbase = REPO / args.out
    outbase.parent.mkdir(parents=True, exist_ok=True)
    with open(f"{outbase}.csv", "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=["target", "relevance", "outcome",
                                           "metallibs", "perf", "tracker_id",
                                           "note"])
        w.writeheader()
        w.writerows(rows)

    # markdown summary
    counts = {}
    for r in rows:
        counts.setdefault(r["relevance"], {}).setdefault(r["outcome"], 0)
        counts[r["relevance"]][r["outcome"]] += 1
    with open(f"{outbase}.md", "w") as fh:
        fh.write("# GPU corpus status\n\n")
        fh.write(f"Pattern: `{args.pattern}` — {len(rows)} test targets.\n\n")
        fh.write("A bazel PASS is not evidence: `VACUOUS` rows passed by "
                 "skipping every path.\n\n")
        allout = sorted({o for c in counts.values() for o in c})
        fh.write("| relevance | " + " | ".join(allout) + " | total |\n")
        fh.write("|---|" + "---|" * (len(allout) + 1) + "\n")
        for rel in ("apple", "generic", "excluded", "foreign",
                    "disabled-everywhere"):
            c = counts.get(rel, {})
            tot = sum(c.values())
            fh.write(f"| {rel} | " +
                     " | ".join(str(c.get(o, 0)) for o in allout) +
                     f" | {tot} |\n")
        for rel in ("apple", "generic"):
            sub = [r for r in rows if r["relevance"] == rel
                   and r["outcome"] in ("VACUOUS", "PARTIAL", "FAIL",
                                        "BUILD_FAIL")]
            if not sub:
                continue
            fh.write(f"\n## {rel}: needs attention\n\n")
            fh.write("| target | outcome | metallibs | note |\n"
                     "|---|---|---|---|\n")
            for r in sorted(sub, key=lambda r: (r["outcome"], r["target"])):
                fh.write(f"| `{r['target']}` | {r['outcome']} | "
                         f"{r['metallibs']} | {r['note'][:70]} |\n")
        perf = [r for r in rows if r["perf"]]
        if perf:
            fh.write("\n## measured\n\n| target | perf |\n|---|---|\n")
            for r in sorted(perf, key=lambda r: r["target"]):
                fh.write(f"| `{r['target']}` | {r['perf']} |\n")

    print(f"wrote {outbase}.csv and {outbase}.md ({len(rows)} targets)")
    for rel in ("apple", "generic", "excluded", "foreign",
                "disabled-everywhere"):
        c = counts.get(rel, {})
        if c:
            print(f"  {rel:8} " + "  ".join(f"{k}={v}" for k, v in sorted(c.items())))


if __name__ == "__main__":
    main()
