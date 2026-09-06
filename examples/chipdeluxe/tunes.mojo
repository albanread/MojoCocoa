# ChipDeluxe -- the tunes. One for now: the trio showcase from CT2, kept
# here so the player has something true to play while CT6 writes the four
# real demos. Everything audible is [I:chip ...]: the instruments, the
# macros, the pans, the echo.

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
