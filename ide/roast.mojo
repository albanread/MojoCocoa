# Roast — a Mojo IDE, written in cocoa-mojo. Milestone 0: the shell.
#
# A real Mac application window: menu bar, toolbar, source-list sidebar, split
# view, and a status bar. No editor yet — milestone 1 brings the rope and the
# grid view. What this proves is that the whole AppKit shell of a document app
# can be assembled from Mojo, with every delegate and action being a Mojo `fn`
# reached through classes registered at run time.
#
# Set ROAST_AUTOCLOSE_TICKS=N to close the window after N timer ticks, so the
# full lifecycle runs unattended in CI. Same trick as window_smoke.
from std.objc import (
    load_framework,
    ObjCClass,
    ObjCObject,
    msg_send,
    nsstring,
    autoreleasepool,
    IMP1,
    IMP1Bool,
    named_global,
    extern_object,
    sel,
)
from std.memory import OpaquePointer
from std.os import getenv
from std.ffi import external_call
from std.objc import ns_to_string, SEL
from gridview import (
    g_caret,
    make_grid_view,
    set_rope,
    document_size,
    GUTTER_W,
    set_query,
    find_next,
    find_previous,
    match_count,
    query,
    caret_position,
    line_height,
)
from rope import Rope
from gridview import (
    set_caret,
    document_size,
    g_revision,
    g_buffer,
    g_caret,
    show_popup,
    hide_popup,
    popup_open,
    byte_to_utf16,
    font_size,
    set_font_size,
)
import lsp
import document
import build

comptime P = OpaquePointer[MutUntrackedOrigin]


# Delegate methods that answer with an object return the `id` as an address,
# because they must be able to answer nil and Mojo's Pointer cannot be null.
# See the IMP*Obj note in std/objc/classes.mojo.
comptime NIL = 0


# Geometry comes from gridview, which needs the same structs to do its
# arithmetic. One declaration, not two that can drift.
from gridview import CGPoint, CGSize, CGRect, NSRange, rect


# ── State the callbacks can reach ────────────────────────────────────────────
# Callbacks are C-ABI `fn`s and get no closure, so anything they touch is a
# named process global. Each is zero until main() sets it.
comptime g_window = named_global["roast.window", Int]
comptime g_status = named_global["roast.status", Int]
comptime g_ticks = named_global["roast.ticks", Int]
comptime g_autoclose = named_global["roast.autoclose", Int]
comptime g_actions = named_global["roast.actions", Int]
comptime g_grid = named_global["roast.grid", Int]
comptime g_findfield = named_global["roast.findfield", Int]

# Edits bump gridview's revision; the timer notices and sends one didChange
# for a burst of typing rather than one per keystroke. (The uri and the
# sent revision live per-document in document.mojo.)
comptime g_idle_ticks = named_global["roast.idle", Int]

# The project: a folder, and the outline view showing what is in it. Children
# are listed on demand and cached per directory, so opening a folder never
# walks it -- a tree with a quarter of a million files under it costs whatever
# has been expanded and nothing more.
comptime g_root = named_global["roast.root", List[String]]
# Where the language server is currently rooted, so re-rooting it to the same
# place is recognised as the no-op it is rather than costing a process.
comptime g_lsp_root = named_global["roast.lsp.root", List[String]]
comptime g_outline = named_global["roast.outline", Int]
comptime g_tree_cache = named_global["roast.tree.cache", Int]

# The revision the file on disk matches. The buffer is dirty whenever the rope
# has moved past it, which is one comparison rather than a flag someone has to
# remember to set.
comptime g_tabbar = named_global["roast.tabbar", Int]

# The console, and the horizontal split it lives in the bottom of.
comptime g_console = named_global["roast.console", Int]
comptime g_vsplit = named_global["roast.vsplit", Int]
comptime g_console_open = named_global["roast.console.open", Int]
# How many bytes of build.output() the console pane is already showing, so a
# pump appends the delta instead of re-setting the whole transcript.
comptime g_console_shown = named_global["roast.console.shown", Int]
comptime g_build_seen = named_global["roast.build.seen", Int]
# The editor's share of the height when the console is showing.
comptime EDITOR_SHARE = 0.68
comptime TAB_H = 28.0
comptime TAB_MIN = 90.0
comptime TAB_MAX = 200.0
# The close box, and the gutter the strip reserves at each end for the overflow
# arrows. Both are in points; the scroll offset is whole points in an Int
# because an app-lifetime global has to survive zero-initialisation.
comptime TAB_CLOSE = 16.0
comptime TAB_GUTTER = 14.0
comptime g_tab_scroll = named_global["roast.tab.scroll", Int]
comptime g_pending_completion = named_global["roast.completing", Int]
# The last handshake this app has announced its open documents to.
comptime g_lsp_announced = named_global["roast.lsp.announced", Int]
comptime g_comp_seen = named_global["roast.comp.seen", Int]


def g_buffer_text() -> String:
    if len(g_buffer()[]) == 0:
        return String()
    return g_buffer()[][0].to_string()


def g_buffer_lines() -> Int:
    """Lines in the open buffer, for the startup report."""
    if len(g_buffer()[]) == 0:
        return 0
    return g_buffer()[][0].line_count()


def set_status(text: String):
    """Write the status bar. Safe before the field exists."""
    if g_status()[] == 0:
        return
    with autoreleasepool():
        let field = ObjCObject(g_status()[])
        _ = msg_send[ObjCObject, "NSTextField", "setStringValue:"](
            field, nsstring(text).ptr()
        )


# ── Toolbar item identifiers ─────────────────────────────────────────────────
# NSToolbar addresses its items by string identifier; the delegate is asked for
# each one by name. Keeping them in one place keeps the three delegate methods
# honest with each other.
comptime TB_BUILD = "roast.build"
comptime TB_RUN = "roast.run"
comptime TB_STOP = "roast.stop"
comptime TB_FIND = "roast.find"


def toolbar_ids() -> ObjCObject:
    """The toolbar's item identifiers, in bar order."""
    let NSMutableArray = ObjCClass.lookup["NSMutableArray"]()
    let ids = msg_send[ObjCObject, "NSMutableArray", "array", is_class=True](
        NSMutableArray.as_object()
    )
    for name in [
        String(TB_BUILD),
        String(TB_RUN),
        String(TB_STOP),
        # Flexible space then search: the find field sits at the trailing edge,
        # where every Mac app puts it.
        String("NSToolbarFlexibleSpaceItem"),
        String(TB_FIND),
    ]:
        _ = msg_send[ObjCObject, "NSMutableArray", "addObject:"](
            ids, nsstring(name).ptr()
        )
    return ids


# ── Callbacks ────────────────────────────────────────────────────────────────
class RoastAppDelegate:
    """The application delegate.

    A `class` declaration is a real Objective-C class: the compiler derives
    each selector from the method name, takes its type encoding from the SDK,
    and registers the lot when the class is first instantiated. Nothing here
    names a selector, an encoding or an IMP.
    """

    def applicationDidFinishLaunching_(self, note: ObjCObject):
        print("roast: applicationDidFinishLaunching")

    def applicationShouldTerminateAfterLastWindowClosed_(
        self, app: ObjCObject
    ) -> Bool:
        # A single-window IDE quits with its window. Tabs live in one window,
        # so this stays true once tabbing is on.
        return True

    def applicationWillTerminate_(self, note: ObjCObject):
        # The body may raise; the boundary catches. Hence no `try` around a
        # call that can only fail by the server having already gone.
        lsp.stop()
        print("roast: applicationWillTerminate")


# ── Console ─────────────────────────────────────────────────────────────────
# One pane for the compiler's output and the program's, because a build that
# succeeds and then runs is one continuous thing to read.
def _dir_of(path: String) -> String:
    let b = path.as_bytes()
    var cut = -1
    for i in range(len(b)):
        if b[i] == 47:
            cut = i
    if cut <= 0:
        return String(".")
    return String(path[byte=0:cut])


def console_sync():
    """Show the log and keep its tail in view.

    Appends what is new rather than re-setting the whole transcript: the pane
    is refreshed on every pump, so setString: made showing a program's output
    quadratic in its length -- a chatty Run got slower the longer it printed.
    The byte count tracks build.output(); a shorter output means it was
    cleared, and the pane starts over.
    """
    if g_console()[] == 0:
        return
    with autoreleasepool():
        let tv = ObjCObject(g_console()[])
        let text = build.output()
        let have = g_console_shown()[]
        if text.byte_length() < have:
            _ = msg_send[ObjCObject, "NSTextView", "setString:"](
                tv, nsstring(text).ptr()
            )
        elif text.byte_length() > have:
            let delta = String(text[byte=have : text.byte_length()])
            let storage = msg_send[ObjCObject, "NSTextView", "textStorage"](tv)
            let at = msg_send[Int, "NSTextStorage", "length"](storage)
            # Plain-string replacement at the end takes its attributes from
            # the character before it, so the console keeps its font without
            # an attributed string being built per append.
            _ = msg_send[
                ObjCObject,
                "NSTextStorage",
                "replaceCharactersInRange:withString:",
            ](storage, NSRange(at, 0), nsstring(delta).ptr())
        else:
            return
        g_console_shown()[] = text.byte_length()
        _ = msg_send[ObjCObject, "NSTextView", "scrollToEndOfDocument:"](
            tv, ObjCObject(0).ptr()
        )


def console_text() -> String:
    """What the pane is actually showing, read back from AppKit rather than
    from the buffer it was built from -- so a check of this is a check of the
    whole path, not of a string we already had."""
    if g_console()[] == 0:
        return String()
    with autoreleasepool():
        return ns_to_string(
            msg_send[ObjCObject, "NSTextView", "string"](
                ObjCObject(g_console()[])
            )
        )


def show_console(want: Bool):
    """Slide the divider. The console is a pane, not a window, so hiding it is
    giving its height back to the editor rather than removing anything."""
    if g_vsplit()[] == 0:
        return
    with autoreleasepool():
        let vs = ObjCObject(g_vsplit()[])
        let b = msg_send[CGRect, "NSView", "bounds"](vs)
        var pos = b.size.height
        if want:
            pos = b.size.height * EDITOR_SHARE
        _ = msg_send[
            ObjCObject, "NSSplitView", "setPosition:ofDividerAtIndex:"
        ](vs, pos, Int(0))
        let subs = msg_send[ObjCObject, "NSView", "subviews"](vs)
        print(
            "roast: console",
            "open" if want else "closed",
            msg_send[CGRect, "NSView", "frame"](
                msg_send[ObjCObject, "NSArray", "objectAtIndex:"](subs, 1)
            ).size.height,
        )
    g_console_open()[] = 1 if want else 0


# ── Build and run ───────────────────────────────────────────────────────────
def _driver() -> String:
    """The cocoamojo beside us. An editor built by this toolchain should
    compile with this toolchain, not with whatever is on PATH."""
    var here = getenv("ROAST_COCOAMOJO")
    if here != "":
        return here^
    let root = getenv("COCOAMOJO_ROOT")
    if root == "":
        return String()
    return root + String("/bin/cocoamojo")


def _save_dirty() -> Int:
    """The compiler reads the disk, so what is on the disk had better be what
    is on the screen. Building without this compiles the last save, which
    looks exactly like the compiler ignoring your fix."""
    let n = document.dirty_count()
    if n == 0:
        return 0
    let started_at = document.current_index()
    var saved = 0
    var i = 0
    while i < document.count():
        if document.dirty_at(i) and document.path_at(i) != "":
            _ = switch_document(i)
            _ = save_current()
            saved += 1
        i += 1
    _ = switch_document(started_at)
    refresh_tabs()
    refresh_grid()
    return saved


def _start_build(then_run: Bool):
    if build.is_running():
        set_status(String("Already running — press Stop first"))
        return
    let driver = _driver()
    if driver == "":
        set_status(String("No compiler: set COCOAMOJO_ROOT"))
        return

    let saved = _save_dirty()
    let entry = build.entry_point(
        project_root(), document.path_at(document.current_index())
    )
    if entry == "":
        set_status(String("Nothing to build — open a file or a folder"))
        return

    let binary = build.binary_for(entry)
    _ = build.ensure_dir(_dir_of(binary))
    build.clear_output()
    var head = String("cocoamojo --build ") + entry
    head += String(" -o ") + binary + String("\n")
    if saved > 0:
        head = String("saved ") + String(saved) + String(" file(s)\n") + head
    build.append_output(head^)

    var args = List[String]()
    args.append(String("--build"))
    args.append(entry)
    args.append(String("-o"))
    args.append(binary)

    # Run is Build followed by the binary. Queue the second half now; the
    # timer starts it if and only if the first half exits zero.
    if then_run:
        build.set_then(binary, _dir_of(entry))
    else:
        build.clear_then()

    show_console(True)
    console_sync()
    if build.start(driver, args, _dir_of(entry), String("Building")):
        set_status(String("Building ") + _basename(entry) + String("…"))
    else:
        console_sync()
        set_status(String("Could not start the compiler"))


def _jump_to(path: String, line: Int, col: Int):
    """Put the caret on a diagnostic, opening the file if it is not open."""
    if path == "":
        return
    let uri = String("file://") + path
    let tab = document.index_of(uri)
    if tab >= 0:
        _ = switch_document(tab)
    elif not load_file(path):
        return
    # Either way, the error's file is now the current tab, and everything that
    # follows a tab change has to happen: reveal it in the strip, point the
    # server at it, redraw. Doing this only when `switch_document` returned
    # true skipped it for a file that had just been opened -- which is the
    # common case for a build error in a file you were not looking at.
    after_switch()
    print("roast: jump to", _basename(path), "line", line, "col", col)
    # The compiler counts from one; the buffer counts from zero.
    var target = line - 1
    if target < 0:
        target = 0
    if len(g_buffer()[]) == 0:
        return
    let rope = g_buffer()[][0]
    if target >= rope.line_count():
        target = rope.line_count() - 1
    var at = rope.line_start(target)
    if col > 1:
        at += col - 1
    if at > rope.byte_length():
        at = rope.byte_length()
    set_caret(at)
    scroll_to_caret()
    refresh_grid()


def _build_finished():
    let status = build.exit_status()
    let what = build.label()
    console_sync()
    let shown = console_text()
    print(
        "roast:",
        what.lower(),
        "finished, status",
        status,
        "-- console holds",
        shown.byte_length(),
        "bytes",
    )
    if getenv("ROAST_AUTOBUILD") != "":
        # CI reads the pane rather than the pipe, so what is asserted is what
        # someone would actually be looking at.
        print("--- console ---")
        print(shown)
        print("--- end ---")

    if status == 0:
        let next_exe = build.then_exe()
        if next_exe != "":
            var cwd = build.then_cwd()
            build.clear_then()
            build.append_output(
                String("\n─── ") + _basename(next_exe) + String(" ───\n")
            )
            console_sync()
            var none = List[String]()
            if build.start(next_exe, none, cwd, String("Running")):
                set_status(String("Running ") + _basename(next_exe) + String("…"))
                return
            console_sync()
            set_status(String("Built, but could not run it"))
            return
        if what == "Running":
            set_status(String("Finished"))
        else:
            set_status(String("Build succeeded"))
        return

    # Failed. Whatever queued behind this does not happen.
    build.clear_then()
    let log = build.output()
    let issue = build.first_error(log)
    if issue.line > 0:
        _jump_to(issue.path, issue.line, issue.col)
        set_status(
            _basename(issue.path)
            + String(":")
            + String(issue.line)
            + String("  ")
            + issue.message
        )
    elif what == "Running":
        set_status(String("Exited with status ") + String(status))
    else:
        set_status(String("Build failed (") + String(status) + String(")"))


class RoastActions:
    """Every menu and toolbar action, the sidebar's data source, and the
    timer -- one object, because one target is what AppKit wants.

    This replaces twenty-three `add_method` calls and the twenty-one
    encoding strings that went with them. The `roast*` selectors are ours,
    so their `v@:@` shape is derived; the AppKit ones are looked up.
    """

    def roastConsole_(self, sender: ObjCObject):
        try:
            show_console(g_console_open()[] == 0)
        except:
            pass

    def roastBuild_(self, sender: ObjCObject):
        try:
            _start_build(False)
        except:
            set_status(String("Build failed to start"))

    def roastRun_(self, sender: ObjCObject):
        try:
            _start_build(True)
        except:
            set_status(String("Run failed to start"))

    def roastStop_(self, sender: ObjCObject):
        try:
            if not build.is_running():
                set_status(String("Nothing running"))
                return
            let what = build.label()
            build.stop()
            g_build_seen()[] = build.serial()
            build.append_output(String("\n─── stopped ───\n"))
            console_sync()
            set_status(what + String(" stopped"))
        except:
            pass

    def roastNewTab_(self, sender: ObjCObject):
        """A new, empty document in a new tab."""
        try:
            # An empty document, which becomes real the first time it is saved.
            _ = document.open_document(String(""), Rope(String("")))
            after_switch()
        except:
            pass

    def roastNextTab_(self, sender: ObjCObject):
        try:
            if document.count() < 2:
                return
            let next = (document.current_index() + 1) % document.count()
            if switch_document(next):
                after_switch()
        except:
            pass

    def roastPrevTab_(self, sender: ObjCObject):
        try:
            if document.count() < 2:
                return
            let prev = (
                document.current_index() + document.count() - 1
            ) % document.count()
            if switch_document(prev):
                after_switch()
        except:
            pass

    def roastOpenExample_(self, sender: ObjCObject):
        """Open a shipped example: the folder as the project, its files as tabs.

        An example is a project, and `fern` is three files. Opening only the
        entry point makes the other two invisible until someone thinks to go
        looking in the sidebar, which rather defeats shipping them as a worked
        example.
        """
        try:
            with autoreleasepool():
                let path = msg_send[
                    ObjCObject, "NSMenuItem", "representedObject"
                ](sender)
                if path.addr() == 0:
                    set_status(String("That example has no path"))
                    return
                let file = ns_to_string(path)
                let cut = file.rfind("/")
                if cut <= 0:
                    set_status(String("Malformed example path"))
                    return
                let folder = String(file[byte=:cut])

                let opened = open_example_project(folder, file)
                if opened == 0:
                    set_status(String("Could not open ") + file)
                    return
                after_switch()
                set_status(
                    String("Example: ")
                    + folder[byte=cut_name(folder):]
                    + String("  ·  ")
                    + String(opened)
                    + String(" file" if opened == 1 else " files")
                )
        except:
            pass

    def roastCloseTab_(self, sender: ObjCObject):
        """Close the current tab. Shares its rule with the tab's × so the two
        cannot disagree about what happens to unsaved work."""
        close_tab_at(document.current_index())

    def outlineViewSelectionDidChange_(self, note: ObjCObject):
        """Clicking a file opens it. Clicking a folder does nothing but expand."""
        try:
            with autoreleasepool():
                if g_outline()[] == 0:
                    return
                let view = ObjCObject(g_outline()[])
                let row = msg_send[Int, "NSTableView", "selectedRow"](view)
                if row < 0:
                    return
                let item = msg_send[ObjCObject, "NSOutlineView", "itemAtRow:"](
                    view, row
                )
                if item.addr() == 0:
                    return
                let path = ns_to_string(item)
                if is_directory(path):
                    return
                _ = load_file(path)
        except:
            pass

    def roastOpenFolder_(self, sender: ObjCObject):
        try:
            with autoreleasepool():
                let NSOpenPanel = ObjCClass.lookup["NSOpenPanel"]()
                let panel = msg_send[
                    ObjCObject, "NSOpenPanel", "openPanel", is_class=True
                ](NSOpenPanel.as_object())
                _ = msg_send[ObjCObject, "NSOpenPanel", "setCanChooseFiles:"](
                    panel, False
                )
                _ = msg_send[
                    ObjCObject, "NSOpenPanel", "setCanChooseDirectories:"
                ](panel, True)
                if msg_send[Int, "NSSavePanel", "runModal"](panel) != 1:
                    return
                let url = msg_send[ObjCObject, "NSSavePanel", "URL"](panel)
                open_folder(
                    ns_to_string(msg_send[ObjCObject, "NSURL", "path"](url))
                )
        except:
            pass

    def roastOpen_(self, sender: ObjCObject):
        """Open a file. The panel is Cocoa's, so it looks and behaves like every
        other open panel on the machine."""
        try:
            with autoreleasepool():
                let NSOpenPanel = ObjCClass.lookup["NSOpenPanel"]()
                let panel = msg_send[
                    ObjCObject, "NSOpenPanel", "openPanel", is_class=True
                ](NSOpenPanel.as_object())
                _ = msg_send[ObjCObject, "NSOpenPanel", "setCanChooseFiles:"](
                    panel, True
                )
                _ = msg_send[
                    ObjCObject, "NSOpenPanel", "setCanChooseDirectories:"
                ](panel, False)
                _ = msg_send[
                    ObjCObject, "NSOpenPanel", "setAllowsMultipleSelection:"
                ](panel, False)
                # Modal, because there is one buffer: opening a second file while
                # the first is still being chosen has nowhere to go until
                # milestone 3 gives documents somewhere to live.
                let answer = msg_send[Int, "NSSavePanel", "runModal"](panel)
                if answer != 1:  # NSModalResponseOK
                    return
                let url = msg_send[ObjCObject, "NSSavePanel", "URL"](panel)
                let path = msg_send[ObjCObject, "NSURL", "path"](url)
                _ = load_file(ns_to_string(path))
        except:
            pass

    def roastSave_(self, sender: ObjCObject):
        try:
            _ = save_current()
        except:
            pass

    def roastSaveAll_(self, sender: ObjCObject):
        """Write every dirty buffer.

        There is one buffer, so today this is Save with a different name. It exists
        now because the command belongs in the File menu from the start and because
        the loop it will grow -- over documents, saving the dirty ones -- is easier
        to add than to retrofit around callers who learned to call Save instead.
        """
        try:
            let n = document.dirty_count()
            if n == 0:
                set_status(String("Nothing to save"))
                return
            let started_at = document.current_index()
            var saved = 0
            var i = 0
            while i < document.count():
                if document.dirty_at(i):
                    # Switching makes it the working set; saving writes the working
                    # set. One path for one document and for all of them.
                    _ = switch_document(i)
                    _ = save_current()
                    saved += 1
                i += 1
            _ = switch_document(started_at)
            refresh_tabs()
            refresh_grid()
            set_status(String("Saved ") + String(saved) + String(" files"))
        except:
            pass

    def roastComplete_(self, sender: ObjCObject):
        """Ask the server what could go here, at the caret."""
        try:
            if not lsp.is_ready() or document.current_uri() == "" or len(g_buffer()[]) == 0:
                set_status(String("No language server"))
                return
            let buf = g_buffer()[][0]
            let line = buf.line_of_offset(g_caret()[])
            let col = byte_to_utf16(g_caret()[]) - byte_to_utf16(
                buf.line_start(line)
            )
            # The server answers the document it was last told about, so an edit
            # still sitting in the debounce would be answered against stale text.
            if g_revision()[] != document.sent_revision():
                lsp.did_change(
                    document.current_uri(), g_revision()[], buf.to_string()
                )
                document.set_sent_revision(g_revision()[])
            _ = lsp.request_completion(document.current_uri(), line, col)
            g_pending_completion()[] = 1
            set_status(String("Completing…"))
        except:
            pass

    def roastZoomIn_(self, sender: ObjCObject):
        try:
            zoom_font(1.0)
        except:
            pass

    def roastZoomOut_(self, sender: ObjCObject):
        try:
            zoom_font(-1.0)
        except:
            pass

    def roastFind_(self, sender: ObjCObject):
        """Put the cursor in the toolbar's search field."""
        try:
            with autoreleasepool():
                if g_findfield()[] == 0:
                    return
                _ = msg_send[Bool, "NSWindow", "makeFirstResponder:"](
                    ObjCObject(g_window()[]), ObjCObject(g_findfield()[]).ptr()
                )
        except:
            pass

    def roastFindChanged_(self, sender: ObjCObject):
        """The field's text changed, or Enter was pressed in it."""
        try:
            with autoreleasepool():
                let field = ObjCObject(g_findfield()[])
                let text = msg_send[ObjCObject, "NSTextField", "stringValue"](field)
                set_query(ns_to_string(text))
                print("roast: find", repr(query()), "matches", match_count())
                _ = find_next()
                report_matches()
                scroll_to_caret()
        except:
            pass

    def roastFindNext_(self, sender: ObjCObject):
        try:
            _ = find_next()
            report_matches()
            scroll_to_caret()
        except:
            pass

    def roastFindPrevious_(self, sender: ObjCObject):
        try:
            _ = find_previous()
            report_matches()
            scroll_to_caret()
        except:
            pass

    def roastHideFind_(self, sender: ObjCObject):
        """Escape: clear the search and give the editor its focus back."""
        try:
            with autoreleasepool():
                if g_findfield()[] != 0:
                    _ = msg_send[ObjCObject, "NSControl", "setStringValue:"](
                        ObjCObject(g_findfield()[]), nsstring(String("")).ptr()
                    )
                set_query(String())
                if g_grid()[] != 0:
                    _ = msg_send[Bool, "NSWindow", "makeFirstResponder:"](
                        ObjCObject(g_window()[]), ObjCObject(g_grid()[]).ptr()
                    )
                set_status(String("Ready"))
                refresh_grid()
        except:
            pass

    def timerTick_(self, timer: ObjCObject):
        g_ticks()[] += 1

        # Read whatever the server has said. This is the whole reason the client
        # reads without blocking: a language server thinking hard must not be an
        # editor that has stopped responding.
        try:
            if lsp.is_running():
                # A handshake that just completed means a server that knows
                # nothing yet -- startup, or the fresh process a project
                # change launched. Tell it what is open before asking it
                # anything.
                if (
                    lsp.is_ready()
                    and g_lsp_announced()[] != lsp.ready_serial()
                ):
                    g_lsp_announced()[] = lsp.ready_serial()
                    announce_open_documents()
                if lsp.poll() > 0:
                    # A completion reply arrives as a bump in the serial; showing
                    # the popup is the app's job, not the client's.
                    if (
                        g_pending_completion()[] != 0
                        and lsp.g_comp_serial()[] != g_comp_seen()[]
                    ):
                        g_comp_seen()[] = lsp.g_comp_serial()[]
                        g_pending_completion()[] = 0
                        if g_grid()[] != 0:
                            show_popup(ObjCObject(g_grid()[]))
                        if lsp.completion_count() == 0:
                            set_status(String("No completions"))
                        else:
                            set_status(
                                String(lsp.completion_count())
                                + String(" completions")
                            )
                    else:
                        _report_diagnostics()
                    refresh_grid()

                # Tell the server about edits once the typing pauses. Sending on
                # every keystroke would have it re-parsing text nobody has finished
                # writing.
                if g_revision()[] != document.sent_revision():
                    _show_dirty()
                    refresh_tabs()
                    g_idle_ticks()[] += 1
                    if g_idle_ticks()[] >= 3 and document.current_uri() != "":
                        if len(g_buffer()[]) > 0:
                            lsp.did_change(
                                document.current_uri(),
                                g_revision()[],
                                g_buffer()[][0].to_string(),
                            )
                        document.set_sent_revision(g_revision()[])
                        g_idle_ticks()[] = 0
                else:
                    g_idle_ticks()[] = 0
        except:
            pass

        # The compiler, on the same terms as the server: drained without blocking,
        # because a build that takes a minute must not be an editor that takes a
        # minute. pump() also reaps the process, which is what moves the serial.
        # CI, and a quick way to see the path work: fire Build or Run a few ticks
        # in, once the window is really up, with nobody at the keyboard.
        if g_ticks()[] == 3:
            let auto = getenv("ROAST_AUTOBUILD")
            if auto != "":
                try:
                    _start_build(auto == "run")
                except:
                    pass

        try:
            if build.is_running():
                if build.pump() > 0:
                    console_sync()
            if build.serial() != g_build_seen()[]:
                g_build_seen()[] = build.serial()
                _build_finished()
        except:
            pass

        let limit = g_autoclose()[]
        if limit != 0 and g_ticks()[] >= limit:
            print("roast: autoclose after", g_ticks()[], "ticks")
            with autoreleasepool():
                if g_window()[] != 0:
                    _ = msg_send[ObjCObject, "NSWindow", "close"](
                        ObjCObject(g_window()[])
                    )

    # ── The sidebar's data source and delegate ─────────────────────────────
    # Items are NSStrings holding paths, so the file system is the model and
    # there is no tree to keep in step with it. These used to be registered
    # with `add_method_unchecked` and encodings written by hand -- `@@:@q@`
    # and the like -- because the handlers returned an Int standing in for an
    # object. Returning ObjCObject says the same thing in the type system, and
    # the SDK check then agrees with the encoding rather than being told to
    # look away.

    def outlineView_numberOfChildrenOfItem_(
        self, view: ObjCObject, item: ObjCObject
    ) -> Int:
        return outline_children_count(item)

    def outlineView_isItemExpandable_(
        self, view: ObjCObject, item: ObjCObject
    ) -> Bool:
        return outline_expandable(item)

    def outlineView_child_ofItem_(
        self, view: ObjCObject, index: Int, item: ObjCObject
    ) -> ObjCObject:
        return outline_child_at(index, item)

    def outlineView_objectValueForTableColumn_byItem_(
        self, view: ObjCObject, column: ObjCObject, item: ObjCObject
    ) -> ObjCObject:
        return outline_display_value(item)

    # ── Toolbar delegate ───────────────────────────────────────────────────

    def toolbarAllowedItemIdentifiers_(self, tb: ObjCObject) -> ObjCObject:
        return toolbar_ids_object()

    def toolbarDefaultItemIdentifiers_(self, tb: ObjCObject) -> ObjCObject:
        return toolbar_ids_object()

    def toolbar_itemForItemIdentifier_willBeInsertedIntoToolbar_(
        self, toolbar: ObjCObject, ident: ObjCObject, inserted: Bool
    ) -> ObjCObject:
        """Build one toolbar item on demand, by identifier."""
        try:
            with autoreleasepool():
                let key = ident
                let name = String(msg_send[Int, "NSString", "length"](key))
                _ = name  # length forces a real NSString; the compare is below

                let NSToolbarItem = ObjCClass.lookup["NSToolbarItem"]()
                var item = msg_send[
                    ObjCObject, "NSToolbarItem", "alloc", is_class=True
                ](NSToolbarItem.as_object())
                item = msg_send[
                    ObjCObject, "NSToolbarItem", "initWithItemIdentifier:"
                ](item, ident)

                # Search is a view item, not a button: it carries an NSSearchField.
                if msg_send[Bool, "NSString", "isEqualToString:"](
                    key, nsstring(String(TB_FIND)).ptr()
                ):
                    let NSSearchField = ObjCClass.lookup["NSSearchField"]()
                    var field = msg_send[
                        ObjCObject, "NSSearchField", "alloc", is_class=True
                    ](NSSearchField.as_object())
                    field = msg_send[ObjCObject, "NSView", "initWithFrame:"](
                        field, rect(0.0, 0.0, 240.0, 24.0)
                    )
                    _ = msg_send[
                        ObjCObject, "NSSearchField", "setPlaceholderString:"
                    ](field, nsstring(String("Find")).ptr())
                    let owner = ObjCObject(g_actions()[])
                    _ = msg_send[ObjCObject, "NSControl", "setTarget:"](
                        field, owner.ptr()
                    )
                    _ = msg_send[ObjCObject, "NSControl", "setAction:"](
                        field, sel["roastFindChanged:"]().ptr()
                    )
                    # Search as you type: NSSearchField sends its action on every
                    # edit when told to, which a plain NSTextField does not.
                    _ = msg_send[ObjCObject, "NSSearchField", "setSendsWholeSearchString:"](
                        field, False
                    )
                    _ = msg_send[ObjCObject, "NSSearchField", "setSendsSearchStringImmediately:"](
                        field, True
                    )
                    _ = msg_send[ObjCObject, "NSToolbarItem", "setView:"](
                        item, field.ptr()
                    )
                    _ = msg_send[ObjCObject, "NSToolbarItem", "setLabel:"](
                        item, nsstring(String("Find")).ptr()
                    )
                    g_findfield()[] = field.addr()
                    return item

                # Which item was asked for? Compare against each identifier.
                # Declared, not initialised: the else returns, so every path
                # that continues assigns all three.
                var title: String
                var symbol: String
                var action: SEL
                if msg_send[Bool, "NSString", "isEqualToString:"](
                    key, nsstring(String(TB_BUILD)).ptr()
                ):
                    title = String("Build")
                    symbol = String("hammer")
                    action = sel["roastBuild:"]()
                elif msg_send[Bool, "NSString", "isEqualToString:"](
                    key, nsstring(String(TB_RUN)).ptr()
                ):
                    title = String("Run")
                    symbol = String("play.fill")
                    action = sel["roastRun:"]()
                elif msg_send[Bool, "NSString", "isEqualToString:"](
                    key, nsstring(String(TB_STOP)).ptr()
                ):
                    title = String("Stop")
                    symbol = String("stop.fill")
                    action = sel["roastStop:"]()
                else:
                    return ObjCObject(0)

                _ = msg_send[ObjCObject, "NSToolbarItem", "setLabel:"](
                    item, nsstring(title).ptr()
                )
                # An SF Symbol, or the item renders as an empty bordered circle.
                # The accessibility description doubles as the tooltip source, so
                # the title serves for both rather than passing nil.
                let NSImage = ObjCClass.lookup["NSImage"]()
                let image = msg_send[
                    ObjCObject,
                    "NSImage",
                    "imageWithSystemSymbolName:accessibilityDescription:",
                    is_class=True,
                ](
                    NSImage.as_object(),
                    nsstring(symbol).ptr(),
                    nsstring(title).ptr(),
                )
                if image.addr() != 0:
                    _ = msg_send[ObjCObject, "NSToolbarItem", "setImage:"](
                        item, image.ptr()
                    )
                _ = msg_send[ObjCObject, "NSToolbarItem", "setToolTip:"](
                    item, nsstring(title).ptr()
                )
                _ = msg_send[ObjCObject, "NSToolbarItem", "setTarget:"](
                    item, ObjCObject(g_actions()[]).ptr()
                )
                _ = msg_send[ObjCObject, "NSToolbarItem", "setAction:"](
                    item, action.ptr()
                )
                return item
        except:
            return ObjCObject(0)


def announce_open_documents():
    """Send didOpen for every open tab.

    load_file announces a file when the server is ready at the time -- which
    it is not at startup (the handshake takes a poll cycle), and not for any
    tab that was open when a project change swapped in a fresh server process.
    Those documents were silently unknown: no diagnostics until an edit, and
    then a didChange for a document the server was never told about, which the
    protocol does not define. This runs when the handshake completes, however
    many times that happens.
    """
    var i = 0
    var told = 0
    while i < document.count():
        let uri = document.uri_at(i)
        if uri != "":
            lsp.did_open(uri, document.text_at(i))
            document.mark_announced(i)
            told += 1
        i += 1
    lsp.set_shown_uri(document.current_uri())
    print("roast: announced", told, "documents to the server")


def zoom_font(delta: Float64):
    """⌘+ and ⌘−. Every metric downstream is arithmetic on two numbers, so a
    zoom is: new font, resize the document to the new line height, redraw."""
    set_font_size(font_size() + delta)
    if g_grid()[] != 0:
        with autoreleasepool():
            let grid = ObjCObject(g_grid()[])
            let frame = msg_send[CGRect, "NSView", "frame"](grid)
            _ = msg_send[ObjCObject, "NSView", "setFrameSize:"](
                grid, document_size(frame.size.width)
            )
            _ = msg_send[ObjCObject, "NSView", "setNeedsDisplay:"](grid, True)
    scroll_to_caret()
    var shown = String(Int(font_size()))
    set_status(String("Type: ") + shown + String(" pt"))


def refresh_grid():
    """Redraw the editor and scroll the selection into view."""
    if g_grid()[] == 0:
        return
    with autoreleasepool():
        let grid = ObjCObject(g_grid()[])
        _ = msg_send[ObjCObject, "NSView", "setNeedsDisplay:"](grid, True)


def scroll_to_caret():
    """Keep the match on screen. A find that jumps somewhere invisible has not
    really found anything."""
    if g_grid()[] == 0:
        return
    with autoreleasepool():
        let grid = ObjCObject(g_grid()[])
        let pos = caret_position(g_caret()[])
        let lh = line_height()
        _ = msg_send[ObjCObject, "NSView", "scrollRectToVisible:"](
            grid, rect(pos.x - 40.0, pos.y - lh * 2.0, 200.0, lh * 5.0)
        )
        _ = msg_send[ObjCObject, "NSView", "setNeedsDisplay:"](grid, True)


def _report_diagnostics():
    """Say what the server found, unless a search is showing its own count."""
    if query().byte_length() > 0:
        return
    let n = lsp.visible_diagnostic_count()
    let first = lsp.first_visible_diagnostic()
    if n == 0 or first < 0:
        set_status(String("No issues"))
        return
    # The first diagnostic in full: a count alone tells you there is a problem
    # without telling you what it is.
    set_status(
        String(n)
        + String(" issue" if n == 1 else " issues")
        + String("  ·  line ")
        + String(lsp.g_diag_line()[][first] + 1)
        + String(": ")
        + lsp.g_diag_msg()[][first]
    )


def report_matches():
    let n = match_count()
    if query().byte_length() == 0:
        set_status(String("Ready"))
    elif n == 0:
        set_status(String("no matches for ") + repr(query()))
    else:
        set_status(String(n) + String(" matches for ") + repr(query()))


def load_file(path: String) -> Bool:
    """Read a file into the buffer and tell the server about it."""
    try:
        var text: String
        with open(path, "r") as f:
            text = f.read()
        let uri = String("file://") + path
        # An already-open file selects its tab rather than opening twice, and
        # the rope arrives with the document rather than being poked into a
        # global that some other tab also thinks it owns.
        _ = document.open_document(uri, Rope(text^))
        set_caret(0)
        document.set_sent_revision(g_revision()[])
        mark_clean()
        refresh_tabs()
        lsp.set_shown_uri(uri)
        # The strip scrolls now, so a tab opened past its right edge would be
        # current and invisible at the same time.
        reveal_tab(document.current_index())
        if lsp.is_ready():
            lsp.did_open(uri, g_buffer_text())
        if g_grid()[] != 0:
            let grid = ObjCObject(g_grid()[])
            let frame = msg_send[CGRect, "NSView", "frame"](grid)
            _ = msg_send[ObjCObject, "NSView", "setFrameSize:"](
                grid, document_size(frame.size.width)
            )
            _ = msg_send[ObjCObject, "NSView", "setNeedsDisplay:"](grid, True)
        if g_window()[] != 0:
            _ = msg_send[ObjCObject, "NSWindow", "setTitle:"](
                ObjCObject(g_window()[]), nsstring(_basename(path)).ptr()
            )
        set_status(path + String("  ·  ") + String(g_buffer_lines()) + String(" lines"))
        return True
    except:
        set_status(String("could not open ") + path)
        return False


# ── Tab bar ─────────────────────────────────────────────────────────────────
# Tabs inside the window rather than macOS window tabs. Every editor does it
# this way, and it suits the architecture: one grid view drawing whichever
# document is current, so switching a tab is an index and a redraw.
def tab_width(total: Float64) -> Float64:
    """How wide one tab is.

    Tabs shrink to share the strip until they reach `TAB_MIN`, and then stop.
    Past that point they overflow and the strip scrolls, which is the whole
    reason `TAB_MIN` is a floor rather than a suggestion: a tab narrower than
    its filename is not a tab, it is a smear.
    """
    let n = max(1, document.count())
    return max(TAB_MIN, min(TAB_MAX, total / Float64(n)))


def tabs_span(total: Float64) -> Float64:
    """The width every tab needs together."""
    return Float64(document.count()) * tab_width(total)


def tab_overflows(total: Float64) -> Bool:
    return tabs_span(total) > total


def max_tab_scroll(total: Float64) -> Float64:
    return max(0.0, tabs_span(total) - total)


def tab_scroll(total: Float64) -> Float64:
    """The offset, clamped. Clamping on read rather than on write means a
    window resize cannot leave the strip scrolled past its own end."""
    let want = Float64(g_tab_scroll()[])
    return max(0.0, min(max_tab_scroll(total), want))


def set_tab_scroll(total: Float64, to: Float64):
    g_tab_scroll()[] = Int(max(0.0, min(max_tab_scroll(total), to)))


def reveal_tab(index: Int):
    """Scroll the strip so a tab is fully visible, if it is not already.

    Switching tabs by keyboard is the case that matters: without this, ⌘⇧] past
    the right edge selects a document you cannot see.
    """
    if g_tabbar()[] == 0:
        return
    try:
        with autoreleasepool():
            let bounds = msg_send[CGRect, "NSView", "bounds"](
                ObjCObject(g_tabbar()[])
            )
            let total = bounds.size.width
            if not tab_overflows(total):
                g_tab_scroll()[] = 0
                return
            let w = tab_width(total)
            let left = Float64(index) * w
            let cur = tab_scroll(total)
            if left < cur + TAB_GUTTER:
                set_tab_scroll(total, left - TAB_GUTTER)
            elif left + w > cur + total - TAB_GUTTER:
                set_tab_scroll(total, left + w - total + TAB_GUTTER)
    except:
        pass


def close_box(x: Float64, w: Float64) -> CGRect:
    """Where the × sits inside a tab, and where a click on it lands."""
    return rect(x + w - TAB_CLOSE - 6.0, (TAB_H - TAB_CLOSE) * 0.5,
                TAB_CLOSE, TAB_CLOSE)


class RoastTabBar(NSView):
    """The tab strip.

    `drawRect_` has to declare the dirty rectangle now. The old
    registration passed the encoding `v@:{CGRect={CGPoint=dd}{CGSize=dd}}`
    while the function took only `(self, cmd)` -- harmless, because the
    rect arrives in registers the callee never reads, but it was a claim
    about a shape nothing checked. The SDK supplies the encoding now, and
    the signature has to match it.

    The label attributes are FIELDS -- the first `named_global`s migrated
    onto the box. They are built lazily on first draw, because that is what
    the v1 box contract offers: fields start zero (the runtime zero-fills the
    ivar), zero is the "not built yet" sentinel, and the only code that can
    write the box is a method -- `RoastTabBar()` returns a copy, so seeding
    from `main` would write the copy and draw with nothing.
    """

    var _attrs: Int  # label attributes, full ink: a retained NSDictionary
    var _dim: Int  # the same, secondaryLabelColor, for inactive tabs

    def _ensure_attrs(mut self):
        """Build the two attribute dictionaries, once per instance."""
        if self._attrs != 0:
            return
        let NSMutableDictionary = ObjCClass.lookup["NSMutableDictionary"]()
        var ta = msg_send[
            ObjCObject, "NSMutableDictionary", "dictionary", is_class=True
        ](NSMutableDictionary.as_object())
        _ = msg_send[ObjCObject, "NSMutableDictionary", "setObject:forKey:"](
            ta, msg_send[
                ObjCObject, "NSFont", "systemFontOfSize:", is_class=True
            ](ObjCClass.lookup["NSFont"]().as_object(), Float64(12.0)).ptr(),
            extern_object["NSFontAttributeName"]().ptr(),
        )
        _ = external_call["objc_retain", P](ta.ptr())
        self._attrs = ta.addr()

        var td = msg_send[
            ObjCObject, "NSMutableDictionary", "dictionaryWithDictionary:",
            is_class=True,
        ](NSMutableDictionary.as_object(), ta.ptr())
        _ = msg_send[ObjCObject, "NSMutableDictionary", "setObject:forKey:"](
            td, msg_send[
                ObjCObject, "NSColor", "secondaryLabelColor", is_class=True
            ](ObjCClass.lookup["NSColor"]().as_object()).ptr(),
            extern_object["NSForegroundColorAttributeName"]().ptr(),
        )
        _ = external_call["objc_retain", P](td.ptr())
        self._dim = td.addr()
        # One line, once per instance, so the smoke test can assert the box
        # actually carried the state -- drawRect_'s try would otherwise
        # swallow a failure here into tabs quietly drawn with defaults.
        print("roast: tab attributes built in the box")

    def drawRect_(mut self, dirty: CGRect):
        try:
            self._ensure_attrs()
            with autoreleasepool():
                let view = ObjCObject(self.__objc_id)
                let bounds = msg_send[CGRect, "NSView", "bounds"](view)
                let NSColorT = ObjCClass.lookup["NSColor"]()

                # The bar, a shade back from the editor so the active tab can be
                # the one that matches it.
                let back = msg_send[
                    ObjCObject, "NSColor", "windowBackgroundColor", is_class=True
                ](NSColorT.as_object())
                _ = msg_send[ObjCObject, "NSColor", "setFill"](back)
                _ = external_call["NSRectFill", NoneType](bounds)

                let total = bounds.size.width
                let w = tab_width(total)
                let off = tab_scroll(total)
                let active = document.current_index()
                let overflow = tab_overflows(total)
                var i = 0
                while i < document.count():
                    let x = Float64(i) * w - off
                    if x + w < 0.0:
                        i += 1
                        continue
                    if x > total:
                        break
                    if i == active:
                        let front = msg_send[
                            ObjCObject, "NSColor", "textBackgroundColor",
                            is_class=True,
                        ](NSColorT.as_object())
                        _ = msg_send[ObjCObject, "NSColor", "setFill"](front)
                        _ = external_call["NSRectFill", NoneType](
                            rect(x, 0.0, w, TAB_H)
                        )
                    # A separator, so tabs read as tabs and not as a run of words.
                    let line = msg_send[
                        ObjCObject, "NSColor", "separatorColor", is_class=True
                    ](NSColorT.as_object())
                    _ = msg_send[ObjCObject, "NSColor", "setFill"](line)
                    _ = external_call["NSRectFill", NoneType](
                        rect(x + w - 1.0, 4.0, 1.0, TAB_H - 8.0)
                    )

                    # The label is clipped short of the close box rather than
                    # drawn under it: a filename running through the × reads as
                    # a rendering fault, and truncating is what every editor
                    # does here.
                    # Roughly seven points a character at the tab font. A
                    # measured width would be exact, but it costs an
                    # attributed-string measurement per tab per redraw, and
                    # this only decides where to put an ellipsis.
                    let room = w - TAB_CLOSE - 20.0
                    var label = document.name_at(i)
                    var glyphs = 0
                    for _ in label.codepoints():
                        glyphs += 1
                    if Float64(glyphs) * 7.0 > room:
                        let keep = max(1, Int(room / 7.0) - 1)
                        label = String(label[codepoint=:keep]) + String("…")
                    _ = msg_send[
                        ObjCObject, "NSString", "drawAtPoint:withAttributes:"
                    ](
                        nsstring(label),
                        CGPoint(x + 10.0, 6.0),
                        ObjCObject(
                            self._attrs if i == active else self._dim
                        ).ptr(),
                    )

                    # The close box. A dirty document shows a dot instead, in
                    # the same place -- which is what the eye is already
                    # looking at, and it becomes an × on hover in editors that
                    # track the mouse. This one swaps on click instead.
                    let mark = String("•") if document.dirty_at(i) else String(
                        "\u00d7"
                    )
                    let box = close_box(x, w)
                    _ = msg_send[
                        ObjCObject, "NSString", "drawAtPoint:withAttributes:"
                    ](
                        nsstring(mark),
                        CGPoint(box.origin.x + 4.0, 6.0),
                        ObjCObject(
                            self._attrs if i == active else self._dim
                        ).ptr(),
                    )
                    i += 1

                # Overflow arrows. Faint, and only on the side that has more
                # to show -- an arrow pointing at nothing is worse than no
                # arrow, because it invites a click that does not move.
                if overflow:
                    let bar = msg_send[
                        ObjCObject, "NSColor", "windowBackgroundColor",
                        is_class=True,
                    ](NSColorT.as_object())
                    if off > 0.5:
                        _ = msg_send[ObjCObject, "NSColor", "setFill"](bar)
                        _ = external_call["NSRectFill", NoneType](
                            rect(0.0, 0.0, TAB_GUTTER, TAB_H)
                        )
                        _ = msg_send[
                            ObjCObject, "NSString",
                            "drawAtPoint:withAttributes:",
                        ](
                            nsstring(String("\u2039")),
                            CGPoint(3.0, 5.0),
                            ObjCObject(self._dim).ptr(),
                        )
                    if off < max_tab_scroll(total) - 0.5:
                        _ = msg_send[ObjCObject, "NSColor", "setFill"](bar)
                        _ = external_call["NSRectFill", NoneType](
                            rect(total - TAB_GUTTER, 0.0, TAB_GUTTER, TAB_H)
                        )
                        _ = msg_send[
                            ObjCObject, "NSString",
                            "drawAtPoint:withAttributes:",
                        ](
                            nsstring(String("\u203a")),
                            CGPoint(total - TAB_GUTTER + 3.0, 5.0),
                            ObjCObject(self._dim).ptr(),
                        )
        except:
            pass

    def isFlipped(self) -> Bool:
        return True

    def mouseDown_(self, event: ObjCObject):
        """Click a tab to show it, or its × to close it."""
        try:
            with autoreleasepool():
                let view = ObjCObject(self.__objc_id)
                let win_pt = msg_send[CGPoint, "NSEvent", "locationInWindow"](
                    event
                )
                let local = msg_send[CGPoint, "NSView", "convertPoint:fromView:"](
                    view, win_pt, ObjCObject(0).ptr()
                )
                let bounds = msg_send[CGRect, "NSView", "bounds"](view)
                let total = bounds.size.width
                let w = tab_width(total)
                let off = tab_scroll(total)

                # The arrows first: they sit on top of whatever tab is under
                # them, so a hit there is a scroll and not a selection.
                if tab_overflows(total):
                    if local.x < TAB_GUTTER and off > 0.5:
                        set_tab_scroll(total, off - w)
                        refresh_tabs()
                        return
                    if (
                        local.x > total - TAB_GUTTER
                        and off < max_tab_scroll(total) - 0.5
                    ):
                        set_tab_scroll(total, off + w)
                        refresh_tabs()
                        return

                let index = Int((local.x + off) / w)
                if index < 0 or index >= document.count():
                    return
                let x = Float64(index) * w - off
                let box = close_box(x, w)
                if (
                    local.x >= box.origin.x
                    and local.x <= box.origin.x + box.size.width
                ):
                    close_tab_at(index)
                    return
                if switch_document(index):
                    after_switch()
        except:
            pass

    def scrollWheel_(self, event: ObjCObject):
        """Two-finger swipe across the strip.

        Both axes are read: a trackpad swiped sideways reports X, a mouse
        wheel reports Y, and a tab strip that only answered one of them would
        feel broken on whichever hardware the user has.
        """
        try:
            with autoreleasepool():
                let view = ObjCObject(self.__objc_id)
                let bounds = msg_send[CGRect, "NSView", "bounds"](view)
                let total = bounds.size.width
                if not tab_overflows(total):
                    return
                let dx = msg_send[Float64, "NSEvent", "scrollingDeltaX"](event)
                let dy = msg_send[Float64, "NSEvent", "scrollingDeltaY"](event)
                let delta = dx if dx != 0.0 else dy
                if delta == 0.0:
                    return
                set_tab_scroll(total, tab_scroll(total) - delta)
                refresh_tabs()
        except:
            pass


def ask_save_close(name: String) -> Int:
    """The standard question about unsaved work: 1 save, 0 close anyway,
    -1 cancel. Buttons in Cocoa's own order, so the dialog reads like every
    other editor's."""
    with autoreleasepool():
        let NSAlert = ObjCClass.lookup["NSAlert"]()
        var alert = msg_send[ObjCObject, "NSAlert", "alloc", is_class=True](
            NSAlert.as_object()
        )
        alert = msg_send[ObjCObject, "NSObject", "init"](alert)
        _ = msg_send[ObjCObject, "NSAlert", "setMessageText:"](
            alert,
            nsstring(
                String("Do you want to save the changes made to ")
                + name
                + String("?")
            ).ptr(),
        )
        _ = msg_send[ObjCObject, "NSAlert", "setInformativeText:"](
            alert,
            nsstring(
                String("Your changes will be lost if you don't save them.")
            ).ptr(),
        )
        _ = msg_send[ObjCObject, "NSAlert", "addButtonWithTitle:"](
            alert, nsstring(String("Save")).ptr()
        )
        _ = msg_send[ObjCObject, "NSAlert", "addButtonWithTitle:"](
            alert, nsstring(String("Cancel")).ptr()
        )
        _ = msg_send[ObjCObject, "NSAlert", "addButtonWithTitle:"](
            alert, nsstring(String("Don't Save")).ptr()
        )
        let answer = msg_send[Int, "NSAlert", "runModal"](alert)
        if answer == 1000:  # NSAlertFirstButtonReturn: Save
            return 1
        if answer == 1002:  # third button: Don't Save
            return 0
        return -1


def close_tab_at(index: Int):
    """Close one tab, asking about unsaved work rather than losing it.

    The same rule the menu command uses, in one place so the × and ⌘W cannot
    drift apart. This used to refuse a dirty close with a status line, which
    meant a buffer could never be deliberately abandoned -- the standard
    Save / Don't Save / Cancel question is what every document app asks.
    """
    if document.dirty_at(index):
        # The question is about a document; show the document it is about.
        if switch_document(index):
            after_switch()
        if g_autoclose()[] != 0:
            # Unattended: a modal alert with nobody at the keyboard is a hang.
            # The old refusal is the right behaviour when no one can answer.
            set_status(String("Unsaved — save it first (⌘S)"))
            return
        let answer = ask_save_close(document.name_at(index))
        if answer < 0:
            return
        if answer == 1 and not save_current():
            return  # the save panel was cancelled; so is the close
    if document.close_at(index):
        after_switch()
    else:
        set_status(String("Last tab stays open"))


def refresh_tabs():
    if g_tabbar()[] == 0:
        return
    with autoreleasepool():
        _ = msg_send[ObjCObject, "NSView", "setNeedsDisplay:"](
            ObjCObject(g_tabbar()[]), True
        )


def flush_pending_edit():
    """Send the buffer before leaving it.

    Edits are debounced -- three idle ticks before a didChange goes out -- so a
    tab edited and left quickly would strand its text here. The server would go
    on reporting diagnostics for a version of the file that no longer exists in
    the editor or on disk, which is exactly the case that looks like the tool
    lying to you.
    """
    try:
        if not lsp.is_ready():
            return
        if g_revision()[] == document.sent_revision():
            return
        if document.current_uri() == "" or len(g_buffer()[]) == 0:
            return
        lsp.did_change(
            document.current_uri(), g_revision()[], g_buffer()[][0].to_string()
        )
        document.set_sent_revision(g_revision()[])
    except:
        pass


def switch_document(index: Int) -> Bool:
    """Change tabs, flushing the outgoing document first.

    Every tab change goes through here rather than calling
    `document.switch_to` directly, so the flush cannot be forgotten at one of
    the nine places a tab can change.
    """
    if index == document.current_index():
        return False
    flush_pending_edit()
    return document.switch_to(index)


def after_switch():
    """Everything that has to follow the current document changing."""
    # The server holds diagnostics for every open tab; tell it which one is
    # being looked at so the right set is drawn.
    lsp.set_shown_uri(document.current_uri())
    reveal_tab(document.current_index())
    refresh_tabs()
    _show_dirty()
    if g_window()[] != 0:
        with autoreleasepool():
            _ = msg_send[ObjCObject, "NSWindow", "setTitle:"](
                ObjCObject(g_window()[]),
                nsstring(document.name_at(document.current_index())).ptr(),
            )
    if g_grid()[] != 0:
        with autoreleasepool():
            let grid = ObjCObject(g_grid()[])
            let frame = msg_send[CGRect, "NSView", "frame"](grid)
            _ = msg_send[ObjCObject, "NSView", "setFrameSize:"](
                grid, document_size(frame.size.width)
            )
            _ = msg_send[ObjCObject, "NSView", "setNeedsDisplay:"](grid, True)
    # The server is told about whichever document is showing -- but only if
    # it is behind. This used to resend the full text on every switch, which
    # on a large file made changing tabs cost a copy of the buffer and the
    # server a re-parse of text it already had.
    try:
        if (
            lsp.is_ready()
            and document.current_uri() != ""
            and g_revision()[] != document.sent_revision()
        ):
            lsp.did_change(
                document.current_uri(), g_revision()[], g_buffer_text()
            )
            document.set_sent_revision(g_revision()[])
    except:
        pass
    set_status(
        document.name_at(document.current_index())
        + String("  ·  ")
        + String(g_buffer_lines())
        + String(" lines")
    )




def is_dirty() -> Bool:
    return document.dirty_at(document.current_index())


def mark_clean():
    document.mark_saved()
    _show_dirty()
    refresh_tabs()


def _show_dirty():
    """The close button's dot: AppKit's own way of saying unsaved, so it looks
    like every other document window rather than a convention of ours."""
    if g_window()[] == 0:
        return
    with autoreleasepool():
        _ = msg_send[ObjCObject, "NSWindow", "setDocumentEdited:"](
            ObjCObject(g_window()[]), is_dirty()
        )


def _basename(path: String) -> String:
    let cut = path.rfind(String("/"))
    if cut < 0:
        return path
    return String(path[byte = cut + 1 : path.byte_length()])


def project_root() -> String:
    if len(g_root()[]) == 0:
        return String()
    return g_root()[][0]


def set_project_root(var path: String):
    let slot = g_root()
    if len(slot[]) == 0:
        slot[].append(path^)
    else:
        slot[][0] = path^


def children_of(dir: String) -> ObjCObject:
    """The entries of a directory, as full paths, cached.

    The outline view asks for a child by index over and over while it draws,
    so listing the directory each time would turn scrolling the sidebar into a
    syscall storm. Hidden files and build output are left out: a project is the
    files someone wrote.
    """
    if g_tree_cache()[] == 0:
        let NSMutableDictionary = ObjCClass.lookup["NSMutableDictionary"]()
        let d = msg_send[
            ObjCObject, "NSMutableDictionary", "dictionary", is_class=True
        ](NSMutableDictionary.as_object())
        _ = external_call["objc_retain", P](d.ptr())
        g_tree_cache()[] = d.addr()
    let cache = ObjCObject(g_tree_cache()[])
    var key = dir
    let hit = msg_send[ObjCObject, "NSDictionary", "objectForKey:"](
        cache, nsstring(key).ptr()
    )
    if hit.addr() != 0:
        return hit

    let NSFileManager = ObjCClass.lookup["NSFileManager"]()
    let fm = msg_send[
        ObjCObject, "NSFileManager", "defaultManager", is_class=True
    ](NSFileManager.as_object())
    var dirpath = dir
    let names = msg_send[
        ObjCObject, "NSFileManager", "contentsOfDirectoryAtPath:error:"
    ](fm, nsstring(dirpath).ptr(), ObjCObject(0).ptr())

    let NSMutableArray = ObjCClass.lookup["NSMutableArray"]()
    var out = msg_send[
        ObjCObject, "NSMutableArray", "array", is_class=True
    ](NSMutableArray.as_object())
    if names.addr() != 0:
        let count = msg_send[Int, "NSArray", "count"](names)
        var i = 0
        while i < count:
            let nm = msg_send[ObjCObject, "NSArray", "objectAtIndex:"](
                names, i
            )
            let name = ns_to_string(nm)
            let skip = (
                name.startswith(".")
                or name == "build"
                or name == "bazel-bin"
                or name == "bazel-out"
                or name.endswith(".o")
            )
            if not skip:
                var full = dir
                full += "/"
                full += name
                _ = msg_send[ObjCObject, "NSMutableArray", "addObject:"](
                    out, nsstring(full).ptr()
                )
            i += 1
        # Alphabetical, which is what a person expects and what makes a file
        # findable twice in the same place.
        _ = msg_send[ObjCObject, "NSMutableArray", "sortUsingSelector:"](
            out, sel["compare:"]().ptr()
        )
    _ = msg_send[ObjCObject, "NSMutableDictionary", "setObject:forKey:"](
        cache, out.ptr(), nsstring(key).ptr()
    )
    return out


def is_directory(path: String) -> Bool:
    with autoreleasepool():
        let NSFileManager = ObjCClass.lookup["NSFileManager"]()
        let fm = msg_send[
            ObjCObject, "NSFileManager", "defaultManager", is_class=True
        ](NSFileManager.as_object())
        var p2 = path
        # A bool out-parameter would be better; asking the URL is simpler and
        # does not need a pointer to a stack BOOL.
        let names = msg_send[
            ObjCObject, "NSFileManager", "contentsOfDirectoryAtPath:error:"
        ](fm, nsstring(p2).ptr(), ObjCObject(0).ptr())
        return names.addr() != 0


# ── Outline view data source ────────────────────────────────────────────────
# Items are NSStrings holding full paths. Using the path as the item means
# there is no parallel model to keep in step with the tree, and no node objects
# to own -- the file system is the model.
def outline_children_count(item: ObjCObject) -> Int:
    try:
        with autoreleasepool():
            var dir = project_root()
            if not item.is_nil():
                dir = ns_to_string(item)
            if dir == "":
                return 0
            return msg_send[Int, "NSArray", "count"](children_of(dir))
    except:
        return 0


def outline_expandable(item: ObjCObject) -> Bool:
    try:
        if item.is_nil():
            return True
        with autoreleasepool():
            return is_directory(ns_to_string(item))
    except:
        return False


def outline_child_at(index: Int, item: ObjCObject) -> ObjCObject:
    """The nth entry. The string belongs to the cached array, which the cache
    dictionary retains, so it outlives this call -- and no pool here, for the
    same reason as outline_value."""
    try:
        var dir = project_root()
        if not item.is_nil():
            dir = ns_to_string(item)
        let kids = children_of(dir)
        if index < 0 or index >= msg_send[Int, "NSArray", "count"](kids):
            return ObjCObject(0)
        return msg_send[ObjCObject, "NSArray", "objectAtIndex:"](kids, index)
    except:
        return ObjCObject(0)


def outline_rows() -> Int:
    """How many rows the sidebar is showing, for the startup report. Rows, not
    children: a collapsed folder contributes one and an expanded one
    contributes its subtree, which is what someone looking at the window
    counts."""
    if g_outline()[] == 0:
        return 0
    return msg_send[Int, "NSTableView", "numberOfRows"](
        ObjCObject(g_outline()[])
    )


def outline_display_value(item: ObjCObject) -> ObjCObject:
    """What the row shows: the name, not the path.

    Deliberately not wrapped in an autorelease pool. The NSString returned here
    is autoreleased, and a pool of ours would drain it on the way out -- AppKit
    then reads freed memory, and the crash lands in
    -[NSTableView preparedCellAtColumn:row:], nowhere near the method that
    returned the object. A method that hands back an autoreleased object must
    let it autorelease into the caller's pool.
    """
    try:
        if item.is_nil():
            return ObjCObject(0)
        let path = ns_to_string(item)
        return nsstring(_basename(path))
    except:
        return ObjCObject(0)


def lsp_server_path() -> String:
    """The language server to run. An editor built by this toolchain should
    ask this toolchain's server rather than whichever one is on PATH."""
    let explicit = getenv("ROAST_LSP")
    if explicit != "":
        return explicit^
    let here = getenv("COCOAMOJO_ROOT")
    if here == "":
        return String()
    return here + String("/bin/mojo-lsp-server")


def lsp_import_path() -> String:
    let explicit = getenv("ROAST_IMPORTS")
    if explicit != "":
        return explicit^
    let here = getenv("COCOAMOJO_ROOT")
    if here == "":
        return String()
    return here + String("/lib/mojo/stdlib")


def lsp_root() -> String:
    """The workspace the server should be rooted at.

    The project, when there is one. Otherwise the folder holding the current
    document -- a server rooted at a FILE, which is what this used to pass,
    resolves imports against a workspace that does not exist.
    """
    let proj = project_root()
    if proj != "":
        return proj^
    let path = document.path_at(document.current_index())
    let cut = path.rfind("/")
    return String(path[byte=:cut]) if cut > 0 else String()


def start_lsp() -> Bool:
    """(Re)start the server rooted at the current workspace.

    Called at launch and again whenever the project changes. The open
    documents are announced when the new process finishes its handshake,
    not here -- see announce_open_documents.
    """
    let server = lsp_server_path()
    let root = lsp_root()
    if server == "" or root == "":
        return False
    if lsp.is_running() and len(g_lsp_root()[]) > 0 and g_lsp_root()[][0] == root:
        return True  # already rooted here; a restart would buy nothing
    lsp.stop()
    if not lsp.start(server, String("file://") + root, lsp_import_path()):
        return False
    lsp.set_shown_uri(document.current_uri())
    # No didOpen here: the protocol says nothing goes out before the server
    # answers initialize, and this used to fire immediately -- with uri ""
    # when the current tab was the scratch buffer. The open documents are
    # announced when the handshake completes, in announce_open_documents.
    let slot = g_lsp_root()
    if len(slot[]) == 0:
        slot[].append(root)
    else:
        slot[][0] = root
    return True


def _lsp_root_now() -> String:
    let slot = g_lsp_root()
    return slot[][0] if len(slot[]) > 0 else String()


def open_folder_files(folder: String, entry: String) -> Int:
    """Open every Mojo file directly in `folder`, leaving `entry` current.

    Top level only. A project with subdirectories would otherwise put its
    whole tree in the tab bar, and the sidebar is what a tree is for.

    `entry` is opened last so it ends up the visible tab: `open_document`
    makes what it opens current, and the file someone chose from the menu is
    the one they meant to look at.
    """
    var opened = 0
    let kids = children_of(folder)
    let n = msg_send[Int, "NSArray", "count"](kids)
    var i = 0
    while i < n:
        let full = ns_to_string(
            msg_send[ObjCObject, "NSArray", "objectAtIndex:"](kids, i)
        )
        if full != entry and full.endswith(".mojo"):
            if load_file(full):
                opened += 1
        i += 1
    if load_file(entry):
        opened += 1
    return opened


def cut_name(path: String) -> Int:
    """The byte offset of the last path component, so a status line can name
    the example rather than repeat its whole path."""
    let cut = path.rfind("/")
    return cut + 1 if cut >= 0 else 0


def open_example_project(folder: String, entry: String) -> Int:
    """Load an example the way opening a project does: what was open belonged
    to the previous project, so it is saved if dirty and then closed.

    Left additive, picking two examples in a row puts the first one's files
    beside the second one's -- and since every example has a main.mojo, the tab
    bar fills with identically named tabs from different projects and the
    sidebar looks like it never changed.

    The rule is the project, not the count: a tab is kept if its file lives
    under the new folder. Picking the same example twice therefore closes
    nothing, and the untitled scratch buffer, which belongs to no project, goes
    with the rest.
    """
    # Dirty buffers first, while their tabs are still there to switch to.
    let started_at = document.current_index()
    var i = 0
    while i < document.count():
        if document.dirty_at(i):
            _ = switch_document(i)
            _ = save_current()
        i += 1
    _ = switch_document(started_at)

    # Root before files: the sidebar and the build entry point are read off it,
    # so opening files against the previous project would build the wrong
    # thing.
    open_folder(folder)
    let opened = open_folder_files(folder, entry)
    if opened == 0:
        return 0

    # Now that the new project has tabs of its own, the old ones can go --
    # backwards, so an index is never invalidated under the loop, and via
    # close_at, which keeps the last tab and has nothing left to refuse.
    #
    # Still dirty means the save above did not happen -- the panel was
    # cancelled, or the write failed. Closing it anyway would discard exactly
    # the text the person just declined to write down, so it stays open
    # alongside the new project instead.
    var prefix = folder
    prefix += "/"
    var j = document.count() - 1
    while j >= 0:
        if not document.path_at(j).startswith(prefix) and not document.dirty_at(j):
            _ = document.close_at(j)
        j -= 1
    return opened


def open_folder(var path: String):
    """Make a folder the project."""
    set_project_root(path^)
    if g_tree_cache()[] != 0:
        with autoreleasepool():
            _ = msg_send[ObjCObject, "NSMutableDictionary", "removeAllObjects"](
                ObjCObject(g_tree_cache()[])
            )
    if g_outline()[] != 0:
        with autoreleasepool():
            _ = msg_send[ObjCObject, "NSOutlineView", "reloadData"](
                ObjCObject(g_outline()[])
            )
    # A server rooted at the old project is answering about files it is no
    # longer looking at -- and an app launched with only its scratch buffer
    # has no root at all, so its startup start_lsp() did nothing. Opening a
    # folder is the moment a workspace exists: start the server if none is
    # running, re-root it if it is rooted elsewhere. Without the first arm,
    # picking an example in a fresh window meant no server for the whole
    # session -- no completions, no diagnostics, silently.
    if not lsp.is_running():
        if start_lsp():
            print("roast: language server started at", lsp_root())
    elif lsp_root() != _lsp_root_now():
        if start_lsp():
            print("roast: language server re-rooted at", project_root())
    set_status(String("Project: ") + project_root())


def save_current() -> Bool:
    """Write the current buffer back, asking where if it has no home yet.

    A `def` rather than the action itself, because Build has to save before it
    compiles and it has no selector arguments to hand on. Returns False if the
    save panel was cancelled or the write failed.
    """
    try:
        with autoreleasepool():
            var path = document.path_at(document.current_index())
            if path == "":
                let NSSavePanel = ObjCClass.lookup["NSSavePanel"]()
                let panel = msg_send[
                    ObjCObject, "NSSavePanel", "savePanel", is_class=True
                ](NSSavePanel.as_object())
                if msg_send[Int, "NSSavePanel", "runModal"](panel) != 1:
                    return False
                let url = msg_send[ObjCObject, "NSSavePanel", "URL"](panel)
                path = ns_to_string(
                    msg_send[ObjCObject, "NSURL", "path"](url)
                )
                document.set_current_uri(String("file://") + path)
                # Under its new name this is a document the server has never
                # heard of; announce it so diagnostics follow the save.
                if lsp.is_ready():
                    lsp.did_open(
                        String("file://") + path, g_buffer_text()
                    )
                    document.set_sent_revision(g_revision()[])
                    lsp.set_shown_uri(String("file://") + path)
            # The rope is written from a snapshot, so a save cannot tear even
            # if the keyboard is busy -- which is the whole point of the tree
            # being immutable.
            let text = g_buffer_text()
            with open(path, "w") as f:
                f.write(text)
            mark_clean()
            set_status(
                String("Saved ")
                + _basename(path)
                + String("  ·  ")
                + String(text.byte_length())
                + String(" bytes")
            )
            return True
    except:
        set_status(String("could not save"))
        return False


# ── Toolbar delegate ─────────────────────────────────────────────────────────
def toolbar_ids_object() -> ObjCObject:
    try:
        return toolbar_ids()
    except:
        return ObjCObject(0)


# ── Menu construction ────────────────────────────────────────────────────────
def add_item(
    menu: ObjCObject,
    title: String,
    selector: String,
    key: String,
    target: Int = 0,
) -> ObjCObject:
    """Append one item to a menu and return it.

    `target` matters more than it looks. A menu item with no target sends its
    action up the responder chain -- first responder, then the window, then the
    app delegate -- which is exactly right for `cut:`, `undo:` and `terminate:`,
    because whatever is focused should handle them. It is exactly wrong for
    Roast's own commands: RoastActions is not in the responder chain, so those
    items were disabled and did nothing at all. Anything named roast* names its
    target.
    """
    let NSMenuItem = ObjCClass.lookup["NSMenuItem"]()
    var item = msg_send[ObjCObject, "NSMenuItem", "alloc", is_class=True](
        NSMenuItem.as_object()
    )
    item = msg_send[
        ObjCObject, "NSMenuItem", "initWithTitle:action:keyEquivalent:"
    ](
        item,
        nsstring(title).ptr(),
        sel_named(selector).ptr(),
        nsstring(key).ptr(),
    )
    if target != 0:
        _ = msg_send[ObjCObject, "NSMenuItem", "setTarget:"](
            item, ObjCObject(target).ptr()
        )
    _ = msg_send[ObjCObject, "NSMenu", "addItem:"](menu, item.ptr())
    return item


def examples_root() -> String:
    """Where the shipped example projects live.

    The distribution puts them at share/examples beside the compiler, and
    `cocoamojo` exports COCOAMOJO_ROOT so a program it launched can find the
    toolchain that built it. ROAST_EXAMPLES overrides for a working tree.
    """
    let override = getenv("ROAST_EXAMPLES")
    if override != "":
        return override^
    let root = getenv("COCOAMOJO_ROOT")
    if root == "":
        return String()
    return root + String("/share/examples")


def example_projects() -> List[String]:
    """Each subdirectory holding a main.mojo, in the order the filesystem
    gives them. A folder without a main.mojo is not a project and is skipped
    rather than offered and then failing to open."""
    var out = List[String]()
    let base = examples_root()
    if base == "":
        return out^
    try:
        with autoreleasepool():
            let NSFileManager = ObjCClass.lookup["NSFileManager"]()
            let fm = msg_send[
                ObjCObject, "NSFileManager", "defaultManager", is_class=True
            ](NSFileManager.as_object())
            var dirpath = base
            let names = msg_send[
                ObjCObject, "NSFileManager", "contentsOfDirectoryAtPath:error:"
            ](fm, nsstring(dirpath).ptr(), ObjCObject(0).ptr())
            if names.addr() == 0:
                return out^
            let n = msg_send[Int, "NSArray", "count"](names)
            var i = 0
            while i < n:
                let nm = ns_to_string(
                    msg_send[ObjCObject, "NSArray", "objectAtIndex:"](names, i)
                )
                if not nm.startswith("."):
                    let main = base + String("/") + nm + String("/main.mojo")
                    if file_exists(main):
                        out.append(nm)
                i += 1
    except:
        pass
    return out^


def file_exists(path: String) -> Bool:
    try:
        with autoreleasepool():
            let NSFileManager = ObjCClass.lookup["NSFileManager"]()
            let fm = msg_send[
                ObjCObject, "NSFileManager", "defaultManager", is_class=True
            ](NSFileManager.as_object())
            var local = path
            return msg_send[Bool, "NSFileManager", "fileExistsAtPath:"](
                fm, nsstring(local).ptr()
            )
    except:
        return False


def fire_example_menu(app: ObjCObject, name: String) -> Bool:
    """Click an item in the Examples menu, with nobody at the mouse.

    ROAST_EXAMPLE reproduces what the menu action does; this drives the menu
    item itself. They are not the same path -- the item carries a file path
    and the action derives the folder from it -- and the path someone actually
    clicks is the one that shipped opening a single file.
    """
    with autoreleasepool():
        let bar = msg_send[ObjCObject, "NSApplication", "mainMenu"](app)
        if bar.addr() == 0:
            return False
        let n = msg_send[Int, "NSMenu", "numberOfItems"](bar)
        var i = 0
        while i < n:
            let holder = msg_send[ObjCObject, "NSMenu", "itemAtIndex:"](bar, i)
            let sub = msg_send[ObjCObject, "NSMenuItem", "submenu"](holder)
            if sub.addr() != 0:
                let title = ns_to_string(
                    msg_send[ObjCObject, "NSMenu", "title"](sub)
                )
                if title == String("Examples"):
                    let m = msg_send[Int, "NSMenu", "numberOfItems"](sub)
                    var j = 0
                    while j < m:
                        let it = msg_send[
                            ObjCObject, "NSMenu", "itemAtIndex:"
                        ](sub, j)
                        let t = ns_to_string(
                            msg_send[ObjCObject, "NSMenuItem", "title"](it)
                        )
                        if t == name:
                            _ = msg_send[
                                ObjCObject,
                                "NSMenu",
                                "performActionForItemAtIndex:",
                            ](sub, j)
                            return True
                        j += 1
                    return False
            i += 1
    return False


def build_examples_menu(bar: ObjCObject, actions: Int):
    """An Examples menu, built from what actually shipped.

    Listed at startup rather than hardcoded, so adding an example project to
    the distribution is enough to make it appear. If none are found -- a
    working tree with no COCOAMOJO_ROOT, say -- the menu says so rather than
    hanging there empty and looking broken.
    """
    let menu = add_submenu(bar, String("Examples"))
    let projects = example_projects()
    if len(projects) == 0:
        let none = add_item(
            menu, String("No examples found"), String(""), String("")
        )
        _ = msg_send[ObjCObject, "NSMenuItem", "setEnabled:"](none, False)
        return
    let base = examples_root()
    var i = 0
    while i < len(projects):
        let name = projects[i]
        let item = add_item(
            menu, name, String("roastOpenExample:"), String(""), actions
        )
        # The path rides on the item. A tag would only carry an index, and an
        # index into a list rebuilt at startup is a bug waiting for someone to
        # reorder the folder.
        _ = msg_send[ObjCObject, "NSMenuItem", "setRepresentedObject:"](
            item, nsstring(base + String("/") + name + String("/main.mojo")).ptr()
        )
        i += 1


def sel_named(name: String) -> ObjCObject:
    """A selector from a runtime string. `sel[...]` needs a literal."""
    var local = name
    let p = external_call["sel_registerName", P](
        local.as_c_string_slice().ptr()
    )
    return ObjCObject(Int(p))


def add_submenu(
    parent: ObjCObject, title: String
) -> ObjCObject:
    """A titled submenu hung off the main menu bar; returns the submenu."""
    let NSMenu = ObjCClass.lookup["NSMenu"]()
    let NSMenuItem = ObjCClass.lookup["NSMenuItem"]()

    var holder = msg_send[ObjCObject, "NSMenuItem", "alloc", is_class=True](
        NSMenuItem.as_object()
    )
    holder = msg_send[ObjCObject, "NSObject", "init"](holder)
    _ = msg_send[ObjCObject, "NSMenu", "addItem:"](parent, holder.ptr())

    var sub = msg_send[ObjCObject, "NSMenu", "alloc", is_class=True](
        NSMenu.as_object()
    )
    sub = msg_send[ObjCObject, "NSMenu", "initWithTitle:"](
        sub, nsstring(title).ptr()
    )
    _ = msg_send[ObjCObject, "NSMenuItem", "setSubmenu:"](holder, sub.ptr())
    return sub


def build_menu_bar(app: ObjCObject, actions: Int):
    """The menu bar. AppKit fills in Window and Services if we point it there."""
    let NSMenu = ObjCClass.lookup["NSMenu"]()
    var bar = msg_send[ObjCObject, "NSMenu", "alloc", is_class=True](
        NSMenu.as_object()
    )
    bar = msg_send[ObjCObject, "NSMenu", "initWithTitle:"](
        bar, nsstring(String("MainMenu")).ptr()
    )

    # App menu. Its title comes from the process name, not from us.
    let app_menu = add_submenu(bar, String("Roast"))
    _ = add_item(
        app_menu, String("About Roast"), String("orderFrontStandardAboutPanel:"), String("")
    )
    _ = msg_send[ObjCObject, "NSMenu", "addItem:"](
        app_menu,
        msg_send[ObjCObject, "NSMenuItem", "separatorItem", is_class=True](
            ObjCClass.lookup["NSMenuItem"]().as_object()
        ).ptr(),
    )
    _ = add_item(app_menu, String("Hide Roast"), String("hide:"), String("h"))
    _ = add_item(app_menu, String("Quit Roast"), String("terminate:"), String("q"))

    # File.
    let file = add_submenu(bar, String("File"))
    _ = add_item(file, String("New Tab"), String("roastNewTab:"), String("t"), actions)
    _ = add_item(file, String("Open…"), String("roastOpen:"), String("o"), actions)
    let folder_item = add_item(
        file, String("Open Folder…"), String("roastOpenFolder:"), String("O"),
        actions,
    )
    _ = msg_send[ObjCObject, "NSMenuItem", "setKeyEquivalentModifierMask:"](
        folder_item, Int(0x20000 | 0x100000)
    )
    _ = add_item(file, String("Save"), String("roastSave:"), String("s"), actions)
    let save_all = add_item(
        file, String("Save All"), String("roastSaveAll:"), String("S"), actions
    )
    _ = msg_send[ObjCObject, "NSMenuItem", "setKeyEquivalentModifierMask:"](
        save_all, Int(0x20000 | 0x100000)
    )
    _ = add_item(
        file, String("Close Tab"), String("roastCloseTab:"), String("w"), actions
    )

    # Edit — the standard responder-chain selectors, free of charge.
    let edit = add_submenu(bar, String("Edit"))
    _ = add_item(edit, String("Undo"), String("undo:"), String("z"))
    _ = add_item(edit, String("Redo"), String("redo:"), String("Z"))
    _ = add_item(edit, String("Cut"), String("cut:"), String("x"))
    _ = add_item(edit, String("Copy"), String("copy:"), String("c"))
    _ = add_item(edit, String("Paste"), String("paste:"), String("v"))
    _ = add_item(edit, String("Select All"), String("selectAll:"), String("a"))
    _ = msg_send[ObjCObject, "NSMenu", "addItem:"](
        edit,
        msg_send[ObjCObject, "NSMenuItem", "separatorItem", is_class=True](
            ObjCClass.lookup["NSMenuItem"]().as_object()
        ).ptr(),
    )
    # Control-space is what every editor uses for "what goes here".
    let comp = add_item(
        edit, String("Complete"), String("roastComplete:"), String(" "), actions
    )
    _ = msg_send[ObjCObject, "NSMenuItem", "setKeyEquivalentModifierMask:"](
        comp, Int(0x40000)
    )
    _ = add_item(edit, String("Find…"), String("roastFind:"), String("f"), actions)
    _ = add_item(edit, String("Find Next"), String("roastFindNext:"), String("g"), actions)
    let prev_item = add_item(
        edit,
        String("Find Previous"),
        String("roastFindPrevious:"),
        String("G"),
        actions,
    )
    # Shift is implied by the capital, but AppKit wants it said.
    _ = msg_send[ObjCObject, "NSMenuItem", "setKeyEquivalentModifierMask:"](
        prev_item, Int(0x20000 | 0x100000)
    )
    _ = add_item(edit, String("Hide Find"), String("roastHideFind:"), String("\u001b"), actions)

    # View.
    let view_menu = add_submenu(bar, String("View"))
    _ = add_item(
        view_menu, String("Zoom In"), String("roastZoomIn:"), String("="), actions
    )
    _ = add_item(
        view_menu, String("Zoom Out"), String("roastZoomOut:"), String("-"), actions
    )

    # Build.
    let build_menu = add_submenu(bar, String("Build"))
    _ = add_item(build_menu, String("Build"), String("roastBuild:"), String("b"), actions)
    _ = add_item(build_menu, String("Run"), String("roastRun:"), String("r"), actions)
    _ = add_item(build_menu, String("Stop"), String("roastStop:"), String("."), actions)
    _ = add_item(
        build_menu,
        String("Console"),
        String("roastConsole:"),
        String("0"),
        actions,
    )

    # Examples — built from what shipped, so the menu and the distribution
    # cannot disagree about which examples exist.
    build_examples_menu(bar, actions)

    # Window — handing AppKit the menu gets tab management for free.
    let window_menu = add_submenu(bar, String("Window"))
    let nxt = add_item(
        window_menu, String("Next Tab"), String("roastNextTab:"),
        String("]"), actions,
    )
    _ = msg_send[ObjCObject, "NSMenuItem", "setKeyEquivalentModifierMask:"](
        nxt, Int(0x20000 | 0x100000)
    )
    let prv = add_item(
        window_menu, String("Previous Tab"), String("roastPrevTab:"),
        String("["), actions,
    )
    _ = msg_send[ObjCObject, "NSMenuItem", "setKeyEquivalentModifierMask:"](
        prv, Int(0x20000 | 0x100000)
    )
    _ = msg_send[ObjCObject, "NSApplication", "setWindowsMenu:"](
        app, window_menu.ptr()
    )

    _ = msg_send[ObjCObject, "NSApplication", "setMainMenu:"](app, bar.ptr())


# ── Main ─────────────────────────────────────────────────────────────────────
def main() raises:
    # AppKit is not linked into a JIT process; without this NSApplication is nil
    # and the app exits silently having drawn nothing.
    if not load_framework["AppKit"]():
        print("roast: FATAL — could not load AppKit")
        return

    let env = getenv("ROAST_AUTOCLOSE_TICKS")
    if env != "":
        g_autoclose()[] = Int(env)

    with autoreleasepool():
        let NSApplication = ObjCClass.lookup["NSApplication"]()
        let app = msg_send[
            ObjCObject, "NSApplication", "sharedApplication", is_class=True
        ](NSApplication.as_object())
        # Regular -- a Dock icon and a menu bar, like any Mac app -- unless
        # this is an unattended run. A harness launch is still a real GUI
        # process on a real desktop, so as a Regular app it took the screen
        # from whoever was working: window in front, focus stolen, tabs
        # opening and closing under their hands. Indistinguishable from the
        # editor doing it by itself, and impossible to argue with while it is
        # happening. Accessory (1) gives the same window and the same
        # AppKit behaviour with no Dock icon and no claim on the front.
        let headless = g_autoclose()[] != 0
        _ = msg_send[Bool, "NSApplication", "setActivationPolicy:"](
            app, Int(1) if headless else Int(0)
        )

        # Delegate.
        # Instantiating a class registers it, so both of these exist in the
        # runtime by the time AppKit is handed them.
        let delegate = ObjCObject(RoastAppDelegate().__objc_id)
        _ = msg_send[ObjCObject, "NSApplication", "setDelegate:"](
            app, delegate.ptr()
        )

        let actions = ObjCObject(RoastActions().__objc_id)
        g_actions()[] = actions.addr()

        build_menu_bar(app, actions.addr())

        # Window. Titled|Closable|Miniaturizable|Resizable = 15.
        let NSWindow = ObjCClass.lookup["NSWindow"]()
        var win = msg_send[ObjCObject, "NSWindow", "alloc", is_class=True](
            NSWindow.as_object()
        )
        # Start at a readable fraction of the main screen instead of a frame
        # typed into the source, which is wrong on every display but one.
        let NSScreen = ObjCClass.lookup["NSScreen"]()
        let screen = msg_send[
            ObjCObject, "NSScreen", "mainScreen", is_class=True
        ](NSScreen.as_object())
        var vis = rect(0.0, 0.0, 1440.0, 900.0)
        if screen.addr() != 0:
            vis = msg_send[CGRect, "NSScreen", "visibleFrame"](screen)
        let init_w = min(1400.0, vis.size.width * 0.78)
        let init_h = min(900.0, vis.size.height * 0.84)
        win = msg_send[
            ObjCObject,
            "NSWindow",
            "initWithContentRect:styleMask:backing:defer:",
        ](
            win,
            rect(0.0, 0.0, init_w, init_h),
            Int(15),
            Int(2),
            Bool(False),
        )
        # Below which the layout stops meaning anything.
        _ = msg_send[ObjCObject, "NSWindow", "setMinSize:"](
            win, CGSize(640.0, 400.0)
        )
        _ = msg_send[ObjCObject, "NSWindow", "setTitle:"](
            win, nsstring(String("Roast")).ptr()
        )
        # Native tabbing: windows sharing an identifier tab together, and the
        # Window menu gets the tab commands automatically.
        _ = msg_send[ObjCObject, "NSWindow", "setTabbingIdentifier:"](
            win, nsstring(String("roast.editor")).ptr()
        )
        _ = msg_send[ObjCObject, "NSWindow", "setTabbingMode:"](win, Int(0))
        # Remember where the user put it. AppKit restores the saved frame
        # here if there is one, so centring only applies to a first run.
        let restored = msg_send[Bool, "NSWindow", "setFrameUsingName:"](
            win, nsstring(String("roast.main")).ptr()
        )
        if not restored:
            _ = msg_send[ObjCObject, "NSWindow", "center"](win)
        _ = msg_send[ObjCObject, "NSWindow", "setFrameAutosaveName:"](
            win, nsstring(String("roast.main")).ptr()
        )
        g_window()[] = win.addr()

        let content = msg_send[ObjCObject, "NSWindow", "contentView"](win)

        # Toolbar FIRST, because installing one changes the content view's
        # height -- by 32 points on this system, measured, not assumed. Every
        # frame below is computed from `h`, so reading it before the toolbar
        # existed laid the whole window out against a height the content view
        # never had: the tab strip sat 32 points below the top of the content
        # and the gap between it and the toolbar was the error, made visible.
        let NSToolbar = ObjCClass.lookup["NSToolbar"]()
        var toolbar = msg_send[ObjCObject, "NSToolbar", "alloc", is_class=True](
            NSToolbar.as_object()
        )
        toolbar = msg_send[ObjCObject, "NSToolbar", "initWithIdentifier:"](
            toolbar, nsstring(String("roast.toolbar")).ptr()
        )
        _ = msg_send[ObjCObject, "NSToolbar", "setDelegate:"](
            toolbar, actions.ptr()
        )
        _ = msg_send[ObjCObject, "NSWindow", "setToolbar:"](win, toolbar.ptr())

        let bounds = msg_send[CGRect, "NSView", "bounds"](content)
        let w = bounds.size.width
        let h = bounds.size.height

        # Status bar: a label pinned to the bottom, and a hairline above it.
        comptime STATUS_H = 22.0
        let NSTextField = ObjCClass.lookup["NSTextField"]()
        let status = msg_send[
            ObjCObject, "NSTextField", "labelWithString:", is_class=True
        ](NSTextField.as_object(), nsstring(String("Ready")).ptr())
        _ = msg_send[ObjCObject, "NSView", "setFrame:"](
            status, rect(10.0, 3.0, w - 20.0, STATUS_H - 6.0)
        )
        # Width-resizable, pinned to the bottom.
        _ = msg_send[ObjCObject, "NSView", "setAutoresizingMask:"](status, Int(2))
        _ = msg_send[ObjCObject, "NSView", "addSubview:"](content, status.ptr())
        g_status()[] = status.addr()

        # Split view: sidebar on the left, editor area on the right.
        let NSSplitView = ObjCClass.lookup["NSSplitView"]()
        var split = msg_send[ObjCObject, "NSSplitView", "alloc", is_class=True](
            NSSplitView.as_object()
        )
        split = msg_send[ObjCObject, "NSView", "initWithFrame:"](
            split, rect(0.0, STATUS_H, w, h - STATUS_H - TAB_H)
        )
        _ = msg_send[ObjCObject, "NSSplitView", "setVertical:"](split, True)
        # Thin divider, the source-list look.
        _ = msg_send[ObjCObject, "NSSplitView", "setDividerStyle:"](split, Int(2))
        _ = msg_send[ObjCObject, "NSView", "setAutoresizingMask:"](split, Int(18))
        _ = msg_send[ObjCObject, "NSView", "addSubview:"](content, split.ptr())

        # Sidebar: a scrolling outline view. Milestone 1 gives it a data source
        # over a real project tree; for now it is the shape, not the content.
        let NSScrollView = ObjCClass.lookup["NSScrollView"]()
        var side_scroll = msg_send[
            ObjCObject, "NSScrollView", "alloc", is_class=True
        ](NSScrollView.as_object())
        side_scroll = msg_send[ObjCObject, "NSView", "initWithFrame:"](
            side_scroll, rect(0.0, 0.0, 240.0, h - STATUS_H - TAB_H)
        )
        _ = msg_send[ObjCObject, "NSScrollView", "setHasVerticalScroller:"](
            side_scroll, True
        )
        let NSOutlineView = ObjCClass.lookup["NSOutlineView"]()
        var outline = msg_send[
            ObjCObject, "NSOutlineView", "alloc", is_class=True
        ](NSOutlineView.as_object())
        outline = msg_send[ObjCObject, "NSView", "initWithFrame:"](
            outline, rect(0.0, 0.0, 240.0, h - STATUS_H - TAB_H)
        )
        # Source-list styling: SidebarStyle = 1 on modern AppKit.
        _ = msg_send[ObjCObject, "NSTableView", "setStyle:"](outline, Int(1))
        # A column, or the view has nowhere to draw. One column, no header:
        # this is a file list, not a table.
        let NSTableColumn = ObjCClass.lookup["NSTableColumn"]()
        var column = msg_send[
            ObjCObject, "NSTableColumn", "alloc", is_class=True
        ](NSTableColumn.as_object())
        column = msg_send[
            ObjCObject, "NSTableColumn", "initWithIdentifier:"
        ](column, nsstring(String("name")).ptr())
        _ = msg_send[ObjCObject, "NSTableColumn", "setWidth:"](
            column, Float64(220.0)
        )
        # A column made in code has no data cell, and a cell-based table view
        # dereferences it on the first draw -- the crash is inside
        # -[NSTableView preparedCellAtColumn:row:], a long way from the column
        # that lacks one. The view is cell-based because the delegate does not
        # implement outlineView:viewForTableColumn:item:, which is what AppKit
        # looks for to decide.
        let NSTextFieldCell = ObjCClass.lookup["NSTextFieldCell"]()
        var cell = msg_send[
            ObjCObject, "NSTextFieldCell", "alloc", is_class=True
        ](NSTextFieldCell.as_object())
        cell = msg_send[ObjCObject, "NSTextFieldCell", "initTextCell:"](
            cell, nsstring(String("")).ptr()
        )
        _ = msg_send[ObjCObject, "NSCell", "setEditable:"](cell, False)
        _ = msg_send[ObjCObject, "NSTableColumn", "setDataCell:"](
            column, cell.ptr()
        )
        _ = msg_send[ObjCObject, "NSTableView", "addTableColumn:"](
            outline, column.ptr()
        )
        _ = msg_send[ObjCObject, "NSOutlineView", "setOutlineTableColumn:"](
            outline, column.ptr()
        )
        _ = msg_send[ObjCObject, "NSTableView", "setHeaderView:"](
            outline, ObjCObject(0).ptr()
        )
        _ = msg_send[ObjCObject, "NSOutlineView", "setDataSource:"](
            outline, actions.ptr()
        )
        _ = msg_send[ObjCObject, "NSOutlineView", "setDelegate:"](
            outline, actions.ptr()
        )
        _ = msg_send[ObjCObject, "NSTableView", "setRowHeight:"](
            outline, Float64(20.0)
        )
        g_outline()[] = outline.addr()
        _ = msg_send[ObjCObject, "NSScrollView", "setDocumentView:"](
            side_scroll, outline.ptr()
        )
        _ = msg_send[ObjCObject, "NSSplitView", "addSubview:"](
            split, side_scroll.ptr()
        )

        # Editor area: an empty scroll view where GridView lands in milestone 1.
        var edit_scroll = msg_send[
            ObjCObject, "NSScrollView", "alloc", is_class=True
        ](NSScrollView.as_object())
        edit_scroll = msg_send[ObjCObject, "NSView", "initWithFrame:"](
            edit_scroll, rect(240.0, 0.0, w - 240.0, h - STATUS_H - TAB_H)
        )
        _ = msg_send[ObjCObject, "NSScrollView", "setHasVerticalScroller:"](
            edit_scroll, True
        )
        _ = msg_send[ObjCObject, "NSScrollView", "setHasHorizontalScroller:"](
            edit_scroll, True
        )

        # The editor surface. Load something real: with no file to open yet,
        # Roast shows its own source, which is the shortest path to seeing the
        # rope, the gutter and the scrolling all work on a genuine file.
        # A folder to open on the way up, so `ROAST_PROJECT=examples/fern`
        # starts in a project rather than needing the panel every time.
        let proj = getenv("ROAST_PROJECT")
        if proj != "":
            open_folder(proj)

        var text: String
        let path = getenv("ROAST_OPEN")
        if path != "":
            try:
                with open(path, "r") as f:
                    text = f.read()
            except:
                text = String("could not read ") + path
        else:
            # An empty untitled document, which is what every other editor
            # opens with. It used to be a page of milestone notes and
            # benchmark figures -- useful to whoever was building the thing,
            # and to nobody who wants to start typing.
            text = String()
        # Through the same door as every other open, so there is exactly one
        # way a document comes into being. Setting the rope directly here is
        # what left the tab bar with nothing to draw.
        _ = document.open_document(
            String("file://") + path if path != "" else String(""),
            Rope(text^),
        )

        let grid = make_grid_view(
            rect(0.0, 0.0, w - 240.0, h - STATUS_H - TAB_H)
        )
        let doc = document_size(w - 240.0)
        _ = msg_send[ObjCObject, "NSView", "setFrameSize:"](grid, doc)
        _ = msg_send[ObjCObject, "NSScrollView", "setDocumentView:"](
            edit_scroll, grid.ptr()
        )
        # A text editor scrolls its own way: no elastic bounce past the ends.
        _ = msg_send[ObjCObject, "NSScrollView", "setVerticalScrollElasticity:"](
            edit_scroll, Int(1)
        )
        g_grid()[] = grid.addr()

        # The editor and the console share the right-hand side, stacked. A
        # nested split rather than a view that gets resized by hand: the
        # divider is then draggable, which is what anyone will try first.
        var vsplit = msg_send[
            ObjCObject, "NSSplitView", "alloc", is_class=True
        ](NSSplitView.as_object())
        vsplit = msg_send[ObjCObject, "NSView", "initWithFrame:"](
            vsplit, rect(240.0, 0.0, w - 240.0, h - STATUS_H - TAB_H)
        )
        _ = msg_send[ObjCObject, "NSSplitView", "setVertical:"](vsplit, False)
        _ = msg_send[ObjCObject, "NSSplitView", "setDividerStyle:"](
            vsplit, Int(2)
        )
        _ = msg_send[ObjCObject, "NSSplitView", "addSubview:"](
            vsplit, edit_scroll.ptr()
        )

        # The console: a plain text view, the editor's face, not editable.
        var out_scroll = msg_send[
            ObjCObject, "NSScrollView", "alloc", is_class=True
        ](NSScrollView.as_object())
        out_scroll = msg_send[ObjCObject, "NSView", "initWithFrame:"](
            out_scroll, rect(0.0, 0.0, w - 240.0, 160.0)
        )
        _ = msg_send[ObjCObject, "NSScrollView", "setHasVerticalScroller:"](
            out_scroll, True
        )
        let NSTextView = ObjCClass.lookup["NSTextView"]()
        var console = msg_send[
            ObjCObject, "NSTextView", "alloc", is_class=True
        ](NSTextView.as_object())
        console = msg_send[ObjCObject, "NSView", "initWithFrame:"](
            console, rect(0.0, 0.0, w - 240.0, 160.0)
        )
        _ = msg_send[ObjCObject, "NSTextView", "setEditable:"](console, False)
        _ = msg_send[ObjCObject, "NSTextView", "setRichText:"](console, False)
        _ = msg_send[ObjCObject, "NSTextView", "setFont:"](
            console,
            msg_send[
                ObjCObject,
                "NSFont",
                "monospacedSystemFontOfSize:weight:",
                is_class=True,
            ](
                ObjCClass.lookup["NSFont"]().as_object(),
                Float64(11.0),
                Float64(0.0),
            ).ptr(),
        )
        _ = msg_send[ObjCObject, "NSTextView", "setString:"](
            console,
            nsstring(
                String("Build ⌘B · Run ⌘R · Stop ⌘. · this pane ⌘0\n")
            ).ptr(),
        )
        _ = msg_send[ObjCObject, "NSScrollView", "setDocumentView:"](
            out_scroll, console.ptr()
        )
        _ = external_call["objc_retain", P](console.ptr())
        g_console()[] = console.addr()

        _ = msg_send[ObjCObject, "NSSplitView", "addSubview:"](
            vsplit, out_scroll.ptr()
        )
        _ = external_call["objc_retain", P](vsplit.ptr())
        g_vsplit()[] = vsplit.addr()

        _ = msg_send[ObjCObject, "NSSplitView", "addSubview:"](
            split, vsplit.ptr()
        )
        # Closed until something is built. The editor is what the window is
        # for; an empty console taking a third of it is a worse first sight.
        show_console(False)
        # Added to the window's content view, above the split, so it spans the
        # editor pane and stays put while the editor scrolls.
        # Already allocated and initialised, so the frame is set rather than
        # passed to initWithFrame:.
        var realtabs = ObjCObject(RoastTabBar().__objc_id)
        _ = msg_send[ObjCObject, "NSView", "setFrame:"](
            realtabs, rect(240.0, h - TAB_H, w - 240.0, TAB_H)
        )
        _ = msg_send[ObjCObject, "NSView", "setAutoresizingMask:"](
            realtabs, Int(2 | 8)
        )
        _ = msg_send[ObjCObject, "NSView", "addSubview:"](
            content, realtabs.ptr()
        )
        g_tabbar()[] = realtabs.addr()

        # The tab labels' attribute dictionaries live on RoastTabBar itself
        # now -- fields, built lazily on first draw. Nothing to set up here.

        # A tick, only so the autoclose path exists for CI.
        let NSTimer = ObjCClass.lookup["NSTimer"]()
        _ = msg_send[
            ObjCObject,
            "NSTimer",
            "scheduledTimerWithTimeInterval:target:selector:userInfo:repeats:",
            is_class=True,
        ](
            NSTimer.as_object(),
            Float64(0.1),
            actions.ptr(),
            sel["timerTick:"]().ptr(),
            actions.ptr(),
            Bool(True),
        )

        # The language server, from the distribution beside us. An editor
        # built by this toolchain should ask this toolchain's server rather
        # than whichever one is on PATH.
        if lsp_server_path() == "":
            print("roast: no language server (set ROAST_LSP or COCOAMOJO_ROOT)")
        elif start_lsp():
            print("roast: language server started at", lsp_root())

        # A project, if one was named. ROAST_PROJECT is a folder; use the
        # sandbox rather than the source tree, which tools/roast-sandbox.sh
        # exists to make.
        let project = getenv("ROAST_PROJECT")
        if project != "":
            open_folder(project)

        # The same thing the Examples menu does, reachable without a click.
        # This shipped opening one file of three because nothing could test
        # it; now something can.
        let example = getenv("ROAST_EXAMPLE")
        if example != "":
            # The count of files the EXAMPLE contributed, not the tab total:
            # the scratch buffer the editor starts with is still there, and
            # opening an example should not close what someone already had.
            print(
                "roast: example files:",
                open_example_project(
                    example, example + String("/main.mojo")
                ),
            )

        # The same thing again, through the menu item rather than around it.
        # Comma-separated, because picking a second example is a different
        # thing from picking a first one: the tree cache, the project root and
        # the language server all have to let go of the previous project.
        let clicked = getenv("ROAST_EXAMPLE_MENU")
        if clicked != "":
            let names = clicked.split(",")
            var k = 0
            while k < len(names):
                let name = String(names[k])
                let hit = fire_example_menu(app, name)
                print(
                    "roast: example menu:",
                    name,
                    hit,
                    "rows",
                    outline_rows(),
                    "tabs",
                    document.count(),
                )
                k += 1

        _ = msg_send[ObjCObject, "NSWindow", "makeFirstResponder:"](
            win, grid.ptr()
        )
        _ = msg_send[ObjCObject, "NSWindow", "makeKeyAndOrderFront:"](
            win, win.ptr()
        )
        if not headless:
            _ = msg_send[
                ObjCObject, "NSApplication", "activateIgnoringOtherApps:"
            ](app, True)
        var what = String("untitled")
        if path != "":
            what = path
        set_status(
            what
            + String("  ·  ")
            + String(g_buffer_lines())
            + String(" lines")
        )

        # Report what AppKit actually thinks it has, so a headless run says
        # whether the shell came up rather than leaving it to a screenshot.
        let visible = msg_send[Bool, "NSWindow", "isVisible"](win)
        let frame = msg_send[CGRect, "NSWindow", "frame"](win)
        let tb = msg_send[ObjCObject, "NSWindow", "toolbar"](win)
        let subviews = msg_send[ObjCObject, "NSView", "subviews"](split)
        let n_split = msg_send[Int, "NSArray", "count"](subviews)
        let menu = msg_send[ObjCObject, "NSApplication", "mainMenu"](app)
        let n_menus = msg_send[Int, "NSMenu", "numberOfItems"](menu)
        print("roast: window visible:", visible)
        print(
            "roast: frame:",
            frame.size.width,
            "x",
            frame.size.height,
            "at",
            frame.origin.x,
            frame.origin.y,
        )
        print("roast: toolbar:", tb.addr() != 0)
        print("roast: tabs:", document.count())
        # What the sidebar is actually showing. The outline had no reporting
        # at all, which is how "the example opened one file" survived a green
        # suite: the tab bar was checked and the file list was not.
        print("roast: project:", project_root())
        print("roast: project rows:", outline_rows())
        # The strip has to sit flush under the toolbar. Installing a toolbar
        # changes the content view's height, so laying out against the height
        # read before it existed leaves a band of window background above the
        # tabs -- visible, and easy to reintroduce. Report the distance so a
        # regression is a failed check rather than something someone notices.
        if g_tabbar()[] != 0:
            let strip = msg_send[CGRect, "NSView", "frame"](
                ObjCObject(g_tabbar()[])
            )
            let ch = msg_send[
                CGRect, "NSView", "bounds"
            ](msg_send[ObjCObject, "NSWindow", "contentView"](win)).size.height
            print("roast: tab gap:", ch - (strip.origin.y + strip.size.height))
        # The items come from the factory method on RoastActions -- a count of
        # zero means identifiers registered but the factory never produced.
        print(
            "roast: toolbar items:",
            msg_send[Int, "NSArray", "count"](
                msg_send[ObjCObject, "NSToolbar", "items"](tb)
            ),
        )
        print("roast: split panes:", n_split)
        let n_vsplit = msg_send[
            Int, "NSArray", "count"
        ](msg_send[ObjCObject, "NSView", "subviews"](ObjCObject(g_vsplit()[])))
        let vsubs = msg_send[ObjCObject, "NSView", "subviews"](
            ObjCObject(g_vsplit()[])
        )
        print(
            "roast: editor panes:",
            n_vsplit,
            "heights",
            msg_send[CGRect, "NSView", "frame"](
                msg_send[ObjCObject, "NSArray", "objectAtIndex:"](vsubs, 0)
            ).size.height,
            msg_send[CGRect, "NSView", "frame"](
                msg_send[ObjCObject, "NSArray", "objectAtIndex:"](vsubs, 1)
            ).size.height,
        )
        print("roast: entry point:", build.entry_point(
            project_root(), document.path_at(document.current_index())
        ))
        print("roast: menu bar items:", n_menus)
        let gframe = msg_send[CGRect, "NSView", "frame"](grid)
        print(
            "roast: document:",
            gframe.size.width,
            "x",
            gframe.size.height,
            "for",
            g_buffer_lines(),
            "lines",
        )

    print("roast: entering [NSApp run]")
    with autoreleasepool():
        let NSApplication2 = ObjCClass.lookup["NSApplication"]()
        let app2 = msg_send[
            ObjCObject, "NSApplication", "sharedApplication", is_class=True
        ](NSApplication2.as_object())
        _ = msg_send[ObjCObject, "NSApplication", "run"](app2)
    print("roast: exited run loop")
