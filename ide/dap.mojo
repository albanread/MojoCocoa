# The debug adapter client.
#
# Roast does not debug Mojo any more than it parses it. `lldb-dap` does --
# the adapter Xcode ships, speaking the Debug Adapter Protocol -- and this
# talks to it over a pipe. DAP is LSP's twin: JSON-RPC-shaped messages with
# Content-Length framing, read without blocking from the same timer. So this
# module is deliberately the shape of lsp.mojo, and borrows its `readable`
# and `posix_read` rather than owning a second copy of the syscall dance.
#
# WHAT WORKS AND WHAT DOES NOT
#
# Breakpoints, stepping, the stop line and the call stack all work today,
# because they rest on DWARF line tables, which are language-neutral. What
# does not work is looking at variables: lldb says so itself, out loud, the
# first time a program stops --
#
#   warning: This version of LLDB has no plugin for the language "mojo".
#   Inspection of frame variables will be limited.
#
# -- and the plugin it means is KGEN/lib/MojoLLDB, which this fork carries
# but does not build into the lldb on this machine. That is the v2 job.
# Pretending otherwise would be worse than the warning.
#
# THREE THINGS THE PROTOCOL DOES THAT SURPRISE
#
# Breakpoints SLIDE. Ask for line 2 and the adapter answers line 10, because
# line 2 was inlined away and 10 is the nearest line that has code. The reply
# carries the line it actually bound, and an editor that draws the marker
# where the click was rather than where the breakpoint IS lies to you every
# time. So `verified_line` is what the gutter draws.
#
# The adapter is CHATTY. Launching a program that links this toolchain emits
# several hundred `module` events before anything interesting happens. They
# are dropped by falling off the end of the handler, which costs one string
# compare each -- worth writing down, because a client that logged them would
# spend its startup writing.
#
# Nothing may be sent before `initialized` ARRIVES. Not the response to
# initialize -- the event, which comes later. Breakpoints asked for before
# then are held and sent when it does, which is why `set_breakpoints` works
# before `start` and is the natural way for an editor to use it.
from json import JSON, parse
from lsp import readable, posix_read
from std.objc import (
    ObjCClass,
    ObjCObject,
    msg_send,
    nsstring,
    ns_to_string,
    autoreleasepool,
    named_global,
)
from std.memory import OpaquePointer, Pointer
from std.ffi import external_call, c_char

comptime P = OpaquePointer[MutUntrackedOrigin]

# ── State ───────────────────────────────────────────────────────────────────
comptime g_task = named_global["dap.task", Int]
comptime g_in = named_global["dap.in", Int]
comptime g_read_fd = named_global["dap.readfd", Int]
comptime g_seq = named_global["dap.seq", Int]
# 0 not started, 1 spawned, 2 initialized-event seen, 3 configured and running
comptime g_phase = named_global["dap.phase", Int]
comptime g_inbox = named_global["dap.inbox", List[String]]

# Where the program is stopped, and why. Line 0 means running.
comptime g_stop_line = named_global["dap.stop.line", Int]
comptime g_stop_thread = named_global["dap.stop.thread", Int]
comptime g_stop_file = named_global["dap.stop.file", List[String]]
comptime g_stop_reason = named_global["dap.stop.reason", List[String]]
# Bumped whenever the program stops or resumes, so the app can notice without
# keeping a flag of its own -- the same trick the build driver's serial uses.
comptime g_serial = named_global["dap.serial", Int]
comptime g_exited = named_global["dap.exited", Int]

# Breakpoints, as asked for and as bound. Flat parallel lists, read from a
# draw callback, which wants no allocation.
comptime g_bp_file = named_global["dap.bp.file", List[String]]
comptime g_bp_line = named_global["dap.bp.line", List[Int]]
comptime g_bp_bound = named_global["dap.bp.bound", List[Int]]
comptime g_bp_verified = named_global["dap.bp.verified", List[Int]]
# Set when the breakpoint list changes while the adapter is up, so the tick
# resends it rather than every caller remembering to.
comptime g_bp_dirty = named_global["dap.bp.dirty", Int]

# The program's own output, which arrives as `output` events rather than on a
# pipe: the adapter owns the inferior's stdout.
comptime g_output = named_global["dap.output", List[String]]


def _slot(list_ptr: Pointer[List[String], MutUntrackedOrigin]) -> String:
    return list_ptr[][0] if len(list_ptr[]) > 0 else String()


def _put(list_ptr: Pointer[List[String], MutUntrackedOrigin], var s: String):
    if len(list_ptr[]) == 0:
        list_ptr[].append(s^)
    else:
        list_ptr[][0] = s^


def is_running() -> Bool:
    return g_task()[] != 0


def is_configured() -> Bool:
    return g_phase()[] >= 3


def is_stopped() -> Bool:
    return g_stop_line()[] > 0


def stop_line() -> Int:
    return g_stop_line()[]


def stop_file() -> String:
    return _slot(g_stop_file())


def stop_reason() -> String:
    return _slot(g_stop_reason())


def serial() -> Int:
    return g_serial()[]


def exited() -> Bool:
    return g_exited()[] != 0


def output() -> String:
    return _slot(g_output())


def clear_output():
    _put(g_output(), String())


# ── Breakpoints ─────────────────────────────────────────────────────────────
def breakpoint_count() -> Int:
    return len(g_bp_line()[])


def breakpoint_file(i: Int) -> String:
    return g_bp_file()[][i] if i >= 0 and i < breakpoint_count() else String()


def breakpoint_line(i: Int) -> Int:
    """Where it was asked for -- what the person clicked."""
    return g_bp_line()[][i] if i >= 0 and i < breakpoint_count() else 0


def verified_line(i: Int) -> Int:
    """Where it actually bound, or the asked-for line while the adapter is
    down. This is what a gutter should draw: a marker on a line that has no
    code is a promise the debugger will not keep."""
    if i < 0 or i >= breakpoint_count():
        return 0
    let bound = g_bp_bound()[][i]
    return bound if bound > 0 else g_bp_line()[][i]


def is_verified(i: Int) -> Bool:
    return i >= 0 and i < breakpoint_count() and g_bp_verified()[][i] != 0


def breakpoint_at(path: String, line: Int) -> Int:
    """The index of a breakpoint on this line -- asked-for OR bound, so
    clicking the marker where it is drawn removes it."""
    var i = 0
    while i < breakpoint_count():
        if g_bp_file()[][i] == path and (
            g_bp_line()[][i] == line or g_bp_bound()[][i] == line
        ):
            return i
        i += 1
    return -1


def toggle_breakpoint(path: String, line: Int) -> Bool:
    """Add or remove one. True if it is now set."""
    let at = breakpoint_at(path, line)
    if at >= 0:
        let f = g_bp_file()
        let l = g_bp_line()
        let b = g_bp_bound()
        let v = g_bp_verified()
        let last = breakpoint_count() - 1
        f[].swap_elements(at, last)
        l[].swap_elements(at, last)
        b[].swap_elements(at, last)
        v[].swap_elements(at, last)
        _ = f[].pop()
        _ = l[].pop()
        _ = b[].pop()
        _ = v[].pop()
        g_bp_dirty()[] = 1
        return False
    g_bp_file()[].append(path)
    g_bp_line()[].append(line)
    g_bp_bound()[].append(0)
    g_bp_verified()[].append(0)
    g_bp_dirty()[] = 1
    return True


def clear_breakpoints():
    let f = g_bp_file()
    let l = g_bp_line()
    let b = g_bp_bound()
    let v = g_bp_verified()
    while len(l[]) > 0:
        _ = f[].pop()
        _ = l[].pop()
        _ = b[].pop()
        _ = v[].pop()
    g_bp_dirty()[] = 1


def _files_with_breakpoints() -> List[String]:
    var out = List[String]()
    var i = 0
    while i < breakpoint_count():
        let f = g_bp_file()[][i]
        var seen = False
        for s in out:
            if s == f:
                seen = True
                break
        if not seen:
            out.append(f)
        i += 1
    return out^


# ── The wire ────────────────────────────────────────────────────────────────
def _send(var body: JSON) -> Bool:
    if g_in()[] == 0:
        return False
    with autoreleasepool():
        let text = body.serialize()
        var framed = String("Content-Length: ")
        framed += String(text.byte_length())
        framed += "\r\n\r\n"
        framed += text
        var local = framed
        let data = msg_send[ObjCObject, "NSString", "dataUsingEncoding:"](
            nsstring(local), Int(4)
        )
        _ = msg_send[ObjCObject, "NSFileHandle", "writeData:"](
            ObjCObject(g_in()[]), data.ptr()
        )
    return True


def request(var command: String, var args: JSON) -> Int:
    g_seq()[] += 1
    let id = g_seq()[]
    var msg = JSON.object()
    msg.set(String("seq"), JSON(id))
    msg.set(String("type"), JSON(String("request")))
    msg.set(String("command"), JSON(command^))
    msg.set(String("arguments"), args^)
    _ = _send(msg^)
    return id


def send_breakpoints():
    """One setBreakpoints per file, which is what the protocol takes: the
    request REPLACES every breakpoint in the file it names, so a file that
    has lost its last breakpoint still has to be told, with an empty list."""
    if g_phase()[] < 2:
        return
    for path in _files_with_breakpoints():
        var lines = JSON.array()
        var i = 0
        while i < breakpoint_count():
            if g_bp_file()[][i] == path:
                var one = JSON.object()
                one.set(String("line"), JSON(g_bp_line()[][i]))
                lines.push(one^)
            i += 1
        var src = JSON.object()
        src.set(String("path"), JSON(path))
        var args = JSON.object()
        args.set(String("source"), src^)
        args.set(String("breakpoints"), lines^)
        _ = request(String("setBreakpoints"), args^)
    g_bp_dirty()[] = 0


def start(adapter: String, program: String, cwd: String) -> Bool:
    """Spawn the adapter and ask it to launch the program.

    `stopOnEntry` is false: someone who pressed Debug with no breakpoints
    wants their program to run, not to stare at a stop in the runtime's
    startup. A breakpoint is how you say otherwise.
    """
    if is_running():
        return True
    with autoreleasepool():
        let NSTask = ObjCClass.lookup["NSTask"]()
        var task = msg_send[ObjCObject, "NSTask", "alloc", is_class=True](
            NSTask.as_object()
        )
        task = msg_send[ObjCObject, "NSObject", "init"](task)
        var path = adapter
        _ = msg_send[ObjCObject, "NSTask", "setLaunchPath:"](
            task, nsstring(path).ptr()
        )
        let NSPipe = ObjCClass.lookup["NSPipe"]()
        let inp = msg_send[ObjCObject, "NSPipe", "pipe", is_class=True](
            NSPipe.as_object()
        )
        let outp = msg_send[ObjCObject, "NSPipe", "pipe", is_class=True](
            NSPipe.as_object()
        )
        _ = msg_send[ObjCObject, "NSTask", "setStandardInput:"](task, inp.ptr())
        _ = msg_send[ObjCObject, "NSTask", "setStandardOutput:"](
            task, outp.ptr()
        )
        let writer = msg_send[ObjCObject, "NSPipe", "fileHandleForWriting"](inp)
        let reader = msg_send[ObjCObject, "NSPipe", "fileHandleForReading"](outp)
        let fd = msg_send[Int, "NSFileHandle", "fileDescriptor"](reader)
        _ = external_call["objc_retain", P](task.ptr())
        _ = external_call["objc_retain", P](writer.ptr())
        _ = external_call["objc_retain", P](reader.ptr())
        g_task()[] = task.addr()
        g_in()[] = writer.addr()
        g_read_fd()[] = fd
        _ = msg_send[ObjCObject, "NSTask", "launch"](task)

    g_phase()[] = 1
    g_exited()[] = 0
    g_stop_line()[] = 0
    _put(g_stop_file(), String())
    _put(g_stop_reason(), String())
    _put(g_output(), String())

    var init_args = JSON.object()
    init_args.set(String("adapterID"), JSON(String("lldb")))
    init_args.set(String("linesStartAt1"), JSON(True))
    init_args.set(String("columnsStartAt1"), JSON(True))
    init_args.set(String("pathFormat"), JSON(String("path")))
    _ = request(String("initialize"), init_args^)

    var launch_args = JSON.object()
    launch_args.set(String("program"), JSON(program))
    launch_args.set(String("cwd"), JSON(cwd))
    launch_args.set(String("stopOnEntry"), JSON(False))
    _ = request(String("launch"), launch_args^)
    return True


def stop():
    """Terminate the adapter and forget where the program was.

    The bound lines go with it: they were facts about a process that no
    longer exists, and a marker still sitting on the line the LAST run bound
    is a marker about nothing.
    """
    if not is_running():
        return
    with autoreleasepool():
        _ = msg_send[ObjCObject, "NSTask", "terminate"](ObjCObject(g_task()[]))
    g_task()[] = 0
    g_in()[] = 0
    g_read_fd()[] = 0
    g_phase()[] = 0
    g_stop_line()[] = 0
    g_stop_thread()[] = 0
    _put(g_stop_file(), String())
    _put(g_stop_reason(), String())
    _put(g_inbox(), String())
    var i = 0
    while i < breakpoint_count():
        g_bp_bound()[][i] = 0
        g_bp_verified()[][i] = 0
        i += 1
    g_serial()[] += 1


# ── Driving it ──────────────────────────────────────────────────────────────
def _resume(var command: String):
    if not is_stopped():
        return
    var args = JSON.object()
    args.set(String("threadId"), JSON(g_stop_thread()[]))
    _ = request(command^, args^)
    # Optimistic, and deliberately so: the adapter answers `continued` for
    # some of these and stays silent for others, and an editor that left the
    # stop marker up until it heard back would look frozen.
    g_stop_line()[] = 0
    _put(g_stop_reason(), String())
    g_serial()[] += 1


def resume():
    _resume(String("continue"))


def step_over():
    _resume(String("next"))


def step_in():
    _resume(String("stepIn"))


def step_out():
    _resume(String("stepOut"))


def pause():
    if not is_running() or is_stopped():
        return
    var args = JSON.object()
    # Thread 0 means "whatever is running" to this adapter; a real id is only
    # known once something has stopped, which is the case this is for.
    args.set(String("threadId"), JSON(g_stop_thread()[]))
    _ = request(String("pause"), args^)


# ── Reading ─────────────────────────────────────────────────────────────────
def poll() -> Int:
    """Drain the adapter and handle whole messages. Returns how many."""
    if g_read_fd()[] == 0:
        return 0
    var handled = 0
    with autoreleasepool():
        comptime CAP = 65536
        while readable(g_read_fd()[]):
            let buf = external_call["calloc", P](Int(CAP + 1), Int(1))
            let n = posix_read(g_read_fd()[], buf, CAP)
            if n <= 0:
                _ = external_call["free", NoneType](buf)
                break
            var acc = _slot(g_inbox())
            acc += String(unsafe_from_utf8_ptr=buf.unsafe_bitcast[c_char]())
            _put(g_inbox(), acc^)
            _ = external_call["free", NoneType](buf)
            if n < CAP:
                break

        while True:
            var acc = _slot(g_inbox())
            let header_end = acc.find("\r\n\r\n")
            if header_end < 0:
                break
            let header = String(acc[byte=0:header_end])
            let marker = header.find("Content-Length:")
            if marker < 0:
                _put(g_inbox(), String(acc[byte = header_end + 4 : acc.byte_length()]))
                continue
            var length = 0
            var i = marker + 15
            let hb = header.as_bytes()
            while i < header.byte_length():
                let c = Int(hb[i])
                if c >= 0x30 and c <= 0x39:
                    length = length * 10 + (c - 0x30)
                elif length > 0:
                    break
                i += 1
            let body_at = header_end + 4
            if acc.byte_length() < body_at + length:
                break
            let body = String(acc[byte = body_at : body_at + length])
            _put(g_inbox(), String(acc[byte = body_at + length : acc.byte_length()]))
            _handle(parse(body))
            handled += 1
    return handled


def _handle(var msg: JSON):
    let kind = msg.get("type")[].as_string()
    if kind == "event":
        _event(msg.get("event")[].as_string(), msg.get("body")[])
        return
    if kind == "response":
        let command = msg.get("command")[].as_string()
        if command == "setBreakpoints":
            _take_breakpoints(msg.get("body")[])
        elif command == "stackTrace":
            _take_stack(msg.get("body")[])


def _event(name: String, body: JSON):
    if name == "initialized":
        # Not the initialize RESPONSE: this event is the adapter saying it is
        # ready to be configured, and nothing may be configured before it.
        g_phase()[] = 2
        send_breakpoints()
        var empty = JSON.object()
        _ = request(String("configurationDone"), empty^)
        g_phase()[] = 3
        return
    if name == "stopped":
        g_stop_thread()[] = body.get("threadId")[].as_int()
        _put(g_stop_reason(), body.get("reason")[].as_string())
        # The event says a thread stopped, not where. The line comes from the
        # stack, which is a second round trip -- so the line is set when that
        # reply lands, not here.
        var args = JSON.object()
        args.set(String("threadId"), JSON(g_stop_thread()[]))
        args.set(String("startFrame"), JSON(0))
        args.set(String("levels"), JSON(1))
        _ = request(String("stackTrace"), args^)
        return
    if name == "exited" or name == "terminated":
        g_exited()[] = 1
        g_stop_line()[] = 0
        _put(g_stop_reason(), String())
        g_serial()[] += 1
        return
    if name == "output":
        let category = body.get("category")[].as_string()
        if category == "" or category == "stdout" or category == "stderr":
            var acc = _slot(g_output())
            acc += body.get("output")[].as_string()
            _put(g_output(), acc^)
        return
    # Everything else -- and `module` arrives in the hundreds -- falls off the
    # end here, which is the cheapest thing that can happen to it.


def _take_breakpoints(body: JSON):
    """Record where each breakpoint actually bound.

    The reply is positional against the request, and the request was one
    file's breakpoints in the order they sit in our lists. So this walks our
    breakpoints for that file in the same order -- which is why the file is
    read back out of the reply's `source` rather than assumed.
    """
    let list = body.get("breakpoints")[]
    if list.count() == 0:
        return
    # Which file this reply is about: the adapter echoes the source on each
    # breakpoint, and every breakpoint in one reply came from one request.
    let first = list.at(0)[]
    let path = first.get("source")[].get("path")[].as_string()
    var nth = 0
    var i = 0
    while i < breakpoint_count() and nth < list.count():
        if g_bp_file()[][i] == path or path == "":
            let b = list.at(nth)[]
            let line = b.get("line")[].as_int()
            if line > 0:
                g_bp_bound()[][i] = line
            g_bp_verified()[][i] = 1 if b.get("verified")[].as_bool() else 0
            nth += 1
        i += 1
    g_serial()[] += 1


def _take_stack(body: JSON):
    let frames = body.get("stackFrames")[]
    if frames.count() == 0:
        return
    let top = frames.at(0)[]
    g_stop_line()[] = top.get("line")[].as_int()
    _put(g_stop_file(), top.get("source")[].get("path")[].as_string())
    g_serial()[] += 1
