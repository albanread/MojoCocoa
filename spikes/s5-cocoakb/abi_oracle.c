/* clang is the oracle.
 *
 * Whatever this file does with a struct by value IS the Objective-C ABI on
 * this machine, because clang is what compiled AppKit. Every other test in
 * this directory has Mojo on both ends, which proves only that cocoa-mojo
 * agrees with itself; this one puts the real compiler on the sending side.
 *
 * It exists because a plausible-sounding gate was nearly added to the
 * compiler on the theory that a struct larger than 16 bytes could not survive
 * the trampoline. AAPCS64 passes such a struct as a caller-owned copy behind
 * a pointer and returns one through the hidden x8 register, and the belief
 * was that the trampoline declared it by value and would read the wrong
 * registers. The belief was wrong -- CABIAAPCS.cpp does the classification
 * properly -- and this file is what said so.
 */
#include <objc/message.h>
#include <objc/runtime.h>

typedef struct { double a, b, c, d, e, f; } Big;  /* 48 bytes: indirect, and
                                                   * NOT an HFA -- six members
                                                   * is past the limit of 4 */
typedef struct { double x, y; } Pair;             /* 16 bytes, HFA(2): v0-v1 */

/* Argument, indirect: 1.5+2.5+3.5+4.5+5.5+6.5 = 24. */
void poke_big(id obj) {
  Big v = {1.5, 2.5, 3.5, 4.5, 5.5, 6.5};
  ((void (*)(id, SEL, Big))objc_msgSend)(obj, sel_registerName("setViewport:"), v);
}

/* Argument, homogeneous float aggregate in v0-v1: 10.5+20.5 = 31. */
void poke_pair(id obj) {
  Pair v = {10.5, 20.5};
  ((void (*)(id, SEL, Pair))objc_msgSend)(obj, sel_registerName("setFrameSize:"), v);
}

/* Return, sret through x8: 1+2+4+8+16+32 = 63. Summed here so the value
 * crossing back into Mojo is one double and cannot itself be in question. */
double take_big(id obj) {
  Big t = ((Big (*)(id, SEL))objc_msgSend)(obj, sel_registerName("frameTransform"));
  return t.a + t.b + t.c + t.d + t.e + t.f;
}
