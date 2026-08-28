# The debug adapter client, against a real adapter and a real program.
#
# No window: a debugger is a conversation with a process, and none of that
# needs a view. What it does need is an adapter and something to debug, so
# ROAST_DAP names the adapter and ROAST_DAP_PROGRAM the binary -- check-ide
# compiles a tiny program with debug info and points this at it.
#
# The two claims worth making are that a breakpoint BINDS and that the stop
# lands where the binding says. Everything else here exists to make those two
# unambiguous when they fail.
from dap import (
    start,
    stop,
    poll,
    is_running,
    is_configured,
    is_stopped,
    stop_line,
    stop_file,
    stop_reason,
    exited,
    output,
    toggle_breakpoint,
    breakpoint_count,
    breakpoint_at,
    breakpoint_line,
    verified_line,
    is_verified,
    clear_breakpoints,
    resume,
)
from std.os import getenv
from std.time import perf_counter_ns, sleep


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


# There is no run loop here, so these are the timer. The sleep is not
# politeness: a tight poll loop spins a core, and the thing it starves is the
# adapter it is waiting for. Without it this passed on a quiet machine and
# timed out inside the full suite, which is the worst way for a check to
# fail -- it looks like the code and it is the harness.
comptime TICK = 0.01


def pump(seconds: Float64) -> Int:
    let until = perf_counter_ns() + Int(seconds * 1e9)
    var handled = 0
    while perf_counter_ns() < until:
        handled += poll()
        sleep(TICK)
    return handled


def pump_until_stopped(seconds: Float64) -> Bool:
    let until = perf_counter_ns() + Int(seconds * 1e9)
    while perf_counter_ns() < until:
        _ = poll()
        if is_stopped() or exited():
            return is_stopped()
        sleep(TICK)
    return False


def main() raises:
    var failures = 0
    let adapter = getenv("ROAST_DAP")
    let program = getenv("ROAST_DAP_PROGRAM")
    if adapter == "" or program == "":
        print("dap: set ROAST_DAP and ROAST_DAP_PROGRAM")
        raise Error("ROAST_DAP not set")

    print("dap: breakpoints before anything is running")
    # The editor's order, not the protocol's: someone clicks a gutter before
    # they press Debug, and the client has to hold that until there is an
    # adapter to tell.
    clear_breakpoints()
    let src = getenv("ROAST_DAP_SOURCE")
    failures += check_int(
        "toggle sets", 1 if toggle_breakpoint(src, 9) else 0, 1
    )
    failures += check_int("one breakpoint", breakpoint_count(), 1)
    failures += check_int(
        "found by its line", 1 if breakpoint_at(src, 9) >= 0 else 0, 1
    )
    failures += check_int(
        "unbound reads as asked-for", verified_line(0), 9
    )
    failures += check_int(
        "toggle clears", 1 if toggle_breakpoint(src, 9) else 0, 0
    )
    failures += check_int("none left", breakpoint_count(), 0)

    print("dap: a breakpoint binds, and the program stops on it")
    _ = toggle_breakpoint(src, 9)
    failures += check_int("start", 1 if start(adapter, program, ".") else 0, 1)
    let stopped = pump_until_stopped(120.0)
    failures += check_int("stopped", 1 if stopped else 0, 1)
    if stopped:
        failures += check("reason", stop_reason(), String("breakpoint"))
        # The bound line is the claim. Line 9 is a `for` body that gets
        # inlined, so the adapter slides the breakpoint to the next line that
        # has code -- and the stop has to land on the SAME line the binding
        # reported, or the marker in the gutter is pointing somewhere the
        # program will never be.
        failures += check_int("verified", 1 if is_verified(0) else 0, 1)
        failures += check_int(
            "asked for line 9", breakpoint_line(0), 9
        )
        let bound = verified_line(0)
        if bound < 9:
            print("  FAIL bound line went backwards --", bound)
            failures += 1
        else:
            print("  OK   bound line =", bound, "(slid from 9)" if bound != 9 else "")
        failures += check_int("stop line matches the binding", stop_line(), bound)
        if stop_file().endswith(".mojo"):
            print("  OK   stop file is a mojo source")
        else:
            print("  FAIL stop file --", repr(stop_file()))
            failures += 1

        print("dap: it runs on")
        resume()
        failures += check_int("resumed", 1 if is_stopped() else 0, 0)
        _ = pump(6.0)
        # The program prints and exits; the adapter forwards both.
        if output().find("total:") >= 0:
            print("  OK   the program's output came through the adapter")
        else:
            print("  FAIL no program output --", repr(output()))
            failures += 1

    stop()
    failures += check_int("stopped adapter", 1 if is_running() else 0, 0)
    failures += check_int(
        "bindings forgotten with the process", verified_line(0), 9
    )

    print()
    if failures == 0:
        print("dap OK")
    else:
        print("dap FAILED:", failures)
        raise Error("dap tests failed")
