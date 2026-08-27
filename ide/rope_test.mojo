# Tests for the rope. Values are asserted, not printed and eyeballed -- these
# pin the behaviour so the path-copying rewrite of `replace` can land without
# changing a line of them.
from rope import Rope
from std.time import perf_counter_ns


# Globals are not a thing here, so a check reports its own verdict and main
# adds them up.
def check(name: String, got: String, want: String) -> Int:
    if got == want:
        print("  OK  ", name)
        return 0
    print("  FAIL", name, "-- got", repr(got), "want", repr(want))
    return 1


def check_int(name: String, got: Int, want: Int) -> Int:
    if got == want:
        print("  OK  ", name, "=", got)
        return 0
    print("  FAIL", name, "-- got", got, "want", want)
    return 1


def main() raises:
    var failures = 0
    print("rope: basics")
    let r = Rope(String("hello\nworld\nagain"))
    failures += check_int("byte_length", r.byte_length(), 17)
    failures += check_int("line_count", r.line_count(), 3)
    failures += check("line 0", r.line(0), String("hello"))
    failures += check("line 1", r.line(1), String("world"))
    failures += check("line 2", r.line(2), String("again"))
    failures += check_int("line_start 1", r.line_start(1), 6)
    failures += check_int("line_of_offset 7", r.line_of_offset(7), 1)
    failures += check("slice", r.slice(6, 11), String("world"))
    failures += check("round trip", r.to_string(), String("hello\nworld\nagain"))
    failures += check_int("find", r.find(String("world")), 6)

    print("rope: editing is persistent")
    let edited = r.insert(5, String(" there"))
    failures += check("edited", edited.line(0), String("hello there"))
    failures += check("original untouched", r.line(0), String("hello"))
    let deleted = edited.delete(5, 11)
    failures += check("deleted", deleted.to_string(), String("hello\nworld\nagain"))

    print("rope: empty and edges")
    let e = Rope(String(""))
    failures += check_int("empty length", e.byte_length(), 0)
    failures += check_int("empty lines", e.line_count(), 1)
    failures += check("empty line 0", e.line(0), String(""))
    let one = Rope(String("solo"))
    failures += check("no trailing newline", one.line(0), String("solo"))
    let trail = Rope(String("a\n"))
    failures += check_int("trailing newline lines", trail.line_count(), 2)
    failures += check("line before trailing", trail.line(0), String("a"))

    print("rope: UTF-8 is not cut in half")
    let u = Rope(String("héllo\nwörld\n日本語"))
    failures += check("utf8 line 0", u.line(0), String("héllo"))
    failures += check("utf8 line 2", u.line(2), String("日本語"))
    failures += check("utf8 round trip", u.to_string(), String("héllo\nwörld\n日本語"))

    # A file big enough to cross many leaves and several tree levels.
    print("rope: searching")
    let hay = Rope(String("alpha beta gamma beta delta"))
    failures += check_int("find first", hay.find(String("beta")), 6)
    failures += check_int("find next", hay.find(String("beta"), 7), 17)
    failures += check_int("find missing", hay.find(String("zzz")), -1)
    failures += check_int("find empty needle", hay.find(String("")), -1)
    failures += check_int("find_last", hay.find_last(String("beta"), 27), 17)
    failures += check_int("find_last before first", hay.find_last(String("beta"), 10), 6)
    failures += check_int("matches in range", len(hay.find_all_in(String("beta"), 0, 27)), 2)

    print("rope: a match across a leaf boundary")
    # Leaves are cut near 4096 bytes, so a needle placed there is only found if
    # the search carries the tail of the previous leaf.
    var filler = String()
    for _ in range(1200):
        filler += "abcd"          # 4800 bytes, so at least one cut
    var straddle = filler
    straddle += "NEEDLE"
    straddle += filler
    let big_hay = Rope(straddle^)
    let want_at = 4800
    failures += check_int("across leaves", big_hay.find(String("NEEDLE")), want_at)
    failures += check_int(
        "and not found twice", big_hay.find(String("NEEDLE"), want_at + 1), -1
    )

    print("rope: 250,000 lines")
    var big = String()
    for i in range(250_000):
        big += "line "
        big += String(i)
        big += " — the quick brown fox jumps over the lazy dog\n"
    let bytes = big.byte_length()

    let t0 = perf_counter_ns()
    let R = Rope(big^)
    let build_ms = Float64(perf_counter_ns() - t0) / 1_000_000.0

    failures += check_int("lines", R.line_count(), 250_001)
    failures += check("first line", R.line(0), String("line 0 — the quick brown fox jumps over the lazy dog"))
    failures += check(
        "last line",
        R.line(249_999),
        String("line 249999 — the quick brown fox jumps over the lazy dog"),
    )

    # Line lookup should be a walk, not a scan: the far end must cost about
    # what the near end costs.
    let t1 = perf_counter_ns()
    for i in range(1000):
        _ = R.line(i * 249)
    let lookup_us = Float64(perf_counter_ns() - t1) / 1000.0 / 1000.0

    print("       bytes:", bytes // 1024, "KB")
    print("       build:", build_ms, "ms")
    print("       line lookup:", lookup_us, "us average over 1000 scattered lines")

    # The keystroke budget, measured rather than asserted. `replace` currently
    # rebuilds, so this is the number that says whether path-copying is needed
    # -- and on a file this size it is.
    var scratch = R.copy()
    let t2 = perf_counter_ns()
    for i in range(20):
        scratch = scratch.insert(10, String("x"))
    let edit_ms = Float64(perf_counter_ns() - t2) / 1_000_000.0 / 20.0
    print("       edit:", edit_ms, "ms per keystroke on 14 MB")
    if edit_ms > 8.3:
        print(
            "  NOTE  over the one-frame budget at this size --",
            "path-copying replace is required, as designed",
        )
    else:
        print("  OK   edit within the one-frame budget")

    # A snapshot must be a pointer copy, not a text copy. If this is slow the
    # whole concurrency story is wrong.
    let t3 = perf_counter_ns()
    for _ in range(1000):
        _ = R.copy()
    let snap_ns = Float64(perf_counter_ns() - t3) / 1000.0
    print("       snapshot:", snap_ns, "ns")
    failures += check_int("snapshot is O(1)", Int(snap_ns < 1000.0), 1)

    if build_ms > 400.0:
        print("  FAIL build exceeded 400 ms")
        failures += 1
    else:
        print("  OK   build within budget")

    print()
    if failures == 0:
        print("rope OK")
    else:
        print("rope FAILED:", failures)
        raise Error("rope tests failed")
