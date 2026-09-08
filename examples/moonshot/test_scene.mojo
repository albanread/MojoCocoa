# ===----------------------------------------------------------------------=== #
# The plot, headless: Apollo 11's planned course drawn into a byte
# framebuffer in each of the three frames and saved as PNGs to look at;
# the assertions are about pixels -- the Earth's disc is the size the
# camera says, the course drew, nothing crashed on points behind the
# camera.
#
# Run: cocoamojo run examples/moonshot/test_scene.mojo
# ===----------------------------------------------------------------------=== #

from astro import *
from orbit import *
from transfer import *
from window import *
from plan import *
from scene import *
from png import save_png
from std.testing import *
from std.ffi import external_call
from std.memory import OpaquePointer, Pointer

comptime P = OpaquePointer[MutUntrackedOrigin]
comptime W = 400
comptime H = 400


def count_index(px: Pointer[UInt8, MutUntrackedOrigin], lo: Int, hi: Int) -> Int:
    var n = 0
    for i in range(W * H):
        var v = Int(px[unsafe_offset=i])
        if v >= lo and v <= hi:
            n += 1
    return n


def save_indexed(path: String, px: Pointer[UInt8, MutUntrackedOrigin]) -> Bool:
    var bgra = Pointer[UInt32, MutUntrackedOrigin](
        unsafe_from_address=Int(external_call["calloc", P](Int(W * H), Int(4)))
    )
    for i in range(W * H):
        var c = palette_rgb(Int(px[unsafe_offset=i]))
        bgra[unsafe_offset=i] = UInt32(255 << 24) | UInt32(Int(c.x) << 16) | UInt32(Int(c.y) << 8) | UInt32(Int(c.z))
    var ok = save_png(path, bgra, W, H)
    external_call["free", NoneType](bgra.unsafe_bitcast[NoneType]())
    return ok


def test_lines_clip_and_draw() raises:
    var px = Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=Int(external_call["calloc", P](Int(W * H), Int(1))))
    var cv = Canvas(px, W, 0, 0, W, H)
    cv.clear(C_BG)
    cv.line(-100.0, 200.0, 500.0, 200.0, C_WHITE)  # across, both ends outside
    cv.line(200.0, -50.0, 200.0, 450.0, C_WHITE)  # down
    cv.line(-10.0, -10.0, -5.0, -5.0, C_WHITE)  # entirely outside: nothing
    cv.line(1e9, 1e9, -1e9, -1e9, C_WHITE)  # a huge diagonal: clipped, finite work
    var n = count_index(px, C_WHITE, C_WHITE)
    assert_true(n >= W + H - 1 and n <= W + H + 600)
    # A projected point behind the camera is refused, not drawn.
    var cam = Camera(Vec3(0.0, 0.0, 0.0), 0.0, 0.0, 100000.0, 40.0)
    var behind = cam.project(Vec3(200000.0, 0.0, 0.0), W, H)
    assert_false(behind.ok)
    var front = cam.project(Vec3(0.0, 0.0, 0.0), W, H)
    assert_true(front.ok)
    assert_almost_equal(front.x, 200.0, atol=1e-9)
    assert_almost_equal(front.y, 200.0, atol=1e-9)
    external_call["free", NoneType](px.unsafe_bitcast[NoneType]())


def test_apollo_course_in_three_frames() raises:
    var eph = Ephemeris()
    var ch = apollo_11_choices()
    var wm = WindowMap(eph, ch.year, ch.month, launch_sites()[ch.pad], landing_sites()[ch.target], 60.0, 120.0, 48, 480)
    var s = make_plan(eph, wm, ch)
    assert_true(s.ok)
    var bodies = Bodies(eph, s.jde_tli, ch.tof_h / 24.0 + 4.0)
    var t_p = s.transfer.correction.arrival.t_p
    var jde_p = s.jde_tli + t_p / 86400.0
    var moon_p = bodies.moon_at(t_p)
    var sun_e = eph.sun_position(s.jde_tli).unit()
    var sun_m = (eph.sun_position(jde_p) - eph.moon_position(jde_p)).unit()
    var mf = eph.moon_frame(jde_p)
    var site = landing_sites()[0]
    var site_dir = mf.to_inertial(site.lat, site.lon)
    var theta = gmst_deg(s.jd_tli) * DEG
    var ex = Vec3(cos(theta), sin(theta), 0.0)
    var ey = Vec3(-sin(theta), cos(theta), 0.0)
    var ez = Vec3(0.0, 0.0, 1.0)
    # The Moon's path over the mission, hourly.
    var moon_path = List[Float64]()
    for hh in range(-24, Int(t_p / 3600.0) + 72):
        var m = bodies.moon_at(Float64(hh) * 3600.0)
        moon_path.append(m.x)
        moon_path.append(m.y)
        moon_path.append(m.z)
    var px = Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=Int(external_call["calloc", P](Int(W * H), Int(1))))
    var cv = Canvas(px, W, 0, 0, W, H)

    # 1. Earth-centred.
    cv.clear(C_BG)
    var cam = Camera(Vec3(0.0, 0.0, 0.0), 35.0, 28.0, 900000.0, 40.0)
    draw_polyline(cv, cam, moon_path, 3, 0, C_GREEN0, 16)
    draw_polyline(cv, cam, s.arc, 7, 1, C_CYAN0, 16)
    draw_body(cv, cam, Vec3(0.0, 0.0, 0.0), R_EARTH, sun_e, ex, ey, ez, C_EARTH0)
    draw_body(cv, cam, moon_p, R_MOON, sun_m, mf.x, mf.y, mf.z, C_MOON0)
    var earth_px = count_index(px, C_EARTH0, C_EARTH0 + SHADES - 1)
    var course_px = count_index(px, C_CYAN0, C_CYAN0 + 15)
    var rpx = R_EARTH * cam.focal(H) / cam.dist
    print("    Earth frame: Earth disc", earth_px, "px (expected about", Int(3.14159 * rpx * rpx), "), course", course_px, "px")
    assert_true(Float64(earth_px) > 2.5 * rpx * rpx and Float64(earth_px) < 3.8 * rpx * rpx)
    assert_true(course_px > 150)
    assert_true(save_indexed(String("/tmp/moonshot-course-earth.png"), px))

    # 2. Moon-centred: the hyperbola, the site, the terminator.
    cv.clear(C_BG)
    var rel = List[Float64]()
    var n = len(s.arc) // 7
    for i in range(n):
        var t = s.arc[i * 7]
        var m = bodies.moon_at(t)
        rel.append(s.arc[i * 7 + 1] - m.x)
        rel.append(s.arc[i * 7 + 2] - m.y)
        rel.append(s.arc[i * 7 + 3] - m.z)
    var cam2 = Camera(Vec3(0.0, 0.0, 0.0), 35.0, 28.0, 24000.0, 40.0)
    draw_polyline(cv, cam2, rel, 3, 0, C_CYAN0, 16)
    draw_body(cv, cam2, Vec3(0.0, 0.0, 0.0), R_MOON, sun_m, mf.x, mf.y, mf.z, C_MOON0)
    var sp = body_point(cam2, Vec3(0.0, 0.0, 0.0), R_MOON, site_dir, W, H)
    if sp.ok:
        cv.disc(sp.x, sp.y, 2.5, C_MAGENTA0 + 15)
    var moon_px = count_index(px, C_MOON0, C_MOON0 + SHADES - 1)
    var lit_px = count_index(px, C_MOON0 + 12, C_MOON0 + SHADES - 1)
    print("    Moon frame: Moon disc", moon_px, "px, of which lit", lit_px, "; site visible:", sp.ok)
    assert_true(moon_px > 2000 and lit_px > 300 and lit_px < moon_px)
    assert_true(save_indexed(String("/tmp/moonshot-course-moon.png"), px))

    # 3. Rotating with the Earth–Moon line.
    cv.clear(C_BG)
    var pole = moon_p.cross(eph.moon_velocity(jde_p)).unit()
    var ref0 = bodies.moon_at(0.0)
    var rot = List[Float64]()
    for i in range(n):
        var t = s.arc[i * 7]
        var m = bodies.moon_at(t)
        var ang = atan2(pole.dot(ref0.cross(m)), ref0.dot(m))
        var p = rotate_about(Vec3(s.arc[i * 7 + 1], s.arc[i * 7 + 2], s.arc[i * 7 + 3]), pole, -ang)
        rot.append(p.x)
        rot.append(p.y)
        rot.append(p.z)
    var cam3 = Camera(Vec3(190000.0 * ref0.unit().x, 190000.0 * ref0.unit().y, 190000.0 * ref0.unit().z), 35.0, 60.0, 700000.0, 40.0)
    draw_polyline(cv, cam3, rot, 3, 0, C_CYAN0, 16)
    draw_body(cv, cam3, Vec3(0.0, 0.0, 0.0), R_EARTH, sun_e, ex, ey, ez, C_EARTH0)
    var moon_rot = rotate_about(moon_p, pole, -atan2(pole.dot(ref0.cross(moon_p)), ref0.dot(moon_p)))
    draw_body(cv, cam3, moon_rot, R_MOON, sun_m, mf.x, mf.y, mf.z, C_MOON0)
    var course3 = count_index(px, C_CYAN0, C_CYAN0 + 15)
    print("    rotating frame: course", course3, "px")
    assert_true(course3 > 150)
    assert_true(save_indexed(String("/tmp/moonshot-course-rotating.png"), px))
    external_call["free", NoneType](px.unsafe_bitcast[NoneType]())


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
