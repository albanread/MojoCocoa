"""One audio unit, two chips, and a lock-free path from the game to the
speaker.

Chip A is the music and chip B is the effects, summed into one mono buffer
by a plain Mojo `fn` handed straight to CoreAudio. There is no shim and no
bridging: an `AURenderCallback` is a C function pointer, and `fn` in a type
position is exactly that.

**Nothing in the callback allocates, locks or raises.** It runs on
CoreAudio's real-time thread, where a lock costs a click in the speaker and
a `malloc` can cost a dropout. Everything it touches was allocated before
the unit started.

**The trigger path.** `sfx_play` is called from the game's thread; the
callback drains at the top of each buffer. That is a single-producer,
single-consumer ring with two counters -- the producer only ever writes the
write counter, the consumer only the read counter, so neither needs a
read-modify-write and there is nothing to contend. What it does need is
ORDERING, and that is what the two fences are for: a release fence after the
payload is stored and before the counter is bumped, and an acquire fence
after the counter is read and before the payload is. Without them a weakly
ordered machine may publish the counter before the slot it refers to, and
the callback plays whatever was in that slot last time round.
"""

from std.atomic import Ordering, fence
from std.ffi import external_call
from std.memory import OpaquePointer, Pointer
from std.objc import load_framework, named_global

from gamepane.abc import (
    Tune, Step, parse_abc, resolve_ties, build_schedule, sort_steps,
    flatten_schedule, render_scheduled, SC_LOOP,
)
from gamepane.api import (
    P, SAMPLE_RATE, PLAYER_BASE, chip_new, chip_free, chip_render, get, put,
    gate_off, set_volume, vget, V_ENV, V_GATE,
    SFX_COUNT, SFX_CLICK, sfx_frames, sfx_start, sfx_frame, sfx_stop,
    Tick,
)


comptime kAudioUnitType_Output = 0x61756F75          # 'auou'
comptime kAudioUnitSubType_DefaultOutput = 0x64656620 # 'def '
comptime kAudioUnitManufacturer_Apple = 0x6170706C    # 'appl'
comptime kAudioFormatLinearPCM = 0x6C70636D           # 'lpcm'
comptime kAudioFormatFlagIsFloat = 1
comptime kAudioFormatFlagIsPacked = 8
comptime kAudioUnitProperty_StreamFormat = 8
comptime kAudioUnitProperty_SetRenderCallback = 23
comptime kAudioUnitScope_Input = 1

comptime AURenderCallback = fn(P, P, P, UInt32, UInt32, P, /) -> Int32


# ── the deck's own state ────────────────────────────────────────────────────
#
# A flat Int block, like the chip's, because the callback is a `fn` and can
# hold nothing but a pointer.

comptime RING_BITS = 8
comptime RING_SIZE = 1 << RING_BITS
"""A power of two, so the wrap is a mask rather than a modulo -- and 256
triggers of slack is far more than a frame can produce."""

comptime D_CHIP_A = 0
comptime D_CHIP_B = 1
comptime D_WRITE = 2         # producer's counter; only the game writes it
comptime D_READ = 3          # consumer's counter; only the callback writes it
comptime D_DROPPED = 4       # triggers refused because the ring was full
comptime D_MUTED = 5
comptime D_TUNE = 7          # 1 when a tune is scheduled on chip A
comptime D_TICK_A = 6        # the music player hook, as an Int
comptime D_VOICE_BASE = 8    # three (effect, frames_left, frame) triples
comptime D_VOICE_STRIDE = 4
comptime D_V_EFFECT = 0
comptime D_V_LEFT = 1
comptime D_V_FRAME = 2
comptime D_V_AGE = 3         # when it started, for stealing the oldest
comptime D_SERIAL = 20       # monotonic, so "oldest" is unambiguous
comptime D_SCRATCH = 21      # the chip-B mix buffer, allocated once
comptime D_RING_BASE = 24
comptime DECK_SLOTS = D_RING_BASE + RING_SIZE


@always_inline
fn dget(d: P, slot: Int) -> Int:
    return d.unsafe_bitcast[Int]()[unsafe_offset=slot]


@always_inline
fn dput(d: P, slot: Int, value: Int):
    d.unsafe_bitcast[Int]()[unsafe_offset=slot] = value


def deck_new() raises -> P:
    """Two chips, a ring, and three effect voices. Allocated once."""
    let d = external_call["calloc", P](Int(DECK_SLOTS), Int(8))
    if Int(d) == 0:
        raise Error("audio deck: out of memory")
    dput(d, D_CHIP_A, Int(chip_new()))
    dput(d, D_CHIP_B, Int(chip_new()))
    set_volume(P(unsafe_from_address=dget(d, D_CHIP_A)), 15)
    set_volume(P(unsafe_from_address=dget(d, D_CHIP_B)), 15)
    for v in range(3):
        dput(d, D_VOICE_BASE + v * D_VOICE_STRIDE + D_V_EFFECT, -1)
    # The mix buffer, allocated HERE and never in the callback.
    let scratch = external_call["calloc", P](Int(MAX_BUFFER), Int(4))
    if Int(scratch) == 0:
        raise Error("audio deck: no scratch buffer")
    dput(d, D_SCRATCH, Int(scratch))
    return d


fn deck_free(d: P):
    if Int(d) == 0:
        return
    chip_free(P(unsafe_from_address=dget(d, D_CHIP_A)))
    chip_free(P(unsafe_from_address=dget(d, D_CHIP_B)))
    _ = external_call["free", NoneType](P(unsafe_from_address=dget(d, D_SCRATCH)))
    _ = external_call["free", NoneType](d)


fn music_chip(d: P) -> P:
    return P(unsafe_from_address=dget(d, D_CHIP_A))


fn sfx_chip(d: P) -> P:
    return P(unsafe_from_address=dget(d, D_CHIP_B))


def play_tune(d: P, source: String, loop: Bool = False) raises -> Int:
    """Parse ABC and schedule it on chip A. Returns the number of steps.

    The schedule is flattened into plain memory HERE, on the game's thread,
    before the callback ever looks at it -- the audio thread only reads an
    array of integers. That is the whole reason a tune can be
    sample-accurate without a lock: there is nothing to lock, because
    nothing is built while it plays.
    """
    var tune = Tune()
    parse_abc(source, tune)
    resolve_ties(tune)
    var steps = List[Step]()
    build_schedule(tune, SAMPLE_RATE, steps)
    sort_steps(steps)
    # `flatten_schedule` takes the chip state mutably, and `music_chip`
    # returns a value rather than a place, so it needs a name first.
    var a = music_chip(d)
    # flatten_schedule returns the ADDRESS of the flattened block, not a
    # count -- so what comes back to the caller is len(steps), which is what
    # "how much tune is there" means to anyone asking.
    let addr = flatten_schedule(steps, a)
    # Looping is the player's own, so a level theme costs one parse however
    # long the level lasts.
    put(a, PLAYER_BASE + SC_LOOP, 1 if loop else 0)
    dput(d, D_TUNE, 1 if (addr != 0 and len(steps) > 0) else 0)
    return len(steps)


fn stop_tune(d: P):
    """Silence the tune. The schedule stays flattened, so playing it again
    costs nothing -- and a game that stops and starts a level theme should
    not pay for the parse twice."""
    dput(d, D_TUNE, 0)
    let a = music_chip(d)
    for v in range(3):
        gate_off(a, v)


fn set_music_tick(d: P, tick: Tick):
    """Install chip A's 50 Hz player routine.

    A plain C function pointer, stored as an Int and read back as one -- the
    same trick the AURenderCallback uses below, and for the same reason: the
    callback is a `fn` and can carry nothing but the deck pointer.
    """
    var t = tick
    dput(d, D_TICK_A, Pointer(to=t).unsafe_bitcast[Int]()[])


fn set_muted(d: P, muted: Bool):
    dput(d, D_MUTED, 1 if muted else 0)


fn dropped_triggers(d: P) -> Int:
    """Triggers refused because the ring was full. Zero in any sane game;
    non-zero says the ring is too small or the callback has stalled."""
    return dget(d, D_DROPPED)


# ── the trigger ring ────────────────────────────────────────────────────────


fn sfx_play(d: P, effect: Int) -> Bool:
    """Queue an effect. Called from the GAME's thread.

    Returns False only when the ring is full, which means 256 triggers
    arrived without the callback running once. Nothing blocks and nothing
    allocates, so this is safe to call from anywhere a game runs.
    """
    let w = dget(d, D_WRITE)
    let r = dget(d, D_READ)
    if w - r >= RING_SIZE:
        dput(d, D_DROPPED, dget(d, D_DROPPED) + 1)
        return False
    dput(d, D_RING_BASE + (w & (RING_SIZE - 1)), effect)
    # RELEASE: the slot must be visible before the counter that publishes it.
    fence[Ordering.RELEASE]()
    dput(d, D_WRITE, w + 1)
    return True


fn pending_triggers(d: P) -> Int:
    return dget(d, D_WRITE) - dget(d, D_READ)


fn _start_effect(d: P, effect: Int):
    """Gate an effect onto a chip-B voice, stealing the oldest if all three
    are busy. Runs on the audio thread; raises nothing, allocates nothing."""
    let b = sfx_chip(d)
    var slot = -1
    for v in range(3):
        if dget(d, D_VOICE_BASE + v * D_VOICE_STRIDE + D_V_EFFECT) < 0:
            slot = v
            break
    if slot < 0:
        # All three busy: take the one that started earliest. A game that
        # fires four things at once should lose the oldest, not the newest --
        # the newest is the one the player just caused.
        var oldest = dget(d, D_VOICE_BASE + D_V_AGE)
        slot = 0
        for v in range(1, 3):
            let age = dget(d, D_VOICE_BASE + v * D_VOICE_STRIDE + D_V_AGE)
            if age < oldest:
                oldest = age
                slot = v
        try:
            sfx_stop(b, slot, dget(d, D_VOICE_BASE + slot * D_VOICE_STRIDE))
        except:
            pass

    let serial = dget(d, D_SERIAL) + 1
    dput(d, D_SERIAL, serial)
    let base = D_VOICE_BASE + slot * D_VOICE_STRIDE
    var e = effect
    if e < 0 or e >= SFX_COUNT:
        e = SFX_CLICK
    dput(d, base + D_V_EFFECT, e)
    dput(d, base + D_V_LEFT, sfx_frames(e))
    dput(d, base + D_V_FRAME, 0)
    dput(d, base + D_V_AGE, serial)
    try:
        sfx_start(b, slot, e)
    except:
        pass


fn drain_triggers(d: P):
    """Consume everything queued. Runs at the top of each buffer."""
    var r = dget(d, D_READ)
    let w = dget(d, D_WRITE)
    # ACQUIRE: the counter has been read, so the slots it covers must be
    # visible before they are read.
    fence[Ordering.ACQUIRE]()
    while r != w:
        _start_effect(d, dget(d, D_RING_BASE + (r & (RING_SIZE - 1))))
        r += 1
    dput(d, D_READ, r)


fn advance_effects(d: P):
    """One 50 Hz frame of every running effect. Called from chip B's own
    player hook, so effects move on the beat the chip defines."""
    let b = sfx_chip(d)
    for v in range(3):
        let base = D_VOICE_BASE + v * D_VOICE_STRIDE
        let e = dget(d, base + D_V_EFFECT)
        if e < 0:
            continue
        let left = dget(d, base + D_V_LEFT)
        if left <= 0:
            try:
                sfx_stop(b, v, e)
            except:
                pass
            dput(d, base + D_V_EFFECT, -1)
            continue
        try:
            sfx_frame(b, v, e, dget(d, base + D_V_FRAME))
        except:
            pass
        dput(d, base + D_V_FRAME, dget(d, base + D_V_FRAME) + 1)
        dput(d, base + D_V_LEFT, left - 1)


# The deck the callback is currently driving. A `fn` player hook takes only
# the chip pointer, so the deck it belongs to has to be reachable some other
# way -- and there is exactly one audio unit per process here, which is the
# same limit the window has and the same limit the Rust has.
comptime g_deck = named_global["gamepane.audio.deck", Int]


fn _sfx_tick(st: P):
    """Chip B's 50 Hz hook."""
    if g_deck()[] != 0:
        advance_effects(P(unsafe_from_address=g_deck()[]))


fn _silent_tick(st: P):
    pass


# ── the callback ────────────────────────────────────────────────────────────


comptime MAX_BUFFER = 4096
"""Scratch for chip A, sized past anything CoreAudio asks for. Allocated
with the deck, never in the callback."""


fn render(
    ref_con: P,
    action_flags: P,
    timestamp: P,
    bus: UInt32,
    frames: UInt32,
    io_data: P,
) -> Int32:
    """Fill one buffer with chip A plus chip B. CoreAudio's real-time thread.

    An AudioBufferList is {UInt32 mNumberBuffers; AudioBuffer mBuffers[]} and
    an AudioBuffer is {UInt32 mNumberChannels; UInt32 mDataByteSize; void*
    mData}; the pointer is 8-aligned, so the first buffer's data sits at
    offset 16 and its size at 12.
    """
    let base = io_data.unsafe_bitcast[UInt32]()
    let byte_size = Int(base[unsafe_offset=3])
    let data_slot = io_data.unsafe_bitcast[Int]()[unsafe_offset=2]
    if data_slot == 0:
        return 0
    let dest = Pointer[Float32, MutUntrackedOrigin](
        unsafe_from_address=data_slot
    )
    let n = byte_size // 4
    let d = ref_con

    if dget(d, D_MUTED) != 0:
        for i in range(n):
            dest[unsafe_offset=i] = Float32(0.0)
        return 0

    # Triggers first, so an effect fired this frame is audible in it.
    drain_triggers(d)

    # Chip A into the destination, chip B into scratch, then sum. Two passes
    # rather than one interleaved render, because the chip's render loop is
    # the hot path and it should stay a straight line.
    let sb = Pointer[Float32, MutUntrackedOrigin](
        unsafe_from_address=dget(d, D_SCRATCH)
    )
    var m = n
    if m > MAX_BUFFER:
        m = MAX_BUFFER

    if dget(d, D_TUNE) != 0:
        # A scheduled tune drives chip A sample-accurately, applying every
        # event that falls inside this buffer at the sample it falls on --
        # rather than on the 50 Hz grid the player hook runs on.
        render_scheduled(music_chip(d), dest, m)
        chip_render(sfx_chip(d), sb, m, _sfx_tick)
        for i in range(m):
            var v0 = Float64(dest[unsafe_offset=i]) * 0.5 + Float64(
                sb[unsafe_offset=i]
            ) * 0.5
            if v0 > 1.0:
                v0 = 1.0
            elif v0 < -1.0:
                v0 = -1.0
            dest[unsafe_offset=i] = Float32(v0)
        for i in range(m, n):
            dest[unsafe_offset=i] = Float32(0.0)
        return 0

    let tick_a = dget(d, D_TICK_A)
    if tick_a != 0:
        chip_render(
            music_chip(d), dest, m,
            Pointer(to=tick_a).unsafe_bitcast[Tick]()[],
        )
    else:
        chip_render(music_chip(d), dest, m, _silent_tick)
    chip_render(sfx_chip(d), sb, m, _sfx_tick)

    for i in range(m):
        # Half each: two chips at full tilt would clip, and halving is
        # cheaper and more honest than a limiter nobody can hear working.
        var v = Float64(dest[unsafe_offset=i]) * 0.5 + Float64(
            sb[unsafe_offset=i]
        ) * 0.5
        if v > 1.0:
            v = 1.0
        elif v < -1.0:
            v = -1.0
        dest[unsafe_offset=i] = Float32(v)
    for i in range(m, n):
        dest[unsafe_offset=i] = Float32(0.0)
    return 0


def start_audio(d: P) raises -> Int:
    """Open the default output and install the Mojo callback."""
    if not load_framework["AudioToolbox"]():
        raise Error("could not load AudioToolbox")

    var desc = external_call["calloc", P](Int(5), Int(4))
    let dd = desc.unsafe_bitcast[UInt32]()
    dd[unsafe_offset=0] = UInt32(kAudioUnitType_Output)
    dd[unsafe_offset=1] = UInt32(kAudioUnitSubType_DefaultOutput)
    dd[unsafe_offset=2] = UInt32(kAudioUnitManufacturer_Apple)

    var nil_addr = 0
    let comp = external_call["AudioComponentFindNext", P](
        P(unsafe_from_address=nil_addr), desc
    )
    if Int(comp) == 0:
        raise Error("no default output audio component")

    var unit_slot = external_call["calloc", P](Int(1), Int(8))
    var rc = external_call["AudioComponentInstanceNew", Int32](comp, unit_slot)
    if rc != 0:
        raise Error("could not instantiate the output unit")
    let unit = P(
        unsafe_from_address=unit_slot.unsafe_bitcast[Int]()[unsafe_offset=0]
    )

    # Mono Float32 at the chip's own rate, which is what a 6581 had.
    var asbd = external_call["calloc", P](Int(40), Int(1))
    asbd.unsafe_bitcast[Float64]()[unsafe_offset=0] = Float64(SAMPLE_RATE)
    let a = asbd.unsafe_bitcast[UInt32]()
    a[unsafe_offset=2] = UInt32(kAudioFormatLinearPCM)
    a[unsafe_offset=3] = UInt32(
        kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
    )
    a[unsafe_offset=4] = UInt32(4)
    a[unsafe_offset=5] = UInt32(1)
    a[unsafe_offset=6] = UInt32(4)
    a[unsafe_offset=7] = UInt32(1)
    a[unsafe_offset=8] = UInt32(32)
    rc = external_call["AudioUnitSetProperty", Int32](
        unit, UInt32(kAudioUnitProperty_StreamFormat),
        UInt32(kAudioUnitScope_Input), UInt32(0), asbd, UInt32(40),
    )
    if rc != 0:
        raise Error("could not set the stream format")

    var cbfn: AURenderCallback = render
    let fn_addr = Pointer(to=cbfn).unsafe_bitcast[Int]()[]
    var cbs = external_call["calloc", P](Int(2), Int(8))
    cbs.unsafe_bitcast[Int]()[unsafe_offset=0] = fn_addr
    cbs.unsafe_bitcast[Int]()[unsafe_offset=1] = Int(d)
    rc = external_call["AudioUnitSetProperty", Int32](
        unit, UInt32(kAudioUnitProperty_SetRenderCallback),
        UInt32(kAudioUnitScope_Input), UInt32(0), cbs, UInt32(16),
    )
    if rc != 0:
        raise Error("could not install the render callback")

    g_deck()[] = Int(d)
    rc = external_call["AudioUnitInitialize", Int32](unit)
    if rc != 0:
        raise Error("could not initialise the output unit")
    rc = external_call["AudioOutputUnitStart", Int32](unit)
    if rc != 0:
        raise Error("could not start the output unit")
    return Int(unit)


fn stop_audio(unit_addr: Int):
    """Always, before main returns. An audio unit outliving the state its
    callback reads is a crash on the way out."""
    if unit_addr == 0:
        return
    let unit = P(unsafe_from_address=unit_addr)
    _ = external_call["AudioOutputUnitStop", Int32](unit)
    _ = external_call["AudioUnitUninitialize", Int32](unit)
    g_deck()[] = 0
