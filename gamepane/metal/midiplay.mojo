# General MIDI playback of an ABC tune through AVMIDIPlayer.
#
# The chip player (`play_tune`) renders a tune on three SID-style voices and
# ignores `%%MIDI program`, because a chip has no choir. This is the other
# answer to the same ABC: write it out as a Standard MIDI File and hand it to
# AVMIDIPlayer with the system's General MIDI soundbank, so program 52 IS a
# choir, 9 a glockenspiel, 80 a square lead and 91 a polysynth pad. It is
# exactly what MACVM's game pane does with `Tune fromAbc:` (MacGamePane
# audio/src/playback.rs), which is why GalixigansDeluxe's music is the
# original's music rather than a chip impression of it. The chip stays for
# the effects, and for tunes that want to be chip music.
#
# One player at a time: starting a tune stops the one before. The player is
# owned here (alloc/init is +1) and released when replaced or stopped; a
# player that has finished costs nothing to keep until then.

from std.ffi import external_call
from std.objc import (
    load_framework, Cls, Obj, ObjCObject, named_global, autoreleasepool,
)
from std.os import getenv, remove
from gamepane.abc import Tune, parse_abc, resolve_ties, write_midi

comptime g_gm_player = named_global["gamepane.gm_player", Int]
comptime g_gm_serial = named_global["gamepane.gm_serial", Int]


def stop_tune_gm():
    """Stop and release the General MIDI player, if there is one."""
    var p = g_gm_player()[]        # a copy: the slot is cleared next
    if p == 0:
        return
    g_gm_player()[] = 0
    with autoreleasepool():
        _ = Obj["AVMIDIPlayer"](p).stop()
        _ = external_call["objc_release", NoneType](ObjCObject(p).ptr())


def play_tune_gm(source: String) raises -> Bool:
    """Play an ABC tune once through the system General MIDI synth.

    The parse and the SMF write happen here, on the caller's thread; the
    player then runs on its own. False when the tune is empty, the file could
    not be written, or AVFoundation would not take it -- a game carries on
    either way, music not being a reason to stop.
    """
    var tune = Tune()
    parse_abc(source, tune)
    resolve_ties(tune)
    var serial = g_gm_serial()[] + 1
    g_gm_serial()[] = serial
    var dir = getenv("TMPDIR")
    if dir.byte_length() == 0:
        dir = String("/tmp/")
    elif not dir.endswith("/"):
        dir += "/"
    var path = dir + "gamepane-gm-" + String(serial) + ".mid"
    if not write_midi(tune, path):
        return False
    stop_tune_gm()
    if not load_framework["AVFoundation"]():
        return False
    var started = False
    with autoreleasepool():
        let url = Cls["NSURL"]().fileURLWithPath(path)
        if url.id != 0:
            let player = Obj["AVMIDIPlayer"](
                contentsOfURL=ObjCObject(url.id),
                soundBankURL=ObjCObject(0),
                error=ObjCObject(0),
            )
            if player.id != 0:
                _ = player.prepareToPlay()
                _ = player.play(ObjCObject(0))
                g_gm_player()[] = player.id
                started = True
    # Init read the file into the player (or refused it); either way it has
    # no further use.
    try:
        remove(path)
    except:
        pass
    return started
