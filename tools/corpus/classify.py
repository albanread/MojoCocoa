#!/usr/bin/env python3
"""Classify each GPU test by the platform it can actually run on.

Authoritative source is the BUILD file, not the file name. Every generated test
carries

    target_compatible_with = ["//:has_gpu"] + _EXTRA_CONSTRAINTS.get(src, [])

so a test's constraint list decides everything:

  generic   no entry in _EXTRA_CONSTRAINTS -> ["//:has_gpu"] -> runs here
  apple     ["//:apple_gpu"]                                 -> runs here
  foreign   ["//:nvidia_gpu"] / amd / h100 / b200 / mi300    -> CANNOT run here
  excluded  select({"//:apple_gpu": ["@platforms//:incompatible"]})
                                                             -> removed on Apple

Only `generic` + `apple` are this fork's denominator. `foreign` is out of scope
(each vendor has its own fork). `excluded` is in scope but switched off, and
each entry usually names a real defect.
"""
import re, sys, json
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]

APPLE_C = re.compile(r'"//:apple_gpu"')
INCOMPAT = re.compile(r'"@platforms//:incompatible"')
FOREIGN_C = re.compile(
    r'"//:(nvidia_gpu|amd_gpu|h100_gpu|b200_gpu|a100_gpu|mi300_gpu|mi355_gpu'
    r'|sm[0-9]+_gpu|gpu_arch_[a-z0-9]+)"')


def _brace_span(text, i):
    """Given index of a '{', return index just past its matching '}'."""
    depth = 0
    while i < len(text):
        if text[i] == '{':
            depth += 1
        elif text[i] == '}':
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    return len(text)


def _extract_dict(text, name):
    """Raw source of a top-level `name = {...}` assignment.

    Handles dict unions -- `_EXTRA_CONSTRAINTS = {...} | {...} | {...}` -- which
    several packages use to merge a comprehension with literal entries. Stopping
    at the first closing brace silently drops every later block, and with it
    every exclusion declared there.
    """
    m = re.search(rf'^{re.escape(name)}\s*=\s*\{{', text, re.M)
    if not m:
        return ""
    parts = []
    i = m.end() - 1
    while True:
        j = _brace_span(text, i)
        parts.append(text[i:j])
        k = j
        while k < len(text) and text[k] in ' \t\n\r':
            k += 1
        if k < len(text) and text[k] == '|':
            k += 1
            while k < len(text) and text[k] in ' \t\n\r':
                k += 1
            if k < len(text) and text[k] == '{':
                i = k
                continue
        break
    return "\n".join(parts)


def _split_entries(body):
    """Yield (key, value_source) for each top-level `"key": value,` pair."""
    i, n = 0, len(body)
    while i < n:
        km = re.compile(r'"([^"]+\.mojo)"\s*:').search(body, i)
        if not km:
            return
        key = km.group(1)
        j = km.end()
        depth, start = 0, j
        while j < n:
            ch = body[j]
            if ch in '([{':
                depth += 1
            elif ch in ')]}':
                if depth == 0:
                    break
                depth -= 1
            elif ch == ',' and depth == 0:
                break
            elif ch == '#':
                j = body.find('\n', j)
                if j == -1:
                    j = n
                continue
            j += 1
        # include a trailing same-line comment (reasons live there too)
        eol = body.find('\n', j)
        tail = body[j:eol if eol != -1 else n]
        yield key, body[start:j] + tail
        i = j + 1


def _apple_incompatible_aliases(text):
    """Constants defined as a select() that marks apple incompatible.

    e.g. `_APPLE_GPU_INCOMPATIBLE = select({"//:apple_gpu": [...incompatible]})`
    Entries then reference the constant by name, so the literal never appears
    on the entry line and a literal-only scan undercounts badly.
    """
    names = set()
    for m in re.finditer(r'^(_[A-Z0-9_]+)\s*=\s*select\(\{', text, re.M):
        i = m.end() - 1
        depth = 0
        j = i
        while j < len(text):
            if text[j] == '{':
                depth += 1
            elif text[j] == '}':
                depth -= 1
                if depth == 0:
                    break
            j += 1
        blob = text[i:j + 1]
        if APPLE_C.search(blob) and INCOMPAT.search(blob):
            names.add(m.group(1))
    return names


def classify_package(build_file):
    text = build_file.read_text(errors="replace")
    aliases = _apple_incompatible_aliases(text)
    alias_re = (re.compile(r'\b(' + '|'.join(map(re.escape, aliases)) + r')\b')
                if aliases else None)
    # packages name this dict differently (_EXTRA_CONSTRAINTS,
    # _EXTRA_MOJO_TEST_CONSTRAINTS, ...); take every constraints dict there is
    dict_names = re.findall(r'^(_[A-Z0-9_]*CONSTRAINTS)\s*=\s*\{', text, re.M)
    out = {}
    for dn in dict_names:
        body = _extract_dict(text, dn)
        if not body:
            continue
        for key, val in _split_entries(body):
            if alias_re and alias_re.search(val):
                cls = "excluded"
            elif APPLE_C.search(val) and INCOMPAT.search(val):
                cls = "excluded"
            elif INCOMPAT.search(val) and not APPLE_C.search(val):
                # incompatible elsewhere only -> still runs here, unless it
                # also carries a foreign requirement. A bare
                # ["@platforms//:incompatible"] with no platform key at all is
                # switched off on every target, not just this one.
                if FOREIGN_C.search(val):
                    cls = "foreign"
                elif not re.search(r'"//:[a-z0-9_]+"', val):
                    cls = "disabled-everywhere"
                else:
                    cls = "generic"
            elif APPLE_C.search(val):
                cls = "apple"
            elif FOREIGN_C.search(val):
                cls = "foreign"
            else:
                cls = "generic"
            cm = re.search(r'#\s*(.+)$', val, re.M)
            reason = cm.group(1).strip() if cm else ""
            tm = re.search(r'([A-Z]{2,6}-\d+)', reason)
            # a test can appear in more than one dict; `excluded` wins
            if key not in out or cls == "excluded":
                out[key] = {"class": cls, "reason": reason,
                            "tracker_id": tm.group(1) if tm else ""}
    return out


def build_index():
    """src-relative-path -> {class, reason, tracker_id}, keyed per package."""
    index = {}
    for bf in sorted(REPO.glob("max/kernels/test/**/BUILD.bazel")):
        pkg = bf.parent.relative_to(REPO).as_posix()
        index[pkg] = classify_package(bf)
    return index


def classify_target(target, index):
    """//pkg:src.mojo.test -> (class, reason, tracker_id)."""
    pkg, name = target[2:].split(":", 1)
    src = name[:-5] if name.endswith(".test") else name
    entry = index.get(pkg, {}).get(src)
    if entry:
        return entry["class"], entry["reason"], entry["tracker_id"]
    return "generic", "", ""


def main():
    index = build_index()
    counts = {}
    rows = []
    for pkg, entries in index.items():
        for src, e in entries.items():
            counts[e["class"]] = counts.get(e["class"], 0) + 1
            rows.append((pkg, src, e["class"], e["tracker_id"], e["reason"]))
    if "--json" in sys.argv:
        print(json.dumps(index, indent=2))
        return
    print("constrained tests by class (unlisted tests are `generic`):")
    for k in sorted(counts):
        print(f"  {k:9} {counts[k]}")
    print()
    print("excluded-on-apple, by package:")
    bypkg = {}
    for pkg, src, cls, tid, reason in rows:
        if cls == "excluded":
            bypkg.setdefault(pkg, []).append((src, tid, reason))
    for pkg in sorted(bypkg, key=lambda p: -len(bypkg[p])):
        print(f"  {len(bypkg[pkg]):3}  {pkg}")


if __name__ == "__main__":
    main()
