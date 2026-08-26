#!/usr/bin/env python3
"""Apple GPU test runner.

Bazel builds; this runs. That split exists because `bazel test` answers the
wrong question for a compiler port:

  * a test whose body is `if cc != 5: print("SKIP"); return` reports PASSED,
    so the pass count silently includes tests that executed no kernel;
  * a target switched off with `@platforms//:incompatible` vanishes from the
    run entirely, and from the denominator with it, so coverage looks better
    the more of it is disabled;
  * cached results print nothing, so a "clean" sweep can mean nothing ran;
  * the summary collapses build failure, wrong numerics and a GPU fault into
    one FAILED bucket, when for a backend port those are three different bugs.

This runner executes the built Mach-O binaries directly, keeps every byte of
stdout/stderr, and classifies what actually happened:

  pass     ran real work, exit 0, no skip marker
  vacuous  exit 0 but every path was skipped -- no evidence of anything
  partial  ran some work and skipped some (e.g. M4 path ok, M5 section gated)
  fail     ran and failed an assertion / raised
  pso      Metal refused the pipeline (a real hardware or lowering limit)
  crash    killed by a signal
  timeout  exceeded the per-test limit
  blocked  BUILD marks it incompatible on Apple; not built, not run

`--unblock` temporarily neutralises the Apple incompatibility markers so the
blocked backlog can be measured instead of assumed. BUILD files are restored
in a finally block, and `--unblock` refuses to run if a previous restore was
left incomplete.
"""
import argparse, json, os, re, shutil, signal, subprocess, sys, tempfile, time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import classify  # BUILD-derived relevance
import scope     # vendor-ownership filter
from common import (REPO, SKIP_RE, WORK_RE, best_perf, log_leaf, sh,
                    source_of)

BACKUP_SUFFIX = ".corpus-runner-backup"

_TMP_ROOT = os.environ.get("CORPUS_RUNNER_TMP")


def tmp_root():
    """Where TEST_TMPDIR lives, resolved on first use.

    A fresh directory under the system temp dir per run. A fixed absolute path
    here is one machine's accident: it means nothing anywhere else, and every
    later run inherits whatever the last one left in it. Resolved lazily so
    that --help and --restore do not create one they never use.
    """
    global _TMP_ROOT
    if not _TMP_ROOT:
        _TMP_ROOT = tempfile.mkdtemp(prefix="corpus-runner-")
    return _TMP_ROOT

PSO_RE = re.compile(
    r'newComputePipelineStateWithFunction|newLibraryWithData|'
    r'XPC_ERROR_CONNECTION_INTERRUPTED|Compiler encountered an internal error',
    re.I)


# ---------------------------------------------------------------- discovery

def discover(pattern):
    """Every .mojo.test target under `pattern`, with its BUILD class."""
    idx = classify.build_index()
    q = sh(f'./bazelw query "tests({pattern})"')
    out = []
    for t in q.stdout.split():
        if not t.startswith("//") or not t.endswith(".mojo.test"):
            continue
        cls, reason, tid = classify.classify_target(t, idx)
        out.append({"target": t, "class": cls, "reason": reason,
                    "tracker_id": tid})
    return out


def binary_path(target):
    """Real path to the built test executable.

    `bazel-bin` is a symlink into the execroot. Running through the symlink
    makes the rules_python runfiles library compare a symlinked path against a
    real one in CurrentRepository() and raise; bazel itself always uses the
    resolved execroot path, so resolve here too.
    """
    pkg, name = target[2:].split(":", 1)
    p = REPO / "bazel-bin" / pkg / name
    try:
        return p.resolve()
    except OSError:
        return p


# Anything that can turn a wrong value into a non-zero exit. FileCheck lines
# count: for a lit test the assertions live in "# CHECK...:" comments and are
# evaluated outside the mojo process. `comptime assert` counts: it fails the
# build rather than the run, which is still a failure.
CHECK_MECHANISM = re.compile(
    r'\bassert_\w+|\bdebug_assert\b|\bcomptime\s+assert\b'
    r'|CHECK(?:-[A-Z0-9_]+)?(?:-NEXT|-SAME|-LABEL)?:'
    r'|raise\s+Error|\bFAILED\b|\bmismatch\b|\bnum_errors\b|\bfailures\b',
    re.M | re.I)


def has_check_mechanism(target):
    """Whether the test source contains anything that could fail it.

    A test that runs kernels and only prints the result passes whatever the GPU
    produced -- zeros, NaNs, garbage. Counting that as a pass overstates
    coverage in exactly the direction that hurts a backend port, so it is
    scored `unverified` instead. This is a static screen: it proves the ABSENCE
    of a mechanism, not the strength of one that is present.
    """
    src = source_of(target)
    if not src.is_file():
        return True  # cannot tell; do not accuse
    try:
        return bool(CHECK_MECHANISM.search(src.read_text(errors="replace")))
    except OSError:
        return True


def runfiles_dir(target):
    pkg, name = target[2:].split(":", 1)
    rf = REPO / "bazel-bin" / pkg / (name + ".runfiles")
    try:
        rf = rf.resolve()
    except OSError:
        pass
    return rf / "_main"


def query_args(targets, chunk=200):
    """Command-line arguments bazel passes to each test.

    Most mojo_test binaries take none, but the lit-driven ones are a generic
    lit runner that requires the test path as an argument -- run without it,
    lit exits with "the following arguments are required: TEST_PATH" and the
    test scores as a failure that has nothing to do with the code under test.

    `$(execpath f)` is expanded to the package-relative source path, which is
    where it resolves from the runfiles root the test runs in.
    """
    args = {}
    for i in range(0, len(targets), chunk):
        batch = targets[i:i + chunk]
        # bazel query takes ONE expression, not a list of labels
        # --keep_going: one un-analysable target in the batch otherwise loses
        # the answer for all 200, silently -- query exits without writing the
        # rest. A lit test that then runs without its TEST_PATH argument scores
        # as a failure of the code under test, which it is not.
        r = sh("./bazelw query --keep_going --output=build 'set("
               + " ".join(batch) + ")'")
        cur = None
        for line in r.stdout.splitlines():
            m = re.match(r'^\s*name = "([^"]+)"', line)
            if m:
                cur = m.group(1)
                continue
            m = re.match(r'^\s*args = \[(.*)\]', line)
            if m and cur:
                vals = re.findall(r'"([^"]*)"', m.group(1))
                for t in batch:
                    if t.endswith(":" + cur):
                        pkg = t[2:].split(":", 1)[0]
                        args[t] = [
                            re.sub(r'\$\(execpath ([^)]+)\)',
                                   lambda mm: f"{pkg}/{mm.group(1)}", v)
                            for v in vals]
                        break
                cur = None
    return args


def bazel_test_env(target, runfiles, timeout):
    """The variables bazel's test harness sets at RUN time.

    These are not part of RunEnvironmentInfo -- that provider carries only what
    the rule declares -- so querying the rule is not enough. Several tests read
    XML_OUTPUT_FILE directly and die with a KeyError without it, which scores as
    a test failure and is really a harness omission. TEST_TMPDIR must be a real
    writable directory for the same reason.
    """
    tmp = Path(tmp_root()) / target.replace("//", "").replace(":", "_") \
        .replace("/", "_")
    tmp.mkdir(parents=True, exist_ok=True)
    xml = tmp / "test.xml"
    undeclared = tmp / "outputs"
    undeclared.mkdir(exist_ok=True)
    return {
        "TEST_TMPDIR": str(tmp),
        "TEST_SRCDIR": str(runfiles.parent) if runfiles.is_dir() else str(REPO),
        "TEST_WORKSPACE": "_main",
        "RUNFILES_DIR": str(runfiles.parent) if runfiles.is_dir() else "",
        "XML_OUTPUT_FILE": str(xml),
        "TEST_UNDECLARED_OUTPUTS_DIR": str(undeclared),
        "TEST_TARGET": target,
        "TEST_SIZE": "large",
        "TEST_TIMEOUT": str(timeout),
        "TESTBRIDGE_TEST_ONLY": "",
        # the lit shim and pytest_runner refuse to start without this; bazel
        # test sets it, bazel run does not, and that is how they tell apart a
        # real test run from someone executing the binary by hand
        "MODULAR_RUNNING_TESTS": "1",
        "TZ": "UTC",
    }


def query_env(targets, chunk=120):
    """Per-target environment, straight from bazel's RunEnvironmentInfo.

    Running a test binary bare is not the same as running the test: bazel
    supplies GPU_ENV_DO_NOT_USE and the MODULAR_DEVICE_CONTEXT_MEMORY_MANAGER_*
    settings to every one, and the filecheck-style tests are shell wrappers
    that additionally need BINARY / SOURCE / FILECHECK / NOT / EXPECT_*. Taking
    the environment from bazel rather than reinventing it is what keeps a result
    here comparable to a result there.
    """
    env = {}
    expr = ('str(target.label) + "\t" + '
            'json.encode(providers(target)["RunEnvironmentInfo"].environment)')
    for i in range(0, len(targets), chunk):
        batch = targets[i:i + chunk]
        q = " ".join(batch)
        # --keep_going for the same reason as query_args: without it a single
        # target whose package cannot be analysed (`Kernels/lib/*` has no
        # source here) empties the whole batch, and every filecheck wrapper in
        # it then runs with no BINARY/FILECHECK and fails for want of its
        # environment rather than for anything in the kernel.
        r = sh(f"./bazelw cquery --keep_going 'set({q})' --output=starlark "
               f"--starlark:expr='{expr}'")
        got = 0
        for line in r.stdout.splitlines():
            if "\t" not in line:
                continue
            label, blob = line.split("\t", 1)
            label = label.replace("@@", "", 1)
            try:
                env[label] = json.loads(blob)
                got += 1
            except ValueError:
                pass
        if got < len(batch):
            print(f"  note: RunEnvironmentInfo for {got} of {len(batch)} "
                  "target(s) in this batch", file=sys.stderr)
    return env


def build_errors(build_log, targets):
    """target -> the first build error bazel or the compiler reported for it.

    "No binary produced" is not a diagnosis. bazel already says WHY, and the
    reason decides whether the row is this fork's problem at all: a target that
    cannot compile because it wants AMD's ISA, or because it needs a package
    that ships only as precompiled .mojoc, is out of scope by the rules in
    STATUS.md -- and indistinguishable from a real defect once the log is
    thrown away. So keep it.

    Two shapes are attributed: a diagnostic naming the .mojo source, and a
    bazel ERROR naming the target label outright.
    """
    by_source = {}
    for t in targets:
        pkg, name = t[2:].split(":", 1)
        by_source[f"{pkg}/{name.replace('.mojo.test', '.mojo')}"] = t
    out = {}
    for line in build_log.splitlines():
        for lbl in re.findall(r"'(//[^']+\.mojo\.test)'", line):
            out.setdefault(lbl, line.strip())
        m = re.search(r'(max/\S+?\.mojo):\d+:\d+: error: (.*)', line)
        if m and m.group(1) in by_source:
            out.setdefault(by_source[m.group(1)], line.strip())
    return out


def query_incompatible(targets, chunk=120):
    """The targets bazel refuses to build for this platform.

    "No binary produced" has two very different causes and calling both a build
    failure misreports the port badly: one is a defect, the other was never
    going to produce a binary. BUILD-dict parsing cannot tell them apart,
    because a rule may declare `target_compatible_with` inline rather than
    through `_EXTRA_CONSTRAINTS` -- which is exactly what the sm100/Blackwell
    rules, `comm` and `shmem` do. bazel knows, so ask bazel.
    """
    out = set()
    expr = ('str(target.label) + "\t" + '
            'str("IncompatiblePlatformProvider" in providers(target))')
    for i in range(0, len(targets), chunk):
        batch = targets[i:i + chunk]
        # --keep_going matters: one un-analysable target poisons the whole
        # batch otherwise. Several tests here depend on `Kernels/lib/*`, which
        # has no source in this tree (see scope.CLOSED_DEP_PATHS), so analysis
        # of the batch aborts and every answer in it is lost -- silently, since
        # cquery still exits without writing to stdout.
        r = sh(f"./bazelw cquery --keep_going 'set({' '.join(batch)})' "
               f"--output=starlark --starlark:expr='{expr}'")
        got = 0
        for line in r.stdout.splitlines():
            if "\t" not in line:
                continue
            label, flag = line.split("\t", 1)
            got += 1
            if flag.strip() == "True":
                out.add(label.replace("@@", "", 1))
        if got < len(batch):
            print(f"  note: cquery answered for {got} of {len(batch)} target(s)"
                  " in this batch; the rest could not be analysed",
                  file=sys.stderr)
    return out


# ------------------------------------------------------------ unblock/restore

def _build_files():
    return sorted(REPO.glob("max/kernels/test/**/BUILD.bazel"))


def check_clean():
    stale = [p for p in _build_files()
             if Path(str(p) + BACKUP_SUFFIX).exists()]
    if stale:
        print("refusing to run: a previous --unblock did not restore these "
              "BUILD files. Restore them with --restore first:", file=sys.stderr)
        for p in stale:
            print(f"  {p}", file=sys.stderr)
        sys.exit(2)


def restore_all():
    n = 0
    for p in _build_files():
        b = Path(str(p) + BACKUP_SUFFIX)
        if b.exists():
            shutil.move(str(b), str(p))
            n += 1
    print(f"restored {n} BUILD file(s)")


def unblock():
    """Neutralise Apple incompatibility markers, keeping a restorable backup.

    Rewrites the marker to a benign empty constraint list. It does NOT delete
    the FIXME comments -- they are the record of why the test was switched off
    and are what makes a re-run interpretable.
    """
    changed = 0
    for p in _build_files():
        text = p.read_text()
        if '"//:apple_gpu": ["@platforms//:incompatible"]' not in text:
            continue
        shutil.copy2(str(p), str(p) + BACKUP_SUFFIX)
        new = text.replace('"//:apple_gpu": ["@platforms//:incompatible"]',
                           '"//:apple_gpu": []')
        p.write_text(new)
        changed += 1
    print(f"unblocked Apple exclusions in {changed} BUILD file(s)")
    return changed


# ------------------------------------------------------------------ classify

def _kill_group(proc):
    """SIGKILL the test's whole process group, then reap it.

    `start_new_session` put the test in its own group; kill the group so
    anything it spawned dies with it rather than holding the sweep open.
    """
    try:
        os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
    except (ProcessLookupError, PermissionError, OSError):
        try:
            proc.kill()
        except OSError:
            pass
    try:
        proc.wait(timeout=10)
    except subprocess.TimeoutExpired:
        pass


def run_one(cmd, env, cwd, timeout, tmpdir):
    """Run one test binary under a timeout that actually bounds it.

    Two deliberate departures from `subprocess.run(..., timeout=)`, both paid
    for by a real incident: a GPU-wedged test ran for 4267 s under a 900 s
    timeout and was ended only by an external SIGKILL. `subprocess.run`
    returned NORMALLY with the kill's exit code, so TimeoutExpired had never
    been raised at all -- the deadline was simply never enforced.

      * output goes to FILES, not pipes. That removes the whole
        selector-and-drain machinery from the timeout path (and with it any
        chance of a full pipe buffer deadlocking a chatty test); what remains
        is `proc.wait(timeout=...)`, which is a plain poll loop.
      * the child gets its own session, so expiry can SIGKILL the process
        GROUP. Killing the direct child is not enough when the thing that is
        stuck is something it spawned.

    Returns (returncode | None, combined output, timed_out).
    """
    op = Path(tmpdir) / "stdout.txt"
    ep = Path(tmpdir) / "stderr.txt"
    timed_out = False
    with open(op, "wb") as fo, open(ep, "wb") as fe:
        proc = subprocess.Popen(cmd, stdout=fo, stderr=fe, env=env, cwd=cwd,
                                start_new_session=True)
        try:
            rc = proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            timed_out = True
            rc = None
            _kill_group(proc)

    def _read(path):
        try:
            return path.read_text(errors="replace")
        except OSError:
            return ""

    return rc, _read(op) + _read(ep), timed_out


def classify_run(rc, out, elapsed, timed_out):
    if timed_out:
        return "timeout", ""
    if rc is not None and rc < 0:
        return "crash", f"signal {-rc} ({signal.Signals(-rc).name})"
    if PSO_RE.search(out):
        m = PSO_RE.search(out)
        line = out[max(0, out.rfind("\n", 0, m.start())):m.end() + 120]
        return "pso", " ".join(line.split())[:180]
    if rc == 0:
        skip, work = SKIP_RE.search(out), WORK_RE.search(out)
        if skip and work:
            return "partial", " ".join(
                out[skip.start():skip.start() + 90].split())
        if skip:
            return "vacuous", " ".join(
                out[skip.start():skip.start() + 90].split())
        return "pass", ""
    tail = [l for l in out.strip().splitlines() if l.strip()][-1:] or [""]
    return "fail", tail[0][:180]


# ---------------------------------------------------------------------- run

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("pattern", nargs="?", default="//max/kernels/test/gpu/...")
    ap.add_argument("--timeout", type=int, default=900)
    ap.add_argument("--only", default="",
                    help="substring filter on the target label")
    ap.add_argument("--classes", default="apple,generic",
                    help="BUILD classes to run (comma separated)")
    ap.add_argument("--unblock", action="store_true",
                    help="temporarily clear Apple @platforms//:incompatible")
    ap.add_argument("--restore", action="store_true",
                    help="restore BUILD files from a previous --unblock")
    ap.add_argument("--out", default="tools/corpus/run-results")
    ap.add_argument("--targets-file", default="",
                    help="newline-separated target labels to run instead of "
                         "discovering by class")
    # No --jobs: the loop below is sequential deliberately. These are GPU
    # tests against a single device, so running them concurrently would have
    # them contend for it and report timings that mean nothing. An option that
    # silently did nothing was worse than not offering one.
    args = ap.parse_args()

    if args.restore:
        restore_all()
        return
    check_clean()

    unblocked = False
    try:
        if args.unblock:
            unblock()
            unblocked = True

        targets = discover(args.pattern)
        want = {c.strip() for c in args.classes.split(",") if c.strip()}
        if args.unblock:
            want.add("excluded")
        if args.targets_file:
            wanted = {l.strip() for l in
                      Path(args.targets_file).read_text().split() if l.strip()}
            sel = [t for t in targets if t["target"] in wanted
                   and args.only in t["target"]]
        else:
            sel = [t for t in targets
                   if t["class"] in want and args.only in t["target"]]
        print(f"{len(sel)} target(s) selected of {len(targets)} discovered")

        # one build for everything; failures are recorded, not fatal
        labels = " ".join(t["target"] for t in sel)
        print("building ...", flush=True)
        t0 = time.time()
        b = sh(f"./bazelw build --keep_going --build_runfile_links {labels}",
               timeout=None)
        print(f"build finished in {time.time() - t0:.0f}s "
              f"(exit {b.returncode})")
        berrs = build_errors((b.stdout or "") + (b.stderr or ""),
                             [t["target"] for t in sel])
        if berrs:
            print(f"  captured a build error for {len(berrs)} target(s)")
        print("querying test environments ...", flush=True)
        envs = query_env([t["target"] for t in sel])
        targs = query_args([t["target"] for t in sel])
        n_args = sum(1 for v in targs.values() if v)
        print(f"  {n_args} target(s) take command-line arguments")
        missing = [t["target"] for t in sel if t["target"] not in envs]
        if missing:
            print(f"  note: no RunEnvironmentInfo for {len(missing)} target(s)")
        incompatible = query_incompatible([t["target"] for t in sel])
        if incompatible:
            print(f"  {len(incompatible)} target(s) bazel refuses on this "
                  "platform (scored `blocked`, not `build-failure`)")

        results = []
        for i, t in enumerate(sel, 1):
            bp = binary_path(t["target"])
            if not bp.is_file():
                # `blocked` is the documented class for this (see the module
                # docstring): bazel declared the target incompatible, so it was
                # never built and never run. Scoring that a build failure reads
                # as a defect of the port and is simply wrong.
                blocked = t["target"] in incompatible
                outcome = "blocked" if blocked else "build-failure"
                detail = ("bazel declares it incompatible with this platform"
                          if blocked
                          else berrs.get(t["target"], "no binary produced"))
                results.append({**t, "outcome": outcome, "detail": detail,
                                "perf": "", "seconds": 0.0})
                print(f"[{i}/{len(sel)}] {outcome:13} "
                      f"{t['target'].split(':')[-1]}", flush=True)
                continue
            tenv = envs.get(t["target"], {})
            # A filecheck-style test is a shell wrapper; the thing that must
            # exist is the binary it execs, not the wrapper. Without this the
            # missing binary surfaces as a FileCheck "input is empty" error and
            # gets scored a test failure instead of a build failure.
            rf_probe = runfiles_dir(t["target"])
            if "BINARY" in tenv and rf_probe.is_dir():
                if not (rf_probe / tenv["BINARY"]).exists():
                    results.append({**t, "outcome": "build-failure",
                                    "detail": f"wrapper target: {tenv['BINARY']}"
                                              " was not produced",
                                    "perf": "", "seconds": 0.0})
                    print(f"[{i}/{len(sel)}] build-failure  "
                          f"{t['target'].split(':')[-1]}", flush=True)
                    continue
            env = dict(os.environ)
            env.update(tenv)
            env.update(bazel_test_env(t["target"], rf_probe, args.timeout))
            # bazel resolves the wrapper's relative paths against the runfiles
            # root, so run there; fall back to the repo if none was built.
            rf = runfiles_dir(t["target"])
            cwd = str(rf) if rf.is_dir() else str(REPO)
            start = time.time()
            cmd = [str(bp)] + targs.get(t["target"], [])
            rc, out, timed_out = run_one(
                cmd, env, cwd, args.timeout, env["TEST_TMPDIR"]
            )
            el = time.time() - start
            outcome, detail = classify_run(rc, out, el, timed_out)
            if outcome == "pass" and not has_check_mechanism(t["target"]):
                outcome = "unverified"
                detail = ("exit 0, but the source has no assertion, no "
                          "CHECK line and no failure path")
            results.append({**t, "outcome": outcome, "detail": detail,
                            "perf": best_perf(out), "seconds": round(el, 2)})
            logdir = REPO / "tools/corpus/logs"
            logdir.mkdir(parents=True, exist_ok=True)
            # log_leaf carries the package and flattens any subdirectory in the
            # target name (nn:attention/test_x.mojo), so two same-named tests in
            # different packages keep both logs and neither names a directory
            # that is not there.
            (logdir / (log_leaf(t["target"]) + ".log")).write_text(out)
            print(f"[{i}/{len(sel)}] {outcome:13} {t['target'].split(':')[-1]}"
                  + (f"   {detail[:70]}" if detail else ""), flush=True)
            # a long-running test should be visible while it runs, not only in
            # the summary; without this a stalled sweep looks identical to a
            # fast one until it ends

        write_report(results, Path(REPO / args.out))
    finally:
        if unblocked:
            restore_all()


def write_report(results, out):
    from collections import Counter
    out.parent.mkdir(parents=True, exist_ok=True)
    # Split before counting. A vendor-owned test that passes by being skipped
    # is not coverage, and a vendor-owned test that fails is not a defect of
    # this fork; either way, leaving them in the denominator misreports it.
    for r in results:
        r["out_of_scope"] = scope.out_of_scope(
            r["target"], r["outcome"],
            r["detail"] if r["outcome"] == "build-failure" else "")
    foreign = [r for r in results if r["out_of_scope"]]
    results = [r for r in results if not r["out_of_scope"]]
    with open(f"{out}.json", "w") as fh:
        json.dump(results, fh, indent=2)
    c = Counter(r["outcome"] for r in results)
    order = ["pass", "partial", "unverified", "vacuous", "fail", "pso",
             "crash", "timeout", "build-failure", "blocked"]
    lines = ["# Apple GPU test run\n",
             f"{len(results)} in-scope tests executed directly (bazel built "
             "them; this runner ran them). "
             f"{len(foreign)} vendor-owned test(s) were excluded -- see the "
             "end of this file.\n",
             "| outcome | count |", "|---|---|"]
    for k in order:
        if c.get(k):
            lines.append(f"| {k} | {c[k]} |")
    real = c.get("pass", 0) + c.get("partial", 0)
    denom = (len(results) - c.get("vacuous", 0) - c.get("unverified", 0)
             - c.get("blocked", 0))
    lines.append(f"\n**{real} of {denom} ran real work, checked it, and "
                 f"passed.** Excluded from that: {c.get('vacuous', 0)} vacuous "
                 f"skip(s), {c.get('unverified', 0)} test(s) that exit 0 "
                 f"with nothing that could fail them, and {c.get('blocked', 0)} "
                 "that bazel refuses to build here at all.\n")
    for bucket in ("fail", "pso", "crash", "timeout", "build-failure",
                   "vacuous", "unverified", "partial", "blocked"):
        sub = [r for r in results if r["outcome"] == bucket]
        if not sub:
            continue
        lines.append(f"\n## {bucket} ({len(sub)})\n")
        lines.append("| test | detail |"); lines.append("|---|---|")
        for r in sorted(sub, key=lambda r: r["target"]):
            lines.append(f"| `{r['target'].split(':', 1)[-1]}` | "
                         f"{r['detail'][:110] or '—'} |")
    perf = [r for r in results if r["perf"]]
    if perf:
        lines.append("\n## measured\n")
        lines.append("| test | perf |"); lines.append("|---|---|")
        for r in sorted(perf, key=lambda r: r["target"]):
            lines.append(f"| `{r['target'].split(':', 1)[-1]}` | {r['perf']} |")
    if foreign:
        lines.append("\n## excluded as another vendor's\n")
        lines.append("| test | outcome here | why |")
        lines.append("|---|---|---|")
        for r in sorted(foreign, key=lambda r: r["target"]):
            lines.append(f"| `{r['target'].split(':', 1)[-1]}` | "
                         f"{r['outcome']} | {r['out_of_scope']} |")
    Path(f"{out}.md").write_text("\n".join(lines) + "\n")
    print(f"\nwrote {out}.md and {out}.json")
    print("  " + "  ".join(f"{k}={c[k]}" for k in order if c.get(k)))


if __name__ == "__main__":
    main()
