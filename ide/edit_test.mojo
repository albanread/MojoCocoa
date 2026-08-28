# Editing behaviour, without a window.
#
# The text input client is the piece the design calls highest-risk, and the
# risk is not the Objective-C plumbing -- it is the arithmetic underneath.
# These drive apply_command and replace_selection directly.
from gridview import (
    set_rope,
    undo,
    copy_selection,
    cut_selection,
    paste_clipboard,
    clipboard_write,
    clipboard_read,
    redo,
    g_undo,
    g_redo,
    g_coalesce_at,
    display_column,
    offset_at_point,
    highlight,
    KIND_PLAIN,
    KIND_COMMENT,
    KIND_STRING,
    KIND_KEYWORD,
    KIND_NUMBER,
    set_query,
    find_next,
    find_previous,
    match_count,
    query,
    set_caret,
    apply_command,
    replace_selection,
    g_buffer,
    g_caret,
    g_anchor,
    byte_to_utf16,
    utf16_to_byte,
)
from rope import Rope
from std.objc import load_framework


def buffer_text() -> String:
    return g_buffer()[][0].to_string()


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

    print("edit: typing")
    set_rope(Rope(String("abc")))
    set_caret(3)
    replace_selection(String("d"))
    failures += check("append", buffer_text(), String("abcd"))
    failures += check_int("caret after insert", g_caret()[], 4)

    set_caret(0)
    replace_selection(String("X"))
    failures += check("insert at start", buffer_text(), String("Xabcd"))

    print("edit: selection replace")
    g_anchor()[] = 0
    g_caret()[] = 5
    replace_selection(String("hi"))
    failures += check("replace selection", buffer_text(), String("hi"))
    failures += check_int("caret collapses", g_caret()[], 2)

    print("edit: backspace respects UTF-8")
    # é is two bytes, 日 is three. A byte-at-a-time backspace corrupts both.
    set_rope(Rope(String("aé日")))
    set_caret(6)
    apply_command(String("deleteBackward:"))
    failures += check("delete 3-byte char", buffer_text(), String("aé"))
    apply_command(String("deleteBackward:"))
    failures += check("delete 2-byte char", buffer_text(), String("a"))
    apply_command(String("deleteBackward:"))
    failures += check("delete ascii", buffer_text(), String(""))
    apply_command(String("deleteBackward:"))
    failures += check("backspace at start is a no-op", buffer_text(), String(""))

    print("edit: newline and tab")
    set_rope(Rope(String("ab")))
    set_caret(1)
    apply_command(String("insertNewline:"))
    failures += check("split line", buffer_text(), String("a\nb"))
    apply_command(String("insertTab:"))
    failures += check("tab is spaces", buffer_text(), String("a\n    b"))

    print("edit: horizontal movement")
    set_rope(Rope(String("hello\nworld")))
    set_caret(0)
    apply_command(String("moveRight:"))
    failures += check_int("right", g_caret()[], 1)
    apply_command(String("moveLeft:"))
    failures += check_int("left", g_caret()[], 0)
    apply_command(String("moveLeft:"))
    failures += check_int("left at start clamps", g_caret()[], 0)
    apply_command(String("moveToEndOfLine:"))
    failures += check_int("end of line", g_caret()[], 5)
    apply_command(String("moveToBeginningOfLine:"))
    failures += check_int("start of line", g_caret()[], 0)

    print("edit: vertical movement keeps the column")
    set_rope(Rope(String("hello\nworld\nhi")))
    set_caret(3)  # 'l' on line 0
    apply_command(String("moveDown:"))
    failures += check_int("down keeps column", g_caret()[], 9)
    apply_command(String("moveUp:"))
    failures += check_int("up returns", g_caret()[], 3)
    # Onto a shorter line, the caret clamps to its end rather than overshooting.
    set_caret(9)
    apply_command(String("moveDown:"))
    failures += check_int("down onto shorter line clamps", g_caret()[], 14)
    apply_command(String("moveUp:"))
    failures += check_int("up from clamped", g_caret()[], 8)

    print("edit: UTF-16 offsets, which Cocoa counts in")
    set_rope(Rope(String("aé日")))
    failures += check_int("byte 0 -> utf16", byte_to_utf16(0), 0)
    failures += check_int("byte 1 -> utf16", byte_to_utf16(1), 1)
    failures += check_int("byte 3 (after é)", byte_to_utf16(3), 2)
    failures += check_int("byte 6 (after 日)", byte_to_utf16(6), 3)
    failures += check_int("utf16 2 -> byte", utf16_to_byte(2), 3)
    failures += check_int("utf16 3 -> byte", utf16_to_byte(3), 6)

    print("edit: undo is a stack of buffers")
    # Start each undo case from a clean stack.
    while len(g_undo()[]) > 0:
        _ = g_undo()[].pop()
    while len(g_redo()[]) > 0:
        _ = g_redo()[].pop()

    set_rope(Rope(String("start")))
    set_caret(5)
    g_coalesce_at()[] = -1
    replace_selection(String("!"))
    failures += check("edited", buffer_text(), String("start!"))
    failures += check_int("undo available", Int(undo()), 1)
    failures += check("undone", buffer_text(), String("start"))
    failures += check_int("caret restored", g_caret()[], 5)
    failures += check_int("redo available", Int(redo()), 1)
    failures += check("redone", buffer_text(), String("start!"))
    failures += check_int("redo exhausted", Int(redo()), 0)

    print("edit: typing coalesces into one entry")
    set_rope(Rope(String("")))
    set_caret(0)
    g_coalesce_at()[] = -1
    while len(g_undo()[]) > 0:
        _ = g_undo()[].pop()
    for ch in [String("a"), String("b"), String("c")]:
        replace_selection(ch)
    failures += check("typed", buffer_text(), String("abc"))
    failures += check_int("one undo entry for a run", len(g_undo()[]), 1)
    _ = undo()
    failures += check("one undo takes the run", buffer_text(), String(""))

    print("edit: a new edit discards the redo branch")
    set_rope(Rope(String("x")))
    set_caret(1)
    g_coalesce_at()[] = -1
    while len(g_undo()[]) > 0:
        _ = g_undo()[].pop()
    while len(g_redo()[]) > 0:
        _ = g_redo()[].pop()
    replace_selection(String("y"))
    _ = undo()
    failures += check_int("redo pending", len(g_redo()[]), 1)
    g_coalesce_at()[] = -1
    replace_selection(String("z"))
    failures += check_int("redo discarded", len(g_redo()[]), 0)
    failures += check("branch replaced", buffer_text(), String("xz"))

    print("edit: undo on an empty stack is a no-op")
    while len(g_undo()[]) > 0:
        _ = g_undo()[].pop()
    let before = buffer_text()
    failures += check_int("undo refuses", Int(undo()), 0)
    failures += check("buffer unchanged", buffer_text(), before)

    print("edit: columns and hit testing")
    set_rope(Rope(String("ab\ncdé日f")))
    # Byte 3 is the start of line 1; é is 2 bytes, 日 is 3.
    failures += check_int("column at line start", display_column(3), 0)
    failures += check_int("column after 2 ascii", display_column(5), 2)
    failures += check_int("column after é", display_column(7), 3)
    failures += check_int("column after 日", display_column(10), 4)
    # A click never lands inside a character.
    let hit = offset_at_point(0.0, 0.0)
    failures += check_int("click before line 0", hit, 0)

    print("edit: find")
    set_rope(Rope(String("alpha beta gamma beta delta")))
    set_caret(0)
    set_query(String("beta"))
    failures += check_int("match count", match_count(), 2)
    failures += check_int("find next", Int(find_next()), 1)
    failures += check_int("selects the match", g_anchor()[], 6)
    failures += check_int("caret after match", g_caret()[], 10)
    failures += check_int("find next again", Int(find_next()), 1)
    failures += check_int("second match", g_anchor()[], 17)
    # Past the last match it wraps, which is what every editor does.
    failures += check_int("wraps", Int(find_next()), 1)
    failures += check_int("wrapped to first", g_anchor()[], 6)
    failures += check_int("find previous", Int(find_previous()), 1)
    failures += check_int("previous is the last", g_anchor()[], 17)

    set_query(String("nothing here"))
    failures += check_int("no matches", match_count(), 0)
    failures += check_int("find fails cleanly", Int(find_next()), 0)
    set_query(String(""))
    failures += check_int("empty query finds nothing", Int(find_next()), 0)

    print("edit: the lexer")

    def kinds_of(src: String) -> String:
        var out = String()
        for k in highlight(src):
            out += String(k)
        return out^

    # plain 0, comment 1, string 2, keyword 3, number 4.
    failures += check("keyword", kinds_of(String("def f")), String("33300"))
    failures += check(
        "comment to end of line", kinds_of(String("a # b")), String("00111")
    )
    failures += check("string", kinds_of(String('x "ab"')), String("002222"))
    failures += check("number", kinds_of(String("n = 42")), String("000044"))
    # `let` and `fn` are this fork's, and an editor that greyed them out would
    # be quietly wrong about the language it is for.
    failures += check("let is a keyword", kinds_of(String("let")), String("333"))
    failures += check("fn is a keyword", kinds_of(String("fn")), String("33"))
    # `class` declares a real Objective-C class in this fork -- its flagship
    # keyword, and until now uncoloured in its own IDE.
    failures += check(
        "class is a keyword", kinds_of(String("class A")), String("3333300")
    )
    failures += check(
        "imm is a keyword", kinds_of(String("imm x")), String("33300")
    )
    # A keyword inside a longer identifier is not a keyword.
    failures += check(
        "define is not def", kinds_of(String("define")), String("000000")
    )
    # A # inside a string is not a comment.
    failures += check(
        "hash in string", kinds_of(String('"#"')), String("222")
    )

    print("edit: keyboard selection")
    # Every motion has an AndModifySelection: twin that AppKit sends for the
    # shifted key. The twin is the same motion leaving the anchor behind.
    set_rope(Rope(String("abc def")))
    set_caret(0)
    apply_command(String("moveRightAndModifySelection:"))
    apply_command(String("moveRightAndModifySelection:"))
    apply_command(String("moveRightAndModifySelection:"))
    failures += check_int("shift-right anchor", g_anchor()[], 0)
    failures += check_int("shift-right caret", g_caret()[], 3)
    # Unshifted arrow with a selection collapses to its edge, not caret±1.
    apply_command(String("moveLeft:"))
    failures += check_int("left collapses to start", g_caret()[], 0)
    failures += check_int("collapse clears anchor", g_anchor()[], 0)
    apply_command(String("moveWordRightAndModifySelection:"))
    failures += check_int("shift-word-right", g_caret()[], 3)
    apply_command(String("moveRight:"))
    failures += check_int("right collapses to end", g_caret()[], 3)
    apply_command(String("moveToEndOfLineAndModifySelection:"))
    failures += check_int("shift-end caret", g_caret()[], 7)
    failures += check_int("shift-end anchor", g_anchor()[], 3)

    print("edit: caret steps in codepoints")
    # é is two bytes, 日 three. A byte-stepping caret parks inside them.
    set_rope(Rope(String("aé日b")))
    set_caret(0)
    apply_command(String("moveRight:"))
    failures += check_int("over a", g_caret()[], 1)
    apply_command(String("moveRight:"))
    failures += check_int("over é", g_caret()[], 3)
    apply_command(String("moveRight:"))
    failures += check_int("over 日", g_caret()[], 6)
    apply_command(String("moveLeft:"))
    failures += check_int("back over 日", g_caret()[], 3)
    apply_command(String("moveLeft:"))
    failures += check_int("back over é", g_caret()[], 1)
    # Arriving beside a multibyte character from another line cannot land
    # inside it: the column snaps to the boundary before it.
    set_rope(Rope(String("xxxx\na日b")))
    set_caret(3)  # column 3 on line 0
    apply_command(String("moveDown:"))
    failures += check_int("down snaps off multibyte", g_caret()[], 6)

    print("edit: word movement")
    set_rope(Rope(String("foo bar_baz  qux")))
    set_caret(16)
    apply_command(String("moveWordLeft:"))
    failures += check_int("word left", g_caret()[], 13)
    apply_command(String("moveWordLeft:"))
    failures += check_int("word left again", g_caret()[], 4)
    apply_command(String("moveWordRight:"))
    failures += check_int("word right", g_caret()[], 11)
    # Crosses lines: newlines are separators like any other.
    set_rope(Rope(String("one\ntwo")))
    set_caret(4)
    apply_command(String("moveWordLeft:"))
    failures += check_int("word left across newline", g_caret()[], 0)

    print("edit: word deletion")
    set_rope(Rope(String("hello brave world")))
    set_caret(17)
    apply_command(String("deleteWordBackward:"))
    failures += check("option-backspace", buffer_text(), String("hello brave "))
    apply_command(String("deleteWordBackward:"))
    failures += check("again", buffer_text(), String("hello "))
    _ = undo()
    failures += check("one undo entry each", buffer_text(), String("hello brave "))
    set_rope(Rope(String("keep  drop rest")))
    set_caret(4)
    apply_command(String("deleteWordForward:"))
    failures += check("delete word forward", buffer_text(), String("keep rest"))
    set_rope(Rope(String("line one\nline two")))
    set_caret(14)
    apply_command(String("deleteToBeginningOfLine:"))
    failures += check("cmd-backspace", buffer_text(), String("line one\ntwo"))

    print("edit: paging")
    set_rope(Rope(String("l0\nl1\nl2\nl3\nl4\nl5")))
    set_caret(0)
    apply_command(String("pageDown:"), page_lines=2)
    failures += check_int("page down two lines", g_caret()[], 6)
    apply_command(String("pageDown:"), page_lines=100)
    failures += check_int("page down clamps to end", g_caret()[], 17)
    apply_command(String("pageUpAndModifySelection:"), page_lines=2)
    failures += check_int("shift-page-up caret", g_caret()[], 11)
    failures += check_int("shift-page-up anchor", g_anchor()[], 17)

    print("edit: document width follows the widest line")
    # The draw loop feeds note_line_cols; here it is fed directly, with a
    # pretend 7-point advance since no font is measured without a window.
    from gridview import (
        note_line_cols,
        reset_line_cols,
        document_size,
        g_advance_x1000,
        g_line_h_x1000,
    )
    g_advance_x1000()[] = 7000
    g_line_h_x1000()[] = 17000
    set_rope(Rope(String("short")))
    reset_line_cols()
    failures += check_int(
        "viewport wins while lines are short",
        Int(document_size(600.0).width),
        600,
    )
    failures += check_int(
        "a wide line moves the record", 1 if note_line_cols(200) else 0, 1
    )
    if document_size(600.0).width > 600.0:
        print("  OK   width grows past the viewport")
    else:
        print("  FAIL width grows past the viewport --", document_size(600.0).width)
        failures += 1
    failures += check_int(
        "narrower lines do not shrink it", 1 if note_line_cols(50) else 0, 0
    )
    reset_line_cols()
    failures += check_int(
        "a document switch resets it", Int(document_size(600.0).width), 600
    )

    print("edit: clipboard")
    # NSPasteboard needs AppKit but no window and no run loop, so this stays a
    # windowless test. The general pasteboard is shared machine state; the
    # round trip writes before it reads, so a busy clipboard cannot fail it.
    if load_framework["AppKit"]():
        set_rope(Rope(String("keep THIS not that")))
        g_anchor()[] = 5
        g_caret()[] = 9
        failures += check_int(
            "copy wants a selection", 1 if copy_selection() else 0, 1
        )
        failures += check("copied text", clipboard_read(), String("THIS"))
        set_caret(0)
        failures += check_int(
            "copy with no selection refuses",
            1 if copy_selection() else 0,
            0,
        )
        failures += check(
            "refused copy leaves the clipboard", clipboard_read(), String("THIS")
        )
        g_anchor()[] = 0
        g_caret()[] = g_buffer()[][0].byte_length()
        replace_selection(String(""))
        failures += check("cleared", buffer_text(), String(""))
        failures += check_int(
            "paste", 1 if paste_clipboard() else 0, 1
        )
        failures += check("pasted text", buffer_text(), String("THIS"))
        failures += check_int("caret after paste", g_caret()[], 4)

        # Cut is copy plus delete, and must be one undo entry.
        set_rope(Rope(String("abcdef")))
        g_anchor()[] = 2
        g_caret()[] = 4
        failures += check_int("cut", 1 if cut_selection() else 0, 1)
        failures += check("cut removes", buffer_text(), String("abef"))
        failures += check("cut copies", clipboard_read(), String("cd"))
        _ = undo()
        failures += check("undo after cut", buffer_text(), String("abcdef"))

        # UTF-8 through the clipboard, byte-exact.
        _ = clipboard_write(String("café 日本"))
        failures += check(
            "unicode round trip", clipboard_read(), String("café 日本")
        )
    else:
        print("  FAIL clipboard -- AppKit did not load")
        failures += 1

    print()
    if failures == 0:
        print("edit OK")
    else:
        print("edit FAILED:", failures)
        raise Error("edit tests failed")
