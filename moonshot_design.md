# Moonshot — the trench plans, the crew flies

Design for a mission planning and tracking console: the player is the
Flight Dynamics team -- FIDO, GUIDO, RETRO, the "trench" -- not the crew.
You choose the launch site and the day, the flight time, the orbits, the
landing site, the margins and every GO/NO-GO; then you watch the mission
play out in 3D against the plan you made. The crew execute what we send
them, with the dispersions real hardware has, and live with the result.
Nothing is scripted: a landing, an abort, or a crew that never gets home
is the plan meeting the physics.

This is the design and the sprint plan in one document; numbering is
MC0–MC9 (Mission Control) so it cannot collide with the G, P, D or CT
series.

## The mission, and an opinion

The ask: a realistic moon journey from launch planning to arrival and
landing; the computations that actually have to be made, made; the course
plotted in 3D; the player making choices and seeing the plan's results;
and the frame of mission planners rather than crew, whose choices the crew
then live with.

The opinion, having read the tree and the history: **the game is the
planning, and the planning is a handful of real computations that were
last done this way on an IBM 360 in Building 30.** Where the Moon will be
(an ephemeris), when a launch site passes through the plane that contains
it (spherical trigonometry and sidereal time), what a transfer of a chosen
duration costs (Lambert), what the Moon's gravity does to it (numerical
integration), what a burn error does to the arrival (Monte Carlo), what
the lighting is at the site on that day (the sub-solar point), and what
the descent has left when the surface arrives (the rocket equation under
a guidance law). None of these is large. Every one of them is the real
thing, and each has an oracle: Meeus's worked examples for the astronomy,
Kepler's closed form for the integrator, and **Apollo 11's published
timeline for the whole chain** -- if our planner is fed KSC, Tranquility
and July 1969 it has to find the 16th, cost about 3.18 km/s at TLI and
0.89 at LOI, and put the Sun 10.8° above the landing site at 20:17 UTC on
the 20th. That is the acceptance test of the entire project, and it is
also the best episode.

The GPU belongs in two places and only two. The **launch-window map** for
a month is a few hundred thousand independent candidates (every launch
minute × every flight time), each a Lambert solve and an ephemeris call --
exactly the one-thing-per-thread shape `grayscott`, `physarum` and `boids`
already proved, with a real computation inside instead of a rule. And the
**dispersion cloud** -- sixteen thousand copies of the plan flown with
perturbed burns to the Moon and back to a probability -- is the honest
version of "will the crew make it", and it is embarrassingly parallel.
The 3D display itself is a polyline and two shaded discs; the CPU draws
it into `DirectPane` in well under a millisecond, and pretending
otherwise would be the wrong kind of GPU demo.

## What exists (the inventory this design stands on)

| piece | where | what it gives us |
|---|---|---|
| the console text | `gamepane/api/text.mojo`, `metal/text.mojo` | `TextOverlay`: a cols×rows grid of 5×7 glyphs with per-cell colour -- the whole planning UI |
| the plot surface | `gamepane/metal/layers.mojo` `DirectPane` | an 8-bit indexed framebuffer with a 256-entry RGBA palette, stride-aware; the 3D course is drawn into it a byte at a time |
| the backdrop | `ShaderPane` (`STARFIELD`) | the star field behind the plot, already shipped |
| the chip | `gamepane/api/audio.mojo` | Quindar tones (2525/2475 Hz, 250 ms -- the real ones), master alarm, telemetry ticks |
| the frame loop | `examples/galaxigans-deluxe/main.mojo` | the gamepane game skeleton: input as flags, a fixed-step update, layers composited by the backend |
| kernels | `examples/boids`, `physarum`, `grayscott` | the precedent: Mojo `def`s compiled to AIR, one thread per candidate, fixed-width (`Int32`/`Float32`) arguments only |
| PNG out | `examples/grayscott/main.mojo` `save_png` | screenshots of the map and the course for the channel |

Nothing new is needed at the infrastructure level. The work is astronomy,
astrodynamics, and a console.

## 1. Frames, time, and where the Moon is

Everything lives in one frame: **Earth-centred, mean equator and equinox
of date**, kilometres and seconds. It precesses at 50″ a year, 0.7″ over a
five-day mission -- 1.3 km at the Moon, a third of the ephemeris's own
accuracy -- so it is treated as inertial, and nutation is never applied
(it moves the frame, not the bodies, and cancels within one frame). Time
is a Julian Day on two clocks kept apart by name: Universal Time for the
launch clock and sidereal time, dynamical time for the ephemeris, ΔT
between them (40 s in 1969, 70 s today: 40 km of the Moon's motion). Three
bodies matter -- Earth, Moon, Sun -- and two of them move on a schedule
we look up rather than integrate, because the question "where will the
Moon be on 19 July 1969 at 17:22 UTC" has a known answer and integrating
the Moon ourselves would only add error to it.

| constant | value |
|---|---|
| μ_Earth | 398 600.4418 km³/s² |
| R_Earth (equatorial) | 6 378.137 km, J2 = 1.082 63 × 10⁻³ |
| Earth rotation ω | 7.292 115 0 × 10⁻⁵ rad/s (0.4651 km/s at the equator) |
| μ_Moon | 4 902.800 066 km³/s² |
| R_Moon | 1 737.4 km |
| Moon mean distance / perigee / apogee | 384 400 / ≈363 300 / ≈405 500 km |
| Moon sidereal period | 27.321 661 d (rotation is the same: 13.18°/day) |
| Moon equator to ecliptic | 1.5424° (Cassini's laws give the pole's direction) |
| μ_Sun, 1 AU | 1.327 124 400 18 × 10¹¹ km³/s², 149 597 870.7 km |
| Moon sphere of influence | ≈ 66 100 km |

The ephemeris is **Meeus, *Astronomical Algorithms*, chapter 47** -- the
abbreviated ELP-2000/82: five fundamental arguments (L′, D, M, M′, F) plus
the A1/A2/A3 corrections and the eccentricity factor E, then a 60-term
series for longitude and distance and a 60-term series for latitude. It
is accurate to about 10″ in longitude and 4 km in distance, which is far
inside anything a burn can resolve, and it is about 150 lines of tables.
The Sun is chapter 25's low-precision solution (0.01°), which is plenty
for a perturbing acceleration and for the lighting angle. Sidereal time
is chapter 12's GMST polynomial. Ecliptic to equatorial is one rotation by
the mean obliquity (23.439 291° − 0.013 004 2° T).

The **Moon-fixed frame** (for landing sites and lighting) comes from
Cassini's laws: the spin axis is 1.5424° from the ecliptic pole toward
longitude Ω + 90° (Ω the lunar node), and the prime meridian turns
uniformly with the Moon's mean longitude. Physical libration is ~0.03°
and is ignored; optical libration is not a separate computation -- it
falls out of drawing the Moon-fixed frame at its true position.

The oracle for all of it is the book's own worked examples. Chapter 47,
example a: **1992 April 12, 0h TD → λ = 133.162 655°, β = −3.229 126°,
Δ = 368 409.7 km.** Chapter 12, example a: 1987 April 10, 0h UT → GMST
13h 10m 46.3668s. Chapter 25: 1992 October 13 → ⊙ = 199.909 88°, R =
0.997 66 AU. MC0 prints those three and the test compares them to the
book to the last digit the book gives.

## 2. The vehicle -- the one table that is typed in

Everything downstream is computed; this is the one place numbers are
entered by hand, and they are rounded public figures for a Saturn-class
stack. The player never edits them; they are the hardware we were given.

| stage | Isp (s) | propellant (kg) | burns | notes |
|---|---|---|---|---|
| S-IVB restart | 421 | ≈ 73 000 | TLI | restarts on revolution 2 or 3 only -- the cryogenics and batteries do not allow a later one |
| Service Module SPS | 314.5 | 18 413 | MCC, LOI-1, LOI-2, (TEI) | the LM is attached at LOI, so LOI burns the whole stack |
| LM descent DPS | 311 | 8 200 | DOI, powered descent | throttleable 10–60% plus a fixed full setting; 45 040 N max |
| stack at insertion | | ≈ 134 000 kg total | | CSM ≈ 28 800, LM ≈ 15 100, S-IVB dry + instrument unit + adapter ≈ 17 000, TLI propellant the rest; that gives the S-IVB ≈ 3 240 m/s against Apollo 11's 3 182 |

Each burn is the rocket equation, `Δv = Isp · g₀ · ln(m₀ / m₁)`, on the
mass that is actually being pushed at that moment -- the S-IVB pushes
everything, the SPS at LOI pushes CSM + LM, the DPS pushes the LM alone.
The results panel shows, per stage, **available Δv, planned Δv, and the
margin in m/s and in seconds of burn**, and the margin is what the crew
live on.

## 3. The computations that actually have to be made

Numbered so the sprints and the results panel can refer to them. "Oracle"
is what proves each one.

| # | computation | in | out | how | oracle |
|---|---|---|---|---|---|
| C1 | Julian Day | calendar date/time UTC | JD, T (Julian centuries from J2000), and JDE = JD + ΔT for the ephemeris | Meeus 7.1; Espenak–Meeus ΔT fits | 2000-01-01 12:00 → 2 451 545.0; ΔT(1969) ≈ 40 s |
| C2 | sidereal time | JD | GMST, and the local sidereal time of a site | Meeus 12.4 | example 12.a |
| C3 | Moon position | T | ecliptic λ, β, Δ → equatorial r⃗_M | Meeus 47 (60+60 terms) | example 47.a |
| C4 | Sun position | T | ⊙, R → r⃗_S | Meeus 25 | example 25.a |
| C5 | Moon-fixed frame | T, Ω, L′ | 3×3 rotation, inertial ↔ selenographic | Cassini's laws | Apollo 11 lighting (C13) closes the loop |
| C6 | launch-site vector | site φ, λ; JD | ŝ in inertial space, and its velocity ω × r⃗ (the rotation credit) | C2 | Earth rotation credit at KSC, azimuth 90°: 0.408 km/s |
| C7 | orbit plane from a launch | ŝ, pad azimuth β, the ascent's downrange angle | the inertial velocity at insertion (the great-circle tangent at β plus the rotation credit ω × r⃗), the insertion point ≈ 2 500 km downrange, and the plane n̂ = r̂ × v̂ they define; inclination cos i = sin β_inertial cos φ; node Ω | vector algebra | β = 90° at any site gives i = φ exactly; Apollo 11's 72.058° pad azimuth must come out within a degree of the recorded 32.52° once the rotation credit is in the velocity (the bare pad formula gives 33.4°, and that gap is the credit) |
| C8 | plane miss | n̂, r⃗_M at arrival | δ = asin(n̂ · r̂_M): how far the Moon-at-arrival sits out of the plane | dot product | 0 at the centre of each daily window |
| C9 | the daily window | site, day, flight time | the span of launch times whose required azimuth lies in the range-safety corridor (KSC: 72°–108°) | for each minute: the plane through ŝ and r̂_M(t_A), its i, the β that gives it; in corridor or not | Apollo 11: 16 July 1969, window opened 13:32 UTC at 72° |
| C10 | Lambert | r⃗₁ (TLI point), r⃗₂ (the arrival aim point), time of flight | v⃗₁, v⃗₂ of the two-body transfer | universal-variable Lambert (Bate, Mueller & White), bisection on z | a Hohmann half-ellipse: 185 km → 384 400 km takes 4.98 d and 3.135 km/s, both closed-form |
| C11 | TLI burn | parking orbit state, v⃗₁ | Δv vector, burn time from thrust and mass; an out-of-plane component adds in quadrature, so steering the lunar orbit's plane at TLI costs metres a second, not hundreds | vis-viva, rocket equation | Apollo 11 TLI: ΔV 3 182 m/s (10 441 ft/s) over 347 s, cutoff 3 041 m/s faster than the parking orbit and 138 km higher; the impulsive plan lands within 1% of the burn |
| C12 | n-body propagation | state, JD | state at any later time under Earth + J2, Moon and Sun point masses (with the indirect terms) | RK4; the step is 0.005 rad of the dominant body's motion, quantized to powers of two (4 s at perigee and perilune, 512 s in cruise); Float64 on the CPU; on the GPU, Float32 arithmetic on **int64 fixed-point accumulators** (2⁻²⁴ km, 2⁻³² km/s) -- the Apollo Guidance Computer's own trick | two-body only: Kepler's closed form (11 mm over a day of LEO); energy drift 5 × 10⁻¹⁰ over five days; the Float32 GPU arc vs the Float64 CPU arc: 351 m at the Moon after a 7 263 km flyby (25 km before fixed point) |
| C13 | targeting | a Lambert first guess, a target (perilune radius, perilune time, and the lunar orbit pole wanted -- signed, so retrograde is also the far-side approach) | the TLI Δv⃗ that hits the target under C12; in-plane (two unknowns) for what the launch geometry gives, or the full vector (three) to steer the lunar orbit's plane | differential correction: finite-difference Jacobian, 5–6 Newton rounds, a few ms | perilune within 1 km and 0.5 s of the target; the Apollo 11 replay (§9) |
| C14 | closest approach | a propagated arc | perilune radius, time, v_∞, the B-plane | the nearest step, a parabola through its neighbours, a 1 s re-propagation, one Newton step on ρ⃗·ρ̇ = 0 | ρ⃗·ρ̇ = 0 to 10⁻⁶; |B| = h/v∞ exactly |
| C15 | LOI | arrival state at perilune, target orbit | Δv = √(v_∞² + 2μ_M/r_p) − v_target(r_p); LOI-2 circularisation | vis-viva | Apollo 11: 889 m/s into 314 × 111 km, then 48 m/s to ≈122 × 100 km |
| C16 | the landing-site pass | lunar orbit plane, Moon-fixed frame, site | when (if ever) the ground track crosses within the cross-range budget of the site; requires i ≥ |site latitude| | C5 + orbit propagation | Tranquility (0.67°N, 23.47°E) reachable from a 1.25° orbit |
| C17 | Sun elevation at the site | JD of landing, site, C4, C5 | elevation and azimuth of the Sun at the site; the lighting constraint 5°–14°, Sun behind the approach | sin e = r̂_site · ŝ_sun in the Moon-fixed frame | Apollo 11: 10.8° at 20:17:40 UTC, 20 July 1969 |
| C18 | DOI and PDI | circular orbit, perilune target 15 km | DOI Δv (≈ 23 m/s); PDI point half an orbit later; the braking-phase target state | vis-viva | Apollo 11 DOI 23 m/s, PDI at GET 102:33 |
| C19 | descent guidance | current state, target state (r⃗_T, v⃗_T, a⃗_T), t_go | commanded acceleration **a⃗_C = a⃗_T + 12 (r⃗_T − r⃗)/t_go² − 6 (v⃗_T + v⃗)/t_go**, throttle = m·\|a⃗_C − g⃗\| / thrust_max, clamped to the engine's range | Klumpp's quartic (P63/P64), t_go by the terminal-jerk cubic | Apollo 11: 12 min 36 s, ≈ 2.0 km/s, landed with tens of seconds of hover (30 s called from the ground, ≈ 45 s by post-flight analysis) |
| C20 | the corridor probability | the plan, error models (§6) | perilune scatter, P(perilune inside the LOI corridor), the LOI Δv distribution | N = 16 384 perturbed copies of C12 on the GPU | the unperturbed copy must reproduce the CPU plan (measured gap) |
| C21 | station coverage | Earth rotation, spacecraft position, Moon position | which of Goldstone / Madrid / Honeysuckle Creek see the spacecraft; Moon occultation → the LOS/AOS times | elevation above each station's horizon; a line-sphere test against the Moon | Apollo 11 LOI-1: LOS 075:41, AOS 076:15 -- 34 min in the dark |
| C22 | the plan budget | all of the above | per-stage Δv, propellant, mass at each event, margins, the timeline in GET | rocket equation, summed | Apollo 11 mission report figures within a few percent |

The window map (C9 for every minute of a month × every flight time in
2.5–5 days) and the dispersion cloud (C20) run on the GPU; everything
else runs once, on the CPU, in Float64, and takes milliseconds. **One
integrator serves both**: `rk4_step` is a plain `def` over fixed-width
types that the CPU calls with `Float64` and the kernel calls with
`Float32`. Metal has no double, and MC1 measured what that costs: with
Float32 accumulators the kernel's arc drifted 1.6 km a day in cruise and
25 km by the Moon, whose gravity multiplied the cruise error by four.
The remedy is the one the Apollo Guidance Computer used, having no
floating point at all: **the state accumulates in int64 fixed point**
(2⁻²⁴ km and 2⁻³² km/s per unit, where every add is exact) and Float32
is used only within a step, on vectors that are small or were formed
exactly from the wide state first. That took the divergence to 351 m at
the Moon -- the floor set by evaluating μ/r³ in Float32 -- and the
Monte Carlo of C20 centres its cloud on its own unperturbed thread
besides, so what it measures is dispersion, not the kernel's bias.

## 4. Why the date matters -- what the map is a map of

The player's earlier question -- is there a least-cost route by time of
year and month -- has a real answer, and the map is built so that the
answer is visible rather than told.

- **Distance.** The Moon's orbit is eccentric (e ≈ 0.055): perigee to
  apogee is ~42 000 km, a 10% swing every 27.55 days, and the transfer to
  a near Moon is cheaper at both ends. A scalloping in the map's cost with
  a period of a month.
- **Plane.** A launch site only passes through the plane that contains the
  Moon-at-arrival when the geometry allows it: the plane's inclination
  must be at least the site's latitude, and the required azimuth must lie
  in the range-safety corridor. As the Moon's declination sweeps ±18°–29°
  through each month, the corridor admits some days and refuses others.
  Apollo could not launch to the Moon on most days of a month, and this
  is why.
- **Lighting.** The Sun must be 5°–14° above the landing site, behind the
  approach, so the crew see the terrain's relief -- local early morning.
  At the lunar equator the Sun climbs 0.51° per hour, so that condition
  lasts about 18 hours **once per lunar day** at each site, and sites
  further east get their morning earlier in the month. This is the
  constraint that picked 16 July for Tranquility, 18 July for Sinus Medii
  and 21 July for the Ocean of Storms in 1969, and it is why a site is
  chosen before a day is.
- **Year.** The Moon's node regresses once in 18.6 years, so the envelope
  of monthly declination breathes between ±18.3° and ±28.6°; the map for
  July 1969 and the map for July 1978 have visibly different bands. The
  Sun's perturbation adds a small wobble. There is no seasonal cost in the
  ordinary sense; the year enters through the envelope.

So the map has axes of **day of month × launch hour**, a slider for
flight time, colour for total Δv, and overlays hatching the cells the
corridor forbids and the cells where the site would be dark. The player
picks a cell; the CPU then flies that cell properly (C10 → C13 → C22)
and fills the results panel. Choosing a longer flight time shows the
trade at once: cheaper TLI and LOI, a longer exposure, and a different
arrival day whose lighting may have moved.

## 5. The player's choices, and what each one does to the numbers

| choice | options | what it moves |
|---|---|---|
| launch site | KSC 28.6°N; Baikonur 45.9°N; Kourou 5.2°N; Vandenberg 34.7°N (polar corridor) | the plane geometry (C7–C9) and the rotation credit (C6): high-latitude sites reach fewer days and pay in payload |
| landing site | Tranquility 0.67°N 23.47°E; Ocean of Storms 3.0°S 23.4°W; Fra Mauro 3.7°S 17.5°W; Hadley 26.1°N 3.6°E; Descartes 9.0°S 15.5°E; Taurus-Littrow 20.2°N 30.8°E; Shackleton 89.9°S | which days have the light (C17), the lunar orbit's inclination (C16), the terrain the descent meets (§7) |
| month and year | 1968–2040, any month | the whole map (§4) |
| launch cell | a minute in the window | azimuth, plane miss, TLI point and time (C9, C11) |
| parking-orbit revs before TLI | 2 or 3 | a later TLI shifts the injection point; miss the third revolution and the S-IVB is gone and the mission becomes an Earth-orbital alternate |
| flight time | 2.5–5 days | TLI and LOI Δv against exposure and lighting drift (C10, C15, C17) |
| free return or hybrid | free-return figure-8, or a hybrid that trades it for landing-site access | whether a dead SPS after TLI is survivable (§6); hybrid unlocks sites the free-return plane cannot reach |
| lunar orbit | LOI-1 apolune × perilune; LOI-2 altitude | LOI cost (C15), the DOI geometry (C18), the ground-track spacing over the site (C16) |
| descent perilune | 10–20 km | PDI Δv and the braking-phase length (C18, C19); lower is cheaper and less forgiving of terrain |
| hover reserve policy | 30/60/90 s at low-gate throttle | how long the crew may look before the abort call is forced (§7) |
| midcourse policy | correct above 0.3 / 1 / 3 m/s | how much SPS is spent keeping the corridor probability up (C20) |
| GO/NO-GO calls | TLI, MCC-1..4, LOI, DOI, PDI, and the 1202-style call during descent | the crew do what we say |

The results panel, updated the moment a choice changes, is §8's plan
sheet: the timeline in GET, every burn with its Δv and duration, the
mass at every event, per-stage margins, the corridor probability, the Sun
at the site, and the coverage table. A red line in it is a constraint
violated -- azimuth out of corridor, dark site, negative margin, TLI past
the S-IVB's life -- and the GO button stays grey until there are none.
Amber is a margin thinner than the flight rules like; the button lights,
and the crew fly it.

## 6. Consequences -- how a plan becomes an outcome

The mission is the plan re-flown with the dispersions real hardware has.
Every random draw comes from one seed shown on the debrief, so a mission
can be replayed with the same luck and a better plan.

| source | model | where it bites |
|---|---|---|
| TLI execution | magnitude σ 0.05%, pointing σ 0.03° | the perilune scatter; 6 m/s of MCC-2 is normal, 30 is a bad day |
| tracking | state estimate σ 1 km, 0.1 m/s, improving with arc length | what the trench *thinks* the trajectory is; the MCC is computed from the estimate, not the truth |
| propellant loading | σ 0.5% per stage | the margin the panel showed is not quite the margin they have |
| SPS anomaly | rare, drawn once at TLI | on a free return, a coast home; on a hybrid, the crew need a DPS burn we must plan on the spot |
| navigation at PDI | σ 1 km downrange (Apollo 11 was 6.9 km long) | the target point lands somewhere else; the terrain there is whatever it is |
| landing radar | acquires between 12 000 and 6 000 m, later on a rough day | until it does, the altitude is the estimate's; a late lock costs hover time |
| descent computer overload | a 1202-style alarm, drawn during braking | our GO/NO-GO call, with the abort limits on the screen |
| terrain | a per-site height field of craters and boulder fields, seeded from the site | a target in a crater forces a redesignation; every redesignation is hover time |

The chain is: margin (§5) → dispersion (this table) → the flight rules'
abort limits → the outcome. A thin SPS margin and a bad TLI draw leave
LOI short and the crew in a 300-km orbit that cannot reach the site; a
30-second hover policy and a boulder field end in an abort to orbit; a
hybrid trajectory and a dead SPS end with the crew needing a burn we did
not budget. The debrief says which line of the plan sheet did it.

## 7. The descent -- the only real-time phase

Everything before PDI is tracked at time warp (1×, 60×, 600×, 3600×) and
the console mostly waits between events, as the real one did. The
descent is twelve minutes and is watched at 1× or 10×. It is flown by the
guidance law (C19) through three targets -- high gate at ≈ 2 300 m with
the LM pitched to see the site, low gate at ≈ 150 m, then a constant-rate
vertical descent -- with the throttle command clamped to the DPS's range
and the mass falling with every second of burn. The trench sees altitude,
descent rate, propellant in seconds of hover, the target point over the
terrain, the redesignations, and the abort limits. The crew redesignate
when the target is in a crater and the reserve allows; when it does not,
the abort call is ours, and an abort past the DPS's ability to reach
orbit is a crew we have lost.

The terrain is synthetic -- craters as bowls with rims, boulder density
rising near young craters, seeded from the site coordinates so Tranquility
always has its West Crater equivalent in the same place. It is not
real topography, and the design does not claim it is; what is real is
the guidance, the engine, the propellant, and the geometry of the pass.

## 8. The screens

One window, `gamepane`, three panes stacked: starfield, the direct pane
with the 3D plot, the text overlay with everything else.

```
┌─ MOONSHOT · FLIGHT DYNAMICS ─────────────────────────────── GET 026:44:58 ─┐
│                                                          │ PLAN            │
│                                                          │ site  KSC 72.1° │
│        · . ·           the course, Earth-centred:       │ tgt   TRANQ     │
│      ·  Moon orbit  ·  the parking orbit, the TLI arc,  │ TLI  3 181 m/s  │
│     ·       ○ Moon   ·  planned (cyan) and tracked      │ LOI    889      │
│     ·               ·   (amber) diverging by 41 km,     │ DOI     23      │
│      ·      ⊕ Earth ·   the Moon's orbit ahead of it,   │ PDI  2 010      │
│        · . ·           the terminator on both bodies    │ SUN   10.8°     │
│                                                          │ margins         │
│   [E]arth  [M]oon  [R]otating   drag to orbit, wheel zoom│  SPS +12%  DPS +7%│
├──────────────────────────────────────────────────────────┴─────────────────┤
│ NEXT  MCC-2  T-00:10:00  Δv 6.4 m/s  corridor P 97.3% → 99.8%   [GO] [HOLD] │
│ MSFN  GDS ●  MAD ○  HSK ○     LOS behind Moon at 075:41  AOS 076:15         │
└────────────────────────────────────────────────────────────────────────────┘
```

**PLAN** is the same window with the map in the plot area and the choice
list where the state vector is. **DEBRIEF** replaces the plot with the
landing dispersion and the plan sheet with the outcome and its cause.

The 3D plot is a perspective camera the player orbits with the mouse,
centred on the Earth, the Moon, or the origin of the **Earth–Moon rotating
frame** -- the only frame in which a free return looks like the figure-8
it is always drawn as. Trajectories are the integrated states, never a
drawn ellipse: a polyline through the samples, depth-cued by palette
index, planned and tracked in different colours. Earth and Moon are
shaded discs from a per-pixel ray-sphere test with the Sun's direction
from C4, a latitude-longitude grid, the three MSFN stations turning with
the Earth, and the landing site on the Moon -- which, on a well-chosen
day, sits just inside the sunlit side of the terminator, and the reason
for the date is on the screen.

Audio is the chip and nothing more: Quindar tones bracketing each event
call, a telemetry tick per frame at 1×, the master alarm for a red line
crossed, and a four-bar chip figure at touchdown.

## 9. A worked session -- also the acceptance test

Site KSC, target Tranquility, July 1969. The map lights the 16th through
the 18th at 72°–100°; the 16th at 13:32 UTC costs 3 181 m/s at TLI on a
73-hour flight with the Sun at 10.8° over the site on the 20th at 20:17
UTC. Rev 2 TLI at GET 2:44, 347 s. GO. Tracked TLI is 0.4 m/s hot, 0.02°
left; the corridor probability reads 96%; MCC-2 at GET 26:45 is 6 m/s,
and it goes to 99.8%. LOS at 75:41; LOI-1 fires in the dark; AOS at
76:15 on the nominal time to the second -- a burn that had failed would
have brought them round the limb minutes early on the flyby, which is how
the trench knew the burn was good before anyone said so. LOI-2, DOI, PDI at 102:33; a 1202 at
five minutes, GO; the target drifts long into a crater field, one
redesignation, touchdown at 102:45 with 45 s of hover left. The debrief
matches the mission report to a few percent on every line, and if it
does not, the project is not done.

## The sprints

Each sprint ends with something that runs, and each has an oracle that is
not us. A sprint whose numbers are only "plausible" is not done.

- **MC0 — Astronomy core.** `astro.mojo`: JD, GMST, the Moon (chapter
  47 tables in full), the Sun, obliquity, the frames, the Moon-fixed
  frame, launch sites and landing sites as data. **Done when** the three
  Meeus examples print to the book's digits and a test asserts them.
- **MC1 — The integrator.** `orbit.mojo`: state, RK4 over Earth (+J2),
  Moon, Sun; Kepler's closed form beside it; the same `def` compiled as a
  GPU kernel over Float32. **Done when** two-body RK4 matches Kepler to
  1 m over a day, energy drifts by less than 10⁻⁹ relative over a 5-day
  arc, and the Float32 kernel's divergence from the Float64 CPU arc is a
  measured, printed number at lunar arrival. *Done: 11 mm, 5 × 10⁻¹⁰,
  and 351 m at 15 331 km from the Moon after a 7 263 km flyby -- on
  int64 fixed-point accumulators, which the measurement (25 km without
  them) made necessary. 16 384 five-day arcs run in 57 ms.*
- **MC2 — Lambert and targeting.** `transfer.mojo`: universal-variable
  Lambert, closest approach, the B-plane, differential correction.
  **Done when** the Hohmann check is closed-form exact, and a 73-hour
  KSC-to-Moon transfer for 16 July 1969 converges to a 111-km perilune
  within 1 km at a TLI Δv within 3% of Apollo's. *Done: Lambert inverts
  Kepler to 10⁻⁸ km/s; the Apollo 11 replay -- parking orbit 32.52°
  holding the Moon at LOI-1's minute, a plane that passes 0.12° from the
  pad at the launch second -- converges in 6 rounds and 7 ms to a
  111.00 km far-side perilune at 73.093 h for 3 181 m/s against the
  S-IVB's 3 182, a retrograde orbit 3.8° from the lunar equator, and
  LOI-1 of 873 m/s against 889. The in-plane burn alone is 3 165 m/s
  and arrives 20° off the equator: the trench steered the plane at TLI
  because a perpendicular component costs only in quadrature.*
- **MC3 — The window map.** `window.mojo` and the kernel: C6–C9 and C17
  per (minute, flight time) across a month, the corridor and lighting
  masks, a PNG of the map. **Done when** July 1969's map lights 16–18
  July for Tranquility and the 21st for the Ocean of Storms, and Apollo
  11's real launch minute sits in its band at 72.06°. *Done, with the
  criterion sharpened by what the map showed: the lighting band centres
  on day 16.5 for Tranquility, 18.5 for Sinus Medii and 21.8 for Site 5
  -- NASA's 16th, 18th and 21st, which were three sites, not one. The
  corridor opens twice a day (the Pacific and Atlantic injection
  geometries); on the 16th the second window runs 13:26–17:48 UTC,
  72.0° to 107.8°, against the recorded 13:32–17:54. Apollo's minute
  reads 32.39° inclination and 72.93° pad azimuth: the great-circle
  ascent model sits 0.9° from the flown azimuth, a six-minute shift of
  the window. 714 240 cells on the GPU in ~190 ms including compile;
  377 sampled cells agree with the Float64 cell to 0.01 m/s, 0.007°,
  0.0001° of Sun, no flag differs. The cell's v∞ is the two-body
  relative speed less the Moon's own energy at the sphere of influence
  (2μ/R_SOI), which puts it 1.3% under MC2's targeted value.*
- **MC4 — The PLAN screen.** The gamepane skeleton, the choice list, the
  plan sheet (C22), the 3D plot with the three frames and the shaded
  bodies. **Done when** every number on the sheet is traceable to a Cn
  and a screenshot of the July 1969 plan exists. *Done. `plan.mojo`
  turns twelve choices into the sheet: geometry and lighting from the
  map's cell (C6–C9, C17), the transfer from the corrector (C10–C15),
  LOI-2 and DOI by vis-viva (C15, C18), the timeline from Apollo 11's
  own intervals, masses and margins by the rocket equation on the §2
  table (C22); `scene.mojo` is the plot -- a perspective camera, clipped
  lines through the integrator's samples, spheres shaded from the Sun's
  real direction with a body grid, in Earth-centred, Moon-centred and
  rotating frames; `main.mojo` is the window, with the month map as a
  fourth view for choosing the minute. Apollo 11's choices give GO with
  the S-IVB 37 m/s from empty and 178 s of hover in the DPS; 08:00 is
  out of corridor, the 24th is a 70° Sun, a 60-hour flight loses the
  light. A replan is about 80 ms. Screenshots of all four views come
  from `MOONSHOT_VIEW=… MOONSHOT_SHOT=… GAMEPANE_FRAMES=3`.*
- **MC5 — TRACK.** Time warp, the GET timeline, the state vector and
  elements, the planned-versus-tracked course, the MSFN coverage and the
  Moon LOS/AOS. **Done when** Apollo 11's LOS/AOS at LOI-1 come out
  within a minute of the record. *Done for LOS, not quite for AOS, and
  the miss is recorded rather than tuned away: LOS 075:40:35 against
  075:41:23 (48 s early), AOS 076:13:53 against 076:15:29 (96 s early).
  Two corrections the record forced along the way: an impulse stands at
  a burn's midpoint, not its ignition (TLI's is 167 s after the S-IVB
  lights, and everything downstream had been three minutes early); and
  the SPS held a fixed inertial attitude, so a finite LOI-1 flown that
  way makes 111 × 333 km where a velocity-following one made 102 × 325
  and the impulse promised 111 × 314. The AOS residual is most likely
  the orbit plane's tilt against the Earth line -- ours 3.8° to the
  lunar equator where Apollo's was about 1.2° -- which MC7 targets. The
  flown course matches the planned one to the metre once the planned arc
  is read by cubic Hermite rather than chord (a chord between samples a
  thousand seconds apart sags 190 m). `mission.mojo` is the truth in
  flight: Kepler on the parking orbit, the integrator from TLI, burns as
  sub-impulses over their seconds, contact found to the second by
  bisection; the console's TRACK mode shows the clock, the state vector
  about whichever body owns the spacecraft, the coverage, the burns and
  the log, with warps 1× to 3600×.*
- **MC6 — Dispersions.** The error models of §6, the tracking estimate,
  the MCC decision, and the dispersion kernel (C20) with its corridor
  probability. **Done when** the unperturbed sample reproduces the CPU
  plan to the MC1-measured gap and 16 384 samples fly in under a second.
  *Done: the exact copy lands 34 m and 0.0 s from the corrector's
  perilune; 16 384 copies fly in 218 ms including compile. Each thread
  finds its own perilune by the sign change of ρ⃗·ρ̇ inside the sphere of
  influence. The numbers are the story: with the S-IVB's 0.05% and
  0.03° alone the B-plane scatters ±1 343 km and 5.6% of copies reach
  the 60–200 km corridor; after a correction at TLI + 24 h with 1 km /
  0.1 m/s tracking, 100% do, at ±14 km -- a near-parabolic transfer has
  ∂apogee/∂v ≈ 4 500 km per m/s, which is why Apollo carried four
  correction opportunities. `mission.mojo` now flies the truth with a
  seeded S-IVB error, a tracking estimate whose error shrinks with the
  arc, MCC-1..4 computed by the corrector from the ESTIMATE and burned
  under the policy with their own errors, and LOI-1 retimed from
  tracking at MCC-4. Seed 1969: TLI misses by 0.56 m/s; MCC-1 burns
  2.2 m/s, MCC-2 and -3 are held under the 1 m/s rule, MCC-4 burns 1.0;
  the true perilune is 110.9 km. The same seed with no corrections:
  −158 km, which is the Moon. The PLAN sheet shows both corridor
  probabilities from two live clouds of 4 096; the TRACK panel shows the
  tracked state, not the truth.*
- **MC7 — Arrival.** LOI-1/LOI-2, the lunar orbit, the site pass, DOI, the
  Moon-centred view with the terminator and the site. **Done when** the
  Apollo 11 LOI numbers (889 then 48 m/s; 314 × 111 → 122 × 100 km)
  reproduce within a few percent and the site-pass test rejects Hadley
  from a 1° orbit and accepts it from a 26° one. *Done, with C16 read
  properly: the LM lands where the orbit plane meets the ground, so the
  flyby plane must hold the site's direction AT THE LANDING TIME as well
  as the approach asymptote, which pins it -- ĥ ∝ Ŝ × ŝ_site, signed
  retrograde. `lunar.mojo`: the finite LOI-1 solved by a 2×2 Newton on
  the burn itself (877 m/s, ignition 0.4 s from the impulse's, makes
  111.04 × 314.01 km -- the 3.7 m/s over the impulse is the finite
  burn's loss; Apollo's 889 was 1.4% more), LOI-2 at the second
  perilune tracking finds (42 m/s to 111.0 × 111.1 km; Apollo's 48 m/s
  aimed at 122 × 100 because the real Moon's gravity field would turn
  that into 60 × 60 nmi by rendezvous, and this Moon is a point mass),
  the site pass by watching the ground track cross the site's
  longitude, and DOI half a descent-orbit before a PDI a braking phase
  short of the site. Hadley: 762 km off the plane from a 1° orbit,
  0.01 km from a 26.5° orbit through it. Apollo 11 flown: the landing
  pass at 102:42:17 with Tranquility 0.2 km off the plane, DOI 101:32,
  PDI 102:29 -- the record's 102:45:40, 101:36 and 102:33. The AOS
  residual did not close: the site-pass plane is the plane we already
  had (3.8° to the equator, the approach asymptote's own declination),
  so the 90 s is something else, and it stays in the tests as a stated
  tolerance rather than a tuned-away number.*
- **MC8 — The descent.** The guidance law with its three gates, the DPS
  model, the terrain, the radar, redesignation, the abort limits, the
  DEBRIEF. **Done when** a nominal Apollo 11 descent lands in 12–13
  minutes for ≈ 2.0 km/s with 30–60 s of hover left, and a 30-s reserve
  policy over a boulder field produces an abort rather than a landing.
  *Done, with the criterion's second half corrected by what the rules
  actually do: the reserve is the abort trigger, so it is the LARGER
  reserve that aborts. `descent.mojo`: Klumpp's quartic on inertial
  vectors (the Moon's curvature costs nothing), t_go from the
  terminal-jerk quadratic each two-second cycle, high gate at 2 286 m
  and 7.9 km, low gate at 152 m and 600 m, then a rate-of-descent phase
  that arrives with the aim and comes down the last twenty metres at a
  metre a second; the DPS at 10–60% or full, so the braking phase runs
  at full throttle and throttles down when the demand falls through
  60%; terrain seeded from the site's coordinates (West Crater at
  +197, +42 m, 90 m across, its field 300 m); the crew see craters from
  the approach and rocks only in the final, redesignate to the nearest
  place ahead they can reach, and look for forty seconds first, which
  is where Apollo 11's margin went. Nominal from a 15 km perilune 480 km
  short of Tranquility: touchdown at 1.0 m/s in 13.1 min for 2 201 m/s
  with 60 s of hover left, one redesignation, 60 m from the site. A
  700 m boulder field on the aim: the 60 s reserve calls the abort at
  12 m with the aim 10 m off; the 30 s reserve lands with 35 s. A
  kilometre of navigation error lands a kilometre long, as Apollo 11
  landed seven. Two corrections the descent forced upstream: DOI is
  placed by angle (a half-turn plus the braking range before the site,
  because the descent ellipse is faster than the circular orbit and
  arrives 7° early if timed by it), and touchdown comes a braking
  phase after PDI, seven minutes AFTER the orbit would have crossed the
  site. Flown end to end with seed 1969, the mission's DOI is at
  101:36:51, PDI at 102:33:57 and touchdown at 102:46:26 -- the record's
  101:36:14, 102:33:05 and 102:45:40, each within a minute -- at 1.0 m/s,
  401 m from the site, with 98 s of hover left. The descent integrates
  in fixed quarter-second steps whatever the clock hands it, so the
  same seed lands the same way from any warp. The console's side view is
  arc downrange and altitude above terrain; the DEBRIEF is the outcome,
  the reason, the minutes, the Δv, the hover left, the distance, and the
  seed.*
- **MC9 — Consequences and sound.** The anomaly draws, the free-return
  versus hybrid outcome, Quindar tones and the alarm, the seed on the
  debrief, the replay. **Done when** §9 plays through end to end and a
  deliberately thin plan fails for the reason the debrief names. *Done.
  The cards come from their own seeded generator (an SPS fault 4%, a
  program alarm 35% recurring 20%, a dead radar 5%) so a seed keeps its
  dispersions from before. The rules that answer them: LOI is called off
  at MCC-4 when the tracked perilune is outside the 60–200 km corridor
  or no finite burn makes the intended orbit; an SPS fault revealed at
  TLI + 6 h calls it off too; two hours past a perilune without LOI the
  trench asks where the flyby comes back to -- inside the corridor by
  itself is a free return, otherwise a DPS burn searched along and
  across the track (the perigee is set by angular momentum, so three
  days out a few metres a second across move it thousands of
  kilometres), or nowhere the DPS can reach; the alarm opens a
  thirty-second call that defaults to GO unless it recurs; no landing
  radar below ten thousand feet is an abort; and the point-mass Moon
  finally has a surface. The plan sheet says whether the unburned flyby
  is a free return (Apollo 11's is: perigee 1 107 km). §9 end to end,
  seed 1969: LANDED at 102:46:26, and the same seed twice gives the same
  log to the character. The thin plan: "never correct" leaves the S-IVB's
  half a metre a second alone, the perilune tracks at 345 km, LOI is
  called off, PC+2 burns 214 m/s on the DPS, and the crew enter at 97 km
  with no landing -- debrief: MCC policy. A 120 s reserve aborts with
  20 m to go -- debrief: hover reserve. The SPS card coasts home; the
  radar card and the recurring alarm abort; a single alarm gets GO and
  lands. The sound is the chip: a D#7 Quindar-style tone on every call,
  a G6/C7 alternating master alarm, a tick at 1×, and a four-bar figure
  of our own at touchdown, all as ABC on the game pane's deck, built not
  JIT-run. Two words of the criterion were corrected along the way: the
  cards are "the seed", and the plan line the debrief names is the
  choice the physics reached first.*

## The rules that keep it honest

- **Every number on the screen is computed.** The vehicle table of §2 is
  the only typed-in data, and it is labelled as such in the source.
- **Every sprint has an oracle that is not us**: Meeus's examples, Kepler's
  closed form, Apollo 11's report. Numbers that are merely plausible do
  not close a sprint.
- **One integrator.** The CPU truth and the GPU cloud call the same `def`;
  the difference between them is measured and printed, never assumed.
- **No scripted outcomes.** The only randomness is the seeded dispersion
  table of §6; a landing or a loss is the plan meeting the physics, and
  the debrief names the line of the plan sheet responsible.
- **The plot draws states, not shapes.** Nothing on the 3D display is an
  ellipse someone drew; it is the integrated trajectory, sampled.
- **Fixed-width kernel arguments, ping-pong where a thread reads another
  thread's output** -- the two rules every GPU example in the tree has
  paid to learn. The window and dispersion kernels read only their own
  candidate, so neither needs a ping-pong; the rule is recorded so nobody
  adds a neighbour read without one.
- **We do the code; the docs are theirs.** The channel's walkthrough is
  not this project's deliverable; the numbers a presenter needs are on
  the screen and in this file.
