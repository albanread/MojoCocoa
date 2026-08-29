# Life, through Python

Conway's Game of Life again — but this window is **pygame's**, not Cocoa's.
The grid logic is Mojo (`gridv1.mojo`); the rendering calls into Python via
`Python.import_module("pygame")`, running in the CPython this toolchain
carries. Put it beside the native `life` example and the comparison is the
demo: same program, two windowing worlds.

## First run

pygame lives in the project's own Python environment, so once:

1. Python menu → **Create Environment for Project**
2. Python menu → **Install Package…** → `pygame`

Then ⌘R. Quit the pygame window to stop.
