# ===----------------------------------------------------------------------=== #
# A PNG writer with no library behind it but zlib's compress2 and crc32,
# lifted from `examples/grayscott` and given its size as arguments. BGRA
# in, an 8-bit RGB PNG out.
# ===----------------------------------------------------------------------=== #

from std.ffi import external_call
from std.memory import OpaquePointer, Pointer

comptime P = OpaquePointer[MutUntrackedOrigin]


def _be32(v: UInt32) -> SIMD[DType.uint8, 4]:
    """PNG is big-endian throughout; arm64 is not."""
    return SIMD[DType.uint8, 4](
        UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF),
        UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF),
    )


def _put_chunk(
    fh: Int, tag: StaticString, data: Pointer[UInt8, MutUntrackedOrigin], n: Int
):
    """One PNG chunk: length, 4-char type, payload, CRC over type+payload."""
    var hdr_addr = Int(external_call["malloc", P](Int(8)))
    var hdr = Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=hdr_addr)
    var tail = Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=hdr_addr + 4)
    var L = _be32(UInt32(n))
    for i in range(4):
        hdr[unsafe_offset=i] = L[i]
    var t = tag.as_bytes()
    for i in range(4):
        hdr[unsafe_offset=4 + i] = t[i]
    _ = external_call["fwrite", Int](hdr.unsafe_bitcast[NoneType](), Int(1), Int(8), fh)
    if n > 0:
        _ = external_call["fwrite", Int](data.unsafe_bitcast[NoneType](), Int(1), n, fh)
    var crc = external_call["crc32", UInt64](
        UInt64(0), tail.unsafe_bitcast[NoneType](), UInt32(4)
    )
    if n > 0:
        crc = external_call["crc32", UInt64](
            crc, data.unsafe_bitcast[NoneType](), UInt32(n)
        )
    var C = _be32(UInt32(crc & UInt64(0xFFFFFFFF)))
    for i in range(4):
        hdr[unsafe_offset=i] = C[i]
    _ = external_call["fwrite", Int](hdr.unsafe_bitcast[NoneType](), Int(1), Int(4), fh)
    external_call["free", NoneType](hdr.unsafe_bitcast[NoneType]())


def save_png(path: String, bgra: Pointer[UInt32, MutUntrackedOrigin], width: Int, height: Int) -> Bool:
    """Write the current frame. Returns False rather than raising: a failed
    screenshot must never take the demo down mid-drag."""
    var stride = width * 3 + 1
    var raw_n = stride * height
    var raw_addr = Int(external_call["malloc", P](Int(raw_n)))
    if raw_addr == 0:
        return False
    var raw = Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=raw_addr)
    for y in range(height):
        var row = y * stride
        raw[unsafe_offset=row] = UInt8(0)
        for x in range(width):
            var px = bgra[unsafe_offset=y * width + x]
            var o = row + 1 + x * 3
            raw[unsafe_offset=o] = UInt8((px >> 16) & UInt32(255))
            raw[unsafe_offset=o + 1] = UInt8((px >> 8) & UInt32(255))
            raw[unsafe_offset=o + 2] = UInt8(px & UInt32(255))

    var cap = UInt64(raw_n + raw_n // 100 + 4096)
    var comp = Pointer[UInt8, MutUntrackedOrigin](
        unsafe_from_address=Int(external_call["malloc", P](Int(cap)))
    )
    var clen = Pointer[UInt64, MutUntrackedOrigin](
        unsafe_from_address=Int(external_call["malloc", P](Int(8)))
    )
    clen[] = cap
    var rc = external_call["compress2", Int32](
        comp.unsafe_bitcast[NoneType](), clen,
        raw.unsafe_bitcast[NoneType](), UInt64(raw_n), Int32(6),
    )
    if rc != Int32(0):
        external_call["free", NoneType](raw.unsafe_bitcast[NoneType]())
        external_call["free", NoneType](comp.unsafe_bitcast[NoneType]())
        external_call["free", NoneType](clen.unsafe_bitcast[NoneType]())
        return False

    var mode = String("wb")
    var local_path = path
    var fh = Int(external_call["fopen", P](
        local_path.as_c_string_slice(), mode.as_c_string_slice()
    ))
    if fh == 0:
        external_call["free", NoneType](raw.unsafe_bitcast[NoneType]())
        external_call["free", NoneType](comp.unsafe_bitcast[NoneType]())
        external_call["free", NoneType](clen.unsafe_bitcast[NoneType]())
        return False

    var sig = Pointer[UInt8, MutUntrackedOrigin](
        unsafe_from_address=Int(external_call["malloc", P](Int(8)))
    )
    var sigbytes = SIMD[DType.uint8, 8](137, 80, 78, 71, 13, 10, 26, 10)
    for i in range(8):
        sig[unsafe_offset=i] = sigbytes[i]
    _ = external_call["fwrite", Int](sig.unsafe_bitcast[NoneType](), Int(1), Int(8), fh)

    var ihdr = Pointer[UInt8, MutUntrackedOrigin](
        unsafe_from_address=Int(external_call["malloc", P](Int(13)))
    )
    var wb = _be32(UInt32(width))
    var hb = _be32(UInt32(height))
    for i in range(4):
        ihdr[unsafe_offset=i] = wb[i]
        ihdr[unsafe_offset=4 + i] = hb[i]
    ihdr[unsafe_offset=8] = UInt8(8)
    ihdr[unsafe_offset=9] = UInt8(2)
    ihdr[unsafe_offset=10] = UInt8(0)
    ihdr[unsafe_offset=11] = UInt8(0)
    ihdr[unsafe_offset=12] = UInt8(0)
    _put_chunk(fh, "IHDR", ihdr, 13)
    _put_chunk(fh, "IDAT", comp, Int(clen[]))
    _put_chunk(fh, "IEND", ihdr, 0)
    _ = external_call["fclose", Int32](fh)

    external_call["free", NoneType](sig.unsafe_bitcast[NoneType]())
    external_call["free", NoneType](ihdr.unsafe_bitcast[NoneType]())
    external_call["free", NoneType](raw.unsafe_bitcast[NoneType]())
    external_call["free", NoneType](comp.unsafe_bitcast[NoneType]())
    external_call["free", NoneType](clen.unsafe_bitcast[NoneType]())
    return True


# ===----------------------------------------------------------------------=== #
# Input arrives on Cocoa's schedule; frames happen on ours. Flags and two
# payload globals (a click position, a requested preset), read and cleared
# once a frame on the thread that owns the GPU -- Mandelbrot's own scheme.
# ===----------------------------------------------------------------------=== #

comptime CMD_CLICK = 1
comptime CMD_PAUSE = 2
comptime CMD_RESET = 4
comptime CMD_QUIT = 8
comptime CMD_PRESET = 16
comptime CMD_SAVE = 32

comptime g_cmd = named_global["grayscott.cmd", Int]
comptime g_click_x = named_global["grayscott.click.x", Int]
comptime g_click_y = named_global["grayscott.click.y", Int]
comptime g_want_preset = named_global["grayscott.preset", Int]

