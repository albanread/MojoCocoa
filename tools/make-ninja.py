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

STATUS -- read this before relying on it.

Source edits: works. Change a .cpp, run ninja, get a rebuilt compiler with no
bazel involved. This is the case that matters day to day and it is the case this
was written for.

A cold build from nothing: not there. Successive fixes took the failure count
from 748 to 40, and the last 40 are two classes -- one MLIR tablegen include
path (OpenMP/OpenACC), and layering-check failures where the .cppmap files bazel
writes from internal state have to be present and correct.

The shape of the problem is worth stating plainly, because it decides whether to
invest further. Bazel's execution contract is implicit, and every clause of it
had to be found by hitting it:

  * it creates each action's output directories
  * it runs actions against a fresh sandbox, and a few rely on that -- the
    crosstool module map is generated with `exec 1>>"$1"` and doubles if
    replayed over an existing file
  * it strips the configuration segment from command lines and maps it back per
    artifact, so one command can name an exec-config tool and a target-config
    output both as bazel-out/cfg/...
  * it symlinks external repositories into the execroot lazily, per invocation
    (347 of them here)
  * it writes module maps and symlink farms from internal state, with no command
    line to replay

Each was a small fix. There is no way to know how many remain. If a guaranteed
from-scratch build with no bazel is the goal, CMake for LLVM and MLIR is the
supported route -- upstream builds libLLVM.dylib natively with
-DLLVM_BUILD_LLVM_DYLIB=ON -- and KGEN would need its own CMake for its 1,007
tablegen rules. That is a real project, and it is a maintainable one, which this
is not.

Prerequisites for the source-edit case:

    # once, to materialise every external repository in the execroot
    for d in <output_base>/external/*/; do
      ln -s "$d" execroot/_main/external/"$(basename "$d")"
    done

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

    paths = build_paths(graph["pathFragments"])
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
        all_inputs = [artifact_path[i] for i in inputs]
        # Only depend on things this build actually produces. Sources and
        # snapshotted artifacts are already on disk; listing them would make
        # ninja demand rules for files nothing here builds.
        deps = sorted(artifact_path[i] for i in inputs if i in produced)

        # Resolve bazel's path-mapping placeholder.
        #
        # Command lines carry `bazel-out/cfg/bin/...` where the artifact's real
        # path has a configuration segment -- bazel strips it so an action's
        # command is identical across configurations and can be cached once,
        # then maps it back per artifact at execution time.
        #
        # The trap is that one command mixes configurations: generating
        # GeneratedDialectChecksum.h names `bazel-out/cfg/bin/...` for both the
        # tool, which lives in the exec configuration, and the output, which
        # lives in the target one. A single global rewrite gets one of them
        # wrong whichever way it goes. So resolve each token against this
        # action's own inputs and outputs, matching on the part after the
        # configuration segment.
        suffix_to_real = {}
        for real in list(all_inputs) + outputs:
            parts = real.split("/", 2)
            if len(parts) == 3 and parts[0] == "bazel-out":
                suffix_to_real.setdefault(parts[2], real)

        def resolve(token):
            if not token.startswith("bazel-out/cfg/"):
                return token
            return suffix_to_real.get(token[len("bazel-out/cfg/"):], token)

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
                + " ".join(shlex.quote(resolve(a)) for a in args) + "\n")
            script.chmod(0o755)
            cmd = env + shlex.quote(str(script))
        else:
            cmd = env + " ".join(shlex.quote(resolve(a)) for a in args)

        # A depfile is only usable when the command actually writes one next to
        # the object, which is the convention bazel's -MF follows.
        primary = artifact_path.get(action.get("primaryOutputId"))
        rule = "cmd_dep" if ("-MF" in args and primary and primary.endswith(".o")) else "cmd"

        # Bazel creates an action's output directories before running it and
        # ninja does not, so tools that open their output for writing fail with
        # "No such file or directory" on a tree built from scratch.
        outdirs = sorted({os.path.dirname(o) for o in outputs if os.path.dirname(o)})
        prefix = "mkdir -p " + " ".join(shlex.quote(dd) for dd in outdirs) + " && " if outdirs else ""

        # Bazel also runs every action against outputs that do not exist yet,
        # and a few rely on it: the crosstool module map is generated with
        # `exec 1>>"$1"`, so replaying it over an existing file appends a second
        # copy and yields a module map that will not parse.
        #
        # Only those get their outputs cleared. Doing it unconditionally is
        # actively harmful -- an action that then fails leaves nothing behind,
        # and if it is later reclassified as a snapshot there is nothing to
        # snapshot. That mistake cost a bazel run to repair.
        # Test the original arguments, not the assembled command: an action
        # whose script went to a wrapper file has a one-token command line, and
        # the `>>` that makes it append is invisible there.
        if any(">>" in a for a in args):
            prefix += "rm -rf " + " ".join(shlex.quote(o) for o in outputs) + " && "
        cmd = prefix + cmd

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
