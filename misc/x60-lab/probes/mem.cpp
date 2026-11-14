// X60 memory-system probes (misc/x60-lab, Phase 2 of docs/notes3).
//
//   mem lat K [thp=0|1] [mb=128]
//       K independent pointer chases through a random cyclic permutation of the cache
//       lines of an mb-MB buffer. Prints cycles per step and per miss; with K chains the
//       hardware can overlap up to K misses, so  MLP = K * cyc(1) / cyc_per_step(K).
//
//   mem stream R W [key=val ...]
//       R read streams and W write streams, unit stride, f32 vectors of 8 lanes (vle32/vse32
//       m1, exactly the kernel's access), all advancing together like the D3Q19 sweep.
//       Prints cycles per 64-byte line touched and GB/s.
//       keys: mb=<MB per stream, default 4>   reps=<passes, default 3>
//             thp=0|1                madvise(MADV_HUGEPAGE) on the buffer before first touch
//             stagger=<bytes>        extra offset between consecutive array bases
//                                    (0 = page- and L1-way-congruent bases, the worst case)
//             pf=<bytes>             touch-ahead: one `lw` per stream and line, pf bytes ahead
//             pfr=<bytes>            the same with the Zicbop encoding prefetch.r (ori x0,rs,1)
//             pfw=<bytes>            prefetch.w (ori x0,rs,3) on each destination line, pfw bytes ahead
//             zero=1                 cbo.zero each destination line before writing it
//             scalar=1               read with one scalar `flw` per 32 bytes instead of a vle32
//                                    (same lines touched; tells vector from scalar miss handling)
//
// Build: g++ -O2 -march=rv64gcv_zvl256b_zicboz mem.cpp -o mem
#include <riscv_vector.h>
#include <sys/mman.h>
#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <numeric>
#include <random>
#include <string>
#include <vector>
#include "pmu.hpp"

static std::map<std::string, long> kv(int argc, char** argv, int from) {
   std::map<std::string, long> m;
   for (int i = from; i < argc; ++i) {
      const char* e = std::strchr(argv[i], '=');
      if (e) m[std::string(argv[i], (size_t) (e - argv[i]))] = std::atol(e + 1);
   }
   return m;
}

static void* big_alloc(size_t bytes, bool thp) {
   const size_t A = 2u << 20;
   void* p = nullptr;
   if (posix_memalign(&p, A, (bytes + A - 1) / A * A)) { std::perror("alloc"); std::exit(1); }
   if (thp) madvise(p, (bytes + A - 1) / A * A, MADV_HUGEPAGE);
   return p;
}

static double now() { return std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count(); }

static int lat(int argc, char** argv) {
   const int K = std::atoi(argv[2]);
   auto o = kv(argc, argv, 3);
   const size_t mb = o.count("mb") ? o["mb"] : 128;
   const size_t lines = mb * (1u << 20) / 64;
   char* buf = (char*) big_alloc(lines * 64, o["thp"]);
   std::vector<uint32_t> perm(lines);
   std::iota(perm.begin(), perm.end(), 0);
   std::shuffle(perm.begin() + 1, perm.end(), std::mt19937(42));
   for (size_t i = 0; i < lines; ++i) *(char**) (buf + perm[i] * 64) = buf + perm[(i + 1) % lines] * 64;
   std::vector<char*> p(K);
   for (int k = 0; k < K; ++k) p[k] = buf + perm[(size_t) k * lines / K] * 64;
   const long steps = 2000000 / K * K / K;
   Pmu pmu;
   //  warm the TLB walk caches a little, then measure
   for (long s = 0; s < 10000; ++s) for (int k = 0; k < K; ++k) p[k] = *(char**) p[k];
   double t0 = now();
   pmu.start();
   //  Each chain lives in its own named register variable (an array would go through the stack,
   //  and on the in-order core the store of a loaded pointer stalls until the load returns).
#define D(i) char* q##i = p[i % K];
#define L(i) if (i < K) q##i = *(char* volatile*) q##i;
#define S(i) if (i < K) p[i] = q##i;
   {
      D(0) D(1) D(2) D(3) D(4) D(5) D(6) D(7) D(8) D(9) D(10) D(11) D(12) D(13) D(14) D(15)
      if (K > 16) { std::fprintf(stderr, "K <= 16\n"); return 1; }
      for (long s = 0; s < steps; ++s) {
         L(0) L(1) L(2) L(3) L(4) L(5) L(6) L(7) L(8) L(9) L(10) L(11) L(12) L(13) L(14) L(15)
      }
      S(0) S(1) S(2) S(3) S(4) S(5) S(6) S(7) S(8) S(9) S(10) S(11) S(12) S(13) S(14) S(15)
   }
   pmu.stop();
   double t = now() - t0;
   uintptr_t sink = 0;
   for (int k = 0; k < K; ++k) sink ^= (uintptr_t) p[k];
   const double cyc = pmu.cycles() ? (double) pmu.cycles() : t * 1.6e9;
   std::printf("lat K=%d thp=%ld mb=%zu cyc_per_step=%.1f cyc_per_miss=%.1f ns_per_step=%.1f sink=%lu\n", K, o["thp"], mb,
               cyc / steps, cyc / steps / K, t / steps * 1e9, (unsigned long) (sink & 1));
   return 0;
}

static inline void touch(const void* a) {
   long v;
   asm volatile("lw %0, 0(%1)" : "=r"(v) : "r"(a) : "memory");   // result never read: no RAW stall
}
static inline void prefetch_r(const void* a) { asm volatile("ori x0, %0, 1" ::"r"(a) : "memory"); }
static inline void prefetch_w(const void* a) { asm volatile("ori x0, %0, 3" ::"r"(a) : "memory"); }
static inline void cbo_zero(void* a) { asm volatile("cbo.zero (%0)" ::"r"(a) : "memory"); }

static int stream(int argc, char** argv) {
   const int R = std::atoi(argv[2]), W = std::atoi(argv[3]);
   auto o = kv(argc, argv, 4);
   const size_t mb = o.count("mb") ? o["mb"] : 4;
   const int reps = o.count("reps") ? o["reps"] : 3;
   const long stagger = o["stagger"], pf = o["pf"], pfr = o["pfr"], pfw = o["pfw"];
   const bool zero = o["zero"], scalar = o["scalar"];
   const size_t n = mb * (1u << 20) / 4;   // floats per stream
   const size_t span = n * 4 + stagger;
   char* buf = (char*) big_alloc(span * (R + W) + 4096, o["thp"]);
   std::vector<float*> rp(R), wp(W);
   for (int r = 0; r < R; ++r) rp[r] = (float*) (buf + r * span);
   for (int w = 0; w < W; ++w) wp[w] = (float*) (buf + (R + w) * span);
   for (int r = 0; r < R; ++r) for (size_t i = 0; i < n; ++i) rp[r][i] = 1.0f + 1e-7f * (float) (i & 1023);
   for (int w = 0; w < W; ++w) std::memset(wp[w], 0, n * 4);
   const size_t vl = 8;
   Pmu pmu;
   double best = 1e30, best_cyc = 0;
   for (int rep = 0; rep < reps; ++rep) {
      const double t0 = now();
      pmu.start();
      vfloat32m1_t acc = __riscv_vfmv_v_f_f32m1(0.f, vl);
      for (size_t i = 0; i < n; i += vl) {
         if (pf && (i & 15) == 0) for (int r = 0; r < R; ++r) touch((const char*) (rp[r] + i) + pf);
         if (pfr && (i & 15) == 0) for (int r = 0; r < R; ++r) prefetch_r((const char*) (rp[r] + i) + pfr);
         int r = 0;
         if (scalar) {   // 8 independent scalar loads per group, summed afterwards
            float fs = 0.f;
            for (; r + 8 <= R; r += 8) {
               float b0 = rp[r][i], b1 = rp[r + 1][i], b2 = rp[r + 2][i], b3 = rp[r + 3][i];
               float b4 = rp[r + 4][i], b5 = rp[r + 5][i], b6 = rp[r + 6][i], b7 = rp[r + 7][i];
               fs += ((b0 + b1) + (b2 + b3)) + ((b4 + b5) + (b6 + b7));
            }
            for (; r < R; ++r) fs += rp[r][i];
            acc = __riscv_vfadd_vf_f32m1(acc, fs, vl);
         }
         for (; r + 8 <= R; r += 8) {   // 8 independent loads, then a sum tree: loads can overlap
            vfloat32m1_t a0 = __riscv_vle32_v_f32m1(rp[r + 0] + i, vl), a1 = __riscv_vle32_v_f32m1(rp[r + 1] + i, vl);
            vfloat32m1_t a2 = __riscv_vle32_v_f32m1(rp[r + 2] + i, vl), a3 = __riscv_vle32_v_f32m1(rp[r + 3] + i, vl);
            vfloat32m1_t a4 = __riscv_vle32_v_f32m1(rp[r + 4] + i, vl), a5 = __riscv_vle32_v_f32m1(rp[r + 5] + i, vl);
            vfloat32m1_t a6 = __riscv_vle32_v_f32m1(rp[r + 6] + i, vl), a7 = __riscv_vle32_v_f32m1(rp[r + 7] + i, vl);
            a0 = __riscv_vfadd_vv_f32m1(a0, a1, vl); a2 = __riscv_vfadd_vv_f32m1(a2, a3, vl);
            a4 = __riscv_vfadd_vv_f32m1(a4, a5, vl); a6 = __riscv_vfadd_vv_f32m1(a6, a7, vl);
            a0 = __riscv_vfadd_vv_f32m1(a0, a2, vl); a4 = __riscv_vfadd_vv_f32m1(a4, a6, vl);
            acc = __riscv_vfadd_vv_f32m1(acc, __riscv_vfadd_vv_f32m1(a0, a4, vl), vl);
         }
         for (; r < R; ++r) acc = __riscv_vfadd_vv_f32m1(acc, __riscv_vle32_v_f32m1(rp[r] + i, vl), vl);
         if (pfw && (i & 15) == 0) for (int w = 0; w < W; ++w) prefetch_w((const char*) (wp[w] + i) + pfw);
         for (int w = 0; w < W; ++w) {
            if (zero && (i & 15) == 0) cbo_zero(wp[w] + i);
            __riscv_vse32_v_f32m1(wp[w] + i, acc, vl);
         }
      }
      float s[8];
      __riscv_vse32_v_f32m1(s, acc, vl);
      pmu.stop();
      const double t = now() - t0;
      if (t < best) { best = t; best_cyc = (double) pmu.cycles(); }
      if (s[0] == 12345.f) std::puts("");   // keep acc alive
   }
   const double lines = (double) (R + W) * n * 4 / 64;
   const double cyc = best_cyc ? best_cyc : best * 1.6e9;
   std::printf("stream R=%d W=%d mb=%zu thp=%ld stagger=%ld pf=%ld pfr=%ld pfw=%ld zero=%d scalar=%d cyc_per_line=%.1f GBps=%.3f\n", R, W, mb,
               o["thp"], stagger, pf, pfr, pfw, (int) zero, (int) scalar, cyc / lines, lines * 64 / best / 1e9);
   return 0;
}

int main(int argc, char** argv) {
   if (argc >= 3 && !std::strcmp(argv[1], "lat")) return lat(argc, argv);
   if (argc >= 4 && !std::strcmp(argv[1], "stream")) return stream(argc, argv);
   std::fprintf(stderr, "usage: mem lat K [thp=1] [mb=128] | mem stream R W [mb= reps= thp= stagger= pf= pfr= zero=]\n");
   return 1;
}
