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


def g_buffer_lines() -> Int:
    """Lines in the open buffer, for the startup report."""
    from gridview import g_buffer

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
fn did_finish_launching(self_: P, cmd: P, note: P):
    print("roast: applicationDidFinishLaunching")


fn should_terminate_after_last_window(self_: P, cmd: P, app: P) -> Bool:
    # A single-window IDE quits with its window. Tabs live in one window, so
    # this stays true once tabbing is on.
    return True


fn will_terminate(self_: P, cmd: P, note: P):
    print("roast: applicationWillTerminate")


fn action_build(self_: P, cmd: P, sender: P):
    set_status(String("Build: not wired until milestone 3"))
    print("roast: build")


fn action_run(self_: P, cmd: P, sender: P):
    set_status(String("Run: not wired until milestone 3"))
    print("roast: run")


fn action_stop(self_: P, cmd: P, sender: P):
    set_status(String("Ready"))
    print("roast: stop")


fn action_new_tab(self_: P, cmd: P, sender: P):
    # Native tabbing: AppKit moves a new window into the existing tab group
    # when both share a tabbingIdentifier.
    print("roast: newTab")
    with autoreleasepool():
        if g_window()[] == 0:
            return
        let win = ObjCObject(g_window()[])
        _ = msg_send[ObjCObject, "NSWindow", "addTabbedWindow:ordered:"](
            win, win.ptr(), Int(1)
        )


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


def report_matches():
    let n = match_count()
    if query().byte_length() == 0:
        set_status(String("Ready"))
    elif n == 0:
        set_status(String("no matches for ") + repr(query()))
    else:
        set_status(String(n) + String(" matches for ") + repr(query()))


fn action_find(self_: P, cmd: P, sender: P):
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


fn action_find_changed(self_: P, cmd: P, sender: P):
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


fn action_find_next(self_: P, cmd: P, sender: P):
    try:
        _ = find_next()
        report_matches()
        scroll_to_caret()
    except:
        pass


fn action_find_previous(self_: P, cmd: P, sender: P):
    try:
        _ = find_previous()
        report_matches()
        scroll_to_caret()
    except:
        pass


fn action_hide_find(self_: P, cmd: P, sender: P):
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


fn timer_tick(self_: P, cmd: P, timer: P):
    g_ticks()[] += 1
    let limit = g_autoclose()[]
    if limit != 0 and g_ticks()[] >= limit:
        print("roast: autoclose after", g_ticks()[], "ticks")
        with autoreleasepool():
            if g_window()[] != 0:
                _ = msg_send[ObjCObject, "NSWindow", "close"](
                    ObjCObject(g_window()[])
                )


# ── Toolbar delegate ─────────────────────────────────────────────────────────
fn toolbar_allowed_ids(self_: P, cmd: P, toolbar: P) -> Int:
    try:
        return toolbar_ids().addr()
    except:
        return NIL


fn toolbar_default_ids(self_: P, cmd: P, toolbar: P) -> Int:
    try:
        return toolbar_ids().addr()
    except:
        return NIL


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
    _ = add_item(file, String("Save"), String("roastSave:"), String("s"), actions)
    _ = add_item(file, String("Close Tab"), String("performClose:"), String("w"))

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
    let build = add_submenu(bar, String("Build"))
    _ = add_item(build, String("Build"), String("roastBuild:"), String("b"), actions)
    _ = add_item(build, String("Run"), String("roastRun:"), String("r"), actions)
    _ = add_item(build, String("Stop"), String("roastStop:"), String("."), actions)

    # Window — handing AppKit the menu gets tab management for free.
    let window_menu = add_submenu(bar, String("Window"))
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
        var db = ObjCClassBuilder("RoastAppDelegate")
        db.add_method["applicationDidFinishLaunching:"](did_finish_launching)
        db.add_method["applicationShouldTerminateAfterLastWindowClosed:"](
            should_terminate_after_last_window
        )
        db.add_method["applicationWillTerminate:"](will_terminate)
        let delegate = new_instance(db^.register())
        _ = msg_send[ObjCObject, "NSApplication", "setDelegate:"](
            app, delegate.ptr()
        )

        # One object carries every menu and toolbar action, and doubles as the
        # toolbar's delegate. Custom selectors need encodings; the SDK ones the
        # database already knows.
        var ab = ObjCClassBuilder("RoastActions")
        ab.add_method["roastBuild:", encoding="v@:@"](action_build)
        ab.add_method["roastRun:", encoding="v@:@"](action_run)
        ab.add_method["roastStop:", encoding="v@:@"](action_stop)
        ab.add_method["roastNewTab:", encoding="v@:@"](action_new_tab)
        ab.add_method["roastFind:", encoding="v@:@"](action_find)
        ab.add_method["roastFindChanged:", encoding="v@:@"](action_find_changed)
        ab.add_method["roastFindNext:", encoding="v@:@"](action_find_next)
        ab.add_method[
            "roastFindPrevious:", encoding="v@:@"
        ](action_find_previous)
        ab.add_method["roastHideFind:", encoding="v@:@"](action_hide_find)
        ab.add_method[
            "controlTextDidChange:", encoding="v@:@"
        ](action_find_changed)
        ab.add_method["timerTick:", encoding="v@:@"](timer_tick)
        ab.add_method[
            "toolbarAllowedItemIdentifiers:", encoding="@@:@"
        ](toolbar_allowed_ids)
        ab.add_method[
            "toolbarDefaultItemIdentifiers:", encoding="@@:@"
        ](toolbar_default_ids)
        ab.add_method[
            "toolbar:itemForItemIdentifier:willBeInsertedIntoToolbar:",
            encoding="@@:@@c",
        ](toolbar_item_for_id)
        let actions = new_instance(ab^.register())
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
            split, rect(0.0, STATUS_H, w, h - STATUS_H)
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
            side_scroll, rect(0.0, 0.0, 240.0, h - STATUS_H)
        )
        _ = msg_send[ObjCObject, "NSScrollView", "setHasVerticalScroller:"](
            side_scroll, True
        )
        let NSOutlineView = ObjCClass.lookup["NSOutlineView"]()
        var outline = msg_send[
            ObjCObject, "NSOutlineView", "alloc", is_class=True
        ](NSOutlineView.as_object())
        outline = msg_send[ObjCObject, "NSView", "initWithFrame:"](
            outline, rect(0.0, 0.0, 240.0, h - STATUS_H)
        )
        # Source-list styling: SidebarStyle = 1 on modern AppKit.
        _ = msg_send[ObjCObject, "NSTableView", "setStyle:"](outline, Int(1))
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
            edit_scroll, rect(240.0, 0.0, w - 240.0, h - STATUS_H)
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
        set_rope(Rope(text^))

        let grid = make_grid_view(rect(0.0, 0.0, w - 240.0, h - STATUS_H))
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

        _ = msg_send[ObjCObject, "NSSplitView", "addSubview:"](
            split, edit_scroll.ptr()
        )

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
