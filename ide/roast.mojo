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
    ObjCClassBuilder,
    IMP1,
    IMP1Bool,
    new_instance,
    named_global,
    extern_object,
    sel,
)
from std.memory import OpaquePointer
from std.os import getenv
from std.ffi import external_call
from std.objc import ns_to_string
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
from gridview import CGPoint, CGSize, CGRect, rect


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

# The open document's URI, and the revision the server was last told about.
# Edits bump gridview's revision; the timer notices and sends one didChange
# for a burst of typing rather than one per keystroke.
comptime g_uri = named_global["roast.uri", List[String]]
comptime g_sent_revision = named_global["roast.sent.revision", Int]
comptime g_idle_ticks = named_global["roast.idle", Int]

# The project: a folder, and the outline view showing what is in it. Children
# are listed on demand and cached per directory, so opening a folder never
# walks it -- a tree with a quarter of a million files under it costs whatever
# has been expanded and nothing more.
comptime g_root = named_global["roast.root", List[String]]
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
comptime g_build_seen = named_global["roast.build.seen", Int]
# The editor's share of the height when the console is showing.
comptime EDITOR_SHARE = 0.68
comptime TAB_H = 28.0
comptime TAB_MIN = 90.0
comptime TAB_MAX = 200.0
comptime g_pending_completion = named_global["roast.completing", Int]
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
    """Show the log and keep its tail in view."""
    if g_console()[] == 0:
        return
    with autoreleasepool():
        let tv = ObjCObject(g_console()[])
        var text = build.output()
        _ = msg_send[ObjCObject, "NSTextView", "setString:"](
            tv, nsstring(text).ptr()
        )
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
            _ = document.switch_to(i)
            _ = save_current()
            saved += 1
        i += 1
    _ = document.switch_to(started_at)
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
    if document.index_of(uri) >= 0:
        if document.switch_to(document.index_of(uri)):
            after_switch()
    elif not load_file(path):
        return
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
            if document.switch_to(next):
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
            if document.switch_to(prev):
                after_switch()
        except:
            pass

    def roastCloseTab_(self, sender: ObjCObject):
        """Close the current tab, refusing to lose unsaved work silently."""
        try:
            if document.dirty_at(document.current_index()):
                set_status(String("Unsaved — save it first (⌘S)"))
                return
            if document.close_current():
                after_switch()
            else:
                set_status(String("Last tab stays open"))
        except:
            pass

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
                    _ = document.switch_to(i)
                    _ = save_current()
                    saved += 1
                i += 1
            _ = document.switch_to(started_at)
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

    def controlTextDidChange_(self, note: ObjCObject):
        self.roastFindChanged_(note)


def refresh_grid():
    """Redraw the editor and scroll the selection into view."""
    if g_grid()[] == 0:
        return
    with autoreleasepool():
        let grid = ObjCObject(g_grid()[])
        let pos = caret_position(0)
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
    let n = lsp.diagnostic_count()
    if n == 0:
        set_status(String("No issues"))
        return
    # The first diagnostic in full: a count alone tells you there is a problem
    # without telling you what it is.
    set_status(
        String(n)
        + String(" issue" if n == 1 else " issues")
        + String("  ·  line ")
        + String(lsp.g_diag_line()[][0] + 1)
        + String(": ")
        + lsp.g_diag_msg()[][0]
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
        var text = String()
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
    let n = max(1, document.count())
    return max(TAB_MIN, min(TAB_MAX, total / Float64(n)))


fn draw_tabs(self_: P, cmd: P):
    try:
        with autoreleasepool():
            let view = ObjCObject(Int(self_))
            let bounds = msg_send[CGRect, "NSView", "bounds"](view)
            let NSColorT = ObjCClass.lookup["NSColor"]()

            # The bar, a shade back from the editor so the active tab can be
            # the one that matches it.
            let back = msg_send[
                ObjCObject, "NSColor", "windowBackgroundColor", is_class=True
            ](NSColorT.as_object())
            _ = msg_send[ObjCObject, "NSColor", "setFill"](back)
            _ = external_call["NSRectFill", NoneType](bounds)

            let w = tab_width(bounds.size.width)
            let active = document.current_index()
            var i = 0
            while i < document.count():
                let x = Float64(i) * w
                if x > bounds.size.width:
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

                # An unsaved document is marked where the close box goes in
                # every other editor, which is where the eye already looks.
                var label = document.name_at(i)
                if document.dirty_at(i):
                    label = String("• ") + label
                _ = msg_send[
                    ObjCObject, "NSString", "drawAtPoint:withAttributes:"
                ](
                    nsstring(label),
                    CGPoint(x + 10.0, 6.0),
                    ObjCObject(
                        g_tab_attrs()[] if i == active else g_tab_dim()[]
                    ).ptr(),
                )
                i += 1
    except:
        pass


fn tabs_is_flipped(self_: P, cmd: P) -> Bool:
    return True


fn tabs_mouse_down(self_: P, cmd: P, event: P):
    """Click a tab to show it."""
    try:
        with autoreleasepool():
            let view = ObjCObject(Int(self_))
            let win_pt = msg_send[CGPoint, "NSEvent", "locationInWindow"](
                ObjCObject(Int(event))
            )
            let local = msg_send[CGPoint, "NSView", "convertPoint:fromView:"](
                view, win_pt, ObjCObject(0).ptr()
            )
            let bounds = msg_send[CGRect, "NSView", "bounds"](view)
            let index = Int(local.x / tab_width(bounds.size.width))
            if document.switch_to(index):
                after_switch()
    except:
        pass


def refresh_tabs():
    if g_tabbar()[] == 0:
        return
    with autoreleasepool():
        _ = msg_send[ObjCObject, "NSView", "setNeedsDisplay:"](
            ObjCObject(g_tabbar()[]), True
        )


def after_switch():
    """Everything that has to follow the current document changing."""
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
    # The server is told about whichever document is showing, so its
    # diagnostics are about the text on screen.
    try:
        if lsp.is_ready() and document.current_uri() != "":
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


comptime g_tab_attrs = named_global["roast.tab.attrs", Int]
comptime g_tab_dim = named_global["roast.tab.dim", Int]


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


fn toolbar_item_for_id(
    self_: P, cmd: P, toolbar: P, ident: P, inserted: Bool
) -> Int:
    """Build one toolbar item on demand, by identifier."""
    try:
        with autoreleasepool():
            let key = ObjCObject(Int(ident))
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
                return item.addr()

            # Which item was asked for? Compare against each identifier.
            var title = String("?")
            var symbol = String("questionmark")
            var action = sel["roastStop:"]()
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
                return NIL

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
            return item.addr()
    except:
        return NIL


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


def sel_named(name: String) -> ObjCObject:
    """A selector from a runtime string. `sel[...]` needs a literal."""
    var local = name
    let p = external_call["sel_registerName", P](
        local.as_c_string_slice().unsafe_ptr()
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
        # Regular: a Dock icon and a menu bar, like any Mac app.
        _ = msg_send[Bool, "NSApplication", "setActivationPolicy:"](app, Int(0))

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
        let bounds = msg_send[CGRect, "NSView", "bounds"](content)
        let w = bounds.size.width
        let h = bounds.size.height

        # Toolbar.
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

        # Status bar: a label pinned to the bottom, and a hairline above it.
        comptime STATUS_H = 22.0
        let NSTextField = ObjCClass.lookup["NSTextField"]()
        let NSButton = ObjCClass.lookup["NSButton"]()
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

        var text = String()
        let path = getenv("ROAST_OPEN")
        if path != "":
            try:
                with open(path, "r") as f:
                    text = f.read()
            except:
                text = String("could not read ") + path
        else:
            text = String(
                "# Roast — milestone 1\n"
                "#\n"
                "# This is a GridView: a custom NSView drawing a persistent\n"
                "# rope with Core Text. Layout is arithmetic, because the font\n"
                "# is fixed-pitch:\n"
                "#\n"
                "#     x = column * advance\n"
                "#     y = line * line_height\n"
                "#\n"
                "# so there is no layout pass to run, and only the lines the\n"
                "# scroll view is showing are drawn.\n"
                "#\n"
                "# Measured on 250,000 lines / 14 MB:\n"
                "#     build         5 ms\n"
                "#     line lookup   2.3 us\n"
                "#     keystroke     2.4 us\n"
                "#     snapshot      400 ns\n"
                "#\n"
                "# Set ROAST_OPEN=<path> to load a real file.\n"
            )
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
        var tabbuilder = ObjCClassBuilder["NSView"]("RoastTabBar")
        tabbuilder.add_method[
            "drawRect:", encoding="v@:{CGRect={CGPoint=dd}{CGSize=dd}}"
        ](draw_tabs)
        tabbuilder.add_method["isFlipped"](tabs_is_flipped)
        tabbuilder.add_method["mouseDown:", encoding="v@:@"](tabs_mouse_down)
        let tabcls = tabbuilder^.register()
        var realtabs = msg_send[
            ObjCObject, "NSObject", "alloc", is_class=True
        ](tabcls.as_object())
        realtabs = msg_send[ObjCObject, "NSView", "initWithFrame:"](
            realtabs, rect(240.0, h - TAB_H, w - 240.0, TAB_H)
        )
        _ = msg_send[ObjCObject, "NSView", "setAutoresizingMask:"](
            realtabs, Int(2 | 8)
        )
        _ = msg_send[ObjCObject, "NSView", "addSubview:"](
            content, realtabs.ptr()
        )
        g_tabbar()[] = realtabs.addr()

        # Tab labels: the editor font, active in full ink and the rest dimmed.
        let NSMutableDictionary2 = ObjCClass.lookup["NSMutableDictionary"]()
        var ta = msg_send[
            ObjCObject, "NSMutableDictionary", "dictionary", is_class=True
        ](NSMutableDictionary2.as_object())
        _ = msg_send[ObjCObject, "NSMutableDictionary", "setObject:forKey:"](
            ta, msg_send[
                ObjCObject, "NSFont", "systemFontOfSize:", is_class=True
            ](ObjCClass.lookup["NSFont"]().as_object(), Float64(12.0)).ptr(),
            extern_object["NSFontAttributeName"]().ptr(),
        )
        _ = external_call["objc_retain", P](ta.ptr())
        g_tab_attrs()[] = ta.addr()
        var td = msg_send[
            ObjCObject, "NSMutableDictionary", "dictionaryWithDictionary:",
            is_class=True,
        ](NSMutableDictionary2.as_object(), ta.ptr())
        _ = msg_send[ObjCObject, "NSMutableDictionary", "setObject:forKey:"](
            td, msg_send[
                ObjCObject, "NSColor", "secondaryLabelColor", is_class=True
            ](ObjCClass.lookup["NSColor"]().as_object()).ptr(),
            extern_object["NSForegroundColorAttributeName"]().ptr(),
        )
        _ = external_call["objc_retain", P](td.ptr())
        g_tab_dim()[] = td.addr()

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
        let here = getenv("COCOAMOJO_ROOT")
        var server = getenv("ROAST_LSP")
        var imports = getenv("ROAST_IMPORTS")
        if server == "" and here != "":
            server = here + String("/bin/mojo-lsp-server")
        if imports == "" and here != "":
            imports = here + String("/lib/mojo/stdlib")
        if server != "" and path != "":
            let uri = document.current_uri()
            if lsp.start(server, String("file://") + path, imports):
                lsp.did_open(document.current_uri(), g_buffer_text())
                print("roast: language server started")
        elif server == "":
            print("roast: no language server (set ROAST_LSP or COCOAMOJO_ROOT)")

        # A project, if one was named. ROAST_PROJECT is a folder; use the
        # sandbox rather than the source tree, which tools/roast-sandbox.sh
        # exists to make.
        let project = getenv("ROAST_PROJECT")
        if project != "":
            open_folder(project)

        _ = msg_send[ObjCObject, "NSWindow", "makeFirstResponder:"](
            win, grid.ptr()
        )
        _ = msg_send[ObjCObject, "NSWindow", "makeKeyAndOrderFront:"](
            win, win.ptr()
        )
        _ = msg_send[ObjCObject, "NSApplication", "activateIgnoringOtherApps:"](
            app, True
        )
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
