#!/usr/bin/env python3
"""Turn bazel's action graph into a standalone Ninja build.

    ./bazelw aquery --config=build-mojo --config=release \\
        'deps(//KGEN/tools/mojo:mojo)' --output=jsonproto > aq.json
    ./tools/make-ninja.py aq.json

Bazel is a build system with opinions about hermeticity, remote caching and
dependency visibility. None of that is needed to *run* a compiler build that has
already been configured -- what is needed is seven thousand command lines in the
right order, which is exactly what `aquery` prints.

This reads that and writes a build.ninja into the execroot. After it, ninja
rebuilds the compiler and its shared libraries with no daemon, no analysis phase
and no bazel on PATH.

What it cannot replay, and why that is fine: 2,558 of the 9,851 actions are
bazel's own bookkeeping -- module maps, symlink farms, runfiles trees -- and
carry no command line because bazel writes them from internal state. Their
outputs already exist in the execroot and nothing regenerates them unless the
BUILD files change, so they are treated as source files. Change a BUILD file and
you need bazel again to re-run aquery; change a .cpp and you do not, which is
the case that matters.

C++ compiles pass -MD -MF, so ninja reads the depfiles and gets header-accurate
incremental rebuilds -- the same information bazel derives from its own
dependency scanning.

STATUS. The extraction is complete and ninja orders the graph correctly; a
from-scratch ninja build gets through LLVM, MLIR and KGEN. What still fails is a
handful of actions in third-party corners the compiler does not need at run
time -- crashpad (whose mig.py wants a Mach interface generator, and whose
handler this distribution does not ship), curl, and protobuf's own version
check. Run with `ninja -k 0` to build past them.

Two behaviours were needed to replay bazel's actions faithfully and are worth
knowing if this ever misbehaves:

  * Outputs are removed before each action. Bazel runs everything against a
    fresh sandbox and some actions rely on it -- the crosstool module map is
    generated with `exec 1>>"$1"`, so replaying it over an existing file appends
    a second copy and produces a module map that will not parse.

  * Exec-configuration paths are normalised. aquery writes an action's outputs
    under the real directory (bazel-out/mojo_host_platform-opt-exec/...) and its
    inputs under the placeholder bazel-out/cfg/..., and ninja cannot connect a
    tablegen binary to the objects it was linked from unless those agree.

Bazel's outputs are read-only. Before the first ninja run:

    chmod -R u+w bazel-out
"""

import json
import os
import shlex
import sys
from pathlib import Path

# Actions bazel writes from internal state rather than by running a command.
# Their outputs are snapshotted, not rebuilt.
UNREPLAYABLE = {
    "CppModuleMap", "Symlink", "RepoMappingManifest", "FileWrite",
    "SourceSymlinkManifest", "RunfilesTree", "TemplateExpand",
    "SolibSymlink", "ExecutableSymlink", "TranslateBuildInfo",
    # Python tooling packaged into runfiles zips. The commands exist, but their
    # inputs are bazel's symlink trees rather than real files, so replaying them
    # fails on a tree that only has the snapshots. These are build-time helpers
    # (a dialect checksum generator); they change when their .py sources do,
    # which is a BUILD-level change and already needs a fresh aquery.
    "PythonZipper", "PyCompile",
}


def build_paths(fragments):
    """pathFragments is a parent-linked tree; flatten it to id -> path."""
    by_id = {f["id"]: f for f in fragments}
    cache = {}

    def resolve(fid):
        if fid in cache:
            return cache[fid]
        parts = []
        cur = fid
        # Iterative rather than recursive: the tree is deep enough to blow the
        # default recursion limit on a full LLVM graph.
        while cur is not None:
            frag = by_id[cur]
            parts.append(frag["label"])
            cur = frag.get("parentId")
        cache[fid] = "/".join(reversed(parts))
        return cache[fid]

    return {f["id"]: resolve(f["id"]) for f in fragments}


def flatten_depsets(depsets):
    """depSetOfFiles is a DAG of sets; flatten each to its artifact ids."""
    by_id = {d["id"]: d for d in depsets}
    cache = {}

    def resolve(did):
        if did in cache:
            return cache[did]
        out = set()
        stack = [did]
        seen = set()
        while stack:
            cur = stack.pop()
            if cur in seen:
                continue
            seen.add(cur)
            if cur in cache:
                out |= cache[cur]
                continue
            node = by_id.get(cur)
            if not node:
                continue
            out.update(node.get("directArtifactIds", []))
            stack.extend(node.get("transitiveDepSetIds", []))
        cache[did] = out
        return out

    return resolve


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    graph = json.loads(Path(sys.argv[1]).read_text())

    # aquery spells exec-configuration paths two ways: outputs get the real
    # directory (bazel-out/mojo_host_platform-opt-exec/...) while inputs get the
    # placeholder bazel-out/cfg/.... Ninja sees two different files and cannot
    # connect a tablegen binary to the objects it is linked from. Unify them.
    exec_cfg = next(
        (c["mnemonic"] for c in graph.get("configuration", [])
         if c.get("mnemonic", "").endswith("-exec")), None)

    def normalize(path):
        if exec_cfg and path.startswith("bazel-out/cfg/"):
            return "bazel-out/" + exec_cfg + path[len("bazel-out/cfg"):]
        return path

    paths = build_paths(graph["pathFragments"])
    paths = {k: normalize(v) for k, v in paths.items()}
    artifact_path = {a["id"]: paths[a["pathFragmentId"]] for a in graph["artifacts"]}
    resolve_depset = flatten_depsets(graph.get("depSetOfFiles", []))

    # Anything produced by an action we can replay is a build output; anything
    # else an action needs is either a source file or a snapshotted artifact.
    produced = set()
    for action in graph["actions"]:
        if action.get("arguments"):
            produced.update(action.get("outputIds", []))

    lines = [
        "# Generated by tools/make-ninja.py from bazel's action graph.",
        "# Regenerate after changing a BUILD file; not needed for source edits.",
        "ninja_required_version = 1.10",
        "",
        "rule cmd",
        "  command = $cmd",
        "  description = $desc",
        "",
        "rule cmd_dep",
        "  command = $cmd",
        "  description = $desc",
        "  depfile = $out.d",
        "  deps = gcc",
        "",
    ]

    scripts = Path(".ninja-actions")
    emitted = 0
    skipped = 0
    for action in graph["actions"]:
        mnemonic = action.get("mnemonic", "?")
        args = action.get("arguments")
        if mnemonic in UNREPLAYABLE:
            skipped += 1
            continue
        if not args:
            continue

        outputs = [artifact_path[o] for o in action.get("outputIds", [])]
        if not outputs:
            continue

        inputs = set()
        for dep_id in action.get("inputDepSetIds", []):
            inputs |= resolve_depset(dep_id)
        # Only depend on things this build actually produces. Sources and
        # snapshotted artifacts are already on disk; listing them would make
        # ninja demand rules for files nothing here builds.
        deps = sorted(artifact_path[i] for i in inputs if i in produced)

        env = "".join(
            f"{e['key']}={shlex.quote(e['value'])} "
            for e in action.get("environmentVariables", [])
        )

        # Three actions in this graph pass a multi-line shell script as a single
        # argument. Ninja variables cannot hold a newline, so those go to a file
        # and ninja runs the file. Everything else is inlined.
        if any("\n" in a for a in args):
            scripts.mkdir(parents=True, exist_ok=True)
            script = scripts / f"action_{emitted}.sh"
            script.write_text(
                "#!/bin/sh\nexec "
                + " ".join(shlex.quote(normalize(a)) for a in args) + "\n")
            script.chmod(0o755)
            cmd = env + shlex.quote(str(script))
        else:
            cmd = env + " ".join(shlex.quote(normalize(a)) for a in args)

        # A depfile is only usable when the command actually writes one next to
        # the object, which is the convention bazel's -MF follows.
        primary = artifact_path.get(action.get("primaryOutputId"))
        rule = "cmd_dep" if ("-MF" in args and primary and primary.endswith(".o")) else "cmd"

        # Bazel runs every action against outputs that do not exist yet, and
        # some of them rely on it -- the crosstool module map is generated with
        # `exec 1>>"$1"`, so replaying it over an existing file appends a second
        # copy and produces a module map that will not parse. Clear the outputs
        # first, which is what a fresh sandbox gives.
        cmd = "rm -rf " + " ".join(shlex.quote(o) for o in outputs) + " && " + cmd

        lines.append(f"build {' '.join(ninja_escape(o) for o in outputs)}: {rule}"
                     + (" | " + " ".join(ninja_escape(d) for d in deps) if deps else ""))
        lines.append("  cmd = " + cmd.replace("$", "$$"))
        lines.append(f"  desc = {mnemonic} {os.path.basename(outputs[0])}")
        lines.append("")
        emitted += 1

    out = Path("build.ninja")
    out.write_text("\n".join(lines))
    print(f"wrote {out} -- {emitted} actions replayable, "
          f"{skipped} bazel-internal artifacts snapshotted")
    print()
    print("Run it from the bazel execroot:")
    print("  cd \"$(readlink bazel-bin | sed 's|/bazel-out/.*||')\" && ninja")


def ninja_escape(path):
    return path.replace("$", "$$").replace(" ", "$ ").replace(":", "$:")


if __name__ == "__main__":
    main()
