"""The layered retro game pane (`gamepane_design.md`).

Two tiers. `gamepane.api` is platform-neutral -- it imports no `std.objc`,
no `max.gpu` and no Metal, so a game written against it is a game that can be
re-hosted. `gamepane.metal` is the one backend that touches a window, a GPU
or an audio device.
"""
