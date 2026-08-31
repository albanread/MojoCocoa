# The window: a tune list, a voice editor, and a playable keyboard.
#
# Everything here draws itself. There is no NSButton and no NSSlider -- the
# panel is a few dozen rectangles and a hit test, which is less code than
# wiring that many controls to target/action, and it keeps the whole interface
# in one place you can read.
#
# The keyboard layout is Logic Pro's and GarageBand's "Musical Typing", which
# is the mapping a Mac musician already has in their fingers:
#
#       W E   T Y U   O P          <- the black keys, in their piano positions
#      A S D F G H J K L ;         <- the white keys, from C
#
#   Z / X   octave down / up        C / V   level down / up
#   Tab     sustain                 Space   play / pause the tune
#
# Z X C V are free for that job precisely because they are not note keys, which
# is why Logic chose them and why this does too.
#
# Nothing here touches the audio thread's schedule. Live notes are register
# writes -- set a frequency, raise a gate -- and the render callback reads
# those registers on its own clock. A torn read costs one frame of one
# oscillator, where a lock would cost a click in the speaker.

from std.objc import (
    Obj, Cls, ObjCObject, msg_send, nsstring, autoreleasepool, named_global,
    extern_object, CGPoint, CGSize, CGRect,
)
from std.ffi import external_call
from std.memory import OpaquePointer, Pointer, MutUntrackedOrigin

from chip import (
    P, get, put, vget, vput, set_wave, set_adsr, set_filter, route_filter,
    set_volume, set_pulse_width, set_freq_hz, PLAYER_BASE, SAMPLE_RATE,
    V_ENV, V_GATE, WAVE_TRI, WAVE_SAW, WAVE_PULSE, WAVE_NOISE,
    FILT_LP, FILT_BP, FILT_HP,
)
from chipplay import SC_PAUSE, SC_SAMPLE, SC_END, SC_VOICE_NOTE, midi_to_hz

# UI and backend state, in the tail of the chip's player region. chipplay
# owns slots 0..23 there; these start well clear of them.
comptime UI_SCOPE = 32
comptime UI_SCOPE_POS = 33
comptime UI_BACKEND = 34
comptime UI_SYNTH = 35           # the DLS synth's AudioUnit, as an address
comptime BACKEND_CHIP = 0
comptime BACKEND_MIDI = 1
comptime SCOPE_LEN = 1024

comptime WIN_W = 980.0
comptime WIN_H = 700.0
comptime FRAME = 18.0

# ── State ───────────────────────────────────────────────────────────────────

comptime g_chip = named_global["abc.chip", Int]
comptime g_view = named_global["abc.view", Int]
comptime g_cmd = named_global["abc.cmd", Int]
comptime g_font_title = named_global["abc.font.title", Int]
comptime g_font_body = named_global["abc.font.body", Int]
comptime g_font_small = named_global["abc.font.small", Int]
comptime g_title = named_global["abc.title", Int]
comptime g_subtitle = named_global["abc.subtitle", Int]

comptime g_paths = named_global["abc.paths", List[String]]
comptime g_names = named_global["abc.names", List[String]]
comptime g_status = named_global["abc.status", List[String]]
# Small integers that would each want a global of their own. One list, named
# slots, so adding one is a constant rather than a declaration.
comptime g_ints = named_global["abc.ints", List[Int]]
comptime g_params = named_global["abc.params", List[Int]]
comptime g_held = named_global["abc.held", List[Int]]

comptime I_SEL = 0          # selected tune, -1 for none
comptime I_OCTAVE = 1       # base octave for musical typing
comptime I_SUSTAIN = 2
comptime I_MODE = 3         # MODE_LIVE or MODE_TUNE
comptime I_EDIT = 4         # which voice the editor is editing
comptime I_DRAG = 5         # which slider the mouse is dragging, -1 for none
comptime I_LOADED = 6       # index of the tune actually loaded, -1 for none
comptime I_SLOTS = 8

comptime MODE_LIVE = 0
comptime MODE_TUNE = 1

comptime CMD_QUIT = 1
comptime CMD_ADD = 2        # run an NSOpenPanel; the pump does this
comptime CMD_PLAY = 4       # load and play the selected tune
comptime CMD_STOP = 8       # back to live mode

# Per voice: wave, A, D, S, R, pulse width, filter routing.
comptime PV_STRIDE = 8
comptime PV_WAVE = 0
comptime PV_A = 1
comptime PV_D = 2
comptime PV_S = 3
comptime PV_R = 4
comptime PV_PW = 5
comptime PV_FILT = 6
comptime PG_BASE = 24       # the global block, past three voices
comptime PG_CUTOFF = 24
comptime PG_RES = 25
comptime PG_FMODE = 26
comptime PG_VOL = 27
comptime PARAM_SLOTS = 28


def ui_init():
    """Every list starts at its full length, so nothing indexes past the end."""
    let ints = g_ints()
    while len(ints[]) < I_SLOTS:
        ints[].append(0)
    ints[][I_SEL] = -1
    ints[][I_OCTAVE] = 4
    ints[][I_MODE] = MODE_LIVE
    ints[][I_EDIT] = 0
    ints[][I_DRAG] = -1
    ints[][I_LOADED] = -1

    let held = g_held()
    while len(held[]) < 3:
        held[].append(-1)

    let p = g_params()
    while len(p[]) < PARAM_SLOTS:
        p[].append(0)
    for v in range(3):
        let b = v * PV_STRIDE
        p[][b + PV_WAVE] = WAVE_PULSE if v == 0 else WAVE_SAW
        p[][b + PV_A] = 0
        p[][b + PV_D] = 7
        p[][b + PV_S] = 11
        p[][b + PV_R] = 5
        p[][b + PV_PW] = 1400
        p[][b + PV_FILT] = 1
    p[][PG_CUTOFF] = 1500
    p[][PG_RES] = 6
    p[][PG_FMODE] = FILT_LP
    p[][PG_VOL] = 14

    let s = g_status()
    while len(s[]) < 1:
        s[].append(String("ready"))


def set_status(var text: String):
    let s = g_status()
    if len(s[]) == 0:
        s[].append(text^)
    else:
        s[][0] = text^


def status() -> String:
    let s = g_status()
    return s[][0] if len(s[]) > 0 else String("")


def iget(slot: Int) -> Int:
    return g_ints()[][slot]


def iset(slot: Int, value: Int):
    g_ints()[][slot] = value


def apply_params():
    """Push every parameter into the chip's registers."""
    let st = P(unsafe_from_address=g_chip()[])
    if Int(st) == 0:
        return
    let p = g_params()
    for v in range(3):
        let b = v * PV_STRIDE
        set_wave(st, v, p[][b + PV_WAVE])
        set_adsr(st, v, p[][b + PV_A], p[][b + PV_D], p[][b + PV_S],
                 p[][b + PV_R])
        set_pulse_width(st, v, p[][b + PV_PW])
        route_filter(st, v, p[][b + PV_FILT] != 0)
    set_filter(st, p[][PG_CUTOFF], p[][PG_RES], p[][PG_FMODE])
    set_volume(st, p[][PG_VOL])


# ── Musical typing ──────────────────────────────────────────────────────────


fn semitone_for(c: Int) -> Int:
    """Logic Pro's Musical Typing layout. -1 for a key that is not a note.

    The home row is the white keys from C and the row above holds the black
    keys where a piano puts them -- which is why R and I are gaps: there is no
    black key between E and F, or between B and C.
    """
    # a s d f g h j k l ;   ->  C D E F G A B C D E
    if c == 97: return 0        # a
    if c == 115: return 2       # s
    if c == 100: return 4       # d
    if c == 102: return 5       # f
    if c == 103: return 7       # g
    if c == 104: return 9       # h
    if c == 106: return 11      # j
    if c == 107: return 12      # k
    if c == 108: return 14      # l
    if c == 59: return 16       # ;
    # w e   t y u   o p     ->  C# D#  F# G# A#  C# D#
    if c == 119: return 1       # w
    if c == 101: return 3       # e
    if c == 116: return 6       # t
    if c == 121: return 8       # y
    if c == 117: return 10      # u
    if c == 111: return 13      # o
    if c == 112: return 15      # p
    return -1


def note_on(midi: Int):
    """Sound a note on a free voice, stealing the oldest if there is none."""
    let st = P(unsafe_from_address=g_chip()[])
    if Int(st) == 0:
        return
    let held = g_held()
    var slot = -1
    for v in range(3):
        if held[][v] < 0:
            slot = v
            break
    if slot < 0:
        # Every voice is busy. Take voice 0: it is the one that has been
        # sounding longest, and a chip with three oscillators has to drop
        # something.
        slot = 0
        vput(st, slot, V_GATE, 0)
    held[][slot] = midi
    set_freq_hz(st, slot, midi_to_hz(midi))
    vput(st, slot, V_GATE, 1)


def note_off(midi: Int):
    let st = P(unsafe_from_address=g_chip()[])
    if Int(st) == 0:
        return
    if iget(I_SUSTAIN) != 0:
        return
    let held = g_held()
    for v in range(3):
        if held[][v] == midi:
            vput(st, v, V_GATE, 0)
            held[][v] = -1


def all_notes_off():
    let st = P(unsafe_from_address=g_chip()[])
    if Int(st) == 0:
        return
    let held = g_held()
    for v in range(3):
        vput(st, v, V_GATE, 0)
        held[][v] = -1


def key_down(c: Int, repeat: Bool):
    """One key press. Returns nothing; every effect is a register or a flag."""
    if repeat:
        return
    let semi = semitone_for(c)
    if semi >= 0:
        if iget(I_MODE) == MODE_TUNE:
            return          # the tune owns the voices
        note_on(iget(I_OCTAVE) * 12 + 12 + semi)
        return

    if c == 122:            # z -- octave down
        var o = iget(I_OCTAVE)
        if o > 0:
            iset(I_OCTAVE, o - 1)
    elif c == 120:          # x -- octave up
        var o2 = iget(I_OCTAVE)
        if o2 < 8:
            iset(I_OCTAVE, o2 + 1)
    elif c == 99:           # c -- level down
        let p = g_params()
        if p[][PG_VOL] > 0:
            p[][PG_VOL] = p[][PG_VOL] - 1
            apply_params()
    elif c == 118:          # v -- level up
        let p2 = g_params()
        if p2[][PG_VOL] < 15:
            p2[][PG_VOL] = p2[][PG_VOL] + 1
            apply_params()
    elif c == 9:            # tab -- sustain
        let was = iget(I_SUSTAIN)
        iset(I_SUSTAIN, 0 if was != 0 else 1)
        if was != 0:
            all_notes_off()
    elif c == 32:           # space -- play or pause
        if iget(I_MODE) == MODE_TUNE:
            let st = P(unsafe_from_address=g_chip()[])
            let paused = get(st, PLAYER_BASE + SC_PAUSE)
            put(st, PLAYER_BASE + SC_PAUSE, 0 if paused != 0 else 1)
        else:
            g_cmd()[] = g_cmd()[] | CMD_PLAY
    elif c == 27 or c == 113:   # esc, q
        g_cmd()[] = g_cmd()[] | CMD_QUIT


def key_up(c: Int):
    let semi = semitone_for(c)
    if semi >= 0 and iget(I_MODE) == MODE_LIVE:
        note_off(iget(I_OCTAVE) * 12 + 12 + semi)


# ── Drawing primitives ──────────────────────────────────────────────────────


fn rgb(r: Int, g: Int, b: Int) -> ObjCObject:
    return Cls["NSColor"]().colorWithSRGBRed_green_blue_alpha(
        Float64(r) / 255.0, Float64(g) / 255.0, Float64(b) / 255.0, 1.0
    )


fn rect(x: Float64, y: Float64, w: Float64, h: Float64) -> CGRect:
    return CGRect(CGPoint(x, y), CGSize(w, h))


fn box(x: Float64, top: Float64, w: Float64, h: Float64) -> CGRect:
    """A rect placed by its TOP edge. The window is laid out downwards and
    Cocoa measures upwards, and doing that subtraction once here is the
    difference between a layout you can read and a page of WIN_H minus."""
    return rect(x, WIN_H - top - h, w, h)


fn fill_rect(r: CGRect, colour: ObjCObject):
    Obj["NSColor"](colour.addr()).setFill()
    _ = external_call["NSRectFill", NoneType](r)


fn inside(r: CGRect, x: Float64, y: Float64) -> Bool:
    return (
        x >= r.origin.x
        and x <= r.origin.x + r.size.width
        and y >= r.origin.y
        and y <= r.origin.y + r.size.height
    )


fn make_font(size: Float64) -> Int:
    with autoreleasepool():
        let f = Cls["NSFont"]().monospacedSystemFontOfSize_weight(
            size, Float64(0.0)
        )
        if not f.is_nil():
            _ = external_call["objc_retain", P](f.ptr())
            return f.addr()
        let g = Cls["NSFont"]().systemFontOfSize(size)
        if g.is_nil():
            return 0
        _ = external_call["objc_retain", P](g.ptr())
        return g.addr()


fn draw_text(text: String, x: Float64, y: Float64, font_addr: Int,
             colour: ObjCObject):
    with autoreleasepool():
        var attrs = Cls["NSMutableDictionary"]().dictionary()
        if font_addr != 0:
            Obj["NSMutableDictionary"](attrs.addr()).setObject_forKey(
                ObjCObject(font_addr).ptr(),
                extern_object["NSFontAttributeName"]().ptr(),
            )
        Obj["NSMutableDictionary"](attrs.addr()).setObject_forKey(
            colour.ptr(),
            extern_object["NSForegroundColorAttributeName"]().ptr(),
        )
        Obj["NSString"](nsstring(text).addr()).drawAtPoint_withAttributes(
            CGPoint(x, y), attrs.ptr()
        )


fn draw_nsstring(addr: Int, x: Float64, y: Float64, font_addr: Int,
                 colour: ObjCObject):
    if addr == 0:
        return
    with autoreleasepool():
        var attrs = Cls["NSMutableDictionary"]().dictionary()
        if font_addr != 0:
            Obj["NSMutableDictionary"](attrs.addr()).setObject_forKey(
                ObjCObject(font_addr).ptr(),
                extern_object["NSFontAttributeName"]().ptr(),
            )
        Obj["NSMutableDictionary"](attrs.addr()).setObject_forKey(
            colour.ptr(),
            extern_object["NSForegroundColorAttributeName"]().ptr(),
        )
        Obj["NSString"](ObjCObject(addr).addr()).drawAtPoint_withAttributes(
            CGPoint(x, y), attrs.ptr()
        )


fn note_name(midi: Int) -> String:
    if midi < 0:
        return String("---")
    let names = String("C C#D D#E F F#G G#A A#B ")
    let pc = midi % 12
    let octave = midi // 12 - 1
    return names[byte = pc * 2 : pc * 2 + 2] + String(octave)


fn format_time(samples: Int) -> String:
    let total = samples // SAMPLE_RATE
    let minutes = total // 60
    let seconds = total % 60
    var s = String(minutes) + String(":")
    if seconds < 10:
        s += String("0")
    return s + String(seconds)


# ── Layout ──────────────────────────────────────────────────────────────────

comptime LIST_X = 20.0
comptime LIST_W = 268.0
comptime LIST_TOP = 96.0
comptime ROW_H = 22.0
comptime ROWS = 14
comptime BTN_TOP = 96.0 + 22.0 * 14.0 + 10.0
comptime BTN_H = 26.0

comptime PANEL_X = 306.0
comptime PANEL_W = 654.0
comptime SCOPE_TOP = 96.0
comptime SCOPE_H = 86.0
comptime EDIT_TOP = 232.0

comptime KEYS_TOP = 502.0
comptime WHITE_W = 62.0
comptime WHITE_H = 148.0
comptime BLACK_W = 38.0
comptime BLACK_H = 92.0
comptime KEYS_X = 20.0

comptime SL_X = PANEL_X + 12.0
comptime SL_W = 250.0
comptime SL_H = 16.0


fn wave_bit(i: Int) -> Int:
    if i == 0: return WAVE_TRI
    if i == 1: return WAVE_SAW
    if i == 2: return WAVE_PULSE
    return WAVE_NOISE


fn wave_name(i: Int) -> String:
    if i == 0: return String("tri")
    if i == 1: return String("saw")
    if i == 2: return String("pulse")
    return String("noise")


fn fmode_bit(i: Int) -> Int:
    if i == 0: return FILT_LP
    if i == 1: return FILT_BP
    return FILT_HP


fn fmode_name(i: Int) -> String:
    if i == 0: return String("LP")
    if i == 1: return String("BP")
    return String("HP")


fn white_semi(i: Int) -> Int:
    if i == 0: return 0
    if i == 1: return 2
    if i == 2: return 4
    if i == 3: return 5
    if i == 4: return 7
    if i == 5: return 9
    if i == 6: return 11
    if i == 7: return 12
    if i == 8: return 14
    return 16


fn white_letter(i: Int) -> String:
    let row = String("ASDFGHJKL;")
    return String(row[byte = i : i + 1])


fn black_after(i: Int) -> Int:
    """Which white key each black key sits after, and its semitone."""
    if i == 0: return 0
    if i == 1: return 1
    if i == 2: return 3
    if i == 3: return 4
    if i == 4: return 5
    if i == 5: return 7
    return 8


fn black_semi(i: Int) -> Int:
    if i == 0: return 1
    if i == 1: return 3
    if i == 2: return 6
    if i == 3: return 8
    if i == 4: return 10
    if i == 5: return 13
    return 15


fn black_letter(i: Int) -> String:
    let row = String("WETYUOP")
    return String(row[byte = i : i + 1])


fn white_rect(i: Int) -> CGRect:
    return box(KEYS_X + Float64(i) * WHITE_W, KEYS_TOP, WHITE_W - 2.0, WHITE_H)


fn black_rect(i: Int) -> CGRect:
    let after = black_after(i)
    let x = KEYS_X + Float64(after + 1) * WHITE_W - BLACK_W / 2.0 - 1.0
    return box(x, KEYS_TOP, BLACK_W, BLACK_H)


fn slider_rect(id: Int) -> CGRect:
    return box(SL_X, EDIT_TOP + 52.0 + Float64(id) * 26.0, SL_W, SL_H)


fn slider_max(id: Int) -> Int:
    if id == 0: return 4095      # pulse width
    if id == 5: return 2047      # cutoff
    return 15                    # A D S R, resonance, level


fn slider_label(id: Int) -> String:
    if id == 0: return String("pulse width")
    if id == 1: return String("attack")
    if id == 2: return String("decay")
    if id == 3: return String("sustain")
    if id == 4: return String("release")
    if id == 5: return String("cutoff")
    if id == 6: return String("resonance")
    return String("level")


def slider_value(id: Int) -> Int:
    let p = g_params()
    let b = iget(I_EDIT) * PV_STRIDE
    if id == 0: return p[][b + PV_PW]
    if id == 1: return p[][b + PV_A]
    if id == 2: return p[][b + PV_D]
    if id == 3: return p[][b + PV_S]
    if id == 4: return p[][b + PV_R]
    if id == 5: return p[][PG_CUTOFF]
    if id == 6: return p[][PG_RES]
    return p[][PG_VOL]


def slider_set(id: Int, value: Int):
    let p = g_params()
    let b = iget(I_EDIT) * PV_STRIDE
    var v = value
    if v < 0:
        v = 0
    if v > slider_max(id):
        v = slider_max(id)
    if id == 0: p[][b + PV_PW] = v
    elif id == 1: p[][b + PV_A] = v
    elif id == 2: p[][b + PV_D] = v
    elif id == 3: p[][b + PV_S] = v
    elif id == 4: p[][b + PV_R] = v
    elif id == 5: p[][PG_CUTOFF] = v
    elif id == 6: p[][PG_RES] = v
    else: p[][PG_VOL] = v
    apply_params()


fn wave_rect(i: Int) -> CGRect:
    return box(SL_X + Float64(i) * 74.0, EDIT_TOP + 24.0, 68.0, 20.0)


fn voice_tab_rect(v: Int) -> CGRect:
    return box(PANEL_X + PANEL_W - 210.0 + Float64(v) * 68.0, EDIT_TOP - 4.0,
               62.0, 20.0)


fn fmode_rect(i: Int) -> CGRect:
    return box(PANEL_X + PANEL_W - 210.0 + Float64(i) * 52.0,
               EDIT_TOP + 24.0, 46.0, 20.0)


fn filt_rect() -> CGRect:
    return box(PANEL_X + PANEL_W - 210.0, EDIT_TOP + 52.0, 150.0, 20.0)


fn btn_rect(i: Int) -> CGRect:
    let w = (LIST_W - 16.0) / 3.0
    return box(LIST_X + Float64(i) * (w + 8.0), BTN_TOP, w, BTN_H)


fn row_rect(i: Int) -> CGRect:
    return box(LIST_X, LIST_TOP + Float64(i) * ROW_H, LIST_W, ROW_H - 2.0)


# ── The screen ──────────────────────────────────────────────────────────────


def draw_button(r: CGRect, label: String, on: Bool, enabled: Bool):
    # `var`, not `let`, on both of these. A `let` names storage, and the
    # storage a conditional expression produces is a temporary destroyed at
    # its last use -- the binding itself. What reaches fill_rect is then a
    # dead object, and the crash lands inside AppKit's drawing with a stack
    # that names nothing in this file.
    var face = rgb(34, 39, 50)
    if on:
        face = rgb(52, 60, 76)
    fill_rect(r, face)
    var ink = rgb(96, 104, 120)
    if enabled:
        ink = rgb(228, 232, 240)
    # The copy is not decoration. Handing this `def`'s String parameter
    # straight to draw_text -- a `fn`, which takes it by value -- crashes
    # inside nsstring on every run, with a stack that names only AppKit;
    # binding it to a local first is reliably fine. Measured 3 runs each way.
    # It has NOT been reduced to a small case: the same shape in a plain
    # program works, so something about the call arriving through drawRect_
    # matters, and the reduction is still owed.
    var l = label
    draw_text(l, r.origin.x + 8.0, r.origin.y + 4.0, g_font_small()[], ink)


def draw_slider(id: Int):
    let r = slider_rect(id)
    let v = slider_value(id)
    let m = slider_max(id)
    fill_rect(r, rgb(30, 34, 44))
    var frac = Float64(v) / Float64(m)
    if frac > 1.0:
        frac = 1.0
    fill_rect(rect(r.origin.x, r.origin.y, r.size.width * frac, r.size.height),
              rgb(120, 220, 160))
    draw_text(slider_label(id), r.origin.x + r.size.width + 10.0,
              r.origin.y + 1.0, g_font_small()[], rgb(150, 158, 176))
    draw_text(String(v), r.origin.x + r.size.width + 108.0, r.origin.y + 1.0,
              g_font_small()[], rgb(228, 232, 240))


def draw_keyboard():
    let held = g_held()
    let base = iget(I_OCTAVE) * 12 + 12
    var sounding = List[Int]()
    for v in range(3):
        sounding.append(held[][v])

    for i in range(10):
        let r = white_rect(i)
        let midi = base + white_semi(i)
        var lit = False
        for k in range(len(sounding)):
            if sounding[k] == midi:
                lit = True
        fill_rect(r, rgb(120, 220, 160) if lit else rgb(226, 230, 238))
        draw_text(white_letter(i), r.origin.x + WHITE_W / 2.0 - 8.0,
                  r.origin.y + 8.0, g_font_small()[], rgb(70, 78, 92))
        if white_semi(i) % 12 == 0:
            draw_text(note_name(midi), r.origin.x + 6.0,
                      r.origin.y + WHITE_H - 18.0, g_font_small()[],
                      rgb(150, 158, 176))

    for i in range(7):
        let r = black_rect(i)
        let midi = base + black_semi(i)
        var lit = False
        for k in range(len(sounding)):
            if sounding[k] == midi:
                lit = True
        fill_rect(r, rgb(90, 170, 125) if lit else rgb(24, 27, 34))
        draw_text(black_letter(i), r.origin.x + BLACK_W / 2.0 - 5.0,
                  r.origin.y + 8.0, g_font_small()[], rgb(190, 198, 212))


def draw_screen():
    let st = P(unsafe_from_address=g_chip()[])
    with autoreleasepool():
        let ink = rgb(228, 232, 240)
        let dim = rgb(128, 138, 158)
        let accent = rgb(120, 220, 160)
        fill_rect(rect(0.0, 0.0, WIN_W, WIN_H), rgb(18, 20, 26))

        # ── Header ──────────────────────────────────────────────────────────
        if g_title()[] != 0:
            draw_nsstring(g_title()[], 22.0, WIN_H - 40.0, g_font_title()[], ink)
        if g_subtitle()[] != 0:
            draw_nsstring(g_subtitle()[], 22.0, WIN_H - 62.0,
                          g_font_small()[], dim)
        # `var`, not `let`: a `let` NAMES storage, and the storage here is a
        # temporary the conditional just built. It is destroyed at its last
        # use -- which is this binding -- and what draw_text then reads is a
        # freed String, which surfaces as a crash inside nsstring with a
        # stack that mentions only AppKit.
        var mode_txt = String("LIVE — the keyboard plays")
        if iget(I_MODE) != MODE_LIVE:
            mode_txt = String("PLAYING a tune")
        draw_text(mode_txt, PANEL_X + PANEL_W - 210.0, WIN_H - 40.0,
                  g_font_small()[], accent)

        # ── Tunes ───────────────────────────────────────────────────────────
        draw_text(String("TUNES"), LIST_X, WIN_H - LIST_TOP + 6.0,
                  g_font_small()[], dim)
        let paths = g_paths()
        let names = g_names()
        let sel = iget(I_SEL)
        let loaded = iget(I_LOADED)
        for i in range(ROWS):
            if i >= len(names[]):
                break
            let r = row_rect(i)
            if i == sel:
                fill_rect(r, rgb(52, 60, 76))
            var mark = String("  ")
            if i == loaded and iget(I_MODE) == MODE_TUNE:
                mark = String("▶ ")
            draw_text(mark + names[][i], r.origin.x + 6.0, r.origin.y + 4.0,
                      g_font_small()[], ink if i == sel else dim)
        if len(names[]) == 0:
            draw_text(String("  none yet — press Add…"), LIST_X + 6.0,
                      row_rect(0).origin.y + 4.0, g_font_small()[], dim)

        draw_button(btn_rect(0), String("Add…"), False, True)
        draw_button(btn_rect(1), String("Play"), iget(I_MODE) == MODE_TUNE,
                    sel >= 0)
        draw_button(btn_rect(2), String("Stop"), False,
                    iget(I_MODE) == MODE_TUNE)

        # ── Scope ───────────────────────────────────────────────────────────
        let sr = box(PANEL_X, SCOPE_TOP, PANEL_W, SCOPE_H)
        fill_rect(sr, rgb(10, 12, 16))
        let mid = sr.origin.y + SCOPE_H / 2.0
        fill_rect(rect(sr.origin.x, mid, PANEL_W, 1.0), rgb(38, 44, 54))
        let scope_addr = get(st, PLAYER_BASE + UI_SCOPE)
        if scope_addr != 0:
            let scope = Pointer[Float32, MutUntrackedOrigin](
                unsafe_from_address=scope_addr
            )
            Obj["NSColor"](accent.addr()).setFill()
            var pw: Float64 = PANEL_W
            let points = Int(pw) // 2
            for i in range(points):
                let s = Float64(scope[unsafe_offset=(i * SCOPE_LEN) // points])
                let h = s * (SCOPE_H / 2.0 - 4.0)
                var top = mid
                var height = h
                if h < 0.0:
                    top = mid + h
                    height = -h
                if height < 1.5:
                    height = 1.5
                _ = external_call["NSRectFill", NoneType](
                    rect(sr.origin.x + Float64(i * 2), top, 2.0, height)
                )

        # Progress, only while a tune owns the voices.
        if iget(I_MODE) == MODE_TUNE:
            let played = get(st, PLAYER_BASE + SC_SAMPLE)
            let total = get(st, PLAYER_BASE + SC_END)
            var line = format_time(played) + String(" / ") + format_time(total)
            if get(st, PLAYER_BASE + SC_PAUSE) != 0:
                line += String("   [paused]")
            draw_text(line, PANEL_X, WIN_H - SCOPE_TOP - SCOPE_H - 20.0,
                      g_font_small()[], ink)
            let bar = box(PANEL_X + 160.0, SCOPE_TOP + SCOPE_H + 8.0,
                          PANEL_W - 160.0, 8.0)
            fill_rect(bar, rgb(34, 38, 48))
            if total > 0:
                var frac = Float64(played) / Float64(total)
                if frac > 1.0:
                    frac = 1.0
                fill_rect(rect(bar.origin.x, bar.origin.y,
                               bar.size.width * frac, 8.0), accent)
        else:
            draw_text(
                String("octave ") + String(iget(I_OCTAVE))
                + String("    sustain ")
                + (String("on") if iget(I_SUSTAIN) != 0 else String("off"))
                + String("    ") + status(),
                PANEL_X, WIN_H - SCOPE_TOP - SCOPE_H - 20.0,
                g_font_small()[], dim,
            )

        # ── Voice editor ────────────────────────────────────────────────────
        draw_text(String("VOICE"), PANEL_X, WIN_H - EDIT_TOP + 4.0,
                  g_font_small()[], dim)
        for v in range(3):
            let held = get(st, PLAYER_BASE + SC_VOICE_NOTE + v)
            var label = String(" ") + String(v + 1)
            if iget(I_MODE) == MODE_TUNE and held >= 0:
                label += String(" ") + note_name(held)
            elif g_held()[][v] >= 0:
                label += String(" ") + note_name(g_held()[][v])
            draw_button(voice_tab_rect(v), label, v == iget(I_EDIT), True)

        let p = g_params()
        let b = iget(I_EDIT) * PV_STRIDE
        for i in range(4):
            draw_button(wave_rect(i), wave_name(i),
                        (p[][b + PV_WAVE] & wave_bit(i)) != 0, True)
        for id in range(8):
            draw_slider(id)

        draw_button(filt_rect(), String("through filter"),
                    p[][b + PV_FILT] != 0, True)
        for i in range(3):
            draw_button(fmode_rect(i), fmode_name(i),
                        (p[][PG_FMODE] & fmode_bit(i)) != 0, True)

        # ── Keyboard ────────────────────────────────────────────────────────
        draw_keyboard()
        draw_text(
            String("Z X octave   ·   C V level   ·   TAB sustain   ·   "
                   "SPACE play/pause   ·   Q quit"),
            KEYS_X, WIN_H - KEYS_TOP - WHITE_H - 20.0,
            g_font_small()[], dim,
        )


# ── Hit testing ─────────────────────────────────────────────────────────────


def click(x: Float64, y: Float64):
    """One mouse-down, in view coordinates."""
    for i in range(3):
        if inside(btn_rect(i), x, y):
            if i == 0:
                g_cmd()[] = g_cmd()[] | CMD_ADD
            elif i == 1:
                g_cmd()[] = g_cmd()[] | CMD_PLAY
            else:
                g_cmd()[] = g_cmd()[] | CMD_STOP
            return

    let names = g_names()
    for i in range(ROWS):
        if i >= len(names[]):
            break
        if inside(row_rect(i), x, y):
            iset(I_SEL, i)
            return

    for v in range(3):
        if inside(voice_tab_rect(v), x, y):
            iset(I_EDIT, v)
            return

    let p = g_params()
    let b = iget(I_EDIT) * PV_STRIDE
    for i in range(4):
        if inside(wave_rect(i), x, y):
            # The chip ANDs selected waveforms together, so this is a set of
            # toggles rather than a radio group -- and clearing the last one
            # leaves silence, which is what the register means.
            p[][b + PV_WAVE] = p[][b + PV_WAVE] ^ wave_bit(i)
            apply_params()
            return

    if inside(filt_rect(), x, y):
        p[][b + PV_FILT] = 0 if p[][b + PV_FILT] != 0 else 1
        apply_params()
        return

    for i in range(3):
        if inside(fmode_rect(i), x, y):
            p[][PG_FMODE] = p[][PG_FMODE] ^ fmode_bit(i)
            apply_params()
            return

    for id in range(8):
        let r = slider_rect(id)
        if inside(r, x, y):
            iset(I_DRAG, id)
            drag(x, y)
            return

    # The drawn keys play too, so a mouse can find a note the letters hide.
    if iget(I_MODE) == MODE_LIVE:
        let base = iget(I_OCTAVE) * 12 + 12
        for i in range(7):
            if inside(black_rect(i), x, y):
                note_on(base + black_semi(i))
                return
        for i in range(10):
            if inside(white_rect(i), x, y):
                note_on(base + white_semi(i))
                return


def drag(x: Float64, y: Float64):
    let id = iget(I_DRAG)
    if id < 0:
        return
    let r = slider_rect(id)
    var frac = (x - r.origin.x) / r.size.width
    if frac < 0.0:
        frac = 0.0
    if frac > 1.0:
        frac = 1.0
    slider_set(id, Int(frac * Float64(slider_max(id)) + 0.5))


def release():
    iset(I_DRAG, -1)
    # A note started with the mouse ends when the mouse does.
    if iget(I_MODE) == MODE_LIVE and iget(I_SUSTAIN) == 0:
        all_notes_off()
