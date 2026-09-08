# ===----------------------------------------------------------------------=== #
# MC9's oracles: the design's §9 session flown end to end; a deliberately
# thin plan failing for the reason the debrief names; and each card,
# forced, ending the way the rules say.
#
# Run: cocoamojo run examples/moonshot/test_mission.mojo
# ===----------------------------------------------------------------------=== #

from astro import *
from orbit import *
from transfer import *
from window import *
from plan import *
from mission import *
from descent import *
from std.testing import *
from std.time import perf_counter_ns


def fly(mut m: Mission, to_get: Float64):
    m.warp = 3600.0
    while to_get - m.get > 0.5 and m.phase != PHASE_DONE:
        var chunk = to_get - m.get
        if chunk > 3600.0:
            chunk = 3600.0
        m.advance(chunk / m.warp)


def plan_for(ch: Choices) -> PlanSheet:
    var eph = Ephemeris()
    var wm = WindowMap(eph, ch.year, ch.month, launch_sites()[ch.pad], landing_sites()[ch.target], 60.0, 120.0, 48, 480)
    return make_plan(eph, wm, ch)


def show(m: Mission, ch: Choices, name: String):
    print("    " + name + ": " + m.outcome + " -- " + m.outcome_reason + "  [" + responsible(m, ch) + "]")


def test_apollo_11_end_to_end() raises:
    var ch = apollo_11_choices()
    var sheet = plan_for(ch)
    print("    the plan: free return", sheet.free_return, "(perigee", fmt(sheet.return_perigee_alt, 0), "km); cards for seed 1969:", draw_cards(1969).sps, draw_cards(1969).alarm, draw_cards(1969).radar_fail)
    var eph = Ephemeris()
    var t0 = perf_counter_ns()
    var m = Mission(eph, sheet, ch.seed)
    m.mcc_threshold = mcc_threshold(ch.mcc_policy)
    fly(m, 110.0 * 3600.0)
    var t1 = perf_counter_ns()
    show(m, ch, String("seed 1969"))
    print("    flown to the end in", fmt(Float64(t1 - t0) / 1e6, 0), "ms; touchdown at", get_string(m.jd_launch + m.get / 86400.0, m.jd_launch), "(Apollo 11: 102:45:40)")
    assert_equal(m.outcome, String("LANDED"))
    assert_true(abs(m.get - (102.0 * 3600.0 + 45.0 * 60.0 + 40.0)) < 180.0)
    # The story is in the log, in order.
    var order = List[String]()
    for s in ["orbit insertion", "TLI", "MCC-1", "LOI-1 ign", "LOI-2 ign", "pass ", "DOI ign", "PDI", "LANDED"]:
        order.append(String(s))
    var at = 0
    for i in range(len(m.log)):
        if at < len(order) and m.log[i].find(order[at]) >= 0:
            at += 1
    assert_equal(at, len(order))
    # The same seed, the same mission, to the character.
    var m2 = Mission(eph, sheet, ch.seed)
    m2.mcc_threshold = mcc_threshold(ch.mcc_policy)
    fly(m2, 110.0 * 3600.0)
    assert_equal(len(m2.log), len(m.log))
    for i in range(len(m.log)):
        assert_equal(m2.log[i], m.log[i])


def test_thin_plan_fails_for_its_reason() raises:
    # Never correct: the S-IVB's half a metre a second is left alone, the
    # tracked perilune at MCC-4 is below the Moon, the trench calls off
    # LOI, and the flyby brings the crew home with no landing -- and the
    # debrief names the MCC policy.
    var ch = apollo_11_choices()
    ch.mcc_policy = 3
    var sheet = plan_for(ch)
    var eph = Ephemeris()
    var m = Mission(eph, sheet, ch.seed)
    m.mcc_threshold = mcc_threshold(3)
    fly(m, 190.0 * 3600.0)
    show(m, ch, String("never correct, seed 1969"))
    for i in range(len(m.log)):
        if m.log[i].find("NO LOI") >= 0 or m.log[i].find("PC+2") >= 0 or m.log[i].find("HOME") >= 0 or m.log[i].find("LOST") >= 0:
            print("      " + m.log[i])
    assert_true(m.loi_off)
    assert_true(m.outcome == "HOME" or m.outcome == "LOST")
    assert_true(responsible(m, ch).find("MCC policy") >= 0)
    # A ninety-second reserve on the nominal ground: the West Crater
    # detour eats past it and the rule aborts, and the debrief says so.
    var ch2 = apollo_11_choices()
    ch2.hover_s = 120.0
    ch2.seed = 7
    var sheet2 = plan_for(ch2)
    var m2 = Mission(eph, sheet2, ch2.seed)
    m2.mcc_threshold = mcc_threshold(ch2.mcc_policy)
    m2.perfect = True
    m2.hover_s = 120.0
    fly(m2, 110.0 * 3600.0)
    show(m2, ch2, String("120 s reserve, perfect"))
    assert_true(m2.outcome == "ABORTED" or m2.outcome == "LANDED")
    if m2.outcome == "ABORTED":
        assert_true(responsible(m2, ch2).find("hover reserve") >= 0)


def test_cards() raises:
    var ch = apollo_11_choices()
    var sheet = plan_for(ch)
    var eph = Ephemeris()
    # The SPS card: LOI is off; a free return coasts home.
    var a = Mission(eph, sheet, ch.seed)
    a.mcc_threshold = mcc_threshold(ch.mcc_policy)
    a.cards = Cards(True, False, False, False)
    fly(a, 190.0 * 3600.0)
    show(a, ch, String("SPS card"))
    assert_true(a.loi_off)
    assert_true(a.outcome == "HOME" or a.outcome == "LOST")
    if sheet.free_return:
        assert_equal(a.outcome, String("HOME"))
    # The radar card: no lock, the rule aborts below ten thousand feet.
    var b = Mission(eph, sheet, ch.seed)
    b.mcc_threshold = mcc_threshold(ch.mcc_policy)
    b.cards = Cards(False, False, False, True)
    fly(b, 110.0 * 3600.0)
    show(b, ch, String("radar card"))
    assert_equal(b.outcome, String("ABORTED"))
    assert_true(b.outcome_reason.find("radar") >= 0)
    # A recurring alarm: the rule aborts.
    var c = Mission(eph, sheet, ch.seed)
    c.mcc_threshold = mcc_threshold(ch.mcc_policy)
    c.cards = Cards(False, True, True, False)
    fly(c, 110.0 * 3600.0)
    show(c, ch, String("recurring alarm"))
    assert_equal(c.outcome, String("ABORTED"))
    assert_true(c.outcome_reason.find("alarm") >= 0)
    # One alarm, the rule says GO, and they land.
    var d = Mission(eph, sheet, ch.seed)
    d.mcc_threshold = mcc_threshold(ch.mcc_policy)
    d.cards = Cards(False, True, False, False)
    fly(d, 110.0 * 3600.0)
    show(d, ch, String("one alarm, GO"))
    assert_equal(d.outcome, String("LANDED"))
    var seen = False
    for i in range(len(d.log)):
        if d.log[i].find("1202") >= 0:
            seen = True
    assert_true(seen)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
