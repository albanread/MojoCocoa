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
    evaluate,
    take_eval_fresh,
    eval_result,
    eval_ok,
    eval_expr,
    stale_evals_dropped,
    frame_count,
    frame_name,
    variable_count,
    variable_name,
    variable_value,
    variable_type,
    stop_line,
    stop_file,
    stop_reason,
    exited,
    output,
    toggle_breakpoint,
    breakpoint_count,
    breakpoint_at,
    breakpoint_line,
    breakpoint_enabled,
    verified_line,
    is_verified,
    clear_breakpoints,
    resume,
    pause,
    relaunch,
    adapter_pid,
    dead_why,
    select_frame,
    thread_count,
    thread_name,
    set_breakpoint_condition,
    set_breakpoint_hit,
    set_breakpoint_enabled,
    supports_conditions,
)
from std.os import getenv
from std.ffi import external_call
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
    # The plugin rides beside the adapter exactly as roast finds it --
    # bin/lldb-dap with lib/libMojoLLDB.dylib one directory over. Passing it
    # here makes this test cover the same launch the IDE performs.
    var init_cmd = String()
    let slash = adapter.rfind("/")
    if slash > 0:
        let plugin = (
            String(adapter[byte=0:slash])
            + String("/../lib/libMojoLLDB.dylib")
        )
        var st = external_call["access", Int](plugin.unsafe_ptr(), Int(0))
        if st == 0:
            init_cmd = String("plugin load ") + plugin
    failures += check_int(
        "start", 1 if start(adapter, program, ".", init_cmd) else 0, 1
    )
    let stopped = pump_until_stopped(120.0)
    failures += check_int("stopped", 1 if stopped else 0, 1)
    if stopped:
        # A stop event and the setBreakpoints response can be in the same pipe
        # read but become observable on adjacent polls. Drain that tail before
        # asserting verification or waiting on the scopes request; otherwise
        # a busy full-suite run mistakes message ordering for a debugger bug.
        _ = pump(1.0)
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

        # Variables. Two round trips behind the stop (scopes, then
        # variables), so pump for them. With Xcode's adapter this section
        # SKIPS rather than fails: no Mojo plugin means no variables, and
        # that absence is the environment, not a regression -- exactly the
        # terms lldb-dap's own absence is treated on.
        var waited = 0.0
        while variable_count() == 0 and waited < 10.0:
            _ = pump(0.5)
            waited += 0.5
        if variable_count() == 0:
            print("  --   variables          none (no MojoLLDB plugin beside this adapter); skipped")
        else:
            print("dap: the stopped frame answers `frame variable`")
            # The stop is at line 9, in `main`: the locals there are
            # `total` and the loop's `i` -- `sum` lives one frame down in
            # `add` and a locals view must NOT show it here.
            var seen_total = False
            var named = 0
            for i in range(variable_count()):
                if variable_name(i) != "":
                    named += 1
                if variable_name(i) == "total":
                    seen_total = True
                    # The value is the DECIMAL, not lldb's hex-then-decimal
                    # double render -- variable_value strips that.
                    if variable_value(i).find("0000") >= 0:
                        print("  FAIL total still carries raw hex --",
                              repr(variable_value(i)))
                        failures += 1
                    else:
                        print("  OK   total =", variable_value(i),
                              " type", variable_type(i))
                if variable_name(i) == "sum":
                    print("  FAIL `sum` leaked from the wrong frame")
                    failures += 1
            failures += check_int(
                "locals are named", 1 if named >= 1 else 0, 1
            )
            failures += check_int(
                "`total` is among them", 1 if seen_total else 0, 1
            )
            # The stack came with the stop: the top frame is main's, and the
            # runtime's startup frames are below it -- proof the walk has
            # depth, not just a top.
            failures += check_int(
                "stack has depth", 1 if frame_count() >= 2 else 0, 1
            )
            if frame_name(0).find("main") >= 0:
                print("  OK   top frame =", frame_name(0))
            else:
                print("  FAIL top frame --", repr(frame_name(0)))
                failures += 1

            # Evaluate: first a plain variable, then an EXPRESSION -- the
            # plugin's JIT compiling Mojo against the live frame and running
            # it in the debuggee. The second is the whole reason the
            # ExpressionParser ships.
            print("dap: the stopped frame evaluates Mojo")
            failures += check_int(
                "evaluate accepted", 1 if evaluate(String("total")) else 0, 1
            )
            var ew = 0.0
            while not take_eval_fresh() and ew < 20.0:
                _ = pump(0.5)
                ew += 0.5
            if ew >= 20.0:
                print("  FAIL evaluate: no reply")
                failures += 1
            else:
                failures += check_int(
                    "total evaluates", 1 if eval_ok() else 0, 1
                )
                print("  OK   total ->", eval_result())

            # An expression over a frame LOCAL cannot evaluate yet: the
            # plugin materializes only REPL-persistent variables, and
            # injecting frame locals into the JIT is the next plugin
            # feature, not a regression. What this pins instead is the part
            # that was broken and is now fixed: the failure REACHES US WITH
            # WORDS. The diagnostics used to be cleared on the way out by a
            # broadcast to a listener that only Jupyter attaches, so every
            # expression error arrived as an empty string.
            _ = evaluate(String("total + 41"))
            ew = 0.0
            while not take_eval_fresh() and ew < 30.0:
                _ = pump(0.5)
                ew += 0.5
            if ew >= 30.0:
                print("  FAIL expression: no reply")
                failures += 1
            elif eval_ok():
                print("  OK   locals in expressions arrived early:",
                      eval_result())
            elif eval_result().find("unknown declaration") >= 0:
                print("  OK   the JIT's refusal has words:",
                      repr(String(eval_result()[byte=0:40])))
            else:
                print("  FAIL expression error is unreadable --",
                      repr(eval_result()))
                failures += 1

        print("dap: it runs on")
        # Resume until the program exits. With optimisation the breakpoint
        # slides OUT of the loop and one resume suffices; built
        # --no-optimization it binds inside the loop and hits five times.
        # A person keeps pressing continue; so does this.
        var resumes = 0
        while not exited() and resumes < 12:
            resume()
            resumes += 1
            var w = 0.0
            while not exited() and not is_stopped() and w < 10.0:
                _ = pump(0.5)
                w += 0.5
        failures += check_int("ran to exit", 1 if exited() else 0, 1)
        print("  OK   resumes to exit =", resumes)
        _ = pump(2.0)
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

    # ── The improvement sprints, each its own session ───────────────────
    # Above is one session on one program; these are debugger_improvements.md
    # D1-D8, verified against the same real adapter. Each section owns its
    # start/stop so a failure in one leaves the next a clean slate, and each
    # skips when its fixture or capability is absent -- the same terms the
    # variables section uses for a plugin-less adapter.
    failures += lifecycle_section(adapter, program, init_cmd)
    failures += pause_section(adapter, init_cmd)
    failures += stack_section(adapter, init_cmd)
    failures += condition_section(adapter, program, init_cmd, src)
    failures += relaunch_section(adapter, program, init_cmd, src)

    print()
    if failures == 0:
        print("dap OK")
    else:
        print("dap FAILED:", failures)
        raise Error("dap tests failed")


def lifecycle_section(adapter: String, program: String, init_cmd: String) -> Int:
    """D1: a killed adapter is reaped, not curated. The session must stop
    looking alive, Stop must be a clean no-op rather than a write into a
    dead pipe, and Debug must be able to start a fresh session after."""
    var failures = 0
    print("dap: a killed adapter is reaped, not curated")
    clear_breakpoints()
    if not start(adapter, program, ".", init_cmd):
        print("  FAIL lifecycle: could not start")
        return 1
    _ = pump(1.0)
    let pid = adapter_pid()
    if pid <= 0:
        print("  FAIL lifecycle: no adapter pid")
        stop()
        return 1
    _ = external_call["kill", Int](pid, Int(9))
    # The tick's poll is the reaper; give it the same moment the app would.
    _ = pump(1.0)
    failures += check_int(
        "session not running after SIGKILL", 1 if is_running() else 0, 0
    )
    failures += check_int(
        "death has a reason", 1 if dead_why() != "" else 0, 1
    )
    # The old crash path: Stop writes a disconnect into the dead pipe. With
    # the guard it returns quietly instead.
    stop()
    failures += check_int(
        "stop after death is a no-op", 1 if is_running() else 0, 0
    )
    # And a fresh session must be startable -- this is the 'already
    # debugging' symptom the sprint named.
    if not start(adapter, program, ".", init_cmd):
        print("  FAIL lifecycle: could not start a fresh session after a kill")
        failures += 1
    else:
        print("  OK   a fresh session starts after the kill")
        _ = pump(0.5)
        stop()
    return failures


def pause_section(adapter: String, init_cmd: String) -> Int:
    """D2: pause interrupts a running program, the stop is a real stop with
    a stack, and resume carries it to exit."""
    var failures = 0
    let spin = getenv("ROAST_DAP_SPIN")
    if spin == "":
        print("dap: pause -- skipped (ROAST_DAP_SPIN not set)")
        return 0
    print("dap: pause interrupts a running program")
    clear_breakpoints()
    if not start(adapter, spin, ".", init_cmd):
        print("  FAIL pause: could not start")
        return 1
    _ = pump(1.0)
    if exited() or not is_running():
        print("  FAIL pause: the spin program ended too soon")
        stop()
        return 1
    pause()
    var w = 0.0
    while not is_stopped() and not exited() and w < 15.0:
        _ = pump(0.5)
        w += 0.5
    failures += check_int("pause stops", 1 if is_stopped() else 0, 1)
    if is_stopped():
        # 'pause' when the interrupt lands between instructions, 'exception'
        # when it lands inside a syscall -- sleep() is exactly that, and the
        # program being interrupted is the fact either way.
        if stop_reason() == "pause" or stop_reason() == "exception":
            print("  OK   pause reason =", stop_reason())
        else:
            print("  FAIL pause reason --", repr(stop_reason()))
            failures += 1
        var w2 = 0.0
        while frame_count() == 0 and w2 < 5.0:
            _ = pump(0.5)
            w2 += 0.5
        failures += check_int(
            "a paused stop has a stack", 1 if frame_count() >= 1 else 0, 1
        )
        resume()
        w2 = 0.0
        while not exited() and w2 < 20.0:
            _ = pump(0.5)
            w2 += 0.5
        failures += check_int(
            "resumes to exit after pause", 1 if exited() else 0, 1
        )
        _ = pump(1.0)
        if output().find("spin: done") >= 0:
            print("  OK   the spin program finished after resuming")
        else:
            print("  FAIL spin never finished --", repr(String(output()[byte=0:120])))
            failures += 1
    stop()
    return failures


def stack_section(adapter: String, init_cmd: String) -> Int:
    """D6: a deep stack arrives whole (paged, not capped at eight), a frame
    can be selected and its locals differ from the top's, and the stop's
    threads are listed."""
    var failures = 0
    let deep = getenv("ROAST_DAP_DEEP")
    let deep_src = getenv("ROAST_DAP_DEEP_SOURCE")
    if deep == "" or deep_src == "":
        print("dap: deep stack -- skipped (ROAST_DAP_DEEP not set)")
        return 0
    print("dap: a deep stack arrives whole, and frames can be selected")
    clear_breakpoints()
    # Line 4 of the fixture is `return 0` at the bottom of the recursion:
    # the stop sits in rec(0), with rec(1..40) and main above -- wait,
    # below -- it. Forty-odd frames is past the first 32-frame page, so the
    # count itself proves the paging.
    _ = toggle_breakpoint(deep_src, 4)
    if not start(adapter, deep, ".", init_cmd):
        print("  FAIL stack: could not start")
        return 1
    var stopped = pump_until_stopped(60.0)
    failures += check_int("deep stop", 1 if stopped else 0, 1)
    if not stopped:
        stop()
        return failures + 1
    _ = pump(1.0)
    var w = 0.0
    while frame_count() < 40 and w < 10.0:
        _ = pump(0.5)
        w += 0.5
    if frame_count() >= 40:
        print("  OK   stack depth =", frame_count(), "(paged past 32)")
    else:
        print("  FAIL stack depth only", frame_count())
        failures += 1
    # Threads: asked for on every stop; listed, at least the stopped one.
    w = 0.0
    while thread_count() == 0 and w < 5.0:
        _ = pump(0.5)
        w += 0.5
    failures += check_int("threads listed", 1 if thread_count() >= 1 else 0, 1)
    if thread_count() >= 1:
        print("  OK   thread 0 =", thread_name(0))
    # Frame selection: rec(0) has level == 0 at the stop; rec(1) has
    # level == 1. Reading frame 1's locals and finding 1 there -- and 0 in
    # frame 0 -- is the wrong-frame leak inverted into a feature.
    if not select_frame(1):
        print("  FAIL could not select frame 1")
        failures += 1
    else:
        w = 0.0
        while variable_count() == 0 and w < 10.0:
            _ = pump(0.5)
            w += 0.5
        var level = String()
        var all_names = String()
        var i = 0
        while i < variable_count():
            if i > 0:
                all_names += String(", ")
            all_names += variable_name(i) + String("=") + variable_value(i)
            if variable_name(i) == "level":
                level = variable_value(i)
            i += 1
        if level == "":
            print("  FAIL frame 1's level missing; frame holds:", all_names)
            failures += 1
        else:
            failures += check("frame 1's level", level, String("1"))
        _ = select_frame(0)
        w = 0.0
        while variable_count() == 0 and w < 10.0:
            _ = pump(0.5)
            w += 0.5
        level = String()
        i = 0
        while i < variable_count():
            if variable_name(i) == "level":
                level = variable_value(i)
            i += 1
        failures += check("frame 0's level", level, String("0"))
    stop()
    return failures


def condition_section(
    adapter: String, program: String, init_cmd: String, src: String
) -> Int:
    """D5 + D7: conditions and hit counts gate the stop; a disabled
    breakpoint never stops; two evaluations in flight attribute correctly."""
    var failures = 0
    print("dap: conditions, hit counts, and disabled rows")
    if not supports_conditions():
        print("  --   conditions      adapter did not advertise them; skipped")
        return 0
    clear_breakpoints()
    _ = toggle_breakpoint(src, 9)
    _ = set_breakpoint_condition(src, 9, String("i == 3"))
    if not start(adapter, program, ".", init_cmd):
        print("  FAIL conditions: could not start")
        return 1
    var stopped = pump_until_stopped(60.0)
    failures += check_int(
        "condition reached the adapter", 1 if stopped else 0, 1
    )
    if stopped:
        _ = pump(1.0)
        var w = 0.0
        while variable_count() == 0 and w < 10.0:
            _ = pump(0.5)
            w += 0.5
        var iv = String()
        var i = 0
        while i < variable_count():
            if variable_name(i) == "i":
                iv = variable_value(i)
            i += 1
        # The wire carries the condition and lldb honours it -- but the
        # plugin's expression parser cannot see frame locals yet (the spike
        # documents this: they are not injected into the JIT), so evaluating
        # `i == 3` ERRORS, and lldb stops on a condition error rather than
        # skipping. Pinned honestly: the stop happens, at the first hit,
        # with the failure VISIBLE in the console -- which is the forwarded
        # `console` category doing its D4 job. When the plugin learns frame
        # locals, this section's expectation flips to iv == 3 and the error
        # assertion goes.
        failures += check(
            "stops at first hit while locals are JIT-invisible", iv, String("0")
        )
        if output().find("error evaluating condition") >= 0:
            print("  OK   the condition's failure is visible in the console")
        else:
            print("  FAIL condition error text missing from the console")
            failures += 1

        # D7: two asks in flight. The first reply is stale the moment the
        # second ask is made; it must be dropped (and counted), not applied
        # under the second ask's name.
        let before = stale_evals_dropped()
        _ = evaluate(String("total"))
        _ = evaluate(String("no_such_name_xyz"))
        w = 0.0
        while not take_eval_fresh() and w < 20.0:
            _ = pump(0.5)
            w += 0.5
        failures += check_int(
            "one stale reply dropped", stale_evals_dropped() - before, 1
        )
        failures += check(
            "the live ask is the answered one",
            eval_expr(),
            String("no_such_name_xyz"),
        )
        failures += check_int(
            "and its failure has words", 1 if eval_ok() else 0, 0
        )

        # Hit count: clear the condition, ask for the third hit. The loop
        # hits the line at i = 0, 1, 2, ... so the third hit is i == 2.
        stop()
    else:
        stop()
        return failures + 1
    clear_breakpoints()
    _ = toggle_breakpoint(src, 9)
    _ = set_breakpoint_hit(src, 9, 3)
    if not start(adapter, program, ".", init_cmd):
        print("  FAIL hit count: could not start")
        return failures + 1
    stopped = pump_until_stopped(60.0)
    failures += check_int("hit-count stop", 1 if stopped else 0, 1)
    if stopped:
        _ = pump(1.0)
        var w = 0.0
        while variable_count() == 0 and w < 10.0:
            _ = pump(0.5)
            w += 0.5
        var iv = String()
        var i = 0
        while i < variable_count():
            if variable_name(i) == "i":
                iv = variable_value(i)
            i += 1
        failures += check("stopped on the third hit (i == 2)", iv, String("2"))
        stop()
    # A disabled row is not in the request, and the program runs to exit.
    clear_breakpoints()
    _ = toggle_breakpoint(src, 9)
    _ = set_breakpoint_enabled(0, False)
    failures += check_int(
        "row disabled locally", 1 if breakpoint_enabled(0) else 0, 0
    )
    if not start(adapter, program, ".", init_cmd):
        print("  FAIL disabled: could not start")
        return failures + 1
    var w3 = 0.0
    while not exited() and w3 < 30.0:
        _ = pump(0.5)
        w3 += 0.5
    failures += check_int(
        "disabled breakpoint never stops", 1 if exited() else 0, 1
    )
    failures += check_int(
        "and never stopped along the way", 1 if is_stopped() else 0, 0
    )
    stop()
    return failures


def relaunch_section(
    adapter: String, program: String, init_cmd: String, src: String
) -> Int:
    """D8: relaunch runs the same binary again -- no rebuild, no re-ask --
    and the breakpoints still bind on the second run."""
    var failures = 0
    print("dap: relaunch restarts without rebuilding")
    clear_breakpoints()
    _ = toggle_breakpoint(src, 9)
    if not start(adapter, program, ".", init_cmd):
        print("  FAIL relaunch: could not start")
        return 1
    var stopped = pump_until_stopped(60.0)
    failures += check_int("first run stops", 1 if stopped else 0, 1)
    stop()
    if not relaunch():
        print("  FAIL relaunch: refused")
        return failures + 1
    stopped = pump_until_stopped(60.0)
    failures += check_int(
        "relaunched run stops on the same line", 1 if stopped else 0, 1
    )
    if stopped:
        failures += check_int("same stop line", stop_line(), 9)
        stop()
    return failures
