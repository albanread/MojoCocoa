# ===----------------------------------------------------------------------=== #
# Moonshot — the mission in flight (sprint MC5).
#
# The plan was a sheet; this is the sheet happening. `Mission` owns the
# clock and the truth: the spacecraft's state, on the parking orbit by
# Kepler's closed form and from TLI onward by the same integrator the
# plan was made with; the burns, executed at the sheet's times as the
# impulses the sheet promised; the three MSFN stations, each asking every
# ten seconds of flight whether it can see the spacecraft above its own
# horizon and not behind the Moon; and the log of what happened when.
#
# Nothing here decides anything. The dispersions that make the crew's
# flight differ from the trench's plan are MC6's; here the flown course
# reproduces the planned one, and the difference between them -- shown
# on the screen in kilometres -- should read zero, which is the check
# that the mission and the plan are the same physics.
#
# Ground elapsed time (GET) is seconds since liftoff; the ephemeris table
# is epoch-ed a day before TLI so the parking orbit has a Moon to look at.
# ===----------------------------------------------------------------------=== #

from std.math import sqrt, asin, acos, atan2, sin, cos, log
from astro import *
from orbit import *
from transfer import *
from plan import *
from cloud import *
from lunar import *
from descent import *

comptime PHASE_PRELAUNCH = 0
comptime PHASE_PARKING = 1
comptime PHASE_TRANSLUNAR = 2
comptime PHASE_LUNAR_ORBIT = 3
comptime PHASE_DESCENT_ORBIT = 4
comptime PHASE_DESCENT = 5
comptime PHASE_RETURN = 6
comptime PHASE_DONE = 7

comptime EV_INSERTION = 0
comptime EV_TLI = 1
comptime EV_MCC = 2
comptime EV_LOI1 = 3
comptime EV_LOI2 = 4
comptime EV_DOI = 5
comptime EV_PDI = 6
comptime EV_SPS_CHECK = 7
comptime EV_PC2 = 8

comptime DEC_NONE = 0
comptime DEC_MCC = 1
"""A decision the trench owes the crew: the mission holds until it comes."""

comptime SUBSTEP = 300.0
"""Seconds of GET between looks at the sky: contact, events, the track.
Between looks the integrator takes its own steps, as the plan did; near
the Moon those are seconds, which is where LOS and AOS are decided."""


def phase_name(p: Int) -> String:
    if p == PHASE_PRELAUNCH:
        return String("ON THE PAD")
    if p == PHASE_PARKING:
        return String("PARKING ORBIT")
    if p == PHASE_TRANSLUNAR:
        return String("TRANSLUNAR COAST")
    if p == PHASE_LUNAR_ORBIT:
        return String("LUNAR ORBIT")
    if p == PHASE_DESCENT_ORBIT:
        return String("DESCENT ORBIT")
    if p == PHASE_DESCENT:
        return String("POWERED DESCENT")
    if p == PHASE_RETURN:
        return String("RETURNING")
    return String("MISSION OVER")


@fieldwise_init
struct Event(ImplicitlyCopyable, Movable):
    var kind: Int
    var name: String
    var get: Float64  # s: ignition for a burn, the instant otherwise
    var dv: Float64  # km/s, planned
    var seconds: Float64  # burn length; 0 for an impulse or a note
    var done: Bool


comptime P_SPS_CARD = 0.04
comptime P_ALARM = 0.35
comptime P_ALARM_RECURS = 0.2
comptime P_RADAR_FAIL = 0.05


@fieldwise_init
struct Cards(ImplicitlyCopyable, Movable):
    """The mission's anomalies, drawn once from their own generator so a
    seed's dispersions stay what they were before the cards existed."""

    var sps: Bool  # the SPS is not to be trusted for LOI
    var alarm: Bool  # a program alarm in the braking phase
    var alarm_recurs: Bool  # and again, which the rule cannot accept
    var radar_fail: Bool  # the landing radar never locks


def draw_cards(seed: Int) -> Cards:
    var rng = Rng(UInt64(seed) * 7919 + 17)
    var sps = rng.next() < P_SPS_CARD
    var alarm = rng.next() < P_ALARM
    var recurs = alarm and rng.next() < P_ALARM_RECURS
    var radar = rng.next() < P_RADAR_FAIL
    return Cards(sps, alarm, recurs, radar)


@fieldwise_init
struct Contact(ImplicitlyCopyable, Movable):
    """One station's view of the spacecraft."""

    var elevation: Float64  # degrees above the station's horizon
    var occulted: Bool  # the Moon is in the way
    var visible: Bool


def station_contact(name_index: Int, jd_ut: Float64, r_sc: Vec3, moon: Vec3) -> Contact:
    """Elevation of the spacecraft from an MSFN station, and whether the
    Moon's disc lies on the line between them."""
    var st = stations()[name_index]
    var p = site_position(st.lat, st.lon, jd_ut)
    var up = p.unit()
    var d = r_sc - p
    var dn = d.norm()
    var dhat = d * (1.0 / dn)
    var elev = asin(dhat.dot(up)) * RAD
    var along = (moon - p).dot(dhat)
    var occulted = False
    if along > 0.0 and along < dn:
        var closest = p + dhat * along
        occulted = (closest - moon).norm() < R_MOON
    return Contact(elev, occulted, elev > 0.0 and not occulted)


struct Mission(Movable):
    var eph: Ephemeris
    var rng: Rng
    var seed: Int
    var jd_launch: Float64
    var tli_offset: Float64
    var bodies: Bodies  # epoch: a day before TLI
    var tab0: Float64  # GET at the table's epoch
    var r_inj: Vec3
    var v_park: Vec3
    var v_tli: Vec3
    var events: List[Event]
    var arc: List[Float64]  # the planned arc, (t from TLI, x, y, z, vx, vy, vz)
    var get: Float64
    var phase: Int
    var r: Vec3  # the truth
    var v: Vec3
    var est_r: Vec3  # what tracking says
    var est_v: Vec3
    var err_r: Vec3  # the estimate's error, redrawn as the arc grows
    var err_v: Vec3
    var err_drawn_at: Float64
    var warp: Float64
    var paused: Bool
    var track: List[Float64]  # (get, x, y, z) every minute of flight
    var last_sample: Float64
    var contact: List[Contact]
    var in_contact: Bool
    var log: List[String]
    var los_aos: List[Float64]  # pairs: LOS get, AOS get (AOS = -1 while behind)
    var divergence: Float64  # km, the estimate against the plan
    # the targets the trench holds, and what it knows
    var target_r_p: Float64
    var target_t_p: Float64  # table seconds
    var target_pole: Vec3
    var apo_alt: Float64
    var mcc_threshold: Float64
    var manual_mcc: Bool  # the trench calls each correction itself
    var pending_kind: Int
    var pending_name: String
    var pending_dv: Vec3  # the correction on the board
    var pending_need: Float64
    var pending_ok: Bool
    var loi1_seconds: Float64
    var mcc_total: Float64  # km/s spent on corrections
    var truth_perilune_alt: Float64  # km, known once LOI-1 is lit
    var truth_perilune_get: Float64
    var sps_kg: Float64  # SPS propellant left, with the loading error
    var tli_error: Float64  # m/s, the S-IVB's actual miss, for the debrief
    var site: Site
    var desc_peri: Float64
    var cross_range: Float64  # km, at the landing pass tracking found
    var t_land: Float64  # GET of touchdown as planned from the pass
    var t_cross: Float64  # GET the orbit crosses the site
    var landing_planned: Bool
    var no_pass: Bool
    var hover_s: Float64
    var descent: Descent
    var descending: Bool
    var pdi_get: Float64  # the descent's clock starts here
    var outcome: String
    var dps_kg: Float64
    var cards: Cards
    var loi_off: Bool  # the trench has called off LOI: the flyby comes home
    var loi_off_reason: String
    var min_r_after_pc2: Float64
    var pc2_done: Bool
    var return_dv: Float64  # km/s, the DPS burn home, if any
    var outcome_reason: String
    var perfect: Bool  # no errors at all: the plan as flown by a perfect vehicle (tests)

    def __init__(out self, eph: Ephemeris, sheet: PlanSheet, seed: Int):
        self.eph = Ephemeris()
        self.rng = Rng(UInt64(seed))
        self.seed = seed
        self.jd_launch = sheet.jd_launch
        # The plan's epoch is the TLI impulse, mid-burn; everything here
        # is measured from it.
        self.tli_offset = (sheet.jd_tli - sheet.jd_launch) * 86400.0
        self.tab0 = self.tli_offset - 86400.0
        var days = (sheet.jd_landing - sheet.jd_tli) + 3.0
        self.bodies = Bodies(eph, sheet.jde_tli - 1.0, days)
        self.r_inj = sheet.transfer.injection.r
        self.v_park = sheet.transfer.injection.v_park
        self.v_tli = sheet.transfer.correction.v
        self.events = List[Event]()
        var t0 = sheet.jd_launch
        # TLI is the one impulse: the parking orbit is defined to put the
        # spacecraft at the injection point at the burn's midpoint. The
        # lunar burns are flown as they were, over their seconds. The four
        # correction opportunities are Apollo's: TLI + 9 h, TLI + 24 h,
        # LOI − 22 h, LOI − 5 h.
        var tli_get = (sheet.jd_tli - t0) * 86400.0
        var loi_get = (sheet.jd_loi1 - t0) * 86400.0
        self.events.append(Event(EV_INSERTION, String("orbit"), (sheet.jd_insertion - t0) * 86400.0, 0.0, 0.0, False))
        self.events.append(Event(EV_TLI, String("TLI"), tli_get, sheet.dv_tli, 0.0, False))
        self.events.append(Event(EV_SPS_CHECK, String("SPS chk"), tli_get + 6.0 * 3600.0, 0.0, 0.0, False))
        self.events.append(Event(EV_MCC, String("MCC-1"), tli_get + 9.0 * 3600.0, 0.0, 0.0, False))
        self.events.append(Event(EV_MCC, String("MCC-2"), tli_get + 24.0 * 3600.0, 0.0, 0.0, False))
        self.events.append(Event(EV_MCC, String("MCC-3"), loi_get - 22.0 * 3600.0, 0.0, 0.0, False))
        self.events.append(Event(EV_MCC, String("MCC-4"), loi_get - 5.0 * 3600.0, 0.0, 0.0, False))
        self.events.append(Event(EV_LOI1, String("LOI-1"), (sheet.jd_loi1_ign - t0) * 86400.0, sheet.dv_loi1, sheet.loi1_seconds, False))
        self.events.append(Event(EV_LOI2, String("LOI-2"), (sheet.jd_loi2 - t0) * 86400.0, sheet.dv_loi2, sheet.loi2_seconds, False))
        self.events.append(Event(EV_DOI, String("DOI"), (sheet.jd_doi - t0) * 86400.0, sheet.dv_doi, sheet.doi_seconds, False))
        self.events.append(Event(EV_PDI, String("PDI"), (sheet.jd_pdi - t0) * 86400.0, 0.0, 0.0, False))
        self.arc = List[Float64]()
        for i in range(len(sheet.arc)):
            self.arc.append(sheet.arc[i])
        self.get = 0.0
        self.phase = PHASE_PRELAUNCH
        self.r = Vec3(0.0, 0.0, 0.0)
        self.v = Vec3(0.0, 0.0, 0.0)
        self.est_r = self.r
        self.est_v = self.v
        self.err_r = Vec3(0.0, 0.0, 0.0)
        self.err_v = Vec3(0.0, 0.0, 0.0)
        self.err_drawn_at = -1.0e9
        self.warp = 1.0
        self.paused = False
        self.track = List[Float64]()
        self.last_sample = -1.0e9
        self.contact = List[Contact]()
        for _ in range(3):
            self.contact.append(Contact(0.0, False, False))
        self.in_contact = False
        self.log = List[String]()
        self.los_aos = List[Float64]()
        self.divergence = 0.0
        self.target_r_p = sheet.transfer.correction.arrival.r_p
        self.target_t_p = loi_get - self.tab0
        self.target_pole = sheet.target_pole
        self.apo_alt = sheet.apo_alt
        self.mcc_threshold = 0.001
        self.manual_mcc = False
        self.pending_kind = DEC_NONE
        self.pending_name = String("")
        self.pending_dv = Vec3(0.0, 0.0, 0.0)
        self.pending_need = 0.0
        self.pending_ok = False
        self.loi1_seconds = sheet.loi1_seconds
        self.mcc_total = 0.0
        self.truth_perilune_alt = 0.0
        self.truth_perilune_get = 0.0
        self.sps_kg = SPS_PROP * (1.0 + self.rng.gauss() * PROP_SIGMA)
        self.tli_error = 0.0
        self.site = sheet.site
        self.desc_peri = sheet.desc_peri
        self.cross_range = 0.0
        self.t_land = (sheet.jd_landing - sheet.jd_launch) * 86400.0
        self.t_cross = self.t_land
        self.landing_planned = False
        self.no_pass = False
        self.hover_s = sheet.hover_s
        self.dps_kg = DPS_PROP * (1.0 + self.rng.gauss() * PROP_SIGMA)
        self.descent = Descent(Vec3(R_MOON + 15.0, 0.0, 0.0), Vec3(0.0, 1.7, 0.0), Vec3(1.0, 0.0, 0.0), Vec3(0.0, 0.0, 1.0), LM_MASS, DPS_PROP, 60.0, Terrain(0.0, 0.0, False), Vec3(0.0, 0.0, 0.0), 9000.0)
        self.descending = False
        self.pdi_get = 0.0
        self.outcome = String("")
        self.cards = draw_cards(seed)
        self.loi_off = False
        self.loi_off_reason = String("")
        self.min_r_after_pc2 = 1.0e30
        self.pc2_done = False
        self.return_dv = 0.0
        self.outcome_reason = String("")
        self.perfect = False
        self.place()
        self.look()

    def jd(self) -> Float64:
        return self.jd_launch + self.get / 86400.0

    def t_tab(self) -> Float64:
        """The ephemeris table's time for the current GET."""
        return self.get - self.tab0

    def moon(self) -> Vec3:
        return self.bodies.moon_at(self.t_tab())

    def moon_v(self) -> Vec3:
        var t = self.t_tab()
        return (self.bodies.moon_at(t + 30.0) - self.bodies.moon_at(t - 30.0)) * (1.0 / 60.0)

    def place(mut self):
        """The state at the current GET in the phases Kepler covers."""
        if self.phase == PHASE_PRELAUNCH:
            var pad = launch_sites()[0]
            self.r = site_position(pad.lat, pad.lon, self.jd())
            self.v = site_velocity(self.r)
        elif self.phase == PHASE_PARKING:
            var k = kepler(self.r_inj, self.v_park, self.get - self.tli_offset, MU_EARTH)
            self.r = k.r
            self.v = k.v

    def contact_any(self, get: Float64, r: Vec3) -> Bool:
        """Does any station see the spacecraft at r at that GET?"""
        var m = self.bodies.moon_at(get - self.tab0)
        var jd = self.jd_launch + get / 86400.0
        for i in range(3):
            if station_contact(i, jd, r, m).visible:
                return True
        return False

    def look(mut self):
        """Every station's view and the contact flag, now -- and the one
        thing the point-mass Moon cannot tell the integrator: that it has
        a surface."""
        var m = self.moon()
        if self.phase >= PHASE_TRANSLUNAR and self.phase != PHASE_DESCENT and self.phase != PHASE_DONE:
            var rho = (self.r - m).norm()
            if rho < R_MOON:
                var speed = (self.v - self.moon_v()).norm()
                self.outcome = String("LOST")
                self.outcome_reason = String("struck the Moon at ") + fmt(speed, 2) + " km/s"
                self.log.append(get_string(self.jd(), self.jd_launch) + "  LOST: " + self.outcome_reason)
                self.phase = PHASE_DONE
                return
        var any = False
        for i in range(3):
            self.contact[i] = station_contact(i, self.jd(), self.r, m)
            if self.contact[i].visible:
                any = True
        self.in_contact = any

    def state_at(self, r0: Vec3, v0: Vec3, g0: Float64, t: Float64) -> RVd:
        """The state at t, from a known state at g0, by the phase's physics."""
        if self.phase == PHASE_TRANSLUNAR or self.phase == PHASE_LUNAR_ORBIT or self.phase == PHASE_DESCENT_ORBIT or self.phase == PHASE_RETURN:
            return self.bodies.run(r0, v0, g0 - self.tab0, t - self.tab0, 1024.0, F_ALL)
        if self.phase == PHASE_PARKING:
            return kepler(self.r_inj, self.v_park, t - self.tli_offset, MU_EARTH)
        var pad = launch_sites()[0]
        var pr = site_position(pad.lat, pad.lon, self.jd_launch + t / 86400.0)
        return RVd(pr, site_velocity(pr))

    def note_transition(mut self, r0: Vec3, v0: Vec3, g0: Float64, was: Bool):
        """Contact changed between g0 and now: find the second it did, by
        bisection from the state at g0, and log it."""
        var lo = g0
        var hi = self.get
        var rl = r0
        var vl = v0
        for _ in range(12):
            var mid = 0.5 * (lo + hi)
            var st = self.state_at(rl, vl, lo, mid)
            if self.contact_any(mid, st.r) == was:
                lo = mid
                rl = st.r
                vl = st.v
            else:
                hi = mid
        var stamp = get_string(self.jd_launch + hi / 86400.0, self.jd_launch)
        if was:
            self.los_aos.append(hi)
            self.los_aos.append(-1.0)
            self.log.append(stamp + "  LOS")
        else:
            if len(self.los_aos) >= 2 and self.los_aos[len(self.los_aos) - 1] < 0.0:
                self.los_aos[len(self.los_aos) - 1] = hi
            self.log.append(stamp + "  AOS")

    def planned_at(self, t_from_tli: Float64) -> Vec3:
        """The planned arc between its samples, by cubic Hermite on the
        recorded positions and velocities: a chord between samples a
        thousand seconds apart sags a few hundred metres off a curved
        path, and the divergence readout must not report that."""
        var n = len(self.arc) // 7
        if n == 0:
            return self.r
        if t_from_tli <= self.arc[0]:
            return Vec3(self.arc[1], self.arc[2], self.arc[3])
        for i in range(1, n):
            if self.arc[i * 7] >= t_from_tli:
                var t0 = self.arc[(i - 1) * 7]
                var t1 = self.arc[i * 7]
                var h = t1 - t0
                if h <= 0.0:
                    return Vec3(self.arc[i * 7 + 1], self.arc[i * 7 + 2], self.arc[i * 7 + 3])
                var u = (t_from_tli - t0) / h
                var p0 = Vec3(self.arc[(i - 1) * 7 + 1], self.arc[(i - 1) * 7 + 2], self.arc[(i - 1) * 7 + 3])
                var v0 = Vec3(self.arc[(i - 1) * 7 + 4], self.arc[(i - 1) * 7 + 5], self.arc[(i - 1) * 7 + 6])
                var p1 = Vec3(self.arc[i * 7 + 1], self.arc[i * 7 + 2], self.arc[i * 7 + 3])
                var v1 = Vec3(self.arc[i * 7 + 4], self.arc[i * 7 + 5], self.arc[i * 7 + 6])
                var u2 = u * u
                var u3 = u2 * u
                var h00 = 2.0 * u3 - 3.0 * u2 + 1.0
                var h10 = u3 - 2.0 * u2 + u
                var h01 = -2.0 * u3 + 3.0 * u2
                var h11 = u3 - u2
                return p0 * h00 + v0 * (h10 * h) + p1 * h01 + v1 * (h11 * h)
        return Vec3(self.arc[(n - 1) * 7 + 1], self.arc[(n - 1) * 7 + 2], self.arc[(n - 1) * 7 + 3])

    def event_index(self, kind: Int) -> Int:
        """The first event of that kind, or -1."""
        for i in range(len(self.events)):
            if self.events[i].kind == kind:
                return i
        return -1

    def next_event(self) -> Int:
        for i in range(len(self.events)):
            if not self.events[i].done:
                return i
        return -1

    def redraw_tracking(mut self):
        """A fresh error for the estimate, smaller the longer tracking has
        watched the arc."""
        var hours = (self.get - self.tli_offset) / 3600.0
        if hours < 0.0:
            hours = 0.0
        var f = 0.0 if self.perfect else 1.0 / sqrt(1.0 + hours / 12.0)
        self.err_r = Vec3(self.rng.gauss(), self.rng.gauss(), self.rng.gauss()) * (TRACK_POS_SIGMA * f)
        self.err_v = Vec3(self.rng.gauss(), self.rng.gauss(), self.rng.gauss()) * (TRACK_VEL_SIGMA * f)
        self.err_drawn_at = self.get

    def update_estimate(mut self):
        if self.phase >= PHASE_TRANSLUNAR:
            if self.get - self.err_drawn_at > 6.0 * 3600.0:
                self.redraw_tracking()
            self.est_r = self.r + self.err_r
            self.est_v = self.v + self.err_v
        else:
            self.est_r = self.r
            self.est_v = self.v

    def midcourse(mut self, name: String):
        """A correction opportunity. The corrector says, from the ESTIMATE,
        what burn would put the perilune back on target; who decides
        whether to make it depends on the policy. Under a rule the number
        decides. Set to call each one, the mission HOLDS here -- the
        decision is the trench's, and `resolve_mcc` is the answer."""
        self.update_estimate()
        var t_now = self.get - self.tab0
        var stamp = get_string(self.jd(), self.jd_launch) + "  "
        var corr = correct(self.bodies, self.eph, self.est_r, self.est_v, Target(self.target_r_p, self.target_t_p, self.target_pole), t_now, self.target_t_p + 6.0 * 3600.0)
        self.pending_name = name
        self.pending_dv = corr.v - self.est_v
        self.pending_need = self.pending_dv.norm()
        self.pending_ok = corr.converged
        if not corr.converged:
            self.log.append(stamp + name + ": no convergence")
            self.apply_mcc(False)
            return
        if self.manual_mcc:
            self.pending_kind = DEC_MCC
            self.paused = True
            self.log.append(stamp + name + ": " + fmt(self.pending_need * 1000.0, 1) + " m/s on the board")
            return
        self.apply_mcc(self.pending_need >= self.mcc_threshold)

    def resolve_mcc(mut self, burn: Bool):
        """Burn it or hold: the answer to a correction the trench was
        asked about. Ignored when nothing is on the board."""
        if self.pending_kind != DEC_MCC:
            return
        self.pending_kind = DEC_NONE
        self.paused = False
        self.apply_mcc(burn)

    def apply_mcc(mut self, burn: Bool):
        """Make the pending correction, or let it stand; then, at the last
        opportunity, the LOI-1 solution from what tracking now says."""
        var name = self.pending_name
        var need = self.pending_need
        var t_now = self.get - self.tab0
        var stamp = get_string(self.jd(), self.jd_launch) + "  "
        var est_after = self.est_v
        if not self.pending_ok:
            pass
        elif burn:
            var flown = self.pending_dv if self.perfect else perturb_burn(self.rng, self.pending_dv, MCC_MAG_SIGMA, MCC_POINT_SIGMA)
            self.v = self.v + flown
            est_after = self.est_v + self.pending_dv
            self.mcc_total += need
            self.sps_kg -= burn_prop(CSM_MASS + LM_MASS, need, SPS_ISP)
            self.log.append(stamp + name + " " + fmt(need * 1000.0, 1) + " m/s burned")
        elif self.manual_mcc:
            self.log.append(stamp + name + " " + fmt(need * 1000.0, 1) + " m/s: held, our call")
        elif self.mcc_threshold > 1.0:
            self.log.append(stamp + name + " " + fmt(need * 1000.0, 1) + " m/s: no correction policy")
        else:
            self.log.append(stamp + name + " " + fmt(need * 1000.0, 1) + " < " + fmt(self.mcc_threshold * 1000.0, 1) + " m/s: held")
        if name == "MCC-4":
            # The LOI-1 solution, from what tracking now says: ignition
            # second and Δv of the finite burn that makes the intended orbit.
            var k = self.event_index(EV_LOI1)
            var ev = self.events[k]
            var look_ahead = arrival(self.bodies, self.eph, self.est_r, est_after, t_now, self.target_t_p + 6.0 * 3600.0)
            var peri_alt = look_ahead.r_p - R_MOON
            if peri_alt < CORRIDOR_LO or peri_alt > CORRIDOR_HI:
                self.loi_off = True
                self.loi_off_reason = String("perilune ") + fmt(peri_alt, 0) + " km, outside the corridor"
                self.log.append(stamp + "NO LOI: perilune " + fmt(peri_alt, 0) + " km, flyby")
                return
            var sol = target_loi(self.bodies, self.est_r, est_after, t_now, ev.get - self.tab0, ev.dv, ev.seconds, self.target_r_p - R_MOON, self.apo_alt)
            if not sol.converged:
                self.loi_off = True
                self.loi_off_reason = String("no LOI solution from a ") + fmt(peri_alt, 0) + " km perilune"
                self.log.append(stamp + "NO LOI: no burn makes the orbit from here, flyby")
                return
            if sol.converged:
                var shift = sol.t_ign + self.tab0 - ev.get
                self.events[k].get = sol.t_ign + self.tab0
                self.events[k].dv = sol.dv
                self.log.append(stamp + "LOI-1 sol " + fmt(shift, 0) + " s, " + fmt(sol.dv * 1000.0, 0) + " m/s, " + fmt(sol.peri_alt, 0) + "x" + fmt(sol.apo_alt, 0))

    def plan_landing(mut self):
        """From the circular orbit tracking reports: the pass over the
        site, and DOI and PDI placed for it."""
        var t_now = self.get - self.tab0
        var stamp = get_string(self.jd(), self.jd_launch) + "  "
        var pass_ = site_pass(self.eph, self.bodies, self.est_r, self.est_v, t_now, t_now + 30.0 * 3600.0, self.site.lat, self.site.lon, 20.0)
        var el = moon_orbit(self.bodies, self.est_r, self.est_v, t_now)
        var circ_alt = el.a - R_MOON
        if pass_.found:
            self.cross_range = pass_.cross_km
            self.t_cross = pass_.t + self.tab0
            var dp = plan_descent(circ_alt, self.desc_peri, pass_.t)
            self.t_land = dp.t_land + self.tab0
            for k in range(len(self.events)):
                if self.events[k].kind == EV_DOI:
                    self.events[k].get = dp.t_doi + self.tab0
                    self.events[k].dv = dp.dv_doi
                if self.events[k].kind == EV_PDI:
                    self.events[k].get = dp.t_pdi + self.tab0
            self.landing_planned = True
            self.log.append(stamp + "pass " + get_string(self.jd_launch + self.t_cross / 86400.0, self.jd_launch) + " site " + fmt(pass_.cross_km, 1) + " km")
            self.log.append(stamp + "touchdown planned " + get_string(self.jd_launch + self.t_land / 86400.0, self.jd_launch))
            self.log.append(stamp + "DOI " + get_string(self.jd_launch + (dp.t_doi + self.tab0) / 86400.0, self.jd_launch) + " " + fmt(dp.dv_doi * 1000.0, 0) + " m/s")
            self.log.append(stamp + "PDI " + get_string(self.jd_launch + (dp.t_pdi + self.tab0) / 86400.0, self.jd_launch))
        else:
            self.no_pass = True
            self.cross_range = pass_.cross_km
            self.log.append(stamp + "NO PASS: site " + fmt(pass_.cross_km, 0) + " km off")

    def execute(mut self, i: Int):
        """A burn, at its moment, as the impulse the sheet promised."""
        var ev = self.events[i]
        var stamp = get_string(self.jd(), self.jd_launch) + "  "
        if ev.kind == EV_INSERTION:
            self.phase = PHASE_PARKING
            self.place()
            self.log.append(stamp + "orbit insertion, 185 km")
        elif ev.kind == EV_TLI:
            # The S-IVB does what it does: the planned Δv with its cutoff
            # and pointing errors. The trench learns of it only through
            # tracking.
            self.r = self.r_inj
            var planned = self.v_tli - self.v_park
            var flown = planned if self.perfect else perturb_burn(self.rng, planned, TLI_MAG_SIGMA, TLI_POINT_SIGMA)
            self.v = self.v_park + flown
            self.tli_error = (flown - planned).norm() * 1000.0
            self.phase = PHASE_TRANSLUNAR
            self.redraw_tracking()
            self.log.append(stamp + "TLI  " + fmt(ev.dv * 1000.0, 0) + " m/s")
        elif ev.kind == EV_SPS_CHECK:
            if self.cards.sps and not self.perfect:
                self.loi_off = True
                self.loi_off_reason = String("SPS chamber pressure low")
                self.log.append(stamp + "SPS chamber pressure low: LOI is OFF")
            else:
                self.log.append(stamp + "SPS telemetry nominal")
        elif ev.kind == EV_PC2:
            self.plan_return()
        elif ev.kind == EV_MCC:
            self.midcourse(ev.name)
        elif (ev.kind == EV_LOI1 or ev.kind == EV_LOI2 or ev.kind == EV_DOI) and self.loi_off:
            if ev.kind == EV_LOI1:
                self.log.append(stamp + "LOI-1 not performed: flyby (" + self.loi_off_reason + ")")
                self.phase = PHASE_RETURN
                var t_p = self.get + 0.5 * ev.seconds
                self.events.append(Event(EV_PC2, String("PC+2"), t_p + 2.0 * 3600.0, 0.0, 0.0, False))
        elif ev.kind == EV_PDI and self.loi_off:
            pass
        elif ev.kind == EV_LOI1 or ev.kind == EV_LOI2 or ev.kind == EV_DOI:
            if ev.kind == EV_LOI1:
                var truth = arrival(self.bodies, self.eph, self.r, self.v, self.get - self.tab0, self.get - self.tab0 + 3600.0)
                self.truth_perilune_alt = truth.r_p - R_MOON
                self.truth_perilune_get = truth.t_p + self.tab0
                self.log.append(stamp + "perilune " + fmt(self.truth_perilune_alt, 1) + " km " + get_string(self.jd_launch + self.truth_perilune_get / 86400.0, self.jd_launch))
            self.log.append(stamp + ev.name + " ign " + fmt(ev.dv * 1000.0, 0) + " m/s, " + fmt(ev.seconds, 0) + " s")
            if ev.kind != EV_DOI:
                self.sps_kg -= burn_prop(CSM_MASS + LM_MASS, ev.dv, SPS_ISP)
            else:
                self.dps_kg -= burn_prop(LM_MASS, ev.dv, DPS_ISP)
            var b = finite_burn(self.bodies, self.r, self.v, self.get - self.tab0, ev.seconds, ev.dv)
            self.r = b.r
            self.v = b.v
            self.get = b.t_end + self.tab0
            self.update_estimate()
            var el = moon_orbit(self.bodies, self.r, self.v, self.get - self.tab0)
            var period = 2.0 * 3.141592653589793 * sqrt(el.a * el.a * el.a / MU_MOON)
            self.log.append(get_string(self.jd(), self.jd_launch) + "  " + ev.name + " cut " + fmt(el.a * (1.0 - el.e) - R_MOON, 0) + "x" + fmt(el.a * (1.0 + el.e) - R_MOON, 0) + " km " + fmt(period / 60.0, 1) + " min")
            if ev.kind == EV_LOI1:
                self.phase = PHASE_LUNAR_ORBIT
                # LOI-2 at the second perilune after this burn, as tracking
                # will find it, circularising at the perilune it finds.
                var t_now = self.get - self.tab0
                var t1 = next_perilune(self.bodies, self.eph, self.est_r, self.est_v, t_now, 1.2 * period)
                var s1 = self.bodies.run(self.est_r, self.est_v, t_now, t1 + 60.0, 1024.0, F_ALL)
                var t2 = next_perilune(self.bodies, self.eph, s1.r, s1.v, t1 + 60.0, 1.2 * period)
                var e2 = moon_orbit(self.bodies, self.est_r, self.est_v, t_now)
                var rp = e2.a * (1.0 - e2.e)
                var dv2 = sqrt(MU_MOON * (2.0 / rp - 1.0 / e2.a)) - sqrt(MU_MOON / rp)
                for k in range(len(self.events)):
                    if self.events[k].kind == EV_LOI2:
                        self.events[k].get = t2 + self.tab0 - 0.5 * self.events[k].seconds
                        self.events[k].dv = dv2
                self.log.append(String("           LOI-2 set ") + get_string(self.jd_launch + (t2 + self.tab0) / 86400.0, self.jd_launch) + " " + fmt(dv2 * 1000.0, 0) + " m/s")
            if ev.kind == EV_LOI2:
                self.plan_landing()
            if ev.kind == EV_DOI:
                self.phase = PHASE_DESCENT_ORBIT
        elif ev.kind == EV_PDI:
            self.start_descent()
            self.log.append(stamp + "PDI  " + fmt(self.descent.hover_seconds(), 0) + " s of hover aboard")
        self.events[i].done = True

    def earth_perigee(self, r: Vec3, v: Vec3, t_now: Float64) -> Float64:
        """km of altitude at the lowest point of the next 3.5 days."""
        var samples = List[Float64]()
        _ = self.bodies.run_recording(r, v, t_now, t_now + 3.5 * 86400.0, 1024.0, F_ALL, samples)
        var best = 1.0e30
        for i in range(len(samples) // 7):
            var rr = Vec3(samples[i * 7 + 1], samples[i * 7 + 2], samples[i * 7 + 3]).norm()
            if rr < best:
                best = rr
        return best - R_EARTH

    def plan_return(mut self):
        """Two hours past perilune with no LOI: where does the flyby take
        the crew? Into the corridor by itself -- a free return -- or with a
        DPS burn along the velocity, sized by search, or nowhere the DPS
        can reach."""
        var t_now = self.get - self.tab0
        var stamp = get_string(self.jd(), self.jd_launch) + "  "
        var natural = self.earth_perigee(self.est_r, self.est_v, t_now)
        if natural > 40.0 and natural < 150.0:
            self.log.append(stamp + "PC+2: free return, perigee " + fmt(natural, 0) + " km, coasting home")
            self.pc2_done = True
            return
        # The DPS pushing the whole stack: what it has. The burn that
        # brings the perigee into the corridor is mostly RADIAL -- the
        # perigee is set by the angular momentum, and three days out a
        # few metres a second across the track move it thousands of
        # kilometres -- so the search is in the plane, along and across.
        var dps_dv = DPS_ISP * G0 * log((CSM_MASS + LM_MASS) / (CSM_MASS + LM_MASS - self.dps_kg + DPS_UNUSABLE_KG))
        var vhat = self.est_v.unit()
        var rhat = (self.est_r - vhat * self.est_r.dot(vhat)).unit()
        var best = 1.0e30
        var best_along = 0.0
        var best_radial = 0.0
        var best_peri = natural
        var i = -12
        while i <= 12:
            var j = -12
            while j <= 12:
                var along = Float64(i) * 0.025
                var radial = Float64(j) * 0.025
                var mag = sqrt(along * along + radial * radial)
                if mag < best and mag <= dps_dv:
                    var peri = self.earth_perigee(self.est_r, self.est_v + vhat * along + rhat * radial, t_now)
                    if peri > 40.0 and peri < 150.0:
                        best = mag
                        best_along = along
                        best_radial = radial
                        best_peri = peri
                j += 1
            i += 1
        if best < 1.0e29:
            self.return_dv = best
            var burn = vhat * best_along + rhat * best_radial
            self.v = self.v + burn
            self.est_v = self.est_v + burn
            self.dps_kg -= burn_prop(CSM_MASS + LM_MASS, best, DPS_ISP)
            self.log.append(stamp + "PC+2: DPS " + fmt(best * 1000.0, 0) + " m/s for a " + fmt(best_peri, 0) + " km perigee")
        else:
            self.outcome = String("LOST")
            self.outcome_reason = String("no way home: perigee ") + fmt(natural, 0) + " km, the DPS has " + fmt(dps_dv * 1000.0, 0) + " m/s"
            self.log.append(stamp + "PC+2: " + self.outcome_reason)
            self.phase = PHASE_DONE
        self.pc2_done = True

    def judge_return(mut self):
        """Past perigee: home, or not."""
        var rr = self.r.norm()
        if rr < self.min_r_after_pc2:
            self.min_r_after_pc2 = rr
            return
        if rr > self.min_r_after_pc2 + 500.0:
            var alt = self.min_r_after_pc2 - R_EARTH
            var stamp = get_string(self.jd(), self.jd_launch) + "  "
            if alt > 40.0 and alt < 150.0:
                self.outcome = String("HOME")
                self.outcome_reason = String("entry at ") + fmt(alt, 0) + " km, no landing"
            else:
                self.outcome = String("LOST")
                self.outcome_reason = String("missed the entry corridor: perigee ") + fmt(alt, 0) + " km"
            self.log.append(stamp + self.outcome + ": " + self.outcome_reason)
            self.phase = PHASE_DONE

    def start_descent(mut self):
        """PDI: hand the LM to the descent, with what the crew know and
        what they do not."""
        var t_tab = self.get - self.tab0
        var jde = self.bodies.jde0 + t_tab / 86400.0
        var frame = self.eph.moon_frame(jde)
        var site_dir = frame.to_inertial(self.site.lat, self.site.lon)
        var rho = self.r - self.moon()
        var rho_dot = self.v - self.moon_v()
        var lm_mass = LM_MASS - (DPS_PROP - self.dps_kg)
        var nav = Vec3(0.0, 0.0, 0.0)
        var radar = 9000.0
        if not self.perfect:
            nav = Vec3(self.rng.gauss() * 1000.0, self.rng.gauss() * 500.0, self.rng.gauss() * 300.0)
            radar = 6000.0 + self.rng.next() * 6000.0
        if self.cards.radar_fail and not self.perfect:
            radar = -1.0
        self.descent = Descent(rho, rho_dot, site_dir, frame.z, lm_mass, self.dps_kg, self.hover_s, Terrain(self.site.lat, self.site.lon, False), nav, radar)
        if self.cards.alarm and not self.perfect:
            self.descent.alarm_at = 60.0 + self.rng.next() * 240.0
            if self.cards.alarm_recurs:
                self.descent.alarm_recur_at = self.descent.alarm_at + 20.0 + self.rng.next() * 40.0
        self.descending = True
        self.pdi_get = self.get
        self.phase = PHASE_DESCENT

    def step_descent(mut self, dt_get: Float64):
        """The descent's own clock, then the mission's state follows it."""
        var before = self.descent.phase
        self.descent.step(dt_get)
        # The clock is the descent's, not an accumulation of slivers.
        self.get = self.pdi_get + self.descent.t
        self.r = self.moon() + self.descent.rho
        self.v = self.moon_v() + self.descent.rho_dot
        self.est_r = self.r
        self.est_v = self.v
        self.dps_kg = self.descent.prop
        var ph = self.descent.phase
        if self.descent.alarm_state == 1 and not self.descent.alarm_logged:
            self.descent.alarm_logged = True
            self.log.append(get_string(self.jd(), self.jd_launch) + "  1202 PROGRAM ALARM -- the call is ours")
        if before < LANDED and ph >= LANDED:
            var stamp = get_string(self.jd(), self.jd_launch) + "  "
            var reason = self.descent.outcome_reason
            self.outcome_reason = reason
            var off = sqrt(self.descent.landed_x * self.descent.landed_x + self.descent.landed_y * self.descent.landed_y)
            var hov = self.descent.hover_seconds()
            self.outcome = phase_label(ph)
            self.log.append(stamp + phase_label(ph) + ": " + reason)
            if ph == LANDED:
                self.log.append(stamp + fmt(off, 0) + " m from the site, " + fmt(hov, 0) + " s hover left")
            self.phase = PHASE_DONE
            self.descending = False

    def integrate_to(mut self, t1: Float64):
        """The truth from the current GET to t1, by the phase's physics."""
        if self.phase == PHASE_TRANSLUNAR or self.phase == PHASE_LUNAR_ORBIT or self.phase == PHASE_DESCENT_ORBIT or self.phase == PHASE_RETURN:
            var out = self.bodies.run(self.r, self.v, self.get - self.tab0, t1 - self.tab0, 1024.0, F_ALL)
            self.r = out.r
            self.v = out.v
            self.get = t1
        else:
            self.get = t1
            self.place()

    def advance(mut self, dt_real: Float64):
        """Real seconds elapsed -> GET advances by warp, in sub-steps, with
        every event executed at its own second."""
        if self.paused or self.phase == PHASE_DONE:
            return
        if self.phase == PHASE_DESCENT:
            var w = self.warp if self.warp <= 10.0 else 10.0
            self.step_descent(dt_real * w)
            self.look()
            return
        var target = self.get + dt_real * self.warp
        while self.get < target and self.phase != PHASE_DONE and self.phase != PHASE_DESCENT:
            var t1 = self.get + SUBSTEP
            if t1 > target:
                t1 = target
            var i = self.next_event()
            if i >= 0 and self.events[i].get <= t1:
                var te = self.events[i].get
                if te > self.get:
                    self.integrate_to(te)
                self.execute(i)
                self.look()
                continue
            var r0 = self.r
            var v0 = self.v
            var g0 = self.get
            var was = self.in_contact
            self.integrate_to(t1)
            self.look()
            if self.phase >= PHASE_PARKING and self.in_contact != was and g0 > 0.0:
                self.note_transition(r0, v0, g0, was)
            if self.phase == PHASE_RETURN and self.pc2_done:
                self.judge_return()
            if self.phase >= PHASE_PARKING and self.get - self.last_sample >= 60.0:
                self.track.append(self.get)
                self.track.append(self.r.x)
                self.track.append(self.r.y)
                self.track.append(self.r.z)
                self.last_sample = self.get
        # PDI happened inside this call: the rest of it is the descent's,
        # on the descent's own clock and warp.
        if self.phase == PHASE_DESCENT and self.get < target:
            var w = self.warp if self.warp <= 10.0 else 10.0
            var dt = dt_real * w
            if dt > target - self.get:
                dt = target - self.get
            self.step_descent(dt)
            self.look()
        self.update_estimate()
        if self.phase == PHASE_TRANSLUNAR:
            self.divergence = (self.est_r - self.planned_at(self.get - self.tli_offset)).norm()
        else:
            self.divergence = 0.0

    def lunar_inclination(self) -> Float64:
        """Degrees between the tracked orbit's normal and the Moon's spin
        axis: 180 is retrograde over the equator."""
        var h = (self.est_r - self.moon()).cross(self.est_v - self.moon_v()).unit()
        var z = self.eph.moon_frame(jde_from_ut(self.jd())).z
        return acos(h.dot(z)) * RAD

    def near_moon(self) -> Bool:
        return (self.r - self.moon()).norm() < MOON_SOI

    def rel_elements(self) -> Elements:
        """Elements about the body that owns the spacecraft right now."""
        if self.near_moon():
            return elements(self.r - self.moon(), self.v - self.moon_v(), MU_MOON)
        return elements(self.r, self.v, MU_EARTH)


def responsible(m: Mission, ch: Choices) -> String:
    """The plan line, or the luck, that decided it: what the debrief says
    beside the outcome."""
    var r = m.outcome_reason
    if m.outcome == "LANDED" and not m.descent.damaged:
        return String("the plan held")
    if r.find("reserve") >= 0:
        return String("hover reserve ") + fmt(ch.hover_s, 0) + " s"
    if m.mcc_threshold > 1.0 and (r.find("struck the Moon") >= 0 or (m.loi_off and m.loi_off_reason.find("perilune") >= 0)):
        return String("MCC policy: never corrected")
    if r.find("no way home") >= 0 or r.find("missed the entry") >= 0:
        return String("no free return, and no LOI")
    if m.loi_off and m.loi_off_reason.find("perilune") >= 0:
        return String("MCC policy: ") + m.loi_off_reason
    if m.loi_off:
        return String("the seed: ") + m.loi_off_reason
    if r.find("alarm") >= 0 or r.find("radar") >= 0:
        return String("the seed: a card")
    if r.find("ran dry") >= 0:
        return String("hover reserve and the ground")
    if r.find("hard") >= 0 or r.find("bad ground") >= 0 or r.find("hit") >= 0:
        return String("the seed: the ground it found")
    if r.find("no place") >= 0:
        return String("the site: no ground within reach")
    return String("the seed")
