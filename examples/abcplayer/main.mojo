# An ABC player, in Mojo, with two ways to make the sound.
#
#   --chip   three chip voices: pulse, saw, noise, filter (the fun one)
#   --midi   Apple's DLS synthesiser, General MIDI (the dull, correct one)
#   --write  a Standard MIDI File, and no playing at all
#
# Both backends share one render callback and one schedule. That is the point
# of the design: the tune is turned into a list of "at sample N, do this",
# and the only thing a backend decides is what "this" means. Nothing about
# timing is duplicated, so nothing about timing can differ between them.
#
# The events are dispatched at sample offsets inside the buffer, not at buffer
# boundaries and not by waking a thread. For the MIDI backend that means
# MusicDeviceMIDIEvent is handed the offset directly; the synth applies the
# note at that sample. For the chip it means the buffer is rendered in spans
# between events. Either way a note begins on the sample it was written for.

from std.objc import (
    Obj, Cls, load_framework, ObjCClass, ObjCObject, msg_send, nsstring,
    autoreleasepool, named_global, extern_object, CGPoint, CGSize, CGRect,
)
from std.memory import Pointer, MutUntrackedOrigin, OpaquePointer
from std.ffi import external_call, c_char
from std.time import sleep
from std.sys import argv
from std.pathlib import cwd
from std.os import getenv

from chip import (
    P, chip_new, get, put, vget, vput, set_wave, set_adsr, set_filter,
    route_filter, set_volume, set_pulse_width, PLAYER_BASE, SAMPLE_RATE,
    V_ENV, WAVE_PULSE, WAVE_SAW, WAVE_TRI, FILT_LP,
)
from model import Tune, EV_NOTE
from parse import parse_abc
from repeats import expand_repeats
from schedule import Step, build_schedule, resolve_ties, ticks_per_beat
from chipplay import (
    flatten_schedule, render_scheduled, midi_to_hz,
    SC_ADDR, SC_COUNT, SC_CURSOR, SC_SAMPLE, SC_END, SC_LOOP, SC_PAUSE,
    SC_DONE, SC_VOICE_NOTE, STEP_SLOTS,
)
from schedule import SE_NOTE_ON, SE_NOTE_OFF
from midi import write_midi
from ui import (
    WIN_W, WIN_H, UI_SCOPE, UI_SCOPE_POS, UI_BACKEND, UI_SYNTH, SCOPE_LEN,
    BACKEND_CHIP, BACKEND_MIDI, CMD_QUIT, CMD_ADD, CMD_PLAY, CMD_STOP,
    MODE_LIVE, MODE_TUNE, I_SEL, I_MODE, I_LOADED, ROWS,
    g_chip, g_view, g_cmd, g_title, g_subtitle,
    g_font_title, g_font_body, g_font_small, g_paths, g_names,
    ui_init, iget, iset, apply_params, all_notes_off, set_status,
    draw_screen, click, drag, release, key_down, key_up, make_font,
)

# ── CoreAudio ───────────────────────────────────────────────────────────────

comptime kAudioUnitType_Output = 0x61756F75
comptime kAudioUnitSubType_DefaultOutput = 0x64656620
comptime kAudioUnitType_MusicDevice = 0x61756D75
comptime kAudioUnitSubType_DLSSynth = 0x646C7320
comptime kAudioUnitManufacturer_Apple = 0x6170706C
comptime kAudioFormatLinearPCM = 0x6C70636D
comptime kAudioFormatFlagIsFloat = 1
comptime kAudioFormatFlagIsPacked = 8
comptime kAudioFormatFlagIsNonInterleaved = 32
comptime kAudioUnitProperty_StreamFormat = 8
comptime kAudioUnitProperty_SetRenderCallback = 23
comptime kAudioUnitScope_Input = 1
comptime kAudioUnitScope_Output = 0

comptime AURenderCallback = fn(P, P, P, UInt32, UInt32, P, /) -> Int32


fn render(
    ref_con: P,
    action_flags: P,
    timestamp: P,
    bus: UInt32,
    frames: UInt32,
    io_data: P,
) -> Int32:
    """Fill one buffer. Runs on CoreAudio's real-time thread.

    The buffer list is two non-interleaved float channels: an AudioBuffer is
    {UInt32 channels; UInt32 bytes; void* data} and the list's array starts at
    offset 8, so channel i's data pointer sits at 16 + i*16.
    """
    let st = ref_con
    let n = Int(frames)
    let words = io_data.unsafe_bitcast[Int]()
    let left_addr = words[unsafe_offset=2]
    if left_addr == 0:
        return 0
    let nbuffers = Int(io_data.unsafe_bitcast[UInt32]()[unsafe_offset=0])
    var right_addr = 0
    if nbuffers > 1:
        right_addr = words[unsafe_offset=4]

    let left = Pointer[Float32, MutUntrackedOrigin](
        unsafe_from_address=left_addr
    )

    if get(st, PLAYER_BASE + UI_PAUSE_SLOT()) != 0:
        for i in range(n):
            left[unsafe_offset=i] = Float32(0.0)
        if right_addr != 0:
            let right = Pointer[Float32, MutUntrackedOrigin](
                unsafe_from_address=right_addr
            )
            for i in range(n):
                right[unsafe_offset=i] = Float32(0.0)
        return 0

    if get(st, PLAYER_BASE + UI_BACKEND) == BACKEND_MIDI:
        render_midi(st, action_flags, timestamp, frames, io_data, n)
    else:
        render_scheduled(st, left, n)
        if right_addr != 0:
            let right = Pointer[Float32, MutUntrackedOrigin](
                unsafe_from_address=right_addr
            )
            for i in range(n):
                right[unsafe_offset=i] = left[unsafe_offset=i]

    # A copy for the scope. Unsynchronised on purpose: a torn sweep costs one
    # frame of a wrong picture, where a lock would cost a click.
    let scope_addr = get(st, PLAYER_BASE + UI_SCOPE)
    if scope_addr != 0:
        let scope = Pointer[Float32, MutUntrackedOrigin](
            unsafe_from_address=scope_addr
        )
        var pos = get(st, PLAYER_BASE + UI_SCOPE_POS)
        for i in range(n):
            scope[unsafe_offset=pos] = left[unsafe_offset=i]
            pos += 1
            if pos >= SCOPE_LEN:
                pos = 0
        put(st, PLAYER_BASE + UI_SCOPE_POS, pos)
    return 0


@always_inline
fn UI_PAUSE_SLOT() -> Int:
    return SC_PAUSE


fn render_midi(
    st: P, action_flags: P, timestamp: P, frames: UInt32, io_data: P, n: Int
):
    """Dispatch this buffer's MIDI events, then pull the synth into it.

    `MusicDeviceMIDIEvent` takes an offset in samples from the start of the
    buffer being rendered, so an event 137 samples in is applied 137 samples
    in -- the same accuracy the chip backend gets by rendering in spans, and
    the reason this player does not need a scheduling thread at all.
    """
    let synth = P(unsafe_from_address=get(st, PLAYER_BASE + UI_SYNTH))
    let addr = get(st, PLAYER_BASE + SC_ADDR)
    if addr != 0:
        let sched = Pointer[Int, MutUntrackedOrigin](unsafe_from_address=addr)
        let count = get(st, PLAYER_BASE + SC_COUNT)
        let start = get(st, PLAYER_BASE + SC_SAMPLE)
        var cursor = get(st, PLAYER_BASE + SC_CURSOR)
        while cursor < count:
            let at = cursor * STEP_SLOTS
            let when = sched[unsafe_offset=at]
            if when >= start + n:
                break
            var offset = when - start
            if offset < 0:
                offset = 0
            let note = sched[unsafe_offset=at + 3]
            let velocity = sched[unsafe_offset=at + 4]
            # Voices beyond the sixteen MIDI channels fold onto the last one.
            var channel = sched[unsafe_offset=at + 2] - 1
            if channel < 0:
                channel = 0
            if channel >= 9:
                channel += 1
            if channel > 15:
                channel = 15
            if sched[unsafe_offset=at + 1] == SE_NOTE_ON:
                _ = external_call["MusicDeviceMIDIEvent", Int32](
                    synth, UInt32(0x90 | channel), UInt32(note),
                    UInt32(velocity), UInt32(offset),
                )
            else:
                _ = external_call["MusicDeviceMIDIEvent", Int32](
                    synth, UInt32(0x80 | channel), UInt32(note),
                    UInt32(0), UInt32(offset),
                )
            cursor += 1
        put(st, PLAYER_BASE + SC_CURSOR, cursor)
        put(st, PLAYER_BASE + SC_SAMPLE, start + n)
        if cursor >= count and start + n > get(st, PLAYER_BASE + SC_END):
            if get(st, PLAYER_BASE + SC_LOOP) != 0:
                put(st, PLAYER_BASE + SC_CURSOR, 0)
                put(st, PLAYER_BASE + SC_SAMPLE, 0)
            else:
                put(st, PLAYER_BASE + SC_DONE, 1)

    # Pull the synth straight into the buffer we were handed.
    _ = external_call["AudioUnitRender", Int32](
        synth, action_flags, timestamp, UInt32(0), frames, io_data
    )


def make_unit(atype: Int, subtype: Int) raises -> P:
    var desc = external_call["calloc", P](Int(5), Int(4))
    let d = desc.unsafe_bitcast[UInt32]()
    d[unsafe_offset=0] = UInt32(atype)
    d[unsafe_offset=1] = UInt32(subtype)
    d[unsafe_offset=2] = UInt32(kAudioUnitManufacturer_Apple)
    var nil_addr = 0
    let comp = external_call["AudioComponentFindNext", P](
        P(unsafe_from_address=nil_addr), desc
    )
    if Int(comp) == 0:
        raise Error("audio component not found")
    var slot = external_call["calloc", P](Int(1), Int(8))
    let rc = external_call["AudioComponentInstanceNew", Int32](comp, slot)
    if rc != 0:
        raise Error("could not instantiate the audio unit")
    return P(unsafe_from_address=slot.unsafe_bitcast[Int]()[unsafe_offset=0])


def stereo_format() -> P:
    """The canonical AudioUnit format: 32-bit float, two non-interleaved
    channels. Both backends speak it, so neither needs a conversion."""
    var asbd = external_call["calloc", P](Int(40), Int(1))
    asbd.unsafe_bitcast[Float64]()[unsafe_offset=0] = Float64(SAMPLE_RATE)
    let a = asbd.unsafe_bitcast[UInt32]()
    a[unsafe_offset=2] = UInt32(kAudioFormatLinearPCM)
    a[unsafe_offset=3] = UInt32(
        kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
        | kAudioFormatFlagIsNonInterleaved
    )
    a[unsafe_offset=4] = UInt32(4)     # bytes per packet
    a[unsafe_offset=5] = UInt32(1)     # frames per packet
    a[unsafe_offset=6] = UInt32(4)     # bytes per frame
    a[unsafe_offset=7] = UInt32(2)     # channels
    a[unsafe_offset=8] = UInt32(32)    # bits per channel
    return asbd


def start_audio(st: P, backend: Int) raises -> Int:
    if not load_framework["AudioToolbox"]():
        raise Error("could not load AudioToolbox")

    if backend == BACKEND_MIDI:
        let synth = make_unit(
            kAudioUnitType_MusicDevice, kAudioUnitSubType_DLSSynth
        )
        var rc = external_call["AudioUnitSetProperty", Int32](
            synth, UInt32(kAudioUnitProperty_StreamFormat),
            UInt32(kAudioUnitScope_Output), UInt32(0), stereo_format(),
            UInt32(40),
        )
        rc = external_call["AudioUnitInitialize", Int32](synth)
        if rc != 0:
            raise Error("could not initialise the DLS synth")
        put(st, PLAYER_BASE + UI_SYNTH, Int(synth))

    let unit = make_unit(kAudioUnitType_Output, kAudioUnitSubType_DefaultOutput)
    var rc = external_call["AudioUnitSetProperty", Int32](
        unit, UInt32(kAudioUnitProperty_StreamFormat),
        UInt32(kAudioUnitScope_Input), UInt32(0), stereo_format(), UInt32(40),
    )
    if rc != 0:
        raise Error("could not set the stream format")

    var cbfn: AURenderCallback = render
    let fn_addr = Pointer(to=cbfn).unsafe_bitcast[Int]()[]
    var cbs = external_call["calloc", P](Int(2), Int(8))
    cbs.unsafe_bitcast[Int]()[unsafe_offset=0] = fn_addr
    cbs.unsafe_bitcast[Int]()[unsafe_offset=1] = Int(st)
    rc = external_call["AudioUnitSetProperty", Int32](
        unit, UInt32(kAudioUnitProperty_SetRenderCallback),
        UInt32(kAudioUnitScope_Input), UInt32(0), cbs, UInt32(16),
    )
    if rc != 0:
        raise Error("could not install the render callback")

    rc = external_call["AudioUnitInitialize", Int32](unit)
    if rc != 0:
        raise Error("could not initialise the output unit")
    rc = external_call["AudioOutputUnitStart", Int32](unit)
    if rc != 0:
        raise Error("could not start the output unit")
    return Int(unit)


fn stop_audio(unit_addr: Int):
    if unit_addr == 0:
        return
    let unit = P(unsafe_from_address=unit_addr)
    _ = external_call["AudioOutputUnitStop", Int32](unit)
    _ = external_call["AudioUnitUninitialize", Int32](unit)


# ── The window ──────────────────────────────────────────────────────────────


class AbcView(NSView):
    """The whole interface. Handlers set flags or write registers; nothing
    here parses a file or touches the audio unit -- the pump does that, for
    the reason mandelbrot gives: work that can block does not belong in a
    callback AppKit is waiting on."""

    def drawRect_(self, dirty: CGRect):
        draw_screen()

    def acceptsFirstResponder(self) -> Bool:
        return True

    def keyDown_(self, event: ObjCObject):
        let repeat = msg_send[Bool, "NSEvent", "isARepeat"](event)
        let chars = msg_send[
            ObjCObject, "NSEvent", "charactersIgnoringModifiers"
        ](event)
        if chars.is_nil():
            return
        let p = msg_send[P, "NSString", "UTF8String"](chars)
        if Int(p) == 0:
            return
        let text = String(unsafe_from_utf8_ptr=p.unsafe_bitcast[c_char]())
        if len(text.as_bytes()) == 0:
            return
        key_down(Int(text.as_bytes()[0]), repeat)

    def keyUp_(self, event: ObjCObject):
        let chars = msg_send[
            ObjCObject, "NSEvent", "charactersIgnoringModifiers"
        ](event)
        if chars.is_nil():
            return
        let p = msg_send[P, "NSString", "UTF8String"](chars)
        if Int(p) == 0:
            return
        let text = String(unsafe_from_utf8_ptr=p.unsafe_bitcast[c_char]())
        if len(text.as_bytes()) == 0:
            return
        key_up(Int(text.as_bytes()[0]))

    def mouseDown_(self, event: ObjCObject):
        # The TYPED msg_send: an NSPoint comes back in two registers, and the
        # dynamic path does not describe that to the ABI -- every click would
        # land on the same wrong pixel, silently.
        let at = msg_send[CGPoint, "NSEvent", "locationInWindow"](event)
        click(at.x, at.y)

    def mouseDragged_(self, event: ObjCObject):
        let at = msg_send[CGPoint, "NSEvent", "locationInWindow"](event)
        drag(at.x, at.y)

    def mouseUp_(self, event: ObjCObject):
        release()


def write_shot(view: ObjCObject, var path: String):
    """Draw one frame into a PNG and exit.

    ABC_SHOT=<path> makes the window checkable without a person at the
    screen, which is the same reason mandelbrot has MANDEL_FRAMES: a layout
    nobody can capture is a layout nobody reviews.
    """
    with autoreleasepool():
        let r = CGRect(CGPoint(0.0, 0.0), CGSize(WIN_W, WIN_H))
        let rep = msg_send[
            ObjCObject, "NSView", "bitmapImageRepForCachingDisplayInRect:"
        ](view, r)
        if rep.is_nil():
            return
        _ = msg_send[
            ObjCObject, "NSView", "cacheDisplayInRect:toBitmapImageRep:"
        ](view, r, rep.ptr())
        let empty = Cls["NSMutableDictionary"]().dictionary()
        let data = msg_send[
            ObjCObject, "NSBitmapImageRep",
            "representationUsingType:properties:",
        ](rep, Int(4), empty.ptr())      # NSBitmapImageFileTypePNG
        if data.is_nil():
            return
        var pth = path
        _ = msg_send[Bool, "NSData", "writeToFile:atomically:"](
            data, nsstring(pth).ptr(), Bool(True)
        )


fn redraw():
    if g_view()[] != 0:
        Obj["NSView"](ObjCObject(g_view()[]).addr()).setNeedsDisplay(True)


def basename(path: String) -> String:
    let b = path.as_bytes()
    var cut = -1
    for i in range(len(b)):
        if b[i] == 47:
            cut = i
    if cut < 0:
        return path
    return String(path[byte = cut + 1 : len(b)])


def add_tune(var path: String):
    let paths = g_paths()
    for i in range(len(paths[])):
        if paths[][i] == path:
            return                      # already listed
    let name = basename(path)
    paths[].append(path^)
    g_names()[].append(name)
    if iget(I_SEL) < 0:
        iset(I_SEL, len(g_names()[]) - 1)


def scan_tunes() raises:
    """Whatever is in tunes/ beside the project, so the list is never empty."""
    let dir = String(cwd()) + String("/tunes")
    with autoreleasepool():
        let NSFileManager = ObjCClass.lookup["NSFileManager"]()
        let fm = msg_send[
            ObjCObject, "NSFileManager", "defaultManager", is_class=True
        ](NSFileManager.as_object())
        var d = dir
        let names = msg_send[
            ObjCObject, "NSFileManager", "contentsOfDirectoryAtPath:error:"
        ](fm, nsstring(d).ptr(), ObjCObject(0).ptr())
        if names.addr() == 0:
            return
        let n = msg_send[Int, "NSArray", "count"](names)
        for i in range(n):
            let item = msg_send[ObjCObject, "NSArray", "objectAtIndex:"](
                names, i
            )
            let cp = msg_send[P, "NSString", "UTF8String"](item)
            if Int(cp) == 0:
                continue
            let nm = String(unsafe_from_utf8_ptr=cp.unsafe_bitcast[c_char]())
            if nm.endswith(".abc"):
                add_tune(dir + String("/") + nm)


def open_panel():
    """NSOpenPanel, run modally from the pump."""
    with autoreleasepool():
        let cls = ObjCClass.lookup["NSOpenPanel"]()
        let panel = msg_send[
            ObjCObject, "NSOpenPanel", "openPanel", is_class=True
        ](cls.as_object())
        _ = msg_send[
            ObjCObject, "NSOpenPanel", "setAllowsMultipleSelection:"
        ](panel, Bool(True))
        _ = msg_send[ObjCObject, "NSOpenPanel", "setCanChooseFiles:"](
            panel, Bool(True)
        )
        _ = msg_send[ObjCObject, "NSOpenPanel", "setCanChooseDirectories:"](
            panel, Bool(False)
        )
        let resp = msg_send[Int, "NSOpenPanel", "runModal"](panel)
        if resp != 1:                    # NSModalResponseOK
            return
        let urls = msg_send[ObjCObject, "NSOpenPanel", "URLs"](panel)
        if urls.is_nil():
            return
        let n = msg_send[Int, "NSArray", "count"](urls)
        for i in range(n):
            let url = msg_send[ObjCObject, "NSArray", "objectAtIndex:"](urls, i)
            let ps = msg_send[ObjCObject, "NSURL", "path"](url)
            let cp = msg_send[P, "NSString", "UTF8String"](ps)
            if Int(cp) != 0:
                add_tune(String(unsafe_from_utf8_ptr=cp.unsafe_bitcast[c_char]()))


def set_header(var title: String, var sub: String):
    with autoreleasepool():
        let t = nsstring(title)
        _ = external_call["objc_retain", P](t.ptr())
        if g_title()[] != 0:
            _ = external_call["objc_release", NoneType](
                ObjCObject(g_title()[]).ptr()
            )
        g_title()[] = t.addr()
        let s = nsstring(sub)
        _ = external_call["objc_retain", P](s.ptr())
        if g_subtitle()[] != 0:
            _ = external_call["objc_release", NoneType](
                ObjCObject(g_subtitle()[]).ptr()
            )
        g_subtitle()[] = s.addr()


def go_live():
    """No schedule, so nothing drives the voices but the keyboard.

    SC_ADDR must stay non-zero -- render_scheduled fills silence when it is
    null -- and SC_END goes far away so the loop-round at the end of a tune
    never fires and gates the live notes off underneath you.
    """
    let st = P(unsafe_from_address=g_chip()[])
    put(st, PLAYER_BASE + SC_PAUSE, 1)
    all_notes_off()
    put(st, PLAYER_BASE + SC_COUNT, 0)
    put(st, PLAYER_BASE + SC_CURSOR, 0)
    put(st, PLAYER_BASE + SC_SAMPLE, 0)
    put(st, PLAYER_BASE + SC_LOOP, 0)
    put(st, PLAYER_BASE + SC_END, 1 << 60)
    for v in range(3):
        put(st, PLAYER_BASE + SC_VOICE_NOTE + v, -1)
    iset(I_MODE, MODE_LIVE)
    iset(I_LOADED, -1)
    apply_params()
    put(st, PLAYER_BASE + SC_PAUSE, 0)


def play_tune(index: Int) raises:
    """Parse, schedule and hand it to the audio thread.

    Paused across the swap: the render callback returns before it reads
    SC_ADDR when SC_PAUSE is set, which is the whole handoff.
    """
    let paths = g_paths()
    if index < 0 or index >= len(paths[]):
        return
    let path = paths[][index]
    var text = String("")
    try:
        with open(path, "r") as f:
            text = f.read()
    except:
        set_status(String("could not read ") + basename(path))
        return

    var tune = Tune()
    parse_abc(text, tune)
    expand_repeats(tune)
    resolve_ties(tune)

    var notes = 0
    for i in range(len(tune.events)):
        if tune.events[i].kind == EV_NOTE and tune.events[i].velocity > 0:
            notes += 1

    var steps = List[Step]()
    build_schedule(tune, SAMPLE_RATE, steps)
    if len(steps) == 0:
        set_status(String("nothing to play in ") + basename(path))
        return

    var st = P(unsafe_from_address=g_chip()[])
    put(st, PLAYER_BASE + SC_PAUSE, 1)
    all_notes_off()
    # The previous schedule was calloc'd and nothing else owns it.
    let old = get(st, PLAYER_BASE + SC_ADDR)
    if old != 0:
        _ = external_call["free", NoneType](P(unsafe_from_address=old))
    put(st, PLAYER_BASE + SC_ADDR, 0)
    _ = flatten_schedule(steps, st)
    put(st, PLAYER_BASE + SC_LOOP, 1)
    put(st, PLAYER_BASE + SC_DONE, 0)

    var sub = String("")
    if len(tune.composer.as_bytes()) > 0:
        sub += tune.composer + String("   ·   ")
    sub += String(len(tune.voices)) + String(" voices   ·   ")
    sub += String(notes) + String(" notes   ·   ")
    sub += String(tune.tempo_bpm) + String(" bpm")
    set_header(
        tune.title if len(tune.title.as_bytes()) > 0 else basename(path),
        sub^,
    )
    iset(I_MODE, MODE_TUNE)
    iset(I_LOADED, index)
    set_status(String("playing"))
    put(st, PLAYER_BASE + SC_PAUSE, 0)


def main() raises:
    var backend = BACKEND_CHIP
    var write_only = String("")
    var first = String("")
    let args = argv()
    for i in range(1, len(args)):
        let a = String(args[i])
        if a == "--midi":
            backend = BACKEND_MIDI
        elif a == "--chip":
            backend = BACKEND_CHIP
        elif a.startswith("--write="):
            write_only = String(a[byte=8 : len(a.as_bytes())])
        else:
            first = a

    # --write is the one mode with no window: parse, write, done.
    if len(write_only.as_bytes()) > 0:
        if len(first.as_bytes()) == 0:
            print("usage: abcplayer <tune.abc> --write=out.mid")
            return
        var text = String("")
        with open(first, "r") as f:
            text = f.read()
        var tune = Tune()
        parse_abc(text, tune)
        expand_repeats(tune)
        resolve_ties(tune)
        if write_midi(tune, write_only):
            print("wrote", write_only)
        else:
            print("could not write", write_only)
        return

    if not load_framework["AppKit"]():
        raise Error("could not load AppKit")

    ui_init()
    var st = chip_new()
    g_chip()[] = Int(st)
    put(st, PLAYER_BASE + UI_BACKEND, backend)
    put(
        st, PLAYER_BASE + UI_SCOPE,
        Int(external_call["calloc", P](Int(SCOPE_LEN), Int(4))),
    )
    # An empty schedule, so live mode renders the chip rather than silence.
    put(
        st, PLAYER_BASE + SC_ADDR,
        Int(external_call["calloc", P](Int(STEP_SLOTS + 8), Int(8))),
    )

    g_font_title()[] = make_font(16.0)
    g_font_body()[] = make_font(13.0)
    g_font_small()[] = make_font(11.0)
    set_header(String("ABC player"), String("chip · three voices"))

    scan_tunes()
    if len(first.as_bytes()) > 0:
        add_tune(first)
        iset(I_SEL, len(g_names()[]) - 1)

    let unit = start_audio(st, backend)
    go_live()
    if len(first.as_bytes()) > 0:
        play_tune(iget(I_SEL))

    with autoreleasepool():
        let NSApplication = ObjCClass.lookup["NSApplication"]()
        let app = msg_send[
            ObjCObject, "NSApplication", "sharedApplication", is_class=True
        ](NSApplication.as_object())
        _ = msg_send[Bool, "NSApplication", "setActivationPolicy:"](app, Int(0))

        let NSWindow = ObjCClass.lookup["NSWindow"]()
        var win = msg_send[ObjCObject, "NSWindow", "alloc", is_class=True](
            NSWindow.as_object()
        )
        win = msg_send[
            ObjCObject, "NSWindow",
            "initWithContentRect:styleMask:backing:defer:",
        ](
            win, CGRect(CGPoint(160.0, 160.0), CGSize(WIN_W, WIN_H)),
            Int(15), Int(2), Bool(False),
        )
        _ = msg_send[ObjCObject, "NSWindow", "setTitle:"](
            win, nsstring(String("ABC player")).ptr()
        )

        let view = ObjCObject(AbcView().__objc_id)
        _ = msg_send[ObjCObject, "NSView", "setFrame:"](
            view, CGRect(CGPoint(0.0, 0.0), CGSize(WIN_W, WIN_H))
        )
        _ = external_call["objc_retain", P](view.ptr())
        g_view()[] = view.addr()
        _ = msg_send[ObjCObject, "NSWindow", "setContentView:"](win, view.ptr())
        _ = msg_send[ObjCObject, "NSWindow", "makeFirstResponder:"](
            win, view.ptr()
        )
        _ = msg_send[ObjCObject, "NSWindow", "makeKeyAndOrderFront:"](
            win, win.ptr()
        )
        _ = msg_send[ObjCObject, "NSApplication", "activateIgnoringOtherApps:"](
            app, Bool(True)
        )

        let NSDate = ObjCClass.lookup["NSDate"]()
        var mode = nsstring(String("kCFRunLoopDefaultMode"))
        var running = True
        while running:
            while True:
                var past = msg_send[
                    ObjCObject, "NSDate", "distantPast", is_class=True
                ](NSDate.as_object())
                var ev = msg_send[
                    ObjCObject, "NSApplication",
                    "nextEventMatchingMask:untilDate:inMode:dequeue:",
                ](app, UInt64.MAX, past.ptr(), mode.ptr(), Bool(True))
                if ev.is_nil():
                    break
                _ = msg_send[ObjCObject, "NSApplication", "sendEvent:"](
                    app, ev.ptr()
                )
            if not msg_send[Bool, "NSWindow", "isVisible"](win):
                break

            # Read the flags out BEFORE clearing them. `let` names the global
            # rather than copying it, so clearing first would make every
            # command evaporate one line later.
            if g_cmd()[] != 0:
                let quit = (g_cmd()[] & CMD_QUIT) != 0
                let want_add = (g_cmd()[] & CMD_ADD) != 0
                let want_play = (g_cmd()[] & CMD_PLAY) != 0
                let want_stop = (g_cmd()[] & CMD_STOP) != 0
                g_cmd()[] = 0
                if quit:
                    break
                if want_add:
                    open_panel()
                if want_stop:
                    go_live()
                    set_status(String("ready"))
                if want_play:
                    play_tune(iget(I_SEL))

            redraw()
            sleep(0.033)
            let shot = getenv("ABC_SHOT")
            if len(shot.as_bytes()) > 0:
                write_shot(view, shot)
                print("wrote", shot)
                break

    stop_audio(unit)
    print("stopped.")
