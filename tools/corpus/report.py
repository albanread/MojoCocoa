#!/usr/bin/env python3
"""Authoritative Apple-GPU corpus report.

Two sources, each used for what it actually knows:

  bazel (build event protocol)  -- whether a target RAN here, and its result.
                                   Authoritative: it accounts for constraints
                                   declared inline on a rule, which parsing
                                   `_EXTRA_CONSTRAINTS` alone misses (the
                                   sm100/Blackwell rules, `comm`, `shmem`).
  BUILD files (classify.py)     -- WHY a target did not run: switched off on
                                   Apple with a named defect, or belongs to
                                   another vendor and is out of this fork's
                                   scope entirely.

Usage:  report.py <bep.json>
"""
import json, re, sys
from collections import Counter
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import classify

REPO = Path(__file__).resolve().parents[2]

# packages whose tests need hardware this machine does not have for reasons
# unrelated to vendor: several GPUs, or an NVSHMEM fabric.
MULTI_GPU_PKGS = ("comm", "shmem", "cluster")


def load_bep(path):
    status, build_failed = {}, set()
    for line in Path(path).read_text(errors="replace").splitlines():
        try:
            e = json.loads(line)
        except ValueError:
            continue
        idv = e.get("id", {})
        if "testSummary" in idv:
            status[idv["testSummary"]["label"]] = \
                e.get("testSummary", {}).get("overallStatus", "?")
        elif "targetCompleted" in idv:
            lbl = idv["targetCompleted"]["label"]
            if e.get("aborted"):
                status.setdefault(lbl, "SKIPPED")
            elif e.get("completed", {}).get("success") is False:
                build_failed.add(lbl)
    return status, build_failed


def main():
    bep = sys.argv[1] if len(sys.argv) > 1 else "bep.json"
    status, build_failed = load_bep(bep)
    idx = classify.build_index()

    rows = []
    for lbl, st in status.items():
        if not lbl.endswith(".mojo.test"):
            continue  # .binary/.debug siblings and :lit suites are not tests
        cls, reason, tid = classify.classify_target(lbl, idx)
        pkg = lbl.split(":")[0].rsplit("/", 1)[-1]
        if st == "SKIPPED":
            if cls == "excluded":
                bucket = "off-on-apple"
            elif cls == "foreign" or pkg not in MULTI_GPU_PKGS:
                bucket = "other-vendor"
            else:
                bucket = "needs-more-gpus"
            if pkg in MULTI_GPU_PKGS:
                bucket = "needs-more-gpus"
        elif lbl in build_failed or st == "FAILED TO BUILD":
            bucket = "build-failure"
        else:
            bucket = {"PASSED": "pass", "FAILED": "fail"}.get(st, st.lower())
        rows.append({"target": lbl, "pkg": pkg, "bucket": bucket,
                     "class": cls, "tracker_id": tid, "reason": reason})

    for r in rows:
        if r["target"] in build_failed and r["bucket"] in ("pass", "fail"):
            r["bucket"] = "build-failure"

    c = Counter(r["bucket"] for r in rows)
    relevant = c["pass"] + c["fail"] + c["build-failure"]

    out = REPO / "tools/corpus/CORPUS.md"
    L = []
    L.append("# Apple GPU corpus: what is relevant, and how it does\n")
    L.append(f"{len(rows)} `.mojo.test` targets under `//max/kernels/test/gpu/...`.\n")
    L.append("Runnability comes from bazel (it honours constraints declared "
             "inline on a rule, which BUILD-dict parsing misses); the reason a "
             "target does not run comes from the BUILD files.\n")
    L.append("## Relevant to this fork\n")
    L.append("| outcome | count |\n|---|---|")
    L.append(f"| pass | {c['pass']} |")
    L.append(f"| fail (ran, wrong or errored) | {c['fail']} |")
    L.append(f"| fail to build | {c['build-failure']} |")
    L.append(f"| **relevant total** | **{relevant}** |")
    pct = 100.0 * c["pass"] / relevant if relevant else 0
    L.append(f"\n**{c['pass']}/{relevant} passing ({pct:.0f}%).**\n")
    L.append("## Not run here\n")
    L.append("| category | count | meaning |\n|---|---|---|")
    L.append(f"| off-on-apple | {c['off-on-apple']} | in scope, switched off in "
             "BUILD with a named defect — the real backlog |")
    L.append(f"| other-vendor | {c['other-vendor']} | NVIDIA/AMD/Qualcomm; each "
             "has its own fork, out of scope here |")
    L.append(f"| needs-more-gpus | {c['needs-more-gpus']} | multi-GPU / NVSHMEM; "
             "single-GPU machine |")

    fails = [r for r in rows if r["bucket"] in ("fail", "build-failure")]
    if fails:
        L.append("\n## Failing now\n")
        L.append("| target | outcome |\n|---|---|")
        for r in sorted(fails, key=lambda r: (r["bucket"], r["target"])):
            L.append(f"| `{r['target'].split(':')[-1]}` "
                     f"({r['pkg']}) | {r['bucket']} |")

    off = [r for r in rows if r["bucket"] == "off-on-apple"]
    if off:
        L.append("\n## Switched off on Apple (the backlog)\n")
        L.append("| test | id | reason |\n|---|---|---|")
        for r in sorted(off, key=lambda r: (r["tracker_id"], r["target"])):
            reason = re.sub(r'^FIXME:\s*', '', r["reason"])
            reason = re.sub(r'^[A-Z]{2,6}-\d+\s*[—–:-]?\s*', '', reason).strip()
            L.append(f"| `{r['target'].split(':')[-1]}` | {r['tracker_id']} | "
                     f"{reason or '—'} |")
    out.write_text("\n".join(L) + "\n")

    print(f"wrote {out}")
    print(f"  relevant: {relevant}  ->  pass {c['pass']}  fail {c['fail']}  "
          f"build-fail {c['build-failure']}")
    print(f"  off-on-apple {c['off-on-apple']}   other-vendor "
          f"{c['other-vendor']}   needs-more-gpus {c['needs-more-gpus']}")


if __name__ == "__main__":
    main()
