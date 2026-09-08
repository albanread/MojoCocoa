# ===----------------------------------------------------------------------=== #
# MC0's oracles. Every assertion here is a number from outside this
# project: Meeus's worked examples to the digits the book prints, and the
# Apollo 11 landing's published Sun elevation for the whole chain.
#
# Run: cocoamojo run examples/moonshot/test_astro.mojo
# ===----------------------------------------------------------------------=== #

from astro import *
from std.testing import *


def test_julian_day() raises:
    # Meeus 7: the standard epoch, Sputnik, and three calendar checks.
    assert_almost_equal(julian_day(2000, 1, 1, 12), 2451545.0, atol=1e-9)
    assert_almost_equal(julian_day(1957, 10, 4, 19, 26, 24.0), 2436116.31, atol=1e-6)
    assert_almost_equal(julian_day(1987, 1, 27), 2446822.5, atol=1e-9)
    assert_almost_equal(julian_day(1988, 6, 19, 12), 2447332.0, atol=1e-9)
    assert_almost_equal(julian_day(1900, 1, 1), 2415020.5, atol=1e-9)
    # And back again, through a time with seconds in it.
    var c = civil(julian_day(1969, 7, 16, 13, 32, 0.0))
    assert_equal(c.year, 1969)
    assert_equal(c.month, 7)
    assert_equal(c.day, 16)
    assert_equal(c.hour, 13)
    assert_equal(c.minute, 32)
    assert_almost_equal(c.second, 0.0, atol=1e-3)


def test_sidereal_time() raises:
    # Meeus 12.a and 12.b: 1987 April 10 at 0h UT and at 19h 21m UT.
    assert_almost_equal(gmst_deg(2446895.5), 197.693195, atol=1e-5)
    assert_almost_equal(gmst_deg(2446896.30625), 128.737873, atol=1e-5)


def test_obliquity() raises:
    # Meeus 22.a: 1987 April 10 -> 23°26′27.407″.
    assert_almost_equal(obliquity_deg(centuries(2446895.5)), 23.440946, atol=1e-5)


def test_delta_t() raises:
    # The fits meet at their seams, and 1969 is about 40 s (it was 39.9).
    assert_almost_equal(delta_t_seconds(1986.0), delta_t_seconds(1985.999999), atol=0.02)
    assert_almost_equal(delta_t_seconds(2005.0), delta_t_seconds(2004.999999), atol=0.1)
    assert_almost_equal(delta_t_seconds(1969.55), 39.9, atol=0.5)


def test_moon_example_47a() raises:
    # 1992 April 12, 0h TD. Each stage the book prints, then the answer.
    var eph = Ephemeris()
    var s = eph.moon(2448724.5)
    assert_almost_equal(s.lp, 134.290182, atol=1e-5)
    assert_almost_equal(s.d, 113.842304, atol=1e-5)
    assert_almost_equal(s.m, 97.643514, atol=1e-5)
    assert_almost_equal(s.mp, 5.150833, atol=1e-5)
    assert_almost_equal(s.f, 219.889721, atol=1e-5)
    assert_almost_equal(s.e, 1.000194, atol=1e-6)
    assert_almost_equal(s.sum_l, -1127527.0, atol=1.0)
    assert_almost_equal(s.sum_b, -3229126.0, atol=1.0)
    assert_almost_equal(s.sum_r, -16590875.0, atol=1.0)
    assert_almost_equal(s.lon, 133.162655, atol=1e-6)
    assert_almost_equal(s.lat, -3.229126, atol=1e-6)
    assert_almost_equal(s.dist, 368409.7, atol=0.05)
    # The same Moon in the equatorial frame. The book's α, δ are apparent
    # (nutation applied, 0.0046° in longitude); ours are mean, so 0.01°.
    var p = eph.moon_position(2448724.5)
    var ll = lon_lat_of(p)
    assert_almost_equal(wrap360(ll.lon), 134.688470, atol=0.01)
    assert_almost_equal(ll.lat, 13.768368, atol=0.01)
    assert_almost_equal(p.norm(), 368409.7, atol=0.05)


def test_sun_example_25a() raises:
    # 1992 October 13, 0h TD.
    var eph = Ephemeris()
    var s = eph.sun(2448908.5)
    assert_almost_equal(s.l0, 201.80720, atol=1e-5)
    assert_almost_equal(s.m, 278.99397, atol=1e-5)
    assert_almost_equal(s.e, 0.016711668, atol=1e-8)
    assert_almost_equal(s.c, -1.89732, atol=1e-5)
    assert_almost_equal(s.lon, 199.90988, atol=1e-5)
    assert_almost_equal(s.r, 0.99766, atol=1e-5)
    # Declination: the book's apparent value is −7.78507°; mean is within 0.01°.
    var ll = lon_lat_of(eph.sun_position(2448908.5))
    assert_almost_equal(ll.lat, -7.78507, atol=0.01)
    assert_almost_equal(eph.sun_position(2448908.5).norm(), 0.99766 * AU, atol=0.00001 * AU)


def test_moon_frame_example_53a() raises:
    # Meeus 53.a, the same instant as 47.a: the optical libration, i.e. the
    # selenographic point under the Earth, l′ = −1.206°, b′ = +4.194°.
    var eph = Ephemeris()
    var se = eph.sub_earth_point(2448724.5)
    assert_almost_equal(se.lon, -1.206, atol=0.003)
    assert_almost_equal(se.lat, 4.194, atol=0.003)
    # The frame is orthonormal and right-handed.
    var fr = eph.moon_frame(2448724.5)
    assert_almost_equal(fr.x.norm(), 1.0, atol=1e-12)
    assert_almost_equal(fr.x.dot(fr.y), 0.0, atol=1e-12)
    assert_almost_equal(fr.x.dot(fr.z), 0.0, atol=1e-12)
    assert_almost_equal(fr.x.cross(fr.y).dot(fr.z), 1.0, atol=1e-12)
    # to_inertial and selenographic are inverses.
    var back = fr.selenographic(fr.to_inertial(-3.01239, -23.42157))
    assert_almost_equal(back.lat, -3.01239, atol=1e-9)
    assert_almost_equal(back.lon, -23.42157, atol=1e-9)


def test_apollo_11_lighting() raises:
    # The chain end to end: Sun elevation at Tranquility Base at touchdown,
    # 1969 July 20 20:17:40 UTC, was 10.8° (Apollo 11 Mission Report).
    var eph = Ephemeris()
    var jde = jde_from_ut(julian_day(1969, 7, 20, 20, 17, 40.0))
    var e = eph.sun_elevation_deg(jde, 0.67408, 23.47297)
    assert_almost_equal(e, 10.8, atol=1.0)
    # Local morning: six hours later the Sun is higher, by about 3°.
    var later = eph.sun_elevation_deg(jde + 0.25, 0.67408, 23.47297)
    assert_true(later > e + 2.5 and later < e + 3.5)


def test_launch_site() raises:
    # KSC's rotation credit is 0.408 km/s eastward; Kourou's is nearly the
    # full 0.465. And a site is over the meridian when GMST + lon = 0.
    var jd = julian_day(1969, 7, 16, 13, 32, 0.0)
    var ksc = site_position(28.6083, -80.6041, jd)
    assert_almost_equal(site_velocity(ksc).norm(), 0.408, atol=0.002)
    assert_almost_equal(site_velocity(ksc).dot(ksc), 0.0, atol=1e-9)
    var kou = site_position(5.2390, -52.7683, jd)
    assert_almost_equal(site_velocity(kou).norm(), 0.463, atol=0.002)
    # Geocentric latitude of KSC: 28.6083° geodetic is 28.44° geocentric.
    assert_almost_equal(lon_lat_of(ksc).lat, 28.44, atol=0.01)
    assert_almost_equal(wrap360(lon_lat_of(ksc).lon), wrap360(gmst_deg(jd) - 80.6041), atol=1e-9)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
