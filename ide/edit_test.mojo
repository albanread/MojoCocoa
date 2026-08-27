# Editing behaviour, without a window.
#
# The text input client is the piece the design calls highest-risk, and the
# risk is not the Objective-C plumbing -- it is the arithmetic underneath.
# These drive apply_command and replace_selection directly.
from gridview import (
    set_rope,
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

    print()
    if failures == 0:
        print("edit OK")
    else:
        print("edit FAILED:", failures)
        raise Error("edit tests failed")
