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
# Which file each diagnostic belongs to, and which file is on screen.
#
# The server publishes for every document it has been told about, and it has
# been told about every open tab. Without the uri these were one global set
# that the newest publish overwrote, so the squiggles under your cursor could
# belong to another file entirely -- drawn at those coordinates in this
# buffer, which is worse than showing nothing.
comptime g_diag_uri = named_global["lsp.diag.uri", List[String]]
comptime g_shown_uri = named_global["lsp.shown.uri", List[String]]

# Completion results, and the id of the request they answer. A reply that is
# not the newest request is dropped: typing fast outruns the server, and a late
# answer for a prefix the user has moved past is worse than no answer.
comptime g_comp_label = named_global["lsp.comp.label", List[String]]
comptime g_comp_detail = named_global["lsp.comp.detail", List[String]]
comptime g_comp_insert = named_global["lsp.comp.insert", List[String]]
comptime g_comp_request = named_global["lsp.comp.request", Int]
comptime g_comp_serial = named_global["lsp.comp.serial", Int]


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


def completion_count() -> Int:
    return len(g_comp_label()[])


def clear_completions():
    let a = g_comp_label()
    let b = g_comp_detail()
    let c = g_comp_insert()
    while len(a[]) > 0:
        _ = a[].pop()
    while len(b[]) > 0:
        _ = b[].pop()
    while len(c[]) > 0:
        _ = c[].pop()


def request_completion(uri: String, line: Int, character: Int) -> Int:
    """Ask what could go here. Line and character are LSP's: zero-based, and
    character counts UTF-16 units, which is why the editor converts."""
    var pos = JSON.object()
    pos.set(String("line"), JSON(line))
    pos.set(String("character"), JSON(character))
    var doc = JSON.object()
    doc.set(String("uri"), JSON(uri))
    var params = JSON.object()
    params.set(String("textDocument"), doc^)
    params.set(String("position"), pos^)
    let id = request(String("textDocument/completion"), params^)
    g_comp_request()[] = id
    return id


def set_shown_uri(var uri: String):
    """Name the document on screen, so diagnostics for the others stay off it."""
    let slot = g_shown_uri()
    if len(slot[]) == 0:
        slot[].append(uri^)
    else:
        slot[][0] = uri^


def shown_uri() -> String:
    let slot = g_shown_uri()
    return slot[][0] if len(slot[]) > 0 else String()


def diag_visible(i: Int) -> Bool:
    """Is this diagnostic about the document on screen?"""
    if i < 0 or i >= len(g_diag_uri()[]):
        return False
    return g_diag_uri()[][i] == shown_uri()


def visible_diagnostic_count() -> Int:
    var n = 0
    var i = 0
    while i < len(g_diag_uri()[]):
        if diag_visible(i):
            n += 1
        i += 1
    return n


def first_visible_diagnostic() -> Int:
    """Index of the first diagnostic about the shown document, or -1."""
    var i = 0
    while i < len(g_diag_uri()[]):
        if diag_visible(i):
            return i
        i += 1
    return -1


def _drop_diagnostics_for(uri: String):
    """Remove the set belonging to one document, leaving the others alone."""
    let l = g_diag_line()
    let c = g_diag_col()
    let e = g_diag_end()
    let sv = g_diag_sev()
    let m = g_diag_msg()
    let u = g_diag_uri()
    var i = len(u[]) - 1
    while i >= 0:
        if u[][i] == uri:
            # Order does not matter to the reader, so swap-with-last and pop
            # rather than shifting five lists down for every removal.
            let last = len(u[]) - 1
            l[].swap_elements(i, last)
            c[].swap_elements(i, last)
            e[].swap_elements(i, last)
            sv[].swap_elements(i, last)
            m[].swap_elements(i, last)
            u[].swap_elements(i, last)
            _ = l[].pop()
            _ = c[].pop()
            _ = e[].pop()
            _ = sv[].pop()
            _ = m[].pop()
            _ = u[].pop()
        i -= 1


def clear_diagnostics():
    let l = g_diag_line()
    let c = g_diag_col()
    let e = g_diag_end()
    let s = g_diag_sev()
    let m = g_diag_msg()
    let u = g_diag_uri()
    while len(u[]) > 0:
        _ = u[].pop()
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
    """Terminate the server and forget everything it told us.

    The state has to go with the process. A restart re-roots the server, so
    diagnostics and completions from the old workspace are about files it is
    no longer looking at, and half a message left in the inbox would be
    parsed as the front of the new server's first reply.
    """
    if not is_running():
        return
    with autoreleasepool():
        _ = msg_send[ObjCObject, "NSTask", "terminate"](
            ObjCObject(g_task()[])
        )
    g_task()[] = 0
    g_in()[] = 0
    g_ready()[] = 0
    g_read_fd()[] = 0
    set_inbox(String())
    clear_diagnostics()
    clear_completions()


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
    # A reply to the outstanding completion request.
    if msg.has("id") and msg.has("result"):
        let id = msg.get("id")[].as_int()
        if id == g_comp_request()[] and id != 0:
            _take_completions(msg.get("result")[])
            return

    # A reply to initialize: tell the server we are ready, then we are.
    if msg.has("result") and not msg.has("method"):
        if g_ready()[] == 0:
            var empty = JSON.object()
            notify(String("initialized"), empty^)
            g_ready()[] = 1


def _take_completions(result: JSON):
    """A completion reply is either a bare array of items or a list object with
    them under `items`. Servers send both shapes; this reads either.

    Two branches rather than a conditional expression, because a conditional
    would have to produce a JSON value and JSON owns two Lists and a String --
    copying one is a decision, not something to slip into an expression.
    """
    clear_completions()
    if result.has("items"):
        _collect_completions(result.get("items")[])
    else:
        _collect_completions(result)
    g_comp_serial()[] += 1


def _collect_completions(items: JSON):
    var i = 0
    while i < items.count():
        let it = items.at(i)[]
        let label = it.get("label")[].as_string()
        if label != "":
            g_comp_label()[].append(label)
            g_comp_detail()[].append(it.get("detail")[].as_string())
            # insertText when the server gives one, otherwise the label. They
            # differ wherever the visible name is not what gets typed.
            let insert = it.get("insertText")[].as_string()
            g_comp_insert()[].append(insert if insert != "" else label)
        i += 1


def _take_diagnostics(params: JSON):
    # A publish replaces that document's set and touches no other. The server
    # sends one of these per document it is watching, so clearing everything
    # here -- which is what this used to do -- meant the last file to be
    # analysed owned the display.
    let uri = params.get("uri")[].as_string()
    _drop_diagnostics_for(uri)
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
        g_diag_uri()[].append(uri)
        i += 1
