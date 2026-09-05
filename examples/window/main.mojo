# A Cocoa window, in Mojo. The button's action is a method on a `class` --
# an Objective-C class the compiler declares, registers and instantiates --
# and every call names what it means: the class in the type, the selector in
# the spelling, the mask by its SDK name. Nothing here writes a selector
# string, a type encoding, or a folklore integer.
from std.objc import (
    Cls,
    Obj,
    ObjCObject,
    load_framework,
    named_global,
    nsenum,
    nsstring,
    sel,
    autoreleasepool,
)
from std.objc.geometry import CGRect, CGPoint, CGSize

comptime clicks = named_global["example.clicks", Int]
comptime label_addr = named_global["example.label", Int]


class ExampleActions:
    """The button's target.

    `buttonClicked_` becomes the selector `buttonClicked:` -- an underscore is
    a colon -- and the compiler derives its `v@:@` encoding, because this is a
    selector we invented rather than one the SDK declares. There is no `_cmd`
    argument to write and no IMP to register: `ExampleActions()` builds the
    class in the runtime and hands back an instance.

    The body may raise; the boundary catches. That is why there is no `try`
    wrapped around a method that plainly cannot fail.
    """

    def buttonClicked_(self, sender: ObjCObject):
        clicks()[] += 1
        with autoreleasepool():
            # setStringValue: takes an object and has no second part to
            # keyword, so the String crosses by hand -- the bridging the
            # keyword surface does automatically arrives here with P4's
            # follow-up.
            _ = Obj["NSTextField"](label_addr()[]).setStringValue("clicked " + String(clicks()[]))


def main() raises:
    # AppKit is not linked into a JIT process; without this NSApplication is
    # nil and the app exits having drawn nothing.
    if not load_framework["AppKit"]():
        raise Error("could not load AppKit")

    with autoreleasepool():
        let app = Cls["NSApplication"]().sharedApplication()
        _ = app.setActivationPolicy(
            nsenum["NSApplicationActivationPolicyRegular"]()
        )

        let actions = ObjCObject(ExampleActions().__objc_id)

        # A construction: the labels name the initialiser the database
        # resolves, and the bare Strings bridge to NSString where the
        # selector takes an object.
        let win = Obj["NSWindow"](
            contentRect=CGRect(CGPoint(240.0, 240.0), CGSize(360.0, 140.0)),
            styleMask=(
                nsenum["NSWindowStyleMaskTitled"]()
                | nsenum["NSWindowStyleMaskClosable"]()
                | nsenum["NSWindowStyleMaskMiniaturizable"]()
                | nsenum["NSWindowStyleMaskResizable"]()
            ),
            backing=nsenum["NSBackingStoreBuffered"](),
            defer=False,
        )
        win.title = "Mojo"

        let content = win.contentView()
        let label = Obj["NSTextField"](labelWithString="not clicked yet")
        _ = label.setFrame(CGRect(CGPoint(20.0, 84.0), CGSize(320.0, 24.0)))
        label_addr()[] = label.id
        _ = content.addSubview(ObjCObject(label.id))

        let button = Obj["NSButton"](
            buttonWithTitle="Click me",
            target=actions,
            action=sel["buttonClicked:"]().ptr(),
        )
        _ = button.setFrame(CGRect(CGPoint(20.0, 30.0), CGSize(160.0, 32.0)))
        _ = content.addSubview(ObjCObject(button.id))

        _ = win.makeKeyAndOrderFront(ObjCObject(0))
        _ = app.activateIgnoringOtherApps(True)

    print("Close the window to quit.")
    with autoreleasepool():
        _ = Cls["NSApplication"]().sharedApplication().run()
