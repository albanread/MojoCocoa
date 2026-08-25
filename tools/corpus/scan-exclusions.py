#!/usr/bin/env python3
"""List tests excluded from the Apple GPU build by BUILD.bazel.

These never become bazel targets, so they are invisible to `bazel test` and to
any pass-rate computed from it. They are the largest single category of missing
Apple coverage and most carry a tracker ID naming a real defect -- Metal
compilation failures, numerical divergence, threadgroup-memory overflow -- not a
hardware capability gap.
"""
import csv, re, sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
MARK = '"//:apple_gpu": ["@platforms//:incompatible"]'

# a test entry looks like:
#   "test_foo.mojo": select({
#       "//:apple_gpu": ["@platforms//:incompatible"],
#       "//conditions:default": [],
#   }),  # FIXME: MOCO-1234 — reason text
ENTRY = re.compile(
    r'"([^"]+\.mojo)"\s*:\s*select\(\{(?:[^{}]|\{[^{}]*\})*?'
    + re.escape(MARK)
    + r'(?:[^{}]|\{[^{}]*\})*?\}\)\s*,?\s*(?:#\s*(.*))?')

def main():
    rows = []
    for bf in sorted(REPO.glob("max/kernels/test/**/BUILD.bazel")):
        text = bf.read_text(errors="replace")
        if MARK not in text:
            continue
        pkg = bf.parent.relative_to(REPO).as_posix()
        for m in ENTRY.finditer(text):
            test, comment = m.group(1), (m.group(2) or "").strip()
            tid = ""
            tm = re.search(r'([A-Z]{2,6}-\d+)', comment)
            if tm:
                tid = tm.group(1)
            reason = re.sub(r'^FIXME:\s*', '', comment)
            reason = re.sub(r'^[A-Z]{2,6}-\d+\s*[—\-–:]?\s*', '', reason).strip()
            rows.append({"package": pkg, "test": test, "tracker_id": tid,
                         "reason": reason or "(no reason given)"})

    out = REPO / "tools/corpus/apple-exclusions"
    with open(f"{out}.csv", "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=["package", "test", "tracker_id", "reason"])
        w.writeheader(); w.writerows(rows)

    bypkg = {}
    for r in rows:
        bypkg.setdefault(r["package"], []).append(r)
    with open(f"{out}.md", "w") as fh:
        fh.write("# Tests excluded from the Apple GPU build\n\n")
        fh.write(f"{len(rows)} test files are marked "
                 "`@platforms//:incompatible` for `//:apple_gpu`.\n"
                 "They never become bazel targets, so they are absent from any "
                 "pass rate measured with `bazel test`.\n\n")
        named = [r for r in rows if r["reason"] != "(no reason given)"]
        fh.write(f"{len(named)} carry a stated reason; "
                 f"{len(rows) - len(named)} do not.\n\n")
        for pkg in sorted(bypkg):
            fh.write(f"## `{pkg}` ({len(bypkg[pkg])})\n\n")
            fh.write("| test | id | reason |\n|---|---|---|\n")
            for r in sorted(bypkg[pkg], key=lambda r: r["test"]):
                fh.write(f"| `{r['test']}` | {r['tracker_id']} | {r['reason']} |\n")
            fh.write("\n")
    print(f"wrote {out}.csv and {out}.md — {len(rows)} exclusions "
          f"across {len(bypkg)} packages")
    for pkg in sorted(bypkg, key=lambda p: -len(bypkg[p])):
        print(f"  {len(bypkg[pkg]):3}  {pkg}")

if __name__ == "__main__":
    main()
