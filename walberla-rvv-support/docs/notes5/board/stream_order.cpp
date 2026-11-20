// notes5 audit probe E4: the same R read streams as misc/x60-lab/probes/mem.cpp ("mem stream R 0"),
// but the lines of every array are visited either in order (seq) or in a random order (rand, one
// permutation shared by all arrays). Per line step it loads the whole 64-byte line of every array with two
// vle32 (8 floats each), 8 arrays at a time before their sum, as mem.cpp does.
//
// Question (docs/notes5/audit-findings-opus5.5.md, F15): past ~20 streams mem.cpp pays a full DRAM latency
// per line (~360 cycles), although the pointer chase overlaps ~6 independent misses (~61 cycles per line).
// If the hardware prefetcher merely stops, independent demand misses should still overlap, and random order
// (which no stream prefetcher follows) should cost about as much as sequential order past the cliff. If
// sequential order is much slower than random order there, the sequential pattern itself (prefetcher
// activity) serializes the misses.
//
// Usage: stream_order R seq|rand [thp=1] [mb=4] [stagger=4160] [reps=3] [scalar=0]
//   scalar=1: one scalar flw per array and line instead of the two vle32 (same lines, 8 independent loads
//             before their sum): tells whether scalar misses overlap where vector misses do not.
// Prints cycles per 64-byte line (best of reps passes; 1.6 GHz fixed clock: governor performance) and GB/s.
// Build: g++ -O2 -march=rv64gcv_zvl256b stream_order.cpp -o stream_order
#include <riscv_vector.h>
#include <sys/mman.h>
#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <numeric>
#include <random>
#include <string>
#include <vector>

static std::map<std::string, long> kv(int argc, char** argv, int from) {
   std::map<std::string, long> m;
   for (int i = from; i < argc; ++i) {
      const char* e = std::strchr(argv[i], '=');
      if (e) m[std::string(argv[i], (size_t) (e - argv[i]))] = std::atol(e + 1);
   }
   return m;
}

static double now() { return std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count(); }

int main(int argc, char** argv) {
   if (argc < 3) { std::fprintf(stderr, "usage: stream_order R seq|rand [thp=1] [mb=4] [stagger=4160] [reps=3]\n"); return 1; }
   const int R = std::atoi(argv[1]);
   const bool rnd = !std::strcmp(argv[2], "rand");
   auto o = kv(argc, argv, 3);
   const long thp = o.count("thp") ? o["thp"] : 1;
   const size_t mb = o.count("mb") ? o["mb"] : 4;
   const long stagger = o.count("stagger") ? o["stagger"] : 4160;
   const int reps = o.count("reps") ? o["reps"] : 3;
   const bool scalar = o.count("scalar") && o["scalar"];
   const size_t n = mb * (1u << 20) / 4;            // floats per array
   const size_t lines = n / 16;                     // 64-byte lines per array
   const size_t span = n * 4 + stagger;
   const size_t A = 2u << 20;
   const size_t bytes = (span * R + 4096 + A - 1) / A * A;
   void* p = nullptr;
   if (posix_memalign(&p, A, bytes)) { std::perror("alloc"); return 1; }
   if (thp) madvise(p, bytes, MADV_HUGEPAGE);
   char* buf = (char*) p;
   std::vector<float*> a(R);
   for (int r = 0; r < R; ++r) a[r] = (float*) (buf + r * span);
   for (int r = 0; r < R; ++r) for (size_t i = 0; i < n; ++i) a[r][i] = 1.0f + 1e-7f * (float) (i & 1023);
   std::vector<uint32_t> perm(lines);
   std::iota(perm.begin(), perm.end(), 0u);
   if (rnd) std::shuffle(perm.begin(), perm.end(), std::mt19937(42));
   const size_t vl = 8;
   double best = 1e30;
   float sink = 0.f;
   for (int rep = 0; rep < reps; ++rep) {
      const double t0 = now();
      vfloat32m1_t acc = __riscv_vfmv_v_f_f32m1(0.f, vl);
      for (size_t k = 0; k < lines; ++k) {
         const size_t i = (size_t) perm[k] * 16;
         int r = 0;
         if (scalar) {   // 8 independent scalar loads (one per line), then their sum
            float fs = 0.f;
            for (; r + 8 <= R; r += 8) {
               const float b0 = a[r][i], b1 = a[r + 1][i], b2 = a[r + 2][i], b3 = a[r + 3][i];
               const float b4 = a[r + 4][i], b5 = a[r + 5][i], b6 = a[r + 6][i], b7 = a[r + 7][i];
               fs += ((b0 + b1) + (b2 + b3)) + ((b4 + b5) + (b6 + b7));
            }
            for (; r < R; ++r) fs += a[r][i];
            acc = __riscv_vfadd_vf_f32m1(acc, fs, vl);
         }
         for (; r + 8 <= R; r += 8) {   // 8 arrays x 2 loads, all independent, then the sum
            vfloat32m1_t x0 = __riscv_vle32_v_f32m1(a[r + 0] + i, vl), y0 = __riscv_vle32_v_f32m1(a[r + 0] + i + 8, vl);
            vfloat32m1_t x1 = __riscv_vle32_v_f32m1(a[r + 1] + i, vl), y1 = __riscv_vle32_v_f32m1(a[r + 1] + i + 8, vl);
            vfloat32m1_t x2 = __riscv_vle32_v_f32m1(a[r + 2] + i, vl), y2 = __riscv_vle32_v_f32m1(a[r + 2] + i + 8, vl);
            vfloat32m1_t x3 = __riscv_vle32_v_f32m1(a[r + 3] + i, vl), y3 = __riscv_vle32_v_f32m1(a[r + 3] + i + 8, vl);
            vfloat32m1_t x4 = __riscv_vle32_v_f32m1(a[r + 4] + i, vl), y4 = __riscv_vle32_v_f32m1(a[r + 4] + i + 8, vl);
            vfloat32m1_t x5 = __riscv_vle32_v_f32m1(a[r + 5] + i, vl), y5 = __riscv_vle32_v_f32m1(a[r + 5] + i + 8, vl);
            vfloat32m1_t x6 = __riscv_vle32_v_f32m1(a[r + 6] + i, vl), y6 = __riscv_vle32_v_f32m1(a[r + 6] + i + 8, vl);
            vfloat32m1_t x7 = __riscv_vle32_v_f32m1(a[r + 7] + i, vl), y7 = __riscv_vle32_v_f32m1(a[r + 7] + i + 8, vl);
            x0 = __riscv_vfadd_vv_f32m1(x0, y0, vl); x1 = __riscv_vfadd_vv_f32m1(x1, y1, vl);
            x2 = __riscv_vfadd_vv_f32m1(x2, y2, vl); x3 = __riscv_vfadd_vv_f32m1(x3, y3, vl);
            x4 = __riscv_vfadd_vv_f32m1(x4, y4, vl); x5 = __riscv_vfadd_vv_f32m1(x5, y5, vl);
            x6 = __riscv_vfadd_vv_f32m1(x6, y6, vl); x7 = __riscv_vfadd_vv_f32m1(x7, y7, vl);
            x0 = __riscv_vfadd_vv_f32m1(x0, x1, vl); x2 = __riscv_vfadd_vv_f32m1(x2, x3, vl);
            x4 = __riscv_vfadd_vv_f32m1(x4, x5, vl); x6 = __riscv_vfadd_vv_f32m1(x6, x7, vl);
            x0 = __riscv_vfadd_vv_f32m1(x0, x2, vl); x4 = __riscv_vfadd_vv_f32m1(x4, x6, vl);
            acc = __riscv_vfadd_vv_f32m1(acc, __riscv_vfadd_vv_f32m1(x0, x4, vl), vl);
         }
         for (; r < R; ++r) {
            acc = __riscv_vfadd_vv_f32m1(acc, __riscv_vle32_v_f32m1(a[r] + i, vl), vl);
            acc = __riscv_vfadd_vv_f32m1(acc, __riscv_vle32_v_f32m1(a[r] + i + 8, vl), vl);
         }
      }
      float s[8];
      __riscv_vse32_v_f32m1(s, acc, vl);
      sink += s[0];
      best = std::min(best, now() - t0);
   }
   const double total_lines = (double) R * (double) lines;
   std::printf("stream_order R=%d order=%s scalar=%d thp=%ld mb=%zu stagger=%ld cyc_per_line=%.1f GBps=%.3f sink=%d\n", R,
               rnd ? "rand" : "seq", (int) scalar, thp, mb, stagger, best * 1.6e9 / total_lines, total_lines * 64 / best / 1e9,
               (int) (sink == 12345.f));
   return 0;
}
