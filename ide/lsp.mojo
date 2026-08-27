# The language server client.
#
# Roast does not parse Mojo. mojo-lsp-server does -- diagnostics, completion
# (the Cocoa database included), definition, semantic tokens -- and this speaks
# to it over a pipe. IDE-EMBEDDING.md is explicit that for an editor not written
# in C++ the LSP boundary is the one to use, and Roast is written in Mojo.
#
# The transport is JSON-RPC with Content-Length framing, which is the whole
# protocol at this level: a header, a blank line, and that many bytes of JSON.
# Reads are non-blocking and drained from a timer, the same shape the playground
# uses for compiler output, because a blocking read on the main thread is an
# editor that stops responding whenever the server thinks.
from json import JSON, parse
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
from std.collections.string.string_span import _get_kgen_string

comptime P = OpaquePointer[MutUntrackedOrigin]


@always_inline
def _sym[name: StaticString]() -> P:
    """A libc symbol as a pointer, cast per signature at the call site."""
    return P(
        _mlir_value=__mlir_op.`pop.extern_ptr_symbol`[
            name=_get_kgen_string[name](),
            alignment=Int(1).__mlir_index__(),
            _type=P._mlir_type,
        ]()
    )


@always_inline
def posix_read(fd: Int, buf: P, count: Int) -> Int:
    var sym = _sym["read"]()
    var call = Pointer(to=sym).unsafe_bitcast[fn(Int, P, Int, /) -> Int]()[]
    return call(fd, buf, count)


@fieldwise_init
struct _PollFD(ImplicitlyCopyable, Movable):
    """struct pollfd: the file descriptor, what to wait for, what happened."""

    var fd: Int32
    var events: Int16
    var revents: Int16


@always_inline
def readable(fd: Int) -> Bool:
    """Is there anything to read right now?

    This exists instead of setting O_NONBLOCK, and the reason is an arm64 ABI
    trap worth writing down. `fcntl` is variadic -- int fcntl(int, int, ...) --
    and on arm64 a variadic argument is passed on the stack, not in a register.
    Calling it through a fixed three-argument signature puts O_NONBLOCK in x2,
    where fcntl never looks, so the flag is silently not set and the next read
    blocks the main thread until the server happens to say something. The
    editor stops responding and nothing in the code looks wrong.

    `poll` takes a pointer, a count and a timeout, all fixed, so it has no such
    hazard. POLLIN is 1; a zero timeout means ask and return.
    """
    var pfd = _PollFD(Int32(fd), Int16(1), Int16(0))
    # The address of the struct, not its contents. Bitcasting the pointer and
    # then dereferencing hands poll the first eight bytes of the struct as if
    # they were an address, which is a different bug every time.
    let n = external_call["poll", Int32](Pointer(to=pfd), Int(1), Int32(0))
    if n <= 0:
        return False
    return (Int(pfd.revents) & 1) != 0


# ── State ───────────────────────────────────────────────────────────────────
comptime g_task = named_global["lsp.task", Int]
comptime g_in = named_global["lsp.in", Int]      # NSFileHandle we write to
comptime g_read_fd = named_global["lsp.readfd", Int]
comptime g_next_id = named_global["lsp.nextid", Int]
comptime g_ready = named_global["lsp.ready", Int]

# Bytes that arrived but do not yet make a whole message. A one-element list,
# for the same reason every other buffer here is: a zero-initialised global
# String is not a valid String, and a zero-initialised List is a valid empty one.
comptime g_inbox = named_global["lsp.inbox", List[String]]

# Diagnostics for the open document, as (line, character, end_character,
# severity) plus the message. Flat lists rather than a struct list because they
# are read from a draw callback, which wants no allocation.
comptime g_diag_line = named_global["lsp.diag.line", List[Int]]
comptime g_diag_col = named_global["lsp.diag.col", List[Int]]
comptime g_diag_end = named_global["lsp.diag.end", List[Int]]
comptime g_diag_sev = named_global["lsp.diag.sev", List[Int]]
comptime g_diag_msg = named_global["lsp.diag.msg", List[String]]


def inbox() -> String:
    if len(g_inbox()[]) == 0:
        return String()
    return g_inbox()[][0]


def set_inbox(var s: String):
    let slot = g_inbox()
    if len(slot[]) == 0:
        slot[].append(s^)
    else:
        slot[][0] = s^


def is_running() -> Bool:
    return g_task()[] != 0


def is_ready() -> Bool:
    return g_ready()[] != 0


def diagnostic_count() -> Int:
    return len(g_diag_line()[])


def clear_diagnostics():
    let l = g_diag_line()
    let c = g_diag_col()
    let e = g_diag_end()
    let s = g_diag_sev()
    let m = g_diag_msg()
    while len(l[]) > 0:
        _ = l[].pop()
    while len(c[]) > 0:
        _ = c[].pop()
    while len(e[]) > 0:
        _ = e[].pop()
    while len(s[]) > 0:
        _ = s[].pop()
    while len(m[]) > 0:
        _ = m[].pop()


# ── Framing ─────────────────────────────────────────────────────────────────
def frame(body: String) -> String:
    """A message on the wire: Content-Length, a blank line, then the bytes.

    The length counts bytes, not characters -- a header saying 40 for a
    39-byte body leaves the server waiting forever for one more.
    """
    var out = String("Content-Length: ")
    out += String(body.byte_length())
    out += "\r\n\r\n"
    out += body
    return out^


def send(var message: JSON) -> Bool:
    """Write one message. Returns False if the server is not running."""
    if g_in()[] == 0:
        return False
    with autoreleasepool():
        let text = frame(message.serialize())
        var local = text
        let data = msg_send[
            ObjCObject, "NSString", "dataUsingEncoding:"
        ](nsstring(local), Int(4))  # NSUTF8StringEncoding
        _ = msg_send[ObjCObject, "NSFileHandle", "writeData:"](
            ObjCObject(g_in()[]), data.ptr()
        )
    return True


def request(var method: String, var params: JSON) -> Int:
    """Send a request and return its id, so a reply can be matched to it."""
    g_next_id()[] += 1
    let id = g_next_id()[]
    var msg = JSON.object()
    msg.set(String("jsonrpc"), JSON(String("2.0")))
    msg.set(String("id"), JSON(id))
    msg.set(String("method"), JSON(method^))
    msg.set(String("params"), params^)
    _ = send(msg^)
    return id


def notify(var method: String, var params: JSON):
    """A notification has no id and expects no reply."""
    var msg = JSON.object()
    msg.set(String("jsonrpc"), JSON(String("2.0")))
    msg.set(String("method"), JSON(method^))
    msg.set(String("params"), params^)
    _ = send(msg^)


# ── Lifecycle ───────────────────────────────────────────────────────────────
def start(server: String, root_uri: String, import_path: String = String()) -> Bool:
    """Spawn the server and send initialize.

    The server is the one beside us in the distribution, which matters: an
    editor built by this toolchain should ask this toolchain's server, not
    whichever one happens to be on PATH.
    """
    if is_running():
        return True
    with autoreleasepool():
        let NSTask = ObjCClass.lookup["NSTask"]()
        var task = msg_send[ObjCObject, "NSTask", "alloc", is_class=True](
            NSTask.as_object()
        )
        task = msg_send[ObjCObject, "NSObject", "init"](task)
        var path = server
        _ = msg_send[ObjCObject, "NSTask", "setLaunchPath:"](
            task, nsstring(path).ptr()
        )

        # The server needs the stdlib, and it will not guess where it is.
        # IDE-EMBEDDING.md is blunt about this: there is no lex-only mode, so
        # every parse imports std, and without a path every line of every file
        # comes back as "unable to locate module 'std'" -- a configuration
        # error wearing a source error's clothes.
        #
        # MODULAR_MOJO_MAX_IMPORT_PATH is the config key mojo-max.import_path
        # as an environment variable; the compiler's own -I paths reach the
        # server the same way.
        if import_path != "":
            let NSProcessInfo = ObjCClass.lookup["NSProcessInfo"]()
            let info = msg_send[
                ObjCObject, "NSProcessInfo", "processInfo", is_class=True
            ](NSProcessInfo.as_object())
            let inherited = msg_send[
                ObjCObject, "NSProcessInfo", "environment"
            ](info)
            let NSMutableDictionary = ObjCClass.lookup["NSMutableDictionary"]()
            var env = msg_send[
                ObjCObject,
                "NSMutableDictionary",
                "dictionaryWithDictionary:",
                is_class=True,
            ](NSMutableDictionary.as_object(), inherited.ptr())
            var ip = import_path
            _ = msg_send[
                ObjCObject, "NSMutableDictionary", "setObject:forKey:"
            ](
                env,
                nsstring(ip).ptr(),
                nsstring(String("MODULAR_MOJO_MAX_IMPORT_PATH")).ptr(),
            )
            _ = msg_send[ObjCObject, "NSTask", "setEnvironment:"](
                task, env.ptr()
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

        let writer = msg_send[
            ObjCObject, "NSPipe", "fileHandleForWriting"
        ](inp)
        let reader = msg_send[
            ObjCObject, "NSPipe", "fileHandleForReading"
        ](outp)
        let fd = msg_send[Int, "NSFileHandle", "fileDescriptor"](reader)

        # Retained for the process's life: these outlive the pool.
        _ = external_call["objc_retain", P](task.ptr())
        _ = external_call["objc_retain", P](writer.ptr())
        _ = external_call["objc_retain", P](reader.ptr())
        g_task()[] = task.addr()
        g_in()[] = writer.addr()
        g_read_fd()[] = fd

        _ = msg_send[ObjCObject, "NSTask", "launch"](task)

    var params = JSON.object()
    params.set(String("processId"), JSON())
    params.set(String("rootUri"), JSON(root_uri))
    var caps = JSON.object()
    params.set(String("capabilities"), caps^)
    _ = request(String("initialize"), params^)
    return True


def stop():
    if not is_running():
        return
    with autoreleasepool():
        _ = msg_send[ObjCObject, "NSTask", "terminate"](
            ObjCObject(g_task()[])
        )
    g_task()[] = 0
    g_in()[] = 0
    g_ready()[] = 0


def did_open(uri: String, text: String):
    var doc = JSON.object()
    doc.set(String("uri"), JSON(uri))
    doc.set(String("languageId"), JSON(String("mojo")))
    doc.set(String("version"), JSON(1))
    doc.set(String("text"), JSON(text))
    var params = JSON.object()
    params.set(String("textDocument"), doc^)
    notify(String("textDocument/didOpen"), params^)


def did_change(uri: String, version: Int, text: String):
    """Full-text sync. Incremental sync is the next step and needs the rope's
    edit spans, which it already knows; whole-document keeps the first version
    honest about what it does."""
    var doc = JSON.object()
    doc.set(String("uri"), JSON(uri))
    doc.set(String("version"), JSON(version))
    var change = JSON.object()
    change.set(String("text"), JSON(text))
    var changes = JSON.array()
    changes.push(change^)
    var params = JSON.object()
    params.set(String("textDocument"), doc^)
    params.set(String("contentChanges"), changes^)
    notify(String("textDocument/didChange"), params^)


# ── Reading ─────────────────────────────────────────────────────────────────
def poll() -> Int:
    """Drain whatever has arrived and handle every complete message.

    Returns how many messages were handled, so a caller can tell whether
    anything happened without inspecting the state.
    """
    if g_read_fd()[] == 0:
        return 0
    var handled = 0
    with autoreleasepool():
        # 64 KB at a time; the loop repeats while the pipe keeps giving.
        comptime CAP = 65536
        while readable(g_read_fd()[]):
            # calloc rather than malloc, and one byte spare: the buffer is
            # zero-filled, so whatever is read is already NUL-terminated and can
            # be taken as a string without carrying a length alongside it. The
            # server sends JSON, which has no embedded NULs.
            let buf = external_call["calloc", P](Int(CAP + 1), Int(1))
            let n = posix_read(g_read_fd()[], buf, CAP)
            if n <= 0:
                _ = external_call["free", NoneType](buf)
                break
            var acc = inbox()
            acc += String(unsafe_from_utf8_ptr=buf.unsafe_bitcast[c_char]())
            set_inbox(acc^)
            _ = external_call["free", NoneType](buf)
            if n < CAP:
                break

        # Every whole message currently in the inbox.
        while True:
            var acc = inbox()
            let header_end = acc.find("\r\n\r\n")
            if header_end < 0:
                break
            let header = String(acc[byte=0:header_end])
            let marker = header.find("Content-Length:")
            if marker < 0:
                # Not a frame we understand; drop it rather than spin.
                set_inbox(String(acc[byte = header_end + 4 : acc.byte_length()]))
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
                break  # the rest has not arrived
            let body = String(acc[byte = body_at : body_at + length])
            set_inbox(String(acc[byte = body_at + length : acc.byte_length()]))
            _handle(parse(body))
            handled += 1
    return handled


def _handle(var msg: JSON):
    """One message from the server."""
    let method = msg.get("method")[].as_string()
    if method == "textDocument/publishDiagnostics":
        _take_diagnostics(msg.get("params")[])
        return
    # A reply to initialize: tell the server we are ready, then we are.
    if msg.has("result") and not msg.has("method"):
        if g_ready()[] == 0:
            var empty = JSON.object()
            notify(String("initialized"), empty^)
            g_ready()[] = 1


def _take_diagnostics(params: JSON):
    clear_diagnostics()
    let list = params.get("diagnostics")[]
    var i = 0
    while i < list.count():
        let d = list.at(i)[]
        let rng = d.get("range")[]
        let start = rng.get("start")[]
        let end = rng.get("end")[]
        g_diag_line()[].append(start.get("line")[].as_int())
        g_diag_col()[].append(start.get("character")[].as_int())
        # An end on a later line is clamped to the start line: the gutter and
        # the underline are per-line, and a squiggle that wraps is worse than
        # one that stops.
        var end_col = end.get("character")[].as_int()
        if end.get("line")[].as_int() != start.get("line")[].as_int():
            end_col = start.get("character")[].as_int() + 1
        g_diag_end()[].append(end_col)
        # 1 error, 2 warning, 3 information, 4 hint.
        g_diag_sev()[].append(d.get("severity")[].as_int())
        g_diag_msg()[].append(d.get("message")[].as_string())
        i += 1
