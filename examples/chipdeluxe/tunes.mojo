# ChipDeluxe -- the four demos, and the showcase that came first.
#
# Not covers and not soundalikes: the DEVICES are the tradition, and each
# tune leans on different ones. Everything audible is [I:chip ...] -- the
# instruments, the macros, the pans, the echo -- so the tunes are also the
# grammar's documentation, read aloud.

# ── 1. POWERLINE ────────────────────────────────────────────────────────────
# The driver. Octave bass in eighths with the pulse width breathing,
# arpeggio chords standing in for a pad, offbeat stabs, and a saw lead
# under a slow filter sweep. The Hubbard lesson without a Hubbard note:
# the drive comes from the bass never resting, not from the drums.
comptime TUNE_POWERLINE = String("""X:1
T:Powerline
M:4/4
L:1/8
Q:1/4=152
K:Am
V:1
[I:chip v=1 wave=noise a=0 d=3 s=0 r=2 vol=12]
C2 C C2 C C | C2 C C2 C C | C2 C C2 C C | C2 C C2 C2 |
C2 C C2 C C | C2 C C2 C C | C2 C C2 C C | C C C C C2 C2 |
C2 C C2 C C | C2 C C2 C C | C2 C C2 C C | C2 C C2 C2 |
C2 C C2 C C | C2 C C2 C C | C2 C C2 C C | C C C C C C C C
V:2
[I:chip v=2 wave=pulse pw=1100 a=0 d=5 s=8 r=3 arp=037 pwm=20/2]
A,8 | A,8 | [I:chip v=2 arp=047] F,8 | F,8 |
[I:chip v=2 arp=047] C8 | C8 | [I:chip v=2 arp=047] G,8 | G,8 |
[I:chip v=2 arp=037] A,8 | A,8 | [I:chip v=2 arp=047] F,8 | F,8 |
[I:chip v=2 arp=047] C8 | C8 | [I:chip v=2 arp=047] G,4 [I:chip v=2 arp=037] E,4 | A,8
V:3
[I:chip v=3 wave=pulse pw=300 a=0 d=2 s=0 r=1 vol=11]
z A z A z A z A | z A z A z A z A | z A z A z A z A | z A z A z A z A |
z c z c z c z c | z c z c z c z c | z B z B z B z B | z B z B z B z B |
z A z A z A z A | z A z A z A z A | z A z A z A z A | z A z A z A z A |
z c z c z c z c | z c z c z c z c | z B z B z B z B | z A z A z A z A
V:4
[I:chip v=4 wave=pulse pw=700 a=0 d=4 s=9 r=3 pwm=28/3 filt=1 cutoff=1000 res=4 mode=lp vol=15]
A,, A, A,, A, A,, A, A,, A, | A,, A, A,, A, A,, A, A,, A, | F,, F, F,, F, F,, F, F,, F, | F,, F, F,, F, F,, F, F,, F, |
C, C C, C C, C C, C | C, C C, C C, C C, C | G,, G, G,, G, G,, G, G,, G, | G,, G, G,, G, G,, G, G,, G, |
A,, A, A,, A, A,, A, A,, A, | A,, A, A,, A, A,, A, A,, A, | F,, F, F,, F, F,, F, F,, F, | F,, F, F,, F, F,, F, F,, F, |
C, C C, C C, C C, C | C, C C, C C, C C, C | G,, G, G,, G, G,, G, G,, G, | A,, A, A,, A, A,, A, A,, A,
V:7
[I:chip v=7 wave=saw a=0 d=4 s=8 r=4 vib=8/4 slide=3 filt=1 cutoff=400 res=6 mode=lp sweep=3 vol=14 echo=6 etime=10 efb=6]
z8 | z8 | z8 | z8 |
e2 e2 g2 a2 | e2 d2 c2 d2 | e2 g2 b2 g2 | e4 d4 |
c2 c2 e2 a2 | a2 g2 e2 g2 | a2 c'2 b2 g2 | e4 d4 |
e2 g2 a2 c'2 | b2 a2 g2 e2 | d2 e2 g2 b2 | a8
""")

# ── 2. GLASS CATHEDRAL ──────────────────────────────────────────────────────
# The build. Nine voices arriving one at a time over a pedal, vibrato
# leads in octaves, and the echo doing the choir's work. The Follin
# lesson: vibrato is a voice, not an ornament -- so the depth is real and
# the attacks are slow enough to let it speak.
comptime TUNE_CATHEDRAL = String("""X:1
T:Glass Cathedral
M:4/4
L:1/4
Q:1/4=76
K:Dm
V:1
[I:chip v=1 wave=tri a=9 d=0 s=13 r=10 vol=13]
D,4 | D,4 | D,4 | D,4 | D,4 | D,4 | C,4 | C,4 | _B,,4 | _B,,4 | A,,4 | A,,2 A,,2 | D,4 | D,4
V:2
[I:chip v=2 wave=tri a=8 d=0 s=12 r=9 vol=11]
z4 | z4 | A,4 | A,4 | A,4 | A,4 | G,4 | G,4 | F,4 | F,4 | E,4 | E,4 | A,4 | A,4
V:4
[I:chip v=4 wave=pulse pw=1600 a=6 d=2 s=11 r=8 pwm=30/1 vol=12 echo=9 etime=32 efb=9]
z4 | z4 | z4 | z4 | d2 e2 | f2 e2 | e2 d2 | e2 c2 | d2 f2 | f2 e2 | e2 ^c2 | e2 ^c2 | d4 | d4
V:7
[I:chip v=7 wave=tri a=5 d=2 s=12 r=9 vib=14/4 vol=13 echo=10 etime=32 efb=9]
z4 | z4 | z4 | z4 | z4 | z4 | z4 | z4 | d'2 f'2 | f'2 e'2 | e'2 ^c'2 | e'2 ^c'2 | d'4 | d'4
V:8
[I:chip v=8 wave=tri a=6 d=2 s=11 r=9 vib=10/3 vol=10]
z4 | z4 | z4 | z4 | z4 | z4 | a2 b2 | b2 a2 | a4 | a2 g2 | g4 | g2 e2 | a4 | a4
""")

# ── 3. COPPER SKY ───────────────────────────────────────────────────────────
# The title groove. The melody TRADES between the outer chips, two bars
# left then two bars right, so the stereo is the arrangement rather than
# a decoration; the centre holds the arp pad and a light kit.
comptime TUNE_COPPERSKY = String("""X:1
T:Copper Sky
M:4/4
L:1/8
Q:1/4=120
K:C
V:1
[I:chip v=1 wave=noise a=0 d=2 s=0 r=2 vol=10]
C2 z2 C2 z2 | C2 z2 C2 z2 | C2 z2 C2 z2 | C2 z2 C2 C2 |
C2 z2 C2 z2 | C2 z2 C2 z2 | C2 z2 C2 z2 | C2 z2 C2 C2 |
C2 z2 C2 z2 | C2 z2 C2 z2 | C2 z2 C2 z2 | C2 z2 C2 C2 |
C2 z2 C2 z2 | C2 z2 C2 z2 | C2 z2 C2 z2 | C2 C2 C2 C2
V:2
[I:chip v=2 wave=pulse pw=900 a=1 d=5 s=9 r=4 arp=047 pwm=18/1 vol=12]
C8 | C8 | [I:chip v=2 arp=037] A,8 | A,8 |
[I:chip v=2 arp=047] F,8 | F,8 | [I:chip v=2 arp=047] G,8 | G,8 |
[I:chip v=2 arp=047] C8 | C8 | [I:chip v=2 arp=037] A,8 | A,8 |
[I:chip v=2 arp=047] F,8 | F,8 | [I:chip v=2 arp=047] G,8 | [I:chip v=2 arp=047] C8
V:4
[I:chip v=4 wave=pulse pw=500 a=0 d=4 s=8 r=4 slide=6 filt=1 cutoff=800 res=5 mode=lp vol=14]
C,2 C2 G,2 C2 | C,2 C2 G,2 E2 | A,,2 A,2 E,2 A,2 | A,,2 A,2 C2 A,2 |
F,,2 F,2 C,2 F,2 | F,,2 F,2 A,2 F,2 | G,,2 G,2 D2 G,2 | G,,2 G,2 B,2 G,2 |
C,2 C2 G,2 C2 | C,2 C2 G,2 E2 | A,,2 A,2 E,2 A,2 | A,,2 A,2 C2 A,2 |
F,,2 F,2 C,2 F,2 | F,,2 F,2 A,2 F,2 | G,,2 G,2 D2 G,2 | C,2 C2 G,2 C,2
V:5
[I:chip v=5 wave=saw a=0 d=4 s=9 r=5 vib=7/4 vol=12 echo=7 etime=25 efb=7]
z8 | z8 | e2 g2 a2 e2 | a2 g2 e2 d2 |
z8 | z8 | d2 f2 g2 b2 | g4 e4 |
z8 | z8 | e2 g2 a2 c'2 | a2 g2 e2 g2 |
z8 | z8 | d2 g2 b2 d'2 | c'8
V:7
[I:chip v=7 wave=pulse pw=1500 a=0 d=4 s=9 r=5 vib=9/5 pwm=30/2 vol=12 echo=7 etime=25 efb=7]
e2 g2 c'2 g2 | e'2 c'2 g2 e2 | z8 | z8 |
a2 c'2 f'2 c'2 | a'2 f'2 c'2 a2 | z8 | z8 |
g2 c'2 e'2 c'2 | g'2 e'2 c'2 g2 | z8 | z8 |
a2 d'2 f'2 a'2 | f'2 d'2 a2 f2 | z8 | z8
""")

# ── 4. FOUR-KILOBYTE WALTZ ──────────────────────────────────────────────────
# The delicate one. Three-four at a lilt, a triangle lead that mostly
# plays BEAT ONE -- the echo is tuned to a beat (Q=140 makes a beat 21.4
# ticks; etime=21) so the repeats ARE beats two and three, quieter each
# time, and the accompaniment is the machine remembering the melody.
comptime TUNE_WALTZ = String("""X:1
T:Four-Kilobyte Waltz
M:3/4
L:1/4
Q:1/4=140
K:G
V:1
[I:chip v=1 wave=noise a=0 d=1 s=0 r=1 vol=7]
z C C | z C C | z C C | z C C | z C C | z C C | z C C | z C C |
z C C | z C C | z C C | z C C | z C C | z C C | z C C | z C C |
z C C | z C C | z C C | z C C | z C C | z C C | z C C | C C C
V:4
[I:chip v=4 wave=pulse pw=800 a=1 d=4 s=7 r=5 vol=12]
G,, z z | D, z z | G,, z z | D, z z | E,, z z | B,, z z | C, z z | D, z z |
G,, z z | D, z z | E,, z z | B,, z z | C, z z | A,, z z | D, z z | D, z z |
G,, z z | D, z z | E,, z z | C, z z | G,, z z | D, z z | C, z z | G,, z z
V:7
[I:chip v=7 wave=tri a=2 d=3 s=10 r=7 vib=8/3 vol=14 echo=13 etime=21 efb=9]
b z z | a z z | g z z | d z z | e z z | f z z | e z d | d z z |
b z z | a z z | g z e | d z z | c z z | e z z | a z ^f | d z z |
g z z | b z z | e' z z | c' z b | a z g | b z a | g z ^f | g z z
""")

comptime TUNE_SHOWCASE = String("""X:1
T:TrioShowcase
M:4/4
L:1/8
Q:1/4=140
K:Am
V:1
[I:chip v=1 wave=pulse pw=1000 a=0 d=4 s=9 r=4 arp=037 pwm=24/2 filt=1 cutoff=500 res=5 mode=lp sweep=4 vol=13]
A,8 | [I:chip v=1 arp=047] F,8 | [I:chip v=1 arp=047] C8 | [I:chip v=1 arp=047] G,8 |
[I:chip v=1 arp=037] A,8 | [I:chip v=1 arp=047] F,8 | [I:chip v=1 arp=047] C4 [I:chip v=1 arp=047] G,4 | [I:chip v=1 arp=037] A,8
V:2
[I:chip v=2 wave=noise a=0 d=2 s=0 r=2]
C2 z2 C2 z2 | C2 z2 C2 z2 | C2 z2 C2 z2 | C2 z2 C2 C2 |
C2 z2 C2 z2 | C2 z2 C2 z2 | C2 C2 C2 C2 | C2 z2 C2 z2
V:4
[I:chip v=4 wave=pulse pw=600 a=0 d=3 s=8 r=3 slide=8 filt=1 cutoff=900 res=4 mode=lp vol=14]
A,,4 A,4 | F,,4 F,4 | C,4 C4 | G,,4 G,4 |
A,,4 A,4 | F,,4 F,4 | C,2 C2 G,,2 G,2 | A,,8
V:7
[I:chip v=7 wave=pulse pw=1800 a=1 d=4 s=10 r=6 vib=10/5 pwm=40/3 vol=13 echo=8 etime=13 efb=7]
z8 | z8 | e4 d4 | e2 d2 c2 =b2 |
a4 c'2 b2 | a4 e4 | g2 e2 d2 e2 | a8
""")


def tune_source(k: Int) raises -> String:
    """Tune k of the list, in the order the player's keys pick them."""
    if k == 0:
        return TUNE_POWERLINE
    if k == 1:
        return TUNE_CATHEDRAL
    if k == 2:
        return TUNE_COPPERSKY
    if k == 3:
        return TUNE_WALTZ
    return TUNE_SHOWCASE


def tune_name(k: Int) raises -> String:
    if k == 0:
        return String("POWERLINE")
    if k == 1:
        return String("GLASS CATHEDRAL")
    if k == 2:
        return String("COPPER SKY")
    if k == 3:
        return String("FOUR-KILOBYTE WALTZ")
    return String("TRIO SHOWCASE")

comptime TUNE_COUNT = 5
