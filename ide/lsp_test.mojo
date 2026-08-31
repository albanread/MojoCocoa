# Talks to the real mojo-lsp-server: spawn it, initialize, open a file with a
# deliberate error in it, and read the diagnostics back.
#
# No window and no event loop -- poll() is driven from a plain loop here and
# from a timer in the app, which is the only difference between them.
from lsp import (
    readable,
    request_completion,
    completion_count,
    g_comp_label,
    g_comp_detail,
    start,
    stop,
    poll,
    frame,
    is_ready,
    did_open,
    diagnostic_count,
    g_diag_line,
    g_diag_col,
    g_diag_sev,
    g_diag_msg,
    clear_diagnostics,
    set_shown_uri,
    visible_diagnostic_count,
    first_visible_diagnostic,
)
from std.os import getenv
from std.time import sleep


def check(name: String, got: String, want: String) -> Int:
    if got == want:
        print("  OK  ", name)
        return 0
    print("  FAIL", name, "-- got", repr(got), "want", repr(want))
    return 1


def check_true(name: String, got: Bool, detail: String) -> Int:
    if got:
        print("  OK  ", name, detail)
        return 0
    print("  FAIL", name, detail)
    return 1


def pump(seconds: Float64) -> Int:
    """Drive poll() for a while, the way the app's timer will."""
    var handled = 0
    var waited = 0.0
    while waited < seconds:
        handled += poll()
        sleep(0.05)
        waited += 0.05
    return handled


def main() raises:
    var failures = 0

    print("lsp: framing")
    failures += check(
        "content length counts bytes",
        frame(String("{}")),
        String("Content-Length: 2\r\n\r\n{}"),
    )
    # Non-ASCII: the header must count bytes, not characters, or the server
    # waits forever for bytes that never come. Nine characters, ten bytes,
    # because é is two.
    failures += check(
        "utf-8 body length",
        frame(String('{"s":"é"}')),
        String('Content-Length: 10\r\n\r\n{"s":"é"}'),
    )

    let server = getenv("ROAST_LSP")
    if server == "":
        print()
        print("lsp: no server given, skipping the live half")
        print("     set ROAST_LSP=<path to mojo-lsp-server>")
        if failures == 0:
            print("lsp OK (framing only)")
            return
        raise Error("lsp framing tests failed")

    print("lsp: handshake with", server)
    let root = String("file:///tmp")
    # Without an import path every parse fails on `std` and the diagnostics
    # are about configuration rather than the code.
    let imports = getenv("ROAST_IMPORTS")
    failures += check_true(
        "spawned", start(server, root, imports), String("")
    )
    _ = pump(6.0)
    failures += check_true("initialized", is_ready(), String("server replied"))

    print("lsp: diagnostics for a file with a real error")
    # `let` bindings are immutable in cocoa-mojo, so assigning to one is an
    # error the compiler has a message for -- which makes it a good probe.
    let bad = String("def main():\n    let x = 1\n    x = 2\n")
    let uri = String("file:///tmp/roast_lsp_probe.mojo")
    did_open(uri, bad)
    _ = pump(12.0)

    let n = diagnostic_count()
    failures += check_true(
        "got diagnostics", n > 0, String("count ") + String(n)
    )
    if n > 0:
        var i = 0
        while i < n:
            print(
                "       line",
                g_diag_line()[][i],
                "col",
                g_diag_col()[][i],
                "severity",
                g_diag_sev()[][i],
                ":",
                g_diag_msg()[][i],
            )
            i += 1
        # The error is on line 2 (zero-based), where x is assigned.
        var found_line_2 = False
        for l in g_diag_line()[]:
            if l == 2:
                found_line_2 = True
        failures += check_true(
            "points at the assignment", found_line_2, String("line 2")
        )

    print("lsp: a diagnostic's related site is marked too")
    # The dangling-`let` error. The server reports it on the line that READS
    # the reference and puts the mutation that invalidated it in
    # relatedInformation -- so without the note the mark lands on a `print`
    # and the `append` that caused it goes unmarked.
    clear_diagnostics()
    let dangle = String(
        "def main():\n"
        "    var l = List[Int]()\n"
        "    l.append(11)\n"
        "    let first = l[0]\n"
        "    l.append(12)\n"
        "    print(first)\n"
    )
    let duri = String("file:///tmp/roast_dangle_probe.mojo")
    set_shown_uri(duri)
    did_open(duri, dangle)
    _ = pump(12.0)

    var err_at = -1
    var note_at = -1
    var i2 = 0
    while i2 < diagnostic_count():
        if g_diag_sev()[][i2] == 1:
            err_at = i2
        elif g_diag_sev()[][i2] == 3:
            note_at = i2
        i2 += 1

    failures += check_true(
        "error reported", err_at >= 0, String("severity 1 present")
    )
    failures += check_true(
        "related site marked", note_at >= 0, String("severity 3 present")
    )
    if note_at >= 0:
        # Line 4 (zero-based) is the second append, which is what invalidated
        # the reference bound on the line above it.
        failures += check_true(
            "note marks the invalidating line",
            g_diag_line()[][note_at] == 4,
            String("line ") + String(g_diag_line()[][note_at]),
        )
    if err_at >= 0:
        # The note's text rides along on the message, so the status line can
        # explain a cause that may be scrolled off screen.
        failures += check_true(
            "message carries the note",
            g_diag_msg()[][err_at].find(String("invalidated here")) >= 0,
            g_diag_msg()[][err_at],
        )
    # One problem, not two: the marker must not be counted or reported first.
    failures += check_true(
        "counted once",
        visible_diagnostic_count() == 1,
        String("count ") + String(visible_diagnostic_count()),
    )
    failures += check_true(
        "status leads with the error",
        first_visible_diagnostic() == err_at,
        String("index ") + String(first_visible_diagnostic()),
    )
    clear_diagnostics()
    set_shown_uri(String())

    print("lsp: completion inside a Cocoa selector string")
    # The position the whole session has been building towards: a partial
    # selector inside msg_send, where the answer comes from cocoa.sqlite rather
    # than from anything in the file.
    let cocoa = String(
        "from std.objc import ObjCClass, msg_send, ObjCObject\n"
        "\n"
        "def main():\n"
        '    let w = msg_send[ObjCObject, "NSWindow", "setTit"](x)\n'
    )
    let curi = String("file:///tmp/roast_cocoa_probe.mojo")
    did_open(curi, cocoa)
    _ = pump(8.0)

    # Line 3, just past "setTit" -- character counts UTF-16 units, and this
    # line is ASCII, so it is the column.
    let line3 = String('    let w = msg_send[ObjCObject, "NSWindow", "setTit"](x)')
    let col = line3.find(String("setTit")) + 6
    _ = request_completion(curi, 3, col)
    _ = pump(10.0)

    let cn = completion_count()
    failures += check_true(
        "got completions", cn > 0, String("count ") + String(cn)
    )
    var found_set_title = False
    var shown = 0
    for i in range(cn):
        if g_comp_label()[][i] == "setTitle:":
            found_set_title = True
        if shown < 6:
            print("       ", g_comp_label()[][i], "  ", g_comp_detail()[][i])
            shown += 1
    failures += check_true(
        "setTitle: offered", found_set_title, String("from cocoa.sqlite")
    )

    stop()
    print()
    if failures == 0:
        print("lsp OK")
    else:
        print("lsp FAILED:", failures)
        raise Error("lsp tests failed")
