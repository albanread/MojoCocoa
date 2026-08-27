# Editing behaviour, without a window.
#
# The text input client is the piece the design calls highest-risk, and the
# risk is not the Objective-C plumbing -- it is the arithmetic underneath.
# These drive apply_command and replace_selection directly.
from gridview import (
    set_rope,
    undo,
    redo,
    g_undo,
    g_redo,
    g_coalesce_at,
    display_column,
    offset_at_point,
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

    print()
    if failures == 0:
        print("edit OK")
    else:
        print("edit FAILED:", failures)
        raise Error("edit tests failed")
