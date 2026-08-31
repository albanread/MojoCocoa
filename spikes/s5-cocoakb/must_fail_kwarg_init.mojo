# Labels that name no constructor are a compile error: the database looked
# for a class method whose selector parts are the labels verbatim and an
# initialiser 'initWith<First>:...', on the class and its superclasses, and
# found neither. The diagnostic names the class and the labels in its
# parameter-values note.
from std.objc import Obj, load_framework
from std.objc.geometry import CGRect, CGPoint, CGSize


def main() raises:
    if not load_framework["AppKit"]():
        raise Error("could not load AppKit")
    let tv = Obj["NSTextView"](grams=CGRect(CGPoint(0.0, 0.0), CGSize(1.0, 1.0)))
    print("width:", tv.frame().size.width)
