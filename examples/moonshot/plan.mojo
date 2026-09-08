# ===----------------------------------------------------------------------=== #
# Moonshot — the plan (sprint MC4).
#
# The player's choices go in; the plan sheet comes out: the timeline, every
# burn, the mass at every event, the margins, and the lines that are red.
# Nothing on the sheet is typed in except the vehicle table at the top,
# which is the hardware we were given (design §2); everything below it is
# computed from the choices by the sprints before this one -- the map's
# cell for the geometry and the lighting (MC3), the corrector for the
# transfer (MC2), the integrator for the arc the plot draws (MC1), the
# ephemeris under all of it (MC0) -- and by the rocket equation.
# ===----------------------------------------------------------------------=== #

from std.math import sqrt, exp, log, acos, asin, sin, cos
from astro import *
from orbit import *
from transfer import *
from window import *

# ── the vehicle: the one typed-in table ──────────────────────────────────
#
# Rounded public figures for a Saturn-class stack. The player never edits
# them; the plan sheet shows what they allow.

comptime G0 = 9.80665e-3
"""km/s², so Isp × G0 is an exhaust velocity in km/s."""
comptime STACK_AT_INSERTION = 134000.0
"""kg: CSM ≈ 28 800, LM ≈ 15 100, S-IVB dry + IU + adapter ≈ 17 000, TLI propellant the rest."""
comptime SIVB_ISP = 421.0
comptime SIVB_PROP = 73000.0
comptime SIVB_THRUST = 890.0e3
"""N at the TLI mixture ratio; 216 kg/s."""
comptime TLI_GRAVITY_LOSS = 0.01
"""The impulsive Δv is short of a six-minute burn by about this much."""
comptime CSM_MASS = 28800.0
comptime LM_MASS = 15100.0
comptime SPS_ISP = 314.5
comptime SPS_PROP = 18413.0
comptime SPS_THRUST = 91.2e3
comptime DPS_ISP = 311.0
comptime DPS_PROP = 8200.0
comptime DPS_THRUST = 45040.0
comptime DPS_HOVER_THRUST = 11300.0
"""N: the low-gate throttle setting, what a second of hover costs."""
comptime MCC_BUDGET = 0.030
"""km/s of SPS held for midcourse corrections."""
comptime TEI_RESERVE = 1.000
"""km/s of SPS the CSM keeps for the ride home -- never spent here, always kept."""
comptime DESCENT_BUDGET = 2.000
"""km/s for the powered descent, the figure MC8 flies against."""

# ── the timeline's fixed intervals, from Apollo 11's own ─────────────────

comptime T_INSERTION = 11.0 * 60.0 + 49.0
"""s, liftoff to orbit."""
comptime T_TLI_REV2 = 2.0 * 3600.0 + 44.0 * 60.0 + 16.0
"""s, liftoff to TLI ignition on the second revolution."""
comptime T_PARK_PERIOD = 5293.0
"""s, one revolution at 185 km; rev 3 is one of these later."""
comptime T_MCC2 = 24.0 * 3600.0
"""s after TLI."""
comptime T_LOI2 = 4.0 * 3600.0 + 21.0 * 60.0 + 46.0
"""s after LOI-1."""
comptime T_STAY = 26.0 * 3600.0 + 55.0 * 60.0 + 50.0
"""s, LOI-1 to touchdown."""
comptime T_DOI_BEFORE = 1.0 * 3600.0 + 9.0 * 60.0 + 26.0
comptime T_PDI_BEFORE = 12.0 * 60.0 + 35.0


@fieldwise_init
struct Choices(ImplicitlyCopyable, Movable):
    """What the trench decides. Indices are into `launch_sites()` and
    `landing_sites()`."""

    var pad: Int
    var target: Int
    var year: Int
    var month: Int
    var day: Int
    var hour: Float64  # UTC, decimal
    var tof_h: Float64  # TLI to perilune
    var revs: Int  # TLI on revolution 2 or 3
    var park_alt: Float64  # km
    var peri_alt: Float64  # km, the approach perilune and the lunar orbit's
    var apo_alt: Float64  # km, LOI-1's apolune
    var orient: Int  # 0 = the plane the launch gives; 1 = retrograde, near the lunar equator
    var descent_peri: Float64  # km, DOI's perilune
    var hover_s: Float64  # seconds of hover held in reserve
    var mcc_policy: Int  # 0: correct above 0.3 m/s, 1: above 1, 2: above 3
    var seed: Int  # the mission's dispersions come from this, and only this


def apollo_11_choices() -> Choices:
    return Choices(0, 0, 1969, 7, 16, 13.0 + 32.0 / 60.0, 73.0927, 2, 185.0, 111.0, 314.0, 1, 15.0, 60.0, 1, 1969)


def burn_prop(m0: Float64, dv: Float64, isp: Float64) -> Float64:
    """Propellant for a Δv (km/s) from mass m0 (kg): the rocket equation."""
    return m0 * (1.0 - exp(-dv / (isp * G0)))


def burn_seconds(prop: Float64, thrust: Float64, isp: Float64) -> Float64:
    return prop / (thrust / (isp * 9.80665))


def dv_of(m0: Float64, prop: Float64, isp: Float64) -> Float64:
    """The Δv (km/s) that `prop` kg gives a vehicle of mass m0."""
    if prop <= 0.0 or prop >= m0:
        return 0.0
    return isp * G0 * log(m0 / (m0 - prop))


struct PlanSheet(Movable):
    """Every number the PLAN screen shows, traceable to a computation."""

    var ok: Bool
    # the launch
    var jd_launch: Float64
    var t_launch: Float64  # s from the map's epoch
    var tof: Float64  # s
    var tli_offset: Float64  # s after launch
    var azimuth: Float64
    var inclination: Float64
    var corridor: Bool
    var windows: List[Float64]  # that day's corridor runs, four numbers each
    var plane: Vec3
    # the site
    var sun_elev: Float64
    var sun_rising: Bool
    var lit: Bool
    # the map's estimate and the corrector's answer
    var est_dv_tli: Float64
    var est_dv_loi: Float64
    var transfer: Transfer
    var target_pole: Vec3  # the planned flyby plane's normal: what the MCCs aim to keep
    var inc_equator: Float64
    var cross_range: Float64  # km: the site's distance from the orbit plane at landing
    var site: Site
    var apo_alt: Float64
    var desc_peri: Float64
    var hover_s: Float64
    var return_perigee_alt: Float64  # km: where the unburned flyby comes back to
    var free_return: Bool
    var moon_dist: Float64  # km, at arrival
    # the timeline, JD UT
    var jd_insertion: Float64
    var jd_tli_ign: Float64  # S-IVB ignition, what the timeline shows
    var jd_tli: Float64  # the impulse: mid-burn, what the physics uses
    var jd_mcc2: Float64
    var jd_loi1_ign: Float64  # SPS ignition, half a burn before perilune
    var jd_loi1: Float64  # perilune, the impulse
    var jd_loi2: Float64
    var jd_doi: Float64
    var jd_pdi: Float64
    var jd_landing: Float64
    # the burns, km/s
    var dv_tli: Float64
    var tli_seconds: Float64
    var dv_loi1: Float64
    var loi1_seconds: Float64
    var dv_loi2: Float64
    var loi2_seconds: Float64
    var dv_doi: Float64
    var doi_seconds: Float64
    var dv_descent: Float64
    var dv_hover: Float64
    # masses and margins
    var mass_after_tli: Float64
    var sivb_used: Float64
    var sivb_margin_kg: Float64
    var sivb_margin_dv: Float64
    var sps_used: Float64  # LOI-1, LOI-2 and the MCC budget, on the stack
    var sps_tei: Float64  # the TEI reserve, on the CSM alone
    var sps_margin_kg: Float64
    var sps_margin_dv: Float64
    var dps_used: Float64
    var dps_margin_kg: Float64
    var dps_margin_s: Float64  # in seconds of hover
    # the lines
    var red: List[String]
    var amber: List[String]
    # the arc the plot draws: (t s from TLI, x, y, z, vx, vy, vz)
    var arc: List[Float64]
    var jde_tli: Float64

    def __init__(out self):
        self.ok = False
        self.jd_launch = 0.0
        self.t_launch = 0.0
        self.tof = 0.0
        self.tli_offset = 0.0
        self.azimuth = 0.0
        self.inclination = 0.0
        self.corridor = False
        self.windows = List[Float64]()
        self.plane = Vec3(0.0, 0.0, 1.0)
        self.sun_elev = 0.0
        self.sun_rising = False
        self.lit = False
        self.est_dv_tli = 0.0
        self.est_dv_loi = 0.0
        var zero = Vec3(0.0, 0.0, 0.0)
        var inj = Injection(zero, zero, zero, 0.0, 0.0)
        var arr = Arrival(0.0, zero, zero, 0.0, 0.0, zero, zero, 0.0, 0.0, False, 0.0, zero, zero)
        self.transfer = Transfer(inj, Correction(zero, arr, 0, False), 0.0, 0.0, 0.0)
        self.target_pole = Vec3(0.0, 0.0, 1.0)
        self.inc_equator = 0.0
        self.cross_range = 0.0
        self.site = Site(String(""), 0.0, 0.0, 0.0, 0.0)
        self.apo_alt = 0.0
        self.desc_peri = 0.0
        self.hover_s = 60.0
        self.return_perigee_alt = 0.0
        self.free_return = False
        self.moon_dist = 0.0
        self.jd_insertion = 0.0
        self.jd_tli_ign = 0.0
        self.jd_tli = 0.0
        self.jd_mcc2 = 0.0
        self.jd_loi1_ign = 0.0
        self.jd_loi1 = 0.0
        self.jd_loi2 = 0.0
        self.jd_doi = 0.0
        self.jd_pdi = 0.0
        self.jd_landing = 0.0
        self.dv_tli = 0.0
        self.tli_seconds = 0.0
        self.dv_loi1 = 0.0
        self.loi1_seconds = 0.0
        self.dv_loi2 = 0.0
        self.loi2_seconds = 0.0
        self.dv_doi = 0.0
        self.doi_seconds = 0.0
        self.dv_descent = 0.0
        self.dv_hover = 0.0
        self.mass_after_tli = 0.0
        self.sivb_used = 0.0
        self.sivb_margin_kg = 0.0
        self.sivb_margin_dv = 0.0
        self.sps_used = 0.0
        self.sps_tei = 0.0
        self.sps_margin_kg = 0.0
        self.sps_margin_dv = 0.0
        self.dps_used = 0.0
        self.dps_margin_kg = 0.0
        self.dps_margin_s = 0.0
        self.red = List[String]()
        self.amber = List[String]()
        self.arc = List[Float64]()
        self.jde_tli = 0.0


def make_plan(eph: Ephemeris, wm: WindowMap, ch: Choices) -> PlanSheet:
    """The whole sheet from the choices. `wm` must be the map for the
    same pad, target, month and year."""
    var sheet = PlanSheet()
    var ch_tli_offset = T_TLI_REV2 + (T_PARK_PERIOD if ch.revs >= 3 else 0.0)
    sheet.tli_offset = ch_tli_offset
    sheet.tof = ch.tof_h * 3600.0
    sheet.jd_launch = julian_day(ch.year, ch.month, ch.day) + ch.hour / 24.0
    sheet.t_launch = wm.t_of(ch.day, ch.hour)

    # C6–C9, C17: the cell.
    var c = wm.cell_cpu(sheet.t_launch, sheet.tof)
    var fl = Int(c[F_FLAGS])
    sheet.azimuth = c[F_AZ]
    sheet.inclination = c[F_INC]
    sheet.corridor = fl & FLAG_CORRIDOR != 0
    sheet.sun_elev = c[F_SUN]
    sheet.sun_rising = fl & FLAG_RISING != 0
    sheet.lit = fl & FLAG_LIT != 0
    sheet.est_dv_tli = c[F_DV_TLI]
    sheet.est_dv_loi = c[F_DV_LOI]
    sheet.windows = corridor_windows(wm, ch.day, sheet.tof)
    sheet.plane = plane_normal(wm, sheet.t_launch, sheet.tof)

    # C10–C15: the transfer, targeted. The S-IVB lights at the offset; a
    # six-minute burn's impulse sits at its midpoint, and that is when the
    # physics injects. The burn's length is taken from the map's estimate
    # of the Δv, which is within a percent of the corrected value.
    sheet.jd_tli_ign = sheet.jd_launch + ch_tli_offset / 86400.0
    var tli_est_s = burn_seconds(burn_prop(STACK_AT_INSERTION, sheet.est_dv_tli * (1.0 + TLI_GRAVITY_LOSS), SIVB_ISP), SIVB_THRUST, SIVB_ISP)
    sheet.jd_tli = sheet.jd_tli_ign + 0.5 * tli_est_s / 86400.0
    sheet.jde_tli = jde_from_ut(sheet.jd_tli)
    var bodies = Bodies(eph, sheet.jde_tli, ch.tof_h / 24.0 + 3.8)
    var r_p = R_MOON + ch.peri_alt
    var z_moon = eph.moon_frame(sheet.jde_tli + sheet.tof / 86400.0).z
    sheet.site = landing_sites()[ch.target]
    sheet.apo_alt = ch.apo_alt
    sheet.desc_peri = ch.descent_peri
    sheet.hover_s = ch.hover_s
    # Where the site will be, on the sky, when the LM gets there: the
    # stay is measured from LOI-1's ignition, about half a burn before
    # perilune.
    var jd_land_est = sheet.jd_tli + (sheet.tof + T_STAY - 180.0) / 86400.0
    var site_dir = eph.moon_frame(jde_from_ut(jd_land_est)).to_inertial(sheet.site.lat, sheet.site.lon)
    if ch.orient == 1:
        sheet.transfer = plan_transfer_to_site(eph, bodies, sheet.plane, ch.park_alt, sheet.tof, r_p, site_dir, -z_moon, ch.apo_alt)
    else:
        sheet.transfer = plan_transfer(eph, bodies, sheet.plane, ch.park_alt, sheet.tof, r_p, True, ch.apo_alt)
    var a = sheet.transfer.correction.arrival
    sheet.target_pole = a.rho.cross(a.rho_dot).unit()
    sheet.inc_equator = acos(a.rho.cross(a.rho_dot).unit().dot(z_moon)) * RAD
    sheet.cross_range = asin(site_dir.dot(sheet.target_pole)) * R_MOON
    sheet.moon_dist = bodies.moon_at(sheet.tof).norm()
    sheet.ok = sheet.transfer.correction.converged

    # The arc, for the plot: from TLI to six hours past perilune.
    var inj = sheet.transfer.injection
    _ = bodies.run_recording(inj.r, sheet.transfer.correction.v, 0.0, a.t_p + 6.0 * 3600.0, 1024.0, F_ALL, sheet.arc)
    # And on, unburned, to see where the flyby brings the crew if the SPS
    # never lights: a perigee inside a few thousand kilometres is a free
    # return -- the RCS can trim that into the entry corridor.
    var ret = List[Float64]()
    _ = bodies.run_recording(inj.r, sheet.transfer.correction.v, 0.0, a.t_p + 3.2 * 86400.0, 1024.0, F_ALL, ret)
    var best = 1.0e30
    for i in range(len(ret) // 7):
        if ret[i * 7] > a.t_p:
            var rr = Vec3(ret[i * 7 + 1], ret[i * 7 + 2], ret[i * 7 + 3]).norm()
            if rr < best:
                best = rr
    sheet.return_perigee_alt = best - R_EARTH
    sheet.free_return = sheet.return_perigee_alt < 5000.0

    # The burns. LOI-2 circularises at the perilune; DOI lowers the
    # perilune from the circular orbit to the descent altitude.
    sheet.dv_tli = sheet.transfer.dv_tli
    sheet.dv_loi1 = sheet.transfer.loi_dv
    var ra = R_MOON + ch.apo_alt
    var a1 = 0.5 * (r_p + ra)
    sheet.dv_loi2 = sqrt(MU_MOON * (2.0 / r_p - 1.0 / a1)) - sqrt(MU_MOON / r_p)
    var r_d = R_MOON + ch.descent_peri
    var a2 = 0.5 * (r_p + r_d)
    sheet.dv_doi = sqrt(MU_MOON / r_p) - sqrt(MU_MOON * (2.0 / r_p - 1.0 / a2))
    sheet.dv_descent = DESCENT_BUDGET
    var hover_rate = DPS_HOVER_THRUST / (DPS_ISP * 9.80665)  # kg/s
    var hover_prop = hover_rate * ch.hover_s

    # Masses. C22: the rocket equation on what is being pushed.
    var dv_tli_burn = sheet.dv_tli * (1.0 + TLI_GRAVITY_LOSS)
    sheet.sivb_used = burn_prop(STACK_AT_INSERTION, dv_tli_burn, SIVB_ISP)
    sheet.tli_seconds = burn_seconds(sheet.sivb_used, SIVB_THRUST, SIVB_ISP)
    sheet.mass_after_tli = STACK_AT_INSERTION - sheet.sivb_used
    sheet.sivb_margin_kg = SIVB_PROP - sheet.sivb_used
    sheet.sivb_margin_dv = dv_of(sheet.mass_after_tli, sheet.sivb_margin_kg, SIVB_ISP) if sheet.sivb_margin_kg > 0.0 else -dv_of(sheet.mass_after_tli, -sheet.sivb_margin_kg, SIVB_ISP)

    var stack = CSM_MASS + LM_MASS
    var mcc = burn_prop(stack, MCC_BUDGET, SPS_ISP)
    var m1 = stack - mcc
    var loi1 = burn_prop(m1, sheet.dv_loi1, SPS_ISP)
    sheet.loi1_seconds = burn_seconds(loi1, SPS_THRUST, SPS_ISP)
    var m2 = m1 - loi1
    var loi2 = burn_prop(m2, sheet.dv_loi2, SPS_ISP)
    sheet.loi2_seconds = burn_seconds(loi2, SPS_THRUST, SPS_ISP)
    sheet.doi_seconds = burn_seconds(burn_prop(LM_MASS, sheet.dv_doi, DPS_ISP), DPS_THRUST * 0.4, DPS_ISP)
    sheet.sps_used = mcc + loi1 + loi2

    # The timeline: ignitions. The LOI-1 impulse is at perilune; the SPS
    # lights half a burn before it. The stay to touchdown and the later
    # events are measured from that ignition, as Apollo's were.
    sheet.jd_insertion = sheet.jd_launch + T_INSERTION / 86400.0
    sheet.jd_mcc2 = sheet.jd_tli + T_MCC2 / 86400.0
    sheet.jd_loi1 = sheet.jd_tli + a.t_p / 86400.0
    sheet.jd_loi1_ign = sheet.jd_loi1 - 0.5 * sheet.loi1_seconds / 86400.0
    sheet.jd_loi2 = sheet.jd_loi1_ign + T_LOI2 / 86400.0
    sheet.jd_landing = sheet.jd_loi1_ign + T_STAY / 86400.0
    sheet.jd_doi = sheet.jd_landing - T_DOI_BEFORE / 86400.0
    sheet.jd_pdi = sheet.jd_landing - T_PDI_BEFORE / 86400.0
    var csm_alone = CSM_MASS - sheet.sps_used
    sheet.sps_tei = burn_prop(csm_alone, TEI_RESERVE, SPS_ISP)
    sheet.sps_margin_kg = SPS_PROP - sheet.sps_used - sheet.sps_tei
    var csm_after_tei = csm_alone - sheet.sps_tei
    sheet.sps_margin_dv = dv_of(csm_after_tei, sheet.sps_margin_kg, SPS_ISP) if sheet.sps_margin_kg > 0.0 else -dv_of(csm_after_tei, -sheet.sps_margin_kg, SPS_ISP)

    var doi = burn_prop(LM_MASS, sheet.dv_doi, DPS_ISP)
    var desc = burn_prop(LM_MASS - doi, sheet.dv_descent, DPS_ISP)
    sheet.dps_used = doi + desc + hover_prop
    sheet.dv_hover = dv_of(LM_MASS - doi - desc, hover_prop, DPS_ISP)
    sheet.dps_margin_kg = DPS_PROP - sheet.dps_used
    sheet.dps_margin_s = sheet.dps_margin_kg / hover_rate

    # The lines. Red is a rule; amber is a margin the rules would rather
    # were larger.
    if not sheet.corridor:
        sheet.red.append(String("azimuth ") + fmt(sheet.azimuth, 1) + "° outside the corridor")
    if not sheet.lit:
        sheet.red.append(String("site Sun ") + fmt(sheet.sun_elev, 1) + "°, outside 5–14°")
    elif not sheet.sun_rising:
        sheet.red.append(String("site in evening light, not morning"))
    if not sheet.ok:
        sheet.red.append(String("transfer did not converge"))
    if sheet.sivb_margin_kg < 0.0:
        sheet.red.append(String("S-IVB short by ") + fmt(-sheet.sivb_margin_kg, 0) + " kg")
    elif sheet.sivb_margin_dv < 0.020:
        sheet.amber.append(String("S-IVB margin ") + fmt(sheet.sivb_margin_dv * 1000.0, 0) + " m/s")
    if sheet.sps_margin_kg < 0.0:
        sheet.red.append(String("SPS short by ") + fmt(-sheet.sps_margin_kg, 0) + " kg with TEI kept")
    elif sheet.sps_margin_dv < 0.150:
        sheet.amber.append(String("SPS margin ") + fmt(sheet.sps_margin_dv * 1000.0, 0) + " m/s")
    if sheet.dps_margin_kg < 0.0:
        sheet.red.append(String("DPS short by ") + fmt(-sheet.dps_margin_kg, 0) + " kg")
    elif sheet.dps_margin_s < 30.0:
        sheet.amber.append(String("DPS margin ") + fmt(sheet.dps_margin_s, 0) + " s of hover")
    if not a.far_side:
        sheet.red.append(String("perilune on the near side: LOI in view, no free return"))
    var cr = sheet.cross_range if sheet.cross_range >= 0.0 else -sheet.cross_range
    if cr > 20.0:
        sheet.red.append(String("site ") + fmt(cr, 0) + " km from the orbit plane at landing")
    elif cr > 5.0:
        sheet.amber.append(String("site ") + fmt(cr, 1) + " km off the plane at landing")
    if ch.revs > 3:
        sheet.red.append(String("S-IVB cannot restart after revolution 3"))
    return sheet^


def is_go(sheet: PlanSheet) -> Bool:
    return sheet.ok and len(sheet.red) == 0


def get_string(jd: Float64, jd_launch: Float64) -> String:
    """Ground elapsed time, hhh:mm:ss."""
    var s = (jd - jd_launch) * 86400.0
    var neg = s < 0.0
    if neg:
        s = -s
    var h = Int(s / 3600.0)
    s -= Float64(h) * 3600.0
    var m = Int(s / 60.0)
    s -= Float64(m) * 60.0
    var sec = Int(s + 0.5)
    if sec == 60:
        sec = 0
        m += 1
    if m == 60:
        m = 0
        h += 1
    var out = String("-") if neg else String("")
    out += (String("00") if h < 10 else (String("0") if h < 100 else String(""))) + String(h) + ":"
    out += (String("0") if m < 10 else String("")) + String(m) + ":"
    out += (String("0") if sec < 10 else String("")) + String(sec)
    return out


def utc_string(jd: Float64) -> String:
    """'Jul 16 13:32'."""
    var c = civil(jd + 0.5 / 86400.0)
    var names = List[String]()
    for n in ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]:
        names.append(String(n))
    var s = names[c.month - 1] + " " + (String("0") if c.day < 10 else String("")) + String(c.day) + " "
    s += (String("0") if c.hour < 10 else String("")) + String(c.hour) + ":"
    s += (String("0") if c.minute < 10 else String("")) + String(c.minute)
    return s


def utc_short(jd: Float64) -> String:
    """'16 13:32': the day and the time, for a column whose month is known."""
    var c = civil(jd + 0.5 / 86400.0)
    var s = (String("0") if c.day < 10 else String("")) + String(c.day) + " "
    s += (String("0") if c.hour < 10 else String("")) + String(c.hour) + ":"
    s += (String("0") if c.minute < 10 else String("")) + String(c.minute)
    return s


def mcc_threshold(policy: Int) -> Float64:
    """km/s: the smallest correction the policy bothers to burn."""
    if policy == 0:
        return 0.0003
    if policy == 1:
        return 0.001
    if policy == 2:
        return 0.003
    if policy == 3:
        return 1.0e9  # never: the plan as the S-IVB left it
    return 0.001  # call each one: the threshold is not consulted
