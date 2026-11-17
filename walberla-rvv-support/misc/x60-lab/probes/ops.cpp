// X60 per-instruction cost probe (misc/x60-lab, Phase 2 of docs/notes3).
//
// For each instruction: throughput = cycles per instruction with 8 independent destinations,
// latency = cycles per instruction in one dependent chain. Vector ops at e32/e64 m1 with
// VLEN = 256 (8 / 4 lanes), scalar FP for comparison. Loads/stores hit L1 (a 1 KB buffer).
// Build: g++ -O2 -march=rv64gcv_zvl256b_zicbop ops.cpp -o ops
#include <cstdio>
#include <cstdint>
#include "pmu.hpp"

alignas(64) static float buf[1024];

#define REP8(x) x x x x x x x x
#define REP64(x) REP8(REP8(x))

//  Run `body` (64 instructions) ITER times and print cycles per instruction.
#define MEASURE(name, setup, body)                                                                     \
   {                                                                                                  \
      Pmu& p = pmu;                                                                                   \
      const long ITER = 20000;                                                                        \
      p.start();   /* first: Linux discards the vector state (vtype -> vill) on every syscall */      \
      asm volatile(setup ::"r"(buf) : "memory", "t0", "ft0", "ft1", "v1", "v2", "v3", "v4", "v5", "v6", "v7", "v8", "v9", "v10"); \
      for (long i = 0; i < ITER; ++i) asm volatile(body ::"r"(buf) : "memory", "t0", "t1", "ft0", "ft1", "ft2", "ft3", "ft4", "ft5", "ft6", "ft7", "ft8", \
                                                         "v1", "v2", "v3", "v4", "v5", "v6", "v7", "v8", "v9", "v10"); \
      p.stop();                                                                                       \
      std::printf("%-28s %6.2f cycles/insn\n", name, (double) p.cycles() / (ITER * 64.0));             \
   }

int main() {
   Pmu pmu;
   for (int i = 0; i < 1024; ++i) buf[i] = 1.0f + i * 1e-6f;
#define VSET32 "li t0, 8\n vsetvli zero, t0, e32, m1, ta, ma\n vle32.v v1, (%0)\n vle32.v v2, (%0)\n vmv.v.v v3, v1\n vmv.v.v v4, v1\n vmv.v.v v5, v1\n vmv.v.v v6, v1\n vmv.v.v v7, v1\n vmv.v.v v8, v1\n vmv.v.v v9, v1\n vmv.v.v v10, v1\n flw ft0, 0(%0)\n flw ft1, 4(%0)\n"
#define VSET64 "li t0, 4\n vsetvli zero, t0, e64, m1, ta, ma\n vle64.v v1, (%0)\n vle64.v v2, (%0)\n vmv.v.v v3, v1\n vmv.v.v v4, v1\n vmv.v.v v5, v1\n vmv.v.v v6, v1\n vmv.v.v v7, v1\n vmv.v.v v8, v1\n vmv.v.v v9, v1\n vmv.v.v v10, v1\n fld ft0, 0(%0)\n fld ft1, 8(%0)\n"
#define TP8(op) op " v3, v1, v2\n" op " v4, v1, v2\n" op " v5, v1, v2\n" op " v6, v1, v2\n" op " v7, v1, v2\n" op " v8, v1, v2\n" op " v9, v1, v2\n" op " v10, v1, v2\n"
#define LAT8(op) op " v3, v3, v2\n" op " v3, v3, v2\n" op " v3, v3, v2\n" op " v3, v3, v2\n" op " v3, v3, v2\n" op " v3, v3, v2\n" op " v3, v3, v2\n" op " v3, v3, v2\n"
#define TPVF8(op) op " v3, v1, ft0\n" op " v4, v1, ft0\n" op " v5, v1, ft0\n" op " v6, v1, ft0\n" op " v7, v1, ft0\n" op " v8, v1, ft0\n" op " v9, v1, ft0\n" op " v10, v1, ft0\n"
#define TPMAC8(op) op " v3, v1, v2\n" op " v4, v1, v2\n" op " v5, v1, v2\n" op " v6, v1, v2\n" op " v7, v1, v2\n" op " v8, v1, v2\n" op " v9, v1, v2\n" op " v10, v1, v2\n"
#define TPS8(op) op " ft2, ft0, ft1\n" op " ft3, ft0, ft1\n" op " ft4, ft0, ft1\n" op " ft5, ft0, ft1\n" op " ft6, ft0, ft1\n" op " ft7, ft0, ft1\n" op " ft8, ft0, ft1\n" op " ft2, ft0, ft1\n"
#define LATS8(op) op " ft2, ft2, ft1\n" op " ft2, ft2, ft1\n" op " ft2, ft2, ft1\n" op " ft2, ft2, ft1\n" op " ft2, ft2, ft1\n" op " ft2, ft2, ft1\n" op " ft2, ft2, ft1\n" op " ft2, ft2, ft1\n"
   for (int e = 32; e <= 64; e += 32) {
      std::printf("== e%d m1\n", e);
      const char* S = e == 32 ? VSET32 : VSET64;
      (void) S;
#define VEC(SET, sfx, off)                                                                                   \
      MEASURE("vfadd.vv tput", SET, REP8(TP8("vfadd.vv")))                                              \
      MEASURE("vfadd.vv lat", SET, REP8(LAT8("vfadd.vv")))                                              \
      MEASURE("vfmul.vv tput", SET, REP8(TP8("vfmul.vv")))                                              \
      MEASURE("vfmul.vv lat", SET, REP8(LAT8("vfmul.vv")))                                              \
      MEASURE("vfmacc.vv tput", SET, REP8(TPMAC8("vfmacc.vv")))                                         \
      MEASURE("vfmacc.vv lat", SET, REP8(LAT8("vfmacc.vv")))                                            \
      MEASURE("vfadd.vf tput", SET, REP8(TPVF8("vfadd.vf")))                                            \
      MEASURE("vfdiv.vv tput", SET, REP8(TP8("vfdiv.vv")))                                              \
      MEASURE("vfdiv.vv lat", SET, REP8(LAT8("vfdiv.vv")))                                              \
      MEASURE("vfrec7.v tput", SET, REP64("vfrec7.v v3, v1\n"))                                         \
      MEASURE("vfmv.v.f tput", SET, REP64("vfmv.v.f v3, ft0\n"))                                        \
      MEASURE("vle" sfx ".v tput (L1)", SET, REP8("vle" sfx ".v v3, (%0)\n vle" sfx ".v v4, (%0)\n vle" sfx ".v v5, (%0)\n vle" sfx ".v v6, (%0)\n vle" sfx ".v v7, (%0)\n vle" sfx ".v v8, (%0)\n vle" sfx ".v v9, (%0)\n vle" sfx ".v v10, (%0)\n")) \
      MEASURE("vle" sfx ".v +1 elem (L1)", SET, "addi t1, %0, " off "\n" REP64("vle" sfx ".v v3, (t1)\n"))                         \
      MEASURE("vse" sfx ".v tput (L1)", SET, REP8("vse" sfx ".v v1, (%0)\n vse" sfx ".v v2, (%0)\n vse" sfx ".v v1, (%0)\n vse" sfx ".v v2, (%0)\n vse" sfx ".v v1, (%0)\n vse" sfx ".v v2, (%0)\n vse" sfx ".v v1, (%0)\n vse" sfx ".v v2, (%0)\n"))
      if (e == 32) { VEC(VSET32, "32", "4") } else { VEC(VSET64, "64", "8") }
   }
   std::printf("== scalar\n");
   MEASURE("fadd.s tput", VSET32, REP8(TPS8("fadd.s")))
   MEASURE("fadd.s lat", VSET32, REP8(LATS8("fadd.s")))
   MEASURE("fmul.s tput", VSET32, REP8(TPS8("fmul.s")))
   MEASURE("fmadd.s tput", VSET32, REP64("fmadd.s ft2, ft0, ft1, ft2\n"))
   MEASURE("fdiv.s tput", VSET32, REP8(TPS8("fdiv.s")))
   MEASURE("fadd.d tput", VSET64, REP8(TPS8("fadd.d")))
   MEASURE("fmul.d tput", VSET64, REP8(TPS8("fmul.d")))
   MEASURE("fdiv.d tput", VSET64, REP8(TPS8("fdiv.d")))
   MEASURE("flw tput (L1)", VSET32, REP8("flw ft2, 0(%0)\n flw ft3, 4(%0)\n flw ft4, 8(%0)\n flw ft5, 12(%0)\n flw ft6, 16(%0)\n flw ft7, 20(%0)\n flw ft8, 24(%0)\n flw ft2, 28(%0)\n"))
   MEASURE("fsw tput (L1)", VSET32, REP8("fsw ft0, 0(%0)\n fsw ft0, 4(%0)\n fsw ft0, 8(%0)\n fsw ft0, 12(%0)\n fsw ft0, 16(%0)\n fsw ft0, 20(%0)\n fsw ft0, 24(%0)\n fsw ft0, 28(%0)\n"))
   return 0;
}
